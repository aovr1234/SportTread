import SwiftUI

/// Full-screen live view while a workout runs, pauses or has just finished.
struct WorkoutLiveView: View {
    @EnvironmentObject private var runner: WorkoutRunner
    @EnvironmentObject private var treadmill: TreadmillController

    var body: some View {
        VStack(spacing: 16) {
            header
            if case .finished(let reason) = runner.phase {
                summary(reason)
            } else {
                stepCard
                liveReadout
                if let next = runner.nextStep {
                    Text("Next: \(next.label) · \(String(format: "%.1f", next.mph)) mph · \(String(format: "%g", next.incline))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let workout = runner.workout {
                    WorkoutProfile(workout: workout, height: 60, showAxes: false, highlight: runner.stepIndex)
                }
                if case .paused(let reason) = runner.phase {
                    Text(reason).font(.subheadline).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                controls
            }
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
        .sensoryFeedback(.impact(weight: .heavy), trigger: runner.stepIndex)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(runner.workout?.name ?? "Workout").font(.title2.weight(.bold))
                Spacer()
                Text(phaseText).font(.subheadline).foregroundStyle(phaseColor)
            }
            ProgressView(value: runner.progress).tint(Theme.volt)
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
        case .running: Theme.volt
        case .paused: .orange
        default: .secondary
        }
    }

    private var stepCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(runner.currentStep?.label ?? "").font(.headline).foregroundStyle(Theme.volt)
            Text(clock(runner.stepRemaining))
                .font(.system(size: 72, weight: .heavy).monospacedDigit())
                .contentTransition(.numericText())
            if let step = runner.currentStep {
                Text("Target \(String(format: "%.1f", step.mph)) mph · \(String(format: "%g", step.incline))% incline")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
    }

    private var liveReadout: some View {
        HStack(spacing: 12) {
            tile(treadmill.speedMph.map { String(format: "%.1f", $0) } ?? "–", "mph")
            tile(treadmill.incline.map { String(format: "%.1f", $0) } ?? "–", "% incline")
            tile(String(format: "%.2f", treadmill.miles), "miles")
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if case .paused = runner.phase {
                    wideButton("Resume", systemImage: "play.fill", tint: Theme.volt, dark: true) { runner.resume() }
                } else {
                    wideButton("Pause", systemImage: "pause.fill", tint: .gray, dark: false) { runner.pause() }
                }
                wideButton("Skip", systemImage: "forward.end.fill", tint: .gray, dark: false) { runner.skip() }
            }
            Button(role: .destructive) {
                runner.end()
            } label: {
                Text("STOP").font(.title2.weight(.heavy)).frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private func summary(_ reason: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: reason == "Workout complete" ? "checkmark.circle.fill" : "flag.checkered")
                .font(.system(size: 64))
                .foregroundStyle(Theme.volt)
            Text(reason).font(.title.weight(.bold))
            HStack(spacing: 12) {
                tile(clock(treadmill.movingSeconds), "moving time")
                tile(String(format: "%.2f", treadmill.miles), "miles")
            }
            Spacer()
            Button {
                runner.dismiss()
            } label: {
                Text("Done").font(.headline).frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.volt)
            .foregroundStyle(.black)
        }
    }

    private func tile(_ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 28, weight: .bold).monospacedDigit())
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private func wideButton(_ title: String, systemImage: String, tint: Color, dark: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).font(.headline).frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .foregroundStyle(dark ? .black : .white)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
