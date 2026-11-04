# How the `SC` root works

Verified on a HERO11 Black running `H22.01.02.20.00` (retail). Addresses below
are from the retail `gpNet` binary: AArch64, non-PIE, load base `0x400000`.

## 1. The transport: an unauthenticated HTTP proxy

`gpHttpServer` (port 80) registers a legacy route `/gp/gpCamera`. The handler
(`gpCameraHandler`, `0x4c4808`) parses three query parameters:

```
cmd  max 8 bytes
p    max 32 bytes, URL-decoded
t    max 32 bytes (unused)
```

It builds a Socionext TLV with message type **2** (`CAT_CGI_BP_CMD`):

| tag | contents |
|---|---|
| `0x41` | 2-byte command code |
| `0x42` | `p` payload |
| `0x44` | `"gp<pid>"` client id |
| `0x43` | 10-byte constant |
| `0xee` | terminator |

and sends it to gpNet's `/to_gpnet` message queue. It then waits up to 10 s for
a reply and writes the reply's `0x45` status byte as the HTTP body. That is why
success is `HTTP 200` with a **single `0x00`** byte, and a missing reply is
`500 Server error: RX timeout.`.

## 2. The command table: the wire code is `SC`

gpNet dispatches incoming TLVs by type. Type 2 selects the BP command table:

```
s_cats @ 0x454820, 32-byte entries
  [2] = CAT_CGI_BP_CMD @ 0x454860 -> descriptor @ 0x48aa80
descriptor: names = 0x4588a0, entries = 0x458258, count = 66
entry:      24 bytes, { fn u64, max_len u32, min_len u32, ... }
names:      66 concatenated 2-char codes, 132 bytes at 0x4588a0
```

Entry 63:

```
63  "SC"  fn=0x41d888  max=0x01  min=0x01
```

`"SC"` is at names offset 126 (even — the dispatcher only accepts even offsets,
because the names are a flat array of 2-char codes).

The handler's own log name is `RTsetSC` (`0x455cb8`), which is *not* the wire
code; this is why searching for `RTsetSC` in requests fails. The string
`RTsetSC - testing sched cap` is in the same block.

## 3. The handler `RTsetSC` @ `0x41d888`

It reads TLV tags `0x44` (client id) and `0x42` (payload), then switches on
payload byte 0:

| `p[0]` | log name | action |
|---|---|---|
| `0x00` | `clr_status` | clears bit 30 of `g_csi_feature+0x6c4` (`0x48e6c4`) if set |
| `0x01` | "Allow Scheduled Capture" | if `/tmp/fuse_d/scheduled_capture.sh` exists, sets bit 30 |
| `0x02` | "Start Scheduled Capture" | `fopen` the script, `fclose`, then `system("/tmp/fuse_d/scheduled_capture.sh&")` |

Relevant strings: path `0x45a5e0`, shell command `0x45a678`, "starting sched
capture" `0x45a630`, handler source
`/src/smarty-camera-support/gpNet/src/gpCommand.c:5767`.

The `0x02` branch does **not** check bit 30. It does not care how the camera was
armed, whether the app is connected, or what the scheduled-capture state is.

`/tmp/fuse_d` is the mounted SD card (`mount -t ipcufs ...`), so the file is
entirely user-controlled.

## 4. The surrounding feature

`SC` is part of a family of internal scheduled-capture commands, all exposed as
BP commands:

| code | handler string |
|---|---|
| `W4` | `RTsetW4 - set time to wait (sched cap)` |
| `S4` | `RTsetS4 - set time to suspend sched cap` |
| `B4` | `RTsetB4 - wait for not busy (sched cap)` |
| `SC` | `RTsetSC - testing sched cap` |

`gpNet` also has a state machine for the feature (`SC_SCHEDULED`, `SC_OFF`,
`SC_CANCELLED`, `SC_TRIGGERED`, `SC_EXPIRED`, `SC_TIME_CHANGED`, `SC_WOKEN`),
globals `g_schedCap_wake_type`, `g_schedCap_target_time`,
`g_schedCap_early_offset`, and functions `get_csi_scheduled_capture_target`,
`doCSIschedCapTGT`, `start_sched_cap`.

The normal path comes from `parse_csi_state`: when the camera wakes from a
scheduled capture, it checks bit 30 of `g_csi_feature+0x6c4` and only then calls
`start_sched_cap` (`0x430848`). That function duplicates the same
`fopen` + `system()` logic. The `0x02` branch of `RTsetSC` is the unguarded
"testing" shortcut around that gate.

This looks like a factory/QA hook: inject a script from the card, trigger the
scheduled-capture path, and have the camera run test automation as root with no
app or reflash. It executes a file from removable storage and is reachable from
an unauthenticated HTTP endpoint, so on a production device it is a root
backdoor.

## 5. Why the earlier attempts failed

- `cmd=RTsetSC` — wrong. The lookup only matches the 2-char code `SC`.
- `cmd=S4&p=%02` — `S4` is entry 62, a different command with
  `min_len=0x0b`/`max_len=0x28`. A 1-byte payload takes the length-error path,
  which temporarily wedges gpNet (10 s RX timeouts). It is not a dead end
  forever; it recovers.
- `cmd=SC&p=%00` — harmless, but on a busy/recovering gpNet it can also
  time out. `%02` is the one that runs the script.
- ASCII `p=2` is wrong: `p` is URL-decoded, so `%02` is the raw byte `0x02`;
  ASCII `2` is `0x32` and hits the error path.

## 6. Why it is root

`gpNet` runs as root (its parent is `/sbin/finit`, PID 1). `system()` inherits
the uid, and `/bin/sh -c "/tmp/fuse_d/scheduled_capture.sh&"` runs the script as
root. With `&`, the shell exits immediately and the script is reparented to
PID 1, which is what the marker's `ppid: /sbin/finit` shows.

## 7. Disclosure

This is a design flaw (unauthorized file execution from removable media), not a
memory-safety bug. It is reachable only from the camera's own AP or USB gadget,
so it requires physical/network control of the device, but it needs no
authentication beyond the AP password. If you are the vendor or a researcher,
report it before publishing beyond a private group.
