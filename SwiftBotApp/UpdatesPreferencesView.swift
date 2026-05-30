import SwiftUI

struct UpdatesPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var updater: AppUpdater

    var body: some View {
        SettingsForm(
            readOnlyBannerText: app.isFailoverManagedNode
                ? "Read-only on Failover nodes. These settings sync from Primary."
                : nil
        ) {
            Section {
                HStack(spacing: 8) {
                    updateChannelOption(.stable)
                    updateChannelOption(.beta)
                }

                if updater.selectedChannel == .beta {
                    Label("Beta channel enabled. Updates will come from the beta appcast feed.", systemImage: "flask.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Prompt for available updates", isOn: automaticUpdateChecksBinding)
                    .disabled(!updater.canCheckForUpdates)
                Text("Check in the background and show Sparkle's update prompt when user action is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Allow unattended updates", isOn: automaticUpdatesBinding)
                    .disabled(!updater.canCheckForUpdates || !updater.automaticallyChecksForUpdates)
                Text("Download and install eligible updates in the background when macOS does not require authorization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Check for Updates") {
                    Button("Check Now…") {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!updater.canCheckForUpdates)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("If automatic updates fail, you can download the latest version manually from:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("GitHub Releases", destination: URL(string: "https://github.com/johnwatso/SwiftBot/releases")!)
                        .font(.caption)
                        .underline()
                }

                if !updater.isConfigured {
                    Text("Set `SUFeedURL` and `SUPublicEDKey` in the app target build settings to enable Sparkle updates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Software Updates", systemImage: "arrow.clockwise")
            } footer: {
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Text("Version \(version) (Build \(build))")
                }
            }
        }
        .preferencesCardDisabled(when: app.isFailoverManagedNode)
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
