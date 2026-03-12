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
    
    @State private var mode: SetupMode?
    @State private var movesForward: Bool = true
    
    var body: some View {
        ZStack {
            SwiftBotGlassBackground()
            OnboardingAnimatedSymbolBackground()
                .allowsHitTesting(false)
            
            VStack(spacing: 32) {
                // Icon + title (always visible)
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .accessibilityHidden(true)
                    
                    Text("Welcome to SwiftBot")
                        .font(.largeTitle.weight(.bold))
                    
                    Text(stepSubtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                // Step content
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
                                if let newMode = newMode {
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
            .padding(48)
        }
        .ignoresSafeArea()
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
