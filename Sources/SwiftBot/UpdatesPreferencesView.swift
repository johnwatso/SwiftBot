import SwiftUI

struct UpdatesPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var updater: AppUpdater

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("Version", value: infoValue("CFBundleShortVersionString"))
                LabeledContent("Build", value: infoValue("CFBundleVersion"))
            } header: {
                Text("Installed Version")
            }

            Section {
                Picker("Update Channel", selection: channelBinding) {
                    ForEach(AppUpdater.UpdateChannel.allCases) { channel in
                        Text(channel.label).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(updater.isDisabledForDebugBuild)
                if updater.selectedChannel == .beta {
                    SettingsSecondaryText("Updates come from the beta appcast feed.")
                }

                Toggle("Check for updates automatically", isOn: automaticUpdateChecksBinding)
                    .disabled(!updater.canCheckForUpdates)
                SettingsSecondaryText("Checks in the background and prompts when an update is available.")

                Toggle("Install updates unattended", isOn: automaticUpdatesBinding)
                    .disabled(!updater.canCheckForUpdates || !updater.automaticallyChecksForUpdates)
                SettingsSecondaryText("Downloads and installs in the background without asking, whenever macOS does not require authorization.")

                if updater.isReadyToInstall {
                    Button {
                        updater.installPendingUpdate()
                    } label: {
                        Label("Install \(updater.availableVersion ?? "Update") and Relaunch", systemImage: "arrow.down.circle")
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Label("Check for Updates…", systemImage: "arrow.clockwise")
                    }
                    .settingsActionButton()
                    .disabled(!updater.canCheckForUpdates)
                }

                if updater.isDisabledForDebugBuild {
                    SettingsWarningText("Updates are off in Debug builds, so Sparkle can't install a release over the app Xcode built.")
                } else if !updater.isConfigured {
                    SettingsWarningText("This build has no update feed or signing key, so updates are unavailable.")
                }

                HStack(spacing: 4) {
                    Text("If updates fail, download the latest version from")
                        .foregroundStyle(.secondary)
                    Link("GitHub Releases", destination: URL(string: "https://github.com/johnwatso/SwiftBot/releases")!)
                }
                .font(.caption)
            } header: {
                Text("Updates")
            }
        }
    }

    private func infoValue(_ key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? "–"
    }

    private var channelBinding: Binding<AppUpdater.UpdateChannel> {
        Binding {
            updater.selectedChannel
        } set: { channel in
            updater.setUpdateChannel(channel)
        }
    }

    private var automaticUpdateChecksBinding: Binding<Bool> {
        Binding {
            updater.automaticallyChecksForUpdates
        } set: { isEnabled in
            updater.setAutomaticallyChecksForUpdates(isEnabled)
        }
    }

    private var automaticUpdatesBinding: Binding<Bool> {
        Binding {
            updater.automaticallyDownloadsUpdates
        } set: { isEnabled in
            updater.setAutomaticallyDownloadsUpdates(isEnabled)
        }
    }
}
