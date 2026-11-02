import HealthKit
import WatchConnectivity

/// Runs an indoor workout session for live heart rate and forwards each reading to the iPhone.
@MainActor
final class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()

    let store = HKHealthStore()
    @Published var heartRate: Double = 0
    @Published var running = false
    @Published var status = "Ready"

    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func start(_ configuration: HKWorkoutConfiguration? = nil) {
        guard session == nil else { return }
        let config = configuration ?? {
            let c = HKWorkoutConfiguration()
            c.activityType = .walking
            c.locationType = .indoor
            return c
        }()
        Task {
            do {
                try await store.requestAuthorization(
                    toShare: [HKObjectType.workoutType()],
                    read: [HKQuantityType(.heartRate)])
                let session = try HKWorkoutSession(healthStore: store, configuration: config)
                let builder = session.associatedWorkoutBuilder()
                builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
                session.delegate = self
                builder.delegate = self
                self.session = session
                self.builder = builder
                let now = Date()
                session.startActivity(with: now)
                try await builder.beginCollection(at: now)
                running = true
                status = "Workout running"
            } catch {
                status = "Start failed: \(error.localizedDescription)"
                session = nil
                builder = nil
            }
        }
    }

    func end() {
        guard let session, let builder else { return }
        session.end()
        Task {
            do {
                try await builder.endCollection(at: Date())
                _ = try await builder.finishWorkout()
                status = "Saved to Health"
            } catch {
                status = "Save failed: \(error.localizedDescription)"
            }
            self.session = nil
            self.builder = nil
            running = false
        }
    }

    private func send(_ bpm: Double) {
        let wc = WCSession.default
        guard wc.activationState == .activated else { return }
        let payload: [String: Any] = ["hr": bpm, "t": Date().timeIntervalSince1970]
        if wc.isReachable {
            wc.sendMessage(payload, replyHandler: nil)
        } else {
            try? wc.updateApplicationContext(payload)
        }
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.status = "Session error: \(error.localizedDescription)" }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType),
              let quantity = workoutBuilder.statistics(for: hrType)?.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        Task { @MainActor in
            self.heartRate = bpm
            self.send(bpm)
        }
    }
}

extension WorkoutManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}
}
