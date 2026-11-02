"""Handshake + status poll using QZ's default I_TL profile. Sends no speed/incline commands."""
import asyncio
import sys
import time
from bleak import BleakClient

ADDR = "D8:68:E9:E2:0D:E4"
TX = "00001534-1412-efde-1523-785feabcd123"
RX = "00001535-1412-efde-1523-785feabcd123"
SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 30

H = bytes.fromhex
Z10 = " 00" * 10
# initData1..12 from QZ btinit() default branch, in the order QZ writes them
I1 = H("fe 02 08 02")
I5 = H("fe 02 0a 02")
INIT = [
    I1, H("ff 08 02 04 02 04 02 04 81 87" + Z10),
    I1, H("ff 08 02 04 02 04 07 04 80 8b" + Z10),
    I1, H("ff 08 02 04 02 04 07 04 88 93" + Z10),
    I5, H("ff 0a 02 04 02 06 02 06 82 00 00 8a 00 00 00 00 00 00 00 00"),
    I5, H("ff 0a 02 04 02 06 02 06 84 00 00 8c 00 00 00 00 00 00 00 00"),
    I1, H("ff 08 02 04 02 04 02 04 95 9b" + Z10),
    H("fe 02 2c 04"),
    H("00 12 02 04 02 28 07 28 90 07 01 10 cc 7a 3e f4 b8 66 3a f8"),
    H("01 12 b4 72 46 1c f0 be 92 40 3c ea ce a4 88 76 4a 28 04 e2"),
    H("ff 08 f6 cc e0 98 02 00 00 d1" + Z10),
]
# noOpData1..7 from QZ update() default branch
POLL = [
    H("fe 02 19 03"),
    H("00 12 02 04 02 15 07 15 02 00 0f bc 90 70 00 00 00 40 00 00"),
    H("ff 07 00 00 00 10 00 08 5d 00" + Z10),
    H("fe 02 17 03"),
    H("00 12 02 04 02 13 07 13 02 00 0d 3c 9c 31 00 00 40 40 00 80"),
    H("ff 05 00 80 01 00 a9 00 00 00" + Z10),
    H("fe 02 0d 02"),
]

# QZ proform_treadmill_505_cst: btinit() initData1..25 and update() noOpData1..6
INIT_505 = [
    I1, H("ff 08 02 04 02 04 02 04 81 87" + Z10),
    I1, H("ff 08 02 04 02 04 04 04 80 88" + Z10),
    I1, H("ff 08 02 04 02 04 04 04 88 90" + Z10),
    I5, H("ff 0a 02 04 02 06 02 06 82 00 00 8a 00 00 00 00 00 00 00 00"),
    I5, H("ff 0a 02 04 02 06 02 06 84 00 00 8c 00 00 00 00 00 00 00 00"),
    I1, H("ff 08 02 04 02 04 02 04 95 9b" + Z10),
    H("fe 02 2c 04"),
    H("00 12 02 04 02 28 04 28 90 04 00 e1 d8 dd d0 d1 d0 d5 e8 e1"),
    H("01 12 f8 0d 00 11 20 55 48 61 98 bd d0 f1 10 35 48 61 b8 cd"),
    H("ff 08 e0 31 40 80 02 00 00 f5" + Z10),
    H("fe 02 19 03"),
    H("00 12 02 04 02 15 04 15 02 0e 00 00 00 00 00 00 00 00 00 00"),
    H("ff 07 00 00 00 10 01 00 3a 00" + Z10),
    H("fe 02 17 03"),
    H("00 12 02 04 02 13 04 13 02 0c 00 00 00 00 00 00 00 00 00 00"),
    H("ff 05 00 80 00 00 a5 00 00 00" + Z10),
    H("fe 02 17 03"),
    H("00 12 02 04 02 13 04 13 02 00 0d 00 10 00 d8 1c 48 00 00 e0"),
    H("ff 05 00 00 00 10 62 00 00 00" + Z10),
]
POLL_505 = [
    H("fe 02 17 03"),
    H("00 12 02 04 02 13 04 13 02 00 0d 80 0a 40 00 00 00 00 00 00"),
    H("ff 05 00 00 00 80 70 00 00 00" + Z10),
    H("fe 02 17 03"),
    H("00 12 02 04 02 13 04 13 02 00 0d 1b 94 31 00 00 40 50 00 80"),
    H("ff 05 18 00 00 01 2f 00 00 00" + Z10),
]
# QZ proform_505_cst_80_44: btinit() initData1..16 + noOpData1..12; polls from update()
POLL_8044 = [
    H("fe 02 17 03"),
    H("00 12 02 04 02 13 04 13 02 00 0d 80 0a 40 00 00 00 00 00 00"),
    H("ff 05 00 00 00 80 70 00 00 00" + Z10),
    H("fe 02 17 03"),
    H("00 12 02 04 02 13 04 13 02 00 0d 1b 94 31 00 00 40 50 00 80"),
    H("ff 05 18 00 00 01 2f 00 00 00" + Z10),
]
INIT_8044 = INIT_505[:13] + [
    H("00 12 02 04 02 28 04 28 90 04 00 36 a4 08 7a ea 68 dc 46 ce"),
    H("01 12 4c b0 32 b2 50 d4 5e c6 74 f8 6a 1a b8 2c d6 7e 1c 80"),
    H("ff 08 22 c2 a0 80 02 00 00 50" + Z10),
    H("fe 02 17 03"),
    H("00 12 02 04 02 13 04 13 02 0c 00 00 00 00 00 00 00 00 00 00"),
    H("ff 05 00 80 00 00 a5 00 00 00" + Z10),
    H("fe 02 19 03"),
    H("00 12 02 04 02 15 04 15 02 0e 00 00 00 00 00 00 00 00 00 00"),
    H("ff 07 00 00 00 10 01 00 3a 00" + Z10),
] + POLL_8044

# QZ proform_treadmill_cst_505_pftl59420_0 (captured from the iFit app): init_001..035
INIT_59420 = [
    I1, H("ff 08 02 04 02 04 02 04 81 87" + Z10),
    I1, H("ff 08 02 04 02 04 04 04 80 88" + Z10),
    I1, H("ff 08 02 04 02 04 04 04 88 90" + Z10),
    H("fe 02 0b 02"), H("ff 0b 02 04 02 07 02 07 82 00 00 00 8b 00 00 00 00 00 00 00"),
    I5, H("ff 0a 02 04 02 06 02 06 84 00 00 8c 00 00 00 00 00 00 00 00"),
    I1, H("ff 08 02 04 02 04 02 04 95 9b" + Z10),
    H("fe 02 2c 04"),
    H("00 12 02 04 02 28 04 28 90 07 01 59 78 a5 c0 e9 10 4d 78 a9"),
    H("01 12 d8 05 30 79 a0 fd 38 79 b8 e5 20 69 d0 0d 78 a9 18 45"),
    H("ff 08 b0 19 40 98 02 00 00 59" + Z10),
    H("fe 02 19 03"),
    H("00 12 02 04 02 15 04 15 02 0e 00 00 00 00 00 00 00 00 00 00"),
    H("ff 07 00 00 00 10 01 00 3a 00" + Z10),
    H("fe 02 17 03"),
    H("00 12 02 04 02 13 04 13 02 0c 00 00 00 00 00 00 00 00 00 00"),
    H("ff 05 00 80 00 00 a5 00 00 00" + Z10),
    H("fe 02 19 03"),
    H("00 12 02 04 02 15 04 15 02 00 0f 00 10 00 d8 1c 48 00 00 e0"),
    H("ff 07 00 00 00 10 00 08 6e 00" + Z10),
    H("fe 02 14 03"),
    H("00 12 02 04 02 10 04 10 02 00 0a 13 94 33 00 10 40 10 00 80"),
    H("ff 02 18 f2 00 00 00 00 00 00" + Z10),
    H("fe 02 10 02"),
    H("ff 10 02 04 02 0c 04 0c 02 04 00 00 00 02 35 25 00 72 00 00"),
    H("fe 02 19 03"),
    H("00 12 02 04 02 15 04 15 02 0e 00 00 00 00 00 00 00 00 00 00"),
    H("ff 07 00 00 00 10 01 00 3a 00" + Z10),
    H("fe 02 10 02"),
    H("ff 10 02 04 02 0c 04 0c 02 05 00 00 00 00 10 00 00 27 00 00"),
]
POLL_59420 = [
    H("fe 02 19 03"),
    H("00 12 02 04 02 15 04 15 02 00 0f 80 02 40 00 00 00 00 00 00"),
    H("ff 07 00 00 00 95 00 10 91 00" + Z10),
    H("fe 02 14 03"),
    H("00 12 02 04 02 10 04 10 02 00 0a 13 94 33 00 10 40 10 00 80"),
    H("ff 02 18 f2 00 00 00 00 00 00" + Z10),
]

PROFILES = {
    "default": (INIT, POLL),
    "505cst": (INIT_505, POLL_505),
    "8044": (INIT_8044, POLL_8044),
    "59420": (INIT_59420, POLL_59420),
}
PROFILE = sys.argv[2] if len(sys.argv) > 2 else "505cst"

t0 = time.monotonic()


def on_notify(_, data: bytearray):
    line = f"{time.monotonic() - t0:6.2f} << {data.hex(' ')}"
    # QZ's status frame: 00 12 01 04 02 .. speed@10-11, incline@12-13 (little-endian /100)
    if len(data) == 20 and data[:4] == b"\x00\x12\x01\x04" and data[4] == 0x02:
        speed = int.from_bytes(data[10:12], "little") / 100
        incline = int.from_bytes(data[12:14], "little", signed=True) / 100
        line += f"   [type {data[5]:02x}] speed={speed:.2f} km/h incline={incline:.2f}%"
    print(line, flush=True)


async def main():
    init, poll = PROFILES[PROFILE]
    for p in init + poll:
        assert len(p) in (4, 20), (p.hex(), len(p))
    async with BleakClient(ADDR, timeout=20.0) as c:
        await c.start_notify(RX, on_notify)
        print(f"-- handshake ({PROFILE})")
        for p in init:
            await c.write_gatt_char(TX, p, response=True)
            await asyncio.sleep(0.6)
        print("-- polling")
        i = 0
        while time.monotonic() - t0 < SECONDS:
            await c.write_gatt_char(TX, poll[i % len(poll)], response=True)
            i += 1
            await asyncio.sleep(0.2)
        await c.stop_notify(RX)


if __name__ == "__main__":
    asyncio.run(main())
