import Foundation

/// Exact-length arithmetic for workouts, and reading a length from text. Pure functions (Foundation
/// only) so they are tested on every build: Tests/LengthTests/main.swift.
enum LengthFit {
    /// Shortest step, in seconds.
    static let minStep = 30
    /// Step lengths are multiples of this many seconds.
    static let unit = 5

    /// Fits step durations to exactly `total` seconds (rounded down to a multiple of 5).
    /// Every step stays at least 30 s; when there are too many steps for that, the smallest inner
    /// steps are dropped and their time shared out. `kept` lists the surviving original indexes.
    /// Returns nil when not even one step fits.
    static func fit(_ seconds: [Int], to total: Int) -> (seconds: [Int], kept: [Int])? {
        let totalUnits = total / unit
        let floorUnits = minStep / unit
        guard !seconds.isEmpty, totalUnits >= floorUnits else { return nil }

        var kept = Array(seconds.indices)
        let secs = seconds.map { max(minStep, $0) }

        while kept.count * floorUnits > totalUnits, kept.count > 1 {
            let positions = kept.count > 2 ? Array(1..<(kept.count - 1)) : Array(kept.indices)
            let drop = positions.min { secs[kept[$0]] < secs[kept[$1]] }!
            kept.remove(at: drop)
        }

        let sum = Double(kept.reduce(0) { $0 + secs[$1] })
        let raw = kept.map { Double(secs[$0]) / sum * Double(totalUnits) }
        var units = raw.map { max(floorUnits, Int($0.rounded())) }
        var diff = totalUnits - units.reduce(0, +)
        while diff != 0 {
            if diff > 0 {
                let i = units.indices.max { raw[$0] - Double(units[$0]) < raw[$1] - Double(units[$1]) }!
                units[i] += 1
                diff -= 1
            } else {
                let candidates = units.indices.filter { units[$0] > floorUnits }
                guard let i = candidates.max(by: { Double(units[$0]) - raw[$0] < Double(units[$1]) - raw[$1] }) else { break }
                units[i] -= 1
                diff += 1
            }
        }
        return (units.map { $0 * unit }, kept)
    }
}

/// A length asked for in text.
enum LengthRequest: Equatable {
    case total(minutes: Int)      // "make it an hour"
    case remaining(minutes: Int)  // "20 minutes left"
    case add(minutes: Int)        // "add 5 minutes"
    case remove(minutes: Int)     // "cut 10 minutes"
}

enum LengthParser {
    /// The length mentioned in the text, in minutes: "1 hr", "an hour", "45 minutes", "hour and a half",
    /// "1 hour 15 minutes". Weeks and other numbers are ignored, and so are lengths that describe a
    /// part of the workout ("10 min warm-up").
    static func minutes(in text: String) -> Int? {
        var s = " " + text.lowercased() + " "
        // Longest phrases first: some contain shorter ones ("half an hour" contains "an hour")
        let words: [(String, String)] = [
            ("an hour and a half", "90 minutes"), ("hour and a half", "90 minutes"), ("one and a half hours", "90 minutes"),
            ("quarter of an hour", "15 minutes"), ("a quarter hour", "15 minutes"),
            ("half an hour", "30 minutes"), ("half hour", "30 minutes"), ("half-hour", "30 minutes"),
            ("an hour", "60 minutes"), ("one hour", "60 minutes"), ("a hour", "60 minutes"), ("two hours", "120 minutes"),
        ]
        for (word, number) in words { s = s.replacingOccurrences(of: word, with: number) }

        let pattern = #"(\d+(?:\.\d+)?)\s*(?:more\s+|extra\s+|additional\s+|full\s+)?(hours?|hrs?|minutes?|mins?)\b(?!\s*(?:warm|cool|rest|recover|interval|each|every|per|break|pause))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var total = 0.0
        var found = false
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let numberRange = Range(match.range(at: 1), in: s),
                  let unitRange = Range(match.range(at: 2), in: s),
                  let value = Double(s[numberRange]) else { continue }
            total += s[unitRange].hasPrefix("h") ? value * 60 : value
            found = true
        }
        return found && total > 0 ? Int(total.rounded()) : nil
    }

    /// What the length means: the whole workout, what's left, or a change.
    static func request(in text: String) -> LengthRequest? {
        guard let minutes = minutes(in: text) else { return nil }
        let s = " " + text.lowercased() + " "
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
        let adds = has([" add ", "extend", "another", "extra", " plus ", " more", "longer", " +"])
        let removes = has([" cut ", "remove", "trim", "drop ", "shave", " less", "shorter", "take off", " minus "])
        let left = has([" left", "remaining", "to go", "from now"])
        if left && !adds && !removes { return .remaining(minutes: minutes) }
        if adds && !removes { return .add(minutes: minutes) }
        if removes && !adds { return .remove(minutes: minutes) }
        return .total(minutes: minutes)
    }
}
