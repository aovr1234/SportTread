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

print("\(checks) checks, \(failures.count) failures")
for failure in failures.prefix(25) { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
