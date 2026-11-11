import Foundation

/// Predictable edits to the remaining steps of a running workout: no UI, no AI. Tested on every build
/// (Tests/LengthTests/main.swift).
enum WorkoutEdits {
    static func isCooldown(_ step: WorkoutStep) -> Bool { step.label.lowercased().contains("cool") }

    static func seconds(_ steps: [WorkoutStep]) -> Int { steps.reduce(0) { $0 + $1.seconds } }

    /// Easier / Harder: speed and incline shift, durations stay the same. The cool-down is left alone.
    static func shifted(_ steps: [WorkoutStep], mph: Double, incline: Double) -> [WorkoutStep] {
        steps.map { step in
            var s = step
            if !isCooldown(s) {
                s.mph += mph
                s.incline = max(0, s.incline + incline)
            }
            return s
        }
    }

    /// Takes `seconds` off the end of the main part (before the cool-down). `removed` is less than
    /// asked only when there's not enough main time left, in which case every remaining main step is at its minimum.
    static func shorter(_ steps: [WorkoutStep], by seconds: Int = 300) -> (steps: [WorkoutStep], removed: Int) {
        var out = steps
        var need = seconds
        var i = out.count - 1
        while need > 0 && i >= 0 {
            if isCooldown(out[i]) {
                i -= 1
                continue
            }
            let length = out[i].seconds
            if length - need >= LengthFit.minStep {
                out[i].seconds = length - need
                need = 0
            } else if length <= need {
                need -= length
                out.remove(at: i)
                i -= 1
            } else {
                need -= length - LengthFit.minStep
                out[i].seconds = LengthFit.minStep
                i -= 1
            }
        }
        return (out, seconds - need)
    }

    /// Adds a block of `seconds` before the cool-down, copying the last main step (or `current`).
    static func longer(_ steps: [WorkoutStep], current: WorkoutStep, by seconds: Int = 300) -> [WorkoutStep] {
        var out = steps
        let model = out.last(where: { !isCooldown($0) }) ?? current
        let block = WorkoutStep(label: "Extra \(seconds / 60) min", seconds: seconds, mph: model.mph, incline: model.incline)
        if let cooldown = out.firstIndex(where: isCooldown) {
            out.insert(block, at: cooldown)
        } else {
            out.append(block)
        }
        return out
    }

    /// Makes proposed remaining steps add up to exactly `target` seconds (what an AI edit must do:
    /// what it says it did is never trusted). nil when `target` is too short for even one step.
    static func fitRemaining(_ proposed: [WorkoutStep], current: WorkoutStep, to target: Int) -> [WorkoutStep]? {
        guard target >= LengthFit.minStep else { return nil }
        var steps = proposed
        if steps.isEmpty {
            steps = [WorkoutStep(label: "Extra time", seconds: target, mph: current.mph, incline: current.incline)]
        }
        let total = target - target % LengthFit.unit
        guard let fitted = LengthFit.fit(steps.map(\.seconds), to: total) else { return nil }
        var out: [WorkoutStep] = []
        for (k, original) in fitted.kept.enumerated() {
            var s = steps[original]
            s.seconds = fitted.seconds[k]
            out.append(s)
        }
        return SafetyCheck.clamped(out)
    }
}
