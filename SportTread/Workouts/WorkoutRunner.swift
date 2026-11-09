import Foundation

/// Plays a workout on the treadmill: starts the belt, sets each step's speed and incline at the
/// step's start, and counts down. Speed or incline changed on the console stays until the next step.
/// If the belt stops on its own (console Stop, safety key) or the connection drops, the workout pauses.
@MainActor
final class WorkoutRunner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case paused(String)
        case finished(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var workout: Workout?
    @Published private(set) var stepIndex = 0
    @Published private(set) var stepElapsed: TimeInterval = 0
    @Published private(set) var totalElapsed: TimeInterval = 0

    /// Called when a workout finishes or is ended early, for the coach's history.
    var onFinish: ((HistoryEntry) -> Void)?

    private let treadmill: TreadmillController
    private var loop: Task<Void, Never>?
    private var beltStartedAt = Date.distantPast

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

    var progress: Double {
        guard let workout, workout.totalSeconds > 0 else { return 0 }
        return min(1, totalElapsed / Double(workout.totalSeconds))
    }

    // MARK: Controls

    func start(_ workout: Workout) {
        guard treadmill.isReady, !isActive, workout.problems.isEmpty else { return }
        self.workout = workout
        stepIndex = 0
        stepElapsed = 0
        totalElapsed = 0
        treadmill.resetStats()
        phase = .starting
        // If the belt is already running (started by hand), keep it going and just apply step 1
        launch(startBelt: !treadmill.isRunning)
    }

    func pause() {
        guard phase == .running || phase == .starting else { return }
        loop?.cancel()
        treadmill.stop()
        phase = .paused("Paused")
    }

    func resume() {
        guard case .paused = phase else { return }
        guard treadmill.isReady else {
            phase = .paused("Not connected. Reconnect on the Treadmill tab, then Resume.")
            return
        }
        phase = .starting
        launch(startBelt: true)
    }

    func skip() {
        switch phase {
        case .running:
            advance()
        case .paused(let reason):
            moveToNextStep()
            if isActive { phase = .paused(reason) }
        default:
            break
        }
    }

    /// Ends the workout early and stops the belt.
    func end() {
        guard isActive else { return }
        finish("Ended early")
    }

    /// Closes the finished workout screen.
    func dismiss() {
        guard !isActive else { return }
        phase = .idle
        workout = nil
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
                }
                return
            }
        }
        applyStep()
        phase = .running

        var last = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            let now = Date()
            let delta = now.timeIntervalSince(last)
            last = now

            if !treadmill.isReady {
                loop = nil
                phase = .paused("Lost the connection. Reconnect on the Treadmill tab, then Resume.")
                return
            }
            // Grace period: the speed reading takes a moment to reflect a fresh start
            if !treadmill.isRunning, now.timeIntervalSince(beltStartedAt) > 6 {
                loop = nil
                treadmill.stop()
                phase = .paused("The belt stopped (console Stop or safety key). Resume when ready.")
                return
            }

            stepElapsed += delta
            totalElapsed += delta
            if let step = currentStep, stepElapsed >= Double(step.seconds) {
                advance()
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
    }

    private func finish(_ reason: String) {
        loop?.cancel()
        loop = nil
        treadmill.stop()
        phase = .finished(reason)
        if let workout {
            onFinish?(HistoryEntry(
                date: Date(), name: workout.name, plannedSeconds: workout.totalSeconds,
                seconds: Int(totalElapsed), miles: treadmill.miles, maxMph: workout.maxMph,
                maxIncline: workout.maxIncline, completed: reason == "Workout complete"))
        }
    }
}
