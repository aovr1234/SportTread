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

    func create(_ request: WorkoutRequest, history: [HistoryEntry],
                readiness: Readiness.Level? = nil, readinessNote: String? = nil) async -> Workout {
        isWorking = true
        defer { isWorking = false }

        var resolved = request
        if resolved.kind == .recommend {
            resolved.kind = TemplateCoach.recommendedKind(history: history)
        }
        // Low readiness: keep it easy whatever was asked
        if readiness == .easy, resolved.intensity != .easy {
            resolved.intensity = .easy
            resolved.notes += (resolved.notes.isEmpty ? "" : " ") + "Kept easy because readiness is low today."
        }
        if let readinessNote {
            resolved.notes += (resolved.notes.isEmpty ? "" : " ") + readinessNote + "."
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AppleIntelligence.isAvailable {
            do {
                let made = try await AppleIntelligence.workout(for: resolved, history: history)
                dlog("Coach: asked for \(resolved.minutes) min \(resolved.kind.rawValue) \(resolved.intensity.rawValue)"
                     + (resolved.notes.isEmpty ? "" : ", note \(resolved.notes.count) characters"))
                dlog("Coach: AI proposed " + made.steps.map { String(format: "%@ %d:%02d %.1f/%.1f", $0.label, $0.seconds / 60, $0.seconds % 60, $0.mph, $0.incline) }
                    .joined(separator: "; "))
                let safe = SafetyCheck.trimmedEnds(SafetyCheck.snapped(SafetyCheck.repair(made, totalMinutes: resolved.minutes)))
                var rejected: String?
                if !safe.problems.isEmpty || safe.totalSeconds != resolved.minutes * 60 {
                    rejected = "it didn't pass the safety check"
                } else if resolved.minutes >= 20, SafetyCheck.isFlat(safe.steps) {
                    rejected = "it was one flat pace"
                } else if !SafetyCheck.matchesKind(safe.steps, kind: resolved.kind, minutes: resolved.minutes) {
                    rejected = "it didn't look like \(resolved.kind.rawValue.lowercased())"
                }
                if let rejected {
                    note = "Apple Intelligence's workout was rejected (\(rejected)), so the built-in rules made this one."
                    dlog("Coach: AI workout rejected, \(rejected); using the rules")
                } else {
                    note = "Created with Apple Intelligence"
                    dlog("Coach: AI workout accepted")
                    return safe
                }
            } catch {
                note = "Apple Intelligence couldn't create it (\(error.localizedDescription)), so the built-in rules made this one."
                dlog("Coach: Apple Intelligence failed: \(error.localizedDescription); using the rules")
            }
            return Self.exact(TemplateCoach.make(resolved, history: history), minutes: resolved.minutes)
        }
        #endif
        note = "Made with the built-in rules (Apple Intelligence: \(Self.appleIntelligenceStatus))."
        return Self.exact(TemplateCoach.make(resolved, history: history), minutes: resolved.minutes)
    }

    /// A workout of any other length never reaches the preview: if it's off, it's fitted to the requested minutes.
    private static func exact(_ workout: Workout, minutes: Int) -> Workout {
        workout.totalSeconds == minutes * 60 ? workout : SafetyCheck.repair(workout, totalMinutes: minutes)
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
        - Start with a warm-up of 3 to 5 minutes in total (never more than 5), in two steps that ramp up
          by at least 0.5 mph (for example 2.0 then 2.5 mph), and end with a cool-down of about 3 minutes
          in total (never more than 4) in two steps that ramp down. Most of the time is the main part.
        - The main part is never one flat step: use at least 3 blocks of 5 to 10 minutes that differ in
          speed (by 0.2 to 0.5 mph) or in incline (0 to 3 percent). Never give every step the same speed and incline.
        - If the person is sore, tired or asks for easy, keep the incline at 0 and vary only the speed a little.
        - Make step lengths whole minutes (multiples of 60 seconds), except interval steps.
        - The chosen workout type and intensity are required. If the person's note seems to ask for something
          else, still make that type and intensity and use the note only to adjust how hard it is.
        - Speeds are in miles per hour. Walking is about 2.5 to 3.8 mph, jogging about 4 to 6 mph.
          Stay close to the person's comfortable speed and never go above 10 mph.
        - Incline is 0 to 10 percent.
        - Never raise the speed by more than 1.5 mph from one step to the next.
        - Easy means relaxed, moderate means somewhat hard, hard means challenging but safe.
        - Each step lasts between 30 seconds and 15 minutes.
        """

    /// What each type means, so a small model can't read "intervals" as "varied walking".
    private static func typeGuide(_ kind: WorkoutRequest.Kind, base: Double) -> String {
        func mph(_ value: Double) -> String { String(format: "%.1f", value) }
        switch kind {
        case .intervals:
            return "Type rules for intervals: the main part repeats at least 5 pairs of a fast step (1 to 3 minutes at \(mph(base + 0.8)) to \(mph(base + 1.5)) mph) and a recovery step (1.5 to 3 minutes at \(mph(base)) mph). It is not a steady walk."
        case .hills:
            return "Type rules for hills: the main part is blocks of 2 to 4 minutes whose incline changes between 2 and 8 percent, with the speed staying near \(mph(base)) mph."
        case .jog:
            return "Type rules for jog: the main part is jogging at 4 to 6 mph in blocks of 5 to 10 minutes."
        case .walk:
            return "Type rules for walk: the main part is walking at 2.5 to 3.8 mph in blocks that vary a little."
        case .recommend:
            return ""
        }
    }

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
        prompt += "\n" + typeGuide(request.kind, base: base)
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
