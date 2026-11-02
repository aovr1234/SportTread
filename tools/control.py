"""At-will treadmill controller for the ProForm 505 CST (QZ PFTL59420 profile).

Stays connected and executes one command per line appended to cmds.txt:
    start            remote start (belt goes to 1.0 mph)
    speed <mph>      e.g. speed 3
    incline <pct>    e.g. incline 5
    stop             pause mode (belt stops)
    quit             stop if running, then disconnect
Prints a status line whenever speed/incline changes. Always pauses the belt on exit.

Usage: python control.py 59420
"""
import asyncio
import pathlib
import time

from bleak import BleakClient

import inclinetest as it
import listen
import speedtest as st
import stoptest as sp

MAX_MPH = 6.0
MAX_INCLINE = 10.0
KMH_PER_MPH = 1.609344
st.MAX_KMH = MAX_MPH * KMH_PER_MPH
it.MAX_INCLINE = MAX_INCLINE

CMDS = pathlib.Path(__file__).with_name("cmds.txt")
t0 = time.monotonic()
last = {"shown": None}


def log(msg: str):
    print(f"{time.monotonic() - t0:6.1f} {msg}", flush=True)


def on_notify(_, data: bytearray):
    # Same status parsing as speedtest.on_notify, without the raw dump
    if len(data) == 20 and data[:5] == b"\x00\x12\x01\x04\x02" and data[5] != 0x20 and data[9] == 0x02:
        speed = int.from_bytes(data[10:12], "little") / 100
        incline = int.from_bytes(data[12:14], "little", signed=True) / 100
        st.state["speed"], st.state["incline"] = speed, incline
        if st.RUNNING_RANGE[0] <= speed <= st.RUNNING_RANGE[1]:
            st.state["hits"].append(speed)
        else:
            st.state["hits"].clear()
        shown = (speed, incline)
        if shown != last["shown"]:
            last["shown"] = shown
            log(f"status: {speed / KMH_PER_MPH:.1f} mph ({speed:.2f} km/h), incline {incline:.1f}%")
    elif len(data) == 20 and data[:5] == b"\xff\x09\x01\x04\x02" and data[9] != 0x02:
        log(f"!! command refused (status {data[9]:02x})")


async def write(c: BleakClient, frames: list[bytes]):
    for f in frames:
        await c.write_gatt_char(listen.TX, f, response=True)


async def run_command(c: BleakClient, line: str) -> bool:
    parts = line.split()
    if not parts:
        return True
    cmd, arg = parts[0].lower(), (parts[1] if len(parts) > 1 else None)
    log(f">> {line}")
    try:
        if cmd == "start":
            await write(c, st.START)
            await st.poll_for(c, 1)
            await write(c, st.speed_frames(st.RESTORE))
            st.state["hits"].clear()
            deadline = time.monotonic() + 15
            while not st.belt_running() and time.monotonic() < deadline:
                await st.poll_for(c, 1)
            log("belt running" if st.belt_running() else "!! belt did not start")
        elif cmd == "speed":
            await write(c, st.speed_frames(float(arg) * KMH_PER_MPH))
        elif cmd == "incline":
            await write(c, it.incline_frames(float(arg)))
        elif cmd == "stop":
            await write(c, sp.mode_frames(0x03))
        elif cmd == "quit":
            return False
        else:
            log(f"!! unknown command {line!r}")
    except (ValueError, TypeError) as e:
        log(f"!! rejected: {e}")
    return True


async def main():
    CMDS.write_text("")
    pos = 0
    async with BleakClient(listen.ADDR, timeout=20.0) as c:
        await c.start_notify(listen.RX, on_notify)
        log(f"handshake ({st.PROFILE})")
        for p in st.INIT:
            await c.write_gatt_char(listen.TX, p, response=True)
            await asyncio.sleep(0.6)
        log(f"ready; caps {MAX_MPH} mph / {MAX_INCLINE}% ; reading {CMDS.name}")
        try:
            running = True
            while running:
                await st.poll_for(c, 0.6)
                text = CMDS.read_text()
                new, pos = text[pos:], len(text)
                for line in new.splitlines():
                    if not await run_command(c, line.strip()):
                        running = False
                        break
        finally:
            if (st.state["speed"] or 0) > 0:
                log("pausing belt before disconnect")
                await write(c, sp.mode_frames(0x03))
                await st.poll_for(c, 3)
            log("disconnected")


if __name__ == "__main__":
    asyncio.run(main())
