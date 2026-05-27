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
                LabeledContent("Update Channel") {
                    Picker("Update Channel", selection: Binding(
                        get: { updater.selectedChannel },
                        set: { updater.setUpdateChannel($0) }
                    )) {
                        ForEach(AppUpdater.UpdateChannel.allCases, id: \.self) { channel in
                            Text(channel.label).tag(channel)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }

                if updater.selectedChannel == .beta {
                    Label("Beta channel enabled. Updates will come from the beta appcast feed.", systemImage: "flask.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                LabeledContent("Check for Updates") {
                    Button("Check Now…") {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!updater.canCheckForUpdates)
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
}
