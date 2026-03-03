import SwiftUI

struct WikiBridgeView: View {
    @EnvironmentObject var app: AppModel

    private var effectivePrefix: String {
        let trimmed = app.settings.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "!" : trimmed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("WikiBridge")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                overviewCard
                configurationCard
            }
            .padding(20)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status")
                .font(.title3.weight(.semibold))

            InfoRow(label: "WikiBridge", value: app.settings.wikiBot.isEnabled ? "Enabled" : "Disabled")
            InfoRow(label: "\(effectivePrefix)finals", value: app.settings.wikiBot.allowFinalsCommand ? "Enabled" : "Disabled")
            InfoRow(label: "\(effectivePrefix)wiki", value: app.settings.wikiBot.allowWikiAlias ? "Enabled" : "Disabled")
            InfoRow(label: "\(effectivePrefix)weapon", value: app.settings.wikiBot.allowWeaponCommand ? "Enabled" : "Disabled")
            InfoRow(label: "Weapon Stats Formatting", value: app.settings.wikiBot.includeWeaponStats ? "Enabled" : "Disabled")
        }
        .padding(20)
        .glassCard(cornerRadius: 24, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configuration")
                .font(.title3.weight(.semibold))

            Toggle("Enable WikiBridge", isOn: $app.settings.wikiBot.isEnabled)
                .toggleStyle(.switch)

            Group {
                Toggle("Enable \(effectivePrefix)finals command", isOn: $app.settings.wikiBot.allowFinalsCommand)
                Toggle("Enable \(effectivePrefix)wiki alias", isOn: $app.settings.wikiBot.allowWikiAlias)
                Toggle("Enable \(effectivePrefix)weapon command", isOn: $app.settings.wikiBot.allowWeaponCommand)
                Toggle("Include weapon stat blocks in responses", isOn: $app.settings.wikiBot.includeWeaponStats)
            }
            .toggleStyle(.switch)
            .disabled(!app.settings.wikiBot.isEnabled)
            .opacity(app.settings.wikiBot.isEnabled ? 1.0 : 0.55)

            HStack {
                Spacer()
                Button("Save WikiBridge Settings") {
                    app.saveSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 24, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }
}
