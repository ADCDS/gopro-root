#!/usr/bin/env python3
"""Enable the camera's Wi-Fi AP over Bluetooth LE, without the Quik app.

GoPro's BLE control service exposes "Set AP Control". Writing mode 1 turns the
camera's Wi-Fi AP on; the AP SSID and password can then be read back from their
own characteristics.

The camera's wireless band (BLE setting 178) matters: a 5 GHz AP is invisible to
2.4 GHz-only adapters. `--band 2.4` switches the camera and bounces the AP;
without it the camera's setting is left alone.

Requires a one-time bond: put the camera in pairing mode (camera UI,
Preferences -> Connections -> Wireless Connections) and run once with --pair.
After that, no camera interaction is needed.

Output (one per line, for scripts/wifi-on.sh):
    SSID=<camera AP name>
    PASSWORD=<camera AP password>
    BAND=2.4|5
    AP_MODE=1
"""

from __future__ import annotations

import argparse
import asyncio
import re
import sys

try:
    from bleak import BleakClient, BleakScanner
    from bleak.exc import BleakError
except ImportError:  # pragma: no cover - exercised on hosts without bleak
    print("error: python package 'bleak' is not installed", file=sys.stderr)
    print("       python3 -m venv .venv && .venv/bin/pip install -r scripts/requirements-wifi.txt",
          file=sys.stderr)
    sys.exit(2)

BASE_UUID = "b5f9{}-aa8d-11e3-9046-0002a5d5c51b"
COMMAND_REQ = BASE_UUID.format("0072")
COMMAND_RSP = BASE_UUID.format("0073")
SETTING_REQ = BASE_UUID.format("0074")
SETTING_RSP = BASE_UUID.format("0075")
QUERY_REQ = BASE_UUID.format("0076")
QUERY_RSP = BASE_UUID.format("0077")
WIFI_AP_SSID = BASE_UUID.format("0002")
WIFI_AP_PASSWORD = BASE_UUID.format("0003")

SET_AP_CONTROL = 0x17
CMD_ENABLE = bytes([0x03, SET_AP_CONTROL, 0x01, 0x01])
CMD_BOUNCE = bytes([0x03, SET_AP_CONTROL, 0x01, 0x02])
SETTING_WIRELESS_BAND = 178
STATUS_AP_MODE = 69
STATUS_WIRELESS_BAND = 76


class Channel:
    """One-at-a-time request/response over the notify characteristics."""

    def __init__(self, client: BleakClient) -> None:
        self.client = client
        self.data: bytes | None = None
        self.event = asyncio.Event()

    def on_notify(self, _: object, data: bytearray) -> None:
        self.data = bytes(data)
        self.event.set()

    async def subscribe(self) -> None:
        for uuid in (COMMAND_RSP, SETTING_RSP, QUERY_RSP):
            await self.client.start_notify(uuid, self.on_notify)

    async def request(self, uuid: str, payload: bytes, label: str) -> bytes:
        self.event.clear()
        self.data = None
        await self.client.write_gatt_char(uuid, payload, response=True)
        try:
            await asyncio.wait_for(self.event.wait(), timeout=8)
        except asyncio.TimeoutError:
            raise RuntimeError(f"{label}: no response from the camera") from None
        data = self.data or b""
        # Packet: type, id, status[, ...].
        if len(data) < 3 or data[2] != 0:
            raise RuntimeError(f"{label}: camera returned {data.hex(':')}")
        return data

    async def status(self, status_id: int) -> int:
        data = await self.request(QUERY_REQ, bytes([0x02, 0x13, status_id]),
                                  f"status {status_id}")
        return data[-1]

    async def read_char(self, uuid: str, label: str) -> str:
        try:
            return (await self.client.read_gatt_char(uuid)).decode(errors="replace")
        except BleakError as exc:
            raise RuntimeError(f"{label}: {exc}") from exc


async def find_camera(pattern: str, timeout: float):
    devices = await BleakScanner.discover(timeout=timeout)
    named = [d for d in devices if d.name]
    matched = [d for d in named if re.search(pattern, d.name, re.IGNORECASE)]
    if matched:
        return matched[0]
    seen = ", ".join(sorted({d.name for d in named})) or "none"
    raise RuntimeError(
        f"no BLE camera matching {pattern!r}; discovered: {seen}\n"
        "       camera awake? USB unplugged (USB disables BLE)? "
        "not paired yet -> run with --pair while the camera is in pairing mode"
    )


async def enable_ap(pattern: str, timeout: float, pair: bool,
                    band: str) -> tuple[str, str, str]:
    device = await find_camera(pattern, timeout)
    print(f"connecting to {device.name} ({device.address})", file=sys.stderr)

    client = BleakClient(device, timeout=20)
    try:
        await client.connect()
    except BleakError as exc:
        raise RuntimeError(
            f"BLE connect failed: {exc}\n"
            "       if this is the first run, put the camera in pairing mode and use --pair"
        ) from exc

    try:
        if pair:
            print("pairing (bonding) with the camera", file=sys.stderr)
            try:
                await client.pair()
            except NotImplementedError:
                pass  # macOS pairs implicitly
            except BleakError as exc:
                raise RuntimeError(
                    f"pairing failed: {exc}\n"
                    "       is the camera in pairing mode (Preferences -> Connections -> "
                    "Wireless Connections)?"
                ) from exc
            print("paired", file=sys.stderr)

        channel = Channel(client)
        await channel.subscribe()

        current_band = await channel.status(STATUS_WIRELESS_BAND)
        current_ap = await channel.status(STATUS_AP_MODE)
        print(f"camera band={current_band} ap_mode={current_ap}", file=sys.stderr)

        want_band = {"2.4": 0, "5": 1}.get(band)
        if want_band is not None and want_band != current_band:
            await channel.request(SETTING_REQ,
                                  bytes([0x03, SETTING_WIRELESS_BAND, 0x01, want_band]),
                                  "set wireless band")
            print(f"wireless band set to {band} GHz", file=sys.stderr)
            current_band = want_band
            # The running AP keeps the old band until it is bounced.
            if current_ap == 1:
                await channel.request(COMMAND_REQ, CMD_BOUNCE, "bounce AP")
                current_ap = 0
            await asyncio.sleep(1)

        if current_ap != 1:
            await channel.request(COMMAND_REQ, CMD_ENABLE, "enable AP")

        for _ in range(15):
            if await channel.status(STATUS_AP_MODE) == 1:
                break
            await asyncio.sleep(1)
        else:
            raise RuntimeError("camera did not report the AP as enabled")

        ssid = await channel.read_char(WIFI_AP_SSID, "read SSID")
        password = await channel.read_char(WIFI_AP_PASSWORD, "read password")
        band_name = "5" if current_band == 1 else "2.4"
        return ssid, password, band_name
    finally:
        try:
            await client.disconnect()
        except BleakError:
            pass


async def main() -> int:
    parser = argparse.ArgumentParser(description="Enable a GoPro Wi-Fi AP over BLE")
    parser.add_argument("--pair", action="store_true",
                        help="bond with the camera (first run, camera in pairing mode)")
    parser.add_argument("--timeout", type=float, default=10,
                        help="BLE scan timeout in seconds (default: 10)")
    parser.add_argument("--name", default=r"GoPro|HERO|MAX",
                        help="regex for the advertised BLE name")
    parser.add_argument("--band", choices=("keep", "2.4", "5"), default="keep",
                        help="wireless band to use (default: keep the camera setting)")
    args = parser.parse_args()

    try:
        ssid, password, band = await enable_ap(args.name, args.timeout, args.pair, args.band)
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(f"SSID={ssid}")
    print(f"PASSWORD={password}")
    print(f"BAND={band}")
    print("AP_MODE=1")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
