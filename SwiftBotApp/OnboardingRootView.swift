import SwiftUI

// MARK: - Setup Mode

enum SetupMode: String, CaseIterable, Identifiable {
    case standalone
    case mesh
    case remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standalone: return "Set Up Standalone Bot"
        case .mesh: return "Set Up SwiftMesh"
        case .remote: return "Connect to SwiftBot Remote"
        }
    }

    var subtitle: String {
        switch self {
        case .standalone: return "Run SwiftBot locally on this Mac."
        case .mesh: return "Join a SwiftMesh cluster."
        case .remote: return "Control an existing SwiftBot node remotely. Beta feature."
        }
    }

    var icon: String {
        switch self {
        case .standalone: return "server.rack"
        case .mesh: return "point.3.connected.trianglepath.dotted"
        case .remote: return "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - Onboarding Root View

struct OnboardingRootView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var mode: SetupMode?
    @State private var movesForward: Bool = true

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

            ZStack {
                switch mode {
                case .standalone:
                    StandaloneSetupView(onBack: { navigateTo(nil) })
                        .id("standalone")
                case .mesh:
                    SwiftMeshSetupView(onBack: { navigateTo(nil) })
                        .id("mesh")
                case .remote:
                    RemoteSetupView(onBack: { navigateTo(nil) })
                        .id("remote")
                case nil:
                    ModeSelectionView(mode: Binding(
                        get: { mode },
                        set: { newMode in
                            if let newMode {
                                navigateTo(newMode)
                            }
                        }
                    ))
                    .id("modeSelection")
                }
            }
            .transition(
                .asymmetric(
                    insertion: .move(edge: movesForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: movesForward ? .leading : .trailing).combined(with: .opacity)
                )
            )
            .animation(.smooth(duration: 0.26), value: mode)
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

                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Color.accentColor.opacity(0.22), radius: 18, x: 0, y: 10)
                    .accessibilityHidden(true)
            }
            .frame(width: 102, height: 92)

            Text("Welcome to SwiftBot")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text(stepSubtitle)
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

    // MARK: - Navigation

    private func navigateTo(_ newMode: SetupMode?) {
        movesForward = newMode != nil
        mode = newMode
    }

    // MARK: - Subtitle

    private var stepSubtitle: String {
        switch mode {
        case nil:
            return "How would you like to set up SwiftBot?"
        case .standalone:
            return "Enter your Discord bot token to get started."
        case .mesh:
            return "Enter your SwiftMesh connection details."
        case .remote:
            return "Connect to a primary SwiftBot node over HTTPS."
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingRootView()
        .environmentObject(AppModel())
        .frame(width: 800, height: 600)
}
