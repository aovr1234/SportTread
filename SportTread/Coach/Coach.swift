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

    /// What the app is doing while it works, shown on the Create button ("Asking Groq…")
    @Published private(set) var progress = ""

    func create(_ request: WorkoutRequest, history: [HistoryEntry],
                readiness: Readiness.Level? = nil, readinessNote: String? = nil) async -> Workout {
        isWorking = true
        progress = ""
        defer {
            isWorking = false
            progress = ""
        }

        // What was asked, exactly as typed (the readiness text the app adds is logged separately)
        dlog("Coach request: \(request.minutes) min, \(request.kind.rawValue), \(request.intensity.rawValue)")
        dlog("Coach note as typed: " + (request.notes.isEmpty ? "(none)" : "\"\(request.notes)\""))
        dlog("Coach readiness: \(readiness.map { $0.rawValue } ?? "unknown"); text added by the app: "
             + (readinessNote.map { "\"\($0)\"" } ?? "(none)"))

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
        let comfortable = TemplateCoach.baseSpeed(history: history)

        // 1. Cloud AI, when it is on: each enabled service in turn, with up to two fix-ups each
        if let made = await createWithCloud(request: request, resolved: resolved, history: history, comfortable: comfortable) {
            return made
        }

        // 2. Apple Intelligence on the phone
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AppleIntelligence.isAvailable {
            do {
                progress = "Asking Apple Intelligence…"
                let made = try await AppleIntelligence.workout(for: resolved, history: history)
                dlog("Coach AI answer: \"\(made.name)\" / \"\(made.summary)\"; \(made.steps.count) steps adding up to "
                     + "\(Self.clock(made.totalSeconds)), asked for \(resolved.minutes):00\n" + Self.describe(made.steps))
                let judged = judge(made, resolved: resolved, comfortable: comfortable)
                if let rejected = judged.rejected {
                    note = "Apple Intelligence's workout was rejected (\(rejected)), so the built-in rules made this one."
                    dlog("Coach: AI workout rejected because \(rejected). After repair it was:\n" + Self.describe(judged.safe.steps))
                } else {
                    note = "Created with Apple Intelligence"
                    dlog("Coach: AI workout accepted. Final steps:\n" + Self.describe(judged.safe.steps))
                    return judged.safe
                }
            } catch {
                note = "Apple Intelligence couldn't create it (\(error.localizedDescription)), so the built-in rules made this one."
                dlog("Coach: Apple Intelligence failed: \(error.localizedDescription); using the rules")
            }
            return Self.logged(Self.exact(TemplateCoach.make(resolved, history: history), minutes: resolved.minutes))
        }
        #endif

        // 3. The built-in rules
        note = "Made with the built-in rules (Apple Intelligence: \(Self.appleIntelligenceStatus))."
        return Self.logged(Self.exact(TemplateCoach.make(resolved, history: history), minutes: resolved.minutes))
    }

    /// Repairs an AI workout and decides whether it is good enough: the reason it was rejected, or nil.
    private func judge(_ made: Workout, resolved: WorkoutRequest, comfortable: Double) -> (safe: Workout, rejected: String?) {
        let safe = SafetyCheck.trimmedEnds(SafetyCheck.snapped(SafetyCheck.repair(made, totalMinutes: resolved.minutes)))
        var rejected: String?
        if !safe.problems.isEmpty || safe.totalSeconds != resolved.minutes * 60 {
            rejected = "it didn't pass the safety check"
        } else if resolved.minutes >= 20, SafetyCheck.isFlat(safe.steps) {
            rejected = "it was one flat pace"
        } else if !SafetyCheck.matchesKind(safe.steps, kind: resolved.kind, minutes: resolved.minutes, effort: resolved.effectiveEffort) {
            rejected = "it didn't look like \(resolved.kind.rawValue.lowercased())"
        } else if resolved.kind == .intervals, resolved.minutes >= 20,
                  !SafetyCheck.lengthIsClose(made.totalSeconds, to: resolved.minutes * 60) {
            rejected = "its own steps added up to \(Self.clock(made.totalSeconds)) instead of \(resolved.minutes):00"
        } else if resolved.kind == .intervals,
                  let problem = SafetyCheck.intervalProblem(safe.steps, comfortable: comfortable,
                                                            intensity: resolved.intensity, minutes: resolved.minutes,
                                                            effort: resolved.effectiveEffort) {
            rejected = problem
        } else if let problem = SafetyCheck.easyPaceProblem(safe.steps, kind: resolved.kind,
                                                            intensity: resolved.intensity, comfortable: comfortable) {
            rejected = problem
        } else if let problem = SafetyCheck.inclineProblem(safe.steps, request: resolved, comfortable: comfortable) {
            rejected = problem
        }
        return (safe, rejected)
    }

    /// Tries each enabled cloud service in order. A rejected answer goes back to the same service with the
    /// exact reason (up to two fix-ups); a service that fails (no key, no internet, free limit reached) is
    /// skipped. Returns nil when cloud AI is off or nothing acceptable came back.
    private func createWithCloud(request: WorkoutRequest, resolved: WorkoutRequest, history: [HistoryEntry],
                                 comfortable: Double) async -> Workout? {
        let settings = CloudSettings.shared
        let providers = settings.ready
        guard !providers.isEmpty else { return nil }

        // What the services see: the request, the note, the comfortable speed and, if allowed, recent workouts
        var asked = resolved
        let shared = settings.sendHistory ? history : []
        if !settings.sendHistory { asked.notes = request.notes }
        let system = WorkoutPrompt.cloudInstructions(for: asked.kind)
        let prompt = WorkoutPrompt.request(asked, base: comfortable, history: shared)
        dlog("Coach: cloud AI is on, trying " + providers.map(\.name).joined(separator: ", ")
             + (settings.sendHistory ? "" : " (recent workouts and readiness not sent)"))
        dlog("Coach cloud prompt:\n" + prompt)

        let deadline = Date().addingTimeInterval(150)
        for provider in providers {
            var messages: [[String: String]] = [["role": "system", "content": system], ["role": "user", "content": prompt]]
            for attempt in 0..<3 {
                if Date() > deadline {
                    dlog("Coach: the cloud time budget (150 s) is used up")
                    return nil
                }
                progress = attempt == 0 ? "Asking \(provider.name)…" : "\(provider.name): fixing it (try \(attempt + 1) of 3)…"
                let reply: CloudClient.Reply
                do {
                    reply = try await CloudClient.chat(provider: provider, key: settings.key(for: provider.id), messages: messages)
                } catch {
                    dlog("Coach: \(provider.name) failed: \(error.localizedDescription). Trying the next one.")
                    break
                }
                dlog(String(format: "Coach: %@ (%@) answered in %.1f s, attempt %d", provider.name, provider.model, reply.seconds, attempt + 1))

                var reason: String
                if let made = WorkoutPrompt.parse(reply.text) {
                    dlog("Coach cloud answer: \"\(made.name)\" / \"\(made.summary)\"; \(made.steps.count) steps adding up to "
                         + "\(Self.clock(made.totalSeconds)), asked for \(resolved.minutes):00\n" + Self.describe(made.steps))
                    let judged = judge(made, resolved: resolved, comfortable: comfortable)
                    guard let rejected = judged.rejected else {
                        note = "Created with \(provider.name)" + (attempt == 0 ? "" : attempt == 1 ? " after one fix" : " after two fixes")
                        dlog("Coach: \(provider.name) workout accepted. Final steps:\n" + Self.describe(judged.safe.steps))
                        return judged.safe
                    }
                    reason = rejected
                    dlog("Coach: \(provider.name) workout rejected because \(rejected)")
                } else {
                    reason = "the reply wasn't one JSON object with a steps list"
                    dlog("Coach: \(provider.name) reply couldn't be read. It began: " + String(reply.text.prefix(200)))
                }
                messages.append(["role": "assistant", "content": reply.text])
                messages.append(["role": "user", "content": WorkoutPrompt.retry(reason: reason, seconds: resolved.minutes * 60)])
            }
        }
        dlog("Coach: no cloud service gave an acceptable workout")
        return nil
    }

    private static func logged(_ workout: Workout) -> Workout {
        dlog("Coach: made with the built-in rules. Final steps:\n" + describe(workout.steps))
        return workout
    }

    nonisolated static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// One line per step, for the diagnostics log.
    nonisolated static func describe(_ steps: [WorkoutStep]) -> String {
        steps.enumerated().map { index, step in
            String(format: "%2d. %@  %@  %.1f mph  %g%%", index + 1, step.label, clock(step.seconds), step.mph, step.incline)
        }.joined(separator: "\n")
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

    private static var loggedInstructions = false

    static func workout(for request: WorkoutRequest, history: [HistoryEntry]) async throws -> Workout {
        let base = TemplateCoach.baseSpeed(history: history)
        let prompt = WorkoutPrompt.request(request, base: base, history: history)
        let instructions = WorkoutPrompt.rules
        if !loggedInstructions {
            loggedInstructions = true
            dlog("Coach instructions (fixed text sent with every request):\n" + instructions)
        }
        dlog("Coach prompt sent to Apple Intelligence:\n" + prompt)
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
