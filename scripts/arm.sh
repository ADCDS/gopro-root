#!/usr/bin/env bash
# Re-arm the dropbear shell on a camera that was power-cycled.
#
# The camera's rootfs is mounted read-only (`/dev/root / ext4 ro`), so nothing
# survives a reboot: /dev/dropbear is devtmpfs and the iptables rule is runtime
# state. The card payload is the only trigger surface, so this re-sends it.
#
#   ./scripts/arm.sh
#
# Serves payloads/dropbear/ over HTTP for the duration of the trigger, so the
# camera runs the current stage.sh from this checkout rather than whatever copy
# happens to be on the card. Idempotent; restarting dropbear drops any active
# ssh session on that camera.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
DIR="$ROOT/payloads/dropbear"
CAM="${CAM:-172.23.148.51}"
KEY="${KEY:-$HOME/.ssh/id_ed25519}"
HTTP_PORT="${HTTP_PORT:-8000}"
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10)

STARTED_SERVER=0
if ! ss -ltn 2>/dev/null | grep -q ":$HTTP_PORT "; then
    ( cd "$DIR" && exec python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 ) \
        >/tmp/gopro-stage-http.log 2>&1 &
    STARTED_SERVER=$!
    trap 'kill "$STARTED_SERVER" 2>/dev/null' EXIT
    sleep 1
fi

"$ROOT/scripts/usb-up.sh" || exit 1

echo
echo "triggering SC on $CAM"
code=$(curl -s -m 12 -o /dev/null -w '%{http_code}' \
    "http://$CAM/gp/gpCamera?cmd=SC&p=%02" || true)
[ "$code" = "200" ] || { echo "error: SC returned ${code:-no response}" >&2; exit 1; }

# The payload fetches stage.sh from the host, runs it, and starts dropbear.
up=0
for _ in $(seq 1 10); do
    sleep 2
    if timeout 6 bash -c "exec 3<>/dev/tcp/$CAM/22" 2>/dev/null; then
        up=1
        break
    fi
done
[ "$up" = 1 ] || { echo "error: nothing listening on $CAM:22" >&2; exit 1; }

echo "checking ssh"
timeout 20 ssh "${SSH_OPTS[@]}" "root@$CAM" 'id; uname -r' 2>&1 \
    | grep -v '^Warning: Permanently added'
