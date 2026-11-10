import ActivityKit
import Foundation

/// What happened the last time the app asked iOS for a Live Activity, shown in Setup.
@MainActor
final class LiveActivityStatus: ObservableObject {
    static let shared = LiveActivityStatus()

    @Published var lastResult = "Not requested yet"

    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// App extensions that survived signing (the Live Activity needs SportTreadLiveActivity.appex).
    var extensions: [String] {
        guard let url = Bundle.main.builtInPlugInsURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.filter { $0.hasSuffix(".appex") }.sorted()
    }
}

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
        let status = LiveActivityStatus.shared
        guard status.enabled else {
            status.lastResult = "Live Activities are turned off for SportTread (Settings › SportTread)"
            return
        }
        do {
            let started = try Activity.request(
                attributes: WorkoutActivityAttributes(workoutName: name, totalSeconds: totalSeconds),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            activity = started
            lastSent = state
            lastSentAt = Date()
            status.lastResult = "Started \(Date().formatted(date: .omitted, time: .shortened)) (\(String(describing: started.activityState)))"
        } catch {
            status.lastResult = "iOS refused: \(error.localizedDescription) [\(String(describing: error))]"
        }
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

    var isActive: Bool { activity != nil }

    /// One-minute demo for Setup, no treadmill needed.
    func startTest() {
        let ends = Date().addingTimeInterval(60)
        start(name: "Live Activity test", totalSeconds: 60, state: State(
            stepLabel: "Test step", stepEnds: ends, stepRemaining: 60, mph: 3.0, incline: 2.0,
            progress: 0.3, paused: false, nextLabel: "Cool-down", finished: nil))
        Task {
            try? await Task.sleep(for: .seconds(60))
            end()
        }
    }
}

/// Live Activity for treadmill mode (manual use): speed, incline, moving time, distance.
/// Same rate limits as the workout one.
@MainActor
final class TreadmillActivity {
    typealias State = TreadmillActivityAttributes.ContentState

    private var activity: Activity<TreadmillActivityAttributes>?
    private var lastSent: State?
    private var lastSentAt = Date.distantPast

    var isActive: Bool { activity != nil }

    func start(_ state: State) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: TreadmillActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            lastSent = state
            lastSentAt = Date()
        } catch {
            LiveActivityStatus.shared.lastResult = "Treadmill activity refused: \(error.localizedDescription)"
        }
    }

    func update(_ state: State) {
        guard let activity else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSentAt)
        if let last = lastSent {
            let structural = last.stopped != state.stopped || last.summary != state.summary
            let readings = abs(last.mph - state.mph) >= 0.05 || abs(last.incline - state.incline) >= 0.25
            guard structural || (readings && elapsed >= 3) || elapsed >= 60 else { return }
        }
        lastSent = state
        lastSentAt = now
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Ends it; with a final state it stays on the Lock Screen for a minute.
    func end(final state: State? = nil) {
        guard let activity else { return }
        self.activity = nil
        lastSent = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        Task { await activity.end(content, dismissalPolicy: content == nil ? .immediate : .after(Date().addingTimeInterval(60))) }
    }
}
