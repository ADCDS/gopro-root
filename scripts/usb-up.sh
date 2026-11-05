#!/usr/bin/env bash
# Bring up the host side of the HERO11's USB NCM gadget.
#
# The camera enumerates as USB 2672:0059 and the kernel names the interface
# enx<mac>. The gadget MAC is regenerated on every plug, so the name changes:
# find it by USB vendor id, never hardcode it.
#
# Prefers NetworkManager (works without root); falls back to `ip addr` when
# running as root and NM is not managing the link.
#
#   ./scripts/usb-up.sh             # configure and probe
#   sudo ./scripts/usb-up.sh        # same, without NetworkManager
#   ./scripts/usb-up.sh --remove    # tear the address back down
#
# The camera never answers ICMP over the gadget, so liveness is a TCP connect
# to port 80, not ping.
set -u

CAM_IP="${CAM_IP:-172.23.148.51}"
HOST_CIDR="${HOST_CIDR:-172.23.148.52/24}"
GOPRO_VID="2672"
NM_PROFILE="${NM_PROFILE:-gopro-usb}"

# Interfaces whose USB parent device is a GoPro.
cam_ifaces() {
    local d p vid
    for d in /sys/class/net/*; do
        [ -e "$d/device" ] || continue
        p=$(readlink -f "$d/device")
        vid=""
        while [ -n "$p" ] && [ "$p" != "/" ]; do
            if [ -f "$p/idVendor" ]; then
                vid=$(cat "$p/idVendor" 2>/dev/null)
                break
            fi
            p=$(dirname "$p")
        done
        [ "$vid" = "$GOPRO_VID" ] && basename "$d"
    done
}

have_nm() {
    command -v nmcli >/dev/null 2>&1 && nmcli -t general status >/dev/null 2>&1
}

mapfile -t IFACES < <(cam_ifaces)
if [ "${#IFACES[@]}" -eq 0 ]; then
    if [ "${1:-}" = "--remove" ]; then
        echo "no camera interface attached; nothing to remove"
        exit 0
    fi
    echo "error: no GoPro USB network interface found (VID $GOPRO_VID)" >&2
    echo "       is the camera plugged in and powered on?  lsusb | grep -i $GOPRO_VID" >&2
    exit 1
fi
ifc="${IFACES[0]}"
[ "${#IFACES[@]}" -gt 1 ] && echo "note: several camera interfaces, using $ifc" >&2

if [ "${1:-}" = "--remove" ]; then
    if have_nm; then
        nmcli connection down "$NM_PROFILE" 2>/dev/null || true
        echo "brought $NM_PROFILE down"
    fi
    if [ "$(id -u)" -eq 0 ]; then
        ip addr flush dev "$ifc" && echo "flushed $ifc"
    fi
    exit 0
fi

echo "camera interface: $ifc"

if have_nm; then
    # One profile, re-pointed at the current gadget name every run, so a
    # re-enumeration does not silently leave the link unconfigured.
    if nmcli -t -f NAME connection show | grep -qx "$NM_PROFILE"; then
        nmcli connection modify "$NM_PROFILE" \
            connection.interface-name "$ifc" \
            ipv4.method manual \
            ipv4.addresses "$HOST_CIDR" \
            ipv4.never-default yes \
            ipv6.method ignore
    else
        nmcli connection add type ethernet ifname "$ifc" con-name "$NM_PROFILE" \
            ipv4.method manual ipv4.addresses "$HOST_CIDR" \
            ipv4.never-default yes ipv6.method ignore >/dev/null
    fi
    nmcli connection up "$NM_PROFILE" >/dev/null || {
        echo "error: nmcli could not activate $NM_PROFILE" >&2
        exit 1
    }
elif [ "$(id -u)" -eq 0 ]; then
    ip link set "$ifc" up
    ip addr replace "$HOST_CIDR" dev "$ifc"
else
    echo "error: no usable NetworkManager and not root" >&2
    echo "       run: sudo $0" >&2
    exit 2
fi

echo "  $(ip -4 -br addr show "$ifc")"

code=$(curl -s -m 6 -o /dev/null -w '%{http_code}' "http://$CAM_IP/gp/gpControl/info" || true)
if [ "$code" = "200" ]; then
    fw=$(curl -s -m 6 "http://$CAM_IP/gp/gpControl/info" \
         | tr ',' '\n' | grep -o '"firmware_version":"[^"]*"' | cut -d'"' -f4)
    echo "OK: $CAM_IP:80 answered 200 (firmware ${fw:-unknown})"
    echo "next: ./scripts/arm.sh"
    exit 0
fi

echo "warn: http://$CAM_IP/gp/gpControl/info -> ${code:-no response}" >&2
echo "      data cable? camera on? not in Wi-Fi mode (USB and Wi-Fi are exclusive)" >&2
exit 1
