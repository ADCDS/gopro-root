#!/bin/sh
# Bootstrap for the GoPro HERO11 dropbear install.
#
# gpNet runs this file as root when it receives BP command "SC" with payload
# byte 0x02. It exists so the real logic can live on the build host: while
# iterating, only stage.sh changes and no card swap is needed.
#
#   1. fetch http://$HOST:8000/stage.sh and run it
#   2. if that fails, run the copy of stage.sh that sits on the card
#   3. push the collected log back to $HOST:$LOG_PORT
#
# $HOST is discovered, not assumed: over USB the peer is the fixed gadget
# address, but over the camera's Wi-Fi AP this host is just a DHCP client, so
# the address is read back from the camera's ARP table (see host_candidates).
#
# Everything is logged to /tmp/fuse_d/DROPBEAR_LOG.txt as well.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

CARD=/tmp/fuse_d
LOG=$CARD/DROPBEAR_LOG.txt
USB_HOST=172.23.148.52
HTTP_PORT=8000
LOG_PORT=9001

log() { echo "$(date '+%F %T' 2>/dev/null) $*" >> "$LOG"; }

if [ ! -d "$CARD" ]; then
    echo "fuse_d not mounted" > /tmp/DROPBEAR_LOG.txt 2>&1
    exit 1
fi

log "=== bootstrap: $(date 2>/dev/null) ==="
log "cmdline: $(cat /proc/cmdline)"
log "wget: $(ls -l /usr/bin/wget 2>&1)"
log "nc:   $(ls -l /usr/bin/nc 2>&1)"

# Which address is this host? Over USB it is the fixed gadget peer. Over the
# camera's Wi-Fi AP this host is a DHCP client, so the address is not known in
# advance - but the machine that just sent the trigger is necessarily in the
# camera's ARP table, so try those first. USB_HOST stays last as the fixed
# fallback. Cheap: a failed candidate is one wget connect attempt.
host_candidates() {
    if [ -r /proc/net/arp ]; then
        while read -r ip _hw flags _rest; do
            [ "$flags" = "0x2" ] || continue      # 0x2: complete entry
            case "$ip" in *:*) continue ;; esac   # IPv4 only
            printf '%s\n' "$ip"
        done < /proc/net/arp
    fi
    printf '%s\n' "$USB_HOST"
}

HOST=$USB_HOST
STAGE=""
for h in $(host_candidates); do
    if /usr/bin/wget -q -T 3 -O /tmp/stage.sh "http://$h:$HTTP_PORT/stage.sh" 2>>"$LOG"; then
        # stage.sh runs as root: only accept a file that is ours.
        if [ -s /tmp/stage.sh ] && grep -q 'Root dropbear installer' /tmp/stage.sh; then
            HOST=$h
            log "fetched stage.sh from $HOST:$HTTP_PORT ($(wc -c < /tmp/stage.sh) bytes)"
            STAGE=/tmp/stage.sh
            break
        fi
    fi
done
if [ -z "$STAGE" ]; then
    # Nothing served it; still point the beacons at the most likely host.
    HOST=$(host_candidates | head -n 1)
    if [ -s "$CARD/stage.sh" ]; then
        log "fetch failed; using card stage.sh ($(wc -c < "$CARD/stage.sh") bytes)"
        STAGE=$CARD/stage.sh
    else
        log "FATAL: no stage script (fetch failed, no card copy)"
        exit 1
    fi
fi
candidates=$(host_candidates | while read -r c; do printf '%s ' "$c"; done)
log "host: $HOST (candidates: $candidates)"

# stage.sh beacons to $HOST; pass the discovered address along.
export HOST

log "--- running $STAGE ---"
/bin/sh "$STAGE" >> "$LOG" 2>&1
log "--- stage rc=$? ---"

# Push the log home. Best effort: the card copy remains authoritative.
if [ -x /usr/bin/nc ]; then
    # BusyBox 1.27 nc: no -w; usage is "nc [-l] [-p PORT] [IPADDR PORT]"
    if timeout 5 /usr/bin/nc "$HOST" "$LOG_PORT" < "$LOG" 2>>"$LOG"; then
        log "log pushed to $HOST:$LOG_PORT"
    else
        log "log push failed (host listener not running?)"
    fi
fi
