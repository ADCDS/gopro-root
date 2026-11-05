#!/usr/bin/env bash
# Re-arm the dropbear shell on a camera that was power-cycled.
#
# The camera's rootfs is mounted read-only (`/dev/root / ext4 ro`), so nothing
# survives a reboot: /dev/dropbear is devtmpfs and the iptables rule is runtime
# state. The card payload is the only trigger surface, so this re-sends it.
#
#   ./scripts/arm.sh                 # auto: USB gadget if attached, else Wi-Fi AP
#   ./scripts/arm.sh --usb  [ip]     # force USB NCM  (default 172.23.148.51)
#   ./scripts/arm.sh --wifi [ip]     # force Wi-Fi AP (default 10.5.5.9)
#
# Both transports work the same way: one unauthenticated HTTP request, then
# dropbear listening on 0.0.0.0:22 once the installer has opened tcp/22. What
# differs is the address the camera uses to reach this host; the bootstrap on
# the card discovers it from the camera's own ARP table, so the same card works
# over USB and over the camera's Wi-Fi AP.
#
# Serves payloads/dropbear/ over HTTP for the duration of the trigger, so the
# camera runs the current stage.sh from this checkout rather than whatever copy
# happens to be on the card. Idempotent; restarting dropbear drops any active
# ssh session on that camera.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
DIR="$ROOT/payloads/dropbear"
KEY="${KEY:-$HOME/.ssh/id_ed25519}"
HTTP_PORT="${HTTP_PORT:-8000}"
WAIT="${WAIT:-45}"
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10)

MODE=auto
CAM_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --wifi) MODE=wifi ;;
        --usb)  MODE=usb ;;
        -h|--help)
            sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "error: unknown option: $1" >&2; exit 2 ;;
        *)  CAM_ARG="$1" ;;
    esac
    shift
done

# Same detection as usb-up.sh: the gadget MAC (and therefore the enx name)
# changes on every plug, so match on the GoPro USB vendor id.
usb_gadget_present() {
    local d p
    for d in /sys/class/net/*; do
        [ -e "$d/device" ] || continue
        p=$(readlink -f "$d/device")
        while [ -n "$p" ] && [ "$p" != "/" ]; do
            if [ -f "$p/idVendor" ]; then
                [ "$(cat "$p/idVendor" 2>/dev/null)" = "2672" ] && return 0
                break
            fi
            p=$(dirname "$p")
        done
    done
    return 1
}

if [ "$MODE" = auto ]; then
    if usb_gadget_present; then MODE=usb; else MODE=wifi; fi
fi

if [ "$MODE" = usb ]; then
    CAM="${CAM:-${CAM_ARG:-172.23.148.51}}"
else
    CAM="${CAM:-${CAM_ARG:-10.5.5.9}}"
fi

STARTED_SERVER=0
if ! ss -ltn 2>/dev/null | grep -q ":$HTTP_PORT "; then
    ( cd "$DIR" && exec python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 ) \
        >/tmp/gopro-stage-http.log 2>&1 &
    STARTED_SERVER=$!
    trap 'kill "$STARTED_SERVER" 2>/dev/null' EXIT
    sleep 1
fi
LOG=/tmp/gopro-stage-http.log
: >> "$LOG" 2>/dev/null || true
BEFORE=$(wc -l < "$LOG" 2>/dev/null || echo 0)

if [ "$MODE" = usb ]; then
    echo "mode: USB NCM (camera $CAM)"
    CAM_IP="$CAM" "$ROOT/scripts/usb-up.sh" || exit 1
else
    # The camera is the AP; this host is a DHCP client on it, so the address
    # changes. Only used to explain what the camera should call back to.
    HOST_IP=$(ip -4 route get "$CAM" 2>/dev/null \
        | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)
    echo "mode: Wi-Fi AP (camera $CAM, host ${HOST_IP:-unknown})"
    # The AP can still be settling (e.g. right after a band bounce), so give
    # the camera's HTTP server a few seconds before declaring failure.
    up80=0
    for i in $(seq 1 15); do
        if timeout 2 bash -c "exec 3<>/dev/tcp/$CAM/80" 2>/dev/null; then
            up80=1
            break
        fi
        sleep 1
    done
    if [ "$up80" != 1 ]; then
        echo "error: $CAM:80 unreachable" >&2
        echo "       join the camera's AP first (wireless on the camera), or use" >&2
        echo "       ./scripts/arm.sh --usb with the cable attached - USB and" >&2
        echo "       Wi-Fi are mutually exclusive on this camera" >&2
        exit 1
    fi
    echo "OK: $CAM:80 answered"
fi

echo
echo "triggering SC on $CAM"
code=$(curl -s -m 12 -o /dev/null -w '%{http_code}' \
    "http://$CAM/gp/gpCamera?cmd=SC&p=%02" || true)
[ "$code" = "200" ] || { echo "error: SC returned ${code:-no response}" >&2; exit 1; }

# The payload fetches stage.sh from the host, runs it, and starts dropbear.
up=0
printf 'waiting for %s:22 ' "$CAM"
for i in $(seq 1 "$WAIT"); do
    sleep 1
    if timeout 2 bash -c "exec 3<>/dev/tcp/$CAM/22" 2>/dev/null; then
        up=1
        break
    fi
    [ $((i % 5)) -eq 0 ] && printf '.'
done
echo
[ "$up" = 1 ] || {
    echo "error: nothing listening on $CAM:22 after ${WAIT}s" >&2
    echo "       see docs/dropbear.md §7 (beacons) or the card's DROPBEAR_LOG.txt" >&2
    exit 1
}

# The card bootstrap decides which host to fetch from. If it is an older copy
# pinned to the USB address, the install still works (card fallback) but runs
# the frozen stage.sh instead of this checkout - say so instead of pretending.
if tail -n "+$((BEFORE + 1))" "$LOG" 2>/dev/null | grep -q 'GET /stage.sh'; then
    echo "stage.sh served from this checkout"
else
    echo "note: the camera did not fetch /stage.sh; it ran the card's copy"
    echo "      re-stage the card once (scripts/install-card.sh, or copy"
    echo "      payloads/dropbear/scheduled_capture.sh to the card root) to get"
    echo "      live stage.sh over both transports"
fi

echo "checking ssh"
timeout 20 ssh "${SSH_OPTS[@]}" "root@$CAM" 'id; uname -r' 2>&1 \
    | grep -v '^Warning: Permanently added'
