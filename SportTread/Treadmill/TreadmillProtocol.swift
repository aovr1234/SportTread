import Foundation

/// iFit Bluetooth protocol for the ProForm 505 CST, as verified on the user's treadmill (see PLAN.md §1
/// and tools/listen.py, tools/speedtest.py, tools/stoptest.py). Byte sequences come from QZ
/// (qdomyos-zwift): the proform_treadmill_cst_505_pftl59420_0 profile for the handshake and polls,
/// and proform_treadmill_505_cst for start.
enum TreadmillProtocol {
    static let serviceUUID = "00001533-1412-efde-1523-785feabcd123"
    static let txUUID = "00001534-1412-efde-1523-785feabcd123"   // write
    static let rxUUID = "00001535-1412-efde-1523-785feabcd123"   // notify

    static let kmhPerMph = 1.609344

    /// Hex string to bytes. Frames longer than a 4-byte header are zero-padded to 20 bytes.
    private static func h(_ hex: String) -> Data {
        var bytes = hex.split(separator: " ").map { UInt8($0, radix: 16)! }
        if bytes.count > 4 {
            bytes += [UInt8](repeating: 0, count: 20 - bytes.count)
        }
        return Data(bytes)
    }

    private static let i1 = "fe 02 08 02"
    private static let i5 = "fe 02 0a 02"

    /// Handshake, including the unlock key this console accepts. Sent once, 600 ms apart.
    static let initFrames: [Data] = ([
        i1, "ff 08 02 04 02 04 02 04 81 87",
        i1, "ff 08 02 04 02 04 04 04 80 88",
        i1, "ff 08 02 04 02 04 04 04 88 90",
        "fe 02 0b 02", "ff 0b 02 04 02 07 02 07 82 00 00 00 8b 00 00 00 00 00 00 00",
        i5, "ff 0a 02 04 02 06 02 06 84 00 00 8c 00 00 00 00 00 00 00 00",
        i1, "ff 08 02 04 02 04 02 04 95 9b",
        "fe 02 2c 04",
        "00 12 02 04 02 28 04 28 90 07 01 59 78 a5 c0 e9 10 4d 78 a9",
        "01 12 d8 05 30 79 a0 fd 38 79 b8 e5 20 69 d0 0d 78 a9 18 45",
        "ff 08 b0 19 40 98 02 00 00 59",
        "fe 02 19 03", "00 12 02 04 02 15 04 15 02 0e 00 00 00 00 00 00 00 00 00 00", "ff 07 00 00 00 10 01 00 3a 00",
        "fe 02 17 03", "00 12 02 04 02 13 04 13 02 0c 00 00 00 00 00 00 00 00 00 00", "ff 05 00 80 00 00 a5 00 00 00",
        "fe 02 19 03", "00 12 02 04 02 15 04 15 02 00 0f 00 10 00 d8 1c 48 00 00 e0", "ff 07 00 00 00 10 00 08 6e 00",
        "fe 02 14 03", "00 12 02 04 02 10 04 10 02 00 0a 13 94 33 00 10 40 10 00 80", "ff 02 18 f2 00 00 00 00 00 00",
        "fe 02 10 02", "ff 10 02 04 02 0c 04 0c 02 04 00 00 00 02 35 25 00 72 00 00",
        "fe 02 19 03", "00 12 02 04 02 15 04 15 02 0e 00 00 00 00 00 00 00 00 00 00", "ff 07 00 00 00 10 01 00 3a 00",
        "fe 02 10 02", "ff 10 02 04 02 0c 04 0c 02 05 00 00 00 00 10 00 00 27 00 00",
    ] as [String]).map(h)

    /// Two status polls of 3 frames each (header, body, tail). Never split one; commands go between them.
    static let pollFrames: [Data] = ([
        "fe 02 19 03",
        "00 12 02 04 02 15 04 15 02 00 0f 80 02 40 00 00 00 00 00 00",
        "ff 07 00 00 00 95 00 10 91 00",
        "fe 02 14 03",
        "00 12 02 04 02 10 04 10 02 00 0a 13 94 33 00 10 40 10 00 80",
        "ff 02 18 f2 00 00 00 00 00 00",
    ] as [String]).map(h)

    /// Starts the belt at 1.0 mph without pressing anything on the console.
    static let startFrames: [Data] = ([
        "fe 02 20 03",
        "00 12 02 04 02 1c 04 1c 02 09 00 00 40 02 18 40 00 00 80 30",
        "ff 0e 2a 00 00 ef 1a 58 02 00 b4 00 58 02 00 10 00 00 00 00",
        "fe 02 11 02",
        "ff 11 02 04 02 0d 04 0d 02 02 03 10 a0 00 00 00 0a 00 d2 00",
    ] as [String]).map(h)

    /// Single-message write: 6 command bytes at [8...13]; checksum = sum of bytes [6...13].
    private static func write6(_ bytes: [UInt8]) -> [Data] {
        var w = [UInt8](repeating: 0, count: 20)
        w.replaceSubrange(0..<8, with: [0xff, 0x0d, 0x02, 0x04, 0x02, 0x09, 0x04, 0x09])
        w.replaceSubrange(8..<14, with: bytes)
        w[14] = UInt8(truncatingIfNeeded: w[6..<14].reduce(0) { $0 + Int($1) })
        return [h("fe 02 0d 02"), Data(w)]
    }

    static func speedFrames(mph: Double) -> [Data] {
        let v = Int((mph * kmhPerMph * 100).rounded())
        return write6([0x02, 0x01, 0x01, UInt8(v & 0xff), UInt8(v >> 8), 0])
    }

    static func inclineFrames(percent: Double) -> [Data] {
        let v = Int((percent * 100).rounded())
        return write6([0x02, 0x01, 0x02, UInt8(v & 0xff), UInt8(v >> 8), 0])
    }

    /// Workout mode 3 (pause) stops the belt. Speed 0 and mode 1 are refused by this console.
    static let stopFrames = write6([0x02, 0x02, 0x00, 0x10, 0x03, 0x00])

    struct Status {
        var speedKmh: Double
        var incline: Double
    }

    /// Status reply: 00 12 01 04 02, type ≠ 0x20, status byte 0x02; speed at [10,11], incline at [12,13] (LE, /100).
    static func status(from d: Data) -> Status? {
        let b = [UInt8](d)
        guard b.count == 20, b[0] == 0x00, b[1] == 0x12, b[2] == 0x01, b[3] == 0x04, b[4] == 0x02,
              b[5] != 0x20, b[9] == 0x02 else { return nil }
        let speed = Double(Int(b[10]) | Int(b[11]) << 8) / 100
        let incline = Double(Int16(bitPattern: UInt16(b[12]) | UInt16(b[13]) << 8)) / 100
        return Status(speedKmh: speed, incline: incline)
    }

    /// Write reply with a status other than 0x02 (accepted): the console refused the command.
    static func refusal(from d: Data) -> UInt8? {
        let b = [UInt8](d)
        guard b.count == 20, b[0] == 0xff, b[1] == 0x09, b[2] == 0x01, b[3] == 0x04, b[4] == 0x02, b[9] != 0x02
        else { return nil }
        return b[9]
    }
}
