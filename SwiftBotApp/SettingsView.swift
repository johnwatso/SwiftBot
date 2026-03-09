import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var updater: AppUpdater
    @Binding var showToken: Bool
    @AppStorage("settings.swiftmesh.expanded.v1") private var isSwiftMeshExpanded = false
    @AppStorage("settings.webui.expanded.v1") private var isWebUIExpanded = false
    @State private var settingsSnapshot = GeneralSettingsSnapshot()
    @State private var transientToastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var inviteActionInProgress = false
    @State private var showRunSetupPrompt = false

    private var hasUnsavedChanges: Bool {
        currentSettingsSnapshot != settingsSnapshot
    }

    private var isFailoverManagedNode: Bool {
        app.settings.clusterMode == .worker || app.settings.clusterMode == .standby
    }

    private var canEditOffloadPolicy: Bool {
        app.settings.clusterMode == .leader
    }

    private var canGenerateInviteLink: Bool {
        !app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var developerFeaturesBinding: Binding<Bool> {
        Binding(
            get: { app.settings.devFeaturesEnabled },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    app.settings.devFeaturesEnabled = newValue
                }
            }
        )
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
            adminWebHTTPSEnabled: app.settings.adminWebUI.httpsEnabled,
            adminWebCertificateMode: app.settings.adminWebUI.certificateMode,
            adminWebHostname: app.settings.adminWebUI.hostname,
            adminWebCloudflareToken: app.settings.adminWebUI.cloudflareAPIToken,
            adminWebPublicAccessEnabled: app.settings.adminWebUI.publicAccessEnabled,
            adminWebImportedCertificateFile: app.settings.adminWebUI.importedCertificateFile,
            adminWebImportedPrivateKeyFile: app.settings.adminWebUI.importedPrivateKeyFile,
            adminWebImportedCertificateChainFile: app.settings.adminWebUI.importedCertificateChainFile,
            adminRestrictSpecificUsers: app.settings.adminWebUI.restrictAccessToSpecificUsers,
            adminDiscordClientID: app.settings.adminWebUI.discordClientID,
            adminDiscordClientSecret: app.settings.adminWebUI.discordClientSecret,
            adminAllowedUserIDs: app.settings.adminWebUI.allowedUserIDs.joined(separator: ", "),
            devFeaturesEnabled: app.settings.devFeaturesEnabled,
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

    private var swiftMeshSummaryLines: [String] {
        let role = app.settings.clusterMode == .standalone ? "Disabled" : app.settings.clusterMode.displayName
        return ["Cluster role: \(role)"]
    }

    private var webUISummaryLines: [String] {
        var lines = [
            "Admin Web UI \(app.settings.adminWebUI.enabled ? "Enabled" : "Disabled")",
            "Port: \(app.settings.adminWebUI.port)"
        ]
        if app.settings.adminWebUI.httpsEnabled {
            switch app.settings.adminWebUI.certificateMode {
            case .automatic:
                let domain = app.settings.adminWebUI.normalizedHostname
                lines.append(domain.isEmpty ? "HTTPS automatic setup pending" : "HTTPS via Let's Encrypt for \(domain)")
            case .importCertificate:
                let certificatePath = app.settings.adminWebUI.normalizedImportedCertificateFile
                lines.append(certificatePath.isEmpty ? "HTTPS imported certificate pending" : "HTTPS via imported PEM")
            }
        }
        if app.settings.adminWebUI.publicAccessEnabled {
            let hostname = app.settings.adminWebUI.normalizedHostname
            lines.append(hostname.isEmpty ? "Public Access setup pending" : "Public Access via Cloudflare Tunnel for \(hostname)")
        }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewSectionHeader(title: "Settings", symbol: "gearshape.2.fill")
            if isFailoverManagedNode {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(.orange)
                    Text("This node is in Failover mode. Non‑SwiftMesh settings are synced from Primary and are read-only here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Invite Bot")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button {
                                Task { await copyInviteLink() }
                            } label: {
                                Label("Copy Invite Link", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                Task { await openInviteLink() }
                            } label: {
                                Label("Open Invite Link", systemImage: "arrow.up.forward.square")
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(!canGenerateInviteLink || inviteActionInProgress)

                        if !canGenerateInviteLink {
                            Text("Bot token required to generate invite link.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    Toggle("Start Bot Automatically", isOn: $app.settings.autoStart)
                        .toggleStyle(.switch)
                }
                .padding(16)
                .commandCatalogSurface(cornerRadius: 22)
                .disabled(isFailoverManagedNode)
                .opacity(isFailoverManagedNode ? 0.62 : 1)

                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Deployment", symbol: "wrench.and.screwdriver.fill")

                    Button(role: .none) {
                        showRunSetupPrompt = true
                    } label: {
                        Label("Run Setup Wizard", systemImage: "wand.and.stars")
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
                .disabled(isFailoverManagedNode)
                .opacity(isFailoverManagedNode ? 0.62 : 1)

                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Advanced", symbol: "slider.horizontal.3")

                    settingsToggleRow("Enable Advanced Features", isOn: developerFeaturesBinding)

                    Text("Enable experimental SwiftBot functionality intended for testing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .commandCatalogSurface(cornerRadius: 22)
                .disabled(isFailoverManagedNode)
                .opacity(isFailoverManagedNode ? 0.62 : 1)

                SettingsDisclosureCard(
                    title: "SwiftMesh",
                    summaryLines: swiftMeshSummaryLines,
                    isExpanded: $isSwiftMeshExpanded
                ) {
                    swiftMeshContent
                }

                SettingsDisclosureCard(
                    title: "Web UI",
                    summaryLines: webUISummaryLines,
                    isExpanded: $isWebUIExpanded,
                    contentDisabled: isFailoverManagedNode
                ) {
                    webUIContent
                }

                if app.settings.devFeaturesEnabled {
                    bugAutoFixSection
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .disabled(isFailoverManagedNode)
                        .opacity(isFailoverManagedNode ? 0.62 : 1)
                }

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
                .disabled(isFailoverManagedNode)
                .opacity(isFailoverManagedNode ? 0.62 : 1)
            }
            .animation(.easeInOut(duration: 0.2), value: app.settings.devFeaturesEnabled)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
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
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hasUnsavedChanges && !isFailoverManagedNode {
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

    private var bugAutoFixSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Bug Auto-Fix (Developer)", symbol: "sparkles")

            VStack(alignment: .leading, spacing: 12) {
                settingsSubsectionTitle("Automation")
                settingsToggleRow("Enable Auto-Fix", isOn: $app.settings.bugAutoFixEnabled)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                settingsSubsectionTitle("Trigger")

                Text("Trigger Emoji")
                    .font(.subheadline.weight(.medium))
                TextField("🤖", text: $app.settings.bugAutoFixTriggerEmoji)
                    .textFieldStyle(.roundedBorder)
                Text("React with this emoji on a tracked bug message to trigger Codex automation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                settingsSubsectionTitle("Codex Integration")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Command Template")
                        .font(.subheadline.weight(.medium))
                    TextField("codex exec \"$SWIFTBOT_BUG_PROMPT\"", text: $app.settings.bugAutoFixCommandTemplate)
                        .textFieldStyle(.roundedBorder)
                    Text("Environment variables: SWIFTBOT_BUG_PROMPT, SWIFTBOT_BUG_CONTEXT_FILE, SWIFTBOT_REPO_PATH, SWIFTBOT_BUG_MESSAGE_ID, SWIFTBOT_BUG_CHANNEL_ID, SWIFTBOT_BUG_GUILD_ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Repository Path")
                        .font(.subheadline.weight(.medium))
                    TextField("/Users/max/Developer/SwiftBot", text: $app.settings.bugAutoFixRepoPath)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Git Branch")
                        .font(.subheadline.weight(.medium))
                    TextField("main", text: $app.settings.bugAutoFixGitBranch)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                settingsSubsectionTitle("Deployment")

                Text("Version and build are read from bug-thread comments (for example: `version=1.8.19 build=181900`).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                settingsToggleRow("Auto push to GitHub", isOn: $app.settings.bugAutoFixPushEnabled)
                settingsToggleRow("Require approval before push", isOn: $app.settings.bugAutoFixRequireApproval)
                    .disabled(!app.settings.bugAutoFixPushEnabled)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                settingsSubsectionTitle("Reactions")

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
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                settingsSubsectionTitle("Restrictions")

                Text("Allowed Usernames")
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

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                settingsSubsectionTitle("Console")

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
    }

    private var swiftMeshContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Role")
                    .font(.subheadline.weight(.medium))
                Picker("Role", selection: $app.settings.clusterMode) {
                    ForEach(ClusterMode.selectableCases) { mode in
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

            if app.settings.clusterMode == .standby {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Primary Address")
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

            VStack(alignment: .leading, spacing: 10) {
                Text("Worker Offload")
                    .font(.subheadline.weight(.medium))
                Toggle("Offload AI replies to workers when Primary", isOn: $app.settings.clusterOffloadAIReplies)
                    .toggleStyle(.switch)
                Toggle("Offload Wiki lookups to workers when Primary", isOn: $app.settings.clusterOffloadWikiLookups)
                    .toggleStyle(.switch)
                Text("Applies only in Primary mode and only when workers are registered/reachable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!canEditOffloadPolicy)
            .opacity(canEditOffloadPolicy ? 1 : 0.62)

            if app.settings.clusterMode == .standby {
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
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var webUIContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            adminWebSettingsCard(
                title: "Web Server",
                symbol: "globe",
                subtitle: "Manage the local SwiftBot dashboard listener and the URL SwiftBot shares with browsers."
            ) {
                AdminWebServerConfigurationSection()
            }

            adminWebSettingsCard(
                title: "Internet Access",
                symbol: "network",
                subtitle: "Expose SwiftBot securely over the internet with automatic HTTPS and Cloudflare Tunneling."
            ) {
                InternetAccessConfigurationSection()
            }

            adminWebSettingsCard(
                title: "Authentication",
                symbol: "person.badge.key",
                subtitle: "Control who can sign in to the Web UI with Discord."
            ) {
                AdminWebAuthenticationSection()
            }

            AdminWebLaunchControls(usesGlassActionStyle: true)
        }
    }

    @ViewBuilder
    private func adminWebSettingsCard<Content: View>(
        title: String,
        symbol: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.headline)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .commandCatalogSurface(cornerRadius: 18)
    }

    @ViewBuilder
    private func settingsSubsectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func settingsToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            Text(title)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
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
    var adminWebHTTPSEnabled = false
    var adminWebCertificateMode: AdminWebUICertificateMode = .automatic
    var adminWebHostname = ""
    var adminWebCloudflareToken = ""
    var adminWebPublicAccessEnabled = false
    var adminWebImportedCertificateFile = ""
    var adminWebImportedPrivateKeyFile = ""
    var adminWebImportedCertificateChainFile = ""
    var adminRestrictSpecificUsers = false
    var adminDiscordClientID = ""
    var adminDiscordClientSecret = ""
    var adminAllowedUserIDs = ""
    var devFeaturesEnabled = false
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

private struct SettingsDisclosureCard<Content: View>: View {
    let title: String
    let summaryLines: [String]
    @Binding var isExpanded: Bool
    let contentDisabled: Bool
    let content: Content
    @State private var isHovering = false

    init(
        title: String,
        summaryLines: [String],
        isExpanded: Binding<Bool>,
        contentDisabled: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.summaryLines = summaryLines
        _isExpanded = isExpanded
        self.contentDisabled = contentDisabled
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        VStack(alignment: .leading, spacing: isExpanded ? 16 : 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if !isExpanded {
                            ForEach(summaryLines, id: \.self) { line in
                                Text(line)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(0.65)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }

            if isExpanded {
                Divider()

                content
                    .disabled(contentDisabled)
                    .opacity(contentDisabled ? 0.62 : 1)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, isExpanded ? 16 : 14)
        .padding(.vertical, isExpanded ? 15 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isExpanded ? .thinMaterial : .ultraThinMaterial, in: shape)
        .overlay(
            shape
                .fill(Color.white.opacity(isHovering && !isExpanded ? 0.045 : 0))
                .allowsHitTesting(false)
        )
        .overlay(
            shape
                .strokeBorder(.white.opacity(isExpanded ? 0.10 : (isHovering ? 0.11 : 0.07)), lineWidth: 1)
        )
    }
}
