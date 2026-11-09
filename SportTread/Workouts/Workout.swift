import Foundation

/// One timed segment of a workout. Stored as plain JSON (id is in-memory only).
struct WorkoutStep: Codable, Hashable, Identifiable {
    var id = UUID()
    var label: String
    var seconds: Int
    var mph: Double
    var incline: Double

    enum CodingKeys: String, CodingKey {
        case label, seconds, mph, incline
    }
}

/// A workout is a list of steps the runner plays in order. Built-in, hand-made and (later)
/// AI-made workouts all use this format.
struct Workout: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var summary: String
    var steps: [WorkoutStep]

    enum CodingKeys: String, CodingKey {
        case name, summary, steps
    }

    var totalSeconds: Int { steps.reduce(0) { $0 + $1.seconds } }
    var maxMph: Double { steps.map(\.mph).max() ?? 0 }
    var maxIncline: Double { steps.map(\.incline).max() ?? 0 }

    func startSecond(of index: Int) -> Int {
        steps.prefix(index).reduce(0) { $0 + $1.seconds }
    }

    /// Reasons this workout can't run on the treadmill; empty when it's safe to start.
    var problems: [String] {
        var found: [String] = []
        if steps.isEmpty { found.append("The workout has no steps") }
        for (i, step) in steps.enumerated() {
            let name = "Step \(i + 1) (\(step.label))"
            if step.seconds <= 0 { found.append("\(name) has no duration") }
            if !(TreadmillController.minMph...TreadmillController.maxMph).contains(step.mph) {
                found.append("\(name): speed must be \(TreadmillController.minMph)–\(TreadmillController.maxMph) mph")
            }
            if !(0...TreadmillController.maxIncline).contains(step.incline) {
                found.append("\(name): incline must be 0–\(Int(TreadmillController.maxIncline))%")
            }
        }
        return found
    }
}

extension Workout {
    private static func step(_ label: String, minutes: Double, _ mph: Double, _ incline: Double) -> WorkoutStep {
        WorkoutStep(label: label, seconds: Int(minutes * 60), mph: mph, incline: incline)
    }

    static let builtIn: [Workout] = [
        Workout(
            name: "Engine test",
            summary: "3 minutes of short steps to check the workout engine",
            steps: [
                step("Easy", minutes: 0.5, 1.5, 0),
                step("A bit faster", minutes: 0.5, 2.0, 1),
                step("Faster, small hill", minutes: 0.5, 2.5, 2),
                step("Back down", minutes: 0.5, 2.0, 1),
                step("Easy", minutes: 1, 1.5, 0),
            ]),
        Workout(
            name: "Easy walk",
            summary: "Steady walking with a gentle incline",
            steps: [
                step("Warm-up", minutes: 3, 2.5, 0),
                step("Steady walk", minutes: 14, 3.0, 1),
                step("Cool-down", minutes: 3, 2.5, 0),
            ]),
        Workout(
            name: "Intervals",
            summary: "8 fast minutes with easy recoveries",
            steps: [step("Warm-up", minutes: 4, 2.8, 1)]
                + (1...8).flatMap { round in
                    [step("Fast \(round)/8", minutes: 1, 4.0, 1), step("Recover", minutes: 1.5, 3.0, 1)]
                }
                + [step("Cool-down", minutes: 2, 2.5, 0)]),
        Workout(
            name: "Rolling hills",
            summary: "Steady pace, incline climbing up to 8%",
            steps: [step("Warm-up", minutes: 4, 3.0, 0)]
                + [2.0, 4, 6, 4, 2, 4, 6, 8, 4, 2].enumerated().map { i, incline in
                    step("Hill \(i + 1)/10", minutes: 2, 3.2, incline)
                }
                + [step("Cool-down", minutes: 3, 2.8, 0)]),
        Workout(
            name: "Progressive",
            summary: "Speed builds every 3 minutes",
            steps: [2.8, 3.0, 3.2, 3.4, 3.6, 3.8, 4.0].enumerated().map { i, mph in
                step("Level \(i + 1)/7", minutes: 3, mph, 1)
            }
                + [step("Cool-down", minutes: 4, 2.6, 0)]),
    ]
}
