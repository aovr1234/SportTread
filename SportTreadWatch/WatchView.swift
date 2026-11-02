import SwiftUI

struct WatchView: View {
    @EnvironmentObject private var workout: WorkoutManager

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "heart.fill").foregroundStyle(.red)
                Text(workout.heartRate > 0 ? "\(Int(workout.heartRate.rounded()))" : "–")
                    .font(.system(size: 44, weight: .heavy).monospacedDigit())
            }
            Text(workout.status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if workout.running {
                Button("End", role: .destructive) { workout.end() }
            } else {
                Button("Start") { workout.start() }
                    .tint(Color(red: 0.776, green: 1.0, blue: 0.0))
            }
        }
    }
}
