"""One slow speed change on a ProForm 505 CST, using QZ's forceSpeed() frame.

Only acts once the belt is already running (started from the console), raises it to
TARGET km/h, holds, then returns it to 1.6 km/h (1.0 mph). Never starts or stops the belt.
"""
import asyncio
import sys
import time

from bleak import BleakClient

import listen  # reuses ADDR, TX, RX, INIT_505, POLL_505, decoder

MAX_KMH = 5.0       # hard safety cap for this test (~3.1 mph)
TARGET = 4.83       # km/h (3.0 mph)
RESTORE = 1.6       # km/h (1.0 mph, console start speed)
HOLD = 12           # seconds at TARGET
WAIT_FOR_BELT = 120 # seconds to wait for the belt to be started on the console

PROFILE = sys.argv[1] if len(sys.argv) > 1 else "505cst"
REMOTE_START = "--start" in sys.argv
# QZ proform_treadmill_505_cst start1..start5 from update()
START = [
    bytes.fromhex("fe 02 20 03"),
    bytes.fromhex("00 12 02 04 02 1c 04 1c 02 09 00 00 40 02 18 40 00 00 80 30"),
    bytes.fromhex("ff 0e 2a 00 00 ef 1a 58 02 00 b4 00 58 02 00 10 00 00 00 00"),
    bytes.fromhex("fe 02 11 02"),
    bytes.fromhex("ff 11 02 04 02 0d 04 0d 02 02 03 10 a0 00 00 00 0a 00 d2 00"),
]
INIT, POLL = listen.PROFILES[PROFILE]
# Belt counts as running only after 3 identical readings in this window (console start = 1.6)
RUNNING_RANGE = (1.0, 2.0)

state = {"speed": None, "incline": None, "poll": 0, "hits": []}


def speed_frames(kmh: float) -> list[bytes]:
    if not 0 < kmh <= MAX_KMH:
        raise ValueError(f"refusing speed {kmh} km/h (cap {MAX_KMH})")
    v = round(kmh * 100)
    w = bytearray.fromhex("ff 0d 02 04 02 09 04 09 02 01 01 00 00 00 00 00 00 00 00 00")
    w[11] = v & 0xFF
    w[12] = (v >> 8) & 0xFF
    w[14] = (w[11] + w[12] + 0x11) & 0xFF  # 505 CST checksum base
    return [bytes.fromhex("fe 02 0d 02"), bytes(w)]


def on_notify(_, data: bytearray):
    listen.on_notify(_, data)
    if len(data) == 20 and data[:5] == b"\x00\x12\x01\x04\x02" and data[5] != 0x20 and data[9] == 0x02:
        speed = int.from_bytes(data[10:12], "little") / 100
        state["speed"] = speed
        state["incline"] = int.from_bytes(data[12:14], "little", signed=True) / 100
        if RUNNING_RANGE[0] <= speed <= RUNNING_RANGE[1]:
            state["hits"].append(speed)
        else:
            state["hits"].clear()


def belt_running() -> bool:
    h = state["hits"][-3:]
    return len(h) == 3 and len(set(h)) == 1


async def poll_for(c: BleakClient, seconds: float):
    # Each poll message is 3 frames (fe header, body, ff tail); the index persists across
    # calls and we only return on a message boundary so nothing gets split.
    end = time.monotonic() + seconds
    while time.monotonic() < end or state["poll"] % 3:
        i = state["poll"]
        await c.write_gatt_char(listen.TX, POLL[i % len(POLL)], response=True)
        state["poll"] = i + 1
        await asyncio.sleep(0.2)


async def send_speed(c: BleakClient, kmh: float):
    print(f"-- >> set speed {kmh:.2f} km/h ({kmh / 1.609:.2f} mph)", flush=True)
    for f in speed_frames(kmh):
        await c.write_gatt_char(listen.TX, f, response=True)


async def main():
    speed_frames(TARGET), speed_frames(RESTORE)  # validate before connecting
    async with BleakClient(listen.ADDR, timeout=20.0) as c:
        await c.start_notify(listen.RX, on_notify)
        print(f"-- handshake ({PROFILE})", flush=True)
        for p in INIT:
            await c.write_gatt_char(listen.TX, p, response=True)
            await asyncio.sleep(0.6)

        state["hits"].clear()
        deadline = time.monotonic() + WAIT_FOR_BELT
        if REMOTE_START:
            print("-- HOLD START NOW; remote start in 10 s", flush=True)
            await poll_for(c, 10)
            print("-- >> start sequence", flush=True)
            for f in START:
                await c.write_gatt_char(listen.TX, f, response=True)
                await asyncio.sleep(0.2)
            await poll_for(c, 1)
            await send_speed(c, RESTORE)
            deadline = time.monotonic() + 15
        print("-- waiting for belt to be running", flush=True)
        while not belt_running():
            if time.monotonic() > deadline:
                print("-- belt never started; no command sent")
                return
            await poll_for(c, 1)

        await poll_for(c, 3)
        await send_speed(c, TARGET)
        await poll_for(c, HOLD)
        await send_speed(c, RESTORE)
        await poll_for(c, 8)
        print(f"-- done; last reading speed={state['speed']} km/h incline={state['incline']}%")
        await c.stop_notify(listen.RX)


if __name__ == "__main__":
    asyncio.run(main())
