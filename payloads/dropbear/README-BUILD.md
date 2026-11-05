# dropbearmulti (vendored)

Static **aarch64** Dropbear `2026.94` used as the camera's SSH server.

```text
size    592864 bytes
sha256  53130089c6e491a861bb011cff3658ef8f94d2843023099577f467973a4f5bff
file    ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped
```

## Why this build

The camera is aarch64 **glibc** (kernel 4.19.124), but a static **musl** binary
is used anyway: it has no dynamic dependencies at all, and it avoids the
statically-linked-glibc NSS caveat (`getpwnam`/`getspnam` wanting a matching
`libnss_files.so` at runtime). The camera's own `/etc/passwd` and `/etc/shadow`
are enough for dropbear to resolve `root`.

**Password authentication is compiled in** (`localoptions.h`:
`DROPBEAR_SVR_PASSWORD_AUTH 1`). It is what provides the `-B` blank-password
login used by default and, with a shadow override, a real password. Key-only is
still a runtime choice (`-s`). Two consequences:

- crypt() is needed, so a static **libxcrypt 4.4.38** is built from source and
  linked in (Alpine has no libxcrypt package);
- the binary is bigger, but has no runtime dependencies.

zlib remains disabled.

## Reproduce

```sh
./scripts/build-dropbear.sh          # musl, in an arm64 alpine container
./scripts/build-dropbear.sh --gnu    # static glibc cross build, no docker
```

Both tarballs are pinned by sha256:

```text
https://github.com/mkj/dropbear/archive/refs/tags/DROPBEAR_2026.94.tar.gz
sha256 827d3f6e510e7554ee18d5c6a00dfee1a6a555559495e65e2e8f8d41c79eed84

https://github.com/besser82/libxcrypt/releases/download/v4.4.38/libxcrypt-4.4.38.tar.xz
sha256 80304b9c306ea799327f01d9a7549bdb28317789182631f1b54f4511b4206dd6
```

The container build is:

```sh
apk add build-base linux-headers curl xz perl
./configure --disable-shared --enable-static --prefix=/usr/local   # libxcrypt
make && make install

./configure --enable-static --disable-zlib --disable-lastlog \
    --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
    CPPFLAGS=-I/usr/local/include LDFLAGS=-L/usr/local/lib LIBS=-lcrypt
make PROGRAMS="dropbear dropbearkey" MULTI=1 STATIC=1
strip dropbearmulti
```

It verifies the result with `qemu-aarch64`: `dropbear -V` must print
`Dropbear v2026.94`, and `dropbear -h` must list `-B` (otherwise the build
silently lost password support).

Bit-for-bit reproducibility is not claimed: the binary embeds a GNU build-id
and libxcrypt pulls in its own objects, so a rebuild will not necessarily match
the sha256 above. The script guarantees a working, statically linked aarch64
build of the same versions and options.

## Runtime

`dropbearmulti` is a multicall binary, invoked as:

```sh
dropbearmulti dropbear    ...
dropbearmulti dropbearkey ...
```

The camera's SD card is a FUSE mount, so the binary is always copied to a local
filesystem (`/dev/dropbear`) before it is executed — see `stage.sh` in this
directory. The host key is generated once per card by `scripts/install-card.sh`
(with `dropbearkey` under `qemu-aarch64`) and stored as `dropbear_hostkey` on
the card, so the camera's SSH identity stays stable across boots.

## License

Dropbear is MIT; the full text is in [`LICENSE`](LICENSE). libxcrypt is
LGPL-2.1-or-later, statically linked.
