"""Remote start at 1 mph, run ~6 s, then QZ's mode-based stop (stop1/stop2 from the
proform_treadmill_9_0 branch). Reports whether the belt reading drops to 0.

Usage: python stoptest.py 59420
"""
import asyncio
import time

from bleak import BleakClient

import listen
import speedtest as st

# iFit write: checksum = sum of bytes from index 6 up to the checksum byte
STOP = [
    bytes.fromhex("fe 02 0f 02"),
    bytes.fromhex("ff 0f 02 04 02 0b 04 0b 02 02 02 10 00 00 01 00 26 00 00 00"),
]
assert sum(STOP[1][6:16]) & 0xFF == STOP[1][16]

# Candidate modes to try in order (field 12 only, like QZ's tlx_control_002): pause, finish
CANDIDATE_MODES = [0x03, 0x04]


def mode_frames(mode: int) -> list[bytes]:
    w = bytearray.fromhex("ff 0d 02 04 02 09 04 09 02 02 00 10 00 00 00 00 00 00 00 00")
    w[12] = mode
    w[14] = sum(w[6:14]) & 0xFF
    return [bytes.fromhex("fe 02 0d 02"), bytes(w)]


assert mode_frames(0x02)[1].hex() == "ff0d0204020904090202001002002300000000 00".replace(" ", "")


async def send(c: BleakClient, label: str, frames: list[bytes]):
    print(f"-- >> {label}", flush=True)
    for f in frames:
        await c.write_gatt_char(listen.TX, f, response=True)


async def main():
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
                print("-- belt did not start")
                break
            await st.poll_for(c, 1)
        await st.poll_for(c, 3)

        for mode in CANDIDATE_MODES:
            await send(c, f"mode {mode:#04x}", mode_frames(mode))
            end = time.monotonic() + 8
            while time.monotonic() < end and st.state["speed"] != 0:
                await st.poll_for(c, 1)
            if st.state["speed"] == 0:
                print(f"-- belt reading is 0: mode {mode:#04x} stopped it", flush=True)
                await st.poll_for(c, 3)
                break
            print(f"-- mode {mode:#04x}: belt still {st.state['speed']} km/h", flush=True)
        else:
            print("-- no candidate stopped the belt")
        print(f"-- done; last reading speed={st.state['speed']} km/h incline={st.state['incline']}%")
        await c.stop_notify(listen.RX)


if __name__ == "__main__":
    asyncio.run(main())
