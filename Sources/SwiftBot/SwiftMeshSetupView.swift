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
    @State private var shareRecordings = false
    @State private var pairingMessage: String?
    @State private var finishing = false
    @State private var pendingJoinCode: String?
    @State private var pairingProgress = ""

    private static let autoContinueSeconds = 10

    private enum MeshStep {
        case setup, review, testing, confirmed, failed
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
            case .review:
                reviewView
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
            ConsoleIconTile(symbol: "point.3.connected.trianglepath.dotted", size: 64)
            
            VStack(spacing: 8) {
                Text("Join SwiftMesh")
                    .font(.title2.weight(.bold))
                
                Text("Open your Primary’s Web Interface on this Mac, then choose **SwiftMesh → Pair SwiftBot**.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                Text("SwiftBot opens here to finish pairing. A copied Join Code can be pasted below.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
                if step == .failed, pendingJoinCode != nil {
                    Button("Retry Setup", action: pairBackup)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                Button {
                    handlePasteAndConnect()
                } label: {
                    Label("Paste Join Code", systemImage: "doc.on.clipboard.fill")
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
            shareRecordings = app.mediaLibrarySettings.sharedLibraryEnabled
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
            
            Text(pairingProgress)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(minHeight: 200)
    }

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set Up Backup").font(.title2.weight(.semibold))
            Text("SwiftBot will configure this Mac and sync the bot’s settings and credentials automatically.")
                .foregroundStyle(.secondary)
            if let bundle {
                LabeledContent("Primary", value: bundle.leaderAddresses.first ?? "Primary")
                if let witness = bundle.witness {
                    LabeledContent("Ruru", value: URL(string: witness.endpoint)?.host ?? witness.endpoint)
                    Text("Ruru is included. No separate code or setup is needed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            RecordingPairingOptions(enabled: $shareRecordings, ruruAvailable: bundle?.witness?.isValid == true)
            HStack {
                Button("Cancel") { pendingJoinCode = nil; step = .setup }
                Spacer()
                Button("Set Up Backup", action: pairBackup)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: 520)
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
                Text("Backup ready")
                    .font(.title3.weight(.bold))

                Text(pairingMessage ?? "Bot settings and credentials are synced.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let witness = bundle?.witness {
                    Label("Ownership witness: Ruru at \(URL(string: witness.endpoint)?.host ?? witness.endpoint)", systemImage: "checkmark.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)

            RecordingPairingOptions(enabled: $shareRecordings, ruruAvailable: bundle?.witness?.isValid == true)
                .disabled(finishing)
                .onChange(of: shareRecordings) { _, _ in cancelAutoContinue() }

            VStack(spacing: 8) {
                Button {
                    finishOnboarding()
                } label: {
                    Label(continueButtonTitle, systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                        .frame(minWidth: 220)
                }
                .onboardingGlassButton()
                .disabled(finishing)

                if autoContinueSecondsRemaining > 0 {
                    Button("Cancel auto-continue") {
                        cancelAutoContinue()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 200)
        .onAppear {
            if !shareRecordings { startAutoContinueCountdown() }
        }
        .onDisappear { autoContinueTask?.cancel() }
    }

    private var continueButtonTitle: String {
        autoContinueSecondsRemaining > 0
            ? "Continue (\(autoContinueSecondsRemaining))"
            : "Continue"
    }

    private func startAutoContinueCountdown() {
        autoContinueTask?.cancel()
        autoContinueSecondsRemaining = Self.autoContinueSeconds
        autoContinueTask = Task { @MainActor in
            while autoContinueSecondsRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                autoContinueSecondsRemaining -= 1
            }
            if !Task.isCancelled {
                finishOnboarding()
            }
        }
    }

    private func cancelAutoContinue() {
        autoContinueTask?.cancel()
        autoContinueTask = nil
        autoContinueSecondsRemaining = 0
    }

    private func finishOnboarding() {
        guard !finishing else { return }
        cancelAutoContinue()
        #if DEBUG
        if ScreenshotDemo.isRecordingOnboarding {
            app.mediaLibrarySettings.sharedLibraryEnabled = shareRecordings
            app.isOnboardingComplete = true
            if shareRecordings { app.requestedSidebarItem = .recordings }
            return
        }
        #endif
        finishing = true
        Task {
            guard await app.setRecordingSharingEnabled(shareRecordings) else {
                pairingMessage = "Could not save your recording sharing choice. Try Continue again."
                finishing = false
                return
            }
            // Pairing already persisted auto-start and started the passive
            // monitor. Do not start a second runtime from the Done button.
            app.isOnboardingComplete = true
            if shareRecordings { app.requestedSidebarItem = .recordings }
            finishing = false
        }
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
        #if DEBUG
        if ScreenshotDemo.isRecordingOnboarding {
            bundle = ScreenshotDemo.recordingPairingBundle
            shareRecordings = SwiftMeshJoinBundle.recordingSharingChoice(from: rawCode) ?? false
            pendingJoinCode = rawCode
            step = .review
            return
        }
        #endif
        errorMessage = nil

        do {
            let decoded = try app.decodeSwiftMeshJoinCode(rawCode)
            self.bundle = decoded
            if let choice = SwiftMeshJoinBundle.recordingSharingChoice(from: rawCode) { shareRecordings = choice }

            pendingJoinCode = rawCode
            step = .review
        } catch {
            errorMessage = error.localizedDescription
            step = .failed
        }
    }

    private func pairBackup() {
        guard let rawCode = pendingJoinCode else { return }
        #if DEBUG
        if ScreenshotDemo.isRecordingOnboarding {
            pairingMessage = "Backup ready. Ruru is connected, and bot settings and credentials are synced."
            step = .confirmed
            return
        }
        #endif
        step = .testing
        pairingMessage = nil
        Task {
            let result = await app.pairSwiftMeshFailover(rawCode, shareRecordings: shareRecordings) {
                pairingProgress = $0
            }
            pairingMessage = result.message
            errorMessage = result.ok ? nil : result.message
            step = result.ok ? .confirmed : .failed
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
