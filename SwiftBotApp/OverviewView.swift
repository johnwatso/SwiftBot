import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Overview view that works with any BotDataProvider (local or remote).
/// Uses the provider protocol to access bot data, enabling a unified UI shell.
struct OverviewView: View {
    /// The bot data provider (injected via environment from unified shell)
    @EnvironmentObject var provider: AnyBotDataProvider
    @EnvironmentObject var app: AppModel

    var onOpenSwiftMesh: (() -> Void)?
    @AppStorage("overview.metric.order.v1") private var metricOrderStorage = ""
    @AppStorage("overview.metric.hidden.v1") private var metricHiddenStorage = ""
    @State private var metricOrder: [String] = []
    @State private var hiddenMetricIDs: Set<String> = []
    @State private var isEditingDashboard = false
    @State private var draggingMetricID: String?

    // Rolling memory samples for the Memory metric (smoothed instead of instantaneous).
    @State private var memorySamples: [UInt64] = []
    private let memorySampleTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private static let memorySampleCapacity = 36 // ~3 minutes at 5s cadence

    private struct MetricWidget: Identifiable {
        let id: String
        let title: String
        let value: String
        let subtitle: String
        let symbol: String
        let detail: String
        let color: Color
    }

    private struct VoiceChannelGroup: Identifiable {
        let id: String
        let title: String
        let members: [VoiceMemberPresence]
    }

    private struct OperationalStatusMetric: Identifiable {
        enum State {
            case healthy
            case warning
            case critical
            case neutral

            var color: Color {
                switch self {
                case .healthy: return .green
                case .warning: return .orange
                case .critical: return .red
                case .neutral: return .secondary
                }
            }
        }

        let id: String
        let title: String
        let value: String
        let detail: String
        let symbol: String
        let state: State
    }

    private struct OperationalActivityItem: Identifiable {
        let id: String
        let timestamp: Date
        let title: String
        let detail: String
        let symbol: String
        let color: Color
    }

    private struct AttentionItem: Identifiable {
        enum Severity: Int {
            case critical = 3
            case warning = 2
            case info = 1

            var color: Color {
                switch self {
                case .critical: return .red
                case .warning: return .orange
                case .info: return .blue
                }
            }

            var label: String {
                switch self {
                case .critical: return "Action"
                case .warning: return "Review"
                case .info: return "Note"
                }
            }

            var symbol: String {
                switch self {
                case .critical: return "exclamationmark.octagon.fill"
                case .warning: return "exclamationmark.triangle.fill"
                case .info: return "info.circle.fill"
                }
            }
        }

        let id: String
        let title: String
        let detail: String
        let severity: Severity
    }

    // MARK: - Data Access via Provider

    private var settings: BotSettings { provider.settings }
    private var status: BotStatus { provider.status }
    private var stats: StatCounter { provider.stats }
    private var voiceLog: [VoiceEventLogEntry] { provider.voiceLog }
    private var commandLog: [CommandLogEntry] { provider.commandLog }
    private var activeVoice: [VoiceMemberPresence] { provider.activeVoice }
    private var uptime: UptimeInfo? { provider.uptime }
    private var connectedServers: [String: String] { provider.connectedServers }
    private var clusterSnapshot: ClusterSnapshot { provider.clusterSnapshot }
    private var clusterNodes: [ClusterNodeStatus] { provider.clusterNodes }
    private var rules: [Rule] { provider.rules }

    private var recentVoice: [VoiceEventLogEntry] {
        Array(voiceLog.prefix(5))
    }

    private var recentCommands: [CommandLogEntry] {
        Array(commandLog.prefix(5))
    }

    private var workerJobCount: Int {
        commandLog.filter { $0.executionRoute == "Worker" || $0.executionRoute == "Remote" }.count
    }

    private var aiProviderSummary: String {
        settings.preferredAIProvider.rawValue
    }

    private var enabledWikiSourceCount: Int {
        settings.wikiBot.sources.filter(\.enabled).count
    }

    private var enabledWikiCommandCount: Int {
        settings.wikiBot.sources
            .filter(\.enabled)
            .reduce(into: 0) { count, source in
                count += source.commands.filter(\.enabled).count
            }
    }

    private var patchyTargetCount: Int {
        settings.patchy.sourceTargets.count
    }

    private var patchyEnabledTargetCount: Int {
        settings.patchy.sourceTargets.filter(\.isEnabled).count
    }

    private var enabledActionRuleCount: Int {
        rules.filter(\.isEnabled).count
    }

    private var helpSummary: String {
        "\(settings.help.mode.rawValue) · \(settings.help.tone.rawValue)"
    }

    private var failedCommandsToday: Int {
        commandLog.filter { Calendar.current.isDateInToday($0.time) && !$0.ok }.count
    }

    private var eventThroughputPerMinute: Double {
        let cutoff = Date().addingTimeInterval(-300)
        return Double(provider.events.filter { $0.timestamp >= cutoff }.count) / 5.0
    }

    private var queueLoad: Double {
        min(Double(provider.events.count) / 20.0, 1.0)
    }

    private var operationalHealth: OperationalStatusMetric.State {
        if status == .reconnecting || app.connectionDiagnostics.lastGatewayCloseCode != nil || failedCommandsToday >= 5 {
            return .critical
        }
        if status == .connecting || queueLoad >= 0.70 || failedCommandsToday > 0 || app.connectionDiagnostics.heartbeatLatencyMs.map({ $0 >= 300 }) == true {
            return .warning
        }
        if status == .running || settings.clusterMode == .worker {
            return .healthy
        }
        return .neutral
    }

    private var operationalHealthTitle: String {
        switch operationalHealth {
        case .healthy: return "Nominal"
        case .warning: return "Needs Review"
        case .critical: return "Action Required"
        case .neutral: return "Offline"
        }
    }

    private var operationalHealthDetail: String {
        switch operationalHealth {
        case .healthy:
            return "Gateway, workflows, and support services are inside their normal operating band."
        case .warning:
            return "SwiftBot is running, but one or more runtime signals should be watched."
        case .critical:
            return "A connection, queue, or automation signal needs attention before the bot is fully healthy."
        case .neutral:
            return "Start SwiftBot to resume live operations and runtime monitoring."
        }
    }

    private var lastOperationalSyncDate: Date? {
        [app.lastVoiceStateAt, app.lastClusterStatusSuccessAt, provider.patchyLastCycleAt]
            .compactMap { $0 }
            .max()
    }

    private var operationalStatusMetrics: [OperationalStatusMetric] {
        let latency = app.connectionDiagnostics.heartbeatLatencyMs
        let queueDepth = provider.events.count
        let memoryText = averageMemoryText

        return [
            OperationalStatusMetric(
                id: "gateway-latency",
                title: "Gateway Latency",
                value: latency.map { "\($0) ms" } ?? "--",
                detail: app.lastGatewayEventName == "-" ? "Awaiting gateway events" : "Last event \(app.lastGatewayEventName)",
                symbol: "antenna.radiowaves.left.and.right",
                state: latency.map { $0 >= 300 ? .warning : .healthy } ?? (status == .running ? .warning : .neutral)
            ),
            OperationalStatusMetric(
                id: "cluster-role",
                title: "Cluster Role",
                value: settings.clusterMode.displayName,
                detail: settings.clusterNodeName.isEmpty ? clusterSnapshot.nodeName : settings.clusterNodeName,
                symbol: "point.3.connected.trianglepath.dotted",
                state: clusterNodes.contains(where: { $0.status == .disconnected }) ? .warning : .healthy
            ),
            OperationalStatusMetric(
                id: "last-sync",
                title: "Last Sync",
                value: lastOperationalSyncDate.map { relativeText(since: $0) } ?? "--",
                detail: app.lastVoiceStateAt == nil ? "No voice state yet" : "Voice state observed",
                symbol: "arrow.triangle.2.circlepath",
                state: lastOperationalSyncDate == nil ? .neutral : .healthy
            ),
            OperationalStatusMetric(
                id: "workflows",
                title: "Active Workflows",
                value: "\(enabledActionRuleCount)",
                detail: "\(rules.count) configured rules",
                symbol: "wand.and.stars",
                state: enabledActionRuleCount > 0 ? .healthy : .warning
            ),
            OperationalStatusMetric(
                id: "queue",
                title: "Queue Health",
                value: "\(queueDepth)",
                detail: "\(String(format: "%.1f", eventThroughputPerMinute)) events/min",
                symbol: "tray.full",
                state: queueLoad >= 0.90 ? .critical : (queueLoad >= 0.70 ? .warning : .healthy)
            ),
            OperationalStatusMetric(
                id: "ai-provider",
                title: "AI Provider",
                value: aiProviderSummary,
                detail: settings.localAIDMReplyEnabled ? "DM replies on" : "DM replies off",
                symbol: "sparkles",
                state: .healthy
            ),
            OperationalStatusMetric(
                id: "memory",
                title: "Memory",
                value: memoryText,
                detail: "Average resident footprint",
                symbol: "memorychip",
                state: .neutral
            ),
            OperationalStatusMetric(
                id: "discord",
                title: "Discord Connectivity",
                value: discordConnectivityLabel,
                detail: discordConnectivityDetail,
                symbol: "checkmark.icloud",
                state: discordConnectivityState
            ),
            OperationalStatusMetric(
                id: "node-mode",
                title: "Node Mode",
                value: currentNodeModeLabel,
                detail: settings.clusterMode == .standalone ? "Local output enabled" : clusterSnapshot.serverStatusText,
                symbol: "cpu",
                state: settings.clusterMode == .standby || settings.clusterMode == .worker ? .warning : .healthy
            ),
            OperationalStatusMetric(
                id: "throughput",
                title: "Event Throughput",
                value: String(format: "%.1f/min", eventThroughputPerMinute),
                detail: "\(provider.events.count) retained runtime events",
                symbol: "waveform.path.ecg",
                state: .healthy
            )
        ]
    }

    private var liveActivityItems: [OperationalActivityItem] {
        var items = provider.events.prefix(8).map { event in
            OperationalActivityItem(
                id: "event-\(event.id)",
                timestamp: event.timestamp,
                title: activityTitle(for: event.kind),
                detail: cleanedActivityMessage(event.message),
                symbol: activitySymbol(for: event.kind),
                color: activityColor(for: event.kind)
            )
        }

        items += commandLog.prefix(4).map { command in
            OperationalActivityItem(
                id: "command-\(command.id)",
                timestamp: command.time,
                title: command.ok ? "Command Executed" : "Command Failed",
                detail: "\(command.user) ran \(command.command)",
                symbol: "terminal",
                color: command.ok ? .cyan : .red
            )
        }

        if provider.patchyIsCycleRunning {
            items.append(OperationalActivityItem(
                id: "patchy-running",
                timestamp: Date(),
                title: "Patchy Running",
                detail: "Update monitoring cycle is active",
                symbol: "hammer.fill",
                color: .purple
            ))
        } else if let lastCycle = provider.patchyLastCycleAt {
            items.append(OperationalActivityItem(
                id: "patchy-\(lastCycle.timeIntervalSince1970)",
                timestamp: lastCycle,
                title: "Patchy Checked",
                detail: "\(patchyEnabledTargetCount) targets monitored",
                symbol: "hammer",
                color: .purple
            ))
        }

        return Array(items.sorted { $0.timestamp > $1.timestamp }.prefix(10))
    }

    private var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []

        if status != .running && settings.clusterMode != .worker {
            items.append(AttentionItem(
                id: "gateway-status",
                title: "Gateway is \(status.rawValue.capitalized)",
                detail: "Live Discord operations are limited until the gateway is running.",
                severity: status == .reconnecting ? .critical : .warning
            ))
        }

        if let closeCode = app.connectionDiagnostics.lastGatewayCloseCode {
            items.append(AttentionItem(
                id: "gateway-close",
                title: "Discord gateway closed",
                detail: "Last abnormal close code: \(closeCode). Check token, intents, and permissions.",
                severity: .critical
            ))
        }

        if let latency = app.connectionDiagnostics.heartbeatLatencyMs, latency >= 300 {
            items.append(AttentionItem(
                id: "latency",
                title: "Gateway latency elevated",
                detail: "\(latency) ms heartbeat latency is above the normal operating band.",
                severity: latency >= 500 ? .critical : .warning
            ))
        }

        // Only flag a quiet feed if the gateway is healthy AND the silence is unusually long.
        // A quiet bot is not a broken bot — most servers have idle stretches.
        if status == .running,
           app.connectionDiagnostics.heartbeatLatencyMs != nil,
           let newestEventAt = provider.events.first?.timestamp {
            let lag = Date().timeIntervalSince(newestEventAt)
            if lag >= 14_400 { // 4 hours
                let hours = Int(lag / 3600)
                items.append(AttentionItem(
                    id: "event-flow-quiet",
                    title: "Runtime feed quiet",
                    detail: "No runtime events in the last \(hours) hour\(hours == 1 ? "" : "s"). The gateway is connected, so Discord activity may simply be low. Restart the bot if you expect events.",
                    severity: .info
                ))
            }
        }

        if settings.clusterMode == .worker || settings.clusterMode == .standby {
            let workerState = clusterSnapshot.workerState
            if workerState == .failed || workerState == .degraded {
                let target = settings.clusterLeaderAddress.isEmpty
                    ? "the configured primary"
                    : settings.clusterLeaderAddress
                items.append(AttentionItem(
                    id: "cluster-leader",
                    title: "Cluster primary unreachable",
                    detail: "Cannot reach \(target): \(clusterSnapshot.workerStatusText)",
                    severity: workerState == .failed ? .critical : .warning
                ))
            }
        }

        if failedCommandsToday > 0 {
            items.append(AttentionItem(
                id: "failed-commands",
                title: "Command failures today",
                detail: "\(failedCommandsToday) command\(failedCommandsToday == 1 ? "" : "s") failed and may need review.",
                severity: failedCommandsToday >= 5 ? .critical : .warning
            ))
        }

        if enabledActionRuleCount == 0 {
            items.append(AttentionItem(
                id: "rules",
                title: "No active workflows",
                detail: "Rules are configured, but none are currently enabled for automation.",
                severity: .info
            ))
        }

        let patchyWarnings = provider.patchyDebugLogs.prefix(30).filter {
            $0.localizedCaseInsensitiveContains("failed") || $0.localizedCaseInsensitiveContains("skipped")
        }.count
        if settings.patchy.monitoringEnabled && patchyEnabledTargetCount == 0 {
            items.append(AttentionItem(
                id: "patchy-targets",
                title: "Patchy has no enabled targets",
                detail: "Monitoring is on, but there are no delivery targets to check.",
                severity: .warning
            ))
        } else if patchyWarnings > 0 {
            items.append(AttentionItem(
                id: "patchy-warnings",
                title: "Patchy warnings detected",
                detail: "\(patchyWarnings) recent update-monitoring warning\(patchyWarnings == 1 ? "" : "s") appeared in the debug log.",
                severity: .warning
            ))
        }

        let degradedNodes = clusterNodes.filter { $0.status == .degraded || $0.status == .disconnected }
        if settings.clusterMode != .standalone && !degradedNodes.isEmpty {
            items.append(AttentionItem(
                id: "cluster-nodes",
                title: "SwiftMesh node health",
                detail: "\(degradedNodes.count) cluster node\(degradedNodes.count == 1 ? "" : "s") need attention.",
                severity: degradedNodes.contains(where: { $0.status == .disconnected }) ? .critical : .warning
            ))
        }

        return items.sorted {
            if $0.severity.rawValue != $1.severity.rawValue {
                return $0.severity.rawValue > $1.severity.rawValue
            }
            return $0.title < $1.title
        }
    }

    private var groupedActiveVoice: [VoiceChannelGroup] {
        let grouped = Dictionary(grouping: activeVoice) { member in
            "\(member.guildId):\(member.channelId)"
        }

        return grouped.map { key, members in
            let first = members.first
            let serverName = first.map { connectedServers[$0.guildId] ?? $0.guildId } ?? "Unknown Server"
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

    private var availableMetricWidgets: [MetricWidget] {
        if settings.clusterMode == .worker {
            return [
                MetricWidget(
                    id: "status",
                    title: "Status",
                    value: app.primaryServiceStatusText,
                    subtitle: clusterSnapshot.serverStatusText,
                    symbol: "bolt.horizontal.circle.fill",
                    detail: "Auto Start \(settings.autoStart ? "On" : "Off")",
                    color: .green
                ),
                MetricWidget(
                    id: "meshMode",
                    title: "Mesh Mode",
                    value: settings.clusterMode.displayName,
                    subtitle: settings.clusterNodeName,
                    symbol: "point.3.connected.trianglepath.dotted",
                    detail: "Primary \(settings.clusterLeaderAddress.isEmpty ? "Not set" : "Configured")",
                    color: .purple
                ),
                MetricWidget(
                    id: "listenPort",
                    title: "Listen Port",
                    value: "\(clusterSnapshot.listenPort)",
                    subtitle: "worker HTTP service",
                    symbol: "antenna.radiowaves.left.and.right",
                    detail: "Node \(settings.clusterNodeName.isEmpty ? "Unnamed" : settings.clusterNodeName)",
                    color: .blue
                ),
                MetricWidget(
                    id: "inVoice",
                    title: "In Voice",
                    value: "\(activeVoice.count)",
                    subtitle: "users right now",
                    symbol: "person.3.sequence.fill",
                    detail: "Live presence",
                    color: .orange
                ),
                MetricWidget(
                    id: "wikibridge",
                    title: "WikiBridge",
                    value: settings.wikiBot.isEnabled ? "Enabled" : "Disabled",
                    subtitle: "\(enabledWikiSourceCount) sources",
                    symbol: "book.pages.fill",
                    detail: "\(enabledWikiCommandCount) commands",
                    color: .orange
                ),
                MetricWidget(
                    id: "patchy",
                    title: "Patchy",
                    value: settings.patchy.monitoringEnabled ? "Monitoring On" : "Monitoring Off",
                    subtitle: "\(patchyEnabledTargetCount)/\(patchyTargetCount) targets",
                    symbol: "hammer.fill",
                    detail: "Jobs \(workerJobCount)",
                    color: .red
                ),
                MetricWidget(
                    id: "recentMedia",
                    title: "New Recordings",
                    value: "\(app.recentMediaCount24h)",
                    subtitle: "last 24 hours",
                    symbol: "film.fill",
                    detail: "Across media sources",
                    color: .teal
                ),
                MetricWidget(
                    id: "actions",
                    title: "Actions",
                    value: "\(enabledActionRuleCount) active",
                    subtitle: "\(rules.count) total rules",
                    symbol: "bolt.circle",
                    detail: helpSummary,
                    color: .red
                )
            ]
        }

        return [
            MetricWidget(
                id: "status",
                title: "Status",
                value: status.rawValue.capitalized,
                subtitle: uptime?.text ?? "--",
                symbol: "bolt.horizontal.circle.fill",
                detail: "Auto Start \(settings.autoStart ? "On" : "Off")",
                color: .green
            ),
            MetricWidget(
                id: "servers",
                title: "Servers",
                value: "\(connectedServers.count)",
                subtitle: "servers connected",
                symbol: "server.rack",
                detail: settings.clusterMode == .standalone ? "Standalone" : settings.clusterMode.displayName,
                color: .blue
            ),
            MetricWidget(
                id: "inVoice",
                title: "In Voice",
                value: "\(activeVoice.count)",
                subtitle: "users right now",
                symbol: "person.3.sequence.fill",
                detail: "Route \(clusterSnapshot.lastJobRoute.rawValue.capitalized)",
                color: .orange
            ),
            MetricWidget(
                id: "commandsRun",
                title: "Commands Run",
                value: "\(stats.commandsRun)",
                subtitle: "this session",
                symbol: "terminal.fill",
                detail: "Recent commands activity",
                color: .red
            ),
            MetricWidget(
                id: "recentMedia",
                title: "New Recordings",
                value: "\(app.recentMediaCount24h)",
                subtitle: "last 24 hours",
                symbol: "film.fill",
                detail: "Across media sources",
                color: .teal
            ),
            MetricWidget(
                id: "wikibridge",
                title: "WikiBridge",
                value: settings.wikiBot.isEnabled ? "Enabled" : "Disabled",
                subtitle: "\(enabledWikiSourceCount) sources",
                symbol: "book.pages.fill",
                detail: "\(enabledWikiCommandCount) commands",
                color: .mint
            ),
            MetricWidget(
                id: "patchy",
                title: "Patchy",
                value: settings.patchy.monitoringEnabled ? "Monitoring On" : "Monitoring Off",
                subtitle: "\(patchyEnabledTargetCount)/\(patchyTargetCount) targets",
                symbol: "hammer.fill",
                detail: "Help \(helpSummary)",
                color: .purple
            ),
            MetricWidget(
                id: "actions",
                title: "Actions",
                value: "\(enabledActionRuleCount) active",
                subtitle: "\(rules.count) total rules",
                symbol: "bolt.circle",
                detail: "Errors \(stats.errors)",
                color: .indigo
            ),
            MetricWidget(
                id: "aiBots",
                title: "AI Bots",
                value: aiProviderSummary,
                subtitle: settings.localAIDMReplyEnabled ? "DM replies enabled" : "DM replies disabled",
                symbol: "sparkles",
                detail: "Guild AI \(settings.behavior.useAIInGuildChannels ? "On" : "Off")",
                color: .purple
            )
        ]
    }

    private var orderedVisibleMetricWidgets: [MetricWidget] {
        let map = Dictionary(uniqueKeysWithValues: availableMetricWidgets.map { ($0.id, $0) })
        let knownIDs = Set(map.keys)
        let orderedIDs = metricOrder.filter { knownIDs.contains($0) } + map.keys.filter { !metricOrder.contains($0) }
        return orderedIDs.compactMap { id in
            guard !hiddenMetricIDs.contains(id) else { return nil }
            return map[id]
        }
    }

    private var hiddenWidgets: [MetricWidget] {
        let visibleIDs = Set(orderedVisibleMetricWidgets.map(\.id))
        return availableMetricWidgets.filter { !visibleIDs.contains($0.id) }
    }

    private var canResetDashboard: Bool {
        let defaultOrder = availableMetricWidgets.map(\.id)
        return metricOrder != defaultOrder || !hiddenMetricIDs.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                overviewHeader
                metricStrip

                if settings.clusterMode != .standalone {
                    OverviewClusterSummaryCard(
                        nodes: clusterNodes,
                        onOpenSwiftMesh: onOpenSwiftMesh
                    )
                }

                operationalStatusCard

                connectionHealthCard

                HStack(alignment: .top, spacing: 16) {
                    liveActivityCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    attentionRequiredCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .onAppear {
            syncDashboardPreferences()
            recordMemorySample()
        }
        .onReceive(memorySampleTimer) { _ in
            recordMemorySample()
        }
        .onChange(of: settings.clusterMode) { _, _ in
            syncDashboardPreferences()
        }
        .onChange(of: isEditingDashboard) { _, isEditing in
            if !isEditing { draggingMetricID = nil }
        }
    }

    private var overviewHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ViewSectionHeader(title: "Overview", symbol: "speedometer")
                Text("Mission control for SwiftBot's live runtime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isEditingDashboard {
                Menu {
                    if hiddenWidgets.isEmpty {
                        Text("No hidden widgets")
                    } else {
                        ForEach(hiddenWidgets) { widget in
                            Button {
                                hiddenMetricIDs.remove(widget.id)
                                persistDashboardPreferences()
                            } label: {
                                Label(widget.title, systemImage: widget.symbol)
                            }
                        }
                    }
                } label: {
                    Label("Add Widget", systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)

                Button("Reset") {
                    metricOrder = availableMetricWidgets.map(\.id)
                    hiddenMetricIDs.removeAll()
                    persistDashboardPreferences()
                }
                .disabled(!canResetDashboard)
                .buttonStyle(.bordered)
            }

            Button(isEditingDashboard ? "Done" : "Edit") {
                isEditingDashboard.toggle()
            }
            .buttonStyle(GlassActionButtonStyle())
            .controlSize(.small)
        }
    }

    private var metricStrip: some View {
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 185), spacing: 12)
        ], spacing: 12) {
            ForEach(orderedVisibleMetricWidgets) { widget in
                ZStack(alignment: .topTrailing) {
                    DashboardMetricCard(
                        title: widget.title,
                        value: widget.value,
                        subtitle: widget.subtitle,
                        symbol: widget.symbol,
                        detail: widget.detail,
                        color: widget.color,
                        appleIntelligenceGlowEnabled: widget.id == "aiBots" && settings.preferredAIProvider == .apple
                    )
                    .rotationEffect(.degrees(isEditingDashboard ? wiggleAmplitude(for: widget.id) : 0))
                    .animation(
                        isEditingDashboard
                            ? .easeInOut(duration: wiggleDuration(for: widget.id))
                                .repeatForever(autoreverses: true)
                                .delay(wiggleDelay(for: widget.id))
                            : .easeOut(duration: 0.12),
                        value: isEditingDashboard
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .onDrag {
                        guard isEditingDashboard else { return NSItemProvider() }
                        draggingMetricID = widget.id
                        return NSItemProvider(object: widget.id as NSString)
                    }
                    .onDrop(of: [UTType.text], delegate: OverviewMetricDropDelegate(
                        targetID: widget.id,
                        orderedIDs: $metricOrder,
                        draggingID: $draggingMetricID,
                        isEnabled: isEditingDashboard,
                        onCommit: persistDashboardPreferences
                    ))

                    if isEditingDashboard {
                        Button {
                            hiddenMetricIDs.insert(widget.id)
                            persistDashboardPreferences()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.red)
                                .background(Circle().fill(.ultraThinMaterial))
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                    }
                }
            }
        }
    }

    private var operationalStatusCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        liveStatusPulse(color: operationalHealth.color)
                        Text("Operational Status")
                            .font(.title3.weight(.semibold))
                    }
                    Text(operationalHealthDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 18)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(operationalHealthTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(operationalHealth.color)
                    Text(uptime?.text ?? currentNodeModeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 180), spacing: 10)
            ], spacing: 10) {
                ForEach(operationalStatusMetrics) { metric in
                    operationalStatusTile(metric)
                }
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [operationalHealth.color.opacity(0.10), Color.white.opacity(0.025)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: operationalHealth.color.opacity(0.10), radius: 22, y: 10)
    }

    private func operationalStatusTile(_ metric: OperationalStatusMetric) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: metric.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(metric.state.color)
                    .frame(width: 22, height: 22)
                    .background(metric.state.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(metric.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(metric.state.color)
                    .frame(width: 6, height: 6)
            }
            Text(metric.value)
                .font(.headline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(metric.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(metric.state.color.opacity(0.16), lineWidth: 1)
        )
    }

    private var liveActivityCard: some View {
        overviewOperationsCard(title: "Live Activity", subtitle: "Runtime stream", symbol: "dot.radiowaves.left.and.right") {
            if liveActivityItems.isEmpty {
                emptyOperationsState("No live activity yet")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(liveActivityItems.enumerated()), id: \.element.id) { index, item in
                        operationalActivityRow(item)
                        if index < liveActivityItems.count - 1 {
                            Divider()
                                .opacity(0.24)
                                .padding(.leading, 34)
                        }
                    }
                }
            }
        }
    }

    private var attentionRequiredCard: some View {
        overviewOperationsCard(title: "Attention Required", subtitle: "\(attentionItems.count) item\(attentionItems.count == 1 ? "" : "s")", symbol: "exclamationmark.triangle") {
            if attentionItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No action needed")
                                .font(.subheadline.weight(.semibold))
                            Text("SwiftBot is operating inside the expected runtime band.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(attentionItems.prefix(6)) { item in
                        attentionRow(item)
                    }
                }
            }
        }
    }

    private func overviewOperationsCard<Content: View>(
        title: String,
        subtitle: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
    }

    private func operationalActivityRow(_ item: OperationalActivityItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.color)
                .frame(width: 24, height: 24)
                .background(item.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(item.timestamp, style: .relative)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private func attentionRow(_ item: AttentionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.severity.symbol)
                .font(.subheadline)
                .foregroundStyle(item.severity.color)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(item.severity.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.severity.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(item.severity.color.opacity(0.12), in: Capsule())
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.severity.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(item.severity.color.opacity(0.16), lineWidth: 1)
        )
    }

    private func emptyOperationsState(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private func liveStatusPulse(color: Color) -> some View {
        TimelineView(.animation) { timeline in
            let pulse = (sin(timeline.date.timeIntervalSince1970 * 3.0) + 1) / 2
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay {
                    Circle()
                        .stroke(color.opacity(0.26), lineWidth: 7)
                        .scaleEffect(1 + pulse * 0.55)
                        .opacity(0.28 + pulse * 0.35)
                }
        }
        .frame(width: 28, height: 28)
    }

    // MARK: - Connection Health (migrated from former Diagnostics tab)

    private var connectionHealthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Connection Health")
                    .font(.headline.weight(.semibold))
                Spacer()
                Button {
                    Task { await app.runTestConnection() }
                } label: {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!app.canRunTestConnection || app.status != .running)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                healthIndicator(
                    label: "Gateway",
                    value: app.status.rawValue.capitalized,
                    symbol: "network",
                    ok: app.status == .running
                )
                healthIndicator(
                    label: "Latency",
                    value: app.connectionDiagnostics.heartbeatLatencyMs.map { "\($0) ms" } ?? "-",
                    symbol: "waveform.path.ecg",
                    ok: app.connectionDiagnostics.heartbeatLatencyMs != nil
                )
                healthIndicator(
                    label: "REST",
                    value: restHealthLabel,
                    symbol: "arrow.up.arrow.down.circle",
                    ok: {
                        if case .ok = app.connectionDiagnostics.restHealth { return true }
                        return false
                    }()
                )
                healthIndicator(
                    label: "Rate Limit",
                    value: app.connectionDiagnostics.rateLimitRemaining.map { "\($0) rem." } ?? "-",
                    symbol: "gauge.with.needle",
                    ok: app.connectionDiagnostics.rateLimitRemaining.map { $0 > 0 } ?? true
                )
                healthIndicator(
                    label: "Permissions",
                    value: permissionsLabel,
                    symbol: "lock.shield",
                    ok: {
                        if case .ok = app.connectionDiagnostics.restHealth { return true }
                        return false
                    }()
                )
                let intentsRejected = app.connectionDiagnostics.lastGatewayCloseCode == 4014
                healthIndicator(
                    label: "Intents",
                    value: intentsRejected ? "Rejected (4014)" : (app.intentsAccepted.map { $0 ? "Accepted" : "Unknown" } ?? "-"),
                    symbol: "checklist",
                    ok: app.intentsAccepted == true && !intentsRejected
                )
            }

            if !app.connectionDiagnostics.lastTestMessage.isEmpty {
                HStack(spacing: 6) {
                    Text(app.connectionDiagnostics.lastTestMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if let at = app.connectionDiagnostics.lastTestAt {
                        Text(at, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if case let .error(code, msg) = app.connectionDiagnostics.restHealth, code > 0 {
                remediationBanner(message: msg)
            }
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
        .padding(12)
        .commandCatalogSurface(cornerRadius: 14)
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
        .commandCatalogSurface(cornerRadius: 12)
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

    private var discordConnectivityLabel: String {
        switch app.connectionDiagnostics.restHealth {
        case .ok: return "REST OK"
        case .error(let code, _): return code == 0 ? "Unavailable" : "HTTP \(code)"
        case .unknown:
            if status == .running { return "Gateway OK" }
            return "Unknown"
        }
    }

    private var discordConnectivityDetail: String {
        switch app.connectionDiagnostics.restHealth {
        case .ok:
            return app.connectionDiagnostics.rateLimitRemaining.map { "\($0) REST requests remaining" } ?? "REST probe succeeded"
        case .error(_, let message):
            return message
        case .unknown:
            return app.connectionDiagnostics.lastTestMessage.isEmpty ? "REST probe not run" : app.connectionDiagnostics.lastTestMessage
        }
    }

    private var discordConnectivityState: OperationalStatusMetric.State {
        switch app.connectionDiagnostics.restHealth {
        case .ok: return .healthy
        case .error: return .critical
        case .unknown: return status == .running ? .healthy : .neutral
        }
    }

    private var currentNodeModeLabel: String {
        switch settings.clusterMode {
        case .standalone: return "Standalone"
        case .leader: return "Primary"
        case .standby: return "Failover"
        case .worker: return "Worker"
        }
    }

    private func activityTitle(for kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .voiceJoin: return "User Joined Voice"
        case .voiceLeave: return "User Left Voice"
        case .voiceMove: return "Voice Channel Move"
        case .command: return "Command Executed"
        case .info: return "Runtime Event"
        case .warning: return "Runtime Warning"
        case .error: return "Runtime Error"
        }
    }

    private func activitySymbol(for kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .voiceJoin, .voiceLeave, .voiceMove: return "waveform"
        case .command: return "terminal"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func activityColor(for kind: ActivityEvent.Kind) -> Color {
        switch kind {
        case .voiceJoin: return .green
        case .voiceLeave: return .red
        case .voiceMove: return .blue
        case .command: return .cyan
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func cleanedActivityMessage(_ message: String) -> String {
        ["🟢 ", "🔴 ", "🔀 ", "✅ ", "⚠️ ", "❌ "].reduce(message) { cleaned, marker in
            cleaned.replacingOccurrences(of: marker, with: "")
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func relativeText(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    private var averageMemoryText: String {
        let samples = memorySamples.isEmpty ? [currentResidentMemoryBytes()] : memorySamples
        let valid = samples.filter { $0 > 0 }
        guard !valid.isEmpty else { return "--" }
        let avg = valid.reduce(UInt64(0), +) / UInt64(valid.count)
        let megabytes = Int((Double(avg) / 1_048_576).rounded())
        return "\(megabytes) MB"
    }

    private func recordMemorySample() {
        let bytes = currentResidentMemoryBytes()
        guard bytes > 0 else { return }
        memorySamples.append(bytes)
        if memorySamples.count > Self.memorySampleCapacity {
            memorySamples.removeFirst(memorySamples.count - Self.memorySampleCapacity)
        }
    }

    private func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private func syncDashboardPreferences() {
        let availableIDs = availableMetricWidgets.map(\.id)
        let parsedOrder = metricOrderStorage
            .split(separator: ",")
            .map { String($0) }
            .filter { availableIDs.contains($0) }
        metricOrder = parsedOrder + availableIDs.filter { !parsedOrder.contains($0) }

        let parsedHidden = Set(
            metricHiddenStorage
                .split(separator: ",")
                .map(String.init)
                .filter { availableIDs.contains($0) }
        )
        hiddenMetricIDs = parsedHidden
    }

    private func persistDashboardPreferences() {
        let availableIDs = Set(availableMetricWidgets.map(\.id))
        let normalizedOrder = metricOrder.filter { availableIDs.contains($0) } + availableIDs.filter { !metricOrder.contains($0) }
        metricOrder = normalizedOrder
        metricOrderStorage = normalizedOrder.joined(separator: ",")
        metricHiddenStorage = hiddenMetricIDs
            .filter { availableIDs.contains($0) }
            .sorted()
            .joined(separator: ",")
    }

    private func wiggleSeed(for id: String) -> Int {
        id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
    }

    private func wiggleAmplitude(for id: String) -> Double {
        let seed = wiggleSeed(for: id)
        let span = Double(seed % 9) / 10.0
        let sign = ((seed / 11) % 2 == 0) ? 1.0 : -1.0
        return sign * (0.6 + span)
    }

    private func wiggleDuration(for id: String) -> Double {
        let seed = wiggleSeed(for: id)
        let span = Double(seed % 6) / 100.0
        return 0.13 + span
    }

    private func wiggleDelay(for id: String) -> Double {
        let seed = wiggleSeed(for: id)
        return Double(seed % 7) / 100.0
    }
}

private struct OverviewMetricDropDelegate: DropDelegate {
    let targetID: String
    @Binding var orderedIDs: [String]
    @Binding var draggingID: String?
    let isEnabled: Bool
    let onCommit: () -> Void

    func dropEntered(info: DropInfo) {
        guard isEnabled, let draggingID, draggingID != targetID else { return }
        guard
            let from = orderedIDs.firstIndex(of: draggingID),
            let to = orderedIDs.firstIndex(of: targetID)
        else { return }

        if orderedIDs[to] != draggingID {
            withAnimation(.easeInOut(duration: 0.16)) {
                orderedIDs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
            onCommit()
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

struct OverviewClusterSummaryCard: View {
    @EnvironmentObject var provider: AnyBotDataProvider
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
        .task(id: provider.settings.clusterMode) {
            guard provider.settings.clusterMode != .standalone else { return }
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
    var appleIntelligenceGlowEnabled = false
    @State private var isHovering = false
    @State private var glowOpacity = 0.0
    @State private var playPulse = false

    private let cornerRadius: CGFloat = 22

    private var isGlowActive: Bool {
        appleIntelligenceGlowEnabled && isHovering
    }

    private var shouldRenderGlow: Bool {
        isGlowActive || glowOpacity > 0.001
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        .glassCard(
            cornerRadius: cornerRadius,
            tint: color.opacity(isHovering ? 0.15 : 0.10),
            stroke: color.opacity(isHovering ? 0.38 : 0.24)
        )
        .scaleEffect(isHovering ? 1.012 : 1)
        .shadow(color: color.opacity(isHovering ? 0.14 : 0.06), radius: isHovering ? 14 : 8, y: isHovering ? 8 : 4)
        .overlay {
            if shouldRenderGlow || playPulse {
                ZStack {
                    if shouldRenderGlow {
                        IntelligenceGlowBorder(cornerRadius: cornerRadius, isAnimating: isGlowActive)
                            .opacity(glowOpacity)
                    }

                    if playPulse {
                        IntelligenceGlowPulse(cornerRadius: cornerRadius) {
                            playPulse = false
                        }
                    }
                }
            }
        }
        .onHover { hovering in
            let wasHovering = isHovering
            withAnimation(.smooth(duration: 0.18)) {
                isHovering = hovering
            }

            if hovering && appleIntelligenceGlowEnabled && !wasHovering {
                playPulse = true
            } else if !hovering {
                playPulse = false
            }

            updateGlowState()
        }
        .onAppear {
            updateGlowState(animated: false)
        }
        .onChange(of: appleIntelligenceGlowEnabled) { _, enabled in
            if !enabled {
                playPulse = false
            }
            updateGlowState()
        }
        .onDisappear {
            playPulse = false
        }
    }

    private func updateGlowState(animated: Bool = true) {
        let targetOpacity = isGlowActive ? 1.0 : 0.0

        if animated {
            withAnimation(.easeInOut(duration: isGlowActive ? 0.18 : 0.32)) {
                glowOpacity = targetOpacity
            }
        } else {
            glowOpacity = targetOpacity
        }
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
