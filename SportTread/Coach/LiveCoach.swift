import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Edits a running workout. The four quick buttons are fixed rules (what a tap does is stated on the
/// button and never depends on the AI). Typed or spoken requests go to Apple Intelligence, but its
/// answer is never trusted: the remaining time is forced to what the request implies (unchanged unless
/// the text asks for a length). Easier edits apply at once; harder ones (more intensity or more time)
/// wait for a tap. Every edit shows the new length with Undo (see WorkoutRunner).
@MainActor
final class LiveCoach: ObservableObject {
    enum Quick: String, CaseIterable, Identifiable {
        case easier, harder, shorter, longer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .easier: "Easier"
            case .harder: "Harder"
            case .shorter: "−5 min"
            case .longer: "+5 min"
            }
        }

        var symbol: String {
            switch self {
            case .easier: "arrow.down.circle"
            case .harder: "arrow.up.circle"
            case .shorter: "minus.circle"
            case .longer: "plus.circle"
            }
        }
    }

    /// A proposed edit to the running workout.
    struct Proposal: Equatable {
        var summary: String
        var request: String
        var remaining: [WorkoutStep]
        var currentMph: Double?
        var currentIncline: Double?
        var isHarder: Bool
    }

    @Published private(set) var isWorking = false
    @Published var message: String?

    // MARK: Requests

    func quick(_ kind: Quick, runner: WorkoutRunner) {
        guard runner.isActive, let current = runner.currentStep else { return }
        dlog("Live coach: quick button \(kind.title)")
        guard let proposal = Self.rules(kind, current: current, remaining: runner.remainingSteps) else {
            message = "There's no main part left to shorten."
            return
        }
        route(proposal, current: current, runner: runner)
    }

    func ask(_ text: String, runner: WorkoutRunner) async {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, runner.isActive, let current = runner.currentStep else { return }
        dlog("Live coach request (typed or spoken): \"\(request)\"")
        isWorking = true
        defer { isWorking = false }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AppleIntelligence.isAvailable {
            guard let target = Self.laterTarget(for: request, runner: runner) else {
                message = "That doesn't leave enough time after this step."
                return
            }
            do {
                var proposal = try await AppleIntelligence.edit(
                    request: request, current: current, remaining: runner.remainingSteps,
                    deviations: Deviation.summary(runner.deviations))
                // The AI's words are never trusted: the later steps must add up to the exact time
                if target == 0 {
                    proposal.remaining = []
                } else if let fitted = WorkoutEdits.fitRemaining(proposal.remaining, current: current, to: target) {
                    proposal.remaining = fitted
                } else {
                    message = "That doesn't leave enough time after this step."
                    return
                }
                route(proposal, current: current, runner: runner)
            } catch {
                message = "Apple Intelligence couldn't do that: \(error.localizedDescription)"
            }
            return
        }
        #endif
        message = "Typed and spoken requests need Apple Intelligence. The quick buttons still work."
    }

    /// Seconds the steps after the current one must add up to for this request: unchanged unless the
    /// text asks for a length. nil when the request can't be met.
    static func laterTarget(for request: String, runner: WorkoutRunner) -> Int? {
        let later = runner.laterSeconds
        let currentLeft = Int(runner.stepRemaining.rounded(.up))
        let target: Int
        switch LengthParser.request(in: request) {
        case .total(let minutes): target = minutes * 60 - runner.plannedThroughCurrent
        case .remaining(let minutes): target = minutes * 60 - currentLeft
        case .add(let minutes): target = later + minutes * 60
        case .remove(let minutes): target = later - minutes * 60
        case nil: target = later
        }
        if target < 0 { return nil }
        if target > 0 && target < LengthFit.minStep { return nil }
        return target - target % LengthFit.unit
    }

    private func route(_ proposal: Proposal, current: WorkoutStep, runner: WorkoutRunner) {
        var made = proposal
        made.remaining = SafetyCheck.clamped(made.remaining)
        made.isHarder = Self.isHarder(made, current: current, remaining: runner.remainingSteps)
        let note = "asked \"\(made.request)\": \(made.summary)"
        dlog("Live coach: \(made.isHarder ? "offered (needs a tap)" : "applied"): \(made.summary)\n" + Coach.describe(made.remaining))
        if made.isHarder {
            runner.present(WorkoutRunner.Offer(
                message: made.summary + " Apply it?",
                action: .edit(remaining: made.remaining, currentMph: made.currentMph, currentIncline: made.currentIncline),
                note: note))
            message = nil
        } else {
            runner.applyEdit(remaining: made.remaining, currentMph: made.currentMph,
                             currentIncline: made.currentIncline, note: note)
            message = nil
        }
    }

    // MARK: Fixed rules

    static func rules(_ kind: Quick, current: WorkoutStep, remaining: [WorkoutStep]) -> Proposal? {
        switch kind {
        case .easier: easier(current: current, remaining: remaining)
        case .harder: harder(current: current, remaining: remaining)
        case .shorter: shorter(current: current, remaining: remaining)
        case .longer: longer(current: current, remaining: remaining)
        }
    }

    static func easier(current: WorkoutStep, remaining: [WorkoutStep]) -> Proposal {
        Proposal(summary: "Easier: speed −0.3 mph and incline −1% from now on.", request: "easier",
                 remaining: WorkoutEdits.shifted(remaining, mph: -0.3, incline: -1),
                 currentMph: current.mph - 0.3, currentIncline: max(0, current.incline - 1), isHarder: false)
    }

    static func harder(current: WorkoutStep, remaining: [WorkoutStep]) -> Proposal {
        Proposal(summary: "Harder: speed +0.3 mph and incline +1% from now on.", request: "harder",
                 remaining: WorkoutEdits.shifted(remaining, mph: 0.3, incline: 1),
                 currentMph: current.mph + 0.3, currentIncline: current.incline + 1, isHarder: true)
    }

    /// −5 min: the last 5 minutes before the cool-down are cut. nil when there's no main part left.
    static func shorter(current: WorkoutStep, remaining: [WorkoutStep]) -> Proposal? {
        let cut = WorkoutEdits.shorter(remaining)
        guard cut.removed > 0 else { return nil }
        let minutes = Double(cut.removed) / 60
        let what = cut.removed == 300 ? "5 min shorter" : String(format: "%.1f min shorter (that's all the main part left)", minutes)
        return Proposal(summary: "\(what): the last minutes before the cool-down are cut.", request: "−5 min",
                        remaining: cut.steps, currentMph: nil, currentIncline: nil, isHarder: false)
    }

    /// +5 min: an extra 5-minute block before the cool-down.
    static func longer(current: WorkoutStep, remaining: [WorkoutStep]) -> Proposal {
        Proposal(summary: "5 min longer: an extra 5-minute block before the cool-down.", request: "+5 min",
                 remaining: WorkoutEdits.longer(remaining, current: current),
                 currentMph: nil, currentIncline: nil, isHarder: true)
    }

    /// More intensity (speed or incline, time-weighted) or more total time counts as harder.
    static func isHarder(_ proposal: Proposal, current: WorkoutStep, remaining: [WorkoutStep]) -> Bool {
        func work(_ steps: [WorkoutStep]) -> Double {
            steps.reduce(0) { $0 + Double($1.seconds) * ($1.mph + $1.incline * 0.3) }
        }
        let nowHarder = (proposal.currentMph ?? current.mph) > current.mph + 0.05
            || (proposal.currentIncline ?? current.incline) > current.incline + 0.25
        return nowHarder
            || work(proposal.remaining) > work(remaining) * 1.02
            || WorkoutEdits.seconds(proposal.remaining) > WorkoutEdits.seconds(remaining) + 15
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GeneratedEdit {
    @Guide(description: "One short sentence telling the runner what changed, e.g. Hills capped at 4% and the last interval removed.")
    var summary: String
    @Guide(description: "True only if the request is about right now (like 'easier now' or 'slow down'), so the current step changes too")
    var changeCurrentStep: Bool
    @Guide(description: "New speed for the current step in mph; used only if changeCurrentStep is true")
    var currentMph: Double
    @Guide(description: "New incline for the current step in percent; used only if changeCurrentStep is true")
    var currentIncline: Double
    @Guide(description: "All steps after the current one, in order, after applying the request", .maximumCount(24))
    var remaining: [GeneratedStep]
}

@available(iOS 26.0, *)
extension AppleIntelligence {
    private static var loggedEditInstructions = false

    private static let editInstructions = """
        You adjust a treadmill workout that is already running, following the runner's request.
        Rules:
        - Change only what the request asks for. Keep step labels unless a step is removed or added.
        - Keep the total remaining time the same unless the request is about time (shorter, longer, add or remove minutes).
        - Keep the cool-down at the end.
        - Speeds are in miles per hour (0.5 to 10), incline in percent (0 to 10).
        - Never raise the speed by more than 1.5 mph from one step to the next.
        - Each step lasts between 30 seconds and 15 minutes.
        - If the runner mentions pain, tiredness or feeling unwell, make it easier, never harder.
        """

    static func edit(request: String, current: WorkoutStep, remaining: [WorkoutStep],
                     deviations: String) async throws -> LiveCoach.Proposal {
        func line(_ s: WorkoutStep) -> String {
            "- \(s.label): \(s.seconds) s at \(String(format: "%.1f", s.mph)) mph, \(String(format: "%g", s.incline))% incline"
        }
        let prompt = """
            Current step: \(line(current))
            Remaining steps:
            \(remaining.isEmpty ? "(none)" : remaining.map(line).joined(separator: "\n"))
            What the runner has done so far: \(deviations)
            The runner asks: \(request)
            """
        if !loggedEditInstructions {
            loggedEditInstructions = true
            dlog("Live coach instructions (fixed text sent with every request):\n" + editInstructions)
        }
        dlog("Live coach prompt sent to Apple Intelligence:\n" + prompt)
        let session = LanguageModelSession(instructions: editInstructions)
        let made = try await session.respond(to: prompt, generating: GeneratedEdit.self).content
        dlog("Live coach AI answer: \"\(made.summary)\", changes the current step: \(made.changeCurrentStep)\n"
             + Coach.describe(made.remaining.map { WorkoutStep(label: $0.label, seconds: $0.seconds, mph: $0.mph, incline: $0.incline) }))
        return LiveCoach.Proposal(
            summary: made.summary, request: request,
            remaining: made.remaining.map { WorkoutStep(label: $0.label, seconds: $0.seconds, mph: $0.mph, incline: $0.incline) },
            currentMph: made.changeCurrentStep ? made.currentMph : nil,
            currentIncline: made.changeCurrentStep ? made.currentIncline : nil,
            isHarder: false)
    }
}
#endif
