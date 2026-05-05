import AppKit
import SwiftUI

struct AdvancedPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @State private var swiftMinerPairingToken = ""
    @State private var swiftMinerPairingMessage: String?
    @State private var swiftMinerPairingSucceeded = false

    var body: some View {
        PreferencesTabContainer {
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. These settings sync from Primary.")
            }

            PreferencesCard("Developer Mode", systemImage: "hammer.circle") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Developer Mode", isOn: Binding(
                        get: { app.settings.devFeaturesEnabled },
                        set: { newValue in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                app.settings.devFeaturesEnabled = newValue
                            }
                        }
                    ))
                    .toggleStyle(.switch)

                    Text("Unlock experimental SwiftBot features including SwiftBot Remote beta, Bug Auto-Fix, and Codex automation. These tools are under active development.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)

            PreferencesCard("Experimental Tools", systemImage: "wrench") {
                Text(
                    app.settings.devFeaturesEnabled
                    ? "Developer Mode is active. SwiftBot Remote beta, Bug Auto-Fix, and other experimental tools are available below."
                    : "Enable Developer Mode above to configure SwiftBot Remote beta, Bug Auto-Fix, and other experimental tools."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)

            PreferencesCard("SwiftMiner", systemImage: "shippingbox.circle") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        settingsToggleRow("Enable SwiftMiner Integration", isOn: $app.settings.swiftMiner.enabled)
                        Spacer()
                        Text(app.settings.swiftMiner.enabled ? "Paired" : "Not Paired")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(app.settings.swiftMiner.enabled ? .green : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pairing Bundle")
                            .font(.subheadline.weight(.medium))
                        TextField("Paste from SwiftMiner", text: $swiftMinerPairingToken)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Button {
                            let result = app.applySwiftMinerPairingToken(swiftMinerPairingToken)
                            swiftMinerPairingSucceeded = result.ok
                            swiftMinerPairingMessage = result.message
                            if result.ok {
                                swiftMinerPairingToken = ""
                            }
                        } label: {
                            Label("Pair with SwiftMiner", systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            let token = NSPasteboard.general.string(forType: .string) ?? ""
                            swiftMinerPairingToken = token
                            let result = app.applySwiftMinerPairingToken(token)
                            swiftMinerPairingSucceeded = result.ok
                            swiftMinerPairingMessage = result.message
                            if result.ok {
                                swiftMinerPairingToken = ""
                            }
                        } label: {
                            Label("Paste and Pair", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let swiftMinerPairingMessage {
                        Text(swiftMinerPairingMessage)
                            .font(.caption)
                            .foregroundStyle(swiftMinerPairingSucceeded ? .green : .red)
                    }

                    Text("Copy the pairing bundle from SwiftMiner > Integrations and paste it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)

            if app.settings.devFeaturesEnabled {
                PreferencesCard("Bug Auto-Fix", systemImage: "sparkles") {
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
                .disabled(app.isFailoverManagedNode)
                .opacity(app.isFailoverManagedNode ? 0.62 : 1)
            } else {
                PreferencesCard("Bug Auto-Fix", systemImage: "sparkles") {
                    Text("Enable Developer Mode above to access Bug Auto-Fix configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(true)
                .opacity(0.75)
            }
        }
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
}
