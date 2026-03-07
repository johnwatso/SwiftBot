import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var app: AppModel
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
            adminAllowedUserIDs: app.settings.adminWebUI.allowedUserIDs.joined(separator: ", ")
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewSectionHeader(title: "Settings", symbol: "gearshape.2.fill")

                VStack(alignment: .leading, spacing: 16) {
                    Text("Discord Authentication")
                        .font(.headline)

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
                .glassCard(cornerRadius: 22, tint: .white.opacity(0.08), stroke: .white.opacity(0.18))

                VStack(alignment: .leading, spacing: 16) {
                    Text("Deployment")
                        .font(.headline)

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
                .glassCard(cornerRadius: 22, tint: .white.opacity(0.08), stroke: .white.opacity(0.18))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
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
}
