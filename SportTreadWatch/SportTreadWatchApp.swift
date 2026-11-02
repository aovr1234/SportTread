import HealthKit
import SwiftUI
import WatchKit

@main
struct SportTreadWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchView().environmentObject(WorkoutManager.shared)
        }
    }
}

final class WatchDelegate: NSObject, WKApplicationDelegate {
    /// Called when the iPhone app starts a workout with startWatchApp(with:).
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in WorkoutManager.shared.start(workoutConfiguration) }
    }
}
