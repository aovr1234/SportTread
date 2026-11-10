import Foundation

/// Plays a workout on the treadmill: starts the belt, sets each step's speed and incline at the
/// step's start, and counts down. Manual changes (app tiles or console) hold until the next step and
/// are logged as deviations for the AI coach. STOP pauses the workout and keeps the incline; ending
/// the workout lowers the incline to 0%. If the belt stops on its own or the connection drops, the
/// workout pauses (and continues by itself after a reconnect if the belt kept running).
@MainActor
final class WorkoutRunner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case paused(String)
        case finished(String)
    }

    /// A suggested change to the rest of the workout, accepted or dismissed with one tap.
    struct Offer: Identifiable, Equatable {
        enum Action: Equatable {
            case shiftSpeed(Double)
            case replaceRemaining([WorkoutStep])
        }

        let id = UUID()
        let message: String
        let action: Action
        /// What gets logged if accepted
        let note: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var workout: Workout?
    @Published private(set) var stepIndex = 0
    @Published private(set) var stepElapsed: TimeInterval = 0
    @Published private(set) var totalElapsed: TimeInterval = 0
    @Published private(set) var deviations: [Deviation] = []
    @Published private(set) var offer: Offer?

    /// Called when a workout finishes or is ended early, for history.
    var onFinish: ((HistoryEntry) -> Void)?

    let treadmill: TreadmillController
    private let activity = WorkoutActivity()
    private var loop: Task<Void, Never>?
    private var beltStartedAt = Date.distantPast

    // Deviation detection: what the treadmill should be doing right now
    private var expectedMph = 0.0
    private var expectedIncline = 0.0
    private var commandedAt = Date.distantPast
    private var speedCandidate: (value: Double, since: Date)?
    private var inclineCandidate: (value: Double, since: Date)?

    init(treadmill: TreadmillController) {
        self.treadmill = treadmill
    }

    var isActive: Bool {
        switch phase {
        case .starting, .running, .paused: true
        case .idle, .finished: false
        }
    }

    var currentStep: WorkoutStep? {
        guard let workout, stepIndex < workout.steps.count else { return nil }
        return workout.steps[stepIndex]
    }

    var nextStep: WorkoutStep? {
        guard let workout, stepIndex + 1 < workout.steps.count else { return nil }
        return workout.steps[stepIndex + 1]
    }

    var stepRemaining: TimeInterval {
        max(0, Double(currentStep?.seconds ?? 0) - stepElapsed)
    }

    var stepProgress: Double {
        guard let step = currentStep, step.seconds > 0 else { return 0 }
        return min(1, stepElapsed / Double(step.seconds))
    }

    var progress: Double {
        guard let workout, workout.totalSeconds > 0 else { return 0 }
        return min(1, totalElapsed / Double(workout.totalSeconds))
    }

    /// Steps after the current one.
    var remainingSteps: [WorkoutStep] {
        guard let workout, stepIndex + 1 < workout.steps.count else { return [] }
        return Array(workout.steps[(stepIndex + 1)...])
    }

    // MARK: Controls

    func start(_ workout: Workout) {
        guard treadmill.isReady, !isActive, workout.problems.isEmpty else { return }
        self.workout = workout
        stepIndex = 0
        stepElapsed = 0
        totalElapsed = 0
        deviations = []
        offer = nil
        treadmill.workoutActive = true
        treadmill.resetStats()
        phase = .starting
        activity.start(name: workout.name, totalSeconds: workout.totalSeconds, state: activityState())
        // If the belt is already running (started by hand), keep it going and just apply step 1
        launch(startBelt: !treadmill.isRunning)
    }

    /// Pause and STOP: the belt stops, the incline stays, the timer freezes.
    func pause(reason: String = "Paused") {
        guard phase == .running || phase == .starting else { return }
        loop?.cancel()
        treadmill.stop()
        phase = .paused(reason)
        note(.pause, reason)
        activity.update(activityState())
    }

    func resume() {
        guard case .paused = phase else { return }
        guard treadmill.isReady else {
            phase = .paused("Not connected. Connect, then Resume.")
            return
        }
        phase = .starting
        note(.resume, "resumed")
        activity.update(activityState())
        launch(startBelt: true)
    }

    func skip() {
        guard let step = currentStep else { return }
        note(.skip, "skipped \(step.label)")
        switch phase {
        case .running:
            advance()
        case .paused(let reason):
            moveToNextStep()
            if isActive {
                phase = .paused(reason)
                activity.update(activityState())
            }
        default:
            break
        }
    }

    /// Ends the workout early: incline to 0%, belt stops, summary shows.
    func end() {
        guard isActive else { return }
        note(.endedEarly, "ended early")
        finish("Ended early")
    }

    /// Closes the finished workout screen.
    func dismiss() {
        guard !isActive else { return }
        phase = .idle
        workout = nil
        offer = nil
    }

    // MARK: Manual changes from the live screen tiles

    func adjustSpeed(to mph: Double) {
        let value = (mph * 10).rounded() / 10
        guard isActive, (TreadmillController.minMph...TreadmillController.maxMph).contains(value) else { return }
        treadmill.setSpeed(value)
        recordSpeedChange(to: value, source: "in the app")
        commandedAt = Date()
    }

    func adjustIncline(to percent: Double) {
        let value = (percent * 2).rounded() / 2
        guard isActive, (0...TreadmillController.maxIncline).contains(value) else { return }
        treadmill.setIncline(value)
        recordInclineChange(to: value, source: "in the app")
        commandedAt = Date()
    }

    // MARK: Offers

    func present(_ newOffer: Offer) {
        offer = newOffer
    }

    func acceptOffer() {
        guard let offer, var workout else { return }
        let start = stepIndex + 1
        switch offer.action {
        case .shiftSpeed(let delta):
            if start < workout.steps.count {
                for i in start..<workout.steps.count { workout.steps[i].mph += delta }
            }
        case .replaceRemaining(let steps):
            workout.steps = Array(workout.steps.prefix(start)) + steps
        }
        workout.steps = SafetyCheck.clamped(workout.steps)
        self.workout = workout
        note(.adjustRest, offer.note)
        self.offer = nil
        activity.update(activityState())
    }

    func dismissOffer() {
        guard let offer else { return }
        if case .shiftSpeed = offer.action { note(.adjustRest, "ignored: \(offer.note)") }
        self.offer = nil
    }

    /// Logs a check-in answer or an AI request; used by the coach features.
    func note(_ kind: Deviation.Kind, _ detail: String, delta: Double? = nil) {
        deviations.append(Deviation(
            at: Int(totalElapsed), step: stepIndex, stepLabel: currentStep?.label ?? "",
            kind: kind, delta: delta, detail: detail))
    }

    // MARK: Engine

    private func launch(startBelt: Bool) {
        loop?.cancel()
        loop = Task { await run(startBelt: startBelt) }
    }

    private func run(startBelt: Bool) async {
        if startBelt {
            treadmill.start(resetStats: false)
            beltStartedAt = Date()
            guard await waitUntilRunning() else {
                if !Task.isCancelled {
                    phase = .paused("The belt didn't start. Check the safety key, then Resume.")
                    activity.update(activityState())
                }
                return
            }
        }
        applyStep()
        phase = .running
        activity.update(activityState())

        var last = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            let now = Date()
            let delta = now.timeIntervalSince(last)
            last = now

            if !treadmill.isReady {
                phase = .paused("Connection lost. Reconnecting… the workout continues when it's back.")
                note(.connection, "connection lost")
                activity.update(activityState())
                continueAfterReconnect()
                return
            }
            // Grace period: the speed reading takes a moment to reflect a fresh start
            if !treadmill.isRunning, now.timeIntervalSince(beltStartedAt) > 6 {
                loop = nil
                treadmill.stop()
                phase = .paused("The belt stopped (console Stop or safety key). Resume when ready.")
                note(.beltStopped, "belt stopped on the console")
                activity.update(activityState())
                return
            }

            detectConsoleChanges(now: now)
            stepElapsed += delta
            totalElapsed += delta
            if let step = currentStep, stepElapsed >= Double(step.seconds) {
                advance()
            }
            if phase == .running { activity.update(activityState()) }
        }
    }

    /// Waits for the treadmill to reconnect. If the belt kept running, the workout carries on by
    /// itself; if it stopped, the workout stays paused for the user to Resume.
    private func continueAfterReconnect() {
        loop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard case .paused = phase else { return }
                guard treadmill.isReady else { continue }
                for _ in 0..<12 where treadmill.speedMph == nil {  // first status reading, up to 3 s
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if Task.isCancelled { return }
                if treadmill.isRunning {
                    phase = .starting
                    launch(startBelt: false)
                } else {
                    phase = .paused("Reconnected. The belt stopped, so tap Resume when ready.")
                    activity.update(activityState())
                }
                return
            }
        }
    }

    private func waitUntilRunning() async -> Bool {
        for _ in 0..<60 {  // up to 15 s
            if Task.isCancelled { return false }
            if treadmill.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func advance() {
        moveToNextStep()
        if phase == .running { applyStep() }
    }

    private func moveToNextStep() {
        guard let workout else { return }
        stepIndex += 1
        stepElapsed = 0
        if stepIndex >= workout.steps.count {
            stepIndex = workout.steps.count - 1
            finish("Workout complete")
        }
    }

    private func applyStep() {
        guard let step = currentStep else { return }
        treadmill.setIncline(step.incline)
        treadmill.setSpeed(step.mph)
        expectedMph = step.mph
        expectedIncline = step.incline
        commandedAt = Date()
        speedCandidate = nil
        inclineCandidate = nil
    }

    // MARK: Deviation detection

    /// A reading that differs from the target and holds steady (speed 2 s, incline 3 s, since the
    /// deck moves gradually) is a change made on the console.
    private func detectConsoleChanges(now: Date) {
        guard now.timeIntervalSince(commandedAt) > 4 else { return }
        if let mph = treadmill.speedMph, mph > 0, abs(mph - expectedMph) >= 0.1 {
            if let candidate = speedCandidate, abs(candidate.value - mph) < 0.05 {
                if now.timeIntervalSince(candidate.since) >= 2 {
                    recordSpeedChange(to: (mph * 10).rounded() / 10, source: "on the console")
                    speedCandidate = nil
                }
            } else {
                speedCandidate = (mph, now)
            }
        } else {
            speedCandidate = nil
        }
        if let incline = treadmill.incline, abs(incline - expectedIncline) >= 0.5 {
            if let candidate = inclineCandidate, abs(candidate.value - incline) < 0.1 {
                if now.timeIntervalSince(candidate.since) >= 3 {
                    recordInclineChange(to: (incline * 2).rounded() / 2, source: "on the console")
                    inclineCandidate = nil
                }
            } else {
                inclineCandidate = (incline, now)
            }
        } else {
            inclineCandidate = nil
        }
    }

    private func recordSpeedChange(to value: Double, source: String) {
        let delta = value - expectedMph
        guard abs(delta) >= 0.05 else { return }
        note(.speed, String(format: "speed %.1f → %.1f mph %@", expectedMph, value, source), delta: delta)
        expectedMph = value
        offerAdjustRestIfRepeated()
    }

    private func recordInclineChange(to value: Double, source: String) {
        let delta = value - expectedIncline
        guard abs(delta) >= 0.25 else { return }
        note(.incline, String(format: "incline %.1f → %.1f%% %@", expectedIncline, value, source), delta: delta)
        expectedIncline = value
    }

    /// Manual speed changes in the same direction in two steps in a row → offer to shift the rest.
    private func offerAdjustRestIfRepeated() {
        guard offer == nil, !remainingSteps.isEmpty else { return }
        let speedChanges = deviations.filter { $0.kind == .speed }
        guard let latest = speedChanges.last, let latestDelta = latest.delta,
              let previous = speedChanges.last(where: { $0.step == latest.step - 1 }), let previousDelta = previous.delta,
              latestDelta.sign == previousDelta.sign
        else { return }
        let shift = ((latestDelta + previousDelta) / 2 * 10).rounded() / 10
        guard abs(shift) >= 0.1 else { return }
        let word = shift < 0 ? "Lower" : "Raise"
        let done = shift < 0 ? "lowered" : "raised"
        let amount = String(format: "%.1f", abs(shift))
        present(Offer(
            message: "You changed the speed in the last two steps. \(word) the rest of the workout by \(amount) mph?",
            action: .shiftSpeed(shift),
            note: "\(done) the rest by \(amount) mph"))
    }

    // MARK: Live Activity and finishing

    private func activityState() -> WorkoutActivity.State {
        WorkoutActivity.State(
            stepLabel: currentStep?.label ?? "",
            stepEnds: Date().addingTimeInterval(stepRemaining),
            stepRemaining: Int(stepRemaining.rounded(.up)),
            mph: treadmill.speedMph ?? currentStep?.mph ?? 0,
            incline: treadmill.incline ?? currentStep?.incline ?? 0,
            progress: progress,
            paused: phase != .running,
            nextLabel: nextStep?.label,
            finished: nil)
    }

    private func finish(_ reason: String) {
        loop?.cancel()
        loop = nil
        treadmill.zeroInclineAndStop()
        treadmill.workoutActive = false
        phase = .finished(reason)
        offer = nil
        var closing = activityState()
        closing.finished = reason
        closing.progress = reason == "Workout complete" ? 1 : progress
        activity.end(final: closing)
        if let workout {
            onFinish?(HistoryEntry(
                date: Date(), name: workout.name, plannedSeconds: workout.totalSeconds,
                seconds: Int(totalElapsed), miles: treadmill.miles, maxMph: workout.maxMph,
                maxIncline: workout.maxIncline, completed: reason == "Workout complete",
                deviations: deviations))
        }
    }
}
