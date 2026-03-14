import SwiftUI

// MARK: - Standalone Setup View

struct StandaloneSetupView: View {
    @EnvironmentObject var app: AppModel
    let onBack: () -> Void

    @State private var tokenInput: String = ""
    @State private var showToken: Bool = false
    @State private var step: StandaloneStep = .entry
    @State private var inviteURL: String?
    @State private var inviteConfirmed: Bool = false
    @State private var isLoadingInviteURL: Bool = false
    @State private var inviteLoadFailed: Bool = false

    private enum StandaloneStep {
        case entry, validating, confirmed, failed
    }

    var body: some View {
        VStack(spacing: 16) {
            // Token field
            HStack {
                Group {
                    if showToken {
                        TextField("Bot token", text: $tokenInput)
                    } else {
                        SecureField("Bot token", text: $tokenInput)
                    }
                }
                .onboardingTextFieldStyle()
                .font(.system(.body, design: .monospaced))
                .disabled(step == .validating || step == .confirmed)

                Button {
                    showToken.toggle()
                } label: {
                    Image(systemName: showToken ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showToken ? "Hide token" : "Show token")
            }
            .frame(maxWidth: 560)

            // Error
            if step == .failed, let result = app.lastTokenValidationResult {
                Text(result.errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            // Actions
            switch step {
            case .entry, .failed:
                actionButtons
            case .validating:
                validatingView
            case .confirmed:
                confirmedView
            }
        }
        .onAppear {
            tokenInput = app.settings.token
        }
    }

    // MARK: - Subviews

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                app.settings.launchMode = .standaloneBot
                app.settings.token = tokenInput
                step = .validating
                Task {
                    let ok = await app.validateAndOnboard()
                    step = ok ? .confirmed : .failed
                }
            } label: {
                Label("Validate Token", systemImage: "checkmark.shield.fill")
                    .frame(minWidth: 200)
            }
            .buttonStyle(GlassActionButtonStyle())
            .controlSize(.large)
            .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var validatingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Validating…")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Validating token, please wait")
    }

    private var confirmedView: some View {
        VStack(spacing: 16) {
            if let result = app.lastTokenValidationResult {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Connected as **\(result.username ?? "Bot")**")
                }
                .font(.body)
            }

            // Invite link states
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
                .frame(maxWidth: 560, alignment: .center)
            }

            Button { app.completeOnboarding() } label: {
                Label("Go to Dashboard", systemImage: "arrow.right.circle.fill")
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
}

// MARK: - Preview

#Preview {
    StandaloneSetupView(onBack: {})
        .environmentObject(AppModel())
        .padding()
        .frame(width: 600, height: 400)
}
