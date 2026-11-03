import SwiftUI

/// Milestone 0 test screen: one section per thing Signulous signing must not break.
struct ContentView: View {
    @EnvironmentObject private var health: HealthTest
    @EnvironmentObject private var watchLink: PhoneWatchLink
    @EnvironmentObject private var dataFolder: DataFolder
    @State private var pickingFolder = false
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section("1 · Apple Health access") {
                    Button("Request Health access") { Task { await health.requestAccess() } }
                    Text(health.accessStatus).font(.footnote).foregroundStyle(.secondary)
                }

                Section("2 · Watch heart rate") {
                    Text(watchLink.state).font(.footnote).foregroundStyle(.secondary)
                    Button("Start workout on watch") { health.startWatchWorkout() }
                    if !health.watchStartStatus.isEmpty {
                        Text(health.watchStartStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "heart.fill").foregroundStyle(.red)
                            Text(watchLink.heartRate.map { "\(Int($0.rounded()))" } ?? "–")
                                .font(.system(size: 48, weight: .heavy).monospacedDigit())
                            Text("bpm").foregroundStyle(.secondary)
                            Spacer()
                            if let last = watchLink.lastUpdate {
                                Text("\(Int(context.date.timeIntervalSince(last)))s ago")
                                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
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
                    Text("Delete removes workouts saved by this iPhone app. For workouts recorded on the watch, use Discard on the watch instead of End.")
                }

                Section {
                    Button(dataFolder.folderName == nil ? "Choose folder" : "Change folder") {
                        pickingFolder = true
                    }
                    if let name = dataFolder.folderName {
                        LabeledContent("Folder", value: name)
                        Button("Save test data now") { dataFolder.saveNow() }
                    }
                    Text(dataFolder.message).font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("4 · Data folder")
                } footer: {
                    Text("Go to iCloud Drive and tap Open. The app creates a SportTread folder there. After reinstalling, do the same and your data is restored.")
                }
            }
            .navigationTitle("Andrew's SportTread")
            .sheet(isPresented: $pickingFolder) {
                FolderPicker(
                    onPick: { url in
                        pickingFolder = false
                        dataFolder.use(url)
                    },
                    onCancel: {
                        pickingFolder = false
                        dataFolder.message = "No folder picked"
                    })
                    .ignoresSafeArea()
            }
            .confirmationDialog("Delete all test workouts saved by this app?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await health.deleteTestWorkouts() } }
            }
        }
    }
}
