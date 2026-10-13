import SwiftUI

// MARK: - Onboarding Root View

struct OnboardingRootView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            SwiftBotGlassBackground()
            OnboardingAnimatedSymbolBackground()
                .allowsHitTesting(false)

            GeometryReader { proxy in
                ScrollView {
                    VStack {
                        onboardingCard
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
        .ignoresSafeArea()
    }

    private var onboardingCard: some View {
        VStack(spacing: 20) {
            cardHeader

            StandaloneSetupView()
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(maxWidth: 520)
        .background(onboardingCardBackground)
        .overlay(onboardingCardStroke)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 34, x: 0, y: 22)
    }

    private var cardHeader: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.accentColor.opacity(colorScheme == .dark ? 0.42 : 0.28),
                                Color.accentColor.opacity(0.0)
                            ],
                            center: .center,
                            startRadius: 6,
                            endRadius: 60
                        )
                    )
                    .frame(width: 112, height: 112)
                    .blur(radius: 4)

                if let bird = NSImage(named: "SwiftBird3") {
                    Image(nsImage: bird)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 88, height: 88)
                        .shadow(color: Color.accentColor.opacity(0.22), radius: 18, x: 0, y: 10)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 102, height: 92)

            Text("Welcome to SwiftBot")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .multilineTextAlignment(.center)

            Text("Enter your Discord bot token to get started.")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
        }
    }

    private var onboardingCardBackground: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.thinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.22),
                                Color.white.opacity(colorScheme == .dark ? 0.03 : 0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
    }

    private var onboardingCardStroke: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.32), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

// MARK: - Preview

#Preview {
    OnboardingRootView()
        .environmentObject(AppModel())
        .frame(width: 800, height: 600)
}
