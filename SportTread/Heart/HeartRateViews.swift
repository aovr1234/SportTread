import SwiftUI

/// "♥ 142" for the Treadmill and Workout screens; nothing at all until a sensor has been chosen.
struct HeartChip: View {
    @EnvironmentObject private var heart: HeartRateMonitor

    var body: some View {
        if heart.sensorName != nil {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").foregroundStyle(heart.signal ? Color.red : Color.secondary)
                Text(heart.signal ? "\(heart.bpm ?? 0)" : "--").monospacedDigit()
            }
            .font(.footnote.weight(.bold))
            .accessibilityLabel(heart.signal ? "Heart rate \(heart.bpm ?? 0)" : "No heart rate signal")
        }
    }
}

/// Setup › heart rate sensor: choose it, see its state, forget it.
struct HeartRateSection: View {
    @EnvironmentObject private var heart: HeartRateMonitor

    var body: some View {
        Section {
            if let name = heart.sensorName {
                LabeledContent("Sensor", value: name)
                LabeledContent("Status", value: statusText)
                if let battery = heart.battery { LabeledContent("Battery", value: "\(battery)%") }
                if let rssi = heart.rssi { LabeledContent("Signal", value: "\(rssi) dBm") }
                Button("Forget this sensor", role: .destructive) { heart.forget() }
            }
            Button(heart.state == .scanning ? "Looking… tap to stop" : "Find a heart-rate sensor") {
                if heart.state == .scanning { heart.stopScan() } else { heart.startScan() }
            }
            ForEach(heart.found) { item in
                Button {
                    heart.choose(item.id)
                } label: {
                    HStack {
                        Text(item.name)
                        Spacer()
                        Text("\(item.rssi) dBm").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Heart rate sensor")
        } footer: {
            Text("Any Bluetooth heart-rate sensor works: a chest strap, an armband such as the Coospo HW9, or a watch app that broadcasts. Wake it (wear it on bare skin), tap Find, and pick it. It reconnects by itself.")
        }
        .listRowBackground(glassRow)
    }

    private var statusText: String {
        switch heart.state {
        case .idle: "Not connected"
        case .scanning: "Looking…"
        case .connecting: "Connecting…"
        case .connected: heart.signal ? "Connected, \(heart.bpm ?? 0) bpm" : "Connected, waiting for a reading"
        case .reconnecting: "Reconnecting…"
        case .unavailable(let why): why
        }
    }
}
