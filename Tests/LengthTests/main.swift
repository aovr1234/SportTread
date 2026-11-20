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

// About you, zones, zone watch and the fitness test (fixes 43, 44, 45)
check(BodyProfile.startingSpeed(heightInches: nil) == 3.0 && BodyProfile.startingSpeed(heightInches: 68) == 3.0, "starting speed for 5'8\" or unknown")
check(BodyProfile.startingSpeed(heightInches: 74) == 3.1 && BodyProfile.startingSpeed(heightInches: 60) == 2.8, "starting speed for 6'2\" (3.1) and 5'0\" (2.8)")
check(BodyProfile.startingSpeed(heightInches: 95) <= 3.6 && BodyProfile.startingSpeed(heightInches: 41) >= 2.6, "starting speed must stay between 2.6 and 3.6")
check(TemplateCoach.baseSpeed(history: [], heightInches: 74) == 3.1 && TemplateCoach.baseSpeed(history: []) == 3.0, "base speed with and without a height")
var calProfile = BodyProfile()
check(calProfile.maxHeartRate == nil && calProfile.zones == nil, "no age, no maximum heart rate")
calProfile.age = 40
check(calProfile.maxHeartRate == 180, "208 - 0.7 x 40 should be 180, got \(String(describing: calProfile.maxHeartRate))")
calProfile.measuredMaxBpm = 190
check(calProfile.maxHeartRate == 190, "a measured maximum must win over the formula")
let cal180 = HeartZones(maxBpm: 180, restingBpm: nil)
check(abs(cal180.range(2).lowerBound - 108) < 1e-9 && abs(cal180.range(2).upperBound - 126) < 1e-9 && abs(cal180.range(5).upperBound - 180) < 1e-9, "zones as shares of the maximum")
check(cal180.zone(for: 85) == 0 && cal180.zone(for: 100) == 1 && cal180.zone(for: 120) == 2 && cal180.zone(for: 200) == 5, "zone numbers")
let calKarvonen = HeartZones(maxBpm: 180, restingBpm: 60)
check(abs(calKarvonen.range(2).lowerBound - 132) < 1e-9 && abs(calKarvonen.range(2).upperBound - 144) < 1e-9 && calKarvonen.midpoint(2) == 138, "zones from the heart-rate reserve")
var zoneLog = SampleLog()
for second in stride(from: 0, to: 60, by: 1) { zoneLog.add(elapsed: Double(second), mph: 3.0, incline: 0, bpm: second < 30 ? 100 : 120) }
let zoneSummary = WorkoutSummary.make(samples: zoneLog.samples, miles: 0.05, movingSeconds: 60, weightLb: 170, zones: cal180)
check(zoneSummary.zoneSeconds == [30, 30, 0, 0, 0], "time in zones \(String(describing: zoneSummary.zoneSeconds)), expected [30, 30, 0, 0, 0]")
check(WorkoutSummary.make(samples: zoneLog.samples, miles: 0.05, movingSeconds: 60, weightLb: 170).zoneSeconds == nil, "no zones without a maximum heart rate")

func watchVerdicts(bpm: Int, seconds: Int) -> [(Int, ZoneWatch.Verdict)] {
    var watch = ZoneWatch(zone: 2)
    var found: [(Int, ZoneWatch.Verdict)] = []
    let start = Date(timeIntervalSince1970: 4_000_000)
    for second in 1...seconds {
        let now = start.addingTimeInterval(Double(second))
        watch.add(bpm: bpm, at: now)
        if let verdict = watch.evaluate(now: now, zones: cal180, signalFresh: true) { found.append((second, verdict)) }
    }
    return found
}
let easyWatch = watchVerdicts(bpm: 100, seconds: 600)
check(easyWatch.count == 2 && easyWatch[0].1 == .tooEasy && (240...250).contains(easyWatch[0].0) && easyWatch[1].0 >= easyWatch[0].0 + 300,
      "below the zone: \(easyWatch.map { "\($0.0)s" }), expected two 'too easy' verdicts, the first near 243 s and 300 s apart")
let hardWatch = watchVerdicts(bpm: 140, seconds: 130)
check(hardWatch.count == 1 && hardWatch[0].1 == .tooHard && (120...130).contains(hardWatch[0].0), "above the zone: \(hardWatch.map { "\($0.0)s" })")
check(watchVerdicts(bpm: 115, seconds: 600).isEmpty, "inside the zone must give no verdict")

let calPlan = CalibrationPlan.workout(comfortable: 3.0, withIncline: false)
check(calPlan.workout.totalSeconds == 1440 && calPlan.workout.problems.isEmpty, "fitness test of \(calPlan.workout.totalSeconds) s, problems \(calPlan.workout.problems)")
check(calPlan.stages.map(\.mph) == [2.2, 2.6, 3.0, 3.4, 3.8, 4.2] && calPlan.stages.allSatisfy { $0.incline == 0 }, "stage speeds \(calPlan.stages.map(\.mph))")
check(calPlan.stages[0].startSecond == 180 && calPlan.stages[5].startSecond == 180 + 5 * 180, "stage start times")
check(SafetyCheck.clamped(calPlan.workout.steps) == calPlan.workout.steps, "the fitness test steps are changed by the safety clamp")
let calPlanIncline = CalibrationPlan.workout(comfortable: 3.0, withIncline: true)
check(calPlanIncline.stages.count == 9 && calPlanIncline.stages.suffix(3).map(\.incline) == [2, 4, 6] && calPlanIncline.workout.totalSeconds == 1980,
      "incline part: \(calPlanIncline.stages.count) stages, \(calPlanIncline.workout.totalSeconds) s")
for c in [2.5, 3.5, 4.0] {
    let p = CalibrationPlan.workout(comfortable: c, withIncline: true)
    check(p.workout.problems.isEmpty && Set(p.stages.map(\.mph)).count >= 3, "fitness test around \(c) mph: problems \(p.workout.problems)")
    check(p.workout.steps.allSatisfy { $0.mph >= 1.5 && $0.mph <= 4.5 }, "fitness test around \(c) mph leaves walking speeds")
}
check(CalibrationPlan.shouldStop(bpm: 166, maxBpm: 180) && !CalibrationPlan.shouldStop(bpm: 165, maxBpm: 180), "the 92% stop line for a 180 maximum is 165.6")

// A fake test: heart rate = 60 + 20 x mph + 4 x incline, plus a little noise
func fakeSamples(stages: [CalibrationPlan.Stage], rising: Int? = nil) -> [SessionSample] {
    var samples: [SessionSample] = []
    for t in stride(from: 0, to: 1980, by: 5) {
        let stage = stages.first { t >= $0.startSecond && t < $0.startSecond + $0.seconds }
        let mph = stage?.mph ?? 2.0
        let incline = stage?.incline ?? 0
        var bpm = 60 + 20 * mph + 4 * incline + Double((t / 5) % 3) - 1
        if let rising, let stage, stages.firstIndex(of: stage) == rising {
            bpm = 90 + Double(t - (stage.startSecond + stage.seconds - 60)) / 60 * 12   // still climbing in the last minute
        }
        samples.append(SessionSample(t: t, mph: mph, incline: incline, bpm: Int(bpm.rounded())))
    }
    return samples
}
let calSamples = fakeSamples(stages: calPlanIncline.stages)
let calAnalysis = CalibrationAnalysis.points(samples: calSamples, stages: calPlanIncline.stages, elapsed: 1980)
check(calAnalysis.points.count == 9 && calAnalysis.unsettled.isEmpty, "analysis found \(calAnalysis.points.count) stages, unsettled \(calAnalysis.unsettled)")
check(CalibrationAnalysis.points(samples: calSamples, stages: calPlanIncline.stages, elapsed: 700).points.count == 2, "only the stages finished at 700 s should count")
check(CalibrationAnalysis.points(samples: fakeSamples(stages: calPlanIncline.stages, rising: 0), stages: calPlanIncline.stages, elapsed: 1980).unsettled == [1], "a stage still rising should be listed as unsettled")
if let calModel = FitnessModel.fit(points: calAnalysis.points, restingBpm: 62, maxBpm: 180, date: Date()) {
    check(abs(calModel.perMph - 20) < 1.5 && abs(calModel.perIncline - 4) < 0.8 && abs(calModel.base - 60) < 5, "fit: \(calModel.base) + \(calModel.perMph) x mph + \(calModel.perIncline) x incline")
    check(calModel.r2 > 0.98 && !calModel.isNoisy, "fit quality \(calModel.r2)")
    check(abs((calModel.mph(forBpm: 120) ?? 0) - 3.0) < 0.3, "speed for 120 bpm should be about 3.0, got \(String(describing: calModel.mph(forBpm: 120)))")
    check(abs((calModel.incline(forBpm: 136, mph: 3.0) ?? 0) - 4) < 0.8, "incline for 136 bpm at 3.0 mph should be about 4")
    check(abs(calModel.predict(mph: 3.4, incline: 2) - 136) < 3, "prediction for 3.4 mph at 2%")
} else {
    check(false, "the fake fitness test gave no model")
}
let speedOnly = calAnalysis.points.filter { $0.incline == 0 }
if let flatModel = FitnessModel.fit(points: speedOnly, restingBpm: nil, maxBpm: nil, date: Date()) {
    check(flatModel.perIncline == 0 && abs(flatModel.perMph - 20) < 1.5, "a speed-only fit has no incline term")
} else {
    check(false, "a speed-only fit failed")
}
check(FitnessModel.fit(points: Array(speedOnly.prefix(3)), restingBpm: nil, maxBpm: nil, date: Date()) == nil, "three points are too few")
let falling = speedOnly.map { FitnessModel.Point(mph: $0.mph, incline: 0, bpm: 200 - 20 * $0.mph) }
check(FitnessModel.fit(points: falling, restingBpm: nil, maxBpm: nil, date: Date()) == nil, "a heart rate that falls with speed must not give a model")
let scattered = zip(speedOnly, [118.0, 95.0, 130.0, 88.0, 125.0, 99.0]).map { FitnessModel.Point(mph: $0.0.mph, incline: 0, bpm: $0.1) }
check(FitnessModel.fit(points: scattered, restingBpm: nil, maxBpm: nil, date: Date())?.isNoisy ?? true, "scattered readings must be reported as noisy")

// Fixes 49-53: real stage windows, resting heart rate, stop guard, your own speeds, tests that must not distort the profile
let restWarm = RestingHeartRate.estimate(readings: Array(repeating: 110, count: 5) + Array(repeating: 80, count: 20))
check(restWarm == 80, "resting estimate should skip the settling start and give 80, got \(String(describing: restWarm))")
check(RestingHeartRate.estimate(readings: Array(repeating: 70, count: 14)) == nil, "fewer than 15 readings can't give a resting rate")
check(RestingHeartRate.estimate(readings: Array(repeating: 0, count: 10) + Array(repeating: 66, count: 15)) == 66, "zero readings must be ignored")
check(RestingHeartRate.choose(measured: 104, health: 62)?.bpm == 62 && RestingHeartRate.choose(measured: 104, health: 62)?.source == "Apple Health", "a standing 104 against a Health 62 should use Health")
check(RestingHeartRate.choose(measured: 70, health: 62)?.bpm == 70, "a standing 70 against Health 62 is believable")
check(RestingHeartRate.choose(measured: nil, health: 62)?.bpm == 62 && RestingHeartRate.choose(measured: 70, health: nil)?.bpm == 70 && RestingHeartRate.choose(measured: nil, health: nil) == nil, "resting sources")

var guardA = StopGuard()
let guardStart = Date(timeIntervalSince1970: 5_000_000)
var steadyHits: [Int] = []
for second in 1...12 {
    let at = guardStart.addingTimeInterval(Double(second))
    if guardA.update(bpm: second <= 5 ? 160 : 168, at: at, maxBpm: 180) { steadyHits.append(second) }
}
check(steadyHits.first == 9, "a steady rise over the line (165.6) from second 6 should stop at second 9 (3 s), got \(steadyHits)")
var guardB = StopGuard()
var jumpHits: [Int] = []
for second in 1...30 {
    let at = guardStart.addingTimeInterval(Double(second))
    if guardB.update(bpm: second <= 10 ? 140 : 176, at: at, maxBpm: 189) { jumpHits.append(second) }
}
check(jumpHits.first == 19, "a jump of 36 bpm needs 8 s above the line before it stops: expected second 19, got \(jumpHits.first.map(String.init) ?? "none")")
var guardC = StopGuard()
check(!guardC.update(bpm: 0, at: guardStart, maxBpm: 180) && !guardC.update(bpm: 200, at: guardStart.addingTimeInterval(1), maxBpm: 180), "a zero reading is ignored and one high reading alone doesn't stop the test")

var mine = BodyProfile()
check(mine.personalSpeeds == nil && mine.speedLimits == .standard, "no personal speeds by default")
mine.easyWalkMph = 2.4
mine.fastWalkMph = 3.0
mine.jogStartMph = 3.6
check(mine.personalSpeeds?.easy == 2.4 && mine.personalSpeeds?.fast == 3.0, "personal speeds")
check(abs(mine.speedLimits.walkLow - 2.1) < 1e-9 && abs(mine.speedLimits.walkHigh - 3.4) < 1e-9 && mine.speedLimits.jogLow == 3.6 && abs(mine.speedLimits.jogHigh - 5.6) < 1e-9, "limits from 2.4 / 3.6")
check(TemplateCoach.baseSpeed(history: [], personal: (2.4, 3.0)) == 2.7, "comfortable speed is the middle of easy and fast walk")
let testOnly = [HistoryEntry(date: Date(), name: CalibrationPlan.workoutName, plannedSeconds: 1440, seconds: 1100, miles: 0.8, maxMph: 3.8, maxIncline: 0, completed: true, effort: 9)]
check(TemplateCoach.baseSpeed(history: testOnly) == 3.0, "a fitness test must not change the comfortable speed")
check(!WorkoutPrompt.request(WorkoutRequest(), base: 3.0, history: testOnly).contains("Fitness test"), "a fitness test must not appear in the coach's recent workouts")
let personalLimits = mine.speedLimits
check(WorkoutPrompt.typeGuide(.walk, base: 2.7, intensity: .moderate, limits: personalLimits).contains("2.1 to 3.4 mph"), "walk guide from personal limits")
check(WorkoutPrompt.typeGuide(.jog, base: 2.7, intensity: .moderate, limits: personalLimits).contains("3.6 to 5.6 mph"), "jog guide from personal limits")
check(WorkoutPrompt.request(WorkoutRequest(), base: 2.7, history: [], limits: personalLimits).contains("starts jogging at about 3.6 mph"), "the request should say where jogging starts")
check(!WorkoutPrompt.request(WorkoutRequest(), base: 3.0, history: []).contains("starts jogging"), "no jog line with the standard limits")
for minutes in [30, 45, 60] {
    for intensity in WorkoutRequest.Intensity.allCases {
        var walkRequest = WorkoutRequest()
        walkRequest.minutes = minutes
        walkRequest.kind = .walk
        walkRequest.intensity = intensity
        let walkWorkout = TemplateCoach.make(walkRequest, history: [], personal: (2.4, 3.0), limits: personalLimits)
        check(walkWorkout.steps.allSatisfy { $0.mph <= 3.4 + 0.001 }, "a walk for the 2.4 / 3.0 / 3.6 person goes up to \(walkWorkout.maxMph) mph (\(intensity.rawValue), \(minutes) min)")
        var jogRequest = walkRequest
        jogRequest.kind = .jog
        let jogWorkout = TemplateCoach.make(jogRequest, history: [], personal: (2.4, 3.0), limits: personalLimits)
        check(SafetyCheck.matchesKind(jogWorkout.steps, kind: .jog, minutes: minutes, jogLow: 3.6), "a jog for the 2.4 / 3.0 / 3.6 person doesn't reach its own jog speed")
    }
}
let personalPlan = CalibrationPlan.workout(comfortable: 2.7, withIncline: false, easy: 2.4, jogStart: 3.6)
check(personalPlan.stages.map(\.mph) == [2.2, 2.4, 2.7, 2.9, 3.2, 3.4], "personal test stages \(personalPlan.stages.map(\.mph))")
check(personalPlan.workout.problems.isEmpty && SafetyCheck.clamped(personalPlan.workout.steps) == personalPlan.workout.steps, "the personal test plan is changed by the safety clamp or has problems")
let tightPlan = CalibrationPlan.workout(comfortable: 2.4, withIncline: true, easy: 2.0, jogStart: 2.8)
check(tightPlan.workout.problems.isEmpty && Set(tightPlan.stages.map(\.mph)).count >= 4, "a narrow speed range still gives several stages")

// Real stage windows: a stage cut short is dropped, a jogged stage goes to the jog list (fix 49)
var windowSamples = fakeSamples(stages: calPlanIncline.stages)
for index in windowSamples.indices where windowSamples[index].t >= 540 && windowSamples[index].t < 720 { windowSamples[index].jog = true }
let windowResult = CalibrationAnalysis.points(samples: windowSamples, windows: [
    CalibrationAnalysis.Window(index: 1, mph: 2.2, incline: 0, start: 180, end: 360),
    CalibrationAnalysis.Window(index: 2, mph: 2.6, incline: 0, start: 360, end: 411),
    CalibrationAnalysis.Window(index: 3, mph: 3.0, incline: 0, start: 540, end: 720),
])
check(windowResult.points.count == 1 && windowResult.points[0].mph == 2.2, "windows: only the full walking stage should count, got \(windowResult.points.count)")
check(windowResult.jogStages == [3], "the jogged stage should be listed, got \(windowResult.jogStages)")
var jogLog = SampleLog()
jogLog.add(elapsed: 0, mph: 3.8, incline: 0, bpm: 150, jog: true)
jogLog.add(elapsed: 5, mph: 3.8, incline: 0, bpm: 150)
check(jogLog.samples[0].jog == true && jogLog.samples[1].jog == nil, "the jog flag is kept only when set")

// A noisy result is not saved, a good one sets the resting rate, forgetting clears it (fix 53)
FitnessModel.forget()
let noisyModel = FitnessModel(date: Date(), restingBpm: 80, maxBpm: 180, base: 50, perMph: 20, perIncline: 0, r2: 0.5, points: [])
FitnessModel.save(noisyModel)
check(FitnessModel.latest == nil && UserDefaults.standard.integer(forKey: BodyProfile.restingKey) == 0, "a noisy result must not be saved")
var goodModel = noisyModel
goodModel.r2 = 0.95
FitnessModel.save(goodModel)
check(FitnessModel.latest != nil && UserDefaults.standard.integer(forKey: BodyProfile.restingKey) == 80, "a good result is saved with its resting rate")
FitnessModel.forget()
check(FitnessModel.latest == nil && UserDefaults.standard.integer(forKey: BodyProfile.restingKey) == 0, "forgetting clears the result and the resting rate")

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
