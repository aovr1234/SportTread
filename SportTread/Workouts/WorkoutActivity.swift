import ActivityKit
import Foundation

/// Starts, updates and ends the workout's Live Activity (Lock Screen and Dynamic Island).
/// Updates are rate-limited: step, pause and finish changes go out at once; speed or incline
/// changes at most every 3 s; otherwise a refresh every 60 s. The countdown ticks on its own.
@MainActor
final class WorkoutActivity {
    typealias State = WorkoutActivityAttributes.ContentState

    private var activity: Activity<WorkoutActivityAttributes>?
    private var lastSent: State?
    private var lastSentAt = Date.distantPast

    func start(name: String, totalSeconds: Int, state: State) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: WorkoutActivityAttributes(workoutName: name, totalSeconds: totalSeconds),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil)
        lastSent = state
        lastSentAt = Date()
    }

    func update(_ state: State) {
        guard let activity else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSentAt)
        if let last = lastSent {
            let structural = last.stepLabel != state.stepLabel || last.paused != state.paused || last.finished != state.finished
            let readings = abs(last.mph - state.mph) >= 0.05 || abs(last.incline - state.incline) >= 0.25
            guard structural || (readings && elapsed >= 3) || elapsed >= 60 else { return }
        }
        lastSent = state
        lastSentAt = now
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Ends the activity; with a final state it stays on the Lock Screen for a minute.
    func end(final state: State? = nil) {
        guard let activity else { return }
        self.activity = nil
        lastSent = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        Task { await activity.end(content, dismissalPolicy: content == nil ? .immediate : .after(Date().addingTimeInterval(60))) }
    }
}
