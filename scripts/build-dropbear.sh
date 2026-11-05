#!/usr/bin/env bash
# Build the static aarch64 dropbearmulti shipped in payloads/dropbear/.
#
#   ./scripts/build-dropbear.sh            # musl static, in an arm64 container
#   ./scripts/build-dropbear.sh --gnu      # static glibc cross build (no docker)
#
# Password authentication is compiled in. It is what enables `-B` (blank
# password login, the default card mode) and, with a shadow override, a real
# password. That pulls in crypt(), so a static libxcrypt is built from a pinned
# tarball and linked in; zlib stays disabled. The result is verified under
# qemu-aarch64 before it is written into the repository.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
OUT="$ROOT/payloads/dropbear/dropbearmulti"

TAG="DROPBEAR_2026.94"
SRC="dropbear-2026.94"
URL="https://github.com/mkj/dropbear/archive/refs/tags/${TAG}.tar.gz"
SHA256="827d3f6e510e7554ee18d5c6a00dfee1a6a555559495e65e2e8f8d41c79eed84"

# crypt() for password auth. Alpine has no libxcrypt package, so it is built
# static from source inside the container.
XVER="4.4.38"
XURL="https://github.com/besser82/libxcrypt/releases/download/v${XVER}/libxcrypt-${XVER}.tar.xz"
XSHA="80304b9c306ea799327f01d9a7549bdb28317789182631f1b54f4511b4206dd6"

MODE="musl"
[ "${1:-}" = "--gnu" ] && MODE="gnu"

# Docker runs as root and therefore owns everything it creates under $WORK;
# it also does its own cleanup so the unprivileged host never has to.
WORK="${WORK:-/tmp/dropbear-build}"
mkdir -p "$WORK"

# ---- source ----------------------------------------------------------------
if [ ! -f "$WORK/$SRC.tar.gz" ]; then
    echo "fetching $URL"
    curl -fsSL -o "$WORK/$SRC.tar.gz" "$URL"
fi
echo "$SHA256  $WORK/$SRC.tar.gz" | sha256sum -c - >/dev/null || {
    echo "error: $SRC.tar.gz does not match the pinned sha256" >&2; exit 1; }

CONFIGURE=(--enable-static --disable-zlib --disable-lastlog
           --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx)

localoptions() {
    cat > "$1" <<'EOF'
#ifndef DROPBEAR_LOCALOPTIONS_H
#define DROPBEAR_LOCALOPTIONS_H
/* Password auth is compiled in: needed for `-B` (blank logins) and for the
 * optional shadow-backed password. Key-only remains a runtime choice (`-s`). */
#define DROPBEAR_SVR_PASSWORD_AUTH 1
#endif
EOF
}

verify() {
    BIN="$1"
    [ -f "$BIN" ] || { echo "error: build produced no dropbearmulti" >&2; exit 1; }
    file "$BIN" | grep -q 'aarch64.*statically linked' || {
        echo "error: not a static aarch64 binary:" >&2; file "$BIN" >&2; exit 1; }
    ver=$(qemu-aarch64 "$BIN" dropbear -V 2>&1 | head -1)
    case "$ver" in
        "Dropbear v2026.94"*) ;;
        *) echo "error: unexpected version string: $ver" >&2; exit 1 ;;
    esac
    qemu-aarch64 "$BIN" dropbear -h 2>&1 | grep -q -- '-B' || {
        echo "error: build has no -B (password auth missing)" >&2; exit 1; }
    qemu-aarch64 "$BIN" dropbearkey >/dev/null 2>&1 || true   # must not crash

    mkdir -p "$(dirname "$OUT")"
    install -m 755 "$BIN" "$OUT"
    echo "built: $ver"
    echo "mode:  $MODE"
    echo "size:  $(stat -c %s "$OUT") bytes"
    echo "sha256: $(sha256sum "$OUT" | cut -d' ' -f1)"
}

# ---- build -----------------------------------------------------------------
if [ "$MODE" = "musl" ]; then
    command -v docker >/dev/null || {
        echo "error: docker not found; use --gnu for the cross build" >&2; exit 1; }
    echo "building static musl aarch64 in an arm64 alpine container"

    cat > "$WORK/in-container.sh" <<'EOS'
set -e
apk add --no-cache build-base linux-headers curl xz perl >/dev/null 2>&1

# The GitHub archive extracts as dropbear-DROPBEAR_<tag>/; flatten it.
rm -rf /w/build
mkdir -p "/w/build/$SRC"
tar xzf "/w/$SRC.tar.gz" -C "/w/build/$SRC" --strip-components=1
cat > "/w/build/$SRC/localoptions.h" <<'EOF'
#ifndef DROPBEAR_LOCALOPTIONS_H
#define DROPBEAR_LOCALOPTIONS_H
#define DROPBEAR_SVR_PASSWORD_AUTH 1
#endif
EOF

mkdir -p /w/xcrypt
if [ ! -f "/w/xcrypt/libxcrypt-$XVER.tar.xz" ]; then
    curl -fsSL -o "/w/xcrypt/libxcrypt-$XVER.tar.xz" "$XURL"
fi
echo "$XSHA  /w/xcrypt/libxcrypt-$XVER.tar.xz" | sha256sum -c - >/dev/null
rm -rf "/w/xcrypt/libxcrypt-$XVER"
tar xJf "/w/xcrypt/libxcrypt-$XVER.tar.xz" -C /w/xcrypt
cd "/w/xcrypt/libxcrypt-$XVER"
./configure --disable-shared --enable-static --prefix=/usr/local \
    >/tmp/xconf.log 2>&1 || { tail -30 /tmp/xconf.log; exit 1; }
make -j"$(nproc)" >/tmp/xmake.log 2>&1 || { tail -40 /tmp/xmake.log; exit 1; }
make install >/tmp/xinstall.log 2>&1 || { tail -30 /tmp/xinstall.log; exit 1; }

cd "/w/build/$SRC"
CPPFLAGS=-I/usr/local/include LDFLAGS=-L/usr/local/lib LIBS=-lcrypt \
    ./configure $CONFIGURE >/tmp/conf.log 2>&1 || { tail -30 /tmp/conf.log; exit 1; }
make -j"$(nproc)" PROGRAMS="dropbear dropbearkey" MULTI=1 STATIC=1 >/tmp/build.log 2>&1 \
    || { tail -60 /tmp/build.log; exit 1; }
strip dropbearmulti
EOS

    docker run --rm --platform linux/arm64 \
        -e SRC="$SRC" -e CONFIGURE="${CONFIGURE[*]}" \
        -e XVER="$XVER" -e XURL="$XURL" -e XSHA="$XSHA" \
        -v "$WORK:/w" -w /w \
        alpine:3.20 sh /w/in-container.sh
    SRCDIR="$WORK/build/$SRC"
else
    command -v aarch64-linux-gnu-gcc >/dev/null || {
        echo "error: aarch64-linux-gnu-gcc not found" >&2; exit 1; }
    echo "building static glibc aarch64 with aarch64-linux-gnu-gcc"

    SRCDIR="$WORK/gnu-src/$SRC"
    rm -rf "$WORK/gnu-src"
    mkdir -p "$SRCDIR"
    tar xzf "$WORK/$SRC.tar.gz" -C "$SRCDIR" --strip-components=1
    localoptions "$SRCDIR/localoptions.h"

    PREFIX="$WORK/xcrypt-gnu"
    if [ ! -f "$PREFIX/lib/libcrypt.a" ]; then
        rm -rf "$WORK/xcrypt-src" "$PREFIX"
        mkdir -p "$WORK/xcrypt-src"
        if [ ! -f "$WORK/libxcrypt-$XVER.tar.xz" ]; then
            curl -fsSL -o "$WORK/libxcrypt-$XVER.tar.xz" "$XURL"
        fi
        echo "$XSHA  $WORK/libxcrypt-$XVER.tar.xz" | sha256sum -c - >/dev/null
        tar xJf "$WORK/libxcrypt-$XVER.tar.xz" -C "$WORK/xcrypt-src"
        (
            cd "$WORK/xcrypt-src/libxcrypt-$XVER"
            ./configure --host=aarch64-linux-gnu CC=aarch64-linux-gnu-gcc \
                --disable-shared --enable-static --prefix="$PREFIX" >/dev/null
            make -j"$(nproc)" >/dev/null
            make install >/dev/null
        )
    fi
    (
        cd "$SRCDIR"
        CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" LIBS=-lcrypt \
            ./configure --host=aarch64-linux-gnu CC=aarch64-linux-gnu-gcc \
            "${CONFIGURE[@]}" >/dev/null
        make -j"$(nproc)" PROGRAMS="dropbear dropbearkey" MULTI=1 STATIC=1 >/dev/null
        aarch64-linux-gnu-strip dropbearmulti
    )
fi

verify "$SRCDIR/dropbearmulti"
