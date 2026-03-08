import SwiftUI

struct UpdatesPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var updater: AppUpdater

    var body: some View {
        PreferencesTabContainer {
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. These settings sync from Primary.")
            }

            PreferencesCard("Software Updates", systemImage: "arrow.clockwise") {
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
                .buttonStyle(.bordered)
                .disabled(!updater.canCheckForUpdates)

                if !updater.isConfigured {
                    Text("Set `SUFeedURL` and `SUPublicEDKey` in the app target build settings to enable Sparkle updates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)
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
