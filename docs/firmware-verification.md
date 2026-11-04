# Firmware verification — is the `SC` root HERO11-only?

**Short answer: no.** The same `SC` → `RTsetSC` → `system()` primitive is
present in the official firmware of every GoPro we could unpack from the
**HERO8 Black through the HERO13 Black / MAX2** generation. Only the HERO11 was
executed on hardware; the other models were verified statically from the
official GoPro update packages.

Two current products are different:

- **MISSION 1 / MISSION 1 PRO / MISSION 1 PRO ILS (04.01.00)** — gpNet still
  has the `SC` command and the `scheduled_capture.sh` string, but the handler
  checks a `STS_CSI_PRODUCTION_BUILD` status bit and logs
  `RTsetSC - ignoring sched cap test on production build`. That is a deliberate
  gate around the test hook.
- **HERO (2024) and LIT HERO** — these use an Ambarella firmware layout. The
  readable rootfs contains `AmbaRTSPServer` and Ambarella userspace, not gpNet.
  No `SC` primitive was found. Encrypted sections, if any, were not unpacked,
  so these are **unverified**, not proven safe.

## Result table

`BP SC` is the index of the `SC` entry in the `CAT_CGI_BP_CMD` command table;
the handler chain is the path from that entry to the `system()` call. `gpHttp`
means the `/gp/gpCamera` route, the `gpCameraHandler` symbol and the
`/to_gpnet` mailbox were all found in gpHttpServer.

| Model | Official firmware | Arch | gpNet build | BP `SC` | Handler chain | `system()` argument | gpHttp | Verdict |
|---|---|---|---|---|---|---|---|---|
| HERO8 Black | 02.51.00 (2022-03-24) | ARM32 | `b7b2536f17ca` | 75 / 78 | `0x3cb00 → 0x3c9d4` | `/tmp/fuse_d/scheduled_capture.sh&` | yes | **rootable (static)** |
| HERO9 Black | 01.72.00 (2022-06-01) | ARM32 | `08e4543318ca` | 75 / 78 | `0x3a004 → 0x39ed8` | `/tmp/fuse_d/scheduled_capture.sh&` | yes | **rootable (static)** |
| HERO10 Black | 01.62.00 (2024-05-23) | AArch64 | `fe23f3bc6931` | 63 / 66 | `0x41b940` | `/tmp/fuse_d/scheduled_capture.sh&` | yes | **rootable (static)** |
| HERO11 Black | 02.32.00 (2025-01-13) | AArch64 | `c431be953cf5` | 63 / 66 | `0x41d888` | `/tmp/fuse_d/scheduled_capture.sh&` | yes | **rootable (static)** |
| HERO11 Black Mini | 02.50.00 (2024-05-02) | AArch64 | `4951edf91517` | 63 / 66 | `0x41d888` | `/tmp/fuse_d/scheduled_capture.sh&` | yes | **rootable (static)** |
| HERO12 Black | 02.44.00 (2026-10-20) | AArch64 PIE | `d8162c642a61` | 61 / 64 | `0x2c1b0 → 0x2c0f0` | `/tmp/fuse_d/scheduled_capture.sh&` | yes | **rootable (static)** |
| HERO13 Black | 02.14.00 (2026-10-20) | AArch64 PIE | `4a83feedb2dc` | 62 / 65 | `0x2ced0 → 0x2ce10` | `/tmp/fuse_d/scheduled_capture.sh&` | yes | **rootable (static)** |
| MAX | 02.06.00 (2026-02-12) | ARM32 | `33796e0b24ba` | 75 / 78 | `0x3cb00 → 0x3c9d4` | `/tmp/fuse_d/scheduled_capture.sh&` | yes | **rootable (static)** |
| MAX2 | 01.34.00 (2026-10-20) | AArch64 PIE | `96754dd4a70b` | 62 / 65 | `0x2d020 → 0x2cf60` | `/tmp/fuse_d/scheduled_capture.sh&` | yes | **rootable (static)** |
| MISSION 1 / PRO / PRO ILS | 04.01.00 (2026-10-13) | AArch64 | `133a7d848a91` | 62 / 65 | `0x23c30` | — (production gate) | yes | **gated** |
| HERO (2024) | 02.30.00 (2025-10-29) | Ambarella | — | — | — | — | ? | **not found** |
| LIT HERO | 02.10.00 (2026-04-14) | Ambarella | — | — | — | — | ? | **not found** |

Full per-model hashes, URLs and ELF metadata are in
[`firmware-verification.json`](firmware-verification.json). The gpNet and
gpHttpServer binaries extracted from the 2026 packages are the exact files
from the official GoPro CDN (SHA-1 verified against the catalog).

## Two code shapes, one primitive

Older and middle-generation builds put the whole thing in one function:

```
RTsetSC(TLV):
  p = tlv_find(TLV, 0x42)
  switch (p[0]):
    0: clear bit 30
    1: if fopen("/tmp/fuse_d/scheduled_capture.sh") { set bit 30 }
    2: fopen(path); fclose(); system("/tmp/fuse_d/scheduled_capture.sh&")
```

HERO10, HERO11 and HERO11 Black Mini are in this shape. The `SC` handler calls
`fopen64` and `system` directly; the system call is unconditional after a
successful `fopen` of the card file.

Newer builds moved the body into `start_sched_cap()` and made `RTsetSC` call it:

```
RTsetSC(TLV):
  ...
  if p[0] == 2: start_sched_cap();
  else if p[0] == 1: ...

start_sched_cap():
  if fopen("/tmp/fuse_d/scheduled_capture.sh", "r"):
      fclose();
      system("/tmp/fuse_d/scheduled_capture.sh&");
```

HERO12, HERO13, MAX2 and the ARM32 HERO8/HERO9/MAX builds are in this shape.
The reachable path is still `SC` payload `0x02` → `system()`; the refactor only
moves the call one frame down.

The ARM32 and AArch64 builds use different command-table layouts (32-bit
descriptors, 20-byte entries, `movw`/`movt` address materialisation versus
64-bit descriptors, 24-byte entries, `adrp`/`add`), but the same 2-char `SC`
code, the same `CAT_CGI_BP_CMD` dispatch and the same script path.

## MISSION 1: the command is still there, but gated

The MISSION 1 family runs the same gpNet binary (SHA-256
`ea8b3201…`) and still exposes `SC` at index 62 of `CAT_CGI_BP_CMD`. The
handler at `0x23c30` starts with:

```
ldr  w0, [x21, #8]
tbnz w0, #19, 0x23d08       ; STS_CSI_PRODUCTION_BUILD
...
0x23d08:
  log("RTsetSC - ignoring sched cap test on production build")
  return 0
```

If bit 19 is set, the payload is never inspected and no `fopen`/`system` call
is reachable. The normal scheduled-capture path (`start_sched_cap` at
`0x176d0`) still contains the `fopen` + `system()` pair at `0x17728` /
`0x1777c`, but it is behind the feature bit that the `SC` test hook used to
bypass.

The status bit is set by a CSI-status command (`orr w9, w0, #0x80000; str w9,
[x8, #8]`). Static analysis cannot prove whether a retail unit leaves it clear
or set at boot; the code is clearly written as a production-build guard. Treat
MISSION 1 as **mitigated** unless a hardware test shows the bit clear.

## HERO (2024) and LIT HERO: different platform

`UPDATE.zip` for these two contains `FW.bin` rather than `DATA.bin`. `FW.bin`
is an Ambarella image. Extracting the readable squashfs at the `hsqs` offset
gives an Ambarella rootfs (`libambasocksvc`, `AmbaRTSPServer`,
`ambernation.sh`) with no `gpNet`, no `gpCommand.c`, no `/gp/gpCamera` and no
`scheduled_capture.sh`. The GoPro app, if it is present in an encrypted
section, was not readable. These models are **not verified** either way; the
SC primitive is simply absent from everything we could read.

## How this was verified

1. The official catalog is a public JSON endpoint, no authentication:

   ```bash
   curl -s https://api.gopro.com/firmware/v2/catalog > catalog.json
   ```

   It returns the current model list with `version`, `url`, `sha1` and
   `release_date`. The per-model endpoint is
   `https://api.gopro.com/firmware/v2/catalog?model=<id>`.

2. Download each `UPDATE.zip`, check the catalog SHA-1, extract `DATA.bin`.

3. Locate the gpNet ELF inside the Milbeaut container using `gpCommand.c` /
   `CAT_CGI_BP_CMD` / `RTsetSC` as anchors. The container is not encrypted;
   the ELF is present as a normal AArch64/ARM executable.

4. Parse the `s_cats` dispatch, the command-set descriptor
   `{names, entries, entries, count}`, and the `SC` entry.

5. Disassemble the handler (and, for the newer shape, follow the local call
   into `start_sched_cap`), resolve the PLT `system` stub and its string
   argument.

6. Repeat for gpHttpServer: check `/gp/gpCamera`, `gpCameraHandler` and
   `/to_gpnet`.

7. On the one available HERO11, the HTTP trigger was executed and the payload
   marker showed `uid=0(root)` with `ppid=/sbin/finit` (see
   [`how-it-works.md`](how-it-works.md)).

The scanner is [`../scripts/fw-scan.py`](../scripts/fw-scan.py). It supports
AArch64 ET_EXEC, AArch64 PIE (ET_DYN) and ARM32, and both the direct and
`start_sched_cap` handler shapes.

## Reproduce

```bash
python3 -m venv work/venv
work/venv/bin/pip install -r scripts/requirements.txt

# fetch, SHA-1-check, extract and scan one model (HERO13, catalog id 65)
PY=work/venv/bin/python ./scripts/fetch-verify.sh 65

# or the nine models that are statically vulnerable
PY=work/venv/bin/python ./scripts/fetch-verify.sh
```

`scripts/fetch-verify.sh` reads the public catalog, downloads the official
`UPDATE.zip`, checks it against the catalog SHA-1, extracts `DATA.bin`, and
runs `scripts/fw-scan.py`. It writes `work/results/<id>.json` per model;
`docs/firmware-verification.json` is the committed summary with URLs, SHA-1s,
DATA.bin SHA-256s and gpNet build-ids.

## Limits

- **Static evidence, not hardware proof, for every model except the HERO11.**
  The code, the command table entry and the unauthenticated proxy are present
  in the official image; whether a particular unit's gpNet is running, has the
  SD card mounted at `/tmp/fuse_d`, and is reachable over Wi-Fi/USB is the same
  operational question as on the HERO11.
- The transport was dynamically verified on HERO11 `H22.01.02.20.00`. The
  HERO11 `02.32.00` image contains the identical handler (`0x41d888` →
  `system` at `0x41d9a0`) and route.
- Firmware images are signed; this analysis did not modify or reflash anything.
- The `SC` entry is a QA/test hook. GoPro has now added a production gate on
  the MISSION 1 platform; that is the right fix and is documented above rather
  than bypassed.

## Legal

Same terms as the main README: use this only on hardware you own. The firmware
packages are GoPro's; they were downloaded from GoPro's public CDN for
interoperability and security research and are not redistributed here.
