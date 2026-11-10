import SwiftUI

/// Workout and treadmill-session history: weekly totals, each session with its effort and what
/// was changed during it. Swipe to delete one entry; Delete all clears the history (asks first).
struct HistoryView: View {
    @EnvironmentObject private var library: WorkoutLibrary
    @State private var confirmingDeleteAll = false

    private var entries: [HistoryEntry] { library.history.sorted { $0.date > $1.date } }

    private var thisWeek: [HistoryEntry] {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return library.history.filter { $0.date >= start }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        MetricTile(value: "\(thisWeek.count)", unit: "this week", size: 28, highlighted: true)
                        MetricTile(value: String(format: "%.1f", thisWeek.reduce(0) { $0 + $1.miles }), unit: "miles", size: 28)
                        MetricTile(value: "\(thisWeek.reduce(0) { $0 + $1.seconds } / 60)", unit: "minutes", size: 28)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if entries.isEmpty {
                    Section {
                        Text("Finished workouts and treadmill sessions show up here.")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(glassRow)
                } else {
                    Section("Sessions") {
                        ForEach(entries) { entry in
                            NavigationLink {
                                HistoryDetailView(entry: entry)
                            } label: {
                                HistoryRow(entry: entry)
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { entries[$0] }.forEach(library.deleteHistory)
                        }
                    }
                    .listRowBackground(glassRow)
                }
            }
            .sportList()
            .navigationTitle("History")
            .toolbar {
                if !entries.isEmpty {
                    Button("Delete all", role: .destructive) { confirmingDeleteAll = true }
                }
            }
            .confirmationDialog("Delete all workout history?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
                Button("Delete all \(entries.count) sessions", role: .destructive) { library.deleteAllHistory() }
            } message: {
                Text("This removes the history the coach learns from. Saved workouts and Apple Health aren't touched. It can't be undone.")
            }
            .onAppear { library.reload() }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.name).font(.headline)
                if !entry.completed {
                    Text("ended early").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                }
                Spacer()
                Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label("\(entry.seconds / 60) min", systemImage: "clock")
                Label(String(format: "%.2f mi", entry.miles), systemImage: "figure.walk")
                if let effort = entry.effort { Label("\(effort)/10", systemImage: "flame") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct HistoryDetailView: View {
    let entry: HistoryEntry
    @EnvironmentObject private var library: WorkoutLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    MetricTile(value: "\(entry.seconds / 60)", unit: "minutes", size: 28)
                    MetricTile(value: String(format: "%.2f", entry.miles), unit: "miles", size: 28)
                    MetricTile(value: entry.effort.map { "\($0)" } ?? "–", unit: "effort", size: 28)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section("Summary") {
                LabeledContent("Date", value: entry.date.formatted(date: .complete, time: .shortened))
                LabeledContent("Result", value: entry.completed ? "Completed" : "Ended early")
                if entry.plannedSeconds > 0 { LabeledContent("Planned", value: "\(entry.plannedSeconds / 60) min") }
                LabeledContent("Top speed", value: String(format: "%.1f mph", entry.maxMph))
                LabeledContent("Top incline", value: String(format: "%.1f%%", entry.maxIncline))
            }
            .listRowBackground(glassRow)
            Section("What changed") {
                if let changes = entry.deviations, !changes.isEmpty {
                    Text(Deviation.summary(changes)).font(.subheadline)
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                        HStack(alignment: .firstTextBaseline) {
                            Text(String(format: "%d:%02d", change.at / 60, change.at % 60))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)
                            VStack(alignment: .leading) {
                                Text(change.detail).font(.subheadline)
                                Text(change.stepLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Followed the plan.").foregroundStyle(.secondary)
                }
            }
            .listRowBackground(glassRow)
            Section {
                Button("Delete this session", role: .destructive) {
                    library.deleteHistory(entry)
                    dismiss()
                }
            }
            .listRowBackground(glassRow)
        }
        .sportList()
        .navigationTitle(entry.name)
    }
}
