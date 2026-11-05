#!/usr/bin/env bash
# Stage the dropbear payload on a mounted GoPro SD card. Run once per card.
#
#   ./scripts/install-card.sh /media/$USER/<CARD>
#   ./scripts/install-card.sh /media/$USER/<CARD> --pubkey ~/.ssh/id_ed25519.pub
#   ./scripts/install-card.sh /media/$USER/<CARD> --password
#   ./scripts/install-card.sh /media/$USER/<CARD> --key-only --pubkey ~/.ssh/id_ed25519.pub
#
# Auth modes, written to dropbear.conf at the card root:
#
#   blank     (default)  dropbear -B; `ssh root@<cam>` logs in with no password
#   password             dropbear asks for the password set here
#   keyonly              public key only (dropbear -s)
#
# The password itself is never written: the card gets root_hash, a SHA-512
# crypt hash, which stage.sh bind-mounts over /etc/shadow on the camera.
#
# Files written to the card root:
#   scheduled_capture.sh   bootstrap that runs as root on "SC"
#   stage.sh               the installer (fetched fresh from the host first)
#   dropbearmulti          static aarch64 dropbear (built by build-dropbear.sh)
#   dropbear.conf          AUTH=<mode>
#   authorized_keys        only with --pubkey
#   root_hash              only in password mode
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

MP=""
PASSWORD=""
KEYS=()
WANT_PASSWORD=0
WANT_KEYONLY=0

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-2}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --pubkey)
            [ $# -ge 2 ] || { echo "error: --pubkey needs a file" >&2; exit 2; }
            KEYS+=("$2"); shift ;;
        --password)
            WANT_PASSWORD=1
            if [ $# -ge 2 ]; then
                case "$2" in --*) ;; *) PASSWORD=$2; shift ;; esac
            fi ;;
        --key-only) WANT_KEYONLY=1 ;;
        -h|--help) usage 0 ;;
        -*) echo "error: unknown option: $1" >&2; usage 2 ;;
        *)  MP="$1" ;;
    esac
    shift
done

[ -n "$MP" ] || usage 2
[ -d "$MP" ] || { echo "error: $MP is not a directory" >&2; exit 2; }

if [ "$WANT_PASSWORD" = 1 ] && [ "$WANT_KEYONLY" = 1 ]; then
    echo "error: --password and --key-only are mutually exclusive" >&2; exit 2
fi
AUTH=blank
[ "$WANT_PASSWORD" = 1 ] && AUTH=password
[ "$WANT_KEYONLY" = 1 ]  && AUTH=keyonly
case "$AUTH" in
    blank|password|keyonly) ;;
    *) echo "error: bad auth mode $AUTH" >&2; exit 2 ;;
esac
if [ "$AUTH" = keyonly ] && [ "${#KEYS[@]}" -eq 0 ]; then
    echo "error: --key-only needs at least one --pubkey" >&2; exit 2
fi

for k in "${KEYS[@]+"${KEYS[@]}"}"; do
    [ -f "$k" ] || { echo "error: no public key at $k" >&2; exit 2; }
done
[ -f "$INSTALLER" ] || { echo "error: $INSTALLER missing" >&2; exit 2; }
[ -f "$STAGE" ]     || { echo "error: $STAGE missing" >&2; exit 2; }
[ -f "$BIN" ]       || { echo "error: $BIN missing - run scripts/build-dropbear.sh" >&2; exit 2; }
command -v qemu-aarch64 >/dev/null || {
    echo "error: qemu-aarch64 not found (Debian: apt install qemu-user)" >&2; exit 2; }

if [ "$AUTH" = password ] && [ -z "$PASSWORD" ]; then
    [ -t 0 ] || { echo "error: --password needs a value when stdin is not a tty" >&2; exit 2; }
    read -rsp "Password for root@camera: " PASSWORD; echo
    read -rsp "Repeat: " PASSWORD2; echo
    [ "$PASSWORD" = "$PASSWORD2" ] || { echo "error: passwords differ" >&2; exit 2; }
    [ -n "$PASSWORD" ] || { echo "error: empty password; omit --password for blank login" >&2; exit 2; }
fi

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
qemu-aarch64 "$BIN" dropbear -h 2>&1 | grep -q -- '-B' || {
    echo "error: $BIN has no password support (-B); rebuild with build-dropbear.sh" >&2
    exit 5
}

install -m 755 "$INSTALLER" "$MP/scheduled_capture.sh"
install -m 755 "$STAGE"     "$MP/stage.sh"
install -m 755 "$BIN"       "$MP/dropbearmulti"

printf '# written by scripts/install-card.sh\nAUTH=%s\n' "$AUTH" > "$MP/dropbear.conf"
chmod 644 "$MP/dropbear.conf"

if [ "${#KEYS[@]}" -gt 0 ]; then
    : > "$MP/authorized_keys"
    for k in "${KEYS[@]}"; do cat "$k" >> "$MP/authorized_keys"; done
    chmod 600 "$MP/authorized_keys"
else
    rm -f "$MP/authorized_keys"
fi

if [ "$AUTH" = password ]; then
    HASH=$(printf '%s' "$PASSWORD" | openssl passwd -6 -stdin -salt "$(openssl rand -hex 8)")
    [ -n "$HASH" ] || { echo "error: openssl could not hash the password" >&2; exit 5; }
    printf '%s\n' "$HASH" > "$MP/root_hash"
    chmod 600 "$MP/root_hash"
else
    rm -f "$MP/root_hash"
fi

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
echo "staged on $MP (AUTH=$AUTH):"
for f in scheduled_capture.sh stage.sh dropbearmulti dropbear.conf authorized_keys root_hash dropbear_hostkey; do
    [ -e "$MP/$f" ] || continue
    printf '  %-22s %8s bytes  %s\n' "$f" \
        "$(stat -c %s "$MP/$f")" "$(sha256sum "$MP/$f" | cut -d' ' -f1)"
done
echo
echo "card into the camera, then arm it:"
echo "  ./scripts/arm.sh"
case "$AUTH" in
    blank)    echo "  ssh root@<camera>          # no password" ;;
    password) echo "  ssh root@<camera>          # password set above" ;;
    keyonly)  echo "  ssh -i <key> root@<camera>" ;;
esac
