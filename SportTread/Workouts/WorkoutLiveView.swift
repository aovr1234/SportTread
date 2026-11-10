import SwiftUI

/// Full-screen live view while a workout runs, pauses or has just finished.
struct WorkoutLiveView: View {
    @EnvironmentObject private var runner: WorkoutRunner
    @EnvironmentObject private var treadmill: TreadmillController
    @EnvironmentObject private var library: WorkoutLibrary
    @EnvironmentObject private var liveCoach: LiveCoach
    @StateObject private var speech = SpeechInput()
    @State private var effort: Int?
    @State private var request = ""
    @State private var coachOpen = false

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if case .finished(let reason) = runner.phase {
                        summary(reason)
                    } else {
                        stepCard
                        adjustTiles
                        if runner.checkInDue {
                            checkInCard
                        }
                        if let offer = runner.offer {
                            offerBanner(offer)
                        }
                        coachPanel
                        nextAndProfile
                        if case .paused(let reason) = runner.phase {
                            if treadmill.isReady {
                                Label(reason, systemImage: "pause.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                TreadmillConnectBar()
                            }
                        }
                    }
                }
                .padding()
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: runner.stepIndex)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: runner.offer)
                .animation(.easeInOut, value: runner.phase)
                .animation(.easeInOut, value: runner.checkInDue)
                .animation(.easeInOut, value: coachOpen)
                .animation(.easeInOut, value: liveCoach.message)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            if runner.isActive { controls.padding(.horizontal).padding(.bottom, 8) }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: runner.stepIndex)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(runner.workout?.name ?? "Workout").font(.title2.weight(.heavy))
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(color: phaseColor, pulsing: runner.phase == .running)
                        .id(runner.phase == .running)
                    Text(phaseText).font(.subheadline.weight(.semibold)).foregroundStyle(phaseColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassCard(cornerRadius: 20)
            }
            GradientBar(progress: runner.progress)
            HStack {
                Text(clock(runner.totalElapsed))
                Spacer()
                Text("-" + clock(Double(runner.workout?.totalSeconds ?? 0) - runner.totalElapsed))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var phaseText: String {
        switch runner.phase {
        case .starting: "Starting…"
        case .running: "Running"
        case .paused: "Paused"
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

    // MARK: Step

    private var stepCard: some View {
        HStack(spacing: 18) {
            ZStack {
                RingProgress(progress: runner.stepProgress, lineWidth: 12)
                Text(clock(runner.stepRemaining))
                    .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: Int(runner.stepRemaining))
            }
            .frame(width: 128, height: 128)
            VStack(alignment: .leading, spacing: 6) {
                Text("STEP \(runner.stepIndex + 1) OF \(runner.workout?.steps.count ?? 0)")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(runner.currentStep?.label ?? "")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(Theme.accent)
                if let step = runner.currentStep {
                    Text("Target \(String(format: "%.1f", step.mph)) mph · \(String(format: "%g", step.incline))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard()
        .id(runner.stepIndex)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
    }

    private var adjustTiles: some View {
        HStack(spacing: 12) {
            AdjustTile(title: "Speed", unit: "mph", value: treadmill.speedMph, step: 0.1,
                       range: TreadmillController.minMph...TreadmillController.maxMph, decimals: 1,
                       enabled: runner.phase == .running) { runner.adjustSpeed(to: $0) }
            AdjustTile(title: "Incline", unit: "%", value: treadmill.incline, step: 0.5,
                       range: 0...TreadmillController.maxIncline, decimals: 1,
                       enabled: runner.phase == .running) { runner.adjustIncline(to: $0) }
        }
    }

    private func offerBanner(_ offer: WorkoutRunner.Offer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(offer.message, systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                Button("Apply") { runner.acceptOffer() }
                    .buttonStyle(SportButtonStyle(kind: .go, height: 40))
                Button("No thanks") { runner.dismissOffer() }
                    .buttonStyle(SportButtonStyle(kind: .neutral, height: 40))
            }
        }
        .padding(14)
        .glassCard(tint: Theme.cyan)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Coach

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
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var coachPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                coachOpen.toggle()
            } label: {
                HStack {
                    Label("Coach", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .symbolEffect(.pulse, isActive: liveCoach.isWorking)
                    Spacer()
                    if liveCoach.isWorking { ProgressView() }
                    Image(systemName: coachOpen ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                ForEach(LiveCoach.Quick.allCases) { kind in
                    Button {
                        Task { await liveCoach.quick(kind, runner: runner) }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: kind.symbol).font(.title3)
                            Text(kind.rawValue).font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.plain)
                    .glassCard(cornerRadius: 14, interactive: true)
                }
            }
            .disabled(liveCoach.isWorking)

            if coachOpen {
                HStack(spacing: 8) {
                    TextField("e.g. skip the hills, my knees hurt", text: $request, axis: .vertical)
                        .lineLimit(1...3)
                        .padding(10)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    micButton
                    Button {
                        let text = request
                        request = ""
                        Task { await liveCoach.ask(text, runner: runner) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .foregroundStyle(Theme.lime)
                    .disabled(request.trimmingCharacters(in: .whitespaces).isEmpty || liveCoach.isWorking)
                }
                if let problem = speech.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                Text("Easier changes apply right away; harder ones wait for your tap.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let message = liveCoach.message {
                Text(message).font(.footnote).foregroundStyle(Theme.lime).transition(.opacity)
            }
        }
        .padding(14)
        .glassCard()
        .onChange(of: speech.transcript) { _, text in
            if !text.isEmpty { request = text }
        }
    }

    /// Hold to talk: listening while pressed, the words land in the box to check before sending.
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

    private var nextAndProfile: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let next = runner.nextStep {
                HStack {
                    Text("NEXT").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Text(next.label).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(String(format: "%.1f", next.mph)) mph · \(String(format: "%g", next.incline))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let workout = runner.workout {
                WorkoutProfile(workout: workout, height: 54, showAxes: false, highlight: runner.stepIndex)
            }
        }
        .padding(14)
        .glassCard()
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if case .paused = runner.phase {
                    Button { runner.resume() } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(SportButtonStyle(kind: .go, height: 52))
                    Button { runner.end() } label: { Label("End workout", systemImage: "flag.checkered") }
                        .buttonStyle(SportButtonStyle(kind: .neutral, height: 52))
                } else {
                    Button { runner.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(SportButtonStyle(kind: .neutral, height: 52))
                    Button { runner.skip() } label: { Label("Skip", systemImage: "forward.end.fill") }
                        .buttonStyle(SportButtonStyle(kind: .neutral, height: 52))
                }
            }
            if !isPaused {
                Button(role: .destructive) {
                    runner.pause(reason: "Stopped. Resume, or End workout to finish.")
                } label: {
                    Label("STOP", systemImage: "stop.fill").font(.title3.weight(.heavy))
                }
                .buttonStyle(SportButtonStyle(kind: .stop, height: 64))
            }
        }
    }

    private var isPaused: Bool {
        if case .paused = runner.phase { return true }
        return false
    }

    // MARK: Summary

    private func summary(_ reason: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: reason == "Workout complete" ? "checkmark.seal.fill" : "flag.checkered")
                .font(.system(size: 68))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.bounce, value: reason)
                .padding(.top, 24)
            Text(reason).font(.largeTitle.weight(.heavy))
            HStack(spacing: 12) {
                MetricTile(value: clock(treadmill.movingSeconds), unit: "moving time", size: 30)
                MetricTile(value: String(format: "%.2f", treadmill.miles), unit: "miles", size: 30)
            }
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
                Text("The coach uses this to adjust your next workout. Incline is back at 0%.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .glassCard()
            Button {
                runner.dismiss()
            } label: {
                Text("Done")
            }
            .buttonStyle(SportButtonStyle(kind: .go))
        }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
