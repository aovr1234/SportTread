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

    /// Incline for the blocks of a walk, by how much incline was asked for and how hard it is. Steps differ by at
    /// most 2 percent, and a workout of 30 minutes (3 blocks) still covers the range the checks ask for.
    static func inclinePattern(_ choice: WorkoutRequest.InclineChoice, _ intensity: WorkoutRequest.Intensity) -> [Double] {
        switch choice {
        case .none:
            return [0]
        case .some:
            switch intensity {
            case .easy: return [0, 1, 2, 1]
            case .moderate: return [0, 2, 3, 2]
            case .hard: return [1, 3, 4, 3]
            }
        case .lots:
            switch intensity {
            case .easy: return [1, 3, 4, 3]
            case .moderate: return [2, 4, 6, 4]
            case .hard: return [3, 5, 8, 5]
            }
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
        let eff = request.effectiveIncline
        // "Effort from Incline": the speed stays near the comfortable speed and the deck does the work
        let inclineMode = request.effectiveEffort == .incline && kind != .jog
        switch kind {
        case .walk, .recommend:
            let speeds: [Double] = inclineMode ? [0, 0.1, -0.1, 0.1] : [0, 0.3, -0.2, 0.2]
            steps += blocks(label: "Steady", seconds: main, base: base, speeds: speeds,
                            inclines: inclinePattern(eff, request.intensity))
        case .jog:
            let jog = min(base + 1.5 + level * 0.2, 6.2)
            let jogInclines: [Double] = eff == .none ? [0] : (eff == .some ? [0, 2, 1, 2] : [1, 4, 2, 1])
            steps += blocks(label: "Jog", seconds: main, base: jog, speeds: [0, 0.3, -0.3, 0.2], inclines: jogInclines)
        case .intervals:
            // Longer workouts get longer intervals, so 60 minutes is about 10 pairs, not 21
            let fastSeconds = request.minutes <= 30 ? 60 : (request.minutes <= 50 ? 90 : 120)
            let recoverSeconds = request.minutes <= 30 ? 90 : (request.minutes <= 50 ? 150 : 180)
            let cycle = fastSeconds + recoverSeconds
            let fast = inclineMode ? base : base + 0.8 + level * 0.4
            var fastIncline = 0.0
            var recoverIncline = 0.0
            if inclineMode {
                fastIncline = 5
                recoverIncline = 2
            } else if eff == .some {
                fastIncline = 2
            } else if eff == .lots {
                fastIncline = 4
                recoverIncline = 1
            }
            let rounds = max(1, main / cycle)
            for round in 1...rounds {
                steps.append(WorkoutStep(label: "Fast \(round)/\(rounds)", seconds: fastSeconds, mph: fast, incline: fastIncline))
                steps.append(WorkoutStep(label: "Recover", seconds: recoverSeconds, mph: base, incline: recoverIncline))
            }
            let left = main - rounds * cycle
            if left >= 30 { steps.append(WorkoutStep(label: "Steady", seconds: left, mph: base, incline: recoverIncline)) }
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
    static let maxInclineJump = 3.0  // percent between consecutive steps (the deck moves slowly)

    /// Steep and fast don't go together: above 3.5 mph at most 8 percent, above 4.5 mph at most 6 percent.
    static func inclineCap(forMph mph: Double) -> Double {
        mph > 4.5 ? 6 : (mph > 3.5 ? 8 : TreadmillLimits.maxIncline)
    }

    /// Applies the incline cap for the speed and the limit on how fast the incline may change.
    private static func limitIncline(_ steps: inout [WorkoutStep]) {
        for i in steps.indices {
            steps[i].incline = min(steps[i].incline, inclineCap(forMph: steps[i].mph))
            if i > 0 { steps[i].incline = min(steps[i].incline, steps[i - 1].incline + maxInclineJump) }
        }
    }

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
        limitIncline(&steps)
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

    /// A warm-up or cool-down step (the heart-rate hold leaves these alone).
    static func isEndStep(_ step: WorkoutStep) -> Bool { isWarm(step) || isCool(step) }

    private static func isCool(_ step: WorkoutStep) -> Bool {
        let label = step.label.lowercased()
        return label.contains("cool") || label.contains("ease out") || label.contains("finish")
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

    /// The AI's own steps add up to within 15% of the requested length. Stretching or squashing a workout
    /// that is much shorter or longer changes what its intervals are.
    static func lengthIsClose(_ raw: Int, to requested: Int) -> Bool {
        guard requested > 0 else { return true }
        return abs(Double(raw - requested)) / Double(requested) <= 0.15
    }

    /// Why an Intervals workout isn't a proper interval workout, or nil: a fast step (0.5 mph or more above
    /// the comfortable speed) longer than 3.5 min, faster than comfortable + 1.0 mph (Easy), + 1.5 (Moderate)
    /// or + 2.0 (Hard) (the same limits the prompt states), or with no recovery after it. Checked for workouts of 20 minutes or more.
    static func intervalProblem(_ steps: [WorkoutStep], comfortable: Double,
                                intensity: WorkoutRequest.Intensity, minutes: Int,
                                effort: WorkoutRequest.EffortFrom = .mix) -> String? {
        guard minutes >= 20 else { return nil }
        let main = mainSteps(steps)
        if effort == .incline {
            // Incline intervals at a steady speed: a steep step must not last more than 3.5 min
            if let long = main.first(where: { $0.incline >= 4 && $0.seconds > 210 }) {
                return String(format: "a steep step lasts %d:%02d", long.seconds / 60, long.seconds % 60)
            }
            return nil
        }
        let allowed = comfortable + WorkoutPrompt.fastRange(intensity).high + 0.05
        for (index, step) in main.enumerated() where step.mph >= comfortable + 0.5 {
            if step.seconds > 210 {
                return String(format: "a fast step lasts %d:%02d", step.seconds / 60, step.seconds % 60)
            }
            if step.mph > allowed {
                return String(format: "a fast step is %.1f mph, too fast for %@", step.mph, intensity.rawValue.lowercased())
            }
            if index + 1 < main.count, main[index + 1].mph >= step.mph - 0.4 {
                return "a fast step has no recovery after it"
            }
        }
        return nil
    }

    /// The incline the request asked for: with Some or Lots (and no note about pain) a walk, jog or intervals workout
    /// of 30 minutes or more needs incline in its main part; with None (or a note about pain), none.
    static func inclineProblem(_ steps: [WorkoutStep], request: WorkoutRequest, comfortable: Double) -> String? {
        guard request.minutes >= 30, request.kind != .hills, request.kind != .recommend else { return nil }
        let main = mainSteps(steps)
        guard !main.isEmpty else { return nil }
        let inclines = main.map(\.incline)
        let peak = inclines.max() ?? 0
        let range = peak - (inclines.min() ?? 0)
        switch request.effectiveIncline {
        case .none:
            return peak > 0.5 ? "it used incline although none was wanted" : nil
        case .some:
            return range >= 1.99 ? nil : "it had no incline blocks"
        case .lots:
            if peak < 3.99 || range < 2.99 { return "it didn't use much incline" }
            if request.effectiveEffort == .incline, request.kind != .jog, (main.map(\.mph).max() ?? 0) > comfortable + 0.6 {
                return "it made the effort with speed instead of incline"
            }
            return nil
        }
    }

    /// An Easy workout never goes faster than the comfortable speed + 1.0 mph (jogs are exempt: they
    /// start near 4 mph by definition).
    static func easyPaceProblem(_ steps: [WorkoutStep], kind: WorkoutRequest.Kind,
                                intensity: WorkoutRequest.Intensity, comfortable: Double) -> String? {
        guard intensity == .easy, kind != .jog else { return nil }
        let fastest = mainSteps(steps).map(\.mph).max() ?? 0
        return fastest > comfortable + WorkoutPrompt.fastRange(.easy).high + 0.05 ? String(format: "it went up to %.1f mph, faster than an easy pace", fastest) : nil
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
    static func matchesKind(_ steps: [WorkoutStep], kind: WorkoutRequest.Kind, minutes: Int,
                            effort: WorkoutRequest.EffortFrom = .mix) -> Bool {
        guard minutes >= 20 else { return true }
        let main = mainSteps(steps)
        guard !main.isEmpty else { return false }
        switch kind {
        case .intervals:
            if effort == .incline {
                return zip(main, main.dropFirst()).filter { abs($0.incline - $1.incline) >= 1.99 }.count >= 4
            }
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
        limitIncline(&steps)

        workout.steps = steps
        return workout
    }
}
