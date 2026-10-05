import AppKit
import SwiftUI

struct DiscordPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @State private var transientToastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var inviteActionInProgress = false
    @State private var isReplacingToken = false
    @State private var showingPermissionsCheck = false
    @State private var showingTokenEditor = false
    @State private var isVerifyingToken = false
    @State private var tokenVerifyError: String?

    private var canGenerateInviteLink: Bool {
        !app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SettingsForm(readOnlyBannerText: app.isFailoverManagedNode
            ? "Discord settings are managed by the Primary node." : nil) {
            Section {
                ConsoleSettingRow(title: "Bot Token", symbol: "key") {
                    HStack(spacing: 8) {
                        Text(canGenerateInviteLink ? "Configured" : "Not configured")
                            .foregroundStyle(.secondary)
                        Button(canGenerateInviteLink ? "Manage…" : "Add…") { showingTokenEditor = true }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                }

                ConsoleSettingRow(title: "Invite Bot", symbol: "person.badge.plus") {
                    HStack(spacing: 6) {
                        SettingsInlineAction("Copy Link", systemImage: "doc.on.doc") {
                            Task { await copyInviteLink() }
                        }
                        .disabled(!canGenerateInviteLink || inviteActionInProgress)

                        SettingsInlineAction("Open", systemImage: "arrow.up.right.square") {
                            Task { await openInviteLink() }
                        }
                        .disabled(!canGenerateInviteLink || inviteActionInProgress)

                        SettingsInlineAction("Check Permissions", systemImage: "checkmark.shield") {
                            showingPermissionsCheck = true
                        }
                        .disabled(!canGenerateInviteLink)
                    }
                }

                ConsoleSettingRow(
                    title: "Connect at Launch",
                    symbol: "power",
                    subtitle: "Start the bot when SwiftBot opens."
                ) {
                    ConsoleRowSwitch(isOn: $app.settings.autoStart)
                }
            } header: {
                Text("Bot")
            } footer: {
                if !canGenerateInviteLink {
                    Text("Create a bot in the Discord Developer Portal and paste its token to enable these actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .preferencesCardDisabled(when: app.isFailoverManagedNode)

        }
        .sheet(isPresented: $showingTokenEditor, onDismiss: resetTokenEditor) {
            VStack(alignment: .leading, spacing: 20) {
                Label("Discord Bot Token", systemImage: "key.fill")
                    .font(.title2.weight(.semibold))
                Text("Stored securely in your macOS Keychain. Copy a bot token from the Discord Developer Portal to paste and verify it here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                botTokenControl
                if isReplacingToken {
                    Label("The current token stays in use until Discord accepts the new one. SwiftBot then reconnects with it.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    if isReplacingToken {
                        Button("Cancel", role: .cancel) { resetTokenEditor() }
                            .keyboardShortcut(.cancelAction)
                            .disabled(isVerifyingToken)
                    } else {
                        Button("Done") { showingTokenEditor = false }
                            .keyboardShortcut(.cancelAction)
                            .disabled(isVerifyingToken)
                    }
                }
            }
            .padding(24)
            .frame(width: 520)
            .interactiveDismissDisabled(isVerifyingToken)
        }
        .sheet(isPresented: $showingPermissionsCheck) {
            BotPermissionsCheckView(token: app.settings.token)
        }
        .overlay(alignment: .topTrailing) {
            if let transientToastMessage {
                Text(transientToastMessage)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    )
                    .padding(.trailing, 18)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var botTokenControl: some View {
        if isReplacingToken || app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 8) {
                Button {
                    Task { await pasteAndVerifyToken() }
                } label: {
                    HStack(spacing: 6) {
                        if isVerifyingToken {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "doc.on.clipboard")
                        }
                        Text(isVerifyingToken ? "Verifying…" : "Paste & Verify Token")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isVerifyingToken)

                if let tokenVerifyError {
                    Text(tokenVerifyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(verifiedTokenLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                Button("Replace…") {
                    tokenVerifyError = nil
                    isReplacingToken = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var verifiedTokenLabel: String {
        let cached = app.settings.cachedBotIdentity.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cached.isEmpty ? "Token saved" : "Verified as @\(cached)"
    }

    private func pasteAndVerifyToken() async {
        guard !isVerifyingToken else { return }
        tokenVerifyError = nil

        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let normalized = app.normalizedDiscordToken(from: clipboard)
        guard !normalized.isEmpty else {
            tokenVerifyError = "Clipboard is empty. Copy your bot token first."
            return
        }

        isVerifyingToken = true
        defer { isVerifyingToken = false }

        // The saved token is only replaced once Discord accepts the new one.
        if await app.replaceBotToken(with: normalized) {
            isReplacingToken = false
            showToast("Token verified")
        } else {
            tokenVerifyError = app.lastTokenValidationResult?.errorMessage
                ?? "Discord rejected this token."
        }
    }

    private func resetTokenEditor() {
        isReplacingToken = false
        tokenVerifyError = nil
    }

    private func copyInviteLink() async {
        guard let inviteURL = await resolveInviteURL() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(inviteURL, forType: .string)
        showToast("Invite link copied")
    }

    private func openInviteLink() async {
        guard let inviteURL = await resolveInviteURL(),
              let url = URL(string: inviteURL)
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func resolveInviteURL() async -> String? {
        guard canGenerateInviteLink else {
            showToast("Bot token required to generate invite link")
            return nil
        }

        inviteActionInProgress = true
        defer { inviteActionInProgress = false }

        let inviteURL = await app.generateInviteURL()
        if inviteURL == nil {
            showToast("Unable to generate invite link")
        }
        return inviteURL
    }

    private func showToast(_ message: String) {
        toastDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            transientToastMessage = message
        }
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    transientToastMessage = nil
                }
            }
        }
    }
}
