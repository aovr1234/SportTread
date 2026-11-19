import Foundation

/// Reads the standard Bluetooth "Heart Rate Measurement" message (characteristic 0x2A37) that chest straps,
/// armbands and watch broadcasters send. Pure Foundation, so it is tested on every build.
enum HeartRateParser {
    struct Reading: Equatable {
        var bpm: Int
        /// Whether the sensor says it touches skin; nil when it doesn't report that
        var contact: Bool?
        /// Beat-to-beat intervals in milliseconds, when the sensor sends them
        var rr: [Double]
    }

    static func parse(_ data: Data) -> Reading? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let flags = bytes[0]
        let wide = flags & 0x01 != 0
        let contact = (flags >> 1) & 0x01 != 0
        let contactSupported = (flags >> 2) & 0x01 != 0
        let energy = (flags >> 3) & 0x01 != 0
        let hasIntervals = (flags >> 4) & 0x01 != 0

        var index = 1
        let bpm: Int
        if wide {
            guard bytes.count >= 3 else { return nil }
            bpm = Int(bytes[1]) | (Int(bytes[2]) << 8)
            index = 3
        } else {
            bpm = Int(bytes[1])
            index = 2
        }
        if energy { index += 2 }
        var intervals: [Double] = []
        if hasIntervals {
            while index + 1 < bytes.count {
                intervals.append(Double(Int(bytes[index]) | (Int(bytes[index + 1]) << 8)) / 1024 * 1000)
                index += 2
            }
        }
        return Reading(bpm: bpm, contact: contactSupported ? contact : nil, rr: intervals)
    }
}
