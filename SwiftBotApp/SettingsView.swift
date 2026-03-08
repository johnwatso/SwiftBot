import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var updater: AppUpdater
    @Binding var showToken: Bool
    @State private var settingsSnapshot = GeneralSettingsSnapshot()
    @State private var showSettingsUpdatedToast = false
    @State private var settingsToastTask: Task<Void, Never>?
    @State private var showRunSetupPrompt = false

    private var hasUnsavedChanges: Bool {
        currentSettingsSnapshot != settingsSnapshot
    }

    private var currentSettingsSnapshot: GeneralSettingsSnapshot {
        GeneralSettingsSnapshot(
            token: app.settings.token,
            autoStart: app.settings.autoStart,
            clusterMode: app.settings.clusterMode,
            clusterNodeName: app.settings.clusterNodeName,
            clusterLeaderAddress: app.settings.clusterLeaderAddress,
            clusterListenPort: app.settings.clusterListenPort,
            clusterSharedSecret: app.settings.clusterSharedSecret,
            adminWebEnabled: app.settings.adminWebUI.enabled,
            adminWebHost: app.settings.adminWebUI.bindHost,
            adminWebPort: app.settings.adminWebUI.port,
            adminWebBaseURL: app.settings.adminWebUI.publicBaseURL,
            adminDiscordClientID: app.settings.adminWebUI.discordClientID,
            adminDiscordClientSecret: app.settings.adminWebUI.discordClientSecret,
            adminAllowedUserIDs: app.settings.adminWebUI.allowedUserIDs.joined(separator: ", "),
            bugAutoFixEnabled: app.settings.bugAutoFixEnabled,
            bugAutoFixTriggerEmoji: app.settings.bugAutoFixTriggerEmoji,
            bugAutoFixCommandTemplate: app.settings.bugAutoFixCommandTemplate,
            bugAutoFixRepoPath: app.settings.bugAutoFixRepoPath,
            bugAutoFixGitBranch: app.settings.bugAutoFixGitBranch,
            bugAutoFixVersionBumpEnabled: app.settings.bugAutoFixVersionBumpEnabled,
            bugAutoFixPushEnabled: app.settings.bugAutoFixPushEnabled,
            bugAutoFixRequireApproval: app.settings.bugAutoFixRequireApproval,
            bugAutoFixApproveEmoji: app.settings.bugAutoFixApproveEmoji,
            bugAutoFixRejectEmoji: app.settings.bugAutoFixRejectEmoji,
            bugAutoFixAllowedUsernames: app.settings.bugAutoFixAllowedUsernames.joined(separator: ", ")
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewSectionHeader(title: "Settings", symbol: "gearshape.2.fill")

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Discord Authentication", symbol: "person.badge.key.fill")

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Bot Token")
                            .font(.subheadline.weight(.medium))
                        HStack {
                            if showToken {
                                TextField("Token", text: $app.settings.token)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("Token", text: $app.settings.token)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button { showToken.toggle() } label: {
                                Image(systemName: showToken ? "eye.slash" : "eye")
                            }
                        }
                        Text("Obtain this from the Discord Developer Portal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Toggle("Start Bot Automatically", isOn: $app.settings.autoStart)
                        .toggleStyle(.switch)
                }
                .padding(16)
                .commandCatalogSurface(cornerRadius: 22)

                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Deployment", symbol: "wrench.and.screwdriver.fill")

                    Button {
                        showRunSetupPrompt = true
                    } label: {
                        Label("Run Setup Wizard…", systemImage: "magicmouse")
                    }
                    .buttonStyle(.bordered)
                    .confirmationDialog(
                        "Run setup again?",
                        isPresented: $showRunSetupPrompt,
                        titleVisibility: .visible
                    ) {
                        Button("Start Setup", role: .destructive) { app.isOnboardingComplete = false }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will take you back to the initial configuration screens.")
                    }
                }
                .padding(16)
                .commandCatalogSurface(cornerRadius: 22)

                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("SwiftMesh", symbol: "point.3.connected.trianglepath.dotted")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Role")
                            .font(.subheadline.weight(.medium))
                        Picker("Role", selection: $app.settings.clusterMode) {
                            ForEach(ClusterMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        Text(app.settings.clusterMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Node Name")
                            .font(.subheadline.weight(.medium))
                        TextField("SwiftBot Node", text: $app.settings.clusterNodeName)
                            .textFieldStyle(.roundedBorder)
                    }

                    if app.settings.clusterMode == .worker || app.settings.clusterMode == .standby {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(app.settings.clusterMode == .standby ? "Primary Address" : "Leader Address")
                                .font(.subheadline.weight(.medium))
                            TextField("http://host:port", text: $app.settings.clusterLeaderAddress)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Listen Port")
                            .font(.subheadline.weight(.medium))
                        Stepper(value: $app.settings.clusterListenPort, in: 1...65535) {
                            Text("\(app.settings.clusterListenPort)")
                                .font(.body.monospacedDigit())
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shared Secret")
                            .font(.subheadline.weight(.medium))
                        SecureField("Required for clustered mode", text: $app.settings.clusterSharedSecret)
                            .textFieldStyle(.roundedBorder)
                    }

                    if app.settings.clusterMode == .worker || app.settings.clusterMode == .standby {
                        HStack(spacing: 10) {
                            Button {
                                app.testWorkerLeaderConnection()
                            } label: {
                                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                            }
                            .buttonStyle(GlassActionButtonStyle())
                            .disabled(app.workerConnectionTestInProgress)

                            Button {
                                app.refreshClusterStatus()
                            } label: {
                                Label("Refresh Status", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(GlassActionButtonStyle())
                        }

                        if app.workerConnectionTestInProgress {
                            ProgressView("Testing connection…")
                                .controlSize(.small)
                        } else {
                            Text(app.workerConnectionTestStatus)
                                .font(.caption)
                                .foregroundStyle(app.workerConnectionTestIsSuccess ? .green : .secondary)
                        }
                    }
                }
                .padding(16)
                .commandCatalogSurface(cornerRadius: 22)

                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Web UI", symbol: "safari.fill")

                    Toggle("Enable Admin Web UI", isOn: $app.settings.adminWebUI.enabled)
                        .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bind Host")
                            .font(.subheadline.weight(.medium))
                        TextField("127.0.0.1", text: $app.settings.adminWebUI.bindHost)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Port")
                            .font(.subheadline.weight(.medium))
                        Stepper(value: $app.settings.adminWebUI.port, in: 1...65535) {
                            Text("\(app.settings.adminWebUI.port)")
                                .font(.body.monospacedDigit())
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Public Base URL (optional)")
                            .font(.subheadline.weight(.medium))
                        TextField("https://admin.example.com", text: $app.settings.adminWebUI.publicBaseURL)
                            .textFieldStyle(.roundedBorder)
                        Text("Leave empty to use http://\(app.settings.adminWebUI.bindHost):\(app.settings.adminWebUI.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Discord OAuth Client ID")
                            .font(.subheadline.weight(.medium))
                        TextField("123456789012345678", text: $app.settings.adminWebUI.discordClientID)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Discord OAuth Client Secret")
                            .font(.subheadline.weight(.medium))
                        SecureField("Client Secret", text: $app.settings.adminWebUI.discordClientSecret)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Allowed User IDs")
                            .font(.subheadline.weight(.medium))
                        TextField("Comma-separated Discord user IDs", text: Binding(
                            get: { app.settings.adminWebUI.allowedUserIDs.joined(separator: ", ") },
                            set: { newValue in
                                app.settings.adminWebUI.allowedUserIDs = newValue
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Text("If empty, only users who are in connected guilds and have Manage Server can log in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .commandCatalogSurface(cornerRadius: 22)

                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Bug Auto-Fix", symbol: "sparkles")

                    Toggle("Enable auto-fix from bug reactions", isOn: $app.settings.bugAutoFixEnabled)
                        .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Trigger Emoji")
                            .font(.subheadline.weight(.medium))
                        TextField("🤖", text: $app.settings.bugAutoFixTriggerEmoji)
                            .textFieldStyle(.roundedBorder)
                        Text("React with this emoji on a tracked bug message to trigger Codex automation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Codex Command Template")
                            .font(.subheadline.weight(.medium))
                        TextField("codex exec \"$SWIFTBOT_BUG_PROMPT\"", text: $app.settings.bugAutoFixCommandTemplate)
                            .textFieldStyle(.roundedBorder)
                        Text("Environment variables: SWIFTBOT_BUG_PROMPT, SWIFTBOT_BUG_CONTEXT_FILE, SWIFTBOT_REPO_PATH, SWIFTBOT_BUG_MESSAGE_ID, SWIFTBOT_BUG_CHANNEL_ID, SWIFTBOT_BUG_GUILD_ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Repository Path (optional)")
                            .font(.subheadline.weight(.medium))
                        TextField("/Users/max/Developer/SwiftBot", text: $app.settings.bugAutoFixRepoPath)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Git Branch")
                                .font(.subheadline.weight(.medium))
                            TextField("main", text: $app.settings.bugAutoFixGitBranch)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("Version and build are read from bug-thread comments (for example: `version=1.8.19 build=181900`).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Auto push to GitHub", isOn: $app.settings.bugAutoFixPushEnabled)
                        .toggleStyle(.switch)
                    Toggle("Require approval before push", isOn: $app.settings.bugAutoFixRequireApproval)
                        .toggleStyle(.switch)
                        .disabled(!app.settings.bugAutoFixPushEnabled)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Approve Emoji")
                                .font(.subheadline.weight(.medium))
                            TextField("🚀", text: $app.settings.bugAutoFixApproveEmoji)
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Reject Emoji")
                                .font(.subheadline.weight(.medium))
                            TextField("🛑", text: $app.settings.bugAutoFixRejectEmoji)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Allowed Usernames (optional)")
                            .font(.subheadline.weight(.medium))
                        TextField(
                            "Comma-separated usernames; leave blank for no restriction",
                            text: Binding(
                                get: { app.settings.bugAutoFixAllowedUsernames.joined(separator: ", ") },
                                set: { raw in
                                    app.settings.bugAutoFixAllowedUsernames = raw
                                        .split(separator: ",")
                                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                                        .filter { !$0.isEmpty }
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Auto-Fix Console")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(app.bugAutoFixStatusText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Button("Clear") {
                                app.bugAutoFixConsoleText = ""
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                        }
                        ScrollView {
                            Text(app.bugAutoFixConsoleText.isEmpty ? "No output yet." : app.bugAutoFixConsoleText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .frame(minHeight: 140, maxHeight: 200)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                        )
                    }
                }
                .padding(16)
                .commandCatalogSurface(cornerRadius: 22)

                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Software Updates", symbol: "arrow.triangle.2.circlepath")

                    HStack(spacing: 8) {
                        updateChannelOption(.stable)
                        updateChannelOption(.beta)
                    }

                    if updater.selectedChannel == .beta {
                        Label("Beta channel enabled. Updates will come from the beta appcast feed.", systemImage: "flask.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Button("Check for Updates...") {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(GlassActionButtonStyle())
                    .disabled(!updater.canCheckForUpdates)

                    if !updater.isConfigured {
                        Text("Set `SUFeedURL` and `SUPublicEDKey` in the app target build settings to enable Sparkle updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .commandCatalogSurface(cornerRadius: 22)
            }
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .overlay(alignment: .bottomTrailing) {
            if hasUnsavedChanges {
                StickySaveButton(label: "Save Settings", systemImage: "square.and.arrow.down.fill") {
                    app.saveSettings()
                    settingsSnapshot = currentSettingsSnapshot
                }
                .padding(.trailing, 22)
                .padding(.bottom, 18)
            }
        }
        .onAppear {
            settingsSnapshot = currentSettingsSnapshot
        }
    }

    @ViewBuilder
    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label {
            Text(title)
                .font(.headline)
        } icon: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func updateChannelOption(_ channel: AppUpdater.UpdateChannel) -> some View {
        let isSelected = updater.selectedChannel == channel
        Button {
            updater.setUpdateChannel(channel)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: channel.symbolName)
                Text(channel.label)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? .white.opacity(0.42) : .white.opacity(0.18), lineWidth: isSelected ? 1.4 : 1)
        )
    }
}

private struct GeneralSettingsSnapshot: Equatable {
    var token = ""
    var autoStart = false
    var clusterMode: ClusterMode = .standalone
    var clusterNodeName = ""
    var clusterLeaderAddress = ""
    var clusterListenPort = 38787
    var clusterSharedSecret = ""
    var adminWebEnabled = false
    var adminWebHost = ""
    var adminWebPort = 38888
    var adminWebBaseURL = ""
    var adminDiscordClientID = ""
    var adminDiscordClientSecret = ""
    var adminAllowedUserIDs = ""
    var bugAutoFixEnabled = false
    var bugAutoFixTriggerEmoji = "🤖"
    var bugAutoFixCommandTemplate = "codex exec \"$SWIFTBOT_BUG_PROMPT\""
    var bugAutoFixRepoPath = ""
    var bugAutoFixGitBranch = "main"
    var bugAutoFixVersionBumpEnabled = true
    var bugAutoFixPushEnabled = true
    var bugAutoFixRequireApproval = true
    var bugAutoFixApproveEmoji = "🚀"
    var bugAutoFixRejectEmoji = "🛑"
    var bugAutoFixAllowedUsernames = ""
}
