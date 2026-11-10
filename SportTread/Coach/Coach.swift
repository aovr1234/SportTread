import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Creates workouts: Apple Intelligence (on-device) when available, otherwise the built-in rules.
/// Either way the result goes through SafetyCheck before it can run.
@MainActor
final class Coach: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var note = ""

    func create(_ request: WorkoutRequest, history: [HistoryEntry]) async -> Workout {
        isWorking = true
        defer { isWorking = false }

        var resolved = request
        if resolved.kind == .recommend {
            resolved.kind = TemplateCoach.recommendedKind(history: history)
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AppleIntelligence.isAvailable {
            do {
                let made = try await AppleIntelligence.workout(for: resolved, history: history)
                let safe = SafetyCheck.repair(made, totalMinutes: resolved.minutes)
                if safe.problems.isEmpty {
                    note = "Created with Apple Intelligence"
                    return safe
                }
                note = "Apple Intelligence's workout didn't pass the safety check, so the built-in rules made this one."
            } catch {
                note = "Apple Intelligence couldn't create it (\(error.localizedDescription)), so the built-in rules made this one."
            }
            return TemplateCoach.make(resolved, history: history)
        }
        #endif
        note = "Made with the built-in rules (Apple Intelligence: \(Self.appleIntelligenceStatus))."
        return TemplateCoach.make(resolved, history: history)
    }

    static var appleIntelligenceStatus: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return AppleIntelligence.status
        }
        return "needs iOS 26"
        #else
        return "not in this build"
        #endif
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GeneratedWorkout {
    @Guide(description: "Short workout name, at most 4 words, e.g. Hill Builder or Easy Recovery Walk")
    var name: String
    @Guide(description: "One encouraging sentence describing the workout")
    var summary: String
    @Guide(description: "The steps in order, starting with a warm-up and ending with a cool-down", .maximumCount(24))
    var steps: [GeneratedStep]
}

@available(iOS 26.0, *)
@Generable
struct GeneratedStep {
    @Guide(description: "Short label such as Warm-up, Fast 2/6, Recover, Hill 3, Steady or Cool-down")
    var label: String
    @Guide(description: "Length of this step in whole seconds, between 30 and 900")
    var seconds: Int
    @Guide(description: "Belt speed in miles per hour, between 0.5 and 10")
    var mph: Double
    @Guide(description: "Treadmill incline in percent, between 0 and 10")
    var incline: Double
}

@available(iOS 26.0, *)
enum AppleIntelligence {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var status: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            return "unavailable (\(String(describing: reason)))"
        }
    }

    private static let instructions = """
        You are a friendly treadmill coach. You design one treadmill workout as a list of timed steps.
        Rules:
        - The steps' seconds must add up to the requested total time.
        - Start with a warm-up of 3 to 5 minutes and end with a cool-down of about 3 minutes.
        - Speeds are in miles per hour. Walking is about 2.5 to 3.8 mph, jogging about 4 to 6 mph.
          Stay close to the person's comfortable speed and never go above 10 mph.
        - Incline is 0 to 10 percent.
        - Never raise the speed by more than 1.5 mph from one step to the next.
        - Easy means relaxed, moderate means somewhat hard, hard means challenging but safe.
        - Each step lasts between 30 seconds and 15 minutes.
        """

    static func workout(for request: WorkoutRequest, history: [HistoryEntry]) async throws -> Workout {
        let base = TemplateCoach.baseSpeed(history: history)
        let recent = history.suffix(5).map { entry in
            let effort = entry.effort.map { ", effort \($0)/10" } ?? ""
            let done = entry.completed ? "completed" : "stopped early"
            let changes = (entry.deviations ?? []).isEmpty ? "" : "; " + Deviation.summary(entry.deviations ?? [])
            return "- \(entry.name): \(entry.seconds / 60) min, top speed \(String(format: "%.1f", entry.maxMph)) mph, \(done)\(effort)\(changes)"
        }
        var prompt = """
            Create a \(request.minutes)-minute \(request.intensity.rawValue.lowercased()) \(request.kind.rawValue.lowercased()) treadmill workout.
            Total time: exactly \(request.minutes * 60) seconds.
            The person's comfortable walking speed is about \(String(format: "%.1f", base)) mph.
            """
        prompt += recent.isEmpty
            ? "\nNo previous workouts yet, so keep it approachable."
            : "\nRecent workouts:\n" + recent.joined(separator: "\n")
        let notes = request.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            prompt += "\nThe person adds: \(notes)"
        }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: GeneratedWorkout.self)
        let made = response.content
        return Workout(
            name: made.name,
            summary: made.summary,
            steps: made.steps.map { WorkoutStep(label: $0.label, seconds: $0.seconds, mph: $0.mph, incline: $0.incline) })
    }
}
#endif
