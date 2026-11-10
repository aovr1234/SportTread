import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Edits a running workout on request: quick buttons or typed/spoken text. Apple Intelligence
/// rewrites the remaining steps (and the current one, if the request is about now); fixed rules
/// take over for the quick buttons when it's unavailable. Results pass SafetyCheck; easier edits
/// apply right away, harder ones (more intensity or more time) wait for a tap.
@MainActor
final class LiveCoach: ObservableObject {
    enum Quick: String, CaseIterable, Identifiable {
        case easier = "Easier"
        case harder = "Harder"
        case shorter = "Shorter"
        case longer = "Longer"

        var id: String { rawValue }

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

    func quick(_ kind: Quick, runner: WorkoutRunner) async {
        await handle(request: kind.rawValue.lowercased(), quick: kind, runner: runner)
    }

    func ask(_ text: String, runner: WorkoutRunner) async {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        await handle(request: request, quick: nil, runner: runner)
    }

    private func handle(request: String, quick: Quick?, runner: WorkoutRunner) async {
        guard runner.isActive, let current = runner.currentStep else { return }
        isWorking = true
        defer { isWorking = false }

        var proposal: Proposal?
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AppleIntelligence.isAvailable {
            proposal = try? await AppleIntelligence.edit(
                request: request, current: current, remaining: runner.remainingSteps,
                deviations: Deviation.summary(runner.deviations))
        }
        #endif
        if proposal == nil, let quick {
            proposal = Self.rules(quick, current: current, remaining: runner.remainingSteps)
        }
        guard var made = proposal else {
            message = "Typed and spoken requests need Apple Intelligence. The quick buttons still work."
            return
        }
        made.remaining = SafetyCheck.clamped(made.remaining)
        made.isHarder = Self.isHarder(made, current: current, remaining: runner.remainingSteps)

        if made.isHarder {
            runner.present(WorkoutRunner.Offer(
                message: made.summary + " Apply it?",
                action: .edit(remaining: made.remaining, currentMph: made.currentMph, currentIncline: made.currentIncline),
                note: "asked \"\(request)\": \(made.summary)"))
            message = nil
        } else {
            runner.applyEdit(remaining: made.remaining, currentMph: made.currentMph,
                             currentIncline: made.currentIncline, note: "asked \"\(request)\": \(made.summary)")
            message = "Applied: \(made.summary)"
        }
    }

    // MARK: Rules (no Apple Intelligence)

    static func rules(_ kind: Quick, current: WorkoutStep, remaining: [WorkoutStep]) -> Proposal {
        func shifted(_ steps: [WorkoutStep], mph: Double, incline: Double) -> [WorkoutStep] {
            steps.map { step in
                var s = step
                if !s.label.lowercased().contains("cool") {
                    s.mph += mph
                    s.incline = max(0, s.incline + incline)
                }
                return s
            }
        }
        func scaled(_ steps: [WorkoutStep], by factor: Double) -> [WorkoutStep] {
            steps.map { step in
                var s = step
                if !s.label.lowercased().contains("cool") {
                    s.seconds = max(30, Int((Double(s.seconds) * factor / 5).rounded()) * 5)
                }
                return s
            }
        }
        switch kind {
        case .easier:
            return Proposal(summary: "Speed −0.3 mph and incline −1% from now on.", request: "easier",
                            remaining: shifted(remaining, mph: -0.3, incline: -1),
                            currentMph: current.mph - 0.3, currentIncline: max(0, current.incline - 1), isHarder: false)
        case .harder:
            return Proposal(summary: "Speed +0.3 mph and incline +1% from now on.", request: "harder",
                            remaining: shifted(remaining, mph: 0.3, incline: 1),
                            currentMph: current.mph + 0.3, currentIncline: current.incline + 1, isHarder: true)
        case .shorter:
            return Proposal(summary: "The remaining steps are 20% shorter.", request: "shorter",
                            remaining: scaled(remaining, by: 0.8), currentMph: nil, currentIncline: nil, isHarder: false)
        case .longer:
            return Proposal(summary: "The remaining steps are 20% longer.", request: "longer",
                            remaining: scaled(remaining, by: 1.2), currentMph: nil, currentIncline: nil, isHarder: true)
        }
    }

    /// More intensity (speed or incline, time-weighted) or more total time counts as harder.
    static func isHarder(_ proposal: Proposal, current: WorkoutStep, remaining: [WorkoutStep]) -> Bool {
        func work(_ steps: [WorkoutStep]) -> Double {
            steps.reduce(0) { $0 + Double($1.seconds) * ($1.mph + $1.incline * 0.3) }
        }
        let time = { (steps: [WorkoutStep]) in steps.reduce(0) { $0 + $1.seconds } }
        let nowHarder = (proposal.currentMph ?? current.mph) > current.mph + 0.05
            || (proposal.currentIncline ?? current.incline) > current.incline + 0.25
        return nowHarder || work(proposal.remaining) > work(remaining) * 1.02 || time(proposal.remaining) > time(remaining) + 15
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
        let session = LanguageModelSession(instructions: editInstructions)
        let made = try await session.respond(to: prompt, generating: GeneratedEdit.self).content
        return LiveCoach.Proposal(
            summary: made.summary, request: request,
            remaining: made.remaining.map { WorkoutStep(label: $0.label, seconds: $0.seconds, mph: $0.mph, incline: $0.incline) },
            currentMph: made.changeCurrentStep ? made.currentMph : nil,
            currentIncline: made.changeCurrentStep ? made.currentIncline : nil,
            isHarder: false)
    }
}
#endif
