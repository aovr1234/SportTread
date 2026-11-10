import Foundation

/// What the user asks the coach for. Minutes is the main input; the rest is optional.
struct WorkoutRequest: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case recommend = "Recommend"
        case walk = "Walk"
        case jog = "Jog"
        case intervals = "Intervals"
        case hills = "Hills"

        var id: String { rawValue }
    }

    enum Intensity: String, CaseIterable, Identifiable {
        case easy = "Easy"
        case moderate = "Moderate"
        case hard = "Hard"

        var id: String { rawValue }
    }

    var minutes = 30
    var kind = Kind.recommend
    var intensity = Intensity.moderate
    var notes = ""
}

/// One way a workout departed from its plan, logged as it happens for the AI coach.
struct Deviation: Codable, Hashable {
    enum Kind: String, Codable {
        case speed, incline, skip, pause, resume, endedEarly, beltStopped, connection, adjustRest, aiEdit, checkIn
    }

    /// Seconds into the workout
    var at: Int
    var step: Int
    var stepLabel: String
    var kind: Kind
    /// Signed change for speed (mph) and incline (%) deviations
    var delta: Double?
    var detail: String

    /// Compact text for the AI coach, e.g. "lowered speed 3 times (avg 0.3 mph); skipped 1 step".
    static func summary(_ items: [Deviation]) -> String {
        guard !items.isEmpty else { return "followed the plan" }
        var parts: [String] = []
        let speeds = items.filter { $0.kind == .speed }.compactMap(\.delta)
        let down = speeds.filter { $0 < 0 }
        let up = speeds.filter { $0 > 0 }
        if !down.isEmpty {
            parts.append("lowered speed \(down.count)× (avg \(String(format: "%.1f", -down.reduce(0, +) / Double(down.count))) mph)")
        }
        if !up.isEmpty {
            parts.append("raised speed \(up.count)× (avg \(String(format: "%.1f", up.reduce(0, +) / Double(up.count))) mph)")
        }
        let inclines = items.filter { $0.kind == .incline }.compactMap(\.delta)
        if !inclines.isEmpty {
            let lowered = inclines.filter { $0 < 0 }.count
            parts.append("changed incline \(inclines.count)× (\(lowered) lower)")
        }
        let skips = items.filter { $0.kind == .skip }
        if !skips.isEmpty { parts.append("skipped \(skips.map(\.stepLabel).joined(separator: ", "))") }
        let pauses = items.filter { $0.kind == .pause }.count
        if pauses > 0 { parts.append("paused \(pauses)×") }
        if items.contains(where: { $0.kind == .beltStopped }) { parts.append("stopped the belt on the console") }
        if let early = items.last(where: { $0.kind == .endedEarly }) { parts.append("ended early during \(early.stepLabel)") }
        let adjusted = items.filter { $0.kind == .adjustRest }
        if !adjusted.isEmpty { parts.append(adjusted.map(\.detail).joined(separator: "; ")) }
        let edits = items.filter { $0.kind == .aiEdit }
        if !edits.isEmpty { parts.append("asked for: " + edits.map(\.detail).joined(separator: "; ")) }
        let checks = items.filter { $0.kind == .checkIn }
        if !checks.isEmpty { parts.append("check-ins: " + checks.map(\.detail).joined(separator: ", ")) }
        return parts.joined(separator: "; ")
    }
}

/// One finished or ended-early workout or treadmill session, kept in the data folder
/// (history.json) for coaching and the History screen.
struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var name: String
    var plannedSeconds: Int
    var seconds: Int
    var miles: Double
    var maxMph: Double
    var maxIncline: Double
    var completed: Bool
    var effort: Int?
    var deviations: [Deviation]? = nil
}
