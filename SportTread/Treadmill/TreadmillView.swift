import SwiftUI

/// Milestone 1: live treadmill control.
struct TreadmillView: View {
    @EnvironmentObject private var treadmill: TreadmillController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusBar

                    HStack(spacing: 12) {
                        bigTile(treadmill.speedMph.map { String(format: "%.1f", $0) } ?? "–", unit: "mph")
                        bigTile(treadmill.incline.map { String(format: "%.1f", $0) } ?? "–", unit: "% incline")
                    }
                    HStack(spacing: 12) {
                        smallTile(timeText, unit: "moving time")
                        smallTile(String(format: "%.2f", treadmill.miles), unit: "miles")
                    }

                    if treadmill.isReady {
                        controls
                    } else {
                        connectCard
                    }

                    if !treadmill.lastEvent.isEmpty {
                        Text(treadmill.lastEvent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("The console Stop button and the safety key always work.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("Andrew's SportTread")
            .safeAreaInset(edge: .bottom) {
                if treadmill.isReady {
                    Button(role: .destructive) {
                        treadmill.stop()
                    } label: {
                        Text("STOP")
                            .font(.title2.weight(.heavy))
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
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

    private var statusBar: some View {
        HStack {
            Circle().fill(statusColor).frame(width: 10, height: 10)
            Text(statusText).font(.subheadline)
            Spacer()
            if treadmill.isReady {
                Button("Disconnect") { treadmill.disconnect() }.font(.subheadline)
            }
        }
    }

    private var statusText: String {
        switch treadmill.state {
        case .idle: "Not connected"
        case .unavailable(let why): why
        case .scanning: "Looking for the treadmill…"
        case .connecting: "Connecting…"
        case .handshaking: "Connecting (about 20 s)…"
        case .ready: treadmill.isRunning ? "Running" : "Connected, belt stopped"
        case .disconnected: "Disconnected"
        }
    }

    private var statusColor: Color {
        switch treadmill.state {
        case .ready: Theme.volt
        case .scanning, .connecting, .handshaking: .orange
        default: .gray
        }
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Turn the treadmill on and close any other app connected to it (like iFit).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                treadmill.connect()
            } label: {
                Text("Connect")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.volt)
            .foregroundStyle(.black)
            .disabled([.scanning, .connecting, .handshaking].contains(treadmill.state))
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if !treadmill.isRunning {
                Button {
                    treadmill.start()
                } label: {
                    Label("Start at 1.0 mph", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.volt)
                .foregroundStyle(.black)
            }

            controlRow(title: "Speed", steps: [-0.5, -0.1, 0.1, 0.5], format: "%+.1f") {
                treadmill.changeSpeed(by: $0)
            }
            .disabled(!treadmill.isRunning)

            HStack(spacing: 8) {
                ForEach([2.0, 3.0, 4.0, 5.0], id: \.self) { mph in
                    Button(String(format: "%.0f mph", mph)) { treadmill.setSpeed(mph) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!treadmill.isRunning)

            controlRow(title: "Incline", steps: [-1, -0.5, 0.5, 1], format: "%+.1f") {
                treadmill.changeIncline(by: $0)
            }
        }
    }

    private func controlRow(title: String, steps: [Double], format: String,
                            action: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(steps, id: \.self) { step in
                    Button(String(format: format, step)) { action(step) }
                        .font(.headline.monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func bigTile(_ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 56, weight: .heavy).monospacedDigit())
                .contentTransition(.numericText())
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    private func smallTile(_ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 28, weight: .bold).monospacedDigit())
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}
