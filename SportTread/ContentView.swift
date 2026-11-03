import HealthKit
import SwiftUI
import UniformTypeIdentifiers

private func info(_ key: String) -> String {
    Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
}

/// Milestone 0 test screen: one section per thing Signulous signing must not break.
struct ContentView: View {
    @EnvironmentObject private var health: HealthTest
    @EnvironmentObject private var heartRate: HeartRateMonitor
    @EnvironmentObject private var dataFolder: DataFolder
    @State private var confirmingDelete = false

    private func backUp() {
        guard let file = dataFolder.makeBackupFile() else { return }
        let shown = DocumentPicker.shared.exportCopy(
            of: file,
            onDone: { saved in dataFolder.message = "Backed up to \(saved.deletingLastPathComponent().lastPathComponent)" },
            onCancel: { dataFolder.message = "Backup cancelled" })
        if !shown { dataFolder.message = "Couldn't open Files" }
    }

    private func restoreBackup() {
        let shown = DocumentPicker.shared.importCopy(
            of: [.json],
            onPick: { file in dataFolder.restore(from: file) },
            onCancel: { dataFolder.message = "Restore cancelled" })
        if !shown { dataFolder.message = "Couldn't open Files" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("1 · Apple Health access") {
                    Button("Request Health access") { Task { await health.requestAccess() } }
                    Text(health.accessStatus).font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Source", selection: $heartRate.source) {
                        ForEach(HeartRateSource.allCases) { Text($0.label).tag($0) }
                    }
                    if heartRate.source != .off {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: "heart.fill").foregroundStyle(.red)
                                Text(heartRate.bpm.map { "\(Int($0.rounded()))" } ?? "–")
                                    .font(.system(size: 48, weight: .heavy).monospacedDigit())
                                Text("bpm").foregroundStyle(.secondary)
                                Spacer()
                                if let measured = heartRate.measuredAt {
                                    Text("measured \(Int(context.date.timeIntervalSince(measured)))s ago")
                                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text(heartRate.status).font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("2 · Heart rate (optional)")
                } footer: {
                    switch heartRate.source {
                    case .off:
                        Text("Heart rate is an add-on. Treadmill workouts work without it; heart-rate workouts need a source.")
                    case .health:
                        Text("Start an Indoor Walk or Run in Apple's Workout app on your watch. SportTread reads each reading as it syncs to Apple Health; \"measured … ago\" shows the delay.")
                    case .bluetooth:
                        Text("Uses any Bluetooth heart-rate monitor: a chest strap, or a watch app that broadcasts heart rate over Bluetooth. Turn the monitor on and keep it nearby.")
                    }
                }

                Section {
                    Button("Save test workout (0.50 mi)") { Task { await health.saveTestWorkout() } }
                    if !health.saveStatus.isEmpty {
                        Text(health.saveStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Delete test workouts", role: .destructive) { confirmingDelete = true }
                    if !health.deleteStatus.isEmpty {
                        Text(health.deleteStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("3 · Save a workout to Health")
                } footer: {
                    Text("Delete removes the test workouts this app saved. Workouts recorded by Apple's Workout app on the watch stay untouched.")
                }

                Section {
                    LabeledContent("Saved in", value: dataFolder.folderDescription)
                    Button("Save test data now") { dataFolder.saveNow() }
                    Button("Back up to Files…") { backUp() }
                    Button("Restore from backup…") { restoreBackup() }
                    if !dataFolder.message.isEmpty {
                        Text(dataFolder.message).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("4 · Data folder")
                } footer: {
                    Text(dataFolder.location == .onDevice
                         ? "iCloud Drive isn't available to the app, so data is on this iPhone and is deleted with the app. Use Back up to save a copy to iCloud Drive, and Restore after reinstalling."
                         : "The app creates its folder automatically. Data in iCloud Drive › SportTread survives deleting the app.")
                }

                Section {
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "unknown")
                    LabeledContent("Health source name", value: HKSource.default().name)
                    LabeledContent("Health source ID", value: HKSource.default().bundleIdentifier)
                    LabeledContent("Display name", value: info("CFBundleDisplayName"))
                    LabeledContent("Bundle name", value: info("CFBundleName"))
                    LabeledContent("Executable", value: info("CFBundleExecutable"))
                    LabeledContent("Version", value: "\(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))")
                    LabeledContent("Built as", value: "0.0.1 (1)")
                } header: {
                    Text("About this build")
                } footer: {
                    Text("Values as installed, after Signulous signing. \"Built as\" is the version GitHub built; if Version differs, Signulous rewrote the app's info.")
                }
            }
            .navigationTitle("Andrew's SportTread")
            .confirmationDialog("Delete all test workouts saved by this app?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await health.deleteTestWorkouts() } }
            }
        }
    }
}
