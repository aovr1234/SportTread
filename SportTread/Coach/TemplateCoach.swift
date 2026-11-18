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

    /// The main part as blocks of about 7 minutes (2 to 8 of them), in whole minutes, each with its own
    /// speed and incline from the patterns; the remainder goes to the last blocks.
    static func blocks(label: String, seconds main: Int, base: Double, speeds: [Double], inclines: [Double]) -> [WorkoutStep] {
        let minutes = max(2, main / 60)
        let count = max(2, min(8, Int((Double(minutes) / 7).rounded())))
        var lengths = Array(repeating: minutes / count, count: count)
        for i in 0..<(minutes % count) { lengths[count - 1 - i] += 1 }
        return lengths.enumerated().map { index, length in
            WorkoutStep(label: "\(label) \(index + 1)/\(count)", seconds: length * 60,
                        mph: base + speeds[index % speeds.count], incline: inclines[index % inclines.count])
        }
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

        // Warm-up and cool-down ramp over two steps each, instead of one flat step
        let warmLow = max(base - 1.0, 1.5)
        let warmHigh = max(base - 0.5, warmLow + 0.2)
        let warmFirst = warm == 240 ? 120 : 60
        var steps = [
            WorkoutStep(label: "Warm-up", seconds: warmFirst, mph: warmLow, incline: 0),
            WorkoutStep(label: "Ease in", seconds: warm - warmFirst, mph: warmHigh, incline: 0),
        ]
        // The main part is several blocks that differ, never one flat step. Easy keeps the incline at 0
        // and varies only the speed a little.
        let walkInclines: [Double] = level == 0 ? [0] : (level == 1 ? [0, 1, 2, 1] : [1, 2, 3, 2])
        switch kind {
        case .walk, .recommend:
            steps += blocks(label: "Steady", seconds: main, base: base, speeds: [0, 0.3, -0.2, 0.2], inclines: walkInclines)
        case .jog:
            let jog = min(base + 1.5 + level * 0.2, 6.2)
            steps += blocks(label: "Jog", seconds: main, base: jog, speeds: [0, 0.3, -0.3, 0.2], inclines: [1, 2, 1, 0])
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
        let coolLow = max(base - 1.0, 1.5)
        steps.append(WorkoutStep(label: "Ease out", seconds: 120, mph: max(base - 0.5, coolLow + 0.2), incline: 0))
        steps.append(WorkoutStep(label: "Cool-down", seconds: cool - 120, mph: coolLow, incline: 0))

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

    /// Range and jump limits only, without adding steps or rescaling: for live edits of a running
    /// workout, where step positions must not move.
    static func clamped(_ input: [WorkoutStep]) -> [WorkoutStep] {
        var steps = input.map { step in
            var s = step
            s.mph = (min(max(s.mph, TreadmillLimits.minMph), TreadmillLimits.maxMph) * 10).rounded() / 10
            s.incline = (min(max(s.incline, 0), TreadmillLimits.maxIncline) * 2).rounded() / 2
            s.seconds = max(30, s.seconds)
            return s
        }
        for i in steps.indices.dropFirst() where steps[i].mph - steps[i - 1].mph > maxSpeedJump {
            steps[i].mph = steps[i - 1].mph + maxSpeedJump
        }
        return steps
    }

    /// True when the workout has no real shape: everything except the first and last step stays within
    /// 0.25 mph and 0.5% (one flat block, or several that are all the same).
    static func isFlat(_ steps: [WorkoutStep]) -> Bool {
        let inner = Array(steps.dropFirst().dropLast())
        guard let first = inner.first else { return true }
        let speeds = inner.map(\.mph)
        let inclines = inner.map(\.incline)
        return (speeds.max() ?? first.mph) - (speeds.min() ?? first.mph) <= 0.25
            && (inclines.max() ?? first.incline) - (inclines.min() ?? first.incline) <= 0.5
    }

    /// Rounds every step to a multiple of 30 s (so an AI workout doesn't come out as 5:25 and 52:10),
    /// keeping the total exactly the same. Returns the workout unchanged if that isn't possible.
    static func snapped(_ workout: Workout) -> Workout {
        guard let fitted = LengthFit.snapped(workout.steps.map(\.seconds), to: workout.totalSeconds) else { return workout }
        var result = workout
        for i in result.steps.indices { result.steps[i].seconds = fitted[i] }
        return result
    }

    static func repair(_ input: Workout, totalMinutes: Int?) -> Workout {
        var workout = input
        var steps = workout.steps.map { step in
            var s = step
            s.mph = (min(max(s.mph, TreadmillLimits.minMph), TreadmillLimits.maxMph) * 10).rounded() / 10
            s.incline = (min(max(s.incline, 0), TreadmillLimits.maxIncline) * 2).rounded() / 2
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

        // Exactly the requested length: steps stay at least 30 s, in 5-second units; if there are too
        // many steps for that, the smallest inner ones are merged (see LengthFit)
        if let totalMinutes, let fitted = LengthFit.fit(steps.map(\.seconds), to: totalMinutes * 60) {
            steps = fitted.kept.enumerated().map { position, original in
                var s = steps[original]
                s.seconds = fitted.seconds[position]
                return s
            }
        }

        for i in steps.indices.dropFirst() where steps[i].mph - steps[i - 1].mph > maxSpeedJump {
            steps[i].mph = steps[i - 1].mph + maxSpeedJump
        }

        workout.steps = steps
        return workout
    }
}
