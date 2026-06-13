import SwiftUI
import AppKit

struct GeneralPreferencesView: View {
    @EnvironmentObject var app: AppModel

    @State private var showRunSetupPrompt = false
    @State private var transientToastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var inviteActionInProgress = false
    @State private var showingClearTokenConfirmation = false
    @State private var showingPermissionsCheck = false
    @State private var isVerifyingToken = false
    @State private var tokenVerifyError: String?

    private var canGenerateInviteLink: Bool {
        !app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusTint: Color {
        if !canGenerateInviteLink { return .secondary }
        switch app.status {
        case .running: return .green
        case .connecting, .reconnecting: return .orange
        case .stopped: return .secondary
        }
    }

    private var statusTitle: String {
        if !canGenerateInviteLink { return "Not configured" }
        switch app.status {
        case .running: return "Connected to Discord"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .stopped: return "Bot stopped"
        }
    }

    private var statusSubtitle: String {
        if !canGenerateInviteLink {
            return "Add a Discord bot token below to get started."
        }
        return app.status == .running
            ? "Auto-start is \(app.settings.autoStart ? "on" : "off")."
            : "Use the toolbar to start the bot."
    }

    var body: some View {
        SettingsForm(
            readOnlyBannerText: app.isFailoverManagedNode
                ? "Bot settings are read-only on Failover nodes. Recording folders stay local to this Mac."
                : nil
        ) {
            Section {
                SettingsStatusRow(
                    systemImage: app.status == .running ? "checkmark.circle.fill" : "bolt.horizontal.circle",
                    tint: statusTint,
                    title: statusTitle,
                    subtitle: statusSubtitle
                ) {
                    Toggle("", isOn: $app.settings.autoStart)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help(app.settings.autoStart ? "Disable auto-start" : "Enable auto-start")
                }

                Picker("Show SwiftBot as", selection: $app.settings.presenceMode) {
                    ForEach(AppPresenceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }
            .preferencesCardDisabled(when: app.isFailoverManagedNode)

            Section {
                LabeledContent("Bot Token") {
                    botTokenControl
                }

                LabeledContent("Invite Bot") {
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
            } header: {
                Text("Discord")
            } footer: {
                if !canGenerateInviteLink {
                    Text("Create a bot in the Discord Developer Portal and paste its token to enable these actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .preferencesCardDisabled(when: app.isFailoverManagedNode)

            LocalRecordingsPreferencesSection()

            Section {
                Button {
                    showRunSetupPrompt = true
                } label: {
                    Label("Run Setup Wizard…", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .confirmationDialog(
                    "Run setup again?",
                    isPresented: $showRunSetupPrompt,
                    titleVisibility: .visible
                ) {
                    Button("Start Setup", role: .destructive) { app.isOnboardingComplete = false }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Returns you to the initial configuration screens. Existing settings are preserved.")
                }
            } header: {
                Text("Setup")
            }
            .preferencesCardDisabled(when: app.isFailoverManagedNode)
        }
        .alert("Replace Bot Token?", isPresented: $showingClearTokenConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) {
                app.settings.token = ""
                app.settings.cachedBotIdentity = CachedBotIdentity()
                tokenVerifyError = nil
            }
        } message: {
            Text("Clears the saved token so you can paste a new one. SwiftBot will disconnect from Discord until a new token is verified.")
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
        if app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                    showingClearTokenConfirmation = true
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

        let previousToken = app.settings.token
        app.settings.token = normalized

        let ok = await app.validateAndOnboard()
        if ok {
            showToast("Token verified")
        } else {
            app.settings.token = previousToken
            tokenVerifyError = app.lastTokenValidationResult?.errorMessage
                ?? "Discord rejected this token."
        }
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

struct LocalRecordingsPreferencesSection: View {
    @EnvironmentObject private var app: AppModel

    private var recordingsSummary: String {
        let sources = app.mediaLibrarySettings.sources
        if sources.isEmpty { return "No folders configured" }
        let enabled = sources.filter(\.isEnabled).count
        return "\(enabled) of \(sources.count) enabled"
    }

    var body: some View {
        Section {
            LabeledContent("Recordings") {
                Text(recordingsSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach($app.mediaLibrarySettings.sources) { $source in
                RecordingSourceRow(source: $source) {
                    app.mediaLibrarySettings.sources.removeAll { $0.id == source.id }
                }
            }

            Button {
                app.mediaLibrarySettings.sources.append(MediaLibrarySource())
            } label: {
                Label("Add Folder", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        } header: {
            Text("Recordings")
        } footer: {
            Text("Folders are local to this Mac and surfaced inside the shared Web UI media browser.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RecordingSourceRow: View {
    @Binding var source: MediaLibrarySource
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $source.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Source name", text: $source.name)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    TextField("/Volumes/NAS/GameCaptures", text: $source.rootPath)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 6)

            Button {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "Choose"
                if panel.runModal() == .OK, let url = panel.url {
                    source.rootPath = url.path
                }
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Choose folder")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove folder")
        }
    }
}
