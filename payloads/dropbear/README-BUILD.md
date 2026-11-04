# dropbearmulti (vendored)

Static **aarch64** Dropbear `2026.94` used as the camera's SSH server.

```text
size    396256 bytes
sha256  4bdb4d52d1660e41ad755ebf89359ff173845f96fa0e426aca5b6770ca1c7200
file    ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped
```

## Why this build

The camera is aarch64 **glibc** (kernel 4.19.124), but a static **musl** binary
is used anyway: it has no dynamic dependencies at all, and it avoids the
statically-linked-glibc NSS caveat (`getpwnam` wanting the matching
`libnss_files.so` at runtime). The camera's own `/etc/passwd` is enough for
dropbear to resolve `root`.

Two features are deliberately removed at build time:

- **password authentication** — key-only by design. This also drops the
  `crypt()` dependency, which is what makes a dependency-free static build
  possible (`localoptions.h`: `DROPBEAR_SVR_PASSWORD_AUTH 0`).
- **zlib** — no compression, nothing extra to link.

## Reproduce

```sh
./scripts/build-dropbear.sh          # musl, in an arm64 alpine container
./scripts/build-dropbear.sh --gnu    # static glibc cross build, no docker
```

The script pins the source tarball by sha256:

```text
https://github.com/mkj/dropbear/archive/refs/tags/DROPBEAR_2026.94.tar.gz
sha256 827d3f6e510e7554ee18d5c6a00dfee1a6a555559495e65e2e8f8d41c79eed84
```

and the container build is:

```sh
apk add --no-cache build-base
./configure --enable-static --disable-zlib --disable-lastlog \
    --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx
make PROGRAMS="dropbear dropbearkey" MULTI=1 STATIC=1
strip dropbearmulti
```

It verifies the result with `qemu-aarch64` (`dropbear -V` must print
`Dropbear v2026.94`) before installing it here.

Bit-for-bit reproducibility is not claimed: the binary embeds a GNU build-id,
so a rebuild will not necessarily match the sha256 above. The script guarantees
a working, statically linked aarch64 build of the same version and options.

## Runtime

`dropbearmulti` is a multicall binary, invoked as:

```sh
dropbearmulti dropbear    ...
dropbearmulti dropbearkey ...
```

The camera's SD card is a FUSE mount, so the binary is always copied to a local
filesystem (`/usr/local/gopro/dropbear` or `/run/dropbear`) before it is
executed — see `scheduled_capture.sh` in this directory.

The host key is generated once per card by `scripts/install-card.sh` (with
`dropbearkey` under `qemu-aarch64`) and stored as `dropbear_hostkey` on the
card, so the camera's SSH identity stays stable across boots.

## License

Dropbear is MIT; the full text is in [`LICENSE`](LICENSE).
