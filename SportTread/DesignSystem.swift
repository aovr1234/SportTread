import SwiftUI

/// Colours and building blocks shared by every screen: the icon's navy-and-neon palette,
/// Liquid Glass panels (frosted material before iOS 26), rolling numbers and springy buttons.
enum Theme {
    static let volt = Color(red: 0.776, green: 1.0, blue: 0.0)      // #C6FF00
    static let cyan = Color(red: 0.0, green: 0.761, blue: 1.0)      // #00C2FF, from the icon
    static let lime = Color(red: 0.49, green: 1.0, blue: 0.31)      // #7DFF4F, from the icon
    static let navy = Color(red: 0.106, green: 0.165, blue: 0.29)   // #1B2A4A
    static let deep = Color(red: 0.043, green: 0.071, blue: 0.133)  // #0B1222
    static let ink = Color(red: 0.016, green: 0.024, blue: 0.047)   // #04060C
    static let stop = Color(red: 1.0, green: 0.27, blue: 0.27)

    static let accent = LinearGradient(colors: [cyan, lime], startPoint: .bottomLeading, endPoint: .topTrailing)
}

/// Navy backdrop with two slowly drifting glows, like the app icon.
struct AppBackground: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [Theme.navy, Theme.deep, Theme.ink],
                           center: UnitPoint(x: 0.5, y: 0.2), startRadius: 0, endRadius: 720)
            Circle()
                .fill(Theme.cyan.opacity(0.20))
                .frame(width: 340, height: 340)
                .blur(radius: 100)
                .offset(x: drift ? -130 : -50, y: drift ? -280 : -190)
            Circle()
                .fill(Theme.lime.opacity(0.15))
                .frame(width: 320, height: 320)
                .blur(radius: 100)
                .offset(x: drift ? 150 : 80, y: drift ? 250 : 340)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

extension View {
    /// Liquid Glass panel on iOS 26+, frosted material before.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self
                .background((tint ?? .clear).opacity(0.18), in: RoundedRectangle(cornerRadius: cornerRadius))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.12)))
        }
    }

    /// Transparent list/form over the app background.
    func sportList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AppBackground())
    }
}

@available(iOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint.opacity(0.35)) }
    if interactive { glass = glass.interactive() }
    return glass
}

/// Row background for lists and forms on the app background.
let glassRow = Color.white.opacity(0.07)

/// Big rolling number with a small caps label.
struct MetricTile: View {
    let value: String
    let unit: String
    var size: CGFloat = 52
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: size, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(highlighted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white))
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard()
    }
}

/// Capsule buttons: neon gradient (go), red (stop) or glass (neutral); spring and glow on press.
struct SportButtonStyle: ButtonStyle {
    enum Kind {
        case go, stop, neutral
    }

    var kind: Kind = .go
    var height: CGFloat = 56

    func makeBody(configuration: Configuration) -> some View {
        SportButtonBody(configuration: configuration, kind: kind, height: height)
    }

    private struct SportButtonBody: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: height)
                .foregroundStyle(kind == .go ? Color.black : Color.white)
                .background(fill, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(kind == .neutral ? 0.15 : 0)))
                .shadow(color: glow.opacity(configuration.isPressed ? 0.2 : 0.45),
                        radius: configuration.isPressed ? 6 : 16, y: 4)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
        }

        private var fill: AnyShapeStyle {
            switch kind {
            case .go: AnyShapeStyle(Theme.accent)
            case .stop: AnyShapeStyle(Theme.stop.gradient)
            case .neutral: AnyShapeStyle(Color.white.opacity(0.12))
            }
        }

        private var glow: Color {
            switch kind {
            case .go: Theme.lime
            case .stop: Theme.stop
            case .neutral: .clear
            }
        }
    }
}

/// Small coloured dot; pulses outward while something is live or in progress.
struct StatusDot: View {
    let color: Color
    var pulsing: Bool
    @State private var expand = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.7), lineWidth: 2)
                    .scaleEffect(expand ? 2.6 : 1)
                    .opacity(expand ? 0 : (pulsing ? 1 : 0)))
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { expand = true }
            }
    }
}

/// Circular progress in the icon's cyan-to-lime gradient.
struct RingProgress: View {
    let progress: Double
    var lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.002, min(1, progress)))
                .stroke(AngularGradient(colors: [Theme.cyan, Theme.lime, Theme.cyan], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.lime.opacity(0.5), radius: 8)
                .animation(.easeInOut(duration: 0.5), value: progress)
        }
    }
}

/// Thin gradient progress bar.
struct GradientBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(6, geo.size.width * min(1, max(0, progress))))
                    .shadow(color: Theme.lime.opacity(0.5), radius: 6)
                    .animation(.easeInOut(duration: 0.5), value: progress)
            }
        }
        .frame(height: 6)
    }
}
