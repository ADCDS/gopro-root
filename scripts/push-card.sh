#!/usr/bin/env bash
# Refresh the dropbear code on the camera's SD card over an already-armed SSH
# session. No card reader, no need to remove the card.
#
#   ./scripts/arm.sh                        # gets a shell over USB or Wi-Fi
#   ./scripts/push-card.sh 172.23.148.51    # USB address
#   ./scripts/push-card.sh 10.5.5.9         # Wi-Fi address
#
# Updates scheduled_capture.sh, stage.sh and dropbearmulti only. The card's
# auth configuration (dropbear.conf, root_hash, authorized_keys) and its SSH
# host key are left untouched; use scripts/install-card.sh to change those.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
DIR="$ROOT/payloads/dropbear"
CAM="${1:-${CAM:-}}"
KEY="${KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10)
CARD=/tmp/fuse_d

[ -n "$CAM" ] || {
    echo "usage: $0 <camera-ip>   (172.23.148.51 over USB, 10.5.5.9 over Wi-Fi)" >&2
    exit 2
}
[ -f "$DIR/scheduled_capture.sh" ] && [ -f "$DIR/stage.sh" ] \
    && [ -f "$DIR/dropbearmulti" ] || {
    echo "error: payload files missing under $DIR" >&2; exit 2
}

if ! ssh "${SSH_OPTS[@]}" "root@$CAM" '[ -d /tmp/fuse_d/DCIM ]' 2>/dev/null; then
    echo "error: root@$CAM has no mounted card at $CARD" >&2
    echo "       arm the camera first (./scripts/arm.sh) and make sure the card is in" >&2
    exit 1
fi

remote_hash() {
    ssh "${SSH_OPTS[@]}" "root@$CAM" "cat $CARD/$1" | sha256sum | cut -d' ' -f1
}

put() {   # local-file remote-name mode
    local src=$1 name=$2 mode=$3 want got
    want=$(sha256sum "$src" | cut -d' ' -f1)
    ssh "${SSH_OPTS[@]}" "root@$CAM" "umask 022; cat > $CARD/$name && chmod $mode $CARD/$name" < "$src"
    got=$(remote_hash "$name")
    if [ "$want" != "$got" ]; then
        echo "error: $name came back wrong ($want != $got)" >&2
        exit 1
    fi
    printf '  %-22s %8s bytes  ok\n' "$name" "$(stat -c %s "$src")"
}

echo "writing to $CAM:$CARD"
put "$DIR/scheduled_capture.sh" scheduled_capture.sh 755
put "$DIR/stage.sh"             stage.sh             755
put "$DIR/dropbearmulti"        dropbearmulti        755
ssh "${SSH_OPTS[@]}" "root@$CAM" 'sync' 2>/dev/null || true

echo
echo "card now has:"
ssh "${SSH_OPTS[@]}" "root@$CAM" \
    "ls -l $CARD/scheduled_capture.sh $CARD/stage.sh $CARD/dropbearmulti $CARD/dropbear.conf $CARD/authorized_keys $CARD/dropbear_hostkey 2>&1" || true
echo
echo "next: ./scripts/arm.sh          # auto-detects USB or Wi-Fi"
