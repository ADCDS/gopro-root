#!/usr/bin/env bash
# Build the static aarch64 dropbearmulti shipped in payloads/dropbear/.
#
#   ./scripts/build-dropbear.sh            # musl static, in an arm64 container
#   ./scripts/build-dropbear.sh --gnu      # static glibc cross build (no docker)
#
# Password authentication is compiled out (localoptions.h), which is what we
# want on the camera anyway and which removes the crypt() dependency. zlib is
# disabled so nothing has to be linked in. The result is verified under
# qemu-aarch64 before it is written into the repository.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
OUT="$ROOT/payloads/dropbear/dropbearmulti"

TAG="DROPBEAR_2026.94"
SRC="dropbear-2026.94"
URL="https://github.com/mkj/dropbear/archive/refs/tags/${TAG}.tar.gz"
SHA256="827d3f6e510e7554ee18d5c6a00dfee1a6a555559495e65e2e8f8d41c79eed84"

MODE="musl"
[ "${1:-}" = "--gnu" ] && MODE="gnu"

WORK="${WORK:-/tmp/dropbear-build}"
mkdir -p "$WORK"

# ---- source ----------------------------------------------------------------
if [ ! -f "$WORK/$SRC.tar.gz" ]; then
    echo "fetching $URL"
    curl -fsSL -o "$WORK/$SRC.tar.gz" "$URL"
fi
echo "$SHA256  $WORK/$SRC.tar.gz" | sha256sum -c - >/dev/null || {
    echo "error: $SRC.tar.gz does not match the pinned sha256" >&2; exit 1; }

rm -rf "$WORK/build"
mkdir -p "$WORK/build"
tar xzf "$WORK/$SRC.tar.gz" -C "$WORK/build"
SRCDIR="$WORK/build/$SRC"

cat > "$SRCDIR/localoptions.h" <<'EOF'
#ifndef DROPBEAR_LOCALOPTIONS_H
#define DROPBEAR_LOCALOPTIONS_H
/* Key-only server: no password auth, hence no crypt() dependency. */
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#endif
EOF

CONFIGURE=(--enable-static --disable-zlib --disable-lastlog
           --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx)

# ---- build -----------------------------------------------------------------
if [ "$MODE" = "musl" ]; then
    command -v docker >/dev/null || {
        echo "error: docker not found; use --gnu for the cross build" >&2; exit 1; }
    echo "building static musl aarch64 in an arm64 alpine container"
    docker run --rm --platform linux/arm64 -v "$WORK/build:/b" -w "/b/$SRC" \
        alpine:3.20 sh -c '
        set -e
        apk add --no-cache build-base >/dev/null 2>&1
        ./configure '"${CONFIGURE[*]}"' >/tmp/conf.log 2>&1 || { tail -20 /tmp/conf.log; exit 1; }
        make -j"$(nproc)" PROGRAMS="dropbear dropbearkey" MULTI=1 STATIC=1 >/tmp/build.log 2>&1 \
            || { tail -40 /tmp/build.log; exit 1; }
        strip dropbearmulti
    '
else
    command -v aarch64-linux-gnu-gcc >/dev/null || {
        echo "error: aarch64-linux-gnu-gcc not found" >&2; exit 1; }
    echo "building static glibc aarch64 with aarch64-linux-gnu-gcc"
    (
        cd "$SRCDIR"
        ./configure --host=aarch64-linux-gnu CC=aarch64-linux-gnu-gcc \
            "${CONFIGURE[@]}" >/dev/null
        make -j"$(nproc)" PROGRAMS="dropbear dropbearkey" MULTI=1 STATIC=1 >/dev/null
        aarch64-linux-gnu-strip dropbearmulti
    )
fi

BIN="$SRCDIR/dropbearmulti"
[ -f "$BIN" ] || { echo "error: build produced no dropbearmulti" >&2; exit 1; }

# ---- verify ----------------------------------------------------------------
file "$BIN" | grep -q 'aarch64.*statically linked' || {
    echo "error: not a static aarch64 binary:" >&2; file "$BIN" >&2; exit 1; }

ver=$(qemu-aarch64 "$BIN" dropbear -V 2>&1 | head -1)
case "$ver" in
    "Dropbear v2026.94"*) ;;
    *) echo "error: unexpected version string: $ver" >&2; exit 1 ;;
esac

qemu-aarch64 "$BIN" dropbearkey >/dev/null 2>&1 || true   # must not crash

mkdir -p "$(dirname "$OUT")"
install -m 755 "$BIN" "$OUT"

echo "built: $ver"
echo "mode:  $MODE"
echo "size:  $(stat -c %s "$OUT") bytes"
echo "sha256: $(sha256sum "$OUT" | cut -d' ' -f1)"
