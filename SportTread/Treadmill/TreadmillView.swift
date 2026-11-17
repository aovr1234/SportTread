import SwiftUI

/// Treadmill mode, laid out to fit one screen with no scrolling: status row, the Speed and Incline tiles
/// (readout and controls in one), a time/miles line, and one bottom bar. Messages are toasts.
struct TreadmillView: View {
    @EnvironmentObject private var treadmill: TreadmillController
    @State private var toast: String?
    @State private var toastID = UUID()
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                statusRow

                HStack(spacing: 12) {
                    AdjustTile(title: "Speed", unit: "mph", value: treadmill.speedMph, step: 0.1,
                               range: TreadmillController.minMph...TreadmillController.maxMph, decimals: 1,
                               enabled: treadmill.isRunning, valueSize: 64, expand: true) { treadmill.setSpeed($0) }
                    AdjustTile(title: "Incline", unit: "%", value: treadmill.incline, step: 0.5,
                               range: 0...TreadmillController.maxIncline, decimals: 1,
                               enabled: treadmill.isReady, valueSize: 64, expand: true) { treadmill.setIncline($0) }
                }

                statsLine
                bottomBar
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(AppBackground())
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassCard(cornerRadius: 18, tint: Theme.cyan)
                        .padding(.horizontal)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: toast)
            .navigationTitle("Andrew's SportTread")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: treadmill.lastEvent) { _, text in
                if !text.isEmpty { show(text, seconds: 4) }
            }
            .onChange(of: treadmill.lastSessionSummary) { _, summary in
                if let summary, !treadmill.sessionActive { show("Session saved: \(summary)", seconds: 6) }
            }
            .sheet(item: $treadmill.lastSessionEntry) { entry in
                SessionSummarySheet(entry: entry)
            }
            .onChange(of: treadmill.isReady) { _, ready in
                UIApplication.shared.isIdleTimerDisabled = ready  // keep the screen on while connected
                if !ready { cancelCountdown() }
            }
        }
    }

    // MARK: Pieces

    private var statusRow: some View {
        HStack(spacing: 10) {
            StatusDot(color: statusColor, pulsing: treadmill.isRunning || busy)
                .id("\(statusColor)-\(treadmill.isRunning || busy)")
            Text(statusText).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer()
            Menu {
                Button("Disconnect", role: .destructive) { treadmill.disconnect() }
                    .disabled(!treadmill.isReady)
                Section {
                    Button {} label: {
                        Label("The console Stop button and the safety key always work.", systemImage: "checkmark.shield")
                    }
                    .disabled(true)
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 28)
    }

    private var statsLine: some View {
        HStack {
            Label(timeText, systemImage: "clock")
            Spacer()
            Label(String(format: "%.2f mi", treadmill.miles), systemImage: "figure.walk")
        }
        .font(.title3.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 22)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if !treadmill.isReady {
            TreadmillConnectBar()
        } else if treadmill.isRunning {
            HStack(spacing: 10) {
                if treadmill.sessionActive { endButton }
                Button(role: .destructive) {
                    treadmill.stop()
                } label: {
                    Label("STOP", systemImage: "stop.fill").font(.title3.weight(.heavy))
                }
                .buttonStyle(SportButtonStyle(kind: .stop, height: 64))
            }
        } else {
            HStack(spacing: 10) {
                if treadmill.sessionActive { endButton }
                startButton
            }
        }
    }

    private var endButton: some View {
        Button {
            treadmill.endWorkout()
        } label: {
            Label("End workout", systemImage: "flag.checkered")
        }
        .buttonStyle(SportButtonStyle(kind: .neutral, height: 64))
    }

    /// Start counts 3-2-1 first (tap again to cancel), so a quick double-tap on STOP can't restart the belt.
    private var startButton: some View {
        Button {
            if countdown != nil { cancelCountdown() } else { beginCountdown() }
        } label: {
            if let countdown {
                Text("\(countdown)… tap to cancel")
            } else {
                Label("Start", systemImage: "play.fill")
            }
        }
        .buttonStyle(SportButtonStyle(kind: countdown == nil ? .go : .neutral, height: 64))
    }

    private func beginCountdown() {
        countdown = 3
        countdownTask = Task { @MainActor in
            for n in stride(from: 3, through: 1, by: -1) {
                countdown = n
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            countdownTask = nil
            treadmill.start(resetStats: !treadmill.sessionActive)
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func show(_ text: String, seconds: Double) {
        let id = UUID()
        toastID = id
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if toastID == id { toast = nil }
        }
    }

    // MARK: Status

    private var timeText: String {
        let s = Int(treadmill.movingSeconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var busy: Bool {
        [.scanning, .connecting, .handshaking, .reconnecting].contains(treadmill.state)
    }

    private var statusText: String {
        switch treadmill.state {
        case .idle: "Not connected"
        case .unavailable(let why): why
        case .scanning: "Looking for the treadmill…"
        case .connecting: "Connecting…"
        case .handshaking: "Connecting (about 20 s)…"
        case .ready: treadmill.isRunning ? "Running" : "Connected, belt stopped"
        case .reconnecting: "Reconnecting…"
        case .disconnected: "Disconnected"
        }
    }

    private var statusColor: Color {
        switch treadmill.state {
        case .ready: Theme.lime
        case .scanning, .connecting, .handshaking, .reconnecting: .orange
        default: .gray
        }
    }
}
