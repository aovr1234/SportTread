import Foundation

/// A simple multi-week plan: N workouts a week for M weeks, progressing week by week.
/// The schedule is rule-based; each session is turned into a workout by the coach when the user
/// taps "Create this workout" (Apple Intelligence when available).
struct TrainingPlan: Codable, Equatable {
    enum Goal: String, Codable, CaseIterable, Identifiable {
        case fitter = "Get fitter"
        case endurance = "Build endurance"
        case weight = "Burn calories"
        case fiveK = "Walk-jog a 5K"

        var id: String { rawValue }

        /// Workout types rotated through each week
        var rotation: [WorkoutRequest.Kind] {
            switch self {
            case .fitter: [.walk, .hills, .intervals]
            case .endurance: [.walk, .intervals, .walk]
            case .weight: [.walk, .hills, .walk]
            case .fiveK: [.intervals, .walk, .jog]
            }
        }
    }

    var goal: Goal
    var weeks: Int
    var perWeek: Int
    var minutes: Int
    var start: Date

    /// Week of the plan (1-based) for a date; nil before the start or after the end.
    func week(at date: Date = Date()) -> Int? {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: start),
                                                   to: Calendar.current.startOfDay(for: date)).day ?? 0
        let week = days / 7 + 1
        return (1...weeks).contains(week) ? week : nil
    }

    func weekStart(_ week: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: (week - 1) * 7, to: Calendar.current.startOfDay(for: start)) ?? start
    }

    /// Workouts done in a plan week (from history; treadmill sessions under 10 min don't count).
    func done(in week: Int, history: [HistoryEntry]) -> Int {
        let from = weekStart(week)
        let to = weekStart(week + 1)
        return history.filter { $0.date >= from && $0.date < to && $0.seconds >= 600 }.count
    }

    /// The next session's request, progressing through the plan: easy first weeks, a lighter
    /// week every 4th week, harder in the last third, and a little longer each week.
    func nextRequest(week: Int, doneThisWeek: Int) -> WorkoutRequest {
        var request = WorkoutRequest()
        request.kind = goal.rotation[doneThisWeek % goal.rotation.count]
        if goal == .fiveK && week <= weeks / 3 && request.kind == .jog { request.kind = .intervals }
        let lastThird = week > weeks * 2 / 3
        if week <= 2 || week % 4 == 0 {
            request.intensity = .easy
        } else {
            request.intensity = lastThird ? .hard : .moderate
        }
        let growth = week % 4 == 0 ? 0 : min(20, (week - 1) * 2)
        request.minutes = min(90, minutes + growth)
        request.notes = "Part of a \(weeks)-week plan to \(goal.rawValue.lowercased()); this is week \(week)."
        return request
    }
}
