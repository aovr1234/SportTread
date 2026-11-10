import HealthKit

/// Daily readiness from what the Apple Watch (or Oura) already records in Apple Health:
/// resting heart rate and HRV against the last 30 days, and last night's sleep. Read-only.
@MainActor
final class Readiness: ObservableObject {
    enum Level: String {
        case ready = "Ready"
        case moderate = "Moderate"
        case easy = "Take it easy"
    }

    @Published private(set) var level: Level?
    @Published private(set) var score: Int?
    @Published private(set) var details: [String] = []
    @Published private(set) var status = "Not checked yet"

    private let store = HKHealthStore()

    static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKCategoryType(.sleepAnalysis),
    ]

    /// One line for the coach's prompt, e.g. "Readiness: Take it easy (55/100): slept 5.1 h; resting HR +6 bpm".
    var coachSummary: String? {
        guard let level, let score else { return nil }
        return "Readiness today: \(level.rawValue) (\(score)/100)" + (details.isEmpty ? "" : ": " + details.joined(separator: "; "))
    }

    func refresh() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "Apple Health isn't available"
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
        } catch {
            status = "Couldn't ask for Health access: \(error.localizedDescription)"
            return
        }
        let now = Date()
        let monthAgo = now.addingTimeInterval(-30 * 86_400)
        let rhr = (try? await samples(.restingHeartRate, since: monthAgo, unit: HKUnit.count().unitDivided(by: .minute()))) ?? []
        let hrv = (try? await samples(.heartRateVariabilitySDNN, since: monthAgo, unit: .secondUnit(with: .milli))) ?? []
        let sleep = (try? await lastNightSleepHours()) ?? nil

        var points = 100
        var notes: [String] = []
        if let today = rhr.first, rhr.count >= 5 {
            let baseline = rhr.dropFirst().map(\.value).reduce(0, +) / Double(rhr.count - 1)
            let diff = today.value - baseline
            if diff >= 7 { points -= 25 } else if diff >= 4 { points -= 12 }
            notes.append(String(format: "resting HR %.0f bpm (%+.0f vs usual)", today.value, diff))
        }
        if let today = hrv.first, hrv.count >= 5 {
            let baseline = hrv.dropFirst().map(\.value).reduce(0, +) / Double(hrv.count - 1)
            let ratio = today.value / max(baseline, 1)
            if ratio < 0.7 { points -= 25 } else if ratio < 0.85 { points -= 12 }
            notes.append(String(format: "HRV %.0f ms (%.0f%% of usual)", today.value, ratio * 100))
        }
        if let hours = sleep {
            if hours < 5 { points -= 25 } else if hours < 6.5 { points -= 12 }
            notes.append(String(format: "slept %.1f h", hours))
        }
        guard !notes.isEmpty else {
            level = nil
            score = nil
            details = []
            status = "No resting heart rate, HRV or sleep data yet. Wear the watch (or Oura) overnight."
            return
        }
        score = max(0, points)
        level = points >= 80 ? .ready : points >= 60 ? .moderate : .easy
        details = notes
        status = "Updated \(now.formatted(date: .omitted, time: .shortened))"
    }

    private struct Reading {
        let value: Double
        let date: Date
    }

    /// Daily readings, newest first.
    private func samples(_ id: HKQuantityTypeIdentifier, since: Date, unit: HKUnit) async throws -> [Reading] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(id), predicate: HKQuery.predicateForSamples(withStart: since, end: nil))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 200)
        return try await descriptor.result(for: store).map { Reading(value: $0.quantity.doubleValue(for: unit), date: $0.endDate) }
    }

    /// Hours asleep since 6 pm yesterday. With several sources (watch and Oura) it takes the
    /// source with the most sleep instead of adding them up.
    private func lastNightSleepHours() async throws -> Double? {
        let start = Calendar.current.date(byAdding: .hour, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: start, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        var bySource: [String: TimeInterval] = [:]
        for sample in try await descriptor.result(for: store) where asleep.contains(sample.value) {
            bySource[sample.sourceRevision.source.bundleIdentifier, default: 0] += sample.endDate.timeIntervalSince(sample.startDate)
        }
        guard let most = bySource.values.max(), most > 0 else { return nil }
        return most / 3600
    }
}
