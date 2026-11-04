#!/usr/bin/env sh
# Runs as root on the camera when gpNet receives the "SC" command with
# payload byte 0x02 (see README / docs/how-it-works.md).
#
# Drop this file at the ROOT of the SD card, named exactly:
#     scheduled_capture.sh
#
# Default behaviour: prove root and record it, change nothing, do not reboot.
# Uncomment the last line if you want the camera to reboot afterwards.

OUT=/tmp/fuse_d/ROOTED.txt
VIS=/tmp/fuse_d/DCIM/100GOPRO/ROOTED.TXT

{
    echo "root via SC / RTsetSC"
    echo "date:  $(date 2>/dev/null)"
    echo "uid:   $(id 2>/dev/null)"
    echo "uname: $(uname -a 2>/dev/null)"
    echo "pwd:   $(pwd 2>/dev/null)"
} > "$OUT" 2>&1

# A copy under DCIM so the marker also shows up in the media list / MTP.
cp "$OUT" "$VIS" 2>/dev/null || true

# Optional: reboot (the camera's own scheduled capture has "No Limit" duration,
# so a reboot is a convenient way to stop a recording started by the schedule).
# sync
# reboot -f
