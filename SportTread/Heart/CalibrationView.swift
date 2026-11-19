import SwiftUI

/// Setup › Fitness test: the checklist, the 45-second resting measurement, then the test runs as a workout.
struct CalibrationView: View {
    @EnvironmentObject private var runner: WorkoutRunner
    @EnvironmentObject private var treadmill: TreadmillController
    @EnvironmentObject private var heart: HeartRateMonitor
    @EnvironmentObject private var library: WorkoutLibrary
    @State private var withIncline = false
    @State private var restingLeft: Int?
    @State private var task: Task<Void, Never>?

    private var profile: BodyProfile { BodyProfile.stored }
    private var comfortable: Double { TemplateCoach.baseSpeed(history: library.history, heightInches: profile.heightInches) }
    private var ready: Bool { heart.signal && treadmill.isReady && profile.age != nil && !runner.isActive }

    var body: some View {
        List {
            Section {
                Text("A guided walk of about 24 minutes: a warm-up, then six stages of 3 minutes at rising speed, then a cool-down. The app notes how your heart settles at each speed and works out your own heart-rate zones in mph. Walking only, no jogging.")
                    .font(.subheadline)
            }
            .listRowBackground(glassRow)

            Section("Before you start") {
                check("Heart-rate sensor connected and sending", heart.signal)
                check("Treadmill connected", treadmill.isReady)
                check("Your age is entered (Setup › About you)", profile.age != nil)
                Label("Clip on the safety key and stay near the console.", systemImage: "key.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(glassRow)

            Section {
                Toggle("Add the incline part (about 9 more minutes)", isOn: $withIncline)
                let stages = CalibrationPlan.levels(comfortable: comfortable, withIncline: withIncline)
                Text("Stages: " + stages.map { $0.incline > 0 ? String(format: "%.1f mph at %g%%", $0.mph, $0.incline) : String(format: "%.1f", $0.mph) }.joined(separator: ", ") + " mph")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("The test stops and cools down by itself if your heart rate reaches 92% of your estimated maximum, and pauses if the sensor loses signal. You can end it at any time.")
            }
            .listRowBackground(glassRow)

            Section {
                if let left = restingLeft {
                    VStack(spacing: 8) {
                        Text("Stand still on the belt").font(.headline)
                        Text("Don't hold the rails. Measuring your resting heart rate…").font(.footnote).foregroundStyle(.secondary)
                        Text("\(left) s").font(.system(size: 40, weight: .heavy, design: .rounded).monospacedDigit())
                        HeartChip().font(.title3)
                    }
                    .frame(maxWidth: .infinity)
                    Button("Cancel", role: .cancel) {
                        task?.cancel()
                        restingLeft = nil
                    }
                } else {
                    Button { begin() } label: {
                        Label("Begin the test", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .disabled(!ready)
                }
            }
            .listRowBackground(glassRow)

            if let model = FitnessModel.latest {
                Section("Last test, \(model.date.formatted(date: .abbreviated, time: .omitted))") {
                    CalibrationResultCard(model: model, note: nil)
                        .listRowInsets(EdgeInsets())
                }
                .listRowBackground(Color.clear)
            }
        }
        .sportList()
        .navigationTitle("Fitness test")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func check(_ text: String, _ ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle")
            .font(.subheadline)
            .foregroundStyle(ok ? Theme.lime : Color.secondary)
    }

    /// 45 s standing still (the middle reading is the resting rate), then the test starts as a workout.
    private func begin() {
        task = Task { @MainActor in
            var readings: [Int] = []
            for second in stride(from: 45, through: 1, by: -1) {
                restingLeft = second
                if let reading = heart.currentReading() { readings.append(reading.bpm) }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled {
                    restingLeft = nil
                    return
                }
            }
            restingLeft = nil
            let resting = readings.sorted().isEmpty ? nil : readings.sorted()[readings.count / 2]
            runner.startCalibration(comfortable: comfortable, withIncline: withIncline, restingBpm: resting)
        }
    }
}

/// The result of a fitness test: how well it fitted, and the zones as heart rate and speed.
struct CalibrationResultCard: View {
    let model: FitnessModel
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.isNoisy ? "The readings were noisy: repeat the test" : "Your heart-rate zones")
                .font(.headline)
                .foregroundStyle(model.isNoisy ? Color.orange : Theme.lime)
            Text(summaryLine).font(.caption).foregroundStyle(.secondary)
            if let max = model.maxBpm {
                let zones = HeartZones(maxBpm: max, restingBpm: model.restingBpm)
                ForEach(1...5, id: \.self) { zone in
                    let range = zones.range(zone)
                    HStack {
                        Text("Zone \(zone)").font(.subheadline.weight(.bold)).frame(width: 64, alignment: .leading)
                        Text("\(Int(range.lowerBound.rounded()))–\(Int(range.upperBound.rounded())) bpm").font(.subheadline.monospacedDigit())
                        Spacer()
                        Text(speedText(range)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Add your age in Setup to see the zones.").font(.footnote).foregroundStyle(.orange)
            }
            if !model.unsettled.isEmpty {
                Text("Stage\(model.unsettled.count > 1 ? "s" : "") \(model.unsettled.map(String.init).joined(separator: ", ")) still rising: those numbers are a little low.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.orange) }
        }
        .padding(14)
        .glassCard()
    }

    private var summaryLine: String {
        var parts: [String] = []
        if let resting = model.restingBpm { parts.append("resting \(resting) bpm") }
        if let max = model.maxBpm { parts.append("maximum \(max) bpm") }
        parts.append(String(format: "about %.0f bpm per mph", model.perMph))
        if model.perIncline > 0.5 { parts.append(String(format: "%.1f bpm per 1%% incline", model.perIncline)) }
        parts.append(String(format: "fit %.0f%%", model.r2 * 100))
        return parts.joined(separator: " · ")
    }

    private func speedText(_ range: ClosedRange<Double>) -> String {
        guard let low = model.mph(forBpm: range.lowerBound), let high = model.mph(forBpm: range.upperBound) else { return "" }
        let lo = max(low, 0.5)
        let hi = max(high, 0.5)
        if hi > 10 { return String(format: "%.1f+ mph", lo) }
        return String(format: "%.1f–%.1f mph", lo, hi)
    }
}

/// The Setup entry for the fitness test.
struct FitnessTestSection: View {
    var body: some View {
        Section {
            NavigationLink {
                CalibrationView()
            } label: {
                Label("Fitness test", systemImage: "waveform.path.ecg")
            }
            if let model = FitnessModel.latest {
                Text("Last test \(model.date.formatted(date: .abbreviated, time: .omitted)): about \(Int(model.perMph.rounded())) bpm per mph\(model.isNoisy ? " (noisy)" : "")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("A 24-minute guided walk that learns how your heart responds, so zones and targets are in your own mph.")
        }
        .listRowBackground(glassRow)
    }
}
