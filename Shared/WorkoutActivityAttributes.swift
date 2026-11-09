import ActivityKit
import Foundation

/// Live Activity data, shared by the app (which starts and updates it) and the widget extension
/// (which draws the Lock Screen and Dynamic Island).
struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var stepLabel: String
        /// When the current step ends; the countdown runs on its own between updates
        var stepEnds: Date
        /// Seconds left in the step, shown frozen while paused
        var stepRemaining: Int
        var mph: Double
        var incline: Double
        var progress: Double
        var paused: Bool
        var nextLabel: String?
        /// Set when the workout is over, e.g. "Workout complete"
        var finished: String?
    }

    var workoutName: String
    var totalSeconds: Int
}
