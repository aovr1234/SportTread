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

    static let maxWarmSeconds = 300
    static let maxCoolSeconds = 240

    private static func isWarm(_ step: WorkoutStep) -> Bool {
        let label = step.label.lowercased()
        return label.contains("warm") || label.contains("ease in")
    }

    private static func isCool(_ step: WorkoutStep) -> Bool {
        let label = step.label.lowercased()
        return label.contains("cool") || label.contains("ease out")
    }

    /// Cleans up the ends of an AI workout (an AI workout can spend 17 of 60 minutes on them, put a "Cool-down"
    /// in the middle, or warm up faster than it then walks):
    /// - a step called cool-down or warm-up that isn't in the end groups is renamed Recover or Build;
    /// - a single warm-up or cool-down step of 2 min or more is split in two, so it ramps;
    /// - the warm-up steps add up to at most 5 min and the cool-down steps to at most 4 min, the extra time
    ///   shared out over the main steps (the total stays exactly the same);
    /// - the warm-up is never faster than the first main step, nor the cool-down faster than the last one;
    /// - the first warm-up step is at least 0.5 mph below the next (and the last cool-down step 0.5 below
    ///   the one before);
    /// - repeated names are told apart (Warm-up / Ease in, Ease out / Cool-down).
    static func trimmedEnds(_ workout: Workout) -> Workout {
        var steps = workout.steps
        func groups() -> (warm: Int, cool: Int)? {
            var warm = 0
            while warm < steps.count, isWarm(steps[warm]) { warm += 1 }
            var cool = 0
            while cool < steps.count - warm, isCool(steps[steps.count - 1 - cool]) { cool += 1 }
            guard warm >= 1, cool >= 1, warm + cool < steps.count else { return nil }
            return (warm, cool)
        }
        guard var counts = groups() else { return workout }
        let minMph = TreadmillLimits.minMph

        // A cool-down or warm-up in the middle is just a slow or building step
        for index in counts.warm..<(steps.count - counts.cool) {
            if isCool(steps[index]) { steps[index].label = "Recover" } else if isWarm(steps[index]) { steps[index].label = "Build" }
        }

        // One long warm-up or cool-down step becomes two, so that it ramps
        if counts.warm == 1, steps[0].seconds >= 120 {
            let first = max(30, (steps[0].seconds / 2) / 30 * 30)
            var low = steps[0]
            low.seconds = first
            low.mph = max(minMph, ((low.mph - 0.5) * 10).rounded() / 10)
            steps[0].seconds -= first
            steps.insert(low, at: 0)
            counts.warm = 2
        }
        if counts.cool == 1, steps[steps.count - 1].seconds >= 120 {
            let last = steps.count - 1
            let first = max(30, (steps[last].seconds / 2) / 30 * 30)
            var high = steps[last]
            high.seconds = first
            steps[last].seconds -= first
            steps[last].mph = max(minMph, ((steps[last].mph - 0.5) * 10).rounded() / 10)
            steps.insert(high, at: last)
            counts.cool = 2
        }

        let warmRange = 0..<counts.warm
        let coolRange = (steps.count - counts.cool)..<steps.count
        let mainRange = counts.warm..<(steps.count - counts.cool)

        var moved = 0
        for (range, cap) in [(warmRange, maxWarmSeconds), (coolRange, maxCoolSeconds)] {
            let lengths = range.map { steps[$0].seconds }
            let total = lengths.reduce(0, +)
            guard total > cap, let fitted = LengthFit.snapped(lengths.map { $0 * cap / total }, to: cap) else { continue }
            for (offset, index) in range.enumerated() { steps[index].seconds = fitted[offset] }
            moved += total - cap
        }
        if moved > 0 {
            let lengths = mainRange.map { steps[$0].seconds }
            let total = lengths.reduce(0, +)
            let target = total + moved
            if let fitted = LengthFit.snapped(lengths.map { $0 * target / total }, to: target) {
                for (offset, index) in mainRange.enumerated() { steps[index].seconds = fitted[offset] }
            }
        }

        // Never warm up faster than the walk that follows, nor cool down faster than the one before
        let firstMain = steps[mainRange.lowerBound].mph
        let lastMain = steps[mainRange.upperBound - 1].mph
        for index in warmRange { steps[index].mph = min(steps[index].mph, firstMain) }
        for index in coolRange { steps[index].mph = min(steps[index].mph, lastMain) }

        if counts.warm >= 2, steps[1].mph - steps[0].mph < 0.5 {
            steps[0].mph = max(minMph, ((steps[1].mph - 0.5) * 10).rounded() / 10)
        }
        if counts.cool >= 2 {
            let before = steps.count - 2
            let last = steps.count - 1
            if steps[before].mph - steps[last].mph < 0.5 {
                steps[last].mph = max(minMph, ((steps[before].mph - 0.5) * 10).rounded() / 10)
            }
        }
        for index in warmRange { steps[index].label = index == 0 ? "Warm-up" : (index == 1 ? "Ease in" : "Ease in \(index)") }
        for (offset, index) in coolRange.enumerated() {
            steps[index].label = index == steps.count - 1 ? "Cool-down" : (offset == 0 ? "Ease out" : "Ease out \(offset + 1)")
        }
        var result = workout
        result.steps = steps
        return result
    }

    /// The steps between the warm-up and the cool-down.
    static func mainSteps(_ steps: [WorkoutStep]) -> [WorkoutStep] {
        var start = 0
        while start < steps.count, isWarm(steps[start]) { start += 1 }
        var end = steps.count
        while end > start, isCool(steps[end - 1]) { end -= 1 }
        return Array(steps[start..<end])
    }

    /// Does the workout look like the type that was asked for? Checked for workouts of 20 minutes or more:
    /// Intervals needs at least 4 swings of 0.5 mph or more between neighbouring main steps, Hills an
    /// incline range of 2% or more, Jog a main speed of 3.8 mph or more. Walk accepts anything.
    static func matchesKind(_ steps: [WorkoutStep], kind: WorkoutRequest.Kind, minutes: Int) -> Bool {
        guard minutes >= 20 else { return true }
        let main = mainSteps(steps)
        guard !main.isEmpty else { return false }
        switch kind {
        case .intervals:
            return zip(main, main.dropFirst()).filter { abs($0.mph - $1.mph) >= 0.49 }.count >= 4
        case .hills:
            let inclines = main.map(\.incline)
            return (inclines.max() ?? 0) - (inclines.min() ?? 0) >= 1.99
        case .jog:
            return (main.map(\.mph).max() ?? 0) >= 3.8
        case .walk, .recommend:
            return true
        }
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
