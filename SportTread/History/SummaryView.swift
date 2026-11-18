import Charts
import SwiftUI

/// The finished-workout numbers: distance as the hero, six tiles, a speed and incline chart, and how
/// this session compares with the last similar one. Used on the finished screen (compact, no scrolling)
/// and at the top of a History entry.
struct SummaryBlock: View {
    let entry: HistoryEntry
    /// Every other history entry, for "compared with last time" and personal bests
    let others: [HistoryEntry]
    var compact = true
    @AppStorage(WorkoutSummary.showCaloriesKey) private var showCalories = true

    private var summary: WorkoutSummary? { entry.summary }

    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            hero
            if let summary {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    cell(clock(entry.seconds), "time")
                    cell(String(format: "%.1f", summary.avgMph), "avg mph")
                    cell(WorkoutSummary.paceText(summary.paceSeconds), "min / mile")
                    cell(String(format: "%.0f", summary.elevationFeet), "ft climbed")
                    if showCalories {
                        cell("~\(summary.calories)", "kcal (est.)")
                    } else {
                        cell(String(format: "%.1f", summary.topMph), "top mph")
                    }
                    cell(String(format: "%.1f%%", summary.avgIncline), "avg incline")
                }
                if summary.samples.count >= 3 { charts(summary) }
                comparison
            } else {
                HStack(spacing: 8) {
                    cell(clock(entry.seconds), "time")
                    cell(String(format: "%.1f", entry.maxMph), "top mph")
                    cell(String(format: "%.1f%%", entry.maxIncline), "top incline")
                }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            Text(String(format: "%.2f", entry.miles))
                .font(.system(size: compact ? 56 : 64, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.accent)
            Text("MILES").font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
        }
    }

    private func cell(_ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .padding(.vertical, 4)
        .glassCard(cornerRadius: 16)
    }

    private func charts(_ summary: WorkoutSummary) -> some View {
        VStack(spacing: 4) {
            Chart(summary.samples, id: \.self) { sample in
                LineMark(x: .value("Minutes", Double(sample.t) / 60), y: .value("mph", sample.mph))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.lime)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(4, (summary.topMph * 1.15).rounded(.up)))
            .frame(height: compact ? 44 : 70)
            Chart(summary.samples, id: \.self) { sample in
                AreaMark(x: .value("Minutes", Double(sample.t) / 60), y: .value("Incline", sample.incline))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.cyan.opacity(0.7))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(4, (summary.topIncline * 1.15).rounded(.up)))
            .frame(height: compact ? 30 : 50)
            HStack {
                Text("Speed").foregroundStyle(Theme.lime)
                Text("Incline").foregroundStyle(Theme.cyan)
                Spacer()
                Text(String(format: "top %.1f mph · %.1f%%", summary.topMph, summary.topIncline)).foregroundStyle(.secondary)
            }
            .font(.caption2.weight(.semibold))
        }
        .padding(10)
        .glassCard(cornerRadius: 16)
    }

    // MARK: Compared with last time

    /// The most recent earlier session with the same name.
    private var previous: HistoryEntry? {
        others.filter { $0.name == entry.name && $0.date < entry.date && $0.summary != nil }
            .max { $0.date < $1.date }
    }

    private var badges: [String] {
        let rivals = others.filter { $0.date != entry.date }
        guard !rivals.isEmpty, entry.seconds > 0 else { return [] }
        var result: [String] = []
        if entry.seconds > (rivals.map(\.seconds).max() ?? 0) { result.append("Longest session") }
        if entry.miles > (rivals.map(\.miles).max() ?? 0) { result.append("Farthest") }
        if let mine = entry.summary?.avgMph, mine > (rivals.compactMap { $0.summary?.avgMph }.max() ?? .infinity) {
            result.append("Fastest average")
        }
        return result
    }

    @ViewBuilder
    private var comparison: some View {
        if previous != nil || !badges.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let previous, let now = entry.summary, let before = previous.summary {
                    let miles = entry.miles - previous.miles
                    let speed = now.avgMph - before.avgMph
                    let seconds = entry.seconds - previous.seconds
                    Label("Last time: \(signed(miles, "%.2f")) mi, \(signed(speed, "%.1f")) mph average, \(signedTime(seconds))",
                          systemImage: "arrow.left.arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !badges.isEmpty {
                    Label(badges.joined(separator: " · "), systemImage: "trophy.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.lime)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func signed(_ value: Double, _ format: String) -> String {
        (value >= 0 ? "+" : "−") + String(format: format, abs(value))
    }

    private func signedTime(_ seconds: Int) -> String {
        (seconds >= 0 ? "+" : "−") + clock(abs(seconds))
    }

    private func clock(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Treadmill-mode session summary, shown as a sheet on the Treadmill tab after End workout.
struct SessionSummarySheet: View {
    let entry: HistoryEntry
    @EnvironmentObject private var library: WorkoutLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("Session saved").font(.title2.weight(.heavy))
            SummaryBlock(entry: entry, others: library.history.filter { $0.id != entry.id })
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .buttonStyle(SportButtonStyle(kind: .go))
        }
        .padding()
        .background(AppBackground())
        .presentationDetents([.large])
    }
}
