import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ViewSectionHeader(title: "Diagnostics", symbol: "waveform.path.ecg")

                diagnosticsSummaryCard

                connectionHealthCard

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

    private var connectionHealthCard: some View {
        diagnosticsCard(title: "Connection Health", symbol: "stethoscope") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                // Gateway state
                healthIndicator(
                    label: "Gateway",
                    value: app.status.rawValue.capitalized,
                    symbol: "network",
                    ok: app.status == .running
                )
                // Heartbeat latency
                healthIndicator(
                    label: "Latency",
                    value: app.connectionDiagnostics.heartbeatLatencyMs.map { "\($0) ms" } ?? "-",
                    symbol: "waveform.path.ecg",
                    ok: app.connectionDiagnostics.heartbeatLatencyMs != nil
                )
                // REST health
                healthIndicator(
                    label: "REST",
                    value: restHealthLabel,
                    symbol: "arrow.up.arrow.down.circle",
                    ok: {
                        if case .ok = app.connectionDiagnostics.restHealth { return true }
                        return false
                    }()
                )
                // Rate limit remaining
                healthIndicator(
                    label: "Rate Limit",
                    value: app.connectionDiagnostics.rateLimitRemaining.map { "\($0) rem." } ?? "-",
                    symbol: "gauge.with.needle",
                    ok: app.connectionDiagnostics.rateLimitRemaining.map { $0 > 0 } ?? true
                )
                // Permissions (derived from REST 200)
                healthIndicator(
                    label: "Permissions",
                    value: permissionsLabel,
                    symbol: "lock.shield",
                    ok: {
                        if case .ok = app.connectionDiagnostics.restHealth { return true }
                        return false
                    }()
                )
                // Intents — show 4014 signal if last close was a privileged intent rejection
                let intentsRejected = app.connectionDiagnostics.lastGatewayCloseCode == 4014
                healthIndicator(
                    label: "Intents",
                    value: intentsRejected ? "Rejected (4014)" : (app.intentsAccepted.map { $0 ? "Accepted" : "Unknown" } ?? "-"),
                    symbol: "checklist",
                    ok: app.intentsAccepted == true && !intentsRejected
                )
            }

            Divider()
                .padding(.vertical, 4)

            // Test Connection button + result
            HStack(spacing: 12) {
                Button {
                    Task { await app.runTestConnection() }
                } label: {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!app.canRunTestConnection || app.status != .running)

                if !app.connectionDiagnostics.lastTestMessage.isEmpty {
                    Text(app.connectionDiagnostics.lastTestMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if let at = app.connectionDiagnostics.lastTestAt {
                    Text(at, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // REST failure remediation
            if case let .error(code, msg) = app.connectionDiagnostics.restHealth, code > 0 {
                remediationBanner(message: msg)
            }

            // Gateway close code remediation (4004 auth failure, 4014 missing intents, etc.)
            if let closeCode = app.connectionDiagnostics.lastGatewayCloseCode {
                remediationBanner(message: app.gatewayCloseRemediationMessage(code: closeCode))
            }

            if app.status == .running,
               let until = app.testConnectionCooldownUntil, !app.canRunTestConnection {
                Text("Test Connection available in \(max(0, Int(until.timeIntervalSinceNow)))s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var restHealthLabel: String {
        switch app.connectionDiagnostics.restHealth {
        case .unknown: return "-"
        case .ok: return "OK"
        case let .error(code, _): return code > 0 ? "Error \(code)" : "Failed"
        }
    }

    private var permissionsLabel: String {
        switch app.connectionDiagnostics.restHealth {
        case .unknown: return "-"
        case .ok: return "OK"
        case .error(403, _): return "Insufficient"
        case let .error(code, _): return code > 0 ? "Error \(code)" : "-"
        }
    }

    private func remediationBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func healthIndicator(label: String, value: String, symbol: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.isEmpty ? "-" : value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ok ? .primary : .secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
