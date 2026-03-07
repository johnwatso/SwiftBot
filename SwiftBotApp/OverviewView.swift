import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var app: AppModel
    var onOpenSwiftMesh: (() -> Void)?

    private struct VoiceChannelGroup: Identifiable {
        let id: String
        let title: String
        let members: [VoiceMemberPresence]
    }

    private var recentVoice: [VoiceEventLogEntry] {
        Array(app.voiceLog.prefix(5))
    }

    private var recentCommands: [CommandLogEntry] {
        Array(app.commandLog.prefix(5))
    }

    private var workerJobCount: Int {
        app.commandLog.filter { $0.executionRoute == "Worker" || $0.executionRoute == "Remote" }.count
    }

    private var aiProviderSummary: String {
        app.settings.preferredAIProvider.rawValue
    }

    private var enabledWikiSourceCount: Int {
        app.settings.wikiBot.sources.filter(\.enabled).count
    }

    private var enabledWikiCommandCount: Int {
        app.settings.wikiBot.sources
            .filter(\.enabled)
            .reduce(into: 0) { count, source in
                count += source.commands.filter(\.enabled).count
            }
    }

    private var patchyTargetCount: Int {
        app.settings.patchy.sourceTargets.count
    }

    private var patchyEnabledTargetCount: Int {
        app.settings.patchy.sourceTargets.filter(\.isEnabled).count
    }

    private var actionRuleCount: Int {
        app.ruleStore.rules.count
    }

    private var enabledActionRuleCount: Int {
        app.ruleStore.rules.filter(\.isEnabled).count
    }

    private var helpSummary: String {
        "\(app.settings.help.mode.rawValue) · \(app.settings.help.tone.rawValue)"
    }

    private var groupedActiveVoice: [VoiceChannelGroup] {
        let grouped = Dictionary(grouping: app.activeVoice) { member in
            "\(member.guildId):\(member.channelId)"
        }

        return grouped.map { key, members in
            let first = members.first
            let serverName = first.map { app.connectedServers[$0.guildId] ?? $0.guildId } ?? "Unknown Server"
            let channelName = first?.channelName ?? "Voice Channel"
            let orderedMembers = members.sorted { lhs, rhs in
                lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
            }
            return VoiceChannelGroup(
                id: key,
                title: "\(channelName) · \(serverName)",
                members: orderedMembers
            )
        }
        .sorted { lhs, rhs in
            if lhs.members.count != rhs.members.count {
                return lhs.members.count > rhs.members.count
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ViewSectionHeader(title: "Overview", symbol: "speedometer")

                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 185), spacing: 10)
                ], spacing: 12) {
                    if app.settings.clusterMode == .worker {
                        DashboardMetricCard(
                            title: "Status",
                            value: app.primaryServiceStatusText,
                            subtitle: app.clusterSnapshot.serverStatusText,
                            symbol: "bolt.horizontal.circle.fill",
                            detail: "Auto Start \(app.settings.autoStart ? "On" : "Off")",
                            color: .green
                        )
                        DashboardMetricCard(
                            title: "Mesh Mode",
                            value: app.settings.clusterMode.displayName,
                            subtitle: app.settings.clusterNodeName,
                            symbol: "point.3.connected.trianglepath.dotted",
                            detail: "Primary \(app.settings.clusterLeaderAddress.isEmpty ? "Not set" : "Configured")",
                            color: .purple
                        )
                        DashboardMetricCard(
                            title: "Listen Port",
                            value: "\(app.clusterSnapshot.listenPort)",
                            subtitle: "worker HTTP service",
                            symbol: "antenna.radiowaves.left.and.right",
                            detail: "Node \(app.settings.clusterNodeName.isEmpty ? "Unnamed" : app.settings.clusterNodeName)",
                            color: .blue
                        )
                        DashboardMetricCard(
                            title: "WikiBridge",
                            value: app.settings.wikiBot.isEnabled ? "Enabled" : "Disabled",
                            subtitle: "\(enabledWikiSourceCount) sources",
                            symbol: "book.pages.fill",
                            detail: "\(enabledWikiCommandCount) commands",
                            color: .orange
                        )
                        DashboardMetricCard(
                            title: "Patchy",
                            value: app.settings.patchy.monitoringEnabled ? "Monitoring On" : "Monitoring Off",
                            subtitle: "\(patchyEnabledTargetCount)/\(patchyTargetCount) targets",
                            symbol: "hammer.fill",
                            detail: "Jobs \(workerJobCount)",
                            color: .red
                        )
                        DashboardMetricCard(
                            title: "Actions",
                            value: "\(enabledActionRuleCount) active",
                            subtitle: "\(actionRuleCount) total rules",
                            symbol: "point.3.filled.connected.trianglepath.dotted",
                            detail: helpSummary,
                            color: .red
                        )
                    } else {
                        DashboardMetricCard(
                            title: "Status",
                            value: app.status.rawValue.capitalized,
                            subtitle: app.uptime?.text ?? "--",
                            symbol: "bolt.horizontal.circle.fill",
                            detail: "Auto Start \(app.settings.autoStart ? "On" : "Off")",
                            color: .green
                        )
                        DashboardMetricCard(
                            title: "Servers",
                            value: "\(app.connectedServers.count)",
                            subtitle: "servers connected",
                            symbol: "server.rack",
                            detail: app.settings.clusterMode == .standalone ? "Standalone" : app.settings.clusterMode.displayName,
                            color: .blue
                        )
                        DashboardMetricCard(
                            title: "In Voice",
                            value: "\(app.activeVoice.count)",
                            subtitle: "users right now",
                            symbol: "person.3.sequence.fill",
                            detail: "Route \(app.clusterSnapshot.lastJobRoute.rawValue.capitalized)",
                            color: .orange
                        )
                        DashboardMetricCard(
                            title: "Commands Run",
                            value: "\(app.stats.commandsRun)",
                            subtitle: "this session",
                            symbol: "terminal.fill",
                            detail: "Recent commands activity",
                            color: .red
                        )
                        DashboardMetricCard(
                            title: "WikiBridge",
                            value: app.settings.wikiBot.isEnabled ? "Enabled" : "Disabled",
                            subtitle: "\(enabledWikiSourceCount) sources",
                            symbol: "book.pages.fill",
                            detail: "\(enabledWikiCommandCount) commands",
                            color: .mint
                        )
                        DashboardMetricCard(
                            title: "Patchy",
                            value: app.settings.patchy.monitoringEnabled ? "Monitoring On" : "Monitoring Off",
                            subtitle: "\(patchyEnabledTargetCount)/\(patchyTargetCount) targets",
                            symbol: "hammer.fill",
                            detail: "Help \(helpSummary)",
                            color: .purple
                        )
                        DashboardMetricCard(
                            title: "Actions",
                            value: "\(enabledActionRuleCount) active",
                            subtitle: "\(actionRuleCount) total rules",
                            symbol: "point.3.filled.connected.trianglepath.dotted",
                            detail: "Errors \(app.stats.errors)",
                            color: .indigo
                        )
                        DashboardMetricCard(
                            title: "AI Bots",
                            value: aiProviderSummary,
                            subtitle: app.settings.localAIDMReplyEnabled ? "DM replies enabled" : "DM replies disabled",
                            symbol: "sparkles",
                            detail: "Guild AI \(app.settings.behavior.useAIInGuildChannels ? "On" : "Off")",
                            color: .purple
                        )
                    }
                }

                if app.settings.clusterMode != .standalone {
                    OverviewClusterSummaryCard(
                        nodes: app.clusterNodes,
                        onOpenSwiftMesh: onOpenSwiftMesh
                    )
                }

                HStack(spacing: 12) {
                    DashboardPanel(title: "Recent Voice Events", actionTitle: "View") {
                        if recentVoice.isEmpty {
                            PlaceholderPanelLine(text: "No voice events yet")
                        } else {
                            ForEach(recentVoice) { entry in
                                PanelLine(
                                    title: entry.description,
                                    subtitle: entry.time.formatted(date: .omitted, time: .standard),
                                    tone: .green
                                )
                            }
                        }
                    }

                    DashboardPanel(title: "Recent Commands", actionTitle: "View") {
                        if recentCommands.isEmpty {
                            PlaceholderPanelLine(text: "No commands yet")
                        } else {
                            ForEach(recentCommands) { entry in
                                PanelLine(
                                    title: "\(entry.user) @ \(entry.server) • \(entry.command)",
                                    subtitle: entry.time.formatted(date: .omitted, time: .standard),
                                    tone: entry.ok ? .accentColor : .red
                                )
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    DashboardPanel(title: app.settings.clusterMode == .worker ? "Worker Activity" : "Currently In Voice") {
                        if app.settings.clusterMode == .worker {
                            InfoRow(label: "Server", value: app.clusterSnapshot.serverStatusText)
                            InfoRow(label: "Last Job", value: app.clusterSnapshot.lastJobSummary)
                            InfoRow(label: "Last Node", value: app.clusterSnapshot.lastJobNode)
                            InfoRow(label: "Diagnostics", value: app.clusterSnapshot.diagnostics)
                        } else if app.activeVoice.isEmpty {
                            PlaceholderPanelLine(text: "No one is in voice right now")
                        } else {
                            ForEach(groupedActiveVoice) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(group.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)

                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(group.members) { member in
                                            VoicePresenceMemberRow(
                                                member: member,
                                                avatarURL: app.avatarURL(forUserId: member.userId, guildId: member.guildId) ?? app.fallbackAvatarURL(forUserId: member.userId)
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 8)
                                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                        }
                    }

                    DashboardPanel(title: "Bot Info") {
                        InfoRow(label: "Uptime", value: app.settings.clusterMode == .worker ? "--" : (app.uptime?.text ?? "--"))
                        InfoRow(label: "Errors", value: "\(app.stats.errors)")
                        InfoRow(label: "State", value: app.settings.clusterMode == .worker ? app.primaryServiceStatusText : app.status.rawValue.capitalized)
                        if app.settings.clusterMode != .standalone {
                            InfoRow(label: "Cluster", value: app.clusterSnapshot.mode.rawValue)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
            .background(SwiftBotGlassBackground().opacity(0.55))
        }
    }
}

struct OverviewClusterSummaryCard: View {
    @EnvironmentObject var app: AppModel
    let nodes: [ClusterNodeStatus]
    var onOpenSwiftMesh: (() -> Void)?

    private var leaderNode: ClusterNodeStatus? {
        nodes.first(where: { $0.role == .leader }) ?? nodes.first
    }

    private var connectedNodeCount: Int {
        nodes.filter { $0.status != .disconnected }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cluster")
                .font(.headline)

            Text("\(connectedNodeCount) nodes connected")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let leaderNode {
                HStack {
                    Text("Primary")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(leaderNode.hostname) (\(leaderNode.role.displayName))")
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
            } else {
                PlaceholderPanelLine(text: "No cluster nodes available")
            }

            Button("View in SwiftMesh") {
                onOpenSwiftMesh?()
            }
            .buttonStyle(GlassActionButtonStyle())
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)
        .task(id: app.settings.clusterMode) {
            guard app.settings.clusterMode != .standalone else { return }
            await app.pollClusterStatus()
        }
    }
}

struct DashboardMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    var detail: String = ""
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 18, tint: color.opacity(0.10), stroke: color.opacity(0.28))
    }
}

struct DashboardPanel<Content: View>: View {
    let title: String
    var actionTitle: String?
    @ViewBuilder let content: Content

    init(title: String, actionTitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.actionTitle = actionTitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let actionTitle {
                    Button(actionTitle) {}
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .glassCard(cornerRadius: 22, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }
}

struct PanelLine: View {
    let title: String
    let subtitle: String
    let tone: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
    }
}

struct VoicePresenceMemberRow: View {
    let member: VoiceMemberPresence
    let avatarURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let avatarURL {
                    AsyncImage(url: avatarURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.secondary)
                                .padding(2)
                        }
                    }
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(2)
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(Circle())

            Text(member.username)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            Text("Joined \(member.joinedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    }
}

struct PlaceholderPanelLine: View {
    let text: String

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .padding(.vertical, 4)
    }
}
