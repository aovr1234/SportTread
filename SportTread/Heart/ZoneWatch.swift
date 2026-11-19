import Foundation

/// Watches the heart rate against a zone and says when the workout looks too easy (below the zone for
/// 4 minutes) or too hard (above it for 2 minutes). At most one verdict every 5 minutes; no signal or being in
/// the zone starts the count again. Pure logic with the time passed in, tested on every build.
struct ZoneWatch {
    enum Verdict: Equatable {
        case tooEasy
        case tooHard
    }

    var zone: Int
    private var window: [(at: Date, bpm: Int)] = []
    private var lastReadingAt = Date.distantPast
    private var belowSince: Date?
    private var aboveSince: Date?
    private var lastVerdictAt = Date.distantPast

    static let easySeconds: TimeInterval = 240
    static let hardSeconds: TimeInterval = 120
    static let quietSeconds: TimeInterval = 300

    init(zone: Int) {
        self.zone = zone
    }

    mutating func add(bpm: Int, at time: Date) {
        guard time > lastReadingAt, bpm > 0 else { return }
        lastReadingAt = time
        window.append((time, bpm))
        window.removeAll { time.timeIntervalSince($0.at) > 30 }
    }

    private func smoothed(now: Date) -> Double? {
        let recent = window.filter { now.timeIntervalSince($0.at) <= 10 }
        guard recent.count >= 3 else { return nil }
        return Double(recent.reduce(0) { $0 + $1.bpm }) / Double(recent.count)
    }

    mutating func evaluate(now: Date, zones: HeartZones, signalFresh: Bool) -> Verdict? {
        guard signalFresh, let bpm = smoothed(now: now) else {
            belowSince = nil
            aboveSince = nil
            return nil
        }
        let range = zones.range(zone)
        if bpm < range.lowerBound {
            aboveSince = nil
            if belowSince == nil { belowSince = now }
            if let since = belowSince, now.timeIntervalSince(since) >= Self.easySeconds,
               now.timeIntervalSince(lastVerdictAt) >= Self.quietSeconds {
                lastVerdictAt = now
                belowSince = nil
                return .tooEasy
            }
        } else if bpm > range.upperBound {
            belowSince = nil
            if aboveSince == nil { aboveSince = now }
            if let since = aboveSince, now.timeIntervalSince(since) >= Self.hardSeconds,
               now.timeIntervalSince(lastVerdictAt) >= Self.quietSeconds {
                lastVerdictAt = now
                aboveSince = nil
                return .tooHard
            }
        } else {
            belowSince = nil
            aboveSince = nil
        }
        return nil
    }
}
