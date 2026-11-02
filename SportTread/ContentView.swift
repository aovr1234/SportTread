import SwiftUI

/// Milestone 0 test screen: one section per thing Signulous signing must not break.
struct ContentView: View {
    @EnvironmentObject private var health: HealthTest
    @EnvironmentObject private var watchLink: PhoneWatchLink
    @EnvironmentObject private var dataFolder: DataFolder
    @State private var pickingFolder = false

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

                Section("3 · Save a workout to Health") {
                    Button("Save test workout (0.50 mi)") { Task { await health.saveTestWorkout() } }
                    if !health.saveStatus.isEmpty {
                        Text(health.saveStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(dataFolder.folderName == nil ? "Choose or create folder" : "Change folder") {
                        pickingFolder = true
                    }
                    if dataFolder.folderName != nil {
                        Button("Save test data now") { dataFolder.saveNow() }
                    }
                    Text(dataFolder.message).font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("4 · Data folder")
                } footer: {
                    Text("Pick iCloud Drive, tap New Folder, name it Treadmill, then open it. After deleting and reinstalling the app, pick the same folder to restore.")
                }
            }
            .navigationTitle("Andrew's SportTread")
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { dataFolder.use(url) }
            }
        }
    }
}
