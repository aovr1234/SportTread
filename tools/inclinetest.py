"""Remote start at 1 mph, incline 0 -> 2% -> 0, then remote stop (speed 0).

Usage: python inclinetest.py 59420
"""
import asyncio
import time

from bleak import BleakClient

import listen
import speedtest as st

MAX_INCLINE = 3.0   # % hard cap for this test
TARGET_INCLINE = 2.0
SETTLE = 20         # seconds to wait for the incline motor


def incline_frames(pct: float) -> list[bytes]:
    if not 0 <= pct <= MAX_INCLINE:
        raise ValueError(f"refusing incline {pct}% (cap {MAX_INCLINE})")
    v = round(pct * 100)
    w = bytearray.fromhex("ff 0d 02 04 02 09 04 09 02 01 02 00 00 00 00 00 00 00 00 00")
    w[11] = v & 0xFF
    w[12] = (v >> 8) & 0xFF
    w[14] = (w[11] + w[12] + 0x12) & 0xFF  # 505 CST incline checksum base (QZ forceIncline)
    return [bytes.fromhex("fe 02 0d 02"), bytes(w)]


def stop_frames() -> list[bytes]:
    # QZ stop/pause = forceSpeed(0)
    w = bytearray.fromhex("ff 0d 02 04 02 09 04 09 02 01 01 00 00 00 11 00 00 00 00 00")
    return [bytes.fromhex("fe 02 0d 02"), bytes(w)]


async def send(c: BleakClient, label: str, frames: list[bytes]):
    print(f"-- >> {label}", flush=True)
    for f in frames:
        await c.write_gatt_char(listen.TX, f, response=True)


async def wait_incline(c: BleakClient, pct: float):
    end = time.monotonic() + SETTLE
    while time.monotonic() < end:
        await st.poll_for(c, 1)
        if st.state["incline"] is not None and abs(st.state["incline"] - pct) < 0.05:
            print(f"-- incline reached {st.state['incline']}%", flush=True)
            await st.poll_for(c, 3)
            return
    print(f"-- incline did not reach {pct}% within {SETTLE}s (last {st.state['incline']}%)", flush=True)


async def main():
    incline_frames(TARGET_INCLINE), st.speed_frames(st.RESTORE)  # validate before connecting
    async with BleakClient(listen.ADDR, timeout=20.0) as c:
        await c.start_notify(listen.RX, st.on_notify)
        print(f"-- handshake ({st.PROFILE})", flush=True)
        for p in st.INIT:
            await c.write_gatt_char(listen.TX, p, response=True)
            await asyncio.sleep(0.6)
        await st.poll_for(c, 2)

        await send(c, "start sequence", st.START)
        await st.poll_for(c, 1)
        await send(c, "speed 1.0 mph", st.speed_frames(st.RESTORE))
        st.state["hits"].clear()
        deadline = time.monotonic() + 15
        while not st.belt_running():
            if time.monotonic() > deadline:
                print("-- belt did not start; sending stop and exiting")
                await send(c, "stop", stop_frames())
                return
            await st.poll_for(c, 1)

        try:
            await send(c, f"incline {TARGET_INCLINE}%", incline_frames(TARGET_INCLINE))
            await wait_incline(c, TARGET_INCLINE)
            await send(c, "incline 0%", incline_frames(0))
            await wait_incline(c, 0)
        finally:
            await send(c, "stop (speed 0)", stop_frames())
            await st.poll_for(c, 8)
        print(f"-- done; last reading speed={st.state['speed']} km/h incline={st.state['incline']}%")
        await c.stop_notify(listen.RX)


if __name__ == "__main__":
    asyncio.run(main())
