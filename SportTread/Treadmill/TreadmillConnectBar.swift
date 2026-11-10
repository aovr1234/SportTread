import SwiftUI

/// Shown wherever the treadmill is needed but not connected: says so plainly and offers Connect.
/// While connecting or reconnecting it shows progress instead of a button.
struct TreadmillConnectBar: View {
    @EnvironmentObject private var treadmill: TreadmillController

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: busy ? "antenna.radiowaves.left.and.right" : "bolt.horizontal.circle")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .symbolEffect(.variableColor.iterative, isActive: busy)
                Text(statusText).font(.subheadline.weight(.semibold))
                Spacer()
                if busy { ProgressView() }
            }
            if !busy {
                Button {
                    treadmill.connect()
                } label: {
                    Label("Connect treadmill", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(SportButtonStyle(kind: .go, height: 52))
            }
        }
        .padding(14)
        .glassCard(tint: .orange)
        .animation(.easeInOut, value: busy)
    }

    private var busy: Bool {
        [.scanning, .connecting, .handshaking, .reconnecting].contains(treadmill.state)
    }

    private var statusText: String {
        switch treadmill.state {
        case .scanning: "Looking for the treadmill…"
        case .connecting: "Connecting to the treadmill…"
        case .handshaking: "Connecting (about 20 s)…"
        case .reconnecting: "Connection lost. Reconnecting…"
        case .unavailable(let why): why
        default: "Treadmill disconnected"
        }
    }
}
