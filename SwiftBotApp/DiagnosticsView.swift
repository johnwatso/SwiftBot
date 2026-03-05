import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ViewSectionHeader(title: "Diagnostics", symbol: "waveform.path.ecg")

                diagnosticsSummaryCard

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                    gatewayCard
                    voiceCard
                }

                clusterCard
                clusterDiagnosticsCard
                activeVoiceCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
    }

    private var diagnosticsSummaryCard: some View {
        diagnosticsCard(title: "Overview", symbol: "square.grid.2x2.fill") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], spacing: 10) {
                diagnosticsMetric(title: "Connection", value: app.status.rawValue.capitalized, symbol: "network")
                diagnosticsMetric(title: "Gateway Events", value: "\(app.gatewayEventCount)", symbol: "waveform.path.ecg")
                diagnosticsMetric(title: "Servers", value: "\(app.connectedServers.count)", symbol: "server.rack")
                diagnosticsMetric(title: "Voice Users", value: "\(app.activeVoice.count)", symbol: "person.3.sequence")
            }
        }
    }

    private var gatewayCard: some View {
        diagnosticsCard(title: "Gateway", symbol: "network") {
            InfoRow(label: "Last Event", value: app.lastGatewayEventName)
            InfoRow(label: "READY Events", value: "\(app.readyEventCount)")
            InfoRow(label: "GUILD_CREATE Events", value: "\(app.guildCreateEventCount)")
        }
    }

    private var voiceCard: some View {
        diagnosticsCard(title: "Voice", symbol: "person.3.sequence") {
            InfoRow(label: "Voice State Events", value: "\(app.voiceStateEventCount)")
            InfoRow(label: "Last Voice Event", value: app.lastVoiceStateSummary)
            InfoRow(label: "Last Timestamp", value: app.lastVoiceStateAt?.formatted(date: .omitted, time: .standard) ?? "-")
        }
    }

    private var clusterCard: some View {
        diagnosticsCard(title: "Cluster", symbol: "point.3.connected.trianglepath.dotted") {
            HStack(spacing: 8) {
                clusterPill(text: app.clusterSnapshot.mode.rawValue, symbol: "circle.grid.cross")
                clusterPill(text: app.clusterSnapshot.lastJobRoute.rawValue.capitalized, symbol: "arrow.triangle.branch")
                Spacer()
                Button("Refresh") {
                    app.refreshClusterStatus()
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
            }

            Divider()

            LazyVGrid(columns: [GridItem(.flexible(minimum: 120), spacing: 16), GridItem(.flexible(minimum: 120), spacing: 16)], spacing: 8) {
                compactInfoRow(label: "Node", value: app.clusterSnapshot.nodeName)
                compactInfoRow(label: "Primary", value: app.clusterSnapshot.leaderAddress.isEmpty ? "-" : app.clusterSnapshot.leaderAddress)
                compactInfoRow(label: "Port", value: "\(app.clusterSnapshot.listenPort)")
                compactInfoRow(label: "Server", value: app.clusterSnapshot.serverStatusText)
                compactInfoRow(label: "Worker", value: app.clusterSnapshot.workerStatusText)
                compactInfoRow(label: "Last Job Node", value: app.clusterSnapshot.lastJobNode)
                compactInfoRow(label: "Last Job", value: app.clusterSnapshot.lastJobSummary)
            }
        }
    }

    private var clusterDiagnosticsCard: some View {
        diagnosticsCard(title: "Cluster Diagnostics", symbol: "stethoscope") {
            Text(app.clusterSnapshot.diagnostics)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var activeVoiceCard: some View {
        diagnosticsCard(title: "Active Voice", symbol: "person.2.wave.2") {
            if app.activeVoice.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.2.slash")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("No active voice users currently tracked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                ForEach(app.activeVoice.prefix(12)) { member in
                    PanelLine(
                        title: "\(member.username) in \(member.channelName)",
                        subtitle: "Server: \(app.connectedServers[member.guildId] ?? member.guildId)",
                        tone: .blue
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosticsCard<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline.weight(.semibold))
            }
            content()
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func diagnosticsMetric(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func compactInfoRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clusterPill(text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.08), in: Capsule())
    }
}
