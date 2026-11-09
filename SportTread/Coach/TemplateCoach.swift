import Foundation

/// Rule-based coach: always available, used when Apple Intelligence isn't, and to pick a workout
/// type and a comfortable base speed from recent history.
enum TemplateCoach {
    /// Comfortable steady walking speed from recent workouts, nudged by the last effort rating.
    static func baseSpeed(history: [HistoryEntry]) -> Double {
        let recent = history.suffix(5)
        var base = 3.0
        if !recent.isEmpty {
            // Steady pace is roughly 85% of the top speed reached in recent workouts
            let averageTop = recent.map(\.maxMph).reduce(0, +) / Double(recent.count)
            base = min(max(averageTop * 0.85, 2.5), 4.5)
        }
        if let last = history.last {
            if !last.completed || (last.effort ?? 5) >= 8 {
                base -= 0.2
            } else if (last.effort ?? 5) <= 4 {
                base += 0.2
            }
        }
        return (base * 10).rounded() / 10
    }

    /// Picks a type for "Recommend": easy walk after a hard or unfinished session, otherwise the
    /// type done least recently.
    static func recommendedKind(history: [HistoryEntry]) -> WorkoutRequest.Kind {
        if let last = history.last, !last.completed || (last.effort ?? 5) >= 8 { return .walk }
        let recentNames = history.suffix(3).map { $0.name.lowercased() }
        for kind in [WorkoutRequest.Kind.intervals, .hills, .walk]
        where !recentNames.contains(where: { $0.contains(kind.rawValue.lowercased()) }) {
            return kind
        }
        return .walk
    }

    static func make(_ request: WorkoutRequest, history: [HistoryEntry]) -> Workout {
        let kind = request.kind == .recommend ? recommendedKind(history: history) : request.kind
        let total = max(10, request.minutes) * 60
        let warm = request.minutes >= 20 ? 240 : 180
        let cool = 180
        let main = total - warm - cool
        let level: Double = switch request.intensity {
        case .easy: 0
        case .moderate: 1
        case .hard: 2
        }
        let base = baseSpeed(history: history) + (level - 1) * 0.3

        var steps = [WorkoutStep(label: "Warm-up", seconds: warm, mph: max(base - 0.5, 1.5), incline: 0)]
        switch kind {
        case .walk, .recommend:
            steps.append(WorkoutStep(label: "Steady walk", seconds: main, mph: base, incline: level))
        case .jog:
            steps.append(WorkoutStep(label: "Jog", seconds: main, mph: min(base + 1.5 + level * 0.2, 6.5), incline: 1))
        case .intervals:
            let fast = base + 0.8 + level * 0.4
            let rounds = max(1, main / 150)
            for round in 1...rounds {
                steps.append(WorkoutStep(label: "Fast \(round)/\(rounds)", seconds: 60, mph: fast, incline: 1))
                steps.append(WorkoutStep(label: "Recover", seconds: 90, mph: base, incline: 1))
            }
            let left = main - rounds * 150
            if left >= 30 { steps.append(WorkoutStep(label: "Steady", seconds: left, mph: base, incline: 1)) }
        case .hills:
            let peak = 4 + level * 2
            let climb = Array(stride(from: 2.0, through: peak, by: 2))
            let pattern = climb + climb.dropLast().dropFirst().reversed()
            let blocks = max(1, main / 120)
            for i in 0..<blocks {
                let seconds = i == blocks - 1 ? main - 120 * (blocks - 1) : 120
                steps.append(WorkoutStep(label: "Hill \(i + 1)/\(blocks)", seconds: seconds, mph: base,
                                         incline: pattern[i % pattern.count]))
            }
        }
        steps.append(WorkoutStep(label: "Cool-down", seconds: cool, mph: max(base - 0.5, 1.5), incline: 0))

        let workout = Workout(
            name: "\(request.minutes)-min \(kind.rawValue)",
            summary: "\(request.intensity.rawValue) \(kind.rawValue.lowercased()) around \(String(format: "%.1f", base)) mph",
            steps: steps)
        return SafetyCheck.repair(workout, totalMinutes: request.minutes)
    }
}

/// Makes any workout (AI-made or not) safe to run: valid ranges, warm-up and cool-down,
/// no sudden speed jumps, and the requested total length.
enum SafetyCheck {
    static let maxSpeedJump = 1.5  // mph between consecutive steps

    static func repair(_ input: Workout, totalMinutes: Int?) -> Workout {
        var workout = input
        var steps = workout.steps.map { step in
            var s = step
            s.mph = (min(max(s.mph, TreadmillController.minMph), TreadmillController.maxMph) * 10).rounded() / 10
            s.incline = (min(max(s.incline, 0), TreadmillController.maxIncline) * 2).rounded() / 2
            s.seconds = max(30, s.seconds)
            if s.label.trimmingCharacters(in: .whitespaces).isEmpty { s.label = "Step" }
            return s
        }
        guard !steps.isEmpty else { return workout }

        if !steps[0].label.lowercased().contains("warm") {
            steps.insert(WorkoutStep(label: "Warm-up", seconds: 180, mph: max(steps[0].mph - 0.5, 1.5), incline: 0), at: 0)
        }
        if let last = steps.last, !last.label.lowercased().contains("cool") {
            steps.append(WorkoutStep(label: "Cool-down", seconds: 180, mph: max(last.mph - 0.5, 1.5), incline: 0))
        }

        // Scale to the requested length, keeping steps at least 30 s, in 5-second units
        if let totalMinutes {
            let target = Double(totalMinutes * 60)
            let current = Double(steps.reduce(0) { $0 + $1.seconds })
            for i in steps.indices {
                steps[i].seconds = max(30, Int((Double(steps[i].seconds) * target / current / 5).rounded()) * 5)
            }
            let diff = Int(target) - steps.reduce(0) { $0 + $1.seconds }
            if let longest = steps.indices.max(by: { steps[$0].seconds < steps[$1].seconds }) {
                steps[longest].seconds = max(30, steps[longest].seconds + diff)
            }
        }

        for i in steps.indices.dropFirst() where steps[i].mph - steps[i - 1].mph > maxSpeedJump {
            steps[i].mph = steps[i - 1].mph + maxSpeedJump
        }

        workout.steps = steps
        return workout
    }
}
