import SwiftUI

/// Full-screen live view while a workout runs, pauses or has just finished. It fits one screen with no
/// scrolling: header (name, time, profile chart as the progress bar, status), the step ring, the Speed and
/// Incline tiles, and one bottom bar. The coach lives in a sheet; check-ins, offers and the length notice
/// float over the top so they never push the layout.
struct WorkoutLiveView: View {
    @EnvironmentObject private var runner: WorkoutRunner
    @EnvironmentObject private var treadmill: TreadmillController
    @EnvironmentObject private var library: WorkoutLibrary
    @State private var effort: Int?
    @State private var coachOpen = false

    var body: some View {
        ZStack {
            AppBackground()
            GeometryReader { geo in
                VStack(spacing: 10) {
                    header
                    if case .finished(let reason) = runner.phase {
                        summary(reason)
                    } else {
                        stepCard(ring: min(124, max(84, geo.size.height * 0.16)))
                        adjustTiles
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
        }
        .overlay(alignment: .top) { overlays }
        .safeAreaInset(edge: .bottom) {
            if runner.isActive { controls.padding(.horizontal).padding(.bottom, 8) }
        }
        .sheet(isPresented: $coachOpen) {
            CoachSheet().presentationDetents([.height(470), .large])
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: runner.stepIndex)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: runner.offer)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: runner.checkInDue)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: runner.editNotice)
        .animation(.easeInOut, value: runner.phase)
        .sensoryFeedback(.impact(weight: .heavy), trigger: runner.stepIndex)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(runner.workout?.name ?? "Workout").font(.headline).lineLimit(1)
                Spacer()
                Text("\(clock(runner.totalElapsed)) / \(clock(Double(runner.workout?.totalSeconds ?? 0)))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !isFinished {
                if let workout = runner.workout {
                    WorkoutProfile(workout: workout, height: 44, showAxes: false,
                                   highlight: runner.stepIndex, position: runner.totalElapsed / 60)
                }
                statusRow
            }
        }
    }

    private var isFinished: Bool {
        if case .finished = runner.phase { return true }
        return false
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            StatusDot(color: phaseColor, pulsing: runner.phase == .running)
                .id(runner.phase == .running)
            Text(statusText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(phaseColor)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            HeartChip()
            if runner.isActive && !treadmill.isReady {
                if [.scanning, .connecting, .handshaking, .reconnecting].contains(treadmill.state) {
                    ProgressView()
                } else {
                    Button("Connect") { treadmill.connect() }
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.lime)
                }
            }
        }
        .frame(minHeight: 30)
    }

    private var statusText: String {
        switch runner.phase {
        case .starting: "Starting…"
        case .running: runner.holdTarget != nil && !runner.holdStatus.isEmpty ? runner.holdStatus : "Running"
        case .paused(let reason): reason
        case .finished: "Done"
        case .idle: ""
        }
    }

    private var phaseColor: Color {
        switch runner.phase {
        case .running: Theme.lime
        case .paused: .orange
        default: .secondary
        }
    }

    // MARK: Step and tiles

    private func stepCard(ring: CGFloat) -> some View {
        HStack(spacing: 16) {
            ZStack {
                RingProgress(progress: runner.stepProgress, lineWidth: 11)
                Text(clock(runner.stepRemaining))
                    .font(.system(size: ring * 0.27, weight: .heavy, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: Int(runner.stepRemaining))
            }
            .frame(width: ring, height: ring)
            VStack(alignment: .leading, spacing: 4) {
                Text("STEP \(runner.stepIndex + 1) OF \(runner.workout?.steps.count ?? 0)")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(runner.currentStep?.label ?? "")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if let step = runner.currentStep {
                    Text("Target \(String(format: "%.1f", step.mph)) mph · \(String(format: "%g", step.incline))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let next = runner.nextStep {
                    Text("Next: \(next.label) · \(String(format: "%.1f", next.mph)) mph · \(String(format: "%g", next.incline))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassCard()
        .id(runner.stepIndex)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
    }

    private var adjustTiles: some View {
        HStack(spacing: 12) {
            AdjustTile(title: "Speed", unit: "mph", value: treadmill.speedMph, step: 0.1,
                       range: TreadmillController.minMph...TreadmillController.maxMph, decimals: 1,
                       enabled: runner.phase == .running, valueSize: 54, expand: true) { runner.adjustSpeed(to: $0) }
            AdjustTile(title: "Incline", unit: "%", value: treadmill.incline, step: 0.5,
                       range: 0...TreadmillController.maxIncline, decimals: 1,
                       enabled: runner.phase == .running, valueSize: 54, expand: true) { runner.adjustIncline(to: $0) }
        }
    }

    // MARK: Overlays (never push the layout)

    private var overlays: some View {
        VStack(spacing: 8) {
            if runner.checkInDue { checkInCard.transition(.move(edge: .top).combined(with: .opacity)) }
            if let offer = runner.offer { offerBanner(offer).transition(.move(edge: .top).combined(with: .opacity)) }
            if let notice = runner.editNotice { noticeCard(notice).transition(.move(edge: .top).combined(with: .opacity)) }
            if let welcome = runner.recoveryNotice {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Theme.lime)
                    Text(welcome).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .glassCard(cornerRadius: 18, tint: Theme.lime)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let problem = treadmill.commandProblem {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .glassCard(cornerRadius: 18, tint: .orange)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: treadmill.commandProblem)
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private var checkInCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("How's it feeling?", systemImage: "hand.wave.fill").font(.subheadline.weight(.semibold))
                Spacer()
                Button { runner.dismissCheckIn() } label: { Image(systemName: "xmark") }
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(["Easy", "Good", "Hard"], id: \.self) { feeling in
                    Button(feeling) { runner.answerCheckIn(feeling) }
                        .buttonStyle(SportButtonStyle(kind: feeling == "Good" ? .go : .neutral, height: 40))
                }
            }
        }
        .padding(14)
        .glassCard(tint: Theme.lime)
    }

    private func offerBanner(_ offer: WorkoutRunner.Offer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(offer.message, systemImage: "sparkles").font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                Button("Apply") { runner.acceptOffer() }
                    .buttonStyle(SportButtonStyle(kind: .go, height: 40))
                Button("No thanks") { runner.dismissOffer() }
                    .buttonStyle(SportButtonStyle(kind: .neutral, height: 40))
            }
        }
        .padding(14)
        .glassCard(tint: Theme.cyan)
    }

    private func noticeCard(_ notice: WorkoutRunner.EditNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.lime)
            Text(notice.text).font(.subheadline.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 0)
            Button("Undo") { runner.undoLastEdit() }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.lime)
        }
        .padding(12)
        .glassCard(cornerRadius: 18, tint: Theme.lime)
    }

    // MARK: Bottom bar

    private var isPaused: Bool {
        if case .paused = runner.phase { return true }
        return false
    }

    private func barLabel(_ title: String, _ symbol: String) -> some View {
        Label {
            Text(title).lineLimit(1).minimumScaleFactor(0.7)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.subheadline.weight(.bold))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { coachOpen = true } label: { Image(systemName: "sparkles").font(.title3) }
                .buttonStyle(SportButtonStyle(kind: .neutral, height: 58))
                .frame(width: 58)
                .accessibilityLabel("Coach")
            if isPaused {
                Button { runner.resume() } label: { barLabel("Resume", "play.fill") }
                    .buttonStyle(SportButtonStyle(kind: .go, height: 58))
                Button { runner.end() } label: { barLabel("End workout", "flag.checkered") }
                    .buttonStyle(SportButtonStyle(kind: .neutral, height: 58))
            } else {
                Button { runner.pause() } label: { barLabel("Pause", "pause.fill") }
                    .buttonStyle(SportButtonStyle(kind: .neutral, height: 58))
                Button { runner.skip() } label: { barLabel("Skip", "forward.end.fill") }
                    .buttonStyle(SportButtonStyle(kind: .neutral, height: 58))
                Button(role: .destructive) {
                    runner.pause(reason: "Stopped. Resume, or End workout to finish.")
                } label: {
                    Text("STOP").font(.headline.weight(.heavy))
                }
                .buttonStyle(SportButtonStyle(kind: .stop, height: 58))
            }
        }
    }

    // MARK: Summary

    private func summary(_ reason: String) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: reason == "Workout complete" ? "checkmark.seal.fill" : "flag.checkered")
                    .font(.title)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: reason)
                Text(reason).font(.title.weight(.heavy))
            }
            if let entry = library.history.last, entry.name == runner.workout?.name {
                SummaryBlock(entry: entry, others: library.history.filter { $0.id != entry.id })
            } else {
                HStack(spacing: 12) {
                    MetricTile(value: clock(treadmill.movingSeconds), unit: "moving time", size: 30)
                    MetricTile(value: String(format: "%.2f", treadmill.miles), unit: "miles", size: 30)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                Text("How hard was it? (1 = very easy, 10 = all out)").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(1...10, id: \.self) { value in
                        Button {
                            effort = value
                            library.rateLast(value)
                        } label: {
                            Text("\(value)")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(effort == value ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.1)),
                                            in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(effort == value ? .black : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .sensoryFeedback(.selection, trigger: effort)
            }
            .padding(12)
            .glassCard()
            Button {
                runner.dismiss()
            } label: {
                Text("Done")
            }
            .buttonStyle(SportButtonStyle(kind: .go))
            .padding(.bottom, 8)
        }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Heart-rate hold: switch, target and what moves (speed, incline or both).
private struct HoldControls: View {
    @EnvironmentObject private var runner: WorkoutRunner
    @EnvironmentObject private var heart: HeartRateMonitor
    @AppStorage("holdTarget") private var target = 150
    @AppStorage("holdControl") private var controlName = HeartRateHold.Control.speed.rawValue

    private var control: HeartRateHold.Control { HeartRateHold.Control(rawValue: controlName) ?? .speed }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Hold my heart rate", systemImage: "heart.fill").font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("Hold my heart rate", isOn: Binding(
                    get: { runner.holdTarget != nil },
                    set: { on in
                        if on { runner.startHold(target: target, control: control) } else { runner.stopHold() }
                    }))
                    .labelsHidden()
                    .disabled(heart.sensorName == nil)
            }
            if heart.sensorName == nil {
                Text("Connect a heart-rate sensor in Setup first.").font(.caption).foregroundStyle(.orange)
            } else {
                Stepper("Target \(target) bpm", value: $target, in: 90...190, step: 5)
                    .font(.subheadline)
                    .onChange(of: target) { _, value in runner.updateHold(target: value, control: control) }
                Picker("Moves", selection: $controlName) {
                    ForEach(HeartRateHold.Control.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: controlName) { _, _ in runner.updateHold(target: target, control: control) }
                Text("Changes the speed or incline in small steps, only in the main part. The tiles and STOP always win.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
    }
}

/// The coach, in a sheet: four fixed quick buttons, typed or spoken requests, and the workout length.
private struct CoachSheet: View {
    @EnvironmentObject private var runner: WorkoutRunner
    @EnvironmentObject private var liveCoach: LiveCoach
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechInput()
    @State private var request = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Coach", systemImage: "sparkles")
                    .font(.headline)
                    .symbolEffect(.pulse, isActive: liveCoach.isWorking)
                Spacer()
                if liveCoach.isWorking { ProgressView() }
                Button("Done") { dismiss() }.fontWeight(.semibold)
            }

            HStack(spacing: 8) {
                ForEach(LiveCoach.Quick.allCases) { kind in
                    Button {
                        liveCoach.quick(kind, runner: runner)
                        dismiss()
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: kind.symbol).font(.title3)
                            Text(kind.title).font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 58)
                    }
                    .buttonStyle(.plain)
                    .glassCard(cornerRadius: 16, interactive: true)
                }
            }
            .disabled(liveCoach.isWorking)

            HoldControls()

            HStack(spacing: 8) {
                TextField("e.g. skip the hills, my knees hurt", text: $request, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                micButton
                Button {
                    let text = request
                    request = ""
                    Task { @MainActor in
                        await liveCoach.ask(text, runner: runner)
                        if liveCoach.message == nil { dismiss() }
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .foregroundStyle(Theme.lime)
                .disabled(request.trimmingCharacters(in: .whitespaces).isEmpty || liveCoach.isWorking)
            }
            if let problem = speech.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            if let message = liveCoach.message {
                Text(message).font(.footnote).foregroundStyle(Theme.lime)
            }

            if let workout = runner.workout {
                let now = WorkoutRunner.clock(workout.totalSeconds)
                let start = WorkoutRunner.clock(runner.originalSeconds)
                Text(workout.totalSeconds == runner.originalSeconds
                     ? "Workout length \(now)"
                     : "Workout length \(now) (started at \(start))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Easier and −5 min apply right away; harder and +5 min wait for your tap. Say a length (\"add 5 minutes\", \"make it an hour total\") and the workout comes out exactly that long.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture { hideKeyboard() }
        .onChange(of: speech.transcript) { _, text in
            if !text.isEmpty { request = text }
        }
        .onAppear { liveCoach.message = nil }
    }

    /// Hold to talk: listening while pressed; the words land in the box to check before sending.
    private var micButton: some View {
        Image(systemName: speech.isListening ? "mic.fill" : "mic")
            .font(.title2)
            .foregroundStyle(speech.isListening ? Theme.stop : Theme.lime)
            .symbolEffect(.pulse, isActive: speech.isListening)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !speech.isListening { Task { await speech.start() } }
                    }
                    .onEnded { _ in speech.stop() })
            .accessibilityLabel("Hold to talk")
    }
}
