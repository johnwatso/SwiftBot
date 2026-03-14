import SwiftUI
import AppKit

struct GeneralSettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var updater: AppUpdater
    @Binding var showToken: Bool
    @AppStorage("settings.swiftmesh.expanded.v1") private var isSwiftMeshExpanded = false
    @AppStorage("settings.media.expanded.v1") private var isMediaExpanded = false
    @AppStorage("settings.webui.expanded.v1") private var isWebUIExpanded = false
    @State private var settingsSnapshot = AppPreferencesSnapshot()
    @State private var transientToastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var inviteActionInProgress = false
    @State private var showRunSetupPrompt = false

    private var hasUnsavedChanges: Bool {
        currentSettingsSnapshot != settingsSnapshot
    }

    private var currentSettingsSnapshot: AppPreferencesSnapshot {
        app.createPreferencesSnapshot()
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

    private var swiftMeshSummaryLines: [String] {
        let role = app.settings.clusterMode == .standalone ? "Disabled" : app.settings.clusterMode.displayName
        return ["Cluster role: \(role)"]
    }

    private var webUISummaryLines: [String] {
        var lines = [
            "Admin Web UI \(app.settings.adminWebUI.enabled ? "Enabled" : "Disabled")",
            "Port: \(app.settings.adminWebUI.port)"
        ]
        if app.settings.adminWebUI.enabled && !app.settings.adminWebUI.hostname.isEmpty {
            lines.append("Hostname: \(app.settings.adminWebUI.hostname)")
        }
        return lines
    }

    private var mediaLibrarySummaryLines: [String] {
        let count = app.mediaLibrarySettings.sources.count
        let enabledCount = app.mediaLibrarySettings.sources.filter(\.isEnabled).count
        return ["\(count) sources (\(enabledCount) enabled)"]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionTitle("Discord Authentication", symbol: "person.badge.key.fill")

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Bot Token")
                                .font(.subheadline.weight(.medium))
                            
                            HStack(spacing: 10) {
                                Group {
                                    if showToken {
                                        TextField("MTA...", text: $app.settings.token)
                                    } else {
                                        SecureField("MTA...", text: $app.settings.token)
                                    }
                                }
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .disabled(isFailoverManagedNode)
                                
                                Button {
                                    showToken.toggle()
                                } label: {
                                    Image(systemName: showToken ? "eye.slash" : "eye")
                                        .frame(width: 20)
                                }
                                .buttonStyle(.plain)
                                .help(showToken ? "Hide token" : "Show token")
                            }
                            
                            Text("Create a bot in the Discord Developer Portal and paste its token here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 10) {
                            Button {
                                Task { await copyInviteLink() }
                            } label: {
                                Label("Copy Invite Link", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canGenerateInviteLink || inviteActionInProgress)

                            Button {
                                Task { await openInviteLink() }
                            } label: {
                                Label("Open Invite Link", systemImage: "arrow.up.forward.square")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canGenerateInviteLink || inviteActionInProgress)
                            
                            if inviteActionInProgress {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.leading, 4)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 16) {
                        sectionTitle("Deployment", symbol: "wrench.and.screwdriver.fill")

                        Button(role: .none) {
                            showRunSetupPrompt = true
                        } label: {
                            Label("Run Initial Setup...", systemImage: "sparkles")
                        }
                        .buttonStyle(.bordered)
                        .confirmationDialog(
                            "Are you sure you want to run the initial setup again?",
                            isPresented: $showRunSetupPrompt,
                            titleVisibility: .visible
                        ) {
                            Button("Run Setup", role: .destructive) {
                                app.runInitialSetup()
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("This will clear your current connection settings and take you back to the onboarding flow.")
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 16) {
                        sectionTitle("Advanced", symbol: "slider.horizontal.3")

                        settingsToggleRow("Enable Advanced Features", isOn: developerFeaturesBinding)

                        Text("Enable experimental SwiftBot functionality intended for testing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )

                SettingsDisclosureCard(
                    title: "SwiftMesh Cluster",
                    summaryLines: swiftMeshSummaryLines,
                    isExpanded: $isSwiftMeshExpanded
                ) {
                    swiftMeshContent
                }

                SettingsDisclosureCard(
                    title: "Media Library",
                    summaryLines: mediaLibrarySummaryLines,
                    isExpanded: $isMediaExpanded
                ) {
                    mediaLibraryContent
                }

                SettingsDisclosureCard(
                    title: "Admin Web UI",
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
                }

                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Software Updates", symbol: "arrow.triangle.2.circlepath")

                    HStack(spacing: 8) {
                        updateChannelOption(.stable)
                        updateChannelOption(.beta)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
                        Text("Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
            }
            .padding(24)
            .padding(.bottom, 80)
        }
        .overlay(alignment: .topTrailing) {
            if let message = transientToastMessage {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
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
            if hasUnsavedChanges {
                StickySaveButton(label: "Save Settings", systemImage: "square.and.arrow.down.fill") {
                    app.saveSettings()
                    withAnimation {
                        settingsSnapshot = currentSettingsSnapshot
                    }
                }
                .padding(.trailing, 22)
                .padding(.bottom, 18)
            }
        }
        .onAppear {
            settingsSnapshot = currentSettingsSnapshot
        }
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

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        SettingsSectionHeader(title: title, systemImage: symbol)
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
                settingsSubsectionTitle("Access Control")

                Text("Allowed Usernames")
                    .font(.subheadline.weight(.medium))
                TextField("Comma-separated Discord usernames", text: Binding(
                    get: { app.settings.bugAutoFixAllowedUsernames.joined(separator: ", ") },
                    set: { newValue in
                        app.settings.bugAutoFixAllowedUsernames = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                Text("Restricts bug auto-fix triggers to these users. Leave empty to allow all server administrators.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var swiftMeshContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                settingsSubsectionTitle("Cluster Role")
                Picker("", selection: $app.settings.clusterMode) {
                    ForEach(ClusterMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isFailoverManagedNode)

                Text(app.settings.clusterMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Node Name")
                        .font(.subheadline.weight(.medium))
                    TextField("SwiftBot Node", text: $app.settings.clusterNodeName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isFailoverManagedNode)
                }

                if app.settings.clusterMode == .standby || app.settings.clusterMode == .worker {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Primary Node Address")
                            .font(.subheadline.weight(.medium))
                        TextField("192.168.1.50", text: $app.settings.clusterLeaderAddress)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Primary Node Port")
                            .font(.subheadline.weight(.medium))
                        TextField("38787", value: $app.settings.clusterLeaderPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Listen Port")
                        .font(.subheadline.weight(.medium))
                    TextField("38787", value: $app.settings.clusterListenPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isFailoverManagedNode)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Shared Secret")
                        .font(.subheadline.weight(.medium))
                    SecureField("Secret key for node authentication", text: $app.settings.clusterSharedSecret)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isFailoverManagedNode)
                }
            }

            if canEditOffloadPolicy {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    settingsSubsectionTitle("Offload Policy")
                    Text("Decide which tasks this Primary node can offload to connected Worker nodes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    settingsToggleRow("Offload AI Replies", isOn: $app.settings.clusterOffloadAIReplies)
                    settingsToggleRow("Offload Wiki Lookups", isOn: $app.settings.clusterOffloadWikiLookups)
                }
            }
        }
    }

    private var webUIContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            adminWebSettingsCard(
                title: "Local Access",
                symbol: "network"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    settingsToggleRow("Enable Admin Web UI", isOn: $app.settings.adminWebUI.enabled)
                    
                    if app.settings.adminWebUI.enabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Port")
                                .font(.subheadline.weight(.medium))
                            Text("\(app.settings.adminWebUI.port)")
                                .font(.system(.body, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            adminWebSettingsCard(
                title: "Public Access",
                symbol: "globe"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    settingsToggleRow("Internet Access (Cloudflare)", isOn: $app.settings.adminWebUI.internetAccessEnabled)
                    
                    if app.settings.adminWebUI.internetAccessEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Subdomain")
                                .font(.subheadline.weight(.medium))
                            TextField("swiftbot", text: $app.settings.adminWebUI.subdomain)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
        }
    }

    private var mediaLibraryContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure the recording folders available on this node. These paths stay local to this Mac and are not synced over SwiftMesh.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                ForEach($app.mediaLibrarySettings.sources) { $source in
                    HStack(spacing: 12) {
                        Toggle("", isOn: $source.isEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                        
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Source Name", text: $source.name)
                                .font(.subheadline.weight(.semibold))
                                .textFieldStyle(.plain)
                            HStack(spacing: 4) {
                                TextField("Path", text: $source.rootPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textFieldStyle(.plain)
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
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        
                        Spacer()
                        
                        Button {
                            app.mediaLibrarySettings.sources.removeAll { $0.id == source.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                
                Button {
                    app.mediaLibrarySettings.sources.append(MediaLibrarySource(name: "New Source", rootPath: ""))
                } label: {
                    Label("Add Source", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func adminWebSettingsCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.bold))
            content()
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func settingsSubsectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline.weight(.semibold))
    }

    private func settingsToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private func copyInviteLink() async {
        guard let inviteURL = await resolveInviteURL() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(inviteURL, forType: .string)
        showToast("Invite link copied to clipboard")
    }

    private func openInviteLink() async {
        guard let inviteURL = await resolveInviteURL(),
              let url = URL(string: inviteURL) else { return }
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
}

private struct SettingsDisclosureCard<Content: View>: View {
    let title: String
    let summaryLines: [String]
    @Binding var isExpanded: Bool
    var contentDisabled: Bool = false
    let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline.weight(.bold))
                        
                        if !isExpanded {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(summaryLines, id: \.self) { line in
                                    Text(line)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                        .padding(.horizontal, 24)
                    
                    content()
                        .padding(24)
                        .disabled(contentDisabled)
                        .opacity(contentDisabled ? 0.6 : 1.0)
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}
