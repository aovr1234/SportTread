import HealthKit

/// Saves each finished workout and treadmill session to Apple Health (when switched on in Setup): an indoor
/// walk or run with the real times, the belt's distance, active energy, heart-rate samples and the climb.
/// Health shows the source as "Spotify" because of how Signulous signs the app.
@MainActor
final class HealthSaver: ObservableObject {
    private let store = HKHealthStore()
    private static let enabledKey = "saveToHealth"
    private static let savedKey = "savedToHealthIDs"

    @Published private(set) var enabled: Bool
    @Published private(set) var status = ""

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ on: Bool) async {
        if on, !(await requestAccess()) { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        status = on ? "Finished workouts will be saved to Apple Health." : "Not saving to Apple Health."
        dlog("Health: saving \(on ? "on" : "off")")
    }

    private func requestAccess() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "Apple Health isn't available on this device."
            return false
        }
        let share: Set<HKSampleType> = [
            HKObjectType.workoutType(), HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned), HKQuantityType(.heartRate),
        ]
        let read: Set<HKObjectType> = Readiness.readTypes.union([HKObjectType.workoutType(), HKQuantityType(.heartRate)])
        do {
            try await store.requestAuthorization(toShare: share, read: read)
        } catch {
            status = "Health access failed: \(error.localizedDescription)"
            return false
        }
        guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
            status = "Saving workouts isn't allowed. Check Settings › Health › Data Access."
            return false
        }
        return true
    }

    func save(_ entry: HistoryEntry) async {
        guard enabled, entry.seconds >= 30 else { return }
        var saved = UserDefaults.standard.stringArray(forKey: Self.savedKey) ?? []
        guard !saved.contains(entry.id.uuidString) else { return }

        let end = entry.date
        let start = end.addingTimeInterval(-Double(entry.seconds))
        let summary = entry.summary
        let config = HKWorkoutConfiguration()
        config.activityType = (summary?.avgMph ?? 0) >= 5 ? .running : .walking
        config.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        do {
            try await builder.beginCollection(at: start)
            var samples: [HKSample] = [
                HKQuantitySample(type: HKQuantityType(.distanceWalkingRunning),
                                 quantity: HKQuantity(unit: .mile(), doubleValue: entry.miles), start: start, end: end),
            ]
            if let summary {
                // The estimate includes resting energy (about 1 kcal per kg per hour); Health wants the active part
                let resting = summary.weightLb * 0.45359237 * Double(entry.seconds) / 3600
                let active = max(0, Double(summary.calories) - resting)
                if active > 0 {
                    samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                                                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: active), start: start, end: end))
                }
                let perMinute = HKUnit.count().unitDivided(by: .minute())
                for sample in summary.samples {
                    guard let bpm = sample.bpm, bpm > 0 else { continue }
                    let at = start.addingTimeInterval(Double(sample.t))
                    samples.append(HKQuantitySample(type: HKQuantityType(.heartRate),
                                                    quantity: HKQuantity(unit: perMinute, doubleValue: Double(bpm)),
                                                    start: at, end: at.addingTimeInterval(5)))
                }
            }
            try await builder.addSamples(samples)
            var metadata: [String: Any] = [
                HKMetadataKeyIndoorWorkout: true,
                HKMetadataKeyWorkoutBrandName: "Andrew's SportTread",
                HKMetadataKeyExternalUUID: entry.id.uuidString,
            ]
            if let feet = summary?.elevationFeet, feet > 0 {
                metadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: feet * 0.3048)
            }
            try await builder.addMetadata(metadata)
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            saved.append(entry.id.uuidString)
            UserDefaults.standard.set(Array(saved.suffix(300)), forKey: Self.savedKey)
            status = "Saved \"\(entry.name)\" to Apple Health at \(Date().formatted(date: .omitted, time: .shortened))."
            dlog("Health: saved \(entry.name), \(entry.seconds) s, \(String(format: "%.2f", entry.miles)) mi")
        } catch {
            status = "Saving to Health failed: \(error.localizedDescription)"
            dlog("Health: saving failed: \(error.localizedDescription)")
        }
    }
}
