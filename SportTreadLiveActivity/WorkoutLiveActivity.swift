import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SportTreadWidgets: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
    }
}

private let volt = Color(red: 0.776, green: 1.0, blue: 0.0)  // #C6FF00

/// Workout on the Lock Screen and in the Dynamic Island.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(volt)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Metric(value: String(format: "%.1f", state.mph), unit: "mph")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Metric(value: String(format: "%.1f%%", state.incline), unit: "incline", alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.finished ?? state.stepLabel).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        Countdown(state: state).font(.title2.weight(.heavy).monospacedDigit())
                        ProgressView(value: state.progress).tint(volt)
                    }
                }
            } compactLeading: {
                Image(systemName: state.paused ? "pause.fill" : "figure.run").foregroundStyle(volt)
            } compactTrailing: {
                Countdown(state: state)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .frame(maxWidth: 48)
            } minimal: {
                Image(systemName: state.paused ? "pause.fill" : "figure.run").foregroundStyle(volt)
            }
            .keylineTint(volt)
        }
    }
}

private struct LockScreenView: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "figure.run").foregroundStyle(volt)
                Text(attributes.workoutName).font(.headline).lineLimit(1)
                Spacer()
                if state.finished == nil {
                    Countdown(state: state).font(.title2.weight(.heavy).monospacedDigit())
                }
            }
            if let finished = state.finished {
                Text(finished).font(.title3.weight(.bold)).foregroundStyle(volt)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.paused ? "Paused" : state.stepLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(state.paused ? .orange : volt)
                    Spacer()
                    Text(String(format: "%.1f mph · %.1f%%", state.mph, state.incline))
                        .font(.subheadline.monospacedDigit())
                }
                ProgressView(value: state.progress).tint(volt)
                if let next = state.nextLabel {
                    Text("Next: \(next)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}

/// Step countdown: ticks on its own while running; frozen while paused.
private struct Countdown: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        if state.paused || state.finished != nil {
            Text(String(format: "%d:%02d", state.stepRemaining / 60, state.stepRemaining % 60))
        } else {
            Text(timerInterval: Date.now...max(Date.now, state.stepEnds), countsDown: true)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct Metric: View {
    let value: String
    let unit: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(value).font(.title3.weight(.bold).monospacedDigit())
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
