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

/// One finished or ended-early workout, kept in the data folder (history.json) for coaching.
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
}
