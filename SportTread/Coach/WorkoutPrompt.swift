import Foundation

/// The text every AI engine is given (Apple Intelligence on the phone and the cloud providers), and the
/// reading of a cloud answer. Pure Foundation, so it is tested on every build: the examples must pass the
/// same checks as any workout, and the reading of answers must cope with fences and chatter.
/// tools/benchmark_llm.py keeps a copy of the rules; keep the two in step.
enum WorkoutPrompt {
    static let rules = """
        You are a friendly treadmill coach. You design one treadmill workout as a list of timed steps.
        Rules:
        - The steps' seconds must add up to the requested total time.
        - Start with a warm-up of 3 to 5 minutes in total (never more than 5), in two steps that ramp up
          by at least 0.5 mph (for example 2.0 then 2.5 mph), and end with a cool-down of about 3 minutes
          in total (never more than 4) in two steps that ramp down. Most of the time is the main part.
        - The main part is never one flat step: use at least 3 blocks of 5 to 10 minutes that differ in
          speed (by 0.2 to 0.5 mph) or in incline (0 to 3 percent). Never give every step the same speed and incline.
        - If the person is sore, tired or asks for easy, keep the incline at 0 and vary only the speed a little.
        - Make step lengths whole minutes (multiples of 60 seconds), except interval steps.
        - The chosen workout type and intensity are required. If the person's note seems to ask for something
          else, still make that type and intensity and use the note only to adjust how hard it is.
        - Speeds are in miles per hour. Walking is about 2.5 to 3.8 mph, jogging about 4 to 6 mph.
          Stay close to the person's comfortable speed and never go above 10 mph.
        - Incline is 0 to 10 percent.
        - Never raise the speed by more than 1.5 mph from one step to the next.
        - Easy means relaxed, moderate means somewhat hard, hard means challenging but safe.
        - Each step lasts between 30 seconds and 15 minutes.
        """

    static let jsonRule = """
        Reply with one JSON object only, with no other text, in exactly this shape:
        {"name": "at most 4 words", "summary": "one encouraging sentence", "steps": [{"label": "Warm-up", "seconds": 120, "mph": 2.0, "incline": 0}]}
        """

    /// How far above the comfortable speed a fast interval step may be, by intensity. The checks use the
    /// same upper limit, so the prompt and the checks never disagree.
    static func fastRange(_ intensity: WorkoutRequest.Intensity) -> (low: Double, high: Double) {
        switch intensity {
        case .easy: (0.5, 1.0)
        case .moderate: (0.8, 1.5)
        case .hard: (1.2, 2.0)
        }
    }

    /// What each type means, so a model can't read "intervals" as "varied walking".
    static func typeGuide(_ kind: WorkoutRequest.Kind, base: Double, intensity: WorkoutRequest.Intensity) -> String {
        func mph(_ value: Double) -> String { String(format: "%.1f", value) }
        switch kind {
        case .intervals:
            let range = fastRange(intensity)
            return "Type rules for intervals: the main part repeats at least 5 pairs of a fast step (1 to 3 minutes at \(mph(base + range.low)) to \(mph(base + range.high)) mph) and a recovery step (1.5 to 3 minutes at \(mph(base)) mph). It is not a steady walk."
        case .hills:
            return "Type rules for hills: the main part is blocks of 2 to 4 minutes whose incline changes between 2 and 8 percent, with the speed staying near \(mph(base)) mph."
        case .jog:
            return "Type rules for jog: the main part is jogging at 4 to 6 mph in blocks of 5 to 10 minutes."
        case .walk:
            return "Type rules for walk: the main part is walking at 2.5 to 3.8 mph in blocks that vary a little."
        case .recommend:
            return ""
        }
    }

    /// The request itself: what to make, the comfortable speed, the type rules, recent workouts and the note.
    static func request(_ request: WorkoutRequest, base: Double, history: [HistoryEntry]) -> String {
        let recent = history.suffix(5).map { entry in
            let effort = entry.effort.map { ", effort \($0)/10" } ?? ""
            let done = entry.completed ? "completed" : "stopped early"
            let changes = (entry.deviations ?? []).isEmpty ? "" : "; " + Deviation.summary(entry.deviations ?? [])
            return "- \(entry.name): \(entry.seconds / 60) min, top speed \(String(format: "%.1f", entry.maxMph)) mph, \(done)\(effort)\(changes)"
        }
        var prompt = """
            Create a \(request.minutes)-minute \(request.intensity.rawValue.lowercased()) \(request.kind.rawValue.lowercased()) treadmill workout.
            Total time: exactly \(request.minutes * 60) seconds.
            The person's comfortable walking speed is about \(String(format: "%.1f", base)) mph.
            """
        prompt += "\n" + typeGuide(request.kind, base: base, intensity: request.intensity)
        prompt += recent.isEmpty
            ? "\nNo previous workouts yet, so keep it approachable."
            : "\nRecent workouts:\n" + recent.joined(separator: "\n")
        let notes = request.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            prompt += "\nThe person adds: \(notes)"
        }
        return prompt
    }

    // MARK: Cloud models

    /// The cloud models get the rules, the answer format, and one worked example of the chosen type.
    static func cloudInstructions(for kind: WorkoutRequest.Kind) -> String {
        let name = kind == .recommend ? WorkoutRequest.Kind.walk : kind
        return rules + "\n\n" + jsonRule + "\n\n"
            + "Here is an example of a good \(name.rawValue.lowercased()) workout for 40 minutes, moderate effort and a comfortable speed of 3.0 mph. "
            + "Do not copy it: make your own for the requested time, speed and effort.\n"
            + exampleJSON(for: name)
    }

    /// What the model is told when the app's checks rejected its answer.
    static func retry(reason: String, seconds: Int) -> String {
        "The app's checks rejected your workout because: \(reason).\n"
            + "Fix exactly that and keep everything that was fine. The steps must still add up to exactly \(seconds) seconds. "
            + "Reply with the complete corrected JSON object only."
    }

    /// A 40-minute example of each type (it must itself pass every check; a test makes sure).
    static func exampleSteps(for kind: WorkoutRequest.Kind) -> [WorkoutStep] {
        func step(_ label: String, _ seconds: Int, _ mph: Double, _ incline: Double = 0) -> WorkoutStep {
            WorkoutStep(label: label, seconds: seconds, mph: mph, incline: incline)
        }
        var steps = [step("Warm-up", 120, 2.0), step("Ease in", 180, 2.8)]
        switch kind {
        case .intervals:
            for round in 1...6 {
                steps.append(step("Fast \(round)/6", 120, 4.2))
                steps.append(step("Recover \(round)/6", round == 6 ? 240 : 180, 3.0))
            }
        case .hills:
            steps = [step("Warm-up", 120, 2.0), step("Ease in", 180, 2.5)]
            let inclines: [Double] = [2, 4, 6, 4, 2, 4, 6, 8, 4, 2]
            for (index, incline) in inclines.enumerated() {
                steps.append(step("Hill \(index + 1)/10", index == 9 ? 240 : 180, 3.0, incline))
            }
        case .jog:
            steps = [step("Warm-up", 120, 2.5), step("Ease in", 180, 3.3)]
            let speeds = [4.2, 4.5, 4.3, 4.6]
            let minutes = [8, 8, 8, 7]
            for index in 0..<4 {
                steps.append(step("Jog \(index + 1)/4", minutes[index] * 60, speeds[index], index == 2 ? 2 : 1))
            }
        case .walk, .recommend:
            steps = [step("Warm-up", 120, 2.0), step("Ease in", 180, 2.5)]
            let speeds = [3.0, 3.3, 3.1, 3.4]
            let inclines: [Double] = [0, 1, 2, 1]
            let minutes = [7, 8, 8, 8]
            for index in 0..<4 {
                steps.append(step("Steady \(index + 1)/4", minutes[index] * 60, speeds[index], inclines[index]))
            }
        }
        steps.append(step("Ease out", 120, 2.5))
        steps.append(step("Cool-down", 120, 2.0))
        return steps
    }

    static func exampleJSON(for kind: WorkoutRequest.Kind) -> String {
        let rows = exampleSteps(for: kind).map { step in
            String(format: "{\"label\": \"%@\", \"seconds\": %d, \"mph\": %.1f, \"incline\": %g}", step.label, step.seconds, step.mph, step.incline)
        }
        return "{\"name\": \"Example\", \"summary\": \"An example workout.\", \"steps\": [" + rows.joined(separator: ", ") + "]}"
    }

    /// Reads a workout out of a model's reply: the first { to the last }, so fences and a few words around
    /// the JSON don't matter. Numbers may arrive as text. nil when there is no usable steps list.
    static func parse(_ text: String) -> Workout? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawSteps = object["steps"] as? [[String: Any]], !rawSteps.isEmpty else { return nil }
        func number(_ value: Any?) -> Double? {
            if let number = value as? NSNumber { return number.doubleValue }
            if let text = value as? String { return Double(text) }
            return nil
        }
        var steps: [WorkoutStep] = []
        for raw in rawSteps {
            guard let seconds = number(raw["seconds"]), let mph = number(raw["mph"]) else { return nil }
            steps.append(WorkoutStep(label: (raw["label"] as? String) ?? "Step", seconds: Int(seconds.rounded()),
                                     mph: mph, incline: number(raw["incline"]) ?? 0))
        }
        return Workout(name: (object["name"] as? String) ?? "Workout", summary: (object["summary"] as? String) ?? "", steps: steps)
    }
}
