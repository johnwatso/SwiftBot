import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Diagnostics")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                RuleGroupSection(title: "Gateway", systemImage: "network") {
                    InfoRow(label: "Connection", value: app.status.rawValue.capitalized)
                    InfoRow(label: "Total Events", value: "\(app.gatewayEventCount)")
                    InfoRow(label: "Last Event", value: app.lastGatewayEventName)
                    InfoRow(label: "READY Events", value: "\(app.readyEventCount)")
                    InfoRow(label: "GUILD_CREATE Events", value: "\(app.guildCreateEventCount)")
                    InfoRow(label: "Servers", value: "\(app.connectedServers.count)")
                }

                RuleGroupSection(title: "Cluster", systemImage: "point.3.connected.trianglepath.dotted") {
                    InfoRow(label: "Mode", value: app.clusterSnapshot.mode.rawValue)
                    InfoRow(label: "Node", value: app.clusterSnapshot.nodeName)
                    InfoRow(label: "Primary Address", value: app.clusterSnapshot.leaderAddress.isEmpty ? "-" : app.clusterSnapshot.leaderAddress)
                    InfoRow(label: "Listen Port", value: "\(app.clusterSnapshot.listenPort)")
                    InfoRow(label: "Server", value: app.clusterSnapshot.serverStatusText)
                    InfoRow(label: "Worker", value: app.clusterSnapshot.workerStatusText)
                    InfoRow(label: "Last Job Route", value: app.clusterSnapshot.lastJobRoute.rawValue.capitalized)
                    InfoRow(label: "Last Job", value: app.clusterSnapshot.lastJobSummary)
                    InfoRow(label: "Last Job Node", value: app.clusterSnapshot.lastJobNode)

                    HStack {
                        Button("Refresh") {
                            app.refreshClusterStatus()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                RuleGroupSection(title: "Cluster Diagnostics", systemImage: "stethoscope") {
                    Text(app.clusterSnapshot.diagnostics)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                RuleGroupSection(title: "Voice", systemImage: "person.3.sequence") {
                    InfoRow(label: "Voice State Events", value: "\(app.voiceStateEventCount)")
                    InfoRow(label: "Active Voice Users", value: "\(app.activeVoice.count)")
                    InfoRow(label: "Last Voice Event", value: app.lastVoiceStateSummary)
                    InfoRow(label: "Last Voice Timestamp", value: app.lastVoiceStateAt?.formatted(date: .omitted, time: .standard) ?? "-")

                    if app.activeVoice.isEmpty {
                        Text("No active voice users currently tracked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(app.activeVoice.prefix(20)) { member in
                            PanelLine(
                                title: "\(member.username) in \(member.channelName)",
                                subtitle: "Server: \(app.connectedServers[member.guildId] ?? member.guildId)",
                                tone: .blue
                            )
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }
}
