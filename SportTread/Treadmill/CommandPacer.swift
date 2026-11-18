import Foundation

/// The rules for sending speed and incline commands, with no Bluetooth in it so they are tested on every
/// build (Tests/LengthTests/main.swift):
/// - each kind goes out at most once a second, the first one at once, and the latest value always wins;
/// - a command is remembered until the treadmill's readings confirm it, because the console sometimes
///   accepts an incline and then drops it (seen after Start, with no refusal);
/// - a reading that falls back to the value from before the command means it didn't take, so it is sent
///   again, up to 3 more times; then the caller is told it failed;
/// - a reading that moved somewhere else is a change made on the console and is never fought.
/// Every function takes the time as a parameter, so tests can replay a situation second by second.
struct CommandPacer {
    enum Send: Equatable {
        case speed(Double)
        case incline(Double)
    }

    struct Want {
        var value: Double
        var sends = 0
        var sentAt = Date.distantFuture
        /// The reading when the command first went out
        var before = 0.0
        var watchUntil = Date.distantFuture
    }

    static let cooldown: TimeInterval = 1
    /// The first send plus 3 resends
    static let maxSends = 4

    private(set) var pendingSpeed: Double?
    private(set) var pendingIncline: Double?
    private(set) var wantSpeed: Want?
    private(set) var wantIncline: Want?
    private var lastSpeedSend = Date.distantPast
    private var lastInclineSend = Date.distantPast
    private var startedAt = Date.distantPast

    init() {}

    /// Drops everything waiting and stops checking earlier commands (Stop, a new Start, a lost connection).
    mutating func clear() {
        pendingSpeed = nil
        pendingIncline = nil
        wantSpeed = nil
        wantIncline = nil
    }

    /// The belt was just started: the console may drop commands for a few seconds, so they are watched longer.
    mutating func markStart(_ now: Date) {
        startedAt = now
    }

    mutating func requestSpeed(_ mph: Double) {
        pendingSpeed = mph
        wantSpeed = Want(value: mph)
    }

    mutating func requestIncline(_ percent: Double) {
        pendingIncline = percent
        wantIncline = Want(value: percent)
    }

    /// The next speed or incline command that is due, if any. Call it only between poll messages.
    mutating func next(now: Date, speedReading: Double?, inclineReading: Double?) -> Send? {
        if let mph = pendingSpeed, now.timeIntervalSince(lastSpeedSend) >= Self.cooldown {
            pendingSpeed = nil
            lastSpeedSend = now
            if var want = wantSpeed, abs(want.value - mph) < 0.001 {
                if want.sends == 0 { want.before = speedReading ?? 0 }
                want.sends += 1
                want.sentAt = now
                want.watchUntil = max(now.addingTimeInterval(8), startedAt.addingTimeInterval(12))
                wantSpeed = want
            }
            return .speed(mph)
        }
        if let percent = pendingIncline, now.timeIntervalSince(lastInclineSend) >= Self.cooldown {
            pendingIncline = nil
            lastInclineSend = now
            if var want = wantIncline, abs(want.value - percent) < 0.001 {
                if want.sends == 0 { want.before = inclineReading ?? 0 }
                want.sends += 1
                want.sentAt = now
                want.watchUntil = max(now.addingTimeInterval(8), startedAt.addingTimeInterval(12))
                wantIncline = want
            }
            return .incline(percent)
        }
        return nil
    }

    /// Compares the readings with the commands. Returns a message when a command had to be given up on.
    mutating func verify(now: Date, speedReading: Double?, inclineReading: Double?) -> String? {
        var problem: String?
        if let want = wantSpeed, want.sentAt != .distantFuture {
            let reading = speedReading ?? 0
            if now > want.watchUntil {
                wantSpeed = nil
            } else if pendingSpeed == nil, reading > 0, now.timeIntervalSince(want.sentAt) >= 3,
                      abs(reading - want.value) >= 0.15, abs(reading - want.before) < 0.1 {
                problem = resend(speed: true, want)
            }
        }
        if let want = wantIncline, want.sentAt != .distantFuture {
            let reading = inclineReading ?? 0
            if now > want.watchUntil {
                wantIncline = nil
            } else if pendingIncline == nil, now.timeIntervalSince(want.sentAt) >= 2.5,
                      abs(reading - want.value) >= 0.25, abs(reading - want.before) < 0.25 {
                problem = resend(speed: false, want) ?? problem
            }
        }
        return problem
    }

    /// The console refused a command: if one went out in the last 3 seconds, send it again.
    mutating func refused(now: Date) -> String? {
        var problem: String?
        if let want = wantSpeed, pendingSpeed == nil, want.sentAt != .distantFuture, now.timeIntervalSince(want.sentAt) < 3 {
            problem = resend(speed: true, want)
        }
        if let want = wantIncline, pendingIncline == nil, want.sentAt != .distantFuture, now.timeIntervalSince(want.sentAt) < 3 {
            problem = resend(speed: false, want) ?? problem
        }
        return problem
    }

    private mutating func resend(speed: Bool, _ want: Want) -> String? {
        if want.sends >= Self.maxSends {
            if speed {
                wantSpeed = nil
                return "Speed didn't take. Tap ▲ or ▼ to try again."
            }
            wantIncline = nil
            return "Incline didn't take. Tap ▲ or ▼ to try again."
        }
        if speed { pendingSpeed = want.value } else { pendingIncline = want.value }
        return nil
    }
}
