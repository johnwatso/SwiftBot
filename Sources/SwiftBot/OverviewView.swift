import AppKit
import Combine
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

    private typealias MetricWidget = DashboardMetricDescriptor

    private struct MetricWidgetGroup: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let widgets: [MetricWidget]
    }

    private struct VoiceChannelGroup: Identifiable {
        let id: String
        let title: String
        let members: [VoiceMemberPresence]
    }

    private typealias OperationalStatusMetric = OverviewHealthReport.StatusTile
    private typealias OperationalActivityItem = OverviewHealthReport.ActivityItem
    private typealias AttentionItem = OverviewHealthReport.AttentionItem

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

    private var helpSummary: String {
        "\(settings.help.mode.rawValue) · \(settings.help.tone.rawValue)"
    }

    /// Shared with the admin WebUI so both surfaces agree on health.
    private var healthReport: OverviewHealthReport {
        OverviewHealthReport(.init(
            status: status,
            settings: settings,
            events: provider.events,
            commandLog: commandLog,
            rules: rules,
            clusterNodes: clusterNodes,
            clusterSnapshot: clusterSnapshot,
            diagnostics: app.connectionDiagnostics,
            lastGatewayEventName: app.lastGatewayEventName,
            intentsAccepted: app.intentsAccepted,
            lastVoiceStateAt: app.lastVoiceStateAt,
            lastClusterStatusSuccessAt: app.lastClusterStatusSuccessAt,
            patchyLastCycleAt: provider.patchyLastCycleAt,
            patchyIsCycleRunning: provider.patchyIsCycleRunning,
            memoryText: OverviewHealthReport.memoryText(samples: memorySamples)
        ))
    }

    private var operationalHealth: OverviewHealthReport.State { healthReport.overall }
    private var operationalHealthTitle: String { healthReport.overallTitle }
    private var operationalStatusMetrics: [OperationalStatusMetric] { healthReport.tiles }
    private var liveActivityItems: [OperationalActivityItem] { healthReport.activity }
    private var attentionItems: [AttentionItem] { healthReport.attention }

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

    private var availableMetricGroups: [MetricWidgetGroup] {
        [
            MetricWidgetGroup(
                id: "overview",
                title: "Overview",
                symbol: "speedometer",
                widgets: overviewSystemMetrics
            ),
            MetricWidgetGroup(
                id: "appleIntelligence",
                title: "Apple Intelligence",
                symbol: "apple.intelligence",
                widgets: AppleIntelligenceDashboardSummary.metrics(app: app)
            ),
            MetricWidgetGroup(
                id: "swiftMesh",
                title: "SwiftMesh",
                symbol: "point.3.connected.trianglepath.dotted",
                widgets: SwiftMeshDashboardSummary.metrics(app: app)
            ),
            MetricWidgetGroup(
                id: "automations",
                title: "Automations",
                symbol: "bolt.badge.automatic.fill",
                widgets: AutomationDashboardSummary.metrics(app: app, category: .automation)
            ),
            MetricWidgetGroup(
                id: "moderation",
                title: "Moderation",
                symbol: "shield.lefthalf.filled",
                widgets: AutomationDashboardSummary.metrics(app: app, category: .moderation)
            ),
            MetricWidgetGroup(
                id: "commands",
                title: "Commands",
                symbol: "terminal.fill",
                widgets: CommandsDashboardSummary.metrics(app: app)
            ),
            MetricWidgetGroup(
                id: "patchy",
                title: "Patchy",
                symbol: "square.and.arrow.down.badge.checkmark.fill",
                widgets: PatchyDashboardSummary.metrics(app: app)
            ),
            MetricWidgetGroup(
                id: "sweep",
                title: "Sweep",
                symbol: "rectangle.stack.fill.badge.minus",
                widgets: SweepDashboardSummary.metrics(service: app.sweepService)
            ),
            MetricWidgetGroup(
                id: "wikiBridge",
                title: "Lookup",
                symbol: "rectangle.and.text.magnifyingglass",
                widgets: WikiBridgeDashboardSummary.metrics(app: app)
            ),
            MetricWidgetGroup(
                id: "recordings",
                title: "Recordings",
                symbol: "film.fill",
                widgets: [RecordingsDashboardSummary.overviewMetric(app: app)]
            ),
            MetricWidgetGroup(
                id: "activity",
                title: "Activity",
                symbol: "list.bullet.clipboard.fill",
                widgets: ActivityDashboardSummary.metrics(app: app)
            ),
            MetricWidgetGroup(
                id: "analytics",
                title: "Analytics",
                symbol: "chart.line.uptrend.xyaxis",
                widgets: AnalyticsDashboardSummary.metrics(app: app)
            )
        ]
    }

    private var availableMetricWidgets: [MetricWidget] {
        uniqueMetrics(availableMetricGroups.flatMap(\.widgets))
    }

    private var overviewSystemMetrics: [MetricWidget] {
        var widgets: [MetricWidget] = [
            MetricWidget(
                id: "status",
                title: "Status",
                value: settings.clusterMode == .worker ? app.primaryServiceStatusText : status.rawValue.capitalized,
                subtitle: settings.clusterMode == .worker ? clusterSnapshot.serverStatusText : (uptime?.text ?? "--"),
                symbol: "bolt.horizontal.circle.fill",
                detail: "Auto Start \(settings.autoStart ? "On" : "Off")",
                color: .green
            )
        ]

        if settings.clusterMode == .worker {
            widgets.append(
                MetricWidget(
                    id: "listenPort",
                    title: "Listen Port",
                    value: "\(clusterSnapshot.listenPort)",
                    subtitle: "worker HTTP service",
                    symbol: "antenna.radiowaves.left.and.right",
                    detail: "Node \(settings.clusterNodeName.isEmpty ? "Unnamed" : settings.clusterNodeName)",
                    color: .blue
                )
            )
        } else {
            widgets.append(
                MetricWidget(
                    id: "servers",
                    title: "Servers",
                    value: "\(connectedServers.count)",
                    subtitle: "servers connected",
                    symbol: "server.rack",
                    detail: settings.clusterMode == .standalone ? "Standalone" : settings.clusterMode.displayName,
                    color: .blue
                )
            )
        }

        widgets.append(
            MetricWidget(
                id: "inVoice",
                title: "In Voice",
                value: "\(activeVoice.count)",
                subtitle: "users right now",
                symbol: "person.3.sequence.fill",
                detail: settings.clusterMode == .worker ? "Live presence" : "Route \(clusterSnapshot.lastJobRoute.rawValue.capitalized)",
                color: .orange
            )
        )
        return widgets
    }

    private var defaultMetricIDs: [String] {
        let defaults = ["appleIntelligence", "status", "inVoice"]
        let availableIDs = Set(availableMetricWidgets.map(\.id))
        return defaults.filter { availableIDs.contains($0) }
    }

    private func uniqueMetrics(_ metrics: [MetricWidget]) -> [MetricWidget] {
        var seen = Set<String>()
        return metrics.filter { metric in
            guard !seen.contains(metric.id) else { return false }
            seen.insert(metric.id)
            return true
        }
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

    private var hiddenMetricGroups: [MetricWidgetGroup] {
        let visibleIDs = Set(orderedVisibleMetricWidgets.map(\.id))
        return availableMetricGroups.compactMap { group in
            let widgets = group.widgets.filter { !visibleIDs.contains($0.id) }
            guard !widgets.isEmpty else { return nil }
            return MetricWidgetGroup(id: group.id, title: group.title, symbol: group.symbol, widgets: widgets)
        }
    }

    private var shouldShowSwiftMeshOverviewMap: Bool {
        settings.clusterMode == .leader || settings.clusterMode == .standby
    }

    private var canResetDashboard: Bool {
        let defaultIDs = defaultMetricIDs
        let availableIDs = Set(availableMetricWidgets.map(\.id))
        let normalizedOrder = metricOrder.filter { availableIDs.contains($0) }
        let defaultHiddenIDs = availableIDs.subtracting(defaultIDs)
        return normalizedOrder != defaultIDs || hiddenMetricIDs != defaultHiddenIDs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            overviewHeader
                .padding(.horizontal, 16)
                .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                metricStrip

                if shouldShowSwiftMeshOverviewMap {
                    OverviewClusterMapCard(
                        nodes: clusterNodes,
                        onOpenSwiftMesh: onOpenSwiftMesh
                    )
                }

                operationalStatusCard

                HStack(alignment: .top, spacing: 16) {
                    liveActivityCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    attentionRequiredCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, 16)
            }
            .fadingEdges(top: 16, bottom: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    if hiddenMetricGroups.isEmpty {
                        Text("No hidden widgets")
                    } else {
                        ForEach(hiddenMetricGroups) { group in
                            Section {
                                ForEach(group.widgets) { widget in
                                    Button {
                                        hiddenMetricIDs.remove(widget.id)
                                        if !metricOrder.contains(widget.id) {
                                            metricOrder.append(widget.id)
                                        }
                                        persistDashboardPreferences()
                                    } label: {
                                        Label(widget.title, systemImage: widget.symbol)
                                    }
                                }
                            } header: {
                                Label(group.title, systemImage: group.symbol)
                            }
                        }
                    }
                } label: {
                    Label("Add Widget", systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)

                Button("Reset") {
                    metricOrder = defaultMetricIDs
                    hiddenMetricIDs = Set(availableMetricWidgets.map(\.id)).subtracting(defaultMetricIDs)
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
        LazyVGrid(columns: DashboardMetricGrid.columns, spacing: DashboardMetricGrid.spacing) {
            ForEach(orderedVisibleMetricWidgets) { widget in
                ZStack(alignment: .topTrailing) {
                    DashboardMetricCard(
                        metric: widget
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
                HStack(spacing: 10) {
                    liveStatusPulse(color: operationalHealth.color)
                    Text("Operational Status")
                        .font(.title3.weight(.bold))
                }
                Spacer(minLength: 18)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(operationalHealthTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(operationalHealth.color)
                    Text(uptime?.text ?? currentNodeModeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 180), spacing: 12)
            ], spacing: 12) {
                ForEach(operationalStatusMetrics) { metric in
                    operationalStatusTile(metric)
                }
            }
        }
        .padding(20)
        .dashboardSurface(
            cornerRadius: 18,
            fillOpacity: 0.045,
            strokeOpacity: 0.08,
            shadowOpacity: 0.025
        )
    }

    private func operationalStatusTile(_ metric: OperationalStatusMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: metric.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(metric.state.color)
                    .frame(width: 22, height: 22)
                    .background(metric.state.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(metric.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(metric.state.color)
                    .frame(width: 5, height: 5)
            }
            Text(metric.value)
                .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(metric.detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.04), lineWidth: 1)
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
        .dashboardSurface(
            cornerRadius: 18,
            fillOpacity: 0.038,
            strokeOpacity: 0.075,
            shadowOpacity: 0.02
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

    private var currentNodeModeLabel: String {
        switch settings.clusterMode {
        case .standalone: return "Standalone"
        case .leader: return "Primary"
        case .standby: return "Failover"
        case .worker: return "Worker"
        }
    }

    private func recordMemorySample() {
        let bytes = OverviewHealthReport.residentMemoryBytes()
        guard bytes > 0 else { return }
        memorySamples.append(bytes)
        if memorySamples.count > Self.memorySampleCapacity {
            memorySamples.removeFirst(memorySamples.count - Self.memorySampleCapacity)
        }
    }

    private func syncDashboardPreferences() {
        let availableIDs = availableMetricWidgets.map(\.id)
        if metricOrderStorage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           metricHiddenStorage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metricOrder = defaultMetricIDs
            hiddenMetricIDs = Set(availableIDs).subtracting(defaultMetricIDs)
            persistDashboardPreferences()
            return
        }

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

struct OverviewClusterMapCard: View {
    @EnvironmentObject var provider: AnyBotDataProvider
    @EnvironmentObject var app: AppModel
    let nodes: [ClusterNodeStatus]
    var onOpenSwiftMesh: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("SwiftMesh")
                    .font(.headline.weight(.semibold))
                Spacer()
                Button {
                    onOpenSwiftMesh?()
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .padding(6)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Open SwiftMesh")
            }

            if app.clusterSnapshot.isHandoverTestActive || app.clusterSnapshot.scheduledHandoverTestAt != nil {
                ClusterMapHandoverNotice(
                    isActive: app.clusterSnapshot.isHandoverTestActive,
                    scheduledAt: app.clusterSnapshot.scheduledHandoverTestAt,
                    endsAt: app.clusterSnapshot.handoverTestEndsAt
                )
            }
            if nodes.isEmpty {
                PlaceholderPanelLine(text: "Waiting for /cluster/status ...")
                    .frame(height: 118, alignment: .center)
            } else {
                ClusterMapView(nodes: nodes, presentation: .overview)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .accessibilityLabel("SwiftMesh Cluster Map")
        .dashboardSurface(
            cornerRadius: 18,
            fillOpacity: 0.045,
            strokeOpacity: 0.08,
            shadowOpacity: 0.025
        )
        .task(id: provider.settings.clusterMode) {
            guard provider.settings.clusterMode == .leader || provider.settings.clusterMode == .standby else { return }
            await app.pollClusterStatus()
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
        .dashboardSurface(cornerRadius: 18, fillOpacity: 0.038, strokeOpacity: 0.075, shadowOpacity: 0.02)
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

// MARK: - Health colors

extension OverviewHealthReport.State {
    var color: Color {
        switch self {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        case .neutral: return .secondary
        }
    }
}

extension OverviewHealthReport.AttentionItem.Severity {
    var color: Color {
        switch self {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}

extension OverviewHealthReport.ActivityItem {
    var color: Color {
        switch tone {
        case .join: return .green
        case .leave: return .red
        case .move: return .blue
        case .command: return .cyan
        case .commandFailed: return .red
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        case .patchy: return .purple
        }
    }
}
