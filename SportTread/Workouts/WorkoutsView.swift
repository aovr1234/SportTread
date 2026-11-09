import Charts
import SwiftUI

/// Workout list and detail. Starting a workout opens the live screen (WorkoutLiveView).
struct WorkoutsView: View {
    var body: some View {
        NavigationStack {
            List(Workout.builtIn) { workout in
                NavigationLink(value: workout) {
                    WorkoutRow(workout: workout)
                }
            }
            .navigationTitle("Workouts")
            .navigationDestination(for: Workout.self) { WorkoutDetailView(workout: $0) }
        }
    }
}

private struct WorkoutRow: View {
    let workout: Workout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(workout.name).font(.headline)
                Spacer()
                Text(durationText(workout.totalSeconds)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(workout.summary).font(.subheadline).foregroundStyle(.secondary)
            WorkoutProfile(workout: workout, height: 36, showAxes: false)
        }
        .padding(.vertical, 4)
    }
}

struct WorkoutDetailView: View {
    let workout: Workout
    @EnvironmentObject private var treadmill: TreadmillController
    @EnvironmentObject private var runner: WorkoutRunner

    var body: some View {
        List {
            Section {
                Text(workout.summary).foregroundStyle(.secondary)
                HStack {
                    stat(durationText(workout.totalSeconds), "time")
                    stat(String(format: "%.1f", workout.maxMph), "max mph")
                    stat(String(format: "%.0f%%", workout.maxIncline), "max incline")
                }
                WorkoutProfile(workout: workout, height: 140, showAxes: true)
                    .padding(.vertical, 6)
            }
            Section("Steps") {
                ForEach(workout.steps) { step in
                    HStack {
                        Text(step.label)
                        Spacer()
                        Text("\(durationText(step.seconds)) · \(String(format: "%.1f", step.mph)) mph · \(String(format: "%g", step.incline))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(workout.name)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Button {
                    runner.start(workout)
                } label: {
                    Label("Start workout", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.volt)
                .foregroundStyle(.black)
                .disabled(!treadmill.isReady || runner.isActive)
                if !treadmill.isReady {
                    Text("Connect on the Treadmill tab first").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.bar)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title3.weight(.bold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Speed profile: one bar per step (height = speed, brightness = incline). Optionally highlights a step.
struct WorkoutProfile: View {
    let workout: Workout
    var height: CGFloat
    var showAxes: Bool
    var highlight: Int?

    private struct Segment: Identifiable {
        let id: Int
        let start: Double
        let end: Double
        let mph: Double
        let incline: Double
    }

    private var segments: [Segment] {
        var start = 0.0
        return workout.steps.enumerated().map { i, step in
            let minutes = Double(step.seconds) / 60
            defer { start += minutes }
            return Segment(id: i, start: start, end: start + minutes, mph: step.mph, incline: step.incline)
        }
    }

    var body: some View {
        Chart(segments) { segment in
            RectangleMark(
                xStart: .value("Start", segment.start),
                xEnd: .value("End", segment.end),
                yStart: .value("Base", 0),
                yEnd: .value("mph", segment.mph))
                .foregroundStyle(color(for: segment))
        }
        .chartYScale(domain: 0...max(4, workout.maxMph + 0.5))
        .chartXAxis(showAxes ? .automatic : .hidden)
        .chartYAxis(showAxes ? .automatic : .hidden)
        .chartXAxisLabel(showAxes ? "minutes" : "")
        .frame(height: height)
    }

    private func color(for segment: Segment) -> Color {
        if let highlight {
            return segment.id == highlight ? Theme.volt : Color.gray.opacity(0.35)
        }
        return Theme.volt.opacity(0.35 + 0.065 * segment.incline)
    }
}

func durationText(_ seconds: Int) -> String {
    seconds % 60 == 0 ? "\(seconds / 60) min" : String(format: "%d:%02d", seconds / 60, seconds % 60)
}
