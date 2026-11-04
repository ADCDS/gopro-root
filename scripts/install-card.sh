#!/usr/bin/env bash
# Stage the dropbear payload on a mounted GoPro SD card.
#
#   ./scripts/install-card.sh /media/$USER/<CARD> [authorized_keys.pub]
#
# Puts these files at the card root, where gpNet looks for scheduled_capture.sh:
#
#   scheduled_capture.sh   bootstrap that runs as root on "SC"
#   stage.sh               the installer (fetched fresh from the host first)
#   dropbearmulti          static aarch64 dropbear (built by build-dropbear.sh)
#   authorized_keys        the operator public key
#   dropbear_hostkey       stable server identity, generated once per card
#
# Refuses to touch a card that has an UPDATE/ folder: the camera would try to
# flash on boot.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
BIN="$ROOT/payloads/dropbear/dropbearmulti"
INSTALLER="$ROOT/payloads/dropbear/scheduled_capture.sh"
STAGE="$ROOT/payloads/dropbear/stage.sh"

MP="${1:-}"
KEY="${2:-$HOME/.ssh/id_ed25519.pub}"

[ -n "$MP" ] || { echo "usage: $0 <mountpoint> [authorized_keys.pub]" >&2; exit 2; }
[ -d "$MP" ] || { echo "error: $MP is not a directory" >&2; exit 2; }
[ -f "$KEY" ] || { echo "error: no public key at $KEY" >&2; exit 2; }
[ -f "$BIN" ] || { echo "error: $BIN missing - run scripts/build-dropbear.sh" >&2; exit 2; }

[ -d "$MP/DCIM" ] || { echo "refusing: $MP has no DCIM/ (not a GoPro card?)" >&2; exit 3; }
if [ -d "$MP/UPDATE" ]; then
    echo "refusing: $MP/UPDATE exists - the camera would flash on boot" >&2
    echo "rename it first (e.g. UPDATE.staged-do-not-flash)" >&2
    exit 4
fi

file "$BIN" | grep -q 'aarch64.*statically linked' || {
    echo "error: $BIN is not a static aarch64 binary" >&2
    echo "       $(file "$BIN" | cut -d: -f2-)" >&2
    exit 5
}

install -m 755 "$INSTALLER" "$MP/scheduled_capture.sh"
install -m 755 "$STAGE"     "$MP/stage.sh"
install -m 755 "$BIN"       "$MP/dropbearmulti"
install -m 644 "$KEY"       "$MP/authorized_keys"

# Generate the host key once per card so the camera's SSH identity is stable
# across boots. dropbearkey runs under qemu; the key is plain data on the card.
if [ ! -s "$MP/dropbear_hostkey" ]; then
    command -v qemu-aarch64 >/dev/null || {
        echo "error: qemu-aarch64 needed to generate the host key" >&2; exit 6; }
    tmp=$(mktemp)
    rm -f "$tmp"
    qemu-aarch64 "$BIN" dropbearkey -t ed25519 -f "$tmp" >/dev/null
    install -m 600 "$tmp" "$MP/dropbear_hostkey"
    rm -f "$tmp"
    echo "generated $MP/dropbear_hostkey"
fi

sync

echo
echo "staged on $MP:"
for f in scheduled_capture.sh stage.sh dropbearmulti authorized_keys dropbear_hostkey; do
    printf '  %-22s %8s bytes  %s\n' "$f" \
        "$(stat -c %s "$MP/$f")" "$(sha256sum "$MP/$f" | cut -d' ' -f1)"
done
echo
echo "next: card into camera, USB attached, then"
echo "  ./scripts/usb-up.sh && ./root-sc.sh http://172.23.148.51"
