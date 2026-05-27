import SwiftUI
import AppKit

struct GeneralPreferencesView: View {
    @EnvironmentObject var app: AppModel

    @State private var showRunSetupPrompt = false
    @State private var showToken = false
    @State private var transientToastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var inviteActionInProgress = false
    @State private var showingClearTokenConfirmation = false
    @State private var showingPermissionsCheck = false

    private var canGenerateInviteLink: Bool {
        !app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var recordingsSummary: String {
        let sources = app.mediaLibrarySettings.sources
        if sources.isEmpty { return "No folders configured" }
        let enabled = sources.filter(\.isEnabled).count
        return "\(enabled) of \(sources.count) enabled"
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
                ? "Read-only on Failover nodes. These settings sync from Primary."
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
            }

            Section {
                LabeledContent("Bot Token") {
                    HStack(spacing: 6) {
                        Group {
                            if showToken {
                                TextField("Token", text: $app.settings.token)
                            } else {
                                SecureField("Token", text: $app.settings.token)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 220)

                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showToken ? "Hide token" : "Show token")

                        if !app.settings.token.isEmpty {
                            Button {
                                showingClearTokenConfirmation = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove token")
                        }
                    }
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
        }
        .alert("Remove Bot Token?", isPresented: $showingClearTokenConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                app.settings.token = ""
            }
        } message: {
            Text("Removing the token will disconnect SwiftBot from Discord until a new token is entered.")
        }
        .sheet(isPresented: $showingPermissionsCheck) {
            BotPermissionsCheckView(token: app.settings.token)
        }
        .preferencesCardDisabled(when: app.isFailoverManagedNode)
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
