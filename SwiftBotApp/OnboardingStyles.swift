import SwiftUI

// MARK: - Background Views

struct OnboardingAnimatedSymbolBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var animationStart = Date()

    private let symbols = [
        "book.pages.fill",
        "hammer.fill",
        "terminal.fill",
        "waveform.path.ecg",
        "sparkles",
        "point.3.connected.trianglepath.dotted",
        "server.rack",
        "person.3.sequence",
        "gearshape.2.fill",
        "cpu.fill",
        "wrench.and.screwdriver.fill",
        "bolt.horizontal.circle.fill"
    ]

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                animatedCanvas(size: proxy.size, date: timeline.date)
            }
        }
        .clipped()
        .opacity(colorScheme == .dark ? 0.78 : 0.96)
    }

    @ViewBuilder
    private func animatedCanvas(size: CGSize, date: Date) -> some View {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let diagonal = hypot(width, height)
        let elapsed = date.timeIntervalSince(animationStart)

        Canvas { context, _ in
            let trackWidth = diagonal * 2.2
            let trackHeight = diagonal * 1.6
            let rowStep: CGFloat = 108
            let rows = Int(trackHeight / rowStep) + 3
            let iconSize: CGFloat = 40
            let spacing: CGFloat = 50
            let step = iconSize + spacing
            let cols = Int(trackWidth / step) + 12

            context.opacity = colorScheme == .dark ? 0.10 : 0.18
            context.translateBy(x: width / 2, y: height / 2)
            context.rotate(by: .radians(-.pi / 4))

            var resolvedSymbols: [String: GraphicsContext.ResolvedSymbol] = [:]
            for symbol in symbols {
                if let resolved = context.resolveSymbol(id: symbol) {
                    resolvedSymbols[symbol] = resolved
                }
            }

            for row in 0..<rows {
                let direction: CGFloat = row.isMultiple(of: 2) ? 1 : -1
                let speed: CGFloat = 8 + CGFloat(deterministicInt(row, seed: 19, modulus: 6))
                let y = -trackHeight / 2 + CGFloat(row) * rowStep
                let rowOffset = deterministicInt(row, seed: 31, modulus: symbols.count)
                let strideChoices = [5, 7, 11]
                let stride = strideChoices[deterministicInt(row, seed: 47, modulus: strideChoices.count)]
                let sequencePeriod = symbols.count / greatestCommonDivisor(stride, symbols.count)
                let cycleWidth = CGFloat(sequencePeriod) * step
                var offset = (CGFloat(elapsed) * speed * direction).truncatingRemainder(dividingBy: cycleWidth)
                if offset < 0 { offset += cycleWidth }
                for col in -6...cols {
                    let x = -trackWidth / 2 + CGFloat(col) * step + offset
                    let symbolIndex = positiveModulo(rowOffset + (col * stride), symbols.count)
                    let symbolID = symbols[symbolIndex]
                    if let resolved = resolvedSymbols[symbolID] {
                        context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .center)
                    }
                }
            }
        } symbols: {
            ForEach(symbols, id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        colorScheme == .dark
                            ? .white.opacity(0.42)
                            : Color(red: 0.12, green: 0.24, blue: 0.37).opacity(0.46)
                    )
                    .tag(symbol)
            }
        }
    }

    private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let m = max(modulus, 1)
        let r = value % m
        return r >= 0 ? r : r + m
    }

    private func deterministicInt(_ row: Int, seed: Int, modulus: Int) -> Int {
        let m = max(modulus, 1)
        let mixed = (row &* 73) ^ (seed &* 131) ^ (row &* seed &* 17)
        let r = mixed % m
        return r >= 0 ? r : r + m
    }

    private func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let t = x % y
            x = y
            y = t
        }
        return max(x, 1)
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
