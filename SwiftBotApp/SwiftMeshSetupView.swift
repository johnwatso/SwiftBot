import SwiftUI
import AppKit

// MARK: - SwiftMesh Setup View

struct SwiftMeshSetupView: View {
    @EnvironmentObject var app: AppModel
    let onBack: () -> Void

    @State private var step: MeshStep = .setup
    @State private var errorMessage: String?
    @State private var bundle: SwiftMeshJoinBundle?
    @State private var autoContinueSecondsRemaining: Int = 0
    @State private var autoContinueTask: Task<Void, Never>?

    private static let autoContinueSeconds = 10

    private enum MeshStep {
        case setup, testing, confirmed, failed
    }

    var body: some View {
        Group {
            switch step {
            case .setup, .failed:
                entryView
                    .transition(.opacity)
            case .testing:
                testingView
                    .transition(.opacity)
            case .confirmed:
                confirmedView
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.22), value: step)
    }

    // MARK: - Subviews

    private var entryView: some View {
        VStack(spacing: 24) {
            // Glowing mesh icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
            }
            
            VStack(spacing: 8) {
                Text("Join SwiftMesh")
                    .font(.title2.weight(.bold))
                
                Text("Grab the Join Code from your Primary node — either from **SwiftMesh preferences** in the Mac app, or from the **SwiftMesh** tab in the Primary's WebUI (Copy or Open in SwiftBot). Then click **Paste & Connect** below. SwiftMesh tests both local and public WAN routes and saves the one that works.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 16)
            
            // Error banner if any
            if let errorMsg = errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connection Failed")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(errorMsg)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer()
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.red.opacity(colorSchemeIntensity))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
                )
                .frame(maxWidth: 520)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
            
            VStack(spacing: 12) {
                Button {
                    handlePasteAndConnect()
                } label: {
                    Label("Paste & Connect", systemImage: "doc.on.clipboard.fill")
                        .font(.headline)
                        .frame(minWidth: 220)
                }
                .buttonStyle(GlassActionButtonStyle())
                .controlSize(.large)
                
                HStack(spacing: 16) {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    
                    Text("•")
                        .foregroundStyle(.tertiary)
                    
                    Button {
                        app.settings.clusterMode = .standalone
                        app.saveSettings()
                        app.completeOnboarding()
                    } label: {
                        Label("Skip & Configure in Settings", systemImage: "arrow.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: 520)
        .onAppear {
            app.settings.launchMode = .swiftMeshClusterNode
            consumePendingDeepLinkCodeIfAny()
        }
        .onChange(of: app.pendingMeshOnboardingCode) { _, _ in
            consumePendingDeepLinkCodeIfAny()
        }
    }

    private var testingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            
            Text(app.workerConnectionTestStatus)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(minHeight: 200)
    }

    private var confirmedView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.green)
            }
            
            VStack(spacing: 8) {
                Text("SwiftMesh Paired!")
                    .font(.title3.weight(.bold))
                
                Text(app.workerConnectionTestStatus)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            
            Button {
                app.saveSettings()
                app.completeOnboarding()
            } label: {
                Label("Go to Dashboard", systemImage: "arrow.right.circle.fill")
                    .font(.headline)
                    .frame(minWidth: 200)
            }
            .onboardingGlassButton()
        }
        .frame(minHeight: 200)
    }

    // MARK: - Helpers

    @Environment(\.colorScheme) private var colorScheme

    private var colorSchemeIntensity: Double {
        colorScheme == .dark ? 0.08 : 0.04
    }

    private func handlePasteAndConnect() {
        let pasteboard = NSPasteboard.general
        guard let rawCode = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawCode.isEmpty else {
            errorMessage = "Your clipboard is empty. Please copy a valid SwiftMesh join code first."
            step = .failed
            return
        }

        guard rawCode.contains("swiftmesh://join") || rawCode.count > 50 else {
            errorMessage = "The text in your clipboard does not look like a valid SwiftMesh join code."
            step = .failed
            return
        }

        applyJoinCode(rawCode)
    }

    /// If a `swiftmesh://join` deep link arrived before this view appeared,
    /// auto-run the same flow as Paste & Connect using the deep-link code.
    private func consumePendingDeepLinkCodeIfAny() {
        guard let raw = app.pendingMeshOnboardingCode else { return }
        app.pendingMeshOnboardingCode = nil
        applyJoinCode(raw)
    }

    private func applyJoinCode(_ rawCode: String) {
        errorMessage = nil

        do {
            let decoded = try app.decodeSwiftMeshJoinCode(rawCode)
            self.bundle = decoded

            let result = app.applySwiftMeshJoinCode(rawCode)
            guard result.ok else {
                errorMessage = result.message
                step = .failed
                return
            }

            step = .testing

            Task {
                let success = await app.testWorkerJoinCodeConnection(
                    addresses: decoded.leaderAddresses,
                    port: decoded.leaderPort
                )

                await MainActor.run {
                    step = success ? .confirmed : .failed
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            step = .failed
        }
    }
}

// MARK: - Preview

#Preview {
    SwiftMeshSetupView(onBack: {})
        .environmentObject(AppModel())
        .padding()
        .frame(width: 600, height: 400)
}
