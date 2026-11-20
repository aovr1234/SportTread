import HealthKit
import SwiftUI
import UniformTypeIdentifiers

private func info(_ key: String) -> String {
    Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
}

/// Setup tab: Health access, the data folder and build info (the milestone 0 checks).
struct ContentView: View {
    @EnvironmentObject private var health: HealthTest
    @EnvironmentObject private var dataFolder: DataFolder
    @ObservedObject private var liveActivity = LiveActivityStatus.shared
    @State private var confirmingDelete = false
    @State private var testActivity = WorkoutActivity()
    @AppStorage(WorkoutSummary.weightKey) private var weightLb = WorkoutSummary.defaultWeightLb
    @AppStorage(WorkoutSummary.showCaloriesKey) private var showCalories = true
    @ObservedObject private var diagnostics = DiagnosticsLog.shared
    @EnvironmentObject private var healthSaver: HealthSaver
    @AppStorage(BodyProfile.heightKey) private var heightInches = 0.0
    @AppStorage(BodyProfile.ageKey) private var age = 0
    @AppStorage(BodyProfile.measuredMaxKey) private var measuredMax = 0
    @AppStorage(BodyProfile.easyWalkKey) private var easyWalk = 0.0
    @AppStorage(BodyProfile.fastWalkKey) private var fastWalk = 0.0
    @AppStorage(BodyProfile.jogStartKey) private var jogStart = 0.0
    @AppStorage(BodyProfile.manualRestingKey) private var manualResting = 0
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var aboutStatus = ""

    /// Your own speed scale: a stepper that starts from a sensible value the first time it is touched.
    private func speedRow(_ title: String, value: Binding<Double>, fallback: Double) -> some View {
        LabeledContent(title) {
            HStack {
                Text(value.wrappedValue < 1 ? "not set" : String(format: "%.1f mph", value.wrappedValue)).monospacedDigit()
                Stepper(title, value: Binding(get: { value.wrappedValue < 1 ? fallback : value.wrappedValue },
                                              set: { value.wrappedValue = ($0 * 10).rounded() / 10 }),
                        in: 1.5...8, step: 0.1)
                    .labelsHidden()
            }
        }
    }

    /// The resting heart rate the zones use, and where it comes from.
    private var restingText: String {
        let defaults = UserDefaults.standard
        for (key, source) in [(BodyProfile.manualRestingKey, "typed"), (BodyProfile.restingKey, "fitness test"), (BodyProfile.healthRestingKey, "Apple Health")] {
            let bpm = defaults.integer(forKey: key)
            if bpm >= 30 { return "\(bpm) (\(source))" }
        }
        return "unknown"
    }

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
                if lowPower {
                    Section {
                        Label("Low Power Mode is on. iOS then limits Bluetooth in the background, so the treadmill link can drop when the app isn't in front.",
                              systemImage: "bolt.slash.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    .listRowBackground(glassRow)
                }
                Section {
                    Toggle("Show calories", isOn: $showCalories)
                    if showCalories {
                        Stepper("\(Int(weightLb)) lb", value: $weightLb, in: 80...400, step: 1)
                    }
                } header: {
                    Text("Calories")
                } footer: {
                    Text(showCalories
                         ? "An estimate from speed, incline and your weight (usually within about 15%). Turn it off if you'd rather use Apple Fitness on your watch."
                         : "Calories are hidden everywhere. The numbers are still saved with each session, so turning this back on shows them.")
                }

                Section {
                    LabeledContent("Height") {
                        HStack {
                            Text(heightInches < 40 ? "not set" : "\(Int(heightInches.rounded()) / 12)' \(Int(heightInches.rounded()) % 12)\"")
                                .monospacedDigit()
                            Stepper("Height", value: Binding(get: { heightInches < 40 ? 68 : heightInches }, set: { heightInches = $0 }),
                                    in: 48...84, step: 1)
                                .labelsHidden()
                        }
                    }
                    LabeledContent("Age") {
                        HStack {
                            Text(age < 10 ? "not set" : "\(age)").monospacedDigit()
                            Stepper("Age", value: Binding(get: { age < 10 ? 35 : age }, set: { age = $0 }), in: 14...90)
                                .labelsHidden()
                        }
                    }
                    LabeledContent("Maximum heart rate") {
                        HStack {
                            Text(BodyProfile.stored.maxHeartRate.map { "\($0)\(measuredMax >= 120 ? " (measured)" : "")" } ?? "needs your age")
                                .monospacedDigit()
                            Stepper("Maximum heart rate", value: Binding(get: { measuredMax < 120 ? 185 : measuredMax }, set: { measuredMax = $0 }),
                                    in: 120...230)
                                .labelsHidden()
                        }
                    }
                    if measuredMax >= 120 {
                        Button("Use the formula for my age instead") { measuredMax = 0 }
                    }
                    LabeledContent("Resting heart rate") {
                        HStack {
                            Text(restingText).monospacedDigit()
                            Stepper("Resting heart rate", value: Binding(get: { manualResting < 30 ? 62 : manualResting }, set: { manualResting = $0 }), in: 30...100)
                                .labelsHidden()
                        }
                    }
                    if manualResting >= 30 {
                        Button("Use the fitness test or Apple Health instead") { manualResting = 0 }
                    }
                    speedRow("Easy walk", value: $easyWalk, fallback: 2.5)
                    speedRow("Fast walk", value: $fastWalk, fallback: 3.0)
                    speedRow("Jogging starts at", value: $jogStart, fallback: 4.0)
                    Button("Fill weight, height and age from Apple Health") {
                        Task { aboutStatus = await healthSaver.readBody() }
                    }
                    if !aboutStatus.isEmpty {
                        Text(aboutStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About you")
                } footer: {
                    Text("Height sets where a new user's comfortable speed starts. Age gives your maximum heart rate (208 minus 0.7 times your age, unless you enter a measured one) and the five zones. Weight is under Calories.")
                }
                .listRowBackground(glassRow)

                HeartRateSection()

                FitnessTestSection()

                Section {
                    Toggle("Save workouts to Apple Health", isOn: Binding(
                        get: { healthSaver.enabled },
                        set: { on in Task { await healthSaver.setEnabled(on) } }))
                    if !healthSaver.status.isEmpty {
                        Text(healthSaver.status).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Each finished workout and treadmill session is saved as an indoor walk or run: the real times, distance, active calories, your heart rate and the climb. Health shows the source as \"Spotify\" because of how the app is signed.")
                }

                Section {
                    NavigationLink {
                        CloudSettingsView()
                    } label: {
                        Label("Cloud AI for workouts", systemImage: "cloud")
                    }
                } footer: {
                    Text("Groq, Gemini and others (free keys) make better workouts than the phone alone. Off until you turn it on.")
                }

                Section {
                    if diagnostics.recent.isEmpty {
                        Text("Nothing logged yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(diagnostics.recent.suffix(12).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    ShareLink(item: diagnostics.fileURL) {
                        Label("Share log", systemImage: "square.and.arrow.up")
                    }
                    Button("Clear log", role: .destructive) { diagnostics.clear() }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Connections, commands, workout steps and why iOS closed the app (iOS reports that once a day). Stays on this iPhone unless you share it. Also in Files › SportTread › diagnostics.log.")
                }

                Section {
                    LabeledContent("Allowed", value: liveActivity.enabled ? "Yes" : "No (Settings › SportTread)")
                    LabeledContent("Extension", value: liveActivity.extensions.isEmpty
                                   ? "Missing (removed during signing)"
                                   : liveActivity.extensions.joined(separator: ", "))
                    Button("Test Live Activity (1 min)") { testActivity.startTest() }
                    Text("Last request: \(liveActivity.lastResult)").font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Live Activities")
                } footer: {
                    Text("After tapping Test, lock the phone: a test activity should show on the Lock Screen for a minute.")
                }

                Section("1 · Apple Health access") {
                    Button("Request Health access") { Task { await health.requestAccess() } }
                    Text(health.accessStatus).font(.footnote).foregroundStyle(.secondary)
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
                    Text("2 · Save a workout to Health")
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
                    Text("3 · Data folder")
                } footer: {
                    Text(dataFolder.location == .onDevice
                         ? "iCloud Drive isn't available to the app, so data is on this iPhone and is deleted with the app. Use Back up to save a copy to iCloud Drive, and Restore after reinstalling."
                         : "The app creates its folder automatically. Data in iCloud Drive › SportTread survives deleting the app.")
                }

                Section {
                    LabeledContent("Apple Intelligence", value: Coach.appleIntelligenceStatus)
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "unknown")
                    LabeledContent("Health source name", value: HKSource.default().name)
                    LabeledContent("Health source ID", value: HKSource.default().bundleIdentifier)
                    LabeledContent("Display name", value: info("CFBundleDisplayName"))
                    LabeledContent("Bundle name", value: info("CFBundleName"))
                    LabeledContent("Executable", value: info("CFBundleExecutable"))
                    LabeledContent("Version", value: "\(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))")
                } header: {
                    Text("About this build")
                } footer: {
                    Text("Values as installed, after Signulous signing.")
                }
            }
            .listRowBackground(glassRow)
            .sportList()
            .navigationTitle("Setup")
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .confirmationDialog("Delete all test workouts saved by this app?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await health.deleteTestWorkouts() } }
            }
        }
    }
}
