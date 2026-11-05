# GoPro `SC` root — root shell over USB or Wi-Fi

A root shell on GoPro HERO8..HERO13 / MAX2 through the camera's own `SC`
command: `GET /gp/gpCamera?cmd=SC&p=%02` runs `/tmp/fuse_d/scheduled_capture.sh`
from the SD card as root. No flashing, no memory corruption. Verified on a
HERO11 Black (`H22.01.02.20.00`); see [docs/how-it-works.md](docs/how-it-works.md).

> **Use this only on a camera you own.** See [Legal](#legal).

## Requirements

- GoPro HERO8..HERO13 / MAX2, an SD card, and a card reader.
- Linux host with `curl`, `python3`, `openssl`, `qemu-aarch64` (`qemu-user`).
- Bluetooth for the Wi-Fi shortcut; USB works without it.

## 1. Prepare the card (once)

```bash
./scripts/install-card.sh /media/$USER/<CARD>
```

Writes a static aarch64 dropbear and its bootstrap to the card root. The default
is **no password**: `ssh root@<camera>` logs straight in. Other modes:

| command | login |
|---|---|
| `install-card.sh <card>` | no password (`ssh root@<cam>`) |
| `install-card.sh <card> --password` | prompts for a password |
| `install-card.sh <card> --pubkey ~/.ssh/id_ed25519.pub` | key, or no password |
| `install-card.sh <card> --key-only --pubkey ~/.ssh/id_ed25519.pub` | key only |

The password is stored as a hash (`root_hash`), never in clear. Put the card
back in the camera; it does not need to come out again. Blank auth means anyone
on the camera's network gets root — use `--password` or `--key-only` if that
matters.

## 2. Arm it

### USB

Camera on, cable attached: `./scripts/arm.sh`

### Wi-Fi

The camera's Wi-Fi is off after every boot. `wifi-on.sh` enables it over
Bluetooth LE and joins the AP, no Quik app:

```bash
./scripts/wifi-on.sh --pair   # once: camera menu -> Preferences -> Connections
                              # -> Wireless Connections (pairing mode)
./scripts/wifi-on.sh          # later: enable the AP and join it
./scripts/arm.sh              # trigger the exploit
```

After the one-time pairing, no camera interaction is needed;
`./scripts/wifi-on.sh --arm` joins and triggers in one go. The camera keeps its
band: if it is on 5 GHz and this host's adapter is 2.4-only, the script switches
it to 2.4 GHz (`--band 2.4` forces it). No Bluetooth? Enable wireless from the
same menu, join by hand, then `./scripts/arm.sh --wifi`.

## 3. Log in

```bash
ssh root@10.5.5.9        # Wi-Fi
ssh root@172.23.148.51   # USB
```

Key mode: `ssh -i ~/.ssh/id_ed25519 root@...`. The host key is stable per card.

## After a camera power cycle

The rootfs is read-only (`/dev/root / ext4 ro`): dropbear and its firewall rule
are runtime state, and nothing auto-starts. Re-arm:

```bash
./scripts/wifi-on.sh && ./scripts/arm.sh   # Wi-Fi
./scripts/arm.sh                           # USB
```

## Troubleshooting

| symptom | meaning |
|---|---|
| `error: SC returned 500` | `gpNet` busy or wedged; wait 10 s, retry |
| `nothing listening on <ip>:22` | installer failed; read `/tmp/fuse_d/DROPBEAR_LOG.txt` |
| `Permission denied (publickey)` | key missing from the card, or not armed |
| `wifi-on.sh`: no BLE camera | camera asleep, on USB (BLE off), or not paired |
| camera AP not visible | wireless is off, or the camera is on 5 GHz |

More detail: [docs/dropbear.md](docs/dropbear.md).

## Legal

A logic flaw in firmware you own, published for owners and defensive research.
Run it only on hardware you own or are authorized to test. Do not use it on a
device or data that is not yours; circumventing device protections can be
illegal even on hardware you own. Provided as-is, no warranty.

If you are GoPro: thanks for the vulnerability and please keep publishing
firmwares like this, it is really important to us to root the devices we own.
TAKE BACK THE HARDWARE!!!
