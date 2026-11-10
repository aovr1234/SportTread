import Foundation

/// Saved workouts (workouts/*.json), workout history (history.json) and the training plan
/// (plan.json) in the app's data folder.
@MainActor
final class WorkoutLibrary: ObservableObject {
    @Published private(set) var saved: [Workout] = []
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var plan: TrainingPlan?

    private let dataFolder: DataFolder
    private var files: [UUID: URL] = [:]   // saved workout → its file (ids aren't stored in the JSON)

    init(dataFolder: DataFolder) {
        self.dataFolder = dataFolder
    }

    private var workoutsDir: URL? { dataFolder.folder?.appendingPathComponent("workouts", isDirectory: true) }
    private var historyFile: URL? { dataFolder.folder?.appendingPathComponent("history.json") }
    private var planFile: URL? { dataFolder.folder?.appendingPathComponent("plan.json") }

    func reload() {
        if let dir = workoutsDir {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            var loaded: [(Workout, URL)] = []
            for url in urls where url.pathExtension == "json" {
                if let workout = try? JSONDecoder.iso.decode(Workout.self, from: Data(contentsOf: url)) {
                    loaded.append((workout, url))
                }
            }
            loaded.sort { $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending }
            saved = loaded.map(\.0)
            files = Dictionary(uniqueKeysWithValues: loaded.map { ($0.0.id, $0.1) })
        }
        if let file = historyFile, let data = try? Data(contentsOf: file),
           let entries = try? JSONDecoder.iso.decode([HistoryEntry].self, from: data) {
            history = entries
        }
        if let file = planFile, let data = try? Data(contentsOf: file) {
            plan = try? JSONDecoder.iso.decode(TrainingPlan.self, from: data)
        } else {
            plan = nil
        }
    }

    /// Overwrites a saved workout's file with an edited version.
    func update(_ original: Workout, with edited: Workout) throws {
        guard let url = files[original.id] else {
            try save(edited)
            return
        }
        try JSONEncoder.iso.encode(edited).write(to: url, options: .atomic)
        reload()
    }

    func isSaved(_ workout: Workout) -> Bool { files[workout.id] != nil }

    // MARK: History

    func deleteHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        writeHistory()
    }

    func deleteAllHistory() {
        history.removeAll()
        writeHistory()
    }

    // MARK: Plan

    func setPlan(_ newPlan: TrainingPlan?) {
        plan = newPlan
        guard let file = planFile else { return }
        if let newPlan, let data = try? JSONEncoder.iso.encode(newPlan) {
            try? data.write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func save(_ workout: Workout) throws {
        guard let dir = workoutsDir else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let slug = workout.name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let url = dir.appendingPathComponent("\(slug.isEmpty ? "workout" : slug)-\(Int(Date().timeIntervalSince1970)).json")
        try JSONEncoder.iso.encode(workout).write(to: url, options: .atomic)
        reload()
    }

    func delete(_ workout: Workout) {
        if let url = files[workout.id] { try? FileManager.default.removeItem(at: url) }
        reload()
    }

    func record(_ entry: HistoryEntry) {
        history.append(entry)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        writeHistory()
    }

    /// Effort rating (1–10) for the most recent workout.
    func rateLast(_ effort: Int) {
        guard !history.isEmpty else { return }
        history[history.count - 1].effort = effort
        writeHistory()
    }

    private func writeHistory() {
        guard let file = historyFile, let data = try? JSONEncoder.iso.encode(history) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
