import SwiftUI
import UIKit

/// Speed or incline control. Tap ▲/▼ to step the value. Press and hold, then slide up/down to
/// scroll in the same steps (haptic tick per step; faster the further you slide, and it keeps
/// counting while you hold near the edge). Releasing sends one value. The number shows in the
/// accent gradient until the treadmill reports it.
struct AdjustTile: View {
    let title: String
    let unit: String
    /// Live reading from the treadmill
    let value: Double?
    let step: Double
    let range: ClosedRange<Double>
    let decimals: Int
    var enabled = true
    let onCommit: (Double) -> Void

    @State private var scrub: Double?
    @State private var scrubBase = 0.0
    @State private var translation: CGFloat = 0
    @State private var edgeBonus = 0.0
    @State private var edgeTask: Task<Void, Never>?
    @State private var scrubEndedAt = Date.distantPast
    @State private var pending: (value: Double, at: Date)?
    private let haptics = UISelectionFeedbackGenerator()

    private var activePending: Double? {
        guard let pending, Date().timeIntervalSince(pending.at) < 6 else { return nil }
        return pending.value
    }

    private var current: Double { activePending ?? value ?? range.lowerBound }

    private var displayText: String {
        guard let shown = scrub ?? activePending ?? value else { return "–" }
        return String(format: "%.\(decimals)f", shown)
    }

    private var highlighted: Bool { scrub != nil || activePending != nil }

    var body: some View {
        VStack(spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            arrow("chevron.up", direction: 1)
            Text(displayText)
                .font(.system(size: 42, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(highlighted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white))
                .contentTransition(.numericText())
                .animation(.snappy, value: displayText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit).font(.caption).foregroundStyle(.secondary)
            arrow("chevron.down", direction: -1)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassCard(tint: scrub != nil ? Theme.cyan : nil, interactive: true)
        .scaleEffect(scrub != nil ? 1.04 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: scrub != nil)
        .simultaneousGesture(scrubGesture)
        .opacity(enabled ? 1 : 0.4)
        .allowsHitTesting(enabled)
        .onChange(of: value) { _, newValue in
            if let target = pending?.value, let newValue, abs(newValue - target) < step / 2 { pending = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(displayText) \(unit)")
        .accessibilityAdjustableAction { direction in
            tap(direction == .increment ? 1 : -1)
        }
    }

    private func arrow(_ symbol: String, direction: Double) -> some View {
        Button {
            tap(direction)
        } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.lime)
    }

    private func tap(_ direction: Double) {
        // A release after scrubbing can also arrive as a button tap; ignore it
        guard Date().timeIntervalSince(scrubEndedAt) > 0.35 else { return }
        haptics.selectionChanged()
        commit(clamp(current + direction * step))
    }

    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { state in
                guard case .second(true, let drag) = state else { return }
                if scrub == nil { beginScrub() }
                translation = drag?.translation.height ?? 0
                updateScrub()
            }
            .onEnded { _ in
                edgeTask?.cancel()
                edgeTask = nil
                if let value = scrub { commit(value) }
                scrub = nil
                translation = 0
                scrubEndedAt = Date()
            }
    }

    private func beginScrub() {
        scrub = current
        scrubBase = current
        edgeBonus = 0
        haptics.prepare()
        haptics.selectionChanged()
        // Holding the finger well above or below the start keeps counting, faster the longer it's held
        edgeTask = Task {
            var held = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                if abs(translation) > 90 {
                    held += 0.12
                    edgeBonus += (translation < 0 ? 1 : -1) * (1 + held)
                    updateScrub()
                } else {
                    held = 0
                }
            }
        }
    }

    private func updateScrub() {
        let distance = -Double(translation)  // sliding up raises the value
        let accelerated = distance / 14 + (distance < 0 ? -1 : 1) * pow(abs(distance) / 70, 2)
        let next = clamp(scrubBase + (accelerated.rounded(.towardZero) + edgeBonus.rounded(.towardZero)) * step)
        if next != scrub {
            scrub = next
            haptics.selectionChanged()
        }
    }

    private func clamp(_ raw: Double) -> Double {
        let snapped = (raw / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    private func commit(_ newValue: Double) {
        pending = (newValue, Date())
        onCommit(newValue)
    }
}
