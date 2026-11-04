#!/usr/bin/env bash
# Serve the dropbear stage script to the camera and capture the log it pushes
# back. Run this while triggering the camera:
#
#   ./scripts/serve.sh
#   # in another shell: ./scripts/usb-up.sh && ./root-sc.sh http://172.23.148.51
#
# The payload on the card is only a bootstrap: it fetches stage.sh from here
# (http://<host>:8000/stage.sh), runs it as root, then sends the log to
# <host>:9001. Edit payloads/dropbear/stage.sh and re-trigger to iterate,
# without touching the card.
#
# HOST_IP must be the address this host has on the camera's USB subnet.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
DIR="$ROOT/payloads/dropbear"
HOST_IP="${HOST_IP:-172.23.148.52}"
HTTP_PORT="${HTTP_PORT:-8000}"
LOG_PORT="${LOG_PORT:-9001}"
OUT="${OUT:-/tmp/gopro-dropbear.log}"

[ -f "$DIR/stage.sh" ] || { echo "error: $DIR/stage.sh missing" >&2; exit 1; }

echo "serving   http://$HOST_IP:$HTTP_PORT/stage.sh  (from $DIR)"
echo "capturing log on $HOST_IP:$LOG_PORT -> $OUT"
echo

( cd "$DIR" && exec python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 ) &
HTTP_PID=$!
cleanup() { kill "$HTTP_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# One connection, then exit; the caller can look at $OUT.
if ! nc -l -p "$LOG_PORT" > "$OUT" 2>/dev/null; then
    echo "warn: could not listen on $LOG_PORT (busy?)" >&2
fi

echo
echo "captured $(wc -c < "$OUT") bytes -> $OUT"
