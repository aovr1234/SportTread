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
            case edit(remaining: [WorkoutStep], currentMph: Double?, currentIncline: Double?)
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
    /// A check-in ("How's it feeling?") is waiting for an answer
    @Published private(set) var checkInDue = false

    /// Shown after every live edit: the new length, with Undo for 10 seconds
    struct EditNotice: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    @Published private(set) var editNotice: EditNotice?
    private var undoSnapshot: Workout?
    private var undoChangedCurrent = false
    /// Length when the workout started (History keeps it next to the final length)
    private(set) var originalSeconds = 0
    private var peakMph = 0.0
    private var peakIncline = 0.0

    private struct ChangeOrigin {
        var index: Int
        var from: Double
        var at: TimeInterval
        var source: String
        var step: Int
    }

    private var lastChange: [Deviation.Kind: ChangeOrigin] = [:]

    /// Minutes between check-ins; 0 = off. Set on the Coach tab.
    static let checkInKey = "checkInMinutes"
    private var lastCheckInAt: TimeInterval = 0
    private var offeredEaseOff = false
    private var offeredShorten = false

    /// Called when a workout finishes or is ended early, for history.
    var onFinish: ((HistoryEntry) -> Void)?

    let treadmill: TreadmillController
    private let activity = WorkoutActivity()
    private var loop: Task<Void, Never>?
    private var beltStartedAt = Date.distantPast
    private var lastNotedProblem: String?
    private var sampleLog = SampleLog()
    private var lastSaveAt = Date.distantPast

    // Heart-rate hold: moves speed and/or incline in small steps on top of the plan to keep the heart near a target
    private var holdEngine: HeartRateHold?

    // Zone watch: suggests harder or easier when the heart rate stays outside a zone (fix 44)
    private var zoneEngine: ZoneWatch?
    @Published private(set) var watchZone: Int?

    // Fitness test (fix 45): the test runs as a workout; at the end the settled heart rates become a model
    private struct CalibrationRun {
        var stages: [CalibrationPlan.Stage]
        var restingBpm: Int?
        var aborted = false
        var noSignalSince: Date?
        /// When each stage really started and ended on the workout clock
        var windows: [CalibrationAnalysis.Window] = []
        var openStage: Int?
        var openStart = 0
        var stopGuard = StopGuard()
        var lastGuardReading: Date?
    }

    /// The person said they are jogging (readings from then on stay out of the walking line)
    @Published private(set) var jogging = false

    /// What the last live edit set for the steps after it, to check that the plan really has them when they start
    private var lastEdit: (from: Int, steps: [WorkoutStep])?

    private var calibration: CalibrationRun?
    @Published private(set) var calibrationResult: FitnessModel?
    @Published private(set) var calibrationNote: String?
    @Published private(set) var holdTarget: Int?
    @Published private(set) var holdControl: HeartRateHold.Control = .speed
    @Published private(set) var holdStatus = ""
    /// Shown for a few seconds after a workout was picked up again following an app restart
    @Published private(set) var recoveryNotice: String?

    // Deviation detection: what the treadmill should be doing right now
    private var expectedMph = 0.0
    private var expectedIncline = 0.0
    private var commandedAt = Date.distantPast
    private var speedCandidate: (value: Double, since: Date)?
    private var inclineCandidate: (value: Double, since: Date)?

    init(treadmill: TreadmillController) {
        self.treadmill = treadmill
        if let saved = Self.loadSavedRun() { recover(saved) }
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

    /// Planned seconds up to and including the current step.
    var plannedThroughCurrent: Int {
        guard let workout else { return 0 }
        return workout.steps.prefix(stepIndex + 1).reduce(0) { $0 + $1.seconds }
    }

    /// Planned seconds of the steps after the current one.
    var laterSeconds: Int { remainingSteps.reduce(0) { $0 + $1.seconds } }

    static func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    // MARK: Controls

    func start(_ workout: Workout) {
        guard treadmill.isReady, !isActive, workout.problems.isEmpty else { return }
        self.workout = workout
        stepIndex = 0
        stepElapsed = 0
        totalElapsed = 0
        deviations = []
        offer = nil
        editNotice = nil
        undoSnapshot = nil
        lastChange = [:]
        peakMph = 0
        peakIncline = 0
        sampleLog.reset()
        holdEngine = nil
        holdTarget = nil
        holdStatus = ""
        zoneEngine = nil
        watchZone = nil
        calibration = nil
        calibrationResult = nil
        calibrationNote = nil
        jogging = false
        lastEdit = nil
        originalSeconds = workout.totalSeconds
        checkInDue = false
        lastCheckInAt = 0
        offeredEaseOff = false
        offeredShorten = false
        treadmill.workoutActive = true
        treadmill.resetStats()
        phase = .starting
        activity.start(name: workout.name, totalSeconds: workout.totalSeconds, state: activityState())
        // If the belt is already running (started by hand), keep it going and just apply step 1
        dlog("Workout started: \(workout.name), \(Self.clock(workout.totalSeconds))")
        saveRun()
        launch(startBelt: !treadmill.isRunning)
    }

    /// Pause and STOP: the belt stops, the incline stays, the timer freezes.
    func pause(reason: String = "Paused") {
        guard phase == .running || phase == .starting else { return }
        loop?.cancel()
        treadmill.stop()
        phase = .paused(reason)
        note(.pause, reason)
        dlog("Workout paused: \(reason)")
        saveRun()
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
        dlog("Workout resumed")
        saveRun()
        activity.update(activityState())
        launch(startBelt: true, resuming: true)
    }

    func skip() {
        guard let step = currentStep else { return }
        note(.skip, "skipped \(step.label)")
        offerShortenIfSkipping()
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
        calibrationResult = nil
        calibrationNote = nil
        phase = .idle
        workout = nil
        offer = nil
        editNotice = nil
        undoSnapshot = nil
    }

    // MARK: Manual changes from the live screen tiles

    func adjustSpeed(to mph: Double) {
        let value = (mph * 10).rounded() / 10
        guard isActive, (TreadmillController.minMph...TreadmillController.maxMph).contains(value) else { return }
        treadmill.setSpeed(value)
        recordSpeedChange(to: value, source: "in the app")
        commandedAt = Date()
        if holdEngine != nil, let step = currentStep, !SafetyCheck.isEndStep(step) {
            holdEngine?.userChanged(at: Date())
            holdEngine?.rebase(speedOffset: value - step.mph)  // the new value is the starting point
        }
    }

    func adjustIncline(to percent: Double) {
        let value = (percent * 2).rounded() / 2
        guard isActive, (0...TreadmillController.maxIncline).contains(value) else { return }
        treadmill.setIncline(value)
        recordInclineChange(to: value, source: "in the app")
        commandedAt = Date()
        if holdEngine != nil, let step = currentStep, !SafetyCheck.isEndStep(step) {
            holdEngine?.userChanged(at: Date())
            holdEngine?.rebase(inclineOffset: value - step.incline)
        }
    }

    // MARK: Heart-rate hold

    /// The limits the hold keeps to: up to half a mph above the workout's top planned speed, up to 2% above its
    /// steepest incline, never beyond the treadmill's own range or the speed and incline cap.
    private var holdLimits: HeartRateHold.Limits {
        let topMph = max(workout?.maxMph ?? 3, currentStep?.mph ?? 0)
        let topIncline = max(workout?.maxIncline ?? 0, currentStep?.incline ?? 0)
        return HeartRateHold.Limits(
            minMph: 1.0, maxMph: min(topMph + 0.5, 7.0),
            maxIncline: min(topIncline + 2, TreadmillController.maxIncline))
    }

    func startHold(target: Int, control: HeartRateHold.Control) {
        guard isActive else { return }
        holdEngine = HeartRateHold(target: target, control: control)
        holdTarget = target
        holdControl = control
        holdStatus = "Heart-rate hold on at \(target) bpm"
        dlog("Heart-rate hold on: target \(target) bpm, moving \(control.rawValue.lowercased())")
    }

    /// Changes the target or what moves, keeping what the hold has already added.
    func updateHold(target: Int, control: HeartRateHold.Control) {
        guard holdEngine != nil else { return }
        holdEngine?.target = target
        holdEngine?.control = control
        holdTarget = target
        holdControl = control
        dlog("Heart-rate hold changed: target \(target) bpm, moving \(control.rawValue.lowercased())")
    }

    func stopHold() {
        guard holdTarget != nil else { return }
        holdEngine = nil
        holdTarget = nil
        holdStatus = ""
        dlog("Heart-rate hold off")
        if phase == .running { applyStep() }  // back to the plan
    }

    // MARK: Zone watch

    func startZoneWatch(zone: Int) {
        guard isActive else { return }
        zoneEngine = ZoneWatch(zone: zone)
        watchZone = zone
        dlog("Zone watch on: Zone \(zone)")
    }

    func stopZoneWatch() {
        guard watchZone != nil else { return }
        zoneEngine = nil
        watchZone = nil
        dlog("Zone watch off")
    }

    private func runZoneWatch(now: Date) {
        guard var engine = zoneEngine, holdEngine == nil, phase == .running, offer == nil, let step = currentStep,
              !SafetyCheck.isEndStep(step), let zones = BodyProfile.stored.zones else { return }
        defer { zoneEngine = engine }
        let reading = treadmill.heartRateProvider?()
        if let reading { engine.add(bpm: reading.bpm, at: reading.at) }
        let fresh = reading.map { now.timeIntervalSince($0.at) < 5 } ?? false
        guard let verdict = engine.evaluate(now: now, zones: zones, signalFresh: fresh) else { return }
        switch verdict {
        case .tooEasy:
            let harder = LiveCoach.harder(current: step, remaining: remainingSteps)
            dlog("Zone watch: under Zone \(engine.zone) for 4 minutes, offered harder")
            present(Offer(
                message: "Your heart rate has been under Zone \(engine.zone) for 4 minutes. Make the rest a bit harder (+0.3 mph, +1%)?",
                action: .edit(remaining: harder.remaining, currentMph: harder.currentMph, currentIncline: harder.currentIncline),
                note: "heart rate under Zone \(engine.zone): made it harder"))
        case .tooHard:
            let easier = LiveCoach.easier(current: step, remaining: remainingSteps)
            dlog("Zone watch: over Zone \(engine.zone) for 2 minutes, offered easier")
            present(Offer(
                message: "Your heart rate has been over Zone \(engine.zone) for 2 minutes. Make the rest a bit easier?",
                action: .edit(remaining: easier.remaining, currentMph: easier.currentMph, currentIncline: easier.currentIncline),
                note: "heart rate over Zone \(engine.zone): made it easier"))
        }
    }

    // MARK: Fitness test

    /// Starts the fitness test as a workout.
    func startCalibration(comfortable: Double, withIncline: Bool, restingBpm: Int?, easy: Double? = nil, jogStart: Double? = nil) {
        guard treadmill.isReady, !isActive else { return }
        let plan = CalibrationPlan.workout(comfortable: comfortable, withIncline: withIncline, easy: easy, jogStart: jogStart)
        start(plan.workout)
        guard isActive else { return }
        calibration = CalibrationRun(stages: plan.stages, restingBpm: restingBpm)
        dlog(String(format: "Fitness test started: %d stages around %.1f mph, resting heart rate %@", plan.stages.count, comfortable,
                    restingBpm.map { String($0) } ?? "unknown"))
    }

    private var isInCoolDown: Bool {
        guard let workout else { return false }
        return stepIndex >= workout.steps.count - 1
    }

    /// The test stops at 92% of the estimated maximum heart rate (it skips to the cool-down) and pauses if the
    /// sensor goes quiet for 10 seconds.
    private func runCalibrationSafety(now: Date) {
        guard var test = calibration, phase == .running, let maxBpm = BodyProfile.stored.maxHeartRate else { return }
        defer { calibration = test }
        let reading = treadmill.heartRateProvider?()
        if let reading, now.timeIntervalSince(reading.at) < 5 {
            test.noSignalSince = nil
            var stop = false
            if reading.at != test.lastGuardReading {
                test.lastGuardReading = reading.at
                stop = test.stopGuard.update(bpm: reading.bpm, at: reading.at, maxBpm: maxBpm)
            }
            if !test.aborted, !isInCoolDown, stop {
                test.aborted = true
                calibrationNote = "Stopped early: your heart rate reached 92% of your estimated maximum. Cooling down."
                dlog("Fitness test: heart rate \(reading.bpm) reached 92% of \(maxBpm); skipping to the cool-down")
                jumpToCoolDown()
            }
        } else {
            let since = test.noSignalSince ?? now
            test.noSignalSince = since
            if now.timeIntervalSince(since) >= 10 {
                test.noSignalSince = nil
                dlog("Fitness test: no heart-rate signal for 10 s; paused")
                pause(reason: "Heart-rate signal lost. Check the armband, then Resume.")
            }
        }
    }

    private func jumpToCoolDown() {
        guard let workout, stepIndex < workout.steps.count - 1 else { return }
        stepIndex = workout.steps.count - 1
        stepElapsed = 0
        applyStep()
        saveRun()
        activity.update(activityState())
    }

    /// Notes when each stage really starts and ends, so the analysis uses the real windows (a skip to the cool-down or a
    /// pause moves them).
    private func trackCalibrationStage() {
        guard var test = calibration else { return }
        defer { calibration = test }
        let stage: Int? = (stepIndex >= 1 && stepIndex <= test.stages.count) ? stepIndex : nil
        guard stage != test.openStage else { return }
        if let open = test.openStage, open >= 1, open <= test.stages.count {
            let spec = test.stages[open - 1]
            test.windows.append(CalibrationAnalysis.Window(index: open, mph: spec.mph, incline: spec.incline,
                                                           start: test.openStart, end: Int(totalElapsed)))
        }
        test.openStage = stage
        test.openStart = Int(totalElapsed)
    }

    func toggleJogging() {
        guard isActive else { return }
        jogging.toggle()
        dlog("Gait: \(jogging ? "jogging" : "walking") at \(String(format: "%.1f", treadmill.speedMph ?? 0)) mph")
    }

    private func finishCalibration(_ running: CalibrationRun) {
        var test = running
        calibration = nil
        if let open = test.openStage, open >= 1, open <= test.stages.count {
            let spec = test.stages[open - 1]
            test.windows.append(CalibrationAnalysis.Window(index: open, mph: spec.mph, incline: spec.incline,
                                                           start: test.openStart, end: Int(totalElapsed)))
        }
        let analysis = CalibrationAnalysis.points(samples: sampleLog.samples, windows: test.windows)
        let profile = BodyProfile.stored
        let healthResting = UserDefaults.standard.integer(forKey: BodyProfile.healthRestingKey)
        let resting = RestingHeartRate.choose(measured: test.restingBpm, health: healthResting >= 30 ? healthResting : nil)
        var notes: [String] = calibrationNote.map { [$0] } ?? []
        if let first = analysis.jogStages.compactMap({ test.stages.indices.contains($0 - 1) ? test.stages[$0 - 1].mph : nil }).min() {
            notes.append(String(format: "You were jogging from %.1f mph; those stages are left out of the walking line.", first))
            if UserDefaults.standard.double(forKey: BodyProfile.jogStartKey) < 2 {
                UserDefaults.standard.set(first, forKey: BodyProfile.jogStartKey)
                notes.append(String(format: "Saved %.1f mph as the speed where you start jogging (change it in Setup).", first))
            }
        }
        let windowText = test.windows.map { "\($0.index):\($0.end - $0.start)s" }.joined(separator: " ")
        guard var model = FitnessModel.fit(points: analysis.points, restingBpm: resting?.bpm, maxBpm: profile.maxHeartRate,
                                           date: Date(), unsettled: analysis.unsettled) else {
            notes.append("Not enough walking stages with a clear heart rate to work out a model. Try the test again.")
            calibrationNote = notes.joined(separator: " ")
            dlog("Fitness test: no model (\(analysis.points.count) usable stages, \(analysis.jogStages.count) jogging; windows \(windowText))")
            return
        }
        model.restingSource = resting?.source
        if model.isNoisy {
            notes.append("The fit was noisy, so this result was not saved and your zones are unchanged.")
        } else {
            FitnessModel.save(model)
        }
        calibrationNote = notes.isEmpty ? nil : notes.joined(separator: " ")
        calibrationResult = model
        dlog(String(format: "Fitness test: base %.1f, %.1f bpm per mph, %.1f per %% incline, fit %.2f, %d stages used (windows %@), jogging stages %@, resting %@",
                    model.base, model.perMph, model.perIncline, model.r2, analysis.points.count, windowText,
                    analysis.jogStages.isEmpty ? "none" : analysis.jogStages.map { String($0) }.joined(separator: ","),
                    resting.map { "\($0.bpm) (\($0.source))" } ?? "unknown"))
    }

    private func setHoldStatus(_ text: String) {
        if holdStatus != text { holdStatus = text }
    }

    private func runHold(now: Date) {
        guard var engine = holdEngine, phase == .running, let step = currentStep else { return }
        defer { holdEngine = engine }
        let reading = treadmill.heartRateProvider?()
        if let reading { engine.add(bpm: reading.bpm, at: reading.at) }
        if SafetyCheck.isEndStep(step) {
            setHoldStatus("Heart-rate hold waits for the main part")
            return
        }
        let limits = holdLimits
        let fresh = reading.map { now.timeIntervalSince($0.at) < 5 } ?? false
        switch engine.evaluate(now: now, baseMph: step.mph, baseIncline: step.incline, limits: limits, signalFresh: fresh) {
        case .none:
            let nowText = engine.smoothed(now: now).map { ", now \(Int($0.rounded()))" } ?? ""
            setHoldStatus("Holding \(engine.target) bpm\(nowText)")
        case .warn(let text):
            setHoldStatus(text)
        case .change(let speed, let incline, let text):
            let mph = min(max(engine.effectiveMph(base: step.mph), limits.minMph), limits.maxMph)
            let steep = min(max(engine.effectiveIncline(base: step.incline), 0),
                            min(limits.maxIncline, SafetyCheck.inclineCap(forMph: mph)))
            if abs(speed) > 0.001 { treadmill.setSpeed(mph) }
            if abs(incline) > 0.001 { treadmill.setIncline(steep) }
            expectedMph = mph
            expectedIncline = steep
            commandedAt = now
            setHoldStatus(text)
            dlog(String(format: "Heart-rate hold: %@ (now %.1f mph, %.1f%%)", text, mph, steep))
        }
    }

    // MARK: Offers

    func present(_ newOffer: Offer) {
        offer = newOffer
    }

    func acceptOffer() {
        guard let offer, var workout else { return }
        self.offer = nil
        switch offer.action {
        case .shiftSpeed(let delta):
            lastEdit = nil
            let start = stepIndex + 1
            if start < workout.steps.count {
                for i in start..<workout.steps.count { workout.steps[i].mph += delta }
            }
            workout.steps = SafetyCheck.clamped(workout.steps)
            self.workout = workout
            note(.adjustRest, offer.note)
            activity.update(activityState())
        case .edit(let remaining, let mph, let incline):
            applyEdit(remaining: remaining, currentMph: mph, currentIncline: incline, note: offer.note)
        }
    }

    /// Replaces the remaining steps and optionally changes the current step now (AI or rule edits).
    /// Keeps the previous workout for Undo and shows the new length for 10 seconds.
    func applyEdit(remaining: [WorkoutStep], currentMph: Double?, currentIncline: Double?, note detail: String) {
        guard isActive, var workout else { return }
        let before = workout.totalSeconds
        undoSnapshot = workout
        undoChangedCurrent = currentMph != nil || currentIncline != nil
        let start = stepIndex + 1
        workout.steps = SafetyCheck.clamped(Array(workout.steps.prefix(start)) + remaining)
        if let mph = currentMph { workout.steps[stepIndex].mph = mph }
        if let incline = currentIncline { workout.steps[stepIndex].incline = incline }
        workout.steps = SafetyCheck.clamped(workout.steps)
        self.workout = workout
        let after = workout.totalSeconds
        note(.aiEdit, "\(detail) (length \(Self.clock(before)) → \(Self.clock(after)))")
        lastEdit = (stepIndex + 1, Array(workout.steps.dropFirst(stepIndex + 1)))
        dlog("Edit applied: \(detail). Next steps: "
             + workout.steps.dropFirst(stepIndex + 1).prefix(3).map { String(format: "%@ %.1f mph %g%%", $0.label, $0.mph, $0.incline) }.joined(separator: "; "))
        if phase == .running, let step = currentStep {
            if currentMph != nil {
                treadmill.setSpeed(step.mph)
                expectedMph = step.mph
            }
            if currentIncline != nil {
                treadmill.setIncline(step.incline)
                expectedIncline = step.incline
            }
            commandedAt = Date()
        }
        activity.update(activityState())

        saveRun()
        let notice = EditNotice(text: "Workout length \(Self.clock(after)), was \(Self.clock(before))")
        editNotice = notice
        Task {
            try? await Task.sleep(for: .seconds(10))
            if editNotice == notice {
                editNotice = nil
                undoSnapshot = nil
            }
        }
    }

    /// Puts the workout back as it was before the last live edit (available for 10 seconds).
    func undoLastEdit() {
        guard let snapshot = undoSnapshot, isActive else { return }
        workout = snapshot
        undoSnapshot = nil
        editNotice = nil
        note(.aiEdit, "undid the last change (length \(Self.clock(snapshot.totalSeconds)))")
        lastEdit = nil
        dlog("Undo tapped: the plan is back to the version before the last edit")
        if undoChangedCurrent, phase == .running, let step = currentStep {
            treadmill.setSpeed(step.mph)
            treadmill.setIncline(step.incline)
            expectedMph = step.mph
            expectedIncline = step.incline
            commandedAt = Date()
        }
        activity.update(activityState())
    }

    // MARK: Check-ins

    /// Answer to "How's it feeling?": Hard eases off right away, Easy offers a harder rest (one tap), Good changes nothing.
    func answerCheckIn(_ feeling: String) {
        checkInDue = false
        lastCheckInAt = totalElapsed
        note(.checkIn, feeling.lowercased())
        activity.update(activityState())
        guard let current = currentStep else { return }
        switch feeling {
        case "Hard":
            let easier = LiveCoach.easier(current: current, remaining: remainingSteps)
            applyEdit(remaining: easier.remaining, currentMph: easier.currentMph, currentIncline: easier.currentIncline,
                      note: "check-in hard: eased off")
        case "Easy":
            let harder = LiveCoach.harder(current: current, remaining: remainingSteps)
            present(Offer(message: "Feeling easy? Make it a bit harder (+0.3 mph, +1%) from now on?",
                          action: .edit(remaining: harder.remaining, currentMph: harder.currentMph,
                                        currentIncline: harder.currentIncline),
                          note: "check-in easy: made it harder"))
        default:
            break
        }
    }

    func dismissCheckIn() {
        checkInDue = false
        lastCheckInAt = totalElapsed
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

    private func launch(startBelt: Bool, resuming: Bool = false) {
        loop?.cancel()
        loop = Task { await run(startBelt: startBelt, resuming: resuming) }
    }

    private func run(startBelt: Bool, resuming: Bool = false) async {
        if startBelt {
            // A resumed workout skips the extra "speed 1.0"; the step sets its own speed right after
            treadmill.start(resetStats: false, setSpeed: !resuming)
            beltStartedAt = Date()
            guard await waitUntilRunning() else {
                if !Task.isCancelled {
                    phase = .paused("The belt didn't start. Check the safety key, then Resume.")
                    activity.update(activityState())
                }
                return
            }
            // Let the console finish starting before the step's incline and speed go out
            // (the treadmill checks them against its readings and resends if it dropped them)
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
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

            if let problem = treadmill.commandProblem, problem != lastNotedProblem {
                lastNotedProblem = problem
                note(.connection, problem)
            }
            detectConsoleChanges(now: now)
            runHold(now: now)
            runZoneWatch(now: now)
            runCalibrationSafety(now: now)
            peakMph = max(peakMph, treadmill.speedMph ?? 0)
            peakIncline = max(peakIncline, treadmill.incline ?? 0)
            stepElapsed += delta
            totalElapsed += delta
            sampleLog.add(elapsed: totalElapsed, mph: treadmill.speedMph ?? 0, incline: treadmill.incline ?? 0,
                          bpm: treadmill.heartRateProvider?()?.bpm, jog: jogging)
            if now.timeIntervalSince(lastSaveAt) >= 10 { saveRun() }
            let checkInMinutes = UserDefaults.standard.integer(forKey: Self.checkInKey)
            if checkInMinutes > 0, !checkInDue, offer == nil,
               totalElapsed - lastCheckInAt >= Double(checkInMinutes * 60), !remainingSteps.isEmpty {
                checkInDue = true
            }
            if let step = currentStep, stepElapsed >= Double(step.seconds) {
                advance()
            }
            trackCalibrationStage()
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
        } else {
            let step = workout.steps[stepIndex]
            dlog(String(format: "Step %d of %d: %@, %.1f mph, %.1f%%", stepIndex + 1, workout.steps.count, step.label, step.mph, step.incline))
            if let edit = lastEdit, stepIndex >= edit.from, stepIndex - edit.from < edit.steps.count {
                let expected = edit.steps[stepIndex - edit.from]
                if abs(expected.mph - step.mph) > 0.05 || abs(expected.incline - step.incline) > 0.05 {
                    dlog(String(format: "Edit check: this step is %.1f mph %g%% but the last edit set %.1f mph %g%%; the plan changed since (an undo or an offer)",
                                step.mph, step.incline, expected.mph, expected.incline))
                } else {
                    dlog("Edit check: this step matches the last edit")
                }
            }
            saveRun()
        }
    }

    private func applyStep() {
        guard let step = currentStep else { return }
        // With the heart-rate hold on, a main step starts from the plan plus what the hold has added so far
        var mph = step.mph
        var incline = step.incline
        if let engine = holdEngine, !SafetyCheck.isEndStep(step) {
            let limits = holdLimits
            mph = min(max(engine.effectiveMph(base: step.mph), limits.minMph), limits.maxMph)
            incline = min(max(engine.effectiveIncline(base: step.incline), 0), min(limits.maxIncline, SafetyCheck.inclineCap(forMph: mph)))
        }
        treadmill.setIncline(incline)
        treadmill.setSpeed(mph)
        expectedMph = mph
        expectedIncline = incline
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
        logChange(.speed, from: expectedMph, to: value, source: source) { String(format: "speed %.1f → %.1f mph", $0, $1) }
        expectedMph = value
        offerAdjustRestIfRepeated()
        offerEaseOffIfSlowingDown()
    }

    /// Three or more slow-downs in a workout → offer to lower the rest by their average (once).
    private func offerEaseOffIfSlowingDown() {
        guard offer == nil, !offeredEaseOff, !remainingSteps.isEmpty else { return }
        let slowdowns = deviations.filter { $0.kind == .speed }.compactMap(\.delta).filter { $0 < 0 }
        guard slowdowns.count >= 3 else { return }
        offeredEaseOff = true
        let shift = max(-1.0, (slowdowns.reduce(0, +) / Double(slowdowns.count) * 10).rounded() / 10)
        let amount = String(format: "%.1f", abs(shift))
        present(Offer(
            message: "You've slowed down \(slowdowns.count) times. Lower the rest of the workout by \(amount) mph?",
            action: .shiftSpeed(shift),
            note: "lowered the rest by \(amount) mph after repeated slow-downs"))
    }

    /// Two skipped steps → offer to cut the last 5 minutes before the cool-down (once).
    private func offerShortenIfSkipping() {
        guard offer == nil, !offeredShorten, let current = currentStep, remainingSteps.count > 1 else { return }
        guard deviations.filter({ $0.kind == .skip }).count >= 2 else { return }
        guard let shorter = LiveCoach.shorter(current: current, remaining: remainingSteps) else { return }
        offeredShorten = true
        present(Offer(
            message: "You've skipped two steps. Cut the last 5 minutes before the cool-down?",
            action: .edit(remaining: shorter.remaining, currentMph: nil, currentIncline: nil),
            note: "cut 5 minutes after skipping steps"))
    }

    private func recordInclineChange(to value: Double, source: String) {
        let delta = value - expectedIncline
        guard abs(delta) >= 0.25 else { return }
        logChange(.incline, from: expectedIncline, to: value, source: source) { String(format: "incline %.1f → %.1f%%", $0, $1) }
        expectedIncline = value
    }

    /// Logs a speed or incline change. Taps on the same tile within 3 s (same step, same source) merge
    /// into one entry that shows where it started and where it ended up.
    private func logChange(_ kind: Deviation.Kind, from: Double, to: Double, source: String,
                           format: (Double, Double) -> String) {
        if let last = lastChange[kind], last.source == source, last.step == stepIndex,
           totalElapsed - last.at <= 3, last.index < deviations.count, deviations[last.index].kind == kind {
            deviations[last.index].delta = to - last.from
            deviations[last.index].detail = format(last.from, to) + " " + source
            lastChange[kind]?.at = totalElapsed
            return
        }
        note(kind, format(from, to) + " " + source, delta: to - from)
        lastChange[kind] = ChangeOrigin(index: deviations.count - 1, from: from, at: totalElapsed,
                                        source: source, step: stepIndex)
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

    // MARK: Autosave and recovery

    /// What is saved every 10 seconds (and at every step, pause, resume and edit) so that a workout survives
    /// iOS closing and relaunching the app. Times are wall-clock based: see `finishRecovery`.
    private struct SavedRun: Codable {
        var workout: Workout
        var stepIndex: Int
        var stepElapsed: Double
        var totalElapsed: Double
        var deviations: [Deviation]
        var originalSeconds: Int
        var peakMph: Double
        var peakIncline: Double
        var samples: SampleLog
        var miles: Double
        var lastMph: Double
        var wasRunning: Bool
        var savedAt: Date
    }

    private static var savedRunURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("activeWorkout.json")
    }

    /// A saved workout younger than 4 hours; older ones are deleted.
    private static func loadSavedRun() -> SavedRun? {
        guard let data = try? Data(contentsOf: savedRunURL) else { return nil }
        guard let saved = try? JSONDecoder().decode(SavedRun.self, from: data),
              Date().timeIntervalSince(saved.savedAt) < 4 * 3600 else {
            try? FileManager.default.removeItem(at: savedRunURL)
            return nil
        }
        return saved
    }

    static var hasSavedRun: Bool { loadSavedRun() != nil }

    private func saveRun() {
        guard isActive, let workout else { return }
        lastSaveAt = Date()
        let saved = SavedRun(
            workout: workout, stepIndex: stepIndex, stepElapsed: stepElapsed, totalElapsed: totalElapsed,
            deviations: deviations, originalSeconds: originalSeconds, peakMph: peakMph, peakIncline: peakIncline,
            samples: sampleLog, miles: treadmill.miles, lastMph: treadmill.speedMph ?? 0,
            wasRunning: phase == .running, savedAt: Date())
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.savedRunURL, options: .atomic) }
    }

    private func clearSavedRun() {
        try? FileManager.default.removeItem(at: Self.savedRunURL)
    }

    /// The app was relaunched while a workout was running: bring it back on screen at once, then work out
    /// what the belt did in the meantime.
    private func recover(_ saved: SavedRun) {
        workout = saved.workout
        stepIndex = min(saved.stepIndex, max(0, saved.workout.steps.count - 1))
        stepElapsed = saved.stepElapsed
        totalElapsed = saved.totalElapsed
        deviations = saved.deviations
        originalSeconds = saved.originalSeconds
        peakMph = saved.peakMph
        peakIncline = saved.peakIncline
        sampleLog = saved.samples
        treadmill.workoutActive = true  // keeps treadmill mode from starting its own session
        treadmill.restoreStats(miles: saved.miles, movingSeconds: saved.totalElapsed)
        phase = .paused("Recovering your workout… reconnecting to the treadmill.")
        dlog("Recovering a saved workout: \(saved.workout.name), step \(saved.stepIndex + 1), "
             + "\(Int(saved.totalElapsed)) s in, saved \(Int(Date().timeIntervalSince(saved.savedAt))) s ago, "
             + (saved.wasRunning ? "it was running" : "it was paused"))
        if !activity.adopt() {
            activity.start(name: saved.workout.name, totalSeconds: saved.workout.totalSeconds, state: activityState())
        }
        loop = Task { await finishRecovery(saved) }
    }

    private func finishRecovery(_ saved: SavedRun) async {
        for _ in 0..<240 {  // the Bluetooth connection comes back by itself; wait up to a minute
            if Task.isCancelled { return }
            if treadmill.isReady, treadmill.speedMph != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if Task.isCancelled { return }
        guard treadmill.isReady, treadmill.speedMph != nil else {
            phase = .paused("The app was restarted and the treadmill isn't connected. Connect, then Resume.")
            note(.connection, "app restarted by iOS; treadmill not reconnected")
            dlog("Recovery: the treadmill didn't reconnect within a minute")
            saveRun()
            activity.update(activityState())
            return
        }
        let gap = max(0, Date().timeIntervalSince(saved.savedAt))
        if saved.wasRunning, treadmill.isRunning {
            // The belt is still moving, so the time since the last save counts as running time.
            // That is exact if it ran the whole time; if it was stopped and restarted on the console
            // in between, the time is a little long.
            stepElapsed += gap
            totalElapsed += gap
            treadmill.restoreStats(miles: saved.miles + saved.lastMph * gap / 3600, movingSeconds: totalElapsed)
            while let step = currentStep, stepElapsed >= Double(step.seconds) {
                stepElapsed -= Double(step.seconds)
                if stepIndex + 1 >= (workout?.steps.count ?? 0) {
                    note(.connection, "app restarted by iOS; the workout ended while it was away")
                    dlog("Recovery: the workout ran out while the app was away")
                    finish("Workout complete")
                    return
                }
                stepIndex += 1
            }
            note(.connection, "app restarted by iOS; recovered after \(Int(gap)) s")
            dlog("Recovery: belt still running, counted \(Int(gap)) s, now step \(stepIndex + 1), \(Int(totalElapsed)) s in")
            let notice = "Welcome back. Your workout kept going: \(Self.clock(Int(totalElapsed))) in."
            recoveryNotice = notice
            Task {
                try? await Task.sleep(for: .seconds(10))
                if recoveryNotice == notice { recoveryNotice = nil }
            }
            phase = .starting
            launch(startBelt: false)
        } else {
            phase = .paused("Recovered after the app restarted. Resume, or End workout to finish.")
            note(.connection, "app restarted by iOS; recovered paused")
            dlog("Recovery: belt stopped or workout was paused, recovered as paused")
        }
        saveRun()
        activity.update(activityState())
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
            finished: nil,
            checkIn: checkInDue ? true : nil)
    }

    private func finish(_ reason: String) {
        loop?.cancel()
        loop = nil
        clearSavedRun()
        holdEngine = nil
        holdTarget = nil
        holdStatus = ""
        zoneEngine = nil
        watchZone = nil
        if let test = calibration { finishCalibration(test) }
        dlog("Workout finished: \(reason), \(Int(totalElapsed)) s, \(String(format: "%.2f", treadmill.miles)) mi")
        treadmill.zeroInclineAndStop()
        treadmill.workoutActive = false
        phase = .finished(reason)
        offer = nil
        checkInDue = false
        var closing = activityState()
        closing.finished = reason
        closing.progress = reason == "Workout complete" ? 1 : progress
        activity.end(final: closing)
        if let workout {
            let reached = peakMph > 0
            onFinish?(HistoryEntry(
                date: Date(), name: workout.name, plannedSeconds: workout.totalSeconds,
                seconds: Int(totalElapsed), miles: treadmill.miles,
                maxMph: reached ? peakMph : workout.maxMph,
                maxIncline: reached ? peakIncline : workout.maxIncline,
                completed: reason == "Workout complete", deviations: deviations,
                originalSeconds: originalSeconds,
                summary: WorkoutSummary.make(samples: sampleLog.samples, miles: treadmill.miles, movingSeconds: Int(totalElapsed),
                                             weightLb: WorkoutSummary.storedWeightLb, zones: BodyProfile.stored.zones)))
        }
    }
}
