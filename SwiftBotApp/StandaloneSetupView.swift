import SwiftUI
import AppKit

// MARK: - Standalone Setup View

struct StandaloneSetupView: View {
    @EnvironmentObject var app: AppModel
    let onBack: () -> Void

    @State private var step: StandaloneStep = .entry
    @State private var inviteURL: String?
    @State private var inviteConfirmed: Bool = false
    @State private var isLoadingInviteURL: Bool = false
    @State private var inviteLoadFailed: Bool = false
    @State private var errorMessage: String?

    private enum StandaloneStep {
        case entry, validating, proceedingToDashboard, confirmed, failed
    }

    private var errorMessageToShow: String? {
        if let msg = errorMessage { return msg }
        if let result = app.lastTokenValidationResult, !result.isValid { return result.errorMessage }
        return nil
    }

    var body: some View {
        VStack(spacing: 16) {
            // Error banner
            if let errorMsg = errorMessageToShow {
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

            switch step {
            case .entry, .failed:
                entryView
                    .transition(.opacity)
            case .validating:
                validatingView
                    .transition(.opacity)
            case .proceedingToDashboard:
                proceedingView
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
            // Glowing clipboard/token icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
            }
            
            VStack(spacing: 8) {
                Text("Connect Your Bot")
                    .font(.title2.weight(.bold))
                
                Text("Copy your bot token from the Discord Developer Portal, then click **Paste & Connect** below. SwiftBot will automatically configure and secure your connection.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 16)
            
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
                        if let url = URL(string: "https://discord.com/developers/applications") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Developer Portal", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.top, 4)
            }
        }
    }

    private var validatingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Validating token & connecting…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 200)
    }

    private var proceedingView: some View {
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
                if let username = app.lastTokenValidationResult?.username {
                    Text("Connected as \(username)!")
                        .font(.title3.weight(.bold))
                } else {
                    Text("Connected!")
                        .font(.title3.weight(.bold))
                }
                
                Text("Your bot is already in a server. Loading dashboard…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 200)
    }

    private var confirmedView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                if let username = app.lastTokenValidationResult?.username {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connected as **\(username)**")
                    }
                    .font(.headline)
                }
                
                Text("We've automatically opened the Discord authorization page in your browser. Please invite the bot to your server, then click below to enter.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 16)

            if isLoadingInviteURL {
                loadingInviteView
            } else if inviteLoadFailed {
                failedInviteView
            }

            if let url = inviteURL {
                inviteLinkView(url: url)

                Toggle(isOn: $inviteConfirmed) {
                    Text("I have invited SwiftBot already")
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .frame(maxWidth: 520, alignment: .center)
            }

            Button { app.completeOnboarding() } label: {
                Label("Go to Dashboard", systemImage: "arrow.right.circle.fill")
                    .font(.headline)
                    .frame(minWidth: 200)
            }
            .onboardingGlassButton()
            .disabled(inviteURL != nil && !inviteConfirmed)
        }
        .task {
            if inviteURL == nil {
                isLoadingInviteURL = true
                inviteURL = await app.generateInviteURL()
                isLoadingInviteURL = false
                inviteLoadFailed = (inviteURL == nil)
            }
        }
    }

    private var loadingInviteView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Generating invite link…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Generating invite link, please wait")
    }

    private var failedInviteView: some View {
        Text("Could not generate an invite link. Your bot's client ID may not be available yet — you can invite the bot manually from the Discord Developer Portal.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 560)
    }

    private func inviteLinkView(url: String) -> some View {
        VStack(spacing: 8) {
            Text("Invite your bot to a server:")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    Label("Copy Invite Link", systemImage: "doc.on.doc")
                }
                .onboardingGlassButton()
                .accessibilityHint("Copies the bot invite link to your clipboard")

                Button {
                    if let u = URL(string: url) {
                        NSWorkspace.shared.open(u)
                    }
                } label: {
                    Label("Open Invite", systemImage: "arrow.up.right.square")
                }
                .onboardingGlassButton()
                .accessibilityHint("Opens the Discord bot authorization page in your browser")
            }
        }
        .padding(12)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    // MARK: - Helpers

    @Environment(\.colorScheme) private var colorScheme

    private var colorSchemeIntensity: Double {
        colorScheme == .dark ? 0.08 : 0.04
    }

    private func handlePasteAndConnect() {
        let pasteboard = NSPasteboard.general
        guard let pastedToken = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pastedToken.isEmpty else {
            errorMessage = "Your clipboard is empty or does not contain text. Please copy your bot token first."
            step = .failed
            return
        }

        // Simple sanity check: Discord tokens are long and contain dots.
        guard pastedToken.contains(".") else {
            errorMessage = "The text in your clipboard does not look like a valid Discord bot token. Please check and copy the correct token."
            step = .failed
            return
        }

        app.settings.launchMode = .standaloneBot
        app.settings.token = pastedToken
        errorMessage = nil
        step = .validating

        Task {
            let ok = await app.validateAndOnboard()
            if ok {
                let inGuild = await app.checkBotInAnyGuild()
                if inGuild {
                    step = .proceedingToDashboard
                    // Show success state briefly then enter app
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run {
                        app.completeOnboarding()
                    }
                } else {
                    step = .confirmed
                    // Automatically open the invite link in browser if not in guild!
                    if let urlString = await app.generateInviteURL(), let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                step = .failed
            }
        }
    }
}

// MARK: - Preview

#Preview {
    StandaloneSetupView(onBack: {})
        .environmentObject(AppModel())
        .padding()
        .frame(width: 600, height: 400)
}
