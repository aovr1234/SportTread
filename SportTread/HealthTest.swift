import HealthKit

/// Milestone 0: checks that HealthKit survives Signulous re-signing, and that a workout
/// with treadmill-measured distance can be written from the phone.
@MainActor
final class HealthTest: ObservableObject {
    let store = HKHealthStore()
    @Published var accessStatus = "Not requested yet"
    @Published var watchStartStatus = ""
    @Published var saveStatus = ""

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAccess() async {
        guard isAvailable else {
            accessStatus = "Health isn't available on this device"
            return
        }
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), HKQuantityType(.distanceWalkingRunning)]
        let read: Set<HKObjectType> = [HKObjectType.workoutType(), HKQuantityType(.heartRate)]
        do {
            try await store.requestAuthorization(toShare: share, read: read)
            let write = store.authorizationStatus(for: HKObjectType.workoutType())
            accessStatus = write == .sharingAuthorized
                ? "Granted: can save workouts"
                : "Asked, but saving workouts isn't allowed. Check Settings › Health › Data Access."
        } catch {
            accessStatus = "Failed: \(error.localizedDescription)"
        }
    }

    /// Launches the watch app straight into a workout session.
    func startWatchWorkout() {
        let config = HKWorkoutConfiguration()
        config.activityType = .walking
        config.locationType = .indoor
        watchStartStatus = "Asking the watch…"
        store.startWatchApp(with: config) { ok, error in
            Task { @MainActor in
                self.watchStartStatus = ok
                    ? "Watch workout started"
                    : "Couldn't start the watch: \(error?.localizedDescription ?? "unknown error")"
            }
        }
    }

    /// Saves a 10-minute indoor walk ending now, with 0.50 mi of treadmill distance.
    func saveTestWorkout() async {
        let config = HKWorkoutConfiguration()
        config.activityType = .walking
        config.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        let end = Date()
        let start = end.addingTimeInterval(-600)
        do {
            try await builder.beginCollection(at: start)
            let distance = HKQuantitySample(
                type: HKQuantityType(.distanceWalkingRunning),
                quantity: HKQuantity(unit: .mile(), doubleValue: 0.5),
                start: start, end: end)
            try await builder.addSamples([distance])
            try await builder.addMetadata([
                HKMetadataKeyIndoorWorkout: true,
                HKMetadataKeyWorkoutBrandName: "Andrew's SportTread (test)",
            ])
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            saveStatus = "Saved a 10-min indoor walk with 0.50 mi at \(end.formatted(date: .omitted, time: .shortened)). Check the Fitness app."
        } catch {
            saveStatus = "Failed: \(error.localizedDescription)"
        }
    }
}
