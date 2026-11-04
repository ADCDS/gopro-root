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
# Everything is logged to /tmp/fuse_d/DROPBEAR_LOG.txt as well.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

CARD=/tmp/fuse_d
LOG=$CARD/DROPBEAR_LOG.txt
HOST=172.23.148.52
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

STAGE=""
if /usr/bin/wget -q -T 5 -O /tmp/stage.sh "http://$HOST:$HTTP_PORT/stage.sh" 2>>"$LOG"; then
    if [ -s /tmp/stage.sh ]; then
        log "fetched stage.sh from $HOST:$HTTP_PORT ($(wc -c < /tmp/stage.sh) bytes)"
        STAGE=/tmp/stage.sh
    fi
fi
if [ -z "$STAGE" ]; then
    if [ -s "$CARD/stage.sh" ]; then
        log "fetch failed; using card stage.sh ($(wc -c < "$CARD/stage.sh") bytes)"
        STAGE=$CARD/stage.sh
    else
        log "FATAL: no stage script (fetch failed, no card copy)"
        exit 1
    fi
fi

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
