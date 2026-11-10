import HealthKit

/// Milestone 0: checks that HealthKit survives Signulous re-signing, and that a workout
/// with treadmill-measured distance can be written from the phone.
@MainActor
final class HealthTest: ObservableObject {
    let store = HKHealthStore()
    @Published var accessStatus = "Not requested yet"
    @Published var saveStatus = ""
    @Published var deleteStatus = ""

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAccess() async {
        guard isAvailable else {
            accessStatus = "Health isn't available on this device"
            return
        }
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), HKQuantityType(.distanceWalkingRunning)]
        let read: Set<HKObjectType> = Readiness.readTypes.union([HKObjectType.workoutType(), HKQuantityType(.heartRate)])
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

    /// Deletes every workout and distance sample this iPhone app saved. Health only lets an app
    /// delete its own data, so workouts recorded by other apps aren't touched.
    func deleteTestWorkouts() async {
        let fromThisApp = HKQuery.predicateForObjects(from: HKSource.default())
        do {
            let workouts = try await deleteObjects(of: HKObjectType.workoutType(), predicate: fromThisApp)
            let samples = try await deleteObjects(of: HKQuantityType(.distanceWalkingRunning), predicate: fromThisApp)
            deleteStatus = workouts == 0 && samples == 0
                ? "Nothing to delete: no test workouts saved by this app"
                : "Deleted \(workouts) workout\(workouts == 1 ? "" : "s") and \(samples) distance sample\(samples == 1 ? "" : "s")"
        } catch {
            deleteStatus = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func deleteObjects(of type: HKObjectType, predicate: NSPredicate) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            store.deleteObjects(of: type, predicate: predicate) { _, count, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: count)
                }
            }
        }
    }
}
