import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var app: AppModel
    
    // Persist selected tab to fix toolbar rendering issues
    @AppStorage("swiftbot.preferences.selectedTab")
    private var selectedTab = 0

    @State private var settingsSnapshot = PreferencesSnapshot()

    private var hasUnsavedChanges: Bool {
        currentSettingsSnapshot != settingsSnapshot
    }

    private var currentSettingsSnapshot: PreferencesSnapshot {
        PreferencesSnapshot(
            token: app.settings.token,
            autoStart: app.settings.autoStart,
            clusterMode: app.settings.clusterMode,
            clusterNodeName: app.settings.clusterNodeName,
            clusterLeaderAddress: app.settings.clusterLeaderAddress,
            clusterLeaderPort: app.settings.clusterLeaderPort,
            clusterListenPort: app.settings.clusterListenPort,
            clusterSharedSecret: app.settings.clusterSharedSecret,
            clusterWorkerOffloadEnabled: app.settings.clusterWorkerOffloadEnabled,
            clusterOffloadAIReplies: app.settings.clusterOffloadAIReplies,
            clusterOffloadWikiLookups: app.settings.clusterOffloadWikiLookups,
            mediaSourcesJSON: mediaSourcesSnapshotJSON(),
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
            adminLocalAuthEnabled: app.settings.adminWebUI.localAuthEnabled,
            adminLocalAuthUsername: app.settings.adminWebUI.localAuthUsername,
            adminLocalAuthPassword: app.settings.adminWebUI.localAuthPassword,
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
            bugAutoFixPushEnabled: app.settings.bugAutoFixPushEnabled,
            bugAutoFixRequireApproval: app.settings.bugAutoFixRequireApproval,
            bugAutoFixApproveEmoji: app.settings.bugAutoFixApproveEmoji,
            bugAutoFixRejectEmoji: app.settings.bugAutoFixRejectEmoji,
            bugAutoFixAllowedUsernames: app.settings.bugAutoFixAllowedUsernames.joined(separator: ", ")
        )
    }

    var body: some View {
        Group {
            if app.isRemoteLaunchMode {
                PreferencesTabContainer {
                    PreferencesCard(
                        "Remote Control Mode",
                        systemImage: "dot.radiowaves.left.and.right",
                        subtitle: "Local Discord, SwiftMesh, and Web UI runtime settings are inactive while this Mac is acting as a remote management client."
                    ) {
                        Text("Use the Remote dashboard to update the primary node connection, inspect status, edit rules, and change runtime settings on the primary.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                TabView(selection: $selectedTab) {
                    GeneralPreferencesView()
                        .tabItem {
                            Label("General", systemImage: "gear")
                        }
                        .tag(0)

                    MeshPreferencesView()
                        .tabItem {
                            Label("SwiftMesh", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .tag(1)

                    WebUIPreferencesView()
                        .tabItem {
                            Label("Web UI", systemImage: "globe")
                        }
                        .tag(2)

                    UpdatesPreferencesView()
                        .tabItem {
                            Label("Updates", systemImage: "arrow.clockwise")
                        }
                        .tag(3)

                    AdvancedPreferencesView()
                        .tabItem {
                            Label("Developer", systemImage: "wrench")
                        }
                        .tag(4)
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasUnsavedChanges {
                        StickySaveButton(label: "Save Settings", systemImage: "square.and.arrow.down.fill") {
                            app.saveSettings()
                            settingsSnapshot = currentSettingsSnapshot
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 18)
                    }
                }
                .onChange(of: currentSettingsSnapshot) { _, newSnapshot in
                    if !hasUnsavedChanges {
                        settingsSnapshot = newSnapshot
                    }
                }
            }
        }
        .frame(width: 720, height: 480)
        .onAppear {
            settingsSnapshot = currentSettingsSnapshot
        }
        .background(
            // Hidden view that observes onboarding state and closes window when complete
            PreferencesWindowCloser()
        )
    }

    private func mediaSourcesSnapshotJSON() -> String {
        guard let data = try? JSONEncoder().encode(app.mediaLibrarySettings.sources),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

// Separate view to handle window closing without affecting PreferencesView identity
private struct PreferencesWindowCloser: View {
    @EnvironmentObject var app: AppModel
    
    var body: some View {
        EmptyView()
            .onChange(of: app.isOnboardingComplete) { oldValue, newValue in
                // Only close when transitioning TO complete (finishing setup)
                // NOT when transitioning FROM complete (starting setup)
                if newValue && !oldValue {
                    // Close the Preferences window
                    DispatchQueue.main.async {
                        NSApp.keyWindow?.close()
                    }
                }
            }
    }
}

private struct PreferencesSnapshot: Equatable {
    var token = ""
    var autoStart = false
    var clusterMode: ClusterMode = .standalone
    var clusterNodeName = ""
    var clusterLeaderAddress = ""
    var clusterLeaderPort = 38787
    var clusterListenPort = 38787
    var clusterSharedSecret = ""
    var clusterWorkerOffloadEnabled = false
    var clusterOffloadAIReplies = false
    var clusterOffloadWikiLookups = false
    var mediaSourcesJSON = ""
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
    var adminLocalAuthEnabled = false
    var adminLocalAuthUsername = ""
    var adminLocalAuthPassword = ""
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
    var bugAutoFixPushEnabled = true
    var bugAutoFixRequireApproval = true
    var bugAutoFixApproveEmoji = "🚀"
    var bugAutoFixRejectEmoji = "🛑"
    var bugAutoFixAllowedUsernames = ""
}
