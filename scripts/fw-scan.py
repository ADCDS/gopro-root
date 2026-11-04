#!/usr/bin/env python3
"""Static verification of the `SC` -> `RTsetSC` root hook in GoPro firmware.

The HERO11 finding is that gpNet's BP command table contains an `SC` entry
whose handler (RTsetSC) runs a script from the SD card as root:

    system("/tmp/fuse_d/scheduled_capture.sh&")

This tool answers the same question for another `DATA.bin`:

  1. find the gpNet ELF inside the Milbeaut firmware container
     (AArch64 ET_EXEC, AArch64 PIE, or ARM32),
  2. parse every command-set descriptor / entry table,
  3. look for an entry named `SC`,
  4. disassemble that entry's handler and resolve calls to `system`/`fopen64`
     with their string arguments,
  5. do the same for the gpHttpServer ELF, checking that the unauthenticated
     `/gp/gpCamera` proxy route is present.

It is deliberately conservative: a positive result means the vulnerable code
is present in the image, not that the camera was physically tested.

Usage:
    fw-scan.py DATA.bin [--model NAME] [--version VER] [--json out.json]
                        [--keep ELF_DIR]

Requires: pyelftools, capstone (see scripts/requirements.txt).
"""

import argparse
import hashlib
import json
import mmap
import os
import re
import struct
import subprocess
import sys
import tempfile

try:
    from elftools.elf.elffile import ELFFile
except ImportError:
    sys.exit("missing pyelftools: pip install -r scripts/requirements.txt")

try:
    from capstone import (Cs, CS_ARCH_ARM, CS_ARCH_ARM64, CS_MODE_ARM,
                          CS_MODE_LITTLE_ENDIAN)
    from capstone.arm import ARM_OP_REG, ARM_OP_IMM, ARM_OP_MEM
    from capstone.arm64 import ARM64_OP_REG, ARM64_OP_IMM
except ImportError:
    sys.exit("missing capstone: pip install -r scripts/requirements.txt")


# --------------------------------------------------------------------------
# ELF container helpers

ELF_MAGIC = b"\x7fELF"
AARCH64 = 0xB7
ARM = 40
ET_EXEC = 2
ET_DYN = 3
SHF_EXECINSTR = 0x4

GPNET_NEEDLES = (
    b"gpCommand.c",
    b"CAT_CGI_BP_CMD",
    b"smarty-camera-support/gpNet",
    b"RTsetSC",
)
HTTP_NEEDLES = (b"gpCameraHandler", b"/gp/gpCamera")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def elf_extent(m, off):
    """Byte length of an AArch64 or ARM ELF at `off`, or None.

    Both the 64-bit (AArch64) and 32-bit (ARM) GoPro gpNet builds occur; the
    header layout differs, so parse the class-specific offsets.
    """
    if m[off:off + 4] != ELF_MAGIC or m[off + 5] != 1:
        return None
    elfclass = m[off + 4]
    e_type, e_machine = struct.unpack_from("<HH", m, off + 0x10)
    if e_type not in (ET_EXEC, ET_DYN):
        return None
    if elfclass == 2 and e_machine == AARCH64:
        pass
    elif elfclass == 1 and e_machine == ARM:
        pass
    else:
        return None
    try:
        if elfclass == 2:
            e_phoff, e_shoff = struct.unpack_from("<QQ", m, off + 0x20)
            e_phentsize, e_phnum = struct.unpack_from("<HH", m, off + 0x36)
            e_shentsize, e_shnum = struct.unpack_from("<HH", m, off + 0x3A)
        else:
            e_phoff, e_shoff = struct.unpack_from("<II", m, off + 0x1C)
            e_phentsize, e_phnum = struct.unpack_from("<HH", m, off + 0x2A)
            e_shentsize, e_shnum = struct.unpack_from("<HH", m, off + 0x2E)
    except struct.error:
        return None
    if not (0 < e_phnum <= 64) or not (0 < e_shnum <= 256):
        return None
    end = 0
    try:
        for k in range(e_phnum):
            o = off + e_phoff + k * e_phentsize
            if elfclass == 2:
                p_off = struct.unpack_from("<Q", m, o + 0x08)[0]
                p_filesz = struct.unpack_from("<Q", m, o + 0x20)[0]
            else:
                p_off = struct.unpack_from("<I", m, o + 0x04)[0]
                p_filesz = struct.unpack_from("<I", m, o + 0x10)[0]
            end = max(end, p_off + p_filesz)
        for k in range(e_shnum):
            o = off + e_shoff + k * e_shentsize
            if elfclass == 2:
                sh_off, sh_size = struct.unpack_from("<QQ", m, o + 0x18)
            else:
                sh_off, sh_size = struct.unpack_from("<II", m, o + 0x10)
            end = max(end, sh_off + sh_size)
        # the section/program header tables themselves must be inside the carve
        end = max(end, e_shoff + e_shnum * e_shentsize)
        end = max(end, e_phoff + e_phnum * e_phentsize)
    except struct.error:
        return None
    if end < 0x1000 or end > (64 << 20):
        return None
    return end


def find_elf_for_hits(m, data_size, needles, search_back=64 << 20):
    """Find the AArch64 ELF that contains one of `needles`.

    Returns [(needle, hit_offset, elf_offset, elf_size, locator)] deduped by
    ELF offset.  The nearest preceding ELF whose extent covers the hit wins.
    """
    found = {}
    for needle in needles:
        start = 0
        while True:
            hit = m.find(needle, start)
            if hit < 0:
                break
            start = hit + 1
            pos = hit
            elf_off = None
            while True:
                cand = m.rfind(ELF_MAGIC, max(0, hit - search_back), pos)
                if cand < 0:
                    break
                size = elf_extent(m, cand)
                if size and cand + size > hit:
                    elf_off, elf_size = cand, size
                    break
                pos = cand
            if elf_off is not None and elf_off not in found:
                found[elf_off] = {
                    "needle": needle.decode("ascii", "replace"),
                    "hit_offset": hit,
                    "elf_offset": elf_off,
                    "elf_size": elf_size,
                }
    return list(found.values())


def carve(m, off, size, out_path):
    with open(out_path, "wb") as fh:
        fh.write(m[off:off + size])
    return out_path


# --------------------------------------------------------------------------
# ELF analysis

class Elf:
    def __init__(self, path):
        self.path = path
        self.fh = open(path, "rb")
        self.elf = ELFFile(self.fh)
        self.sections = list(self.elf.iter_sections())
        self.elfclass = self.elf.elfclass
        self.is_arm = self.elf["e_machine"] == "EM_ARM"
        self.is_aarch64 = self.elf["e_machine"] == "EM_AARCH64"
        self._fde = None

    def section_at(self, addr):
        for s in self.sections:
            a, n = s["sh_addr"], s["sh_size"]
            if a <= addr < a + n:
                return s
        return None

    def section_named(self, name):
        return self.elf.get_section_by_name(name)

    def in_exec(self, addr):
        s = self.section_at(addr)
        return bool(s and (s["sh_flags"] & SHF_EXECINSTR))

    def read_cstr(self, addr):
        s = self.section_at(addr)
        if not s:
            return None
        d = s.data()
        off = addr - s["sh_addr"]
        if off < 0 or off >= len(d):
            return None
        z = d.find(b"\0", off)
        if z < 0:
            z = len(d)
        return d[off:z].decode("utf-8", "replace")

    def find_string_addr(self, needle):
        """Virtual address of `needle` in a loaded section, or None."""
        if isinstance(needle, str):
            needle = needle.encode()
        for s in self.sections:
            if not (s["sh_flags"] & 0x2):  # SHF_ALLOC
                continue
            if s["sh_type"] == "SHT_NOBITS":
                continue
            d = s.data()
            i = d.find(needle)
            if i >= 0:
                return s["sh_addr"] + i
        return None

    def find_string_addrs(self, needle, limit=8):
        if isinstance(needle, str):
            needle = needle.encode()
        out = []
        for s in self.sections:
            if not (s["sh_flags"] & 0x2) or s["sh_type"] == "SHT_NOBITS":
                continue
            d = s.data()
            i = 0
            while len(out) < limit:
                i = d.find(needle, i)
                if i < 0:
                    break
                out.append(s["sh_addr"] + i)
                i += 1
        return out

    def plt_stubs(self):
        """{stub_addr: symbol_name} for the dynamic PLT."""
        plt = self.section_named(".plt")
        dynsym = self.section_named(".dynsym")
        if not (plt and dynsym):
            return {}
        if self.is_arm:
            return self._arm_plt_stubs(plt, dynsym)
        out = {}
        rela = self.section_named(".rela.plt")
        if not rela:
            return out
        base = plt["sh_addr"]
        for i, rel in enumerate(rela.iter_relocations()):
            sym = dynsym.get_symbol(rel["r_info_sym"])
            out[base + 32 + 16 * i] = sym.name
        return out

    def _arm_plt_stubs(self, plt, dynsym):
        """ARM PLT stubs compute their GOT slot from PC; decode them and match
        the slot against .rel.plt so the mapping does not depend on ordering."""
        rel = self.section_named(".rel.plt")
        if not rel:
            return {}
        got_to_sym = {}
        for r in rel.iter_relocations():
            got_to_sym[r["r_offset"]] = dynsym.get_symbol(r["r_info_sym"]).name
        d = plt.data()
        base = plt["sh_addr"]
        md = Cs(CS_ARCH_ARM, CS_MODE_ARM | CS_MODE_LITTLE_ENDIAN)
        md.detail = True
        insns = list(md.disasm(d, base))
        out = {}
        for i in range(len(insns) - 2):
            a, b, c = insns[i], insns[i + 1], insns[i + 2]
            if not (a.mnemonic == "add" and len(a.operands) >= 3 and
                    a.operands[0].type == ARM_OP_REG and
                    a.reg_name(a.operands[0].reg) == "ip" and
                    a.reg_name(a.operands[1].reg) == "pc" and
                    b.mnemonic == "add" and len(b.operands) == 3 and
                    b.operands[0].type == ARM_OP_REG and
                    b.reg_name(b.operands[0].reg) == "ip" and
                    b.reg_name(b.operands[1].reg) == "ip" and
                    b.operands[2].type == ARM_OP_IMM and
                    c.mnemonic == "ldr" and len(c.operands) == 2 and
                    c.reg_name(c.operands[0].reg) == "pc" and
                    c.operands[1].type == ARM_OP_MEM and
                    c.reg_name(c.operands[1].mem.base) == "ip"):
                continue
            try:
                val = (a.address + 8) + a.operands[2].imm
                val += b.operands[2].imm
                got = val + c.operands[1].mem.disp
            except (IndexError, AttributeError):
                continue
            sym = got_to_sym.get(got)
            if sym:
                out[a.address] = sym
        return out

    def fde_ranges(self):
        """[(start, end)] from readelf --debug-dump=frames, or []."""
        if self._fde is not None:
            return self._fde
        ranges = []
        try:
            txt = subprocess.run(
                ["readelf", "--debug-dump=frames", self.path],
                capture_output=True, text=True, timeout=120,
            ).stdout
            for m in re.finditer(r"pc=([0-9a-f]+)\.\.([0-9a-f]+)", txt):
                ranges.append((int(m.group(1), 16), int(m.group(2), 16)))
        except (OSError, subprocess.SubprocessError):
            pass
        self._fde = ranges
        return ranges

    def function_range(self, addr, fallback=0x800):
        for a, b in self.fde_ranges():
            if a <= addr < b:
                return a, b
        return addr, addr + (0x400 if self.is_arm else fallback)

    def disasm(self, start, end, stop_at_ret=False):
        s = self.section_at(start)
        if not s or not (s["sh_flags"] & SHF_EXECINSTR):
            return []
        data = s.data()
        off = start - s["sh_addr"]
        code = data[off:off + (end - start)]
        if self.is_arm:
            md = Cs(CS_ARCH_ARM, CS_MODE_ARM | CS_MODE_LITTLE_ENDIAN)
        else:
            md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
        md.detail = True
        out = []
        for ins in md.disasm(code, start):
            out.append(ins)
            if stop_at_ret:
                if self.is_arm:
                    if ins.mnemonic == "bx" and "lr" in ins.op_str:
                        break
                    if ins.mnemonic == "pop" and "pc" in ins.op_str:
                        break
                elif ins.mnemonic == "ret":
                    break
        return out

    def section_bytes(self, addr, size):
        s = self.section_at(addr)
        if not s:
            return None
        off = addr - s["sh_addr"]
        if off < 0 or off + size > len(s.data()):
            return None
        return s.data()[off:off + size]

    def build_id(self):
        """Hex GNU build-id from .note.gnu.build-id, or None."""
        s = self.section_named(".note.gnu.build-id")
        if not s:
            return None
        d = s.data()
        try:
            namesz, descsz, _ = struct.unpack_from("<III", d, 0)
            name = d[12:12 + namesz]
            desc = d[12 + ((namesz + 3) & ~3):][:descsz]
        except struct.error:
            return None
        if name.rstrip(b"\0") != b"GNU":
            return None
        return desc.hex()


def find_bp_cmd_table(elf, tables):
    """Find the CAT_CGI_BP_CMD dispatch entry in s_cats and the command table
    it points at."""
    if elf.elfclass == 32:
        return find_bp_cmd_table_arm(elf, tables)
    name_addr = elf.find_string_addr("CAT_CGI_BP_CMD")
    if name_addr is None:
        return None

    def is_scats(off, d, base):
        if off < 0 or off + 32 > len(d):
            return False
        q0, q1, q2, q3 = struct.unpack_from("<4Q", d, off)
        if not elf.section_at(q0) or not elf.section_at(q2):
            return False
        name = elf.read_cstr(q0)
        if not name or len(name) > 64:
            return False
        if not re.fullmatch(r"[A-Z0-9_]+", name):
            return False
        if q3 > 64:
            return False
        return True

    for secname in (".rodata", ".data.rel.ro", ".data"):
        sec = elf.section_named(secname)
        if not sec or sec["sh_type"] == "SHT_NOBITS":
            continue
        d = sec.data()
        base = sec["sh_addr"]
        target = struct.pack("<Q", name_addr)
        i = 0
        while True:
            i = d.find(target, i)
            if i < 0:
                break
            addr = base + i
            if addr % 8 == 0 and is_scats(i, d, base):
                desc_ptr = struct.unpack_from("<Q", d, i + 16)[0]
                for t in tables:
                    if t["descriptor"] == desc_ptr:
                        start = i
                        while start >= 32 and is_scats(start - 32, d, base):
                            start -= 32
                        return {
                            "s_cats_entry": addr,
                            "s_cats_index": (i - start) // 32,
                            "descriptor": desc_ptr,
                            "table": t["entries_ptr"],
                            "count": t["count"],
                        }
            i += 1
    return None




def reg_name(ins, op):
    return ins.reg_name(op.reg)


def resolve_reg_arm(elf, insns, idx, reg, depth=0):
    """ARM (A32) variant: movw/movt pairs, mov, add, and PC-relative ldr."""
    if depth > 8 or idx <= 0:
        return None

    def dst_of(ins):
        if ins.operands and ins.operands[0].type == ARM_OP_REG:
            return ins.reg_name(ins.operands[0].reg)
        return None

    for j in range(idx - 1, max(-1, idx - 48), -1):
        ins = insns[j]
        ops = ins.operands
        m = ins.mnemonic
        if m == "movt" and dst_of(ins) == reg and len(ops) >= 2                 and ops[1].type == ARM_OP_IMM:
            hi = ops[1].imm
            for k in range(j - 1, max(-1, j - 24), -1):
                if insns[k].mnemonic == "movw" and dst_of(insns[k]) == reg                         and len(insns[k].operands) >= 2:
                    return (hi << 16) | (insns[k].operands[1].imm & 0xFFFF)
            return hi << 16
        if m == "movw" and dst_of(ins) == reg and len(ops) >= 2                 and ops[1].type == ARM_OP_IMM:
            lo = ops[1].imm & 0xFFFF
            for k in range(j - 1, max(-1, j - 24), -1):
                if insns[k].mnemonic == "movt" and dst_of(insns[k]) == reg                         and len(insns[k].operands) >= 2:
                    return ((insns[k].operands[1].imm & 0xFFFF) << 16) | lo
            return lo
        if m == "mov" and dst_of(ins) == reg and len(ops) == 2                 and ops[1].type == ARM_OP_REG:
            return resolve_reg_arm(elf, insns, j, ins.reg_name(ops[1].reg),
                                   depth + 1)
        if m == "add" and dst_of(ins) == reg and len(ops) == 3                 and ops[1].type == ARM_OP_REG and ops[2].type == ARM_OP_IMM:
            base = resolve_reg_arm(elf, insns, j, ins.reg_name(ops[1].reg),
                                   depth + 1)
            return None if base is None else base + ops[2].imm
        if m == "ldr" and dst_of(ins) == reg and len(ops) == 2                 and ops[1].type == ARM_OP_MEM and \
                ins.reg_name(ops[1].mem.base) == "pc":
            addr = ins.address + 8 + ops[1].mem.disp
            raw = elf.section_bytes(addr, 4)
            if raw:
                return struct.unpack("<I", raw)[0]
            return None
    return None


def resolve_reg(elf, insns, idx, reg, depth=0):
    """Resolve `reg` at instruction index `idx` (exclusive) to a constant."""
    if elf.is_arm:
        return resolve_reg_arm(elf, insns, idx, reg, depth)
    if depth > 8 or idx <= 0:
        return None
    for j in range(idx - 1, max(-1, idx - 48), -1):
        ins = insns[j]
        ops = ins.operands
        m = ins.mnemonic
        if m == "adrp" and len(ops) == 2 and ops[0].type == ARM64_OP_REG \
                and ops[1].type == ARM64_OP_IMM and reg_name(ins, ops[0]) == reg:
            return ops[1].imm
        if m == "add" and len(ops) == 3 and ops[0].type == ARM64_OP_REG \
                and ops[1].type == ARM64_OP_REG and ops[2].type == ARM64_OP_IMM \
                and reg_name(ins, ops[0]) == reg:
            base = resolve_reg(elf, insns, j, reg_name(ins, ops[1]), depth + 1)
            return None if base is None else base + ops[2].imm
        if m == "mov" and len(ops) == 2 and ops[0].type == ARM64_OP_REG \
                and ops[1].type == ARM64_OP_REG and reg_name(ins, ops[0]) == reg:
            return resolve_reg(elf, insns, j, reg_name(ins, ops[1]), depth + 1)
        if m in ("movz", "mov") and len(ops) == 2 and ops[0].type == ARM64_OP_REG \
                and ops[1].type == ARM64_OP_IMM and reg_name(ins, ops[0]) == reg:
            return ops[1].imm
        if m == "mov" and len(ops) == 2 and ops[0].type == ARM64_OP_REG \
                and ops[1].type == ARM64_OP_REG and reg_name(ins, ops[1]) == "xzr" \
                and reg_name(ins, ops[0]) == reg:
            return 0
    return None


def calls_in(elf, start, end):
    """Resolve direct calls in [start,end) with their x0 string argument.

    External calls through the PLT get `symbol`; direct calls into .text get
    `symbol=None` so they can be followed (e.g. RTsetSC -> start_sched_cap ->
    system in newer firmware).
    """
    insns = elf.disasm(start, end, stop_at_ret=elf.is_arm)
    stubs = elf.plt_stubs()
    argreg = "r0" if elf.is_arm else "x0"
    out = []
    for i, ins in enumerate(insns):
        if ins.mnemonic not in ("bl", "b") or not ins.operands:
            continue
        target = ins.operands[0].imm
        name = stubs.get(target)
        if name is None and not elf.in_exec(target):
            continue
        x0 = resolve_reg(elf, insns, i, argreg)
        sarg = elf.read_cstr(x0) if x0 else None
        out.append({
            "at": ins.address,
            "kind": ins.mnemonic,
            "target": target,
            "symbol": name,
            "arg_addr": x0,
            "arg": sarg,
        })
    return out


def collect_calls(elf, fn, depth=0, seen=None, path=None, max_functions=64):
    """Follow local calls from `fn` and return system/popen calls with strings."""
    if seen is None:
        seen = set()
    if path is None:
        path = []
    if depth > 3 or fn in seen or len(seen) >= max_functions or not elf.in_exec(fn):
        return []
    seen.add(fn)
    start, end = elf.function_range(fn)
    out = []
    for c in calls_in(elf, start, end):
        c = dict(c)
        c["via"] = path + [fn]
        if c["symbol"] in ("system", "popen"):
            if c["arg"]:
                out.append(c)
        elif c["symbol"] is None:
            target = c["target"]
            # Ignore intra-function branches: only follow real calls / tail
            # calls into another function (FDE start).
            if start <= target < end:
                continue
            tstart, _ = elf.function_range(target)
            if tstart != target:
                continue
            out.extend(collect_calls(elf, target, depth + 1, seen,
                                     path + [fn], max_functions))
    return out



def find_bp_cmd_table_arm(elf, tables):
    """ARM s_cats entries are 20 bytes: {desc*, type, name*, len, max}."""
    name_addr = elf.find_string_addr("CAT_CGI_BP_CMD")
    if name_addr is None:
        return None
    target = struct.pack("<I", name_addr)

    def is_scats(off, d):
        if off < 0 or off + 20 > len(d):
            return False
        desc, etype, nm, length, mx = struct.unpack_from("<5I", d, off)
        if not elf.section_at(desc) or not elf.section_at(nm):
            return False
        name = elf.read_cstr(nm)
        if not name or len(name) > 64:
            return False
        if not re.fullmatch(r"[A-Z0-9_]+", name):
            return False
        if etype > 16 or length > 64 or mx > 64:
            return False
        return True

    for secname in (".rodata", ".data.rel.ro", ".data"):
        sec = elf.section_named(secname)
        if not sec or sec["sh_type"] == "SHT_NOBITS":
            continue
        d = sec.data()
        base = sec["sh_addr"]
        i = 0
        while True:
            i = d.find(target, i)
            if i < 0:
                break
            start = i - 8  # name is the third u32 of the 20-byte entry
            if start >= 0 and is_scats(start, d):
                desc, etype, nm, length, mx = struct.unpack_from("<5I", d, start)
                for t in tables:
                    if t["descriptor"] == desc:
                        s0 = start
                        while s0 >= 20 and is_scats(s0 - 20, d):
                            s0 -= 20
                        return {
                            "s_cats_entry": base + start,
                            "s_cats_index": (start - s0) // 20,
                            "descriptor": desc,
                            "table": t["entries_ptr"],
                            "count": t["count"],
                        }
            i += 1
    return None



def parse_command_tables_arm(elf):
    """ARM descriptors are 16 bytes {names*, entries*, entries*, count} and
    entries are 20 bytes {fn, max, min, extra1, extra2}."""
    tables = []
    seen = set()
    for secname in (".data", ".data.rel.ro", ".rodata"):
        sec = elf.section_named(secname)
        if not sec:
            continue
        d = sec.data()
        base = sec["sh_addr"]
        for off in range(0, max(0, len(d) - 16), 4):
            names_ptr, ent_ptr, ent_ptr2, count = struct.unpack_from("<4I", d, off)
            if names_ptr == 0 or ent_ptr == 0 or ent_ptr != ent_ptr2:
                continue
            if not (1 <= count <= 512):
                continue
            nsec = elf.section_at(names_ptr)
            esec = elf.section_at(ent_ptr)
            if not nsec or not esec:
                continue
            if nsec["sh_type"] == "SHT_NOBITS" or esec["sh_type"] == "SHT_NOBITS":
                continue
            if names_ptr + 2 * count > nsec["sh_addr"] + nsec["sh_size"]:
                continue
            if ent_ptr + 20 * count > esec["sh_addr"] + esec["sh_size"]:
                continue
            nd = nsec.data()
            nb = nd[names_ptr - nsec["sh_addr"]:names_ptr - nsec["sh_addr"] + 2 * count]
            if not all(0x20 <= b < 0x7f for b in nb):
                continue
            ed = esec.data()
            eo = ent_ptr - esec["sh_addr"]
            entries = []
            good = 0
            for k in range(count):
                fn, maxlen, minlen, extra1, extra2 = struct.unpack_from(
                    "<5I", ed, eo + 20 * k)
                name = nb[2 * k:2 * k + 2].decode("ascii")
                entries.append({
                    "index": k,
                    "name": name,
                    "fn": fn,
                    "max_len": maxlen,
                    "min_len": minlen,
                    "extra1": extra1,
                    "extra2": extra2,
                })
                if fn == 0:
                    good += 1
                elif elf.in_exec(fn) and maxlen <= 0x100000 and minlen <= 0x100000:
                    good += 1
            if good < count * 0.8:
                continue
            key = (names_ptr, ent_ptr, count)
            if key in seen:
                continue
            seen.add(key)
            tables.append({
                "descriptor": base + off,
                "names_ptr": names_ptr,
                "entries_ptr": ent_ptr,
                "count": count,
                "names": nb.decode("ascii"),
                "entries": entries,
            })
    return tables



def parse_command_tables(elf):
    """Find command-set descriptors {names, entries, entries, count} and their
    entry tables.  Returns a list of dicts."""
    if elf.elfclass == 32:
        return parse_command_tables_arm(elf)
    tables = []
    seen = set()
    for secname in (".data", ".data.rel.ro", ".rodata"):
        sec = elf.section_named(secname)
        if not sec:
            continue
        d = sec.data()
        base = sec["sh_addr"]
        for off in range(0, max(0, len(d) - 32), 8):
            names_ptr, ent_ptr, ent_ptr2, count = struct.unpack_from("<4Q", d, off)
            if names_ptr == 0 or ent_ptr == 0 or ent_ptr != ent_ptr2:
                continue
            if not (1 <= count <= 512):
                continue
            nsec = elf.section_at(names_ptr)
            esec = elf.section_at(ent_ptr)
            if not nsec or not esec:
                continue
            if nsec["sh_type"] == "SHT_NOBITS" or esec["sh_type"] == "SHT_NOBITS":
                continue
            if names_ptr + 2 * count > nsec["sh_addr"] + nsec["sh_size"]:
                continue
            if ent_ptr + 24 * count > esec["sh_addr"] + esec["sh_size"]:
                continue
            nd = nsec.data()
            nb = nd[names_ptr - nsec["sh_addr"]:names_ptr - nsec["sh_addr"] + 2 * count]
            if not all(0x20 <= b < 0x7f for b in nb):
                continue
            ed = esec.data()
            eo = ent_ptr - esec["sh_addr"]
            entries = []
            good = 0
            for k in range(count):
                fn, maxlen, minlen, extra = struct.unpack_from("<QIII", ed, eo + 24 * k)
                name = nb[2 * k:2 * k + 2].decode("ascii")
                entries.append({
                    "index": k,
                    "name": name,
                    "fn": fn,
                    "max_len": maxlen,
                    "min_len": minlen,
                    "extra": extra,
                })
                if fn == 0:
                    good += 1
                elif elf.in_exec(fn) and maxlen <= 0x100000 and minlen <= 0x100000:
                    good += 1
            if good < count * 0.8:
                continue
            key = (names_ptr, ent_ptr, count)
            if key in seen:
                continue
            seen.add(key)
            tables.append({
                "descriptor": base + off,
                "names_ptr": names_ptr,
                "entries_ptr": ent_ptr,
                "count": count,
                "names": nb.decode("ascii"),
                "entries": entries,
            })
    return tables



def analyze_gpnet(elf_path):
    elf = Elf(elf_path)
    tables = parse_command_tables(elf)
    bp = find_bp_cmd_table(elf, tables)
    shell_addrs = elf.find_string_addrs("/tmp/fuse_d/scheduled_capture.sh&")
    path_addrs = elf.find_string_addrs("/tmp/fuse_d/scheduled_capture.sh")
    rt_addrs = elf.find_string_addrs("RTsetSC")
    sc_entries = []
    for t in tables:
        for e in t["entries"]:
            if e["name"] != "SC" or not elf.in_exec(e["fn"]):
                continue
            start, end = elf.function_range(e["fn"])
            system_calls = collect_calls(elf, e["fn"])
            fopen_calls = [c for c in calls_in(elf, start, end)
                           if c["symbol"] in ("fopen", "fopen64", "__fopen64")]
            code = elf.section_bytes(e["fn"], end - e["fn"])
            sc_entries.append({
                "descriptor": t["descriptor"],
                "table": t["entries_ptr"],
                "index": e["index"],
                "fn": e["fn"],
                "max_len": e["max_len"],
                "min_len": e["min_len"],
                "function_range": [start, end],
                "handler_code_sha256": hashlib.sha256(code).hexdigest() if code else None,
                "is_bp_cmd": bool(bp and bp.get("table") == t["entries_ptr"]),
                "system_calls": system_calls,
                "fopen_calls": fopen_calls,
                "references_rt_name": any(start <= a < end for a in rt_addrs),
            })
    # fallback: the strings may be present but the table parse may differ
    strings = {
        "shell_cmd": shell_addrs,
        "fopen_path": path_addrs,
        "rt_name": rt_addrs,
    }
    return {
        "elf": elf_path,
        "sha256": sha256_file(elf_path),
        "build_id": elf.build_id(),
        "arch": "arm32" if elf.is_arm else "aarch64",
        "elf_type": elf.elf["e_type"],
        "size": os.path.getsize(elf_path),
        "tables_found": len(tables),
        "bp_cmd": bp,
        "sc_entries": sc_entries,
        "strings": strings,
    }


def analyze_gphttpserver(elf_path):
    elf = Elf(elf_path)
    routes = {
        "/gp/gpCamera": elf.find_string_addr("/gp/gpCamera"),
        "gpCameraHandler": elf.find_string_addr("gpCameraHandler"),
        "/to_gpnet": elf.find_string_addr("/to_gpnet"),
        "/gp/gpControl": elf.find_string_addr("/gp/gpControl"),
    }
    return {
        "elf": elf_path,
        "sha256": sha256_file(elf_path),
        "size": os.path.getsize(elf_path),
        "strings": {k: (hex(v) if v is not None else None) for k, v in routes.items()},
        "route_present": routes["/gp/gpCamera"] is not None,
        "handler_present": routes["gpCameraHandler"] is not None,
        "mailbox_present": routes["/to_gpnet"] is not None,
    }


# --------------------------------------------------------------------------
# Main

def scan(data_path, workdir, keep_dir=None):
    with open(data_path, "rb") as fh:
        m = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ)
        size = len(m)
        result = {
            "data_bin": os.path.abspath(data_path),
            "data_size": size,
            "data_sha256": sha256_file(data_path),
        }
        gpnet_hits = find_elf_for_hits(m, size, GPNET_NEEDLES)
        http_hits = find_elf_for_hits(m, size, HTTP_NEEDLES)
        result["gpnet_candidates"] = gpnet_hits
        result["gphttpserver_candidates"] = http_hits

        os.makedirs(workdir, exist_ok=True)
        gpnet_results = []
        for i, hit in enumerate(gpnet_hits):
            out = os.path.join(workdir, f"gpNet.{i}.elf")
            carve(m, hit["elf_offset"], hit["elf_size"], out)
            try:
                gpnet_results.append(analyze_gpnet(out))
            except Exception as exc:  # noqa: BLE001 - report, don't abort the batch
                gpnet_results.append({"elf": out, "error": repr(exc)})
            if keep_dir:
                os.makedirs(keep_dir, exist_ok=True)
                import shutil
                shutil.copy2(out, os.path.join(keep_dir, os.path.basename(out)))
        result["gpnet"] = gpnet_results

        http_results = []
        for i, hit in enumerate(http_hits):
            out = os.path.join(workdir, f"gpHttpServer.{i}.elf")
            carve(m, hit["elf_offset"], hit["elf_size"], out)
            try:
                http_results.append(analyze_gphttpserver(out))
            except Exception as exc:  # noqa: BLE001
                http_results.append({"elf": out, "error": repr(exc)})
            if keep_dir:
                os.makedirs(keep_dir, exist_ok=True)
                import shutil
                shutil.copy2(out, os.path.join(keep_dir, os.path.basename(out)))
        result["gphttpserver"] = http_results

        # verdict
        route = any(h.get("route_present") for h in http_results)
        vuln_entries, sc_entries, sys_entries = [], [], []
        for g in gpnet_results:
            if "error" in g:
                continue
            for e in g.get("sc_entries", []):
                sc_entries.append(e)
                args = [c for c in e.get("system_calls", []) if c.get("arg")]
                if args:
                    sys_entries.append(e)
                    if e.get("is_bp_cmd") or not g.get("bp_cmd"):
                        vuln_entries.append(e)
        reasons = []
        for e in vuln_entries:
            arg = [c["arg"] for c in e["system_calls"] if c.get("arg")][0]
            reasons.append(
                f"SC entry in BP table {hex(e['table'])} handler {hex(e['fn'])} "
                f"calls system({arg!r})"
            )
        if not gpnet_results:
            verdict = "GPNET_NOT_FOUND"
        elif vuln_entries and route:
            verdict = "VULNERABLE_STATIC"
        elif vuln_entries and not route:
            verdict = "SC_PRESENT_HTTP_ROUTE_MISSING"
        elif sc_entries and not sys_entries:
            verdict = "SC_PRESENT_NO_SYSTEM"
        elif not sc_entries:
            verdict = "NO_SC_ENTRY"
        else:
            verdict = "SC_PRESENT_OUTSIDE_BP_TABLE"
        result["gphttpserver_route"] = route
        result["verdict"] = verdict
        result["reasons"] = reasons
        m.close()
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("data_bin")
    ap.add_argument("--model")
    ap.add_argument("--version")
    ap.add_argument("--json")
    ap.add_argument("--keep", metavar="DIR", help="copy carved ELFs here")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory(prefix="fwscan.") as tmp:
        result = scan(args.data_bin, tmp, args.keep)
    result["model"] = args.model
    result["version"] = args.version
    text = json.dumps(result, indent=2)
    if args.json:
        with open(args.json, "w") as fh:
            fh.write(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
