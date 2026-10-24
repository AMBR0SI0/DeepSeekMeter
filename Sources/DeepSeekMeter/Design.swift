import SwiftUI

// MARK: - Palette

enum Palette {
    static let surface = Color(red: 0.055, green: 0.063, blue: 0.082)
    static let calm = Color(red: 0.38, green: 0.79, blue: 0.64)
    static let warn = Color(red: 0.99, green: 0.73, blue: 0.27)
    static let hot = Color(red: 1.00, green: 0.38, blue: 0.40)
    static let quiet = Color(red: 0.55, green: 0.58, blue: 0.66)

    static let accent = LinearGradient(
        colors: [Color(red: 0.40, green: 0.62, blue: 1.00), Color(red: 0.72, green: 0.45, blue: 1.00)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let hairline = LinearGradient(
        colors: [.white.opacity(0.30), .white.opacity(0.04), .white.opacity(0.12)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Level {
    var tint: Color {
        switch self {
        case .idle: return Palette.quiet
        case .calm: return Palette.calm
        case .warn: return Palette.warn
        case .hot: return Palette.hot
        }
    }

    var label: String {
        switch self {
        case .idle: return "idle"
        case .calm: return "normal"
        case .warn: return "elevated"
        case .hot: return "high"
        }
    }
}

// MARK: - Card

struct GlassCard: ViewModifier {
    var radius: CGFloat
    var glow: Color?

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Palette.surface.opacity(0.80))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.9)
            }
            .shadow(color: .black.opacity(0.42), radius: 26, y: 12)
            .shadow(color: (glow ?? .clear).opacity(0.30), radius: 22)
    }
}

// MARK: - Orb

struct Orb: View {
    var level: Level
    var size: CGFloat = 18
    /// A permanently spinning orb costs a full frame's worth of CPU in a HUD
    /// that is always on screen, so it only moves while it is being read.
    var animated = true
    @State private var spin = false
    @State private var blink = false

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(
                    colors: [level.tint, level.tint.opacity(0.15), level.tint],
                    center: .center
                ))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(spin ? .linear(duration: 7).repeatForever(autoreverses: false) : nil, value: spin)

            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: size * 0.25, height: size * 0.25)

            Circle()
                .stroke(level.tint, lineWidth: max(size * 0.067, 0.7))
                .scaleEffect(blink ? 1.55 : 1.0)
                .opacity(blink ? 0.0 : 0.65)
                .animation(
                    level == .hot
                        ? .easeOut(duration: 0.9).repeatForever(autoreverses: false)
                        : .default,
                    value: blink
                )
        }
        .frame(width: size, height: size)
        .onAppear {
            spin = animated
            blink = animated && level == .hot
        }
        .onChange(of: animated) { _, on in
            spin = on
            blink = on && level == .hot
        }
        .onChange(of: level) { _, new in blink = animated && new == .hot }
    }
}

/// Column chart for the narrow hover state, where a line chart has no room to read.
struct VBars: View {
    var values: [Int]
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let peak = max(values.max() ?? 1, 1)
            let count = max(values.count, 1)
            let gap: CGFloat = 1.6
            let width = max((geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 0.8)

            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)

                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        let filled = CGFloat(value) / CGFloat(peak)
                        Capsule()
                            .fill(tint.opacity(0.28 + 0.62 * filled))
                            .frame(width: width, height: max(geo.size.height * filled, value > 0 ? 1.5 : 0))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .animation(.smooth(duration: 0.5), value: values)
        }
    }
}

// MARK: - Gauge

struct GaugeBar: View {
    var value: Int
    var warn: Int
    var red: Int
    var level: Level
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let cap = Double(red) * 1.15
            let fraction = min(Double(value) / cap, 1)
            let fill = geo.size.width * CGFloat(fraction)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))

                Capsule()
                    .fill(LinearGradient(
                        colors: [level.tint.opacity(0.65), level.tint],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: max(fill, fraction > 0 ? 5 : 0))
                    .shadow(color: level.tint.opacity(0.5), radius: 6)

                tick(at: Double(warn) / cap, width: geo.size.width)
                tick(at: Double(red) / cap, width: geo.size.width)
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.55), value: value)
    }

    private func tick(at fraction: Double, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.20))
            .frame(width: 1, height: 9)
            .offset(x: width * CGFloat(min(fraction, 1)) - 0.5)
    }
}

// MARK: - Typography

extension View {
    func label(_ size: CGFloat = 9) -> some View {
        self.font(.system(size: size, weight: .semibold, design: .default))
            .tracking(1.1)
            .textCase(.uppercase)
    }

    func number(_ size: CGFloat) -> some View {
        self.font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
    }
}
