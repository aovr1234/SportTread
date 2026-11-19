import Foundation

// Length guarantee tests. Run on every build (see .github/workflows/build.yml); the build fails if any
// workout or live edit comes out the wrong length, even by a second.

var failures: [String] = []
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
    checks += 1
    if !condition() { failures.append(message()) }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

var rng = SeededGenerator(state: 42)
let labels = ["Warm-up", "Fast", "Recover", "Hill", "Steady", "Cool-down", "Step", ""]

func randomSteps(count: Int, maxSeconds: Int = 1500) -> [WorkoutStep] {
    (0..<count).map { _ in
        WorkoutStep(label: labels.randomElement(using: &rng)!,
                    seconds: Int.random(in: 1...maxSeconds, using: &rng),
                    mph: Double.random(in: 0...14, using: &rng),
                    incline: Double.random(in: -2...14, using: &rng))
    }
}

// 1. The built-in rules: every length, type and intensity, with and without history
let history = [
    HistoryEntry(date: Date(), name: "Easy walk", plannedSeconds: 1800, seconds: 1800, miles: 1.6,
                 maxMph: 3.4, maxIncline: 2, completed: true, effort: 8),
    HistoryEntry(date: Date(), name: "Intervals", plannedSeconds: 1500, seconds: 900, miles: 0.8,
                 maxMph: 4.2, maxIncline: 1, completed: false),
]
for minutes in 10...90 {
    for kind in WorkoutRequest.Kind.allCases {
        for intensity in WorkoutRequest.Intensity.allCases {
            for h in [[], history] {
                var request = WorkoutRequest()
                request.minutes = minutes
                request.kind = kind
                request.intensity = intensity
                let workout = TemplateCoach.make(request, history: h)
                check(workout.totalSeconds == minutes * 60,
                      "rules \(kind.rawValue)/\(intensity.rawValue) \(minutes) min came out \(workout.totalSeconds) s")
                check(workout.problems.isEmpty, "rules \(kind.rawValue) \(minutes) min has problems: \(workout.problems)")
            }
        }
    }
}

// 2. Simulated AI workouts (random steps, speeds out of range, tiny and huge steps) must be repaired to exact
for minutes in 10...90 {
    for _ in 0..<200 {
        let made = Workout(name: "ai", summary: "", steps: randomSteps(count: Int.random(in: 1...24, using: &rng)))
        let fixed = SafetyCheck.repair(made, totalMinutes: minutes)
        check(fixed.totalSeconds == minutes * 60, "AI workout for \(minutes) min came out \(fixed.totalSeconds) s")
        check(fixed.problems.isEmpty, "AI workout for \(minutes) min has problems: \(fixed.problems)")
        check(fixed.steps.allSatisfy { $0.seconds >= 30 && $0.seconds % 5 == 0 }, "AI workout for \(minutes) min has a bad step length")
    }
}

// 3. Live edits
for _ in 0..<3000 {
    let steps = randomSteps(count: Int.random(in: 2...16, using: &rng), maxSeconds: 900).map { s -> WorkoutStep in
        var s = s
        s.seconds = max(30, s.seconds / 5 * 5)
        return s
    }
    let current = steps[0]
    let remaining = Array(steps.dropFirst())
    let main = remaining.filter { !WorkoutEdits.isCooldown($0) }.reduce(0) { $0 + $1.seconds }

    let cut = WorkoutEdits.shorter(remaining)
    check(WorkoutEdits.seconds(remaining) - WorkoutEdits.seconds(cut.steps) == cut.removed, "shorter: removed count doesn't match")
    check(cut.removed == 300 || cut.steps.filter { !WorkoutEdits.isCooldown($0) }.allSatisfy { $0.seconds == 30 },
          "shorter removed \(cut.removed) s but main steps aren't all at the minimum")
    check(cut.removed == 300 || main < 300 + 30 * remaining.count, "shorter fell short of 300 s with \(main) s of main time")
    check(cut.steps.allSatisfy { $0.seconds >= 30 }, "shorter left a step under 30 s")

    let longer = WorkoutEdits.longer(remaining, current: current)
    check(WorkoutEdits.seconds(longer) == WorkoutEdits.seconds(remaining) + 300, "longer didn't add exactly 300 s")

    let easier = WorkoutEdits.shifted(remaining, mph: -0.3, incline: -1)
    check(WorkoutEdits.seconds(easier) == WorkoutEdits.seconds(remaining), "easier changed the duration")

    // A proposed edit (e.g. from the AI) is forced to the exact remaining time
    let target = Int.random(in: 1...120, using: &rng) * 30
    let proposed = randomSteps(count: Int.random(in: 0...12, using: &rng))
    if let fitted = WorkoutEdits.fitRemaining(proposed, current: current, to: target) {
        check(WorkoutEdits.seconds(fitted) == target, "fitRemaining gave \(WorkoutEdits.seconds(fitted)) s for a target of \(target) s")
    } else {
        check(false, "fitRemaining returned nil for a target of \(target) s")
    }
}

// 4. Reading a length from text
let parserCases: [(String, LengthRequest?)] = [
    ("1 hr", .total(minutes: 60)),
    ("an hour", .total(minutes: 60)),
    ("45 minutes", .total(minutes: 45)),
    ("hour and a half", .total(minutes: 90)),
    ("1.5 hours", .total(minutes: 90)),
    ("1 hour 15 minutes", .total(minutes: 75)),
    ("half an hour", .total(minutes: 30)),
    ("make it an hour total", .total(minutes: 60)),
    ("I want 45 min of walking", .total(minutes: 45)),
    ("add 5 minutes", .add(minutes: 5)),
    ("give me 5 more minutes", .add(minutes: 5)),
    ("cut 10 min", .remove(minutes: 10)),
    ("10 minutes shorter", .remove(minutes: 10)),
    ("20 minutes left", .remaining(minutes: 20)),
    ("Part of a 6-week plan to get fitter; this is week 3.", nil),
    ("10 min warm up", nil),
    ("skip the hills, my knees hurt", nil),
]
for (text, expected) in parserCases {
    check(LengthParser.request(in: text) == expected, "'\(text)' read as \(String(describing: LengthParser.request(in: text))), expected \(String(describing: expected))")
}

// 5. Workout summary numbers (hand-worked: 3.0 mph at 2% for 60 s, 170 lb)
var walkLog = SampleLog()
for second in stride(from: 0, to: 60, by: 1) { walkLog.add(elapsed: Double(second), mph: 3.0, incline: 2.0) }
check(walkLog.samples.count == 12, "sample log kept \(walkLog.samples.count) samples, expected 12 (one every 5 s)")
let walk = WorkoutSummary.make(samples: walkLog.samples, miles: 0.05, movingSeconds: 60, weightLb: 170)
check(abs(walk.avgMph - 3.0) < 0.001, "average speed \(walk.avgMph), expected 3.0")
check(walk.paceSeconds == 1200, "pace \(String(describing: walk.paceSeconds)), expected 1200 s per mile (20:00)")
check(abs(walk.elevationFeet - 5.28) < 0.05, "elevation gain \(walk.elevationFeet) ft, expected 5.28")
check(walk.calories == 6, "calories \(walk.calories), expected 6")
check(abs(walk.avgIncline - 2.0) < 0.001 && walk.topIncline == 2.0 && walk.topMph == 3.0, "top and average figures are wrong")
var longLog = SampleLog()
for second in stride(from: 0, to: 1500, by: 1) { longLog.add(elapsed: Double(second), mph: 6.0, incline: 0) }
let run = WorkoutSummary.make(samples: longLog.samples, miles: 2.5, movingSeconds: 1500, weightLb: 170)
check(run.samples.count <= WorkoutSummary.maxSamples, "chart data not thinned: \(run.samples.count) samples")
check(run.splits().count == 2 && abs((run.splits().first ?? 0) - 600) <= 20, "mile splits \(run.splits()), expected two near 10:00")
check(run.elevationFeet == 0 && run.calories > 150, "flat run: elevation \(run.elevationFeet), calories \(run.calories)")

// 7. Shape of the workouts (fixes 18 and 25): a workout isn't just the right length, it has a shape
let rampLabels: Set<String> = ["Warm-up", "Ease in", "Ease out", "Cool-down"]
for minutes in 10...90 {
    for kind in WorkoutRequest.Kind.allCases {
        for intensity in WorkoutRequest.Intensity.allCases {
            var request = WorkoutRequest()
            request.minutes = minutes
            request.kind = kind
            request.intensity = intensity
            let w = TemplateCoach.make(request, history: [])
            let name = "\(kind.rawValue)/\(intensity.rawValue) \(minutes) min"
            let n = w.steps.count
            check(n >= 4, "rules \(name) has only \(n) steps")
            guard n >= 4 else { continue }
            check(w.steps.allSatisfy { $0.seconds % 30 == 0 && $0.seconds >= 30 }, "rules \(name) has a step that isn't a multiple of 30 s")
            check(w.steps[0].mph < w.steps[1].mph, "rules \(name): the warm-up doesn't ramp up (\(w.steps[0].mph) then \(w.steps[1].mph))")
            check(w.steps[n - 2].mph > w.steps[n - 1].mph, "rules \(name): the cool-down doesn't ramp down")
            for i in 1..<n {
                check(w.steps[i].mph - w.steps[i - 1].mph <= SafetyCheck.maxSpeedJump + 0.001, "rules \(name): speed jumps by more than 1.5 mph at step \(i)")
            }
            if minutes >= 20, kind == .walk || kind == .jog {
                let blocks = w.steps.filter { !rampLabels.contains($0.label) }
                let speeds = blocks.map(\.mph)
                check(blocks.count >= 2, "rules \(name) has \(blocks.count) main blocks")
                check((speeds.max() ?? 0) - (speeds.min() ?? 0) >= 0.25, "rules \(name): the main blocks are all the same speed")
            }
        }
    }
}

// A flat AI answer is recognised; a varied one is not
let flatAI = [
    WorkoutStep(label: "Warm-up", seconds: 300, mph: 3.0, incline: 0),
    WorkoutStep(label: "Moderate Endurance", seconds: 3000, mph: 3.0, incline: 0),
    WorkoutStep(label: "Cool-down", seconds: 300, mph: 2.5, incline: 0),
]
check(SafetyCheck.isFlat(flatAI), "the flat 3.0 mph workout wasn't recognised as flat")
let variedAI = [
    WorkoutStep(label: "Warm-up", seconds: 300, mph: 3.0, incline: 0),
    WorkoutStep(label: "Steady Walk", seconds: 1200, mph: 3.0, incline: 0),
    WorkoutStep(label: "Light Hill", seconds: 900, mph: 3.5, incline: 2),
    WorkoutStep(label: "Recovery Pace", seconds: 900, mph: 3.0, incline: 0),
    WorkoutStep(label: "Cool-down", seconds: 300, mph: 2.5, incline: 0),
]
check(!SafetyCheck.isFlat(variedAI), "a workout with a hill was called flat")

// AI step lengths are snapped to 30 s without changing the total
for minutes in 10...90 {
    for _ in 0..<100 {
        let made = Workout(name: "ai", summary: "", steps: randomSteps(count: Int.random(in: 1...24, using: &rng)))
        let fixed = SafetyCheck.repair(made, totalMinutes: minutes)
        let snapped = SafetyCheck.snapped(fixed)
        check(snapped.totalSeconds == minutes * 60, "snapping changed the total for \(minutes) min to \(snapped.totalSeconds) s")
        check(snapped.steps.allSatisfy { $0.seconds % 30 == 0 && $0.seconds >= 30 }, "snapping left an odd step length for \(minutes) min")
    }
}
let odd = Workout(name: "ai", summary: "", steps: [
    WorkoutStep(label: "Warm-up", seconds: 155, mph: 3.0, incline: 0),
    WorkoutStep(label: "Main", seconds: 3130, mph: 3.0, incline: 0),
    WorkoutStep(label: "Cool-down", seconds: 315, mph: 2.5, incline: 0),
])
check(SafetyCheck.snapped(odd).totalSeconds == odd.totalSeconds, "snapping the 2:35 / 52:10 / 5:15 workout changed its total")
check(SafetyCheck.snapped(odd).steps.allSatisfy { $0.seconds % 30 == 0 }, "2:35 / 52:10 / 5:15 wasn't snapped to 30 s steps")

// Warm-up and cool-down stay short and distinct (fix 26), with the total unchanged
let longEnds = Workout(name: "ai", summary: "", steps: [
    WorkoutStep(label: "Warm-up", seconds: 270, mph: 3.0, incline: 0),
    WorkoutStep(label: "Warm-up", seconds: 210, mph: 3.2, incline: 0),
    WorkoutStep(label: "Steady", seconds: 1020, mph: 3.0, incline: 0),
    WorkoutStep(label: "Hill", seconds: 690, mph: 3.5, incline: 1),
    WorkoutStep(label: "Recover", seconds: 870, mph: 3.0, incline: 0),
    WorkoutStep(label: "Cool-down", seconds: 360, mph: 2.8, incline: 0),
    WorkoutStep(label: "Cool-down", seconds: 180, mph: 2.6, incline: 0),
])
let trimmed = SafetyCheck.trimmedEnds(longEnds)
check(trimmed.totalSeconds == longEnds.totalSeconds, "trimming changed the total from \(longEnds.totalSeconds) to \(trimmed.totalSeconds)")
check(trimmed.steps.count == longEnds.steps.count, "trimming changed the number of steps")
check(trimmed.steps[1].mph <= trimmed.steps[2].mph + 0.001, "the warm-up still ends faster than the first main step")
check(trimmed.steps[0].seconds + trimmed.steps[1].seconds <= SafetyCheck.maxWarmSeconds, "warm-up still \(trimmed.steps[0].seconds + trimmed.steps[1].seconds) s")
check(trimmed.steps[5].seconds + trimmed.steps[6].seconds <= SafetyCheck.maxCoolSeconds, "cool-down still \(trimmed.steps[5].seconds + trimmed.steps[6].seconds) s")
check(trimmed.steps[1].mph - trimmed.steps[0].mph >= 0.49, "warm-up ramp is only \(trimmed.steps[1].mph - trimmed.steps[0].mph) mph")
check(trimmed.steps[5].mph - trimmed.steps[6].mph >= 0.49, "cool-down ramp is only \(trimmed.steps[5].mph - trimmed.steps[6].mph) mph")
check(trimmed.steps.map(\.label) == ["Warm-up", "Ease in", "Steady", "Hill", "Recover", "Ease out", "Cool-down"], "labels are \(trimmed.steps.map(\.label))")
check(trimmed.steps.allSatisfy { $0.seconds % 30 == 0 && $0.seconds >= 30 }, "a trimmed step isn't on a 30 s mark")
check(Array(trimmed.steps[2...4]).reduce(0, { $0 + $1.seconds }) > Array(longEnds.steps[2...4]).reduce(0, { $0 + $1.seconds }), "the extra time didn't go to the main steps")
for minutes in 10...90 {
    for _ in 0..<100 {
        let made = Workout(name: "ai", summary: "", steps: randomSteps(count: Int.random(in: 1...24, using: &rng)))
        let before = SafetyCheck.snapped(SafetyCheck.repair(made, totalMinutes: minutes))
        let after = SafetyCheck.trimmedEnds(before)
        check(after.totalSeconds == before.totalSeconds, "trimming changed the total for \(minutes) min")
        check(after.steps.count >= before.steps.count && after.steps.count <= before.steps.count + 2, "trimming changed the step count for \(minutes) min from \(before.steps.count) to \(after.steps.count)")
        check(after.steps.allSatisfy { $0.seconds % 30 == 0 && $0.seconds >= 30 }, "trimming left an odd step length for \(minutes) min")
        check(after.problems.isEmpty, "trimming created problems for \(minutes) min: \(after.problems)")
    }
}

// The 0.7.4 workout with a "Cool-down" as step 3 and a warm-up faster than the walk (fix 27)
let misplaced = Workout(name: "ai", summary: "", steps: [
    WorkoutStep(label: "Warm-up", seconds: 150, mph: 3.0, incline: 0),
    WorkoutStep(label: "Warm-up", seconds: 150, mph: 3.5, incline: 0),
    WorkoutStep(label: "Cool-down", seconds: 270, mph: 2.8, incline: 0),
    WorkoutStep(label: "Hill 1", seconds: 480, mph: 3.2, incline: 1),
    WorkoutStep(label: "Steady walk", seconds: 660, mph: 3.0, incline: 0),
    WorkoutStep(label: "Hill 2", seconds: 480, mph: 3.7, incline: 2),
    WorkoutStep(label: "Steady walk", seconds: 690, mph: 3.0, incline: 0),
    WorkoutStep(label: "Hill 3", seconds: 480, mph: 3.4, incline: 3),
    WorkoutStep(label: "Cool-down", seconds: 240, mph: 2.8, incline: 0),
])
let fixed27 = SafetyCheck.trimmedEnds(misplaced)
check(fixed27.totalSeconds == misplaced.totalSeconds, "fix 27 changed the total to \(fixed27.totalSeconds) s")
check(fixed27.steps[2].label == "Recover", "the middle Cool-down is now called \(fixed27.steps[2].label)")
check(fixed27.steps.filter { $0.label.lowercased().contains("cool") }.count == 1 && fixed27.steps.last?.label == "Cool-down", "the cool-down isn't only at the end: \(fixed27.steps.map(\.label))")
check(fixed27.steps.filter { $0.label == "Warm-up" || $0.label == "Ease in" }.count == 2, "warm-up steps are \(fixed27.steps.map(\.label))")
check(fixed27.steps[1].mph <= fixed27.steps[2].mph + 0.001, "the warm-up still ends faster than the first main step")
check(fixed27.steps[1].mph - fixed27.steps[0].mph >= 0.49, "the warm-up doesn't ramp")
check(fixed27.steps.count == misplaced.steps.count + 1, "the single cool-down wasn't split in two: \(fixed27.steps.count) steps")
check(WorkoutEdits.isCooldown(fixed27.steps[2]) == false, "live edits would treat the Recover step as the cool-down")
check(fixed27.steps.allSatisfy { $0.seconds % 30 == 0 && $0.seconds >= 30 }, "fix 27 left an odd step length")

// The chosen type is checked (fix 28): rules workouts of every type pass, walking passes as nothing else
for minutes in 20...90 {
    for kind in [WorkoutRequest.Kind.walk, .jog, .intervals, .hills] {
        for intensity in WorkoutRequest.Intensity.allCases {
            for h in [[], history] {
                var request = WorkoutRequest()
                request.minutes = minutes
                request.kind = kind
                request.intensity = intensity
                let w = TemplateCoach.make(request, history: h)
                check(SafetyCheck.matchesKind(w.steps, kind: kind, minutes: minutes),
                      "rules \(kind.rawValue)/\(intensity.rawValue) \(minutes) min doesn't pass its own type check")
            }
        }
    }
}
check(!SafetyCheck.matchesKind(variedAI, kind: .intervals, minutes: 60), "a walk with one hill passed as intervals")
check(!SafetyCheck.matchesKind(fixed27.steps, kind: .intervals, minutes: 60), "the 0.7.4 walk passed as intervals")
check(!SafetyCheck.matchesKind(flatAI, kind: .hills, minutes: 60), "a flat walk passed as hills")
check(!SafetyCheck.matchesKind(variedAI, kind: .jog, minutes: 60), "a 3.5 mph walk passed as a jog")
check(SafetyCheck.matchesKind(variedAI, kind: .walk, minutes: 60), "a walk didn't pass as a walk")
var intervalAI: [WorkoutStep] = [WorkoutStep(label: "Warm-up", seconds: 300, mph: 3.0, incline: 0)]
for round in 1...6 {
    intervalAI.append(WorkoutStep(label: "Fast \(round)", seconds: 120, mph: 4.2, incline: 1))
    intervalAI.append(WorkoutStep(label: "Recover \(round)", seconds: 180, mph: 3.0, incline: 0))
}
intervalAI.append(WorkoutStep(label: "Cool-down", seconds: 240, mph: 2.6, incline: 0))
check(SafetyCheck.matchesKind(intervalAI, kind: .intervals, minutes: 60), "a real interval workout failed the intervals check")
check(SafetyCheck.matchesKind(flatAI, kind: .intervals, minutes: 15), "short workouts must not be type-checked")

// Interval quality and length (fix 30), replaying the answers from the 0.7.5 log
func raw(_ label: String, _ minutes: Int, _ seconds: Int, _ mph: Double) -> WorkoutStep {
    WorkoutStep(label: label, seconds: minutes * 60 + seconds, mph: mph, incline: 0)
}
let short30 = Workout(name: "ai", summary: "", steps: [
    raw("Warm-up", 1, 0, 2.0), raw("Warm-up", 2, 0, 2.5),
    raw("Fast 1/6", 1, 30, 4.2), raw("Recover", 1, 30, 3.0), raw("Fast 2/6", 1, 30, 4.5), raw("Recover", 1, 30, 3.0),
    raw("Fast 3/6", 1, 30, 4.8), raw("Recover", 1, 30, 3.0), raw("Fast 4/6", 1, 30, 5.0), raw("Recover", 1, 30, 3.0),
    raw("Fast 5/6", 1, 30, 5.2), raw("Recover", 1, 30, 3.0), raw("Fast 6/6", 1, 30, 5.5), raw("Cool-down", 2, 0, 3.0),
])
check(short30.totalSeconds == 1290, "the 30-min log case adds up to \(short30.totalSeconds) s")
check(!SafetyCheck.lengthIsClose(short30.totalSeconds, to: 1800), "21.5 min for a 30 min request was called close")
check(SafetyCheck.lengthIsClose(3600, to: 3600) && SafetyCheck.lengthIsClose(4050, to: 3600) && SafetyCheck.lengthIsClose(3200, to: 3600),
      "lengths within 15% should be close")
check(!SafetyCheck.lengthIsClose(4300, to: 3600), "a length 19% over was called close")
let easy60 = Workout(name: "ai", summary: "", steps: [
    raw("Warm-up", 1, 30, 2.5), raw("Warm-up ramp", 1, 30, 2.8), raw("Cool-down", 1, 30, 2.2),
    raw("Fast 1/6", 1, 30, 3.8), raw("Recover 1/6", 1, 30, 3.0), raw("Fast 2/6", 3, 0, 4.2), raw("Recover 2/6", 3, 0, 3.0),
    raw("Fast 3/6", 4, 30, 4.5), raw("Recover 3/6", 4, 30, 3.0), raw("Fast 4/6", 6, 0, 4.7), raw("Recover 4/6", 6, 0, 3.0),
    raw("Fast 5/6", 7, 30, 5.0), raw("Recover 5/6", 7, 30, 3.0), raw("Fast 6/6", 9, 0, 5.2), raw("Cool-down", 9, 0, 2.2),
])
check(easy60.totalSeconds == 4050, "the 60-min log case adds up to \(easy60.totalSeconds) s")
let easyFixed = SafetyCheck.trimmedEnds(SafetyCheck.snapped(SafetyCheck.repair(easy60, totalMinutes: 60)))
check(easyFixed.totalSeconds == 3600, "the repaired 60-min log case is \(easyFixed.totalSeconds) s")
check(SafetyCheck.intervalProblem(easyFixed.steps, comfortable: 3.0, intensity: .easy, minutes: 60) != nil,
      "the 60-min Easy log case (fast steps up to 9 min at 5.2 mph) was accepted")
check(SafetyCheck.easyPaceProblem(easyFixed.steps, kind: .intervals, intensity: .easy, comfortable: 3.0) != nil,
      "an Easy workout at 5.2 mph passed the easy pace check")
check(SafetyCheck.easyPaceProblem(easyFixed.steps, kind: .jog, intensity: .easy, comfortable: 3.0) == nil, "jogs must be exempt from the easy pace check")
check(SafetyCheck.easyPaceProblem(easyFixed.steps, kind: .intervals, intensity: .moderate, comfortable: 3.0) == nil, "only Easy has the pace cap")
check(SafetyCheck.intervalProblem(intervalAI, comfortable: 3.0, intensity: .moderate, minutes: 60) == nil,
      "a proper interval workout (2 min at 4.2, 3 min recoveries) was rejected: \(SafetyCheck.intervalProblem(intervalAI, comfortable: 3.0, intensity: .moderate, minutes: 60) ?? "")")
check(SafetyCheck.intervalProblem(intervalAI, comfortable: 3.0, intensity: .easy, minutes: 60) != nil, "4.2 mph intervals passed as Easy for a 3.0 mph walker")
check(SafetyCheck.intervalProblem(intervalAI, comfortable: 3.0, intensity: .moderate, minutes: 15) == nil, "short workouts must not be quality-checked")
check(SafetyCheck.easyPaceProblem(variedAI, kind: .walk, intensity: .easy, comfortable: 3.0) == nil, "a 3.5 mph easy walk was rejected")
var noRecovery = intervalAI
noRecovery[2].mph = 4.2   // the recovery after the first fast step is fast too
check(SafetyCheck.intervalProblem(noRecovery, comfortable: 3.0, intensity: .moderate, minutes: 60) != nil, "a fast step with no recovery passed")

// Cloud AI (fixes 31 and 32): the prompt, its examples, and reading answers
for kind in [WorkoutRequest.Kind.walk, .jog, .intervals, .hills] {
    let steps = WorkoutPrompt.exampleSteps(for: kind)
    let example = Workout(name: "example", summary: "", steps: steps)
    check(example.totalSeconds == 2400, "the \(kind.rawValue) example adds up to \(example.totalSeconds) s, not 2400")
    check(example.problems.isEmpty, "the \(kind.rawValue) example has problems: \(example.problems)")
    check(SafetyCheck.matchesKind(steps, kind: kind, minutes: 40), "the \(kind.rawValue) example doesn't pass its own type check")
    check(!SafetyCheck.isFlat(steps), "the \(kind.rawValue) example is flat")
    if kind == .intervals {
        check(SafetyCheck.intervalProblem(steps, comfortable: 3.0, intensity: .moderate, minutes: 40) == nil,
              "the intervals example fails the interval check: \(SafetyCheck.intervalProblem(steps, comfortable: 3.0, intensity: .moderate, minutes: 40) ?? "")")
    }
    for i in 1..<steps.count {
        check(steps[i].mph - steps[i - 1].mph <= SafetyCheck.maxSpeedJump + 0.001, "the \(kind.rawValue) example jumps by more than 1.5 mph at step \(i + 1)")
    }
    let cleaned = SafetyCheck.trimmedEnds(example)
    check(cleaned.steps.map(\.seconds) == steps.map(\.seconds) && cleaned.steps.map(\.label) == steps.map(\.label),
          "the \(kind.rawValue) example is changed by the end clean-up")
    let reread = WorkoutPrompt.parse(WorkoutPrompt.exampleJSON(for: kind))
    check(reread?.steps.count == steps.count && reread?.totalSeconds == 2400, "the \(kind.rawValue) example JSON doesn't read back")
}
let fenced = "Sure! Here you go:\n```json\n{\"name\": \"Test\", \"summary\": \"x\", \"steps\": [{\"label\": \"Warm-up\", \"seconds\": 120, \"mph\": 2.0, \"incline\": 0}, {\"label\": \"Main\", \"seconds\": \"600\", \"mph\": \"3.0\"}]}\n```\nEnjoy!"
let parsed = WorkoutPrompt.parse(fenced)
check(parsed?.steps.count == 2 && parsed?.steps[1].seconds == 600 && parsed?.steps[1].mph == 3.0 && parsed?.steps[1].incline == 0,
      "a fenced reply with text-number fields wasn't read correctly")
check(WorkoutPrompt.parse("I could not do that.") == nil, "a reply without JSON was accepted")
check(WorkoutPrompt.parse("{\"steps\": []}") == nil, "an empty steps list was accepted")
check(WorkoutPrompt.parse("{\"steps\": [{\"label\": \"a\"}]}") == nil, "a step without seconds was accepted")
check(WorkoutPrompt.typeGuide(.intervals, base: 3.0, intensity: .easy).contains("3.5 to 4.0 mph"), "the Easy interval guide should say 3.5 to 4.0 mph")
check(WorkoutPrompt.typeGuide(.intervals, base: 3.0, intensity: .hard).contains("4.2 to 5.0 mph"), "the Hard interval guide should say 4.2 to 5.0 mph")
check(WorkoutPrompt.retry(reason: "a fast step lasts 9:00", seconds: 3600).contains("a fast step lasts 9:00")
      && WorkoutPrompt.retry(reason: "x", seconds: 3600).contains("3600"), "the retry message lacks the reason or the length")
check(WorkoutPrompt.cloudInstructions(for: .intervals).contains(WorkoutPrompt.rules) && WorkoutPrompt.cloudInstructions(for: .intervals).contains("JSON"),
      "the cloud instructions lack the rules or the JSON format")
// The Easy interval workout the free OVHcloud model made (2 min at 4.0 mph, 3 min at 3.0 mph) is accepted: the prompt and the checks agree
var easyOVH: [WorkoutStep] = [WorkoutStep(label: "Warm-up", seconds: 120, mph: 2.5, incline: 0), WorkoutStep(label: "Ease in", seconds: 180, mph: 3.0, incline: 0)]
for round in 1...10 {
    easyOVH.append(WorkoutStep(label: "Interval \(round) - Fast", seconds: 120, mph: 4.0, incline: 0))
    easyOVH.append(WorkoutStep(label: "Interval \(round) - Recovery", seconds: 180, mph: 3.0, incline: 0))
}
easyOVH.append(WorkoutStep(label: "Ease out", seconds: 120, mph: 2.5, incline: 0))
easyOVH.append(WorkoutStep(label: "Cool-down", seconds: 120, mph: 2.0, incline: 0))
check(SafetyCheck.intervalProblem(easyOVH, comfortable: 3.0, intensity: .easy, minutes: 60) == nil, "the good Easy interval workout was rejected by the interval check")
check(SafetyCheck.easyPaceProblem(easyOVH, kind: .intervals, intensity: .easy, comfortable: 3.0) == nil, "the good Easy interval workout was rejected by the easy pace check")
check(SafetyCheck.matchesKind(easyOVH, kind: .intervals, minutes: 60), "the good Easy interval workout doesn't pass the type check")

// Heart-rate messages (fix 38)
func hr(_ bytes: [UInt8]) -> HeartRateParser.Reading? { HeartRateParser.parse(Data(bytes)) }
check(hr([0x00, 72]) == HeartRateParser.Reading(bpm: 72, contact: nil, rr: []), "plain 8-bit heart rate")
check(hr([0x01, 0x2C, 0x01])?.bpm == 300, "16-bit heart rate 0x012C should be 300")
check(hr([0x10, 70, 0x00, 0x04]) == HeartRateParser.Reading(bpm: 70, contact: nil, rr: [1000]), "beat interval 1024/1024 s should be 1000 ms")
check(hr([0x06, 80])?.contact == true && hr([0x04, 80])?.contact == false, "contact flags")
check(hr([0x18, 90, 0x10, 0x00, 0x00, 0x04])?.rr == [1000] && hr([0x18, 90, 0x10, 0x00, 0x00, 0x04])?.bpm == 90, "energy field must be skipped")
check(hr([]) == nil && hr([0x00]) == nil && hr([0x01, 0x10]) == nil, "short messages must be refused")
var beatLog = SampleLog()
for second in stride(from: 0, to: 60, by: 1) { beatLog.add(elapsed: Double(second), mph: 3.0, incline: 1.0, bpm: second < 30 ? 100 : 140) }
let beatSummary = WorkoutSummary.make(samples: beatLog.samples, miles: 0.05, movingSeconds: 60, weightLb: 170)
check(beatSummary.avgBpm == 120 && beatSummary.peakBpm == 140, "heart rate summary \(String(describing: beatSummary.avgBpm)) / \(String(describing: beatSummary.peakBpm)), expected 120 / 140")
check(walk.avgBpm == nil && walk.peakBpm == nil, "a session without a sensor must have no heart rate")

// Heart-rate hold (fixes 39 and 42): against a simulated heart that follows speed and incline with a 30 s lag
func simulateHold(control: HeartRateHold.Control, target: Int, limits: HeartRateHold.Limits, seconds: Int)
    -> (bpm: Double, mph: Double, incline: Double, warned: Bool) {
    var hold = HeartRateHold(target: target, control: control)
    var bpm = 118.0
    var mph = 3.0
    var incline = 0.0
    var warned = false
    let start = Date(timeIntervalSince1970: 2_000_000)
    for second in 1...seconds {
        let now = start.addingTimeInterval(Double(second))
        bpm += (70 + 25 * (mph - 1) + 4 * incline - bpm) / 30
        hold.add(bpm: Int(bpm.rounded()), at: now)
        switch hold.evaluate(now: now, baseMph: 3.0, baseIncline: 0, limits: limits, signalFresh: true) {
        case .change(let ds, let di, _):
            mph += ds
            incline += di
        case .warn:
            warned = true
        case .none:
            break
        }
    }
    return (bpm, mph, incline, warned)
}
let wide = HeartRateHold.Limits(minMph: 1.0, maxMph: 4.0, maxIncline: 6.0)
for control in HeartRateHold.Control.allCases {
    let result = simulateHold(control: control, target: 135, limits: wide, seconds: 900)
    check(abs(result.bpm - 135) <= 6, "hold \(control.rawValue): heart rate ended at \(Int(result.bpm)), target 135")
    check(result.mph <= 4.0001 && result.mph >= 1.0 && result.incline >= -0.0001 && result.incline <= 6.0001,
          "hold \(control.rawValue) left its limits: \(result.mph) mph, \(result.incline)%")
}
let tight = simulateHold(control: .speed, target: 170, limits: HeartRateHold.Limits(minMph: 1.0, maxMph: 3.2, maxIncline: 4), seconds: 900)
check(tight.mph <= 3.2001 && tight.warned, "a target out of reach must stop at the speed limit and say so (speed \(tight.mph))")
let lowTarget = simulateHold(control: .speed, target: 100, limits: wide, seconds: 900)
check(lowTarget.mph >= 1.0 - 0.0001 && lowTarget.bpm < 118, "a low target must slow down but not below the minimum speed")
var guardHold = HeartRateHold(target: 140, control: .speed)
let t0h = Date(timeIntervalSince1970: 3_000_000)
for second in 1...5 { guardHold.add(bpm: 170, at: t0h.addingTimeInterval(Double(second))) }
if case .change(let ds, _, let text) = guardHold.evaluate(now: t0h.addingTimeInterval(6), baseMph: 3.0, baseIncline: 0, limits: wide, signalFresh: true) {
    check(abs(ds + 0.3) < 0.001 && text.contains("far above"), "a heart rate 30 over the target should cut the speed by 0.3 mph and say so, got \(ds): \(text)")
} else {
    check(false, "a heart rate far above the target didn't slow the belt")
}
check(guardHold.evaluate(now: t0h.addingTimeInterval(7), baseMph: 3.0, baseIncline: 0, limits: wide, signalFresh: false) != .none, "no signal must give a warning, not a change")
check(guardHold.evaluate(now: t0h.addingTimeInterval(8), baseMph: 3.0, baseIncline: 0, limits: wide, signalFresh: true) == .none, "adjustments must be at least 15 s apart")
var handHold = HeartRateHold(target: 140, control: .speed)
for second in 1...5 { handHold.add(bpm: 120, at: t0h.addingTimeInterval(Double(second))) }
handHold.userChanged(at: t0h.addingTimeInterval(5))
check(handHold.evaluate(now: t0h.addingTimeInterval(20), baseMph: 3.0, baseIncline: 0, limits: wide, signalFresh: true) == .none,
      "the hold must wait 45 s after a change by hand")

// The ends of a workout are found by name, including "Finish" (fix 35)
let finishWorkout = Workout(name: "ai", summary: "", steps: [
    WorkoutStep(label: "Warm-up", seconds: 120, mph: 2.0, incline: 0), WorkoutStep(label: "Warm-up 2", seconds: 180, mph: 2.5, incline: 0),
    WorkoutStep(label: "Block 1", seconds: 900, mph: 3.0, incline: 1), WorkoutStep(label: "Block 2", seconds: 900, mph: 3.2, incline: 2),
    WorkoutStep(label: "Block 3", seconds: 1200, mph: 3.0, incline: 0), WorkoutStep(label: "Cool down", seconds: 180, mph: 2.5, incline: 0),
    WorkoutStep(label: "Finish", seconds: 120, mph: 2.0, incline: 0),
])
let finishFixed = SafetyCheck.trimmedEnds(finishWorkout)
check(finishFixed.steps.map(\.label) == ["Warm-up", "Ease in", "Block 1", "Block 2", "Block 3", "Ease out", "Cool-down"],
      "labels with Finish: \(finishFixed.steps.map(\.label))")
check(finishFixed.totalSeconds == finishWorkout.totalSeconds, "the ends clean-up changed the total")

// Live coach answers from a cloud model (fix 34)
let editReply = "Here you go: {\"summary\": \"Hills added.\", \"isChange\": true, \"changeCurrentStep\": false, \"currentMph\": 3.0, \"currentIncline\": 0, \"remaining\": [{\"label\": \"Recover\", \"seconds\": 90, \"mph\": 2.7, \"incline\": 3}]}"
let edit = WorkoutPrompt.parseEdit(editReply)
check(edit?.isChange == true && edit?.steps.count == 1 && edit?.steps.first?.incline == 3 && edit?.summary == "Hills added.", "a live edit reply wasn't read correctly")
let hello = WorkoutPrompt.parseEdit("{\"summary\": \"Hi! Tell me what to change.\", \"isChange\": false, \"changeCurrentStep\": false, \"remaining\": []}")
check(hello?.isChange == false && hello?.steps.isEmpty == true, "a greeting reply should be read as no change")
check(WorkoutPrompt.parseEdit("nothing here") == nil && WorkoutPrompt.parseEdit("{\"summary\": \"x\"}") == nil, "a reply without steps was accepted as an edit")

// Incline choices and effort (fix 41), joint limits and interval lengths (fix 36)
var painful = WorkoutRequest()
painful.notes = "my legs are a bit sore"
check(painful.gentle && painful.effectiveIncline == .none, "a note about sore legs should mean no incline")
painful.notes = "legs are sore but add some hills"
check(!painful.gentle && painful.effectiveIncline == .some, "asking for hills overrides the sore note")
var steep = WorkoutRequest()
steep.effortFrom = .incline
check(steep.effectiveIncline == .lots && steep.effectiveEffort == .incline, "effort from incline means lots of incline")
steep.incline = .none
check(steep.effectiveIncline == .none && steep.effectiveEffort == .mix, "no incline wanted cancels the incline effort")
var fastOnly = WorkoutRequest()
fastOnly.incline = .lots
fastOnly.effortFrom = .speed
check(fastOnly.effectiveIncline == .some, "effort from speed keeps the incline at some")
check(SafetyCheck.inclineCap(forMph: 3.0) == 10 && SafetyCheck.inclineCap(forMph: 4.0) == 8 && SafetyCheck.inclineCap(forMph: 5.0) == 6, "speed and incline cap")
let steepFast = SafetyCheck.repair(Workout(name: "x", summary: "", steps: [
    WorkoutStep(label: "Warm-up", seconds: 600, mph: 2.0, incline: 0), WorkoutStep(label: "Hard", seconds: 1200, mph: 5.0, incline: 9),
    WorkoutStep(label: "Cool-down", seconds: 600, mph: 2.0, incline: 0),
]), totalMinutes: 40)
check(steepFast.steps.allSatisfy { $0.incline <= SafetyCheck.inclineCap(forMph: $0.mph) + 0.001 }, "repair left a steep and fast step")
check(zip(steepFast.steps, steepFast.steps.dropFirst()).allSatisfy { $1.incline - $0.incline <= SafetyCheck.maxInclineJump + 0.001 }, "repair left an incline jump over 3%")

let comfortable0 = TemplateCoach.baseSpeed(history: [])
for minutes in stride(from: 20, through: 90, by: 5) {
    for kind in [WorkoutRequest.Kind.walk, .jog, .intervals, .hills] {
        for intensity in WorkoutRequest.Intensity.allCases {
            for choice in WorkoutRequest.InclineChoice.allCases {
                for effort in WorkoutRequest.EffortFrom.allCases {
                    for sore in [false, true] {
                        var r = WorkoutRequest()
                        r.minutes = minutes
                        r.kind = kind
                        r.intensity = intensity
                        r.incline = choice
                        r.effortFrom = effort
                        if sore { r.notes = "my legs are sore" }
                        let w = TemplateCoach.make(r, history: [])
                        let name = "rules \(kind.rawValue)/\(intensity.rawValue) incline \(choice.rawValue) effort \(effort.rawValue)\(sore ? " sore" : "") \(minutes) min"
                        check(w.totalSeconds == minutes * 60 && w.problems.isEmpty, "\(name): length \(w.totalSeconds) or problems \(w.problems)")
                        for i in w.steps.indices {
                            check(w.steps[i].incline <= SafetyCheck.inclineCap(forMph: w.steps[i].mph) + 0.001, "\(name): steep and fast at step \(i + 1)")
                            if i > 0 { check(w.steps[i].incline - w.steps[i - 1].incline <= 3.001, "\(name): incline jumps at step \(i + 1)") }
                        }
                        check(SafetyCheck.matchesKind(w.steps, kind: kind, minutes: minutes, effort: r.effectiveEffort), "\(name): doesn't pass its own type check")
                        check(SafetyCheck.inclineProblem(w.steps, request: r, comfortable: comfortable0) == nil,
                              "\(name): incline check says \(SafetyCheck.inclineProblem(w.steps, request: r, comfortable: comfortable0) ?? "")")
                        if sore && kind != .hills { check(w.steps.allSatisfy { $0.incline == 0 }, "\(name): a sore note must keep the incline at 0") }
                    }
                }
            }
        }
    }
}
for (minutes, fastSeconds) in [(20, 60), (30, 60), (31, 90), (50, 90), (51, 120), (90, 120)] {
    var r = WorkoutRequest()
    r.minutes = minutes
    r.kind = .intervals
    r.incline = .none
    let w = TemplateCoach.make(r, history: [])
    let fasts = w.steps.filter { $0.label.hasPrefix("Fast") }
    check(!fasts.isEmpty && fasts.allSatisfy { $0.seconds == fastSeconds }, "intervals for \(minutes) min should use \(fastSeconds) s fast steps, got \(fasts.map(\.seconds))")
}
var sixty = WorkoutRequest()
sixty.minutes = 60
sixty.kind = .intervals
let sixtyFasts = TemplateCoach.make(sixty, history: []).steps.filter { $0.label.hasPrefix("Fast") }.count
check(sixtyFasts >= 8 && sixtyFasts <= 12, "60 min of intervals should be about 10 pairs, got \(sixtyFasts)")

// 6. Treadmill command rules (CommandPacer): replayed second by second, no Bluetooth
let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

// 25 quick taps: one command goes out at once, the rest wait for the cooldown, and the last tap wins
do {
    var pacer = CommandPacer()
    var sent: [CommandPacer.Send] = []
    for tap in 0..<25 {
        pacer.requestSpeed(5.0 - Double(tap) * 0.1)
        if let send = pacer.next(now: at(Double(tap) * 0.04), speedReading: 5.0, inclineReading: 0) { sent.append(send) }
    }
    check(sent.count == 1, "25 taps in one second sent \(sent.count) speed commands, expected 1")
    check(pacer.next(now: at(0.5), speedReading: 5.0, inclineReading: 0) == nil, "a speed command went out before the 1 s cooldown")
    if case .speed(let last)? = pacer.next(now: at(1.05), speedReading: 5.0, inclineReading: 0) {
        check(abs(last - 2.6) < 0.001, "after the cooldown the last tap (2.6 mph) should go out, not \(last)")
    } else {
        check(false, "the last tap never went out after the cooldown")
    }
    check(pacer.next(now: at(1.1), speedReading: 5.0, inclineReading: 0) == nil, "nothing more should be waiting")
}

// Speed and incline are paced separately, one command per call
do {
    var pacer = CommandPacer()
    pacer.requestSpeed(2.0)
    pacer.requestIncline(3.0)
    check(pacer.next(now: at(0), speedReading: 1, inclineReading: 0) == .speed(2.0), "speed should go first")
    check(pacer.next(now: at(0), speedReading: 1, inclineReading: 0) == .incline(3.0), "incline should go next")
    check(pacer.next(now: at(0), speedReading: 1, inclineReading: 0) == nil, "nothing should be left")
}

// Stop (clear) throws away everything waiting and everything being checked
do {
    var pacer = CommandPacer()
    pacer.requestSpeed(2.0)
    pacer.requestIncline(3.0)
    _ = pacer.next(now: at(0), speedReading: 1, inclineReading: 0)
    pacer.clear()
    check(pacer.next(now: at(5), speedReading: 1, inclineReading: 0) == nil, "clear left a command waiting")
    check(pacer.verify(now: at(6), speedReading: 1, inclineReading: 0) == nil && pacer.wantIncline == nil && pacer.wantSpeed == nil,
          "clear left a command being checked")
}

// The console drops an incline after Start: it is sent again, up to 3 more times, then given up
do {
    var pacer = CommandPacer()
    pacer.markStart(at(0))
    pacer.requestIncline(3.0)
    check(pacer.next(now: at(0.1), speedReading: 1, inclineReading: 0) == .incline(3.0), "first incline send")
    check(pacer.verify(now: at(3.0), speedReading: 1, inclineReading: 3.0) == nil, "a reading that matches must not trigger a resend")
    check(pacer.pendingIncline == nil, "a matching reading queued a resend")
    var sends = 1
    var problem: String?
    var clock = 3.5
    for _ in 0..<6 where problem == nil {
        problem = pacer.verify(now: at(clock), speedReading: 1, inclineReading: 0)  // fell back to 0
        if problem == nil, pacer.next(now: at(clock + 0.1), speedReading: 1, inclineReading: 0) == .incline(3.0) { sends += 1 }
        clock += 3.2
    }
    check(sends == CommandPacer.maxSends, "incline was sent \(sends) times, expected \(CommandPacer.maxSends)")
    check(problem?.contains("Incline") == true, "no 'Incline didn't take' message after the last resend")
    check(pacer.wantIncline == nil, "a given-up command is still being checked")
}

// A refusal right after a command sends it again; a refusal long after does not
do {
    var pacer = CommandPacer()
    pacer.requestSpeed(2.0)
    _ = pacer.next(now: at(0), speedReading: 3.0, inclineReading: 0)
    check(pacer.refused(now: at(1)) == nil && pacer.pendingSpeed == 2.0, "a refusal after a command should queue it again")
    check(pacer.next(now: at(2), speedReading: 3.0, inclineReading: 0) == .speed(2.0), "the refused speed should go out again")
    check(pacer.refused(now: at(30)) == nil && pacer.pendingSpeed == nil, "a refusal 28 s later must not resend")
}

// A change made on the console is never fought, for speed or incline
do {
    var pacer = CommandPacer()
    pacer.requestSpeed(2.5)
    pacer.requestIncline(4.0)
    _ = pacer.next(now: at(0), speedReading: 3.0, inclineReading: 1.0)
    _ = pacer.next(now: at(0), speedReading: 3.0, inclineReading: 1.0)
    // the user presses the console: speed 2.0 (not the command, not the old 3.0), incline 2.0
    check(pacer.verify(now: at(4), speedReading: 2.0, inclineReading: 2.0) == nil, "console change produced a message")
    check(pacer.pendingSpeed == nil && pacer.pendingIncline == nil, "the app resent a command over a console change")
}

// A command that took is watched, then forgotten
do {
    var pacer = CommandPacer()
    pacer.requestSpeed(2.5)
    _ = pacer.next(now: at(0), speedReading: 3.0, inclineReading: 0)
    check(pacer.verify(now: at(4), speedReading: 2.5, inclineReading: 0) == nil && pacer.pendingSpeed == nil, "a matching speed was resent")
    check(pacer.verify(now: at(20), speedReading: 2.5, inclineReading: 0) == nil && pacer.wantSpeed == nil, "a confirmed command is never forgotten")
}

print("\(checks) checks, \(failures.count) failures")
for failure in failures.prefix(25) { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
