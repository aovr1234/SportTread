import SwiftUI

/// Treadmill mode: live readout and manual control, with End workout and a session summary.
struct TreadmillView: View {
    @EnvironmentObject private var treadmill: TreadmillController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusPill

                    HStack(spacing: 12) {
                        MetricTile(value: treadmill.speedMph.map { String(format: "%.1f", $0) } ?? "–",
                                   unit: "mph", highlighted: treadmill.isRunning)
                        MetricTile(value: treadmill.incline.map { String(format: "%.1f", $0) } ?? "–",
                                   unit: "% incline")
                    }
                    HStack(spacing: 12) {
                        MetricTile(value: timeText, unit: "moving time", size: 30)
                        MetricTile(value: String(format: "%.2f", treadmill.miles), unit: "miles", size: 30)
                    }

                    if let summary = treadmill.lastSessionSummary, !treadmill.sessionActive {
                        Label("Session saved: \(summary)", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.lime)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .glassCard(tint: Theme.lime)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if treadmill.isReady {
                        controls
                    } else {
                        TreadmillConnectBar()
                        Text("Turn the treadmill on and close any other app connected to it (like iFit).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !treadmill.lastEvent.isEmpty {
                        Text(treadmill.lastEvent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(treadmill.lastEvent)
                            .transition(.opacity)
                    }
                    Text("The console Stop button and the safety key always work.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: treadmill.isRunning)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: treadmill.sessionActive)
                .animation(.easeInOut, value: treadmill.lastEvent)
            }
            .background(AppBackground())
            .navigationTitle("Andrew's SportTread")
            .safeAreaInset(edge: .bottom) {
                if treadmill.isReady {
                    Button(role: .destructive) {
                        treadmill.stop()
                    } label: {
                        Label("STOP", systemImage: "stop.fill").font(.title3.weight(.heavy))
                    }
                    .buttonStyle(SportButtonStyle(kind: .stop, height: 64))
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: treadmill.isReady) { _, ready in
                UIApplication.shared.isIdleTimerDisabled = ready  // keep the screen on while connected
            }
        }
    }

    private var timeText: String {
        let s = Int(treadmill.movingSeconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Pieces

    private var statusPill: some View {
        HStack(spacing: 10) {
            StatusDot(color: statusColor, pulsing: treadmill.isRunning || busy)
                .id("\(statusColor)-\(treadmill.isRunning || busy)")
            Text(statusText).font(.subheadline.weight(.semibold))
            Spacer()
            if treadmill.isReady {
                Button("Disconnect") { treadmill.disconnect() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 30)
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

    private var controls: some View {
        VStack(spacing: 14) {
            if !treadmill.isRunning {
                Button {
                    treadmill.start()
                } label: {
                    Label("Start at 1.0 mph", systemImage: "play.fill")
                }
                .buttonStyle(SportButtonStyle(kind: .go, height: 60))
                .transition(.scale.combined(with: .opacity))
            }

            HStack(spacing: 12) {
                AdjustTile(title: "Speed", unit: "mph", value: treadmill.speedMph, step: 0.1,
                           range: TreadmillController.minMph...TreadmillController.maxMph, decimals: 1,
                           enabled: treadmill.isRunning) { treadmill.setSpeed($0) }
                AdjustTile(title: "Incline", unit: "%", value: treadmill.incline, step: 0.5,
                           range: 0...TreadmillController.maxIncline, decimals: 1) { treadmill.setIncline($0) }
            }

            HStack(spacing: 8) {
                ForEach([2.0, 3.0, 4.0, 5.0], id: \.self) { mph in
                    Button(String(format: "%.0f mph", mph)) { treadmill.setSpeed(mph) }
                        .buttonStyle(SportButtonStyle(kind: .neutral, height: 40))
                        .font(.subheadline)
                }
            }
            .disabled(!treadmill.isRunning)

            if treadmill.sessionActive {
                Button {
                    treadmill.endWorkout()
                } label: {
                    Label("End workout", systemImage: "flag.checkered")
                }
                .buttonStyle(SportButtonStyle(kind: .neutral, height: 52))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                Text("Ends the session: incline back to 0%, belt stops, session saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
