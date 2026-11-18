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
        check(after.steps.count == before.steps.count, "trimming changed the step count for \(minutes) min")
        check(after.steps.allSatisfy { $0.seconds % 30 == 0 && $0.seconds >= 30 }, "trimming left an odd step length for \(minutes) min")
        check(after.problems.isEmpty, "trimming created problems for \(minutes) min: \(after.problems)")
    }
}

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
