#!/usr/bin/env bash
# Turn the camera's Wi-Fi AP on over Bluetooth LE, then join it - no Quik app.
#
#   ./scripts/wifi-on.sh              # enable the AP and join it
#   ./scripts/wifi-on.sh --pair       # first run: camera in pairing mode
#   ./scripts/wifi-on.sh --arm        # ...and trigger the exploit afterwards
#   ./scripts/wifi-on.sh --band 2.4   # force the band (most adapters are 2.4 only)
#   ./scripts/wifi-on.sh --no-connect # only enable it and print SSID/password
#
# The camera keeps its own wireless band by default. If it is on 5 GHz and the
# AP is not visible (a 2.4 GHz-only adapter cannot see it), the script switches
# the camera to 2.4 GHz and retries once.
#
# One-time setup: put the camera in pairing mode (camera UI:
# Preferences -> Connections -> Wireless Connections), run `--pair`, and the
# host is bonded. Later runs need no camera interaction.
#
# BLE is disabled while the camera is on USB; unplug it first. If this host has
# no Bluetooth, enable wireless on the camera by hand and use ./scripts/arm.sh.
#
# Needs python 'bleak' (scripts/requirements-wifi.txt) and BlueZ.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
CAM_IP="${CAM:-10.5.5.9}"

PAIR=""
CONNECT=1
ARM=0
TIMEOUT=10
NAME=""
BAND=""
BAND_FORCED=0
SSID=""
PW=""
HAVE_NM=0

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --pair)       PAIR=--pair ;;
        --no-connect) CONNECT=0 ;;
        --arm)        ARM=1 ;;
        --timeout)    TIMEOUT="${2:-}"; shift ;;
        --name)       NAME="${2:-}"; shift ;;
        --band)
            BAND="${2:-}"
            case "$BAND" in
                keep) ;;
                2.4|5) BAND_FORCED=1 ;;
                *) echo "error: --band must be keep, 2.4 or 5" >&2; exit 2 ;;
            esac
            shift ;;
        -h|--help)    usage 0 ;;
        *) echo "error: unknown option: $1" >&2; usage 2 ;;
    esac
    shift
done

PY="${PYTHON:-}"
if [ -z "$PY" ]; then
    if [ -x "$ROOT/.venv/bin/python3" ]; then PY="$ROOT/.venv/bin/python3"; else PY=python3; fi
fi

if ! "$PY" -c 'import bleak' 2>/dev/null; then
    echo "error: python package 'bleak' is not installed for $PY" >&2
    echo "       python3 -m venv .venv" >&2
    echo "       .venv/bin/pip install -r scripts/requirements-wifi.txt" >&2
    exit 2
fi

command -v nmcli >/dev/null 2>&1 && nmcli -t general status >/dev/null 2>&1 && HAVE_NM=1

# enable_ap [extra args...] -> prints the SSID/PASSWORD/BAND block
enable_ap() {
    local args=(--timeout "$TIMEOUT")
    [ -n "$PAIR" ] && args+=("$PAIR")
    [ -n "$NAME" ] && args+=(--name "$NAME")
    [ -n "$BAND" ] && args+=(--band "$BAND")
    "$PY" "$ROOT/scripts/wifi_on.py" "${args[@]}" "$@"
}

read_fields() {
    SSID=$(printf '%s\n' "$1" | sed -n 's/^SSID=//p' | head -n 1)
    PW=$(printf '%s\n' "$1" | sed -n 's/^PASSWORD=//p' | head -n 1)
    BAND=$(printf '%s\n' "$1" | sed -n 's/^BAND=//p' | head -n 1)
}

reachable() {
    timeout 2 bash -c "exec 3<>/dev/tcp/$CAM_IP/80" 2>/dev/null
}

scan_for_ssid() {
    [ "$HAVE_NM" = 1 ] || return 0
    nmcli device wifi rescan >/dev/null 2>&1
    sleep 3
    nmcli -t -f SSID device wifi list 2>/dev/null | grep -Fxq -- "$SSID"
}

join_ap() {
    if reachable; then
        return 0
    fi
    if [ "$HAVE_NM" != 1 ]; then
        echo "join manually: SSID=$SSID  PASSWORD=$PW"
        return 1
    fi
    for _ in 1 2 3; do
        if nmcli --wait 15 device wifi connect "$SSID" password "$PW" >/dev/null 2>&1; then
            echo "joined $SSID"
            return 0
        fi
        # NetworkManager may have re-connected to its saved profile already.
        if reachable; then
            echo "joined $SSID (NetworkManager auto-connect)"
            return 0
        fi
        nmcli device wifi rescan >/dev/null 2>&1
        sleep 2
    done
    return 1
}

wait_http() {
    printf 'waiting for %s:80 ' "$CAM_IP"
    for _ in $(seq 1 20); do
        if reachable; then
            echo "OK"
            return 0
        fi
        sleep 1
        printf '.'
    done
    echo
    return 1
}

out=$(enable_ap) || exit 1
printf '%s\n' "$out"
read_fields "$out"
[ -n "$SSID" ] || { echo "error: camera did not report an SSID" >&2; exit 1; }

if [ "$CONNECT" = 1 ]; then
    if reachable; then
        echo "already connected to the camera network"
    else
        if ! scan_for_ssid; then
            if [ "$BAND" = 5 ] && [ "$BAND_FORCED" = 0 ]; then
                echo "camera AP is on 5 GHz and this host cannot see it;" >&2
                echo "switching the camera to 2.4 GHz and retrying" >&2
                out=$(enable_ap --band 2.4) || exit 1
                printf '%s\n' "$out"
                read_fields "$out"
                scan_for_ssid || true
            else
                echo "warn: $SSID not in the Wi-Fi scan; trying to join anyway" >&2
            fi
        fi
        if reachable || join_ap; then
            :
        else
            echo "warn: could not join $SSID" >&2
        fi
        wait_http || echo "warn: camera unreachable at $CAM_IP" >&2
    fi
fi

if [ "$ARM" = 1 ]; then
    exec "$ROOT/scripts/arm.sh" --wifi "$CAM_IP"
fi
