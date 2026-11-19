import Foundation

/// Holds the heart rate near a target during a workout by moving the speed, the incline or both in small,
/// slow steps on top of the workout's own plan. Pure logic with the time passed in, so it is tested on every
/// build against a simulated heart (a delayed response to speed and incline).
///
/// - Every 15 s (speed) or 30 s (incline) at most one step: 0.1 mph (0.2 if the error is over 8 bpm) or 0.5%
///   incline (1% over 12 bpm), only when the 10-second average is more than 3 bpm from the target.
/// - Never beyond the limits it is given (the workout's top speed, the deck's incline and the speed/incline cap).
/// - No signal: no change. A change made by the user pauses it for 45 s and becomes the new starting point.
struct HeartRateHold {
    enum Control: String, CaseIterable, Identifiable {
        case speed = "Speed"
        case incline = "Incline"
        case both = "Both"

        var id: String { rawValue }
    }

    struct Limits {
        var minMph: Double
        var maxMph: Double
        var maxIncline: Double
    }

    enum Action: Equatable {
        case none
        /// The amounts the offsets just moved by, and a sentence for the screen and the log
        case change(speed: Double, incline: Double, text: String)
        case warn(String)
    }

    var target: Int
    var control: Control
    private(set) var speedOffset = 0.0
    private(set) var inclineOffset = 0.0
    private var lastAdjust = Date.distantPast
    private var pausedUntil = Date.distantPast
    private var window: [(at: Date, bpm: Int)] = []
    private var lastReadingAt = Date.distantPast

    init(target: Int, control: Control) {
        self.target = target
        self.control = control
    }

    /// Feed every new reading (readings with an old or repeated time stamp are ignored).
    mutating func add(bpm: Int, at time: Date) {
        guard time > lastReadingAt, bpm > 0 else { return }
        lastReadingAt = time
        window.append((time, bpm))
        window.removeAll { time.timeIntervalSince($0.at) > 30 }
    }

    /// Average of the readings of the last 10 seconds (at least 3 of them), or nil.
    func smoothed(now: Date) -> Double? {
        let recent = window.filter { now.timeIntervalSince($0.at) <= 10 }
        guard recent.count >= 3 else { return nil }
        return Double(recent.reduce(0) { $0 + $1.bpm }) / Double(recent.count)
    }

    func effectiveMph(base: Double) -> Double { base + speedOffset }
    func effectiveIncline(base: Double) -> Double { base + inclineOffset }

    /// The user changed speed or incline by hand: wait 45 s before adjusting again.
    mutating func userChanged(at now: Date) {
        pausedUntil = now.addingTimeInterval(45)
    }

    /// After a manual change, the new value becomes the starting point (offsets relative to the plan).
    mutating func rebase(speedOffset: Double? = nil, inclineOffset: Double? = nil) {
        if let speedOffset { self.speedOffset = speedOffset }
        if let inclineOffset { self.inclineOffset = inclineOffset }
    }

    mutating func evaluate(now: Date, baseMph: Double, baseIncline: Double, limits: Limits, signalFresh: Bool) -> Action {
        guard signalFresh else { return .warn("Heart-rate signal lost. Holding the current speed and incline.") }
        guard now >= pausedUntil, let bpm = smoothed(now: now) else { return .none }
        let error = bpm - Double(target)
        guard abs(error) > 3 else { return .none }
        let period: TimeInterval = control == .incline ? 30 : 15
        guard now.timeIntervalSince(lastAdjust) >= period else { return .none }

        let up = error < 0
        var speedStep = abs(error) > 8 ? 0.2 : 0.1
        var inclineStep = abs(error) > 12 ? 1.0 : 0.5
        if error > 25 {
            speedStep = 0.3
            inclineStep = 1.0
        }
        let direction = up ? 1.0 : -1.0
        let speedNow = baseMph + speedOffset
        let inclineNow = baseIncline + inclineOffset

        func speedRoom() -> Bool {
            let value = speedNow + direction * speedStep
            return value >= limits.minMph - 0.001 && value <= limits.maxMph + 0.001
        }
        func inclineRoom() -> Bool {
            let value = inclineNow + direction * inclineStep
            return value >= -0.001 && value <= min(limits.maxIncline, SafetyCheck.inclineCap(forMph: speedNow)) + 0.001
        }

        var changeSpeed = false
        var changeIncline = false
        switch control {
        case .speed: changeSpeed = speedRoom()
        case .incline: changeIncline = inclineRoom()
        case .both:
            if up {
                if inclineRoom() { changeIncline = true } else if speedRoom() { changeSpeed = true }
            } else {
                if speedRoom() { changeSpeed = true } else if inclineRoom() { changeIncline = true }
            }
        }
        guard changeSpeed || changeIncline else {
            return abs(error) > 10
                ? .warn(String(format: "Heart rate %d, target %d: no more room to %@ within this workout's limits.",
                               Int(bpm.rounded()), target, up ? "speed up" : "slow down"))
                : .none
        }

        var dSpeed = 0.0
        var dIncline = 0.0
        if changeSpeed { dSpeed = direction * speedStep }
        if changeIncline { dIncline = direction * inclineStep }
        // A faster belt may need a lower incline (above 3.5 mph at most 8%, above 4.5 mph at most 6%)
        let cap = min(limits.maxIncline, SafetyCheck.inclineCap(forMph: speedNow + dSpeed))
        if inclineNow + dIncline > cap { dIncline = cap - inclineNow }

        speedOffset += dSpeed
        inclineOffset += dIncline
        lastAdjust = now
        var parts: [String] = []
        if abs(dSpeed) > 0.001 { parts.append(String(format: "speed %@%.1f mph", dSpeed > 0 ? "+" : "−", abs(dSpeed))) }
        if abs(dIncline) > 0.001 { parts.append(String(format: "incline %@%.1f%%", dIncline > 0 ? "+" : "−", abs(dIncline))) }
        var text = String(format: "Heart rate %d, target %d: %@", Int(bpm.rounded()), target, parts.joined(separator: ", "))
        if error > 25 { text += ". That is far above the target: slow down or stop if you feel unwell" }
        return .change(speed: dSpeed, incline: dIncline, text: text)
    }
}
