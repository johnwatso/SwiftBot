import SwiftUI

// MARK: - Background Views

struct OnboardingAnimatedSymbolBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var animationStart = Date()

    // SF Symbols drawn from the set actually used elsewhere in the app, so
    // the onboarding backdrop reads as a continuation of SwiftBot's own UI
    // rather than generic decoration. Mirrors the "use the same icons as the
    // dashboard" choice the web login makes with its lucide set.
    private let symbols: [String] = [
        "server.rack",
        "point.3.connected.trianglepath.dotted",
        "dot.radiowaves.left.and.right",
        "cpu.fill",
        "terminal.fill",
        "curlybraces",
        "hammer.fill",
        "wrench.and.screwdriver.fill",
        "bolt.badge.automatic.fill",
        "sparkles",
        "waveform.path.ecg",
        "book.fill",
        "books.vertical.fill",
        "person.crop.circle.fill",
        "person.3.sequence",
        "play.circle.fill",
        "film.stack",
        "text.bubble.fill",
        "lock.fill",
        "lock.shield",
        "checkmark.shield.fill",
        "checkmark.seal.fill",
        "link.circle",
        "shippingbox.circle",
        "arrow.triangle.2.circlepath",
        "gearshape.2.fill",
        "info.circle.fill",
        "crown.fill",
        "clock",
        "magnifyingglass"
    ]

    // Apple system color palette — matches the web login screen's
    // getAppleIconPalette(). Slightly more saturated variants in dark mode
    // so the symbols pop through the glass card.
    private var palette: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.23, green: 0.51, blue: 0.96),  // blue
                Color(red: 0.39, green: 0.40, blue: 0.95),  // indigo
                Color(red: 0.66, green: 0.33, blue: 0.97),  // purple
                Color(red: 0.93, green: 0.28, blue: 0.60),  // pink
                Color(red: 0.94, green: 0.27, blue: 0.27),  // red
                Color(red: 0.98, green: 0.45, blue: 0.09),  // orange
                Color(red: 0.13, green: 0.77, blue: 0.37),  // green
                Color(red: 0.06, green: 0.72, blue: 0.51),  // mint
                Color(red: 0.02, green: 0.71, blue: 0.83),  // cyan
                Color(red: 0.05, green: 0.65, blue: 0.91)   // sky
            ]
        }
        return [
            Color(red: 0.00, green: 0.48, blue: 1.00),  // systemBlue
            Color(red: 0.35, green: 0.34, blue: 0.84),  // systemIndigo
            Color(red: 0.69, green: 0.32, blue: 0.87),  // systemPurple
            Color(red: 1.00, green: 0.18, blue: 0.33),  // systemPink
            Color(red: 1.00, green: 0.23, blue: 0.19),  // systemRed
            Color(red: 1.00, green: 0.58, blue: 0.00),  // systemOrange
            Color(red: 0.20, green: 0.78, blue: 0.35),  // systemGreen
            Color(red: 0.00, green: 0.78, blue: 0.75),  // systemMint
            Color(red: 0.19, green: 0.69, blue: 0.78),  // systemTeal
            Color(red: 0.20, green: 0.68, blue: 0.90)   // systemCyan
        ]
    }

    // Number of floating particles. Tuned to match the dense-but-airy feel
    // of the web login (150 lucide icons over a viewport).
    private let particleCount = 110

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                animatedCanvas(size: proxy.size, date: timeline.date)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func animatedCanvas(size: CGSize, date: Date) -> some View {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let elapsed = date.timeIntervalSince(animationStart)
        let particles = palette
        let baseOpacity: Double = colorScheme == .dark ? 0.55 : 0.50

        // One resolved symbol per (symbol, color) pair so the Canvas can
        // draw each particle with its assigned tint without re-rendering.
        let combos: [SymbolCombo] = symbolColorCombinations()

        Canvas { context, _ in
            var resolved: [String: GraphicsContext.ResolvedSymbol] = [:]
            for combo in combos {
                let id = comboID(symbol: combo.symbol, colorIndex: combo.colorIndex)
                if let r = context.resolveSymbol(id: id) {
                    resolved[id] = r
                }
            }

            for index in 0..<particleCount {
                let xFraction = pseudoRandom(index, seed: 11)
                let duration = 30.0 + pseudoRandom(index, seed: 23) * 40.0  // 30–70s
                let phase = pseudoRandom(index, seed: 37) * duration
                let progress = ((elapsed + phase).truncatingRemainder(dividingBy: duration)) / duration
                // Travel from just below the viewport (1.10) up to just
                // above (-0.10), matching the float-up keyframes on web.
                let y = height * (1.10 - 1.20 * CGFloat(progress))
                let x = width * CGFloat(xFraction)

                // Fade in for the first 15% and out for the last 15%,
                // mirroring the web keyframes (15% / 85% opacity stops).
                let fade: Double
                if progress < 0.15 {
                    fade = progress / 0.15
                } else if progress > 0.85 {
                    fade = (1.0 - progress) / 0.15
                } else {
                    fade = 1.0
                }

                let symbol = symbols[Int(pseudoRandom(index, seed: 53) * Double(symbols.count)) % symbols.count]
                let colorIndex = Int(pseudoRandom(index, seed: 71) * Double(particles.count)) % particles.count
                let rotation = pseudoRandom(index, seed: 89) * 2 * .pi + (.pi * 2 * progress)
                // Size range mirrors the web login (14–36px).
                let scale = 0.4 + pseudoRandom(index, seed: 97) * 0.6

                let id = comboID(symbol: symbol, colorIndex: colorIndex)
                guard let symResolved = resolved[id] else { continue }

                var ctx = context
                ctx.opacity = baseOpacity * fade
                ctx.translateBy(x: x, y: y)
                ctx.rotate(by: .radians(rotation))
                ctx.scaleBy(x: scale, y: scale)
                ctx.draw(symResolved, at: .zero, anchor: .center)
            }
        } symbols: {
            ForEach(combos) { combo in
                Image(systemName: combo.symbol)
                    .font(.system(size: 36, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(palette[combo.colorIndex])
                    .tag(comboID(symbol: combo.symbol, colorIndex: combo.colorIndex))
            }
        }
    }

    private struct SymbolCombo: Identifiable, Hashable {
        let symbol: String
        let colorIndex: Int
        var id: String { "\(symbol)#\(colorIndex)" }
    }

    private func symbolColorCombinations() -> [SymbolCombo] {
        var combos: [SymbolCombo] = []
        combos.reserveCapacity(symbols.count * palette.count)
        for symbol in symbols {
            for colorIndex in 0..<palette.count {
                combos.append(SymbolCombo(symbol: symbol, colorIndex: colorIndex))
            }
        }
        return combos
    }

    private func comboID(symbol: String, colorIndex: Int) -> String {
        "\(symbol)#\(colorIndex)"
    }

    /// Deterministic 0..<1 hash. Stable across frames so each particle
    /// keeps its own column, speed, color, and symbol for the session.
    private func pseudoRandom(_ index: Int, seed: Int) -> Double {
        let mixed = UInt64(bitPattern: Int64((index &* 0x9E3779B1) ^ (seed &* 0x85EBCA77) ^ ((index &+ seed) &* 0xC2B2AE3D)))
        return Double(mixed % 10_000) / 10_000.0
    }
}

// MARK: - View Modifiers for Onboarding

extension View {
    /// Standard text field style for onboarding inputs
    func onboardingTextFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                .white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            )
    }

    /// Glass-style button for onboarding actions
    func onboardingGlassButton() -> some View {
        self
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                .white.opacity(0.10),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.24), lineWidth: 1)
            )
    }
}
