# Root shell over SSH: dropbear from the SD card

The `SC` command gives root code execution ([`how-it-works.md`](how-it-works.md)).
This turns that primitive into an interactive root shell on `0.0.0.0:22`,
reachable over the camera's USB gadget at `172.23.148.51` or its Wi-Fi AP at
`10.5.5.9` once the host has joined it.

**Verified on hardware:** `ssh root@172.23.148.51 id` → `uid=0(root)`,
uname `Linux gopro 4.19.124 … aarch64 GNU/Linux`.

```
card: scheduled_capture.sh  (bootstrap)
  |
  |  GET /gp/gpCamera?cmd=SC&p=%02
  v
gpNet -> system("/tmp/fuse_d/scheduled_capture.sh&")     (root)
  |
  +-- wget http://<host>:8000/stage.sh   -> /tmp/stage.sh   (+ card fallback)
  |     <host> is discovered: USB peer, or an ARP neighbour on the camera AP
  +-- run stage.sh:  /dev/dropbear/{dropbearmulti,authorized_keys,hostkey}
  |                  auth per dropbear.conf: -B | (shadow) | -s
  |                  iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
  v
ssh root@10.5.5.9
```

Keeping the logic in `stage.sh` on the build host matters: the card payload is
only a bootstrap, so the installer can be changed and re-triggered without
pulling the card ([`../scripts/arm.sh`](../scripts/arm.sh)).

## 1. Why a static musl dropbear

The camera is aarch64 glibc, but the vendored binary is a static **musl** build
of Dropbear 2026.94: no dynamic loader, no libc coupling, and no
statically-linked-glibc NSS caveat. zlib is compiled out.

Password authentication is now compiled **in** (`DROPBEAR_SVR_PASSWORD_AUTH 1`).
It is what provides `-B` (blank-password login) and the optional real password.
That pulls in `crypt()`, so a static libxcrypt is built from a pinned tarball
and linked into the binary. Key-only remains a runtime choice (`-s`).

Build and checksums: [`../payloads/dropbear/README-BUILD.md`](../payloads/dropbear/README-BUILD.md).

## 2. The firewall

Inbound is `DROP` by default, with per-interface chains:

```
-P INPUT DROP
-A INPUT -i ap0  -g SMARTY      # tcp 80/8080/8081, udp 8554/67/68
-A INPUT -i usb0 -g SMARTY
-A INPUT -j REJECT
```

`gpNet` itself opens ports the same way — its TFTP path carries the literal
commands `/usr/sbin/iptables -I INPUT 1 … --dport 69 -j ACCEPT` and
`-D INPUT 1`. So `/usr/sbin/iptables` exists and inserting at rule 1 is the
sanctioned pattern. The installer does that for tcp/22, guarded by
`iptables -C` so re-runs do not stack rules. The rule is interface-agnostic,
so it covers `ap0` and `usb0` alike.

**Caveat:** gpNet's cleanup is a *positional* `-D INPUT 1`; if its TFTP path
runs after us it could delete our rule instead of its own. Re-arm to restore it.

## 3. Choosing a state directory — three traps

The SD card is a **FUSE** mount (`ipcufs`): shell scripts run from it (because
`/bin/sh` *reads* the file), but a binary should not be executed from it. The
installer copies `dropbearmulti` to a local filesystem and proves it runs
(`dropbear -V`) before starting it.

Where that copy lives is the fiddly part, because dropbear's
`checkpubkeyperms()` walks **every ancestor** of `authorized_keys` and refuses
any that is group- or world-writable:

1. **`/tmp` and `/run` are bare tmpfs**, which the kernel defaults to mode
   **1777**. `-D /run/dropbear` fails authentication with no useful error.
   1777 shows as `drwxrwxrwt` — the world-write slot reads `t`, not `w`, so a
   naive permission check misses it.
2. **The rootfs is read-only**: `/dev/root / ext4 ro`, and `/usr/local/gopro`
   and `/home/root` are read-only too. They cannot hold state.
3. **gpNet runs the payload with an unrestricted umask**, so a plain
   `mkdir /run/dropbear` creates **0777** — dropbear then refuses the key
   because *our own directory* is world-writable. The installer sets
   `umask 022` and `chmod 700` before validating.

`/dev` is devtmpfs mounted with an explicit `mode=755`, and it is writable, so
`/dev/dropbear` is the state directory (700, root). It is runtime state and
does not survive a reboot.

## 4. Auth modes

`scripts/install-card.sh` writes `dropbear.conf` (`AUTH=blank|password|keyonly`)
and, for password mode, `root_hash` — a SHA-512 crypt hash, never the password.

| `AUTH=` | dropbear flags | meaning |
|---|---|---|
| `blank` (default) | `-B` | login with no password: dropbear accepts SSH "none" auth because `/etc/shadow` has `root::…` |
| `password` | *(none)* | password auth against the overridden shadow |
| `keyonly` | `-s` | public key only |

Keys in `authorized_keys` are always honoured; `keyonly` requires them.

Password mode needs a hash the camera's read-only `/etc/shadow` cannot hold.
`stage.sh` copies `/etc/shadow` to `/tmp`, replaces root's hash from
`root_hash`, and `mount --bind`s the result over `/etc/shadow` before starting
dropbear. It fails closed: if the mount fails, no listener is started. A stale
overlay from a previous run is unmounted first, so switching back to `blank`
works without a reboot.

## 5. Host identity

`scripts/install-card.sh` generates `dropbear_hostkey` once per card
(`dropbearkey -t ed25519` under `qemu-aarch64`) and the installer copies it to
the state directory, so the camera's SSH identity is stable across re-arms.

## 6. Persistence: there is none, by design

Nothing can auto-start dropbear at boot:

- the rootfs is read-only, so there is no init hook to install
  (`/etc/init.d`, `/etc/rcS.d` are on the `ro` image);
- `/dev/dropbear` is devtmpfs and the iptables rule is runtime state;
- the card's `autoexec.sh` runner does not execute on retail firmware.

Re-arm after every power cycle:

```sh
./scripts/arm.sh          # auto: USB if the gadget is attached, else the camera AP
./scripts/arm.sh --wifi   # force 10.5.5.9
./scripts/arm.sh --usb    # force 172.23.148.51
```

`arm.sh` serves `payloads/dropbear/` over HTTP for the duration of the trigger,
so the camera always runs the current `stage.sh` from this checkout. The card's
own copy of `stage.sh` is only a fallback for when the host is not serving.

The transport changes one thing: the address the camera calls back to. Over USB
it is the fixed gadget peer `172.23.148.52`; over the camera AP this host is a
DHCP client, so the bootstrap reads the address back from the camera's own ARP
table (the machine that just sent the trigger is necessarily there).

## 7. Wi-Fi over BLE

The camera's AP is off after every boot. `scripts/wifi-on.sh` enables it over
Bluetooth LE and joins it, with no Quik app:

- scans for the GoPro BLE service (`0xFEA6`), connects and bonds (`--pair`)
- writes `03 17 01 01` to the command characteristic (Set AP Control, mode 1)
- reads the AP SSID/password from their characteristics
- `nmcli device wifi connect`s to it, then waits for `10.5.5.9:80`

Pairing is once per host: the camera must be in pairing mode
(Preferences → Connections → Wireless Connections). After that the host is
bonded and no camera interaction is needed. BLE is disabled while the camera is
on USB, so unplug first. Without a Bluetooth adapter, enable wireless on the
camera by hand.

The AP's **wireless band** matters: a 5 GHz AP is invisible to 2.4 GHz-only
adapters. The script reads status 76 (0 = 2.4 GHz, 1 = 5 GHz) and status 69
(AP mode). If the SSID does not show up in a scan and the camera is on 5 GHz, it
writes setting 178 (0 = 2.4 GHz), bounces the AP (Set AP Control mode 2) and
retries. `--band 2.4` / `--band 5` force it up front; `--band keep` is the
default.

## 8. Building and servicing the card

```sh
./scripts/install-card.sh /media/$USER/<CARD> [--pubkey KEY] [--password] [--key-only]
```

That writes `scheduled_capture.sh` (bootstrap), `stage.sh`, `dropbearmulti`,
`dropbear.conf`, and optionally `authorized_keys`, `root_hash`, plus
`dropbear_hostkey`. Only the bootstrap and the binary/keys are strictly needed
at runtime; `stage.sh` is the offline fallback.

To refresh the code without taking the card out, use an already-armed shell:

```sh
./scripts/arm.sh                       # USB or Wi-Fi
./scripts/push-card.sh 172.23.148.51   # or 10.5.5.9
```

It streams the current `scheduled_capture.sh`, `stage.sh`, `dropbearmulti` and
`authorized_keys` into `/tmp/fuse_d`, checks the sha256 read back, and leaves
`dropbear.conf`, `root_hash` and `dropbear_hostkey` alone.

## 9. Diagnosing a failed install

The payload cannot assume a working shell, so it reports over the one channel
proven to work — the same HTTP fetch it uses to get `stage.sh`:

- every step does a `wget` of `/beacon/<step>`; the access log of the host HTTP
  server (`/tmp/gopro-stage-http.log`) is the progress trace;
- on exit the whole install log is replayed one line per request (`/beacon/LOG:…`);
- the card also gets `/tmp/fuse_d/DROPBEAR_LOG.txt` and
  `DCIM/100GOPRO/DROPBEAR_LOG.TXT`.

`arm.sh` reports whether `/stage.sh` was fetched from this checkout; if not, the
camera ran the card's copy of `stage.sh` instead.

Two BusyBox 1.27 quirks that bit during development: `head -200` is invalid
(use `head -n 200`), and `nc` has no `-w` option (`nc [-l] [-p PORT] [IPADDR
PORT]`).

## 10. Uninstall

```sh
ssh root@<cam> 'killall -9 dropbearmulti; \
  /usr/sbin/iptables -D INPUT -p tcp --dport 22 -j ACCEPT; \
  rm -rf /dev/dropbear'
```

Then remove `scheduled_capture.sh`, `stage.sh`, `dropbearmulti`,
`dropbear.conf`, `authorized_keys`, `root_hash`, `dropbear_hostkey`,
`DROPBEAR_LOG.txt` and `DCIM/100GOPRO/DROPBEAR_LOG.TXT` from the card. A power
cycle clears any remaining runtime state.
