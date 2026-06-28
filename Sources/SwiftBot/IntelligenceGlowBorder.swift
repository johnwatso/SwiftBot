import SwiftUI

struct IntelligenceGlowBorder: View {
    @Environment(\.colorScheme) private var colorScheme

    var cornerRadius: CGFloat = 16
    var isAnimating = true

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    glowGradient,
                    lineWidth: 2
                )
                .opacity(colorScheme == .dark ? 0.92 : 0.82)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    glowGradient,
                    lineWidth: 6
                )
                .blur(radius: 6)
                .opacity(colorScheme == .dark ? 0.50 : 0.44)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    glowGradient,
                    lineWidth: 12
                )
                .blur(radius: 14)
                .opacity(colorScheme == .dark ? 0.26 : 0.22)
        }
        .blendMode(.plusLighter)
        .compositingGroup()
        .allowsHitTesting(false)
        .onAppear {
            guard isAnimating else { return }
            rotation = 0
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }

    private var glowGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [
                .purple,
                .pink,
                .blue,
                .cyan,
                .orange,
                .purple
            ]),
            center: .center,
            angle: .degrees(rotation)
        )
    }
}

struct IntelligenceGlowPulse: View {
    var cornerRadius: CGFloat = 16
    var onFinished: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var opacity = 0.8

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [
                        .purple,
                        .pink,
                        .blue,
                        .cyan,
                        .orange,
                        .purple
                    ]),
                    center: .center
                ),
                lineWidth: 10
            )
            .blur(radius: 16)
            .scaleEffect(scale)
            .opacity(opacity)
            .blendMode(.plusLighter)
            .compositingGroup()
            .allowsHitTesting(false)
            .task {
                withAnimation(.easeOut(duration: 0.6)) {
                    scale = 1.15
                    opacity = 0
                }

                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    onFinished()
                }
            }
    }
}
