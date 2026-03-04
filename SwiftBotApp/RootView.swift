import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: SidebarItem = .overview
    @State private var showToken = false

    var body: some View {
        NavigationSplitView {
            DashboardSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 280)
        } detail: {
            Group {
                switch selection {
                case .overview:
                    OverviewView(onOpenSwiftMesh: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = .swiftMesh
                        }
                    })
                case .patchy: PatchyView()
                case .voice: VoiceView()
                case .commands: CommandsView()
                case .wikiBridge: WikiBridgeView()
                case .logs: LogsView()
                case .settings: GeneralSettingsView(showToken: $showToken)
                case .aiBots: AIBotsView()
                case .diagnostics: DiagnosticsView()
                case .swiftMesh: SwiftMeshView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SwiftBotGlassBackground())
            .navigationTitle(windowTitle)
        }
        .navigationSplitViewStyle(.balanced)
        .background(SwiftBotGlassBackground())
    }
    
    private var windowTitle: String {
        if app.status == .running {
            return "\(app.botUsername) - SwiftBot"
        } else {
            return "SwiftBot Dashboard"
        }
    }
}

struct DashboardSidebar: View {
    @EnvironmentObject var app: AppModel
    @Binding var selection: SidebarItem
    @Namespace private var selectionHighlightNamespace

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                Group {
                    if let avatarURL = app.botAvatarURL {
                        AsyncImage(url: avatarURL) { phase in
                            switch phase {
                            case .empty:
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 56, height: 56)
                                    ProgressView()
                                        .tint(.white)
                                }
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 56, height: 56)
                                    .clipShape(Circle())
                            case .failure:
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "cpu.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                }
                            @unknown default:
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "cpu.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    } else {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 56, height: 56)
                            Image(systemName: "cpu.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                    }
                }

                VStack(spacing: 2) {
                    Text(app.botUsername)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(app.primaryServiceIsOnline ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(app.primaryServiceStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: clusterIcon)
                            .font(.caption2)
                        Text(app.clusterSnapshot.mode.rawValue)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .sidebarProfileCard()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SidebarSection(title: "Dashboard") {
                        SidebarRow(item: .overview, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                    }

                    SidebarSection(title: "Automation") {
                        SidebarRow(item: .commands, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                        SidebarRow(item: .voice, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace, count: app.activeVoice.count)
                        SidebarRow(item: .patchy, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                        SidebarRow(item: .wikiBridge, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                    }

                    SidebarSection(title: "System") {
                        SidebarRow(item: .aiBots, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                        SidebarRow(item: .settings, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                        SidebarRow(item: .diagnostics, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                        SidebarRow(item: .logs, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                    }

                    SidebarSection(title: "Infrastructure") {
                        SidebarRow(item: .swiftMesh, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            Group {
                if !isPrimaryServiceRunning {
                    Button {
                        Task { await app.startBot() }
                    } label: {
                        Label(startButtonTitle, systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        app.stopBot()
                    } label: {
                        Label(stopButtonTitle, systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .controlSize(.large)
        }
        .padding(12)
        .background(Color.clear)
    }

    private var isPrimaryServiceRunning: Bool {
        app.settings.clusterMode == .worker ? app.isWorkerServiceRunning : app.status != .stopped
    }

    private var clusterIcon: String {
        switch app.settings.clusterMode {
        case .standalone: return "desktopcomputer"
        case .leader: return "point.3.connected.trianglepath.dotted"
        case .worker: return "cpu"
        }
    }

    private var startButtonTitle: String {
        app.settings.clusterMode == .worker ? "Start Worker" : "Start Bot"
    }

    private var stopButtonTitle: String {
        app.settings.clusterMode == .worker ? "Stop Worker" : "Stop Bot"
    }
}

struct SidebarRow: View {
    let item: SidebarItem
    @Binding var selection: SidebarItem
    let selectionHighlightNamespace: Namespace.ID
    var count: Int?

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selection = item
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .frame(width: 16)
                Text(item.rawValue)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.20), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if selection == item {
                    SidebarSelectionHighlight()
                        .matchedGeometryEffect(id: "sidebarSelectionHighlight", in: selectionHighlightNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tag(item)
    }
}

private struct SidebarSelectionHighlight: View {
    @Environment(\.controlActiveState) private var controlActiveState

    private var highlightMaterial: Material {
        controlActiveState == .active ? .ultraThinMaterial : .bar
    }

    private var strokeOpacity: Double {
        controlActiveState == .active ? 0.16 : 0.10
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(highlightMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 1)
            )
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 4) {
                content
            }
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case patchy = "Patchy"
    case voice = "Actions"
    case commands = "Commands"
    case wikiBridge = "WikiBridge"
    case logs = "Logs"
    case settings = "Settings"
    case aiBots = "AI Bots"
    case diagnostics = "Diagnostics"
    case swiftMesh = "SwiftMesh"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .patchy: return "shippingbox.fill"
        case .voice: return "point.3.filled.connected.trianglepath.dotted"
        case .commands: return "terminal.fill"
        case .wikiBridge: return "book.pages.fill"
        case .logs: return "list.bullet.clipboard.fill"
        case .settings: return "gearshape.2.fill"
        case .aiBots: return "sparkles.rectangle.stack.fill"
        case .diagnostics: return "waveform.path.ecg"
        case .swiftMesh: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject var app: AppModel
    var onOpenSwiftMesh: (() -> Void)?

    private var recentVoice: [VoiceEventLogEntry] {
        Array(app.voiceLog.prefix(5))
    }

    private var recentCommands: [CommandLogEntry] {
        Array(app.commandLog.prefix(5))
    }

    private var workerJobCount: Int {
        app.commandLog.filter { $0.executionRoute == "Worker" || $0.executionRoute == "Remote" }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Overview")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                    }

                    Spacer()
                }

                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 180), spacing: 12)
                ], spacing: 12) {
                    if app.settings.clusterMode == .worker {
                        DashboardMetricCard(
                            title: "Status",
                            value: app.primaryServiceStatusText,
                            subtitle: app.clusterSnapshot.serverStatusText,
                            color: .green
                        )
                        DashboardMetricCard(
                            title: "Listen Port",
                            value: "\(app.clusterSnapshot.listenPort)",
                            subtitle: "worker HTTP service",
                            color: .blue
                        )
                        DashboardMetricCard(
                            title: "Jobs Handled",
                            value: "\(workerJobCount)",
                            subtitle: "this session",
                            color: .orange
                        )
                        DashboardMetricCard(
                            title: "Last Route",
                            value: app.clusterSnapshot.lastJobRoute.rawValue.capitalized,
                            subtitle: app.clusterSnapshot.lastJobNode,
                            color: .red
                        )
                    } else {
                        DashboardMetricCard(
                            title: "Status",
                            value: app.status.rawValue.capitalized,
                            subtitle: app.uptime?.text ?? "--",
                            color: .green
                        )
                        DashboardMetricCard(
                            title: "Servers",
                            value: "\(app.connectedServers.count)",
                            subtitle: "servers connected",
                            color: .blue
                        )
                        DashboardMetricCard(
                            title: "In Voice",
                            value: "\(app.activeVoice.count)",
                            subtitle: "users right now",
                            color: .orange
                        )
                        DashboardMetricCard(
                            title: "Commands Run",
                            value: "\(app.stats.commandsRun)",
                            subtitle: "this session",
                            color: .red
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
                            ForEach(app.activeVoice) { member in
                                PanelLine(
                                    title: "\(member.username) in \(member.channelName)",
                                    subtitle: member.joinedAt.formatted(date: .omitted, time: .shortened),
                                    tone: .indigo
                                )
                            }
                        }
                    }

                    DashboardPanel(title: "Bot Info") {
                        InfoRow(label: "Uptime", value: app.settings.clusterMode == .worker ? "--" : (app.uptime?.text ?? "--"))
                        InfoRow(label: "Prefix", value: app.settings.prefix)
                        InfoRow(label: "Errors", value: "\(app.stats.errors)")
                        InfoRow(label: "State", value: app.settings.clusterMode == .worker ? app.primaryServiceStatusText : app.status.rawValue.capitalized)
                        if app.settings.clusterMode != .standalone {
                            InfoRow(label: "Cluster", value: app.clusterSnapshot.mode.rawValue)
                        }
                    }
                }
            }
            .padding(20)
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
                    Text("Leader")
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
            .buttonStyle(.borderedProminent)
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

enum TriggerType: String, CaseIterable, Identifiable, Codable {
    case userJoinedVoice = "User Joins Voice"
    case userLeftVoice = "User Leaves Voice"
    case userMovedVoice = "User Moves Voice"
    case messageContains = "Message Contains"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .userJoinedVoice: return "person.crop.circle.badge.plus"
        case .userLeftVoice: return "person.crop.circle.badge.xmark"
        case .userMovedVoice: return "arrow.left.arrow.right.circle"
        case .messageContains: return "text.bubble"
        }
    }

    var defaultMessage: String {
        switch self {
        case .userJoinedVoice: return "🔊 <@{userId}> connected to <#{channelId}>"
        case .userLeftVoice: return "🔌 <@{userId}> disconnected from <#{channelId}> (Online for {duration})"
        case .userMovedVoice: return "🔀 <@{userId}> moved from <#{fromChannelId}> to <#{toChannelId}>"
        case .messageContains: return "nm you?"
        }
    }

    var defaultRuleName: String {
        switch self {
        case .userJoinedVoice: return "Join Action"
        case .userLeftVoice: return "Leave Action"
        case .userMovedVoice: return "Move Action"
        case .messageContains: return "Message Reply"
        }
    }

    static var allDefaultMessages: Set<String> {
        var messages = Set(allCases.map(\.defaultMessage))
        // Include legacy defaults so trigger changes still auto-populate
        messages.insert("🔊 <@{userId}> connected to <#{channelId}>")
        messages.insert("🔌 <@{userId}> disconnected from <#{channelId}>")
        messages.insert("🔀 <@{userId}> moved from <#{fromChannelId}> to <#{toChannelId}>")
        return messages
    }
}

enum ConditionType: String, CaseIterable, Identifiable, Codable {
    case server = "Server Is"
    case voiceChannel = "Voice Channel Is"
    case usernameContains = "Username Contains"
    case minimumDuration = "Duration In Channel"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .server: return "building.2"
        case .voiceChannel: return "waveform"
        case .usernameContains: return "text.magnifyingglass"
        case .minimumDuration: return "timer"
        }
    }
}

enum ActionType: String, CaseIterable, Identifiable, Codable {
    case sendMessage = "Send Message"
    case addLogEntry = "Add Log Entry"
    case setStatus = "Set Bot Status"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .sendMessage: return "paperplane.fill"
        case .addLogEntry: return "list.bullet.clipboard"
        case .setStatus: return "dot.radiowaves.left.and.right"
        }
    }
}

struct Condition: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: ConditionType
    var value: String = ""
    var secondaryValue: String = ""
    var enabled: Bool = true
}

struct RuleAction: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: ActionType = .sendMessage
    var serverId: String = ""
    var channelId: String = ""
    var mentionUser: Bool = true
    var message: String = "🔊 <@{userId}> connected to <#{channelId}>"
    var statusText: String = "Voice notifier active"
}

typealias Action = RuleAction

struct Rule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = "New Action"
    var trigger: TriggerType = .userJoinedVoice
    var conditions: [Condition] = []
    var actions: [RuleAction] = [RuleAction()]
    var isEnabled: Bool = true

    var triggerServerId: String = ""
    var triggerVoiceChannelId: String = ""
    var triggerMessageContains: String = "up to?"
    var replyToDMs: Bool = false

    var includeStageChannels: Bool = true

    var triggerSummary: String {
        switch trigger {
        case .userJoinedVoice: return "When someone joins voice"
        case .userLeftVoice: return "When someone leaves voice"
        case .userMovedVoice: return "When someone moves voice"
        case .messageContains:
            return triggerMessageContains.isEmpty ? "When message contains text" : "When message contains \"\(triggerMessageContains)\""
        }
    }
}

struct VoiceView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VoiceWorkspaceView(ruleStore: app.ruleStore)
            .environmentObject(app)
    }
}

struct VoiceWorkspaceView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var ruleStore: RuleStore
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HSplitView {
            RuleListView(
                rules: rulesBinding,
                selectedRuleID: appSelectionBinding,
                onAddNew: {
                    let sid = serverIds.first ?? ""
                    let cid = app.availableTextChannelsByServer[sid]?.first?.id ?? ""
                    ruleStore.addNewRule(serverId: sid, channelId: cid)
                },
                onDeleteOffsets: { offsets in
                    ruleStore.deleteRules(at: offsets, undoManager: undoManager)
                },
                onDeleteRuleID: { ruleID in
                    ruleStore.deleteRule(id: ruleID, undoManager: undoManager)
                },
                onDeleteSelected: {
                    if let selected = ruleStore.selectedRuleID {
                        ruleStore.deleteRule(id: selected, undoManager: undoManager)
                    }
                }
            )
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            Group {
                if let selectedRuleBinding {
                    RuleEditorView(rule: selectedRuleBinding)
                        .id(ruleStore.selectedRuleID)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Select an Action Rule")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.clear)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .padding(12)
        .onChange(of: ruleStore.rules) { _ in
            if let selected = ruleStore.selectedRuleID,
               !ruleStore.rules.contains(where: { $0.id == selected }) {
                ruleStore.selectedRuleID = nil
            }
            ruleStore.scheduleAutoSave()
        }
    }

    private var rulesBinding: Binding<[Rule]> {
        Binding(
            get: { ruleStore.rules },
            set: { ruleStore.rules = $0 }
        )
    }

    private var appSelectionBinding: Binding<UUID?> {
        Binding(
            get: { ruleStore.selectedRuleID },
            set: { ruleStore.selectedRuleID = $0 }
        )
    }

    private var selectedRuleBinding: Binding<Rule>? {
        guard let selectedRuleID = ruleStore.selectedRuleID,
              let index = ruleStore.rules.firstIndex(where: { $0.id == selectedRuleID })
        else {
            return nil
        }

        return Binding(
            get: {
                ruleStore.rules[index]
            },
            set: { updatedRule in
                guard ruleStore.rules.indices.contains(index),
                      ruleStore.rules[index].id == selectedRuleID else {
                    if let refreshedIndex = ruleStore.rules.firstIndex(where: { $0.id == selectedRuleID }) {
                        ruleStore.rules[refreshedIndex] = updatedRule
                    }
                    return
                }
                ruleStore.rules[index] = updatedRule
            }
        )
    }

    private var serverIds: [String] {
        app.connectedServers.keys.sorted {
            (app.connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(app.connectedServers[$1] ?? $1) == .orderedAscending
        }
    }
}

struct RuleListView: View {
    @Binding var rules: [Rule]
    @Binding var selectedRuleID: UUID?
    let onAddNew: () -> Void
    let onDeleteOffsets: (IndexSet) -> Void
    let onDeleteRuleID: (UUID) -> Void
    let onDeleteSelected: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RulePaneHeader(
                title: "Actions",
                subtitle: "Build reusable flows from triggers, filters, and outputs.",
                systemImage: "point.3.filled.connected.trianglepath.dotted"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button(action: onAddNew) {
                        Label("New Rule", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    LazyVStack(spacing: 10) {
                        ForEach($rules) { $rule in
                            RuleRowView(
                                rule: $rule,
                                isSelected: selectedRuleID == rule.id,
                                onSelect: {
                                    withAnimation(.snappy(duration: 0.12)) {
                                        selectedRuleID = rule.id
                                    }
                                },
                                onDelete: { onDeleteRuleID(rule.id) }
                            )
                        }
                    }

                    Button(role: .destructive, action: onDeleteSelected) {
                        Label("Delete Selected", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedRuleID == nil)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .background(rulePaneBackground)
    }

    private var rulePaneBackground: some View {
        Rectangle()
            .fill(.white.opacity(0.04))
    }
}

struct RuleRowView: View {
    @Binding var rule: Rule
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.headline)
                Text(rule.triggerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enabled", isOn: $rule.isEnabled)
                .labelsHidden()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(selectionBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? .white.opacity(0.28) : .white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onSelect)
    }

    private var selectionBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(.thinMaterial)
        }
        return AnyShapeStyle(Color.white.opacity(0.05))
    }
}

struct RuleEditorView: View {
    @Binding var rule: Rule
    @EnvironmentObject var app: AppModel

    private var serverIds: [String] {
        app.connectedServers.keys.sorted {
            (app.connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(app.connectedServers[$1] ?? $1) == .orderedAscending
        }
    }

    private func serverName(for serverId: String) -> String {
        app.connectedServers[serverId] ?? "Server \(serverId.suffix(4))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                RulePaneHeader(
                    title: "Block Library",
                    subtitle: "Reusable building blocks for this rule flow.",
                    systemImage: "square.stack.3d.up.fill"
                )

                ScrollView {
                    RuleBuilderLibraryView(
                        serverIds: serverIds,
                        onAddCondition: addCondition(_:),
                        onAddAction: addAction(_:),
                        focusTrigger: { applyTriggerDefaults(for: rule.trigger) }
                    )
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                }
            }
            .frame(minWidth: 250, idealWidth: 270, maxWidth: 300)
            .background(rulePaneBackground)

            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(width: 1)

            VStack(spacing: 0) {
                RulePaneHeader(
                    title: rule.name.isEmpty ? "Action Rule" : rule.name,
                    subtitle: rule.triggerSummary,
                    systemImage: "point.3.filled.connected.trianglepath.dotted"
                )

                TextField("Rule Name", text: $rule.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                .background(rulePaneBackground)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        RuleCanvasSection(title: "Trigger Block", systemImage: "bolt.fill", accent: .yellow) {
                            TriggerSectionView(
                                triggerType: $rule.trigger,
                                triggerServerId: $rule.triggerServerId,
                                triggerVoiceChannelId: $rule.triggerVoiceChannelId,
                                triggerMessageContains: $rule.triggerMessageContains,
                                replyToDMs: $rule.replyToDMs,
                                includeStageChannels: $rule.includeStageChannels,
                                serverIds: serverIds,
                                serverName: serverName(for:),
                                voiceChannels: app.availableVoiceChannelsByServer[rule.triggerServerId] ?? []
                            )
                        }

                        RuleFlowArrow()

                        RuleCanvasSection(title: "Filter Blocks", systemImage: "line.3.horizontal.decrease.circle", accent: .cyan) {
                            ConditionsSectionView(
                                conditions: $rule.conditions,
                                serverIds: serverIds,
                                serverName: serverName(for:),
                                voiceChannels: app.availableVoiceChannelsByServer[rule.triggerServerId] ?? []
                            )
                        }

                        RuleFlowArrow()

                        RuleCanvasSection(title: "Action Blocks", systemImage: "paperplane.fill", accent: .mint) {
                            ActionsSectionView(
                                actions: $rule.actions,
                                serverIds: serverIds,
                                serverName: serverName(for:),
                                textChannelsByServer: app.availableTextChannelsByServer
                            )
                        }
                    }
                    .frame(maxWidth: 880, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
            }
            .background(rulePaneBackground)
        }
        .navigationTitle("")
        .onAppear {
            initializeRuleDefaultsIfNeeded()
        }
        .onChange(of: rule) { _ in
            app.ruleStore.scheduleAutoSave()
        }
        .onChange(of: rule.trigger) { newTrigger in
            applyTriggerDefaults(for: newTrigger)
        }
    }

    private func addCondition(_ type: ConditionType) {
        rule.conditions.append(Condition(type: type))
        app.ruleStore.scheduleAutoSave()
    }

    private func addAction(_ type: ActionType) {
        var action = RuleAction()
        action.type = type
        action.serverId = serverIds.first ?? ""
        action.channelId = app.availableTextChannelsByServer[action.serverId]?.first?.id ?? ""
        action.message = rule.trigger.defaultMessage

        switch type {
        case .sendMessage:
            break
        case .addLogEntry:
            action.message = "Rule fired for {username}"
        case .setStatus:
            action.statusText = "Handling \(rule.trigger.rawValue.lowercased())"
        }

        rule.actions.append(action)
        app.ruleStore.scheduleAutoSave()
    }

    private func initializeRuleDefaultsIfNeeded() {
        var didChange = false

        if rule.triggerServerId.isEmpty {
            rule.triggerServerId = serverIds.first ?? ""
            didChange = true
        }

        if rule.actions.isEmpty {
            var action = RuleAction()
            action.serverId = serverIds.first ?? ""
            let channels = app.availableTextChannelsByServer[action.serverId] ?? []
            action.channelId = channels.first?.id ?? ""
            action.message = rule.trigger.defaultMessage
            rule.actions = [action]
            didChange = true
        } else {
            if rule.actions[0].serverId.isEmpty, let first = serverIds.first {
                rule.actions[0].serverId = first
                didChange = true
            }
            if rule.actions[0].channelId.isEmpty {
                let channels = app.availableTextChannelsByServer[rule.actions[0].serverId] ?? []
                if let first = channels.first {
                    rule.actions[0].channelId = first.id
                    didChange = true
                }
            }
        }

        if didChange {
            app.ruleStore.scheduleAutoSave()
        }
    }

    private func applyTriggerDefaults(for newTrigger: TriggerType) {
        let defaults = TriggerType.allDefaultMessages
        var didChange = false

        if !rule.actions.isEmpty,
           rule.actions[0].type == .sendMessage,
           defaults.contains(rule.actions[0].message) {
            rule.actions[0].message = newTrigger.defaultMessage
            didChange = true
        }

        let defaultNames = Set(TriggerType.allCases.map(\.defaultRuleName) + ["New Action", "Join Action"])
        if defaultNames.contains(rule.name) {
            rule.name = newTrigger.defaultRuleName
            didChange = true
        }

        if newTrigger == .messageContains,
           rule.triggerMessageContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rule.triggerMessageContains = "up to?"
            didChange = true
        }

        if didChange {
            app.ruleStore.scheduleAutoSave()
        }
    }

    private var rulePaneBackground: some View {
        Rectangle()
            .fill(.white.opacity(0.04))
    }
}

struct RuleBuilderLibraryView: View {
    let serverIds: [String]
    let onAddCondition: (ConditionType) -> Void
    let onAddAction: (ActionType) -> Void
    let focusTrigger: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RuleLibrarySection(title: "Start") {
                RuleLibraryButton(
                    title: "Trigger Block",
                    subtitle: "Choose the event that starts this rule",
                    systemImage: "bolt.fill",
                    accent: .yellow,
                    action: focusTrigger
                )
            }

            RuleLibrarySection(title: "Filters") {
                ForEach(ConditionType.allCases) { type in
                    RuleLibraryButton(
                        title: type.rawValue,
                        subtitle: "Add a reusable filter block",
                        systemImage: type.symbol,
                        accent: .cyan,
                        action: { onAddCondition(type) }
                    )
                }
            }

            RuleLibrarySection(title: "Actions") {
                ForEach(ActionType.allCases) { type in
                    RuleLibraryButton(
                        title: type.rawValue,
                        subtitle: "Insert this output block into the flow",
                        systemImage: type.symbol,
                        accent: .mint,
                        action: { onAddAction(type) }
                    )
                }
            }

            if serverIds.isEmpty {
                Text("Connect the bot to Discord to unlock server and channel pickers in action blocks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 4)
    }
}

struct RulePaneHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 66, alignment: .bottomLeading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
        }
    }
}

struct RuleLibrarySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
    }
}

struct RuleLibraryButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(accent)
            }
            .padding(12)
            .glassCard(cornerRadius: 18, tint: .white.opacity(0.05), stroke: .white.opacity(0.14))
        }
        .buttonStyle(.plain)
    }
}

struct RuleCanvasSection<Content: View>: View {
    let title: String
    let systemImage: String
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 22, tint: .white.opacity(0.10), stroke: .white.opacity(0.18))
    }
}

struct RuleFlowArrow: View {
    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(width: 44, height: 2)
            Image(systemName: "arrow.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(width: 44, height: 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

struct RuleGroupSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 20, tint: .white.opacity(0.10), stroke: .white.opacity(0.18))
    }
}

struct TriggerSectionView: View {
    @Binding var triggerType: TriggerType
    @Binding var triggerServerId: String
    @Binding var triggerVoiceChannelId: String
    @Binding var triggerMessageContains: String
    @Binding var replyToDMs: Bool
    @Binding var includeStageChannels: Bool

    let serverIds: [String]
    let serverName: (String) -> String
    let voiceChannels: [GuildVoiceChannel]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Event", selection: $triggerType) {
                ForEach(TriggerType.allCases) { trigger in
                    Label(trigger.rawValue, systemImage: trigger.symbol).tag(trigger)
                }
            }

            Picker("Server", selection: $triggerServerId) {
                ForEach(serverIds, id: \.self) { serverId in
                    Text(serverName(serverId)).tag(serverId)
                }
            }

            if triggerType != .messageContains, !voiceChannels.isEmpty {
                Picker("Voice Channel", selection: $triggerVoiceChannelId) {
                    Text("Any Channel").tag("")
                    ForEach(voiceChannels) { channel in
                        Text(channel.name).tag(channel.id)
                    }
                }
            }

            if triggerType == .messageContains {
                TextField("Message contains…", text: $triggerMessageContains)
                Toggle("Reply to DMs", isOn: $replyToDMs)
            }

            if triggerType == .userJoinedVoice || triggerType == .userMovedVoice {
                Toggle("Include Stage Channels", isOn: $includeStageChannels)
            }
        }
    }
}

struct ConditionsSectionView: View {
    @Binding var conditions: [Condition]

    let serverIds: [String]
    let serverName: (String) -> String
    let voiceChannels: [GuildVoiceChannel]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if conditions.isEmpty {
                Text("No conditions configured. Rules will run for all matching events.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach($conditions) { $condition in
                    ConditionRowView(
                        condition: $condition,
                        serverIds: serverIds,
                        serverName: serverName,
                        voiceChannels: voiceChannels,
                        onDelete: {
                            conditions.removeAll { $0.id == condition.id }
                        }
                    )
                }
            }

            Menu {
                ForEach(ConditionType.allCases) { type in
                    Button {
                        conditions.append(Condition(type: type))
                    } label: {
                        Label(type.rawValue, systemImage: type.symbol)
                    }
                }
            } label: {
                Label("Add Condition", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
        }
    }
}

struct ConditionRowView: View {
    @Binding var condition: Condition

    let serverIds: [String]
    let serverName: (String) -> String
    let voiceChannels: [GuildVoiceChannel]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Condition", selection: $condition.type) {
                    ForEach(ConditionType.allCases) { type in
                        Label(type.rawValue, systemImage: type.symbol).tag(type)
                    }
                }
                Toggle("Enabled", isOn: $condition.enabled)
                    .toggleStyle(.switch)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            conditionEditor
        }
        .padding(10)
        .glassCard(cornerRadius: 18, tint: .white.opacity(0.08), stroke: .white.opacity(0.16))
    }

    @ViewBuilder
    private var conditionEditor: some View {
        switch condition.type {
        case .server:
            Picker("Server", selection: $condition.value) {
                ForEach(serverIds, id: \.self) { serverId in
                    Text(serverName(serverId)).tag(serverId)
                }
            }
        case .voiceChannel:
            Picker("Voice Channel", selection: $condition.value) {
                Text("Any Channel").tag("")
                ForEach(voiceChannels) { channel in
                    Text(channel.name).tag(channel.id)
                }
            }
        case .usernameContains:
            TextField("Username contains…", text: $condition.value)
        case .minimumDuration:
            HStack {
                TextField("Minimum", text: $condition.value)
                    .frame(width: 80)
                Text("minutes in channel")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ActionsSectionView: View {
    @Binding var actions: [Action]

    let serverIds: [String]
    let serverName: (String) -> String
    let textChannelsByServer: [String: [GuildTextChannel]]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if actions.isEmpty {
                Button {
                    var action = Action()
                    action.serverId = serverIds.first ?? ""
                    action.channelId = textChannelsByServer[action.serverId]?.first?.id ?? ""
                    actions = [action]
                } label: {
                    Label("Add First Action Block", systemImage: "plus")
                }
            } else {
                ForEach($actions) { $action in
                    ActionSectionView(
                        action: $action,
                        serverIds: serverIds,
                        serverName: serverName,
                        textChannels: textChannelsByServer[action.serverId] ?? [],
                        onDelete: {
                            actions.removeAll { $0.id == action.id }
                        }
                    )
                }
            }
        }
    }
}

struct ActionSectionView: View {
    @Binding var action: Action

    let serverIds: [String]
    let serverName: (String) -> String
    let textChannels: [GuildTextChannel]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Action", selection: $action.type) {
                    ForEach(ActionType.allCases) { actionType in
                        Label(actionType.rawValue, systemImage: actionType.symbol).tag(actionType)
                    }
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            switch action.type {
            case .sendMessage:
                if serverIds.isEmpty {
                    Text("No connected servers available yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Server", selection: $action.serverId) {
                        ForEach(serverIds, id: \.self) { serverId in
                            Text(serverName(serverId)).tag(serverId)
                        }
                    }
                }

                if textChannels.isEmpty {
                    Text("No text channels discovered for this server.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Text Channel", selection: $action.channelId) {
                        ForEach(textChannels) { channel in
                            Text("#\(channel.name)").tag(channel.id)
                        }
                    }
                }

                Toggle("Mention user in message", isOn: $action.mentionUser)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Message")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $action.message)
                        .frame(minHeight: 120)
                        .padding(6)
                        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                        )
                }
            case .addLogEntry:
                TextField("Log message", text: $action.message)
            case .setStatus:
                TextField("Status text", text: $action.statusText)
            }

            Text("Use placeholders in messages: {userId}, {username}, {channelId}, {channelName}, {guildName}, {duration}")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .glassCard(cornerRadius: 18, tint: .white.opacity(0.06), stroke: .white.opacity(0.16))
        .onAppear {
            if action.serverId.isEmpty {
                action.serverId = serverIds.first ?? ""
            }
            if action.channelId.isEmpty {
                action.channelId = textChannels.first?.id ?? ""
            }
        }
        .onChange(of: action.serverId) { _ in
            action.channelId = textChannels.first?.id ?? ""
        }
    }
}

struct CommandsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commands")
                .font(.system(size: 30, weight: .bold, design: .rounded))

            Table(app.commandLog) {
                TableColumn("Time") { Text($0.time.formatted(date: .omitted, time: .standard)) }
                TableColumn("User") { Text($0.user) }
                TableColumn("Server") { Text($0.server) }
                TableColumn("Command") { Text($0.command) }
                TableColumn("Channel") { Text($0.channel) }
                TableColumn("Route") { Text($0.executionRoute) }
                TableColumn("Executed On") { Text($0.executionNode) }
                TableColumn("Status") { entry in
                    Text(entry.ok ? "OK" : "ERROR")
                        .foregroundStyle(entry.ok ? .green : .red)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .glassCard(cornerRadius: 20, tint: .white.opacity(0.08), stroke: .white.opacity(0.18))
        }
        .padding(20)
    }
}

struct LogsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Logs")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Spacer()
                Button("Clear") { app.logs.clear() }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.logs.fullLog(), forType: .string)
                }
                Toggle("Auto-scroll", isOn: $app.logs.autoScroll)
                    .toggleStyle(.switch)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(app.logs.lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.contains("❌") ? .red : (line.contains("⚠️") ? .yellow : .green))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(12)
                }
                .glassCard(cornerRadius: 20, tint: .black.opacity(0.04), stroke: .white.opacity(0.16))
                .onChange(of: app.logs.lines.count) { _ in
                    if app.logs.autoScroll, let last = app.logs.lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .padding(20)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var updater: AppUpdater
    @Binding var showToken: Bool
    @State private var prefixDraft = "!"
    @State private var clusterNodeNameDraft = ""
    @State private var leaderAddressDraft = ""
    @State private var listenPortDraft = ""

    private let allowedPrefixes = ["$", "#", "!", "?", "%"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.system(size: 30, weight: .bold, design: .rounded))

            Form {
                HStack {
                    Group {
                        if showToken {
                            TextField("Bot Token", text: $app.settings.token)
                        } else {
                            SecureField("Bot Token", text: $app.settings.token)
                        }
                    }
                    Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                }

                Picker("Command Prefix", selection: $prefixDraft) {
                    ForEach(allowedPrefixes, id: \.self) { prefix in
                        Text(prefix).tag(prefix)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Auto Start", isOn: $app.settings.autoStart)

                Section("SwiftMesh") {
                    Picker("Mode", selection: $app.settings.clusterMode) {
                        ForEach(ClusterMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("Node Name", text: $clusterNodeNameDraft)

                    if app.settings.clusterMode == .worker {
                        TextField("Leader Address", text: $leaderAddressDraft)

                        HStack {
                            Button("Test Connection") {
                                app.settings.clusterNodeName = clusterNodeNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                app.settings.clusterLeaderAddress = leaderAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                app.settings.clusterListenPort = Int(listenPortDraft) ?? 38787
                                app.testWorkerLeaderConnection()
                            }
                            .buttonStyle(.bordered)
                            .disabled(app.workerConnectionTestInProgress)

                            if app.workerConnectionTestInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        Text(app.workerConnectionTestStatus)
                            .font(.caption)
                            .foregroundStyle(
                                app.workerConnectionTestIsSuccess
                                    ? .green
                                    : (app.workerConnectionTestStatus == "Not tested" || app.workerConnectionTestInProgress
                                        ? .secondary
                                        : .red)
                            )
                    }

                    if app.settings.clusterMode == .leader {
                        TextField("Listen Port", text: $listenPortDraft)
                    }

                    Text(app.settings.clusterMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if app.settings.clusterMode == .worker {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Worker Control")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            HStack {
                                if app.isWorkerServiceRunning {
                                    Button("Stop Worker") {
                                        app.stopBot()
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                } else {
                                    Button("Start Worker") {
                                        app.settings.clusterNodeName = clusterNodeNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                        app.settings.clusterLeaderAddress = leaderAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                        app.settings.clusterListenPort = Int(listenPortDraft) ?? 38787
                                        Task { await app.startBot() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cluster Status")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Refresh SwiftMesh Status") {
                                app.refreshClusterStatus()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Text(app.settings.clusterMode == .worker ? app.clusterSnapshot.serverStatusText : app.clusterSnapshot.workerStatusText)
                        .font(.caption)
                        .foregroundStyle((app.clusterSnapshot.workerState == .connected || app.clusterSnapshot.serverState == .listening) ? .green : .secondary)
                }

                Section("Software Updates") {
                    LabeledContent("Updater") {
                        Text(updater.isConfigured ? "Configured" : "Not Configured")
                            .foregroundStyle(updater.isConfigured ? .green : .secondary)
                    }

                    LabeledContent("Feed URL Found") {
                        Text(updater.feedURLString.isEmpty ? "No" : "Yes")
                            .foregroundStyle(updater.feedURLString.isEmpty ? Color.secondary : Color.green)
                    }

                    LabeledContent("Public Key Found") {
                        Text(updater.hasPublicKey ? "Yes" : "No")
                            .foregroundStyle(updater.hasPublicKey ? Color.green : Color.secondary)
                    }

                    if updater.isConfigured {
                        LabeledContent("Feed URL") {
                            Text(updater.feedURLString)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Button("Check for Updates...") {
                            updater.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!updater.canCheckForUpdates)
                    } else {
                        Text("Set `SUFeedURL` and `SUPublicEDKey` in the app target build settings to enable Sparkle updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Bundle") {
                        Text(updater.bundlePath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Button("Save") {
                    app.settings.prefix = prefixDraft
                    app.settings.clusterNodeName = clusterNodeNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    app.settings.clusterLeaderAddress = leaderAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    app.settings.clusterListenPort = Int(listenPortDraft) ?? 38787
                    app.saveSettings()
                    prefixDraft = app.settings.prefix
                    clusterNodeNameDraft = app.settings.clusterNodeName
                    leaderAddressDraft = app.settings.clusterLeaderAddress
                    listenPortDraft = "\(app.settings.clusterListenPort)"
                }
                .buttonStyle(.borderedProminent)

                Link("Discord Developer Portal", destination: URL(string: "https://discord.com/developers/applications")!)
            }
            .onAppear {
                prefixDraft = allowedPrefixes.contains(app.settings.prefix) ? app.settings.prefix : "!"
                clusterNodeNameDraft = app.settings.clusterNodeName
                leaderAddressDraft = app.settings.clusterLeaderAddress
                listenPortDraft = "\(app.settings.clusterListenPort)"
            }
            .onChange(of: app.settings.prefix) { newValue in
                prefixDraft = allowedPrefixes.contains(newValue) ? newValue : "!"
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .glassCard(cornerRadius: 24, tint: .white.opacity(0.08), stroke: .white.opacity(0.16))
        }
        .padding(20)
    }
}

struct AIBotsView: View {
    @EnvironmentObject var app: AppModel

    private enum AISettingKey {
        static let enableReplies = "ai.enableReplies"
        static let guildChannels = "ai.useGuildTextChannels"
        static let allowDMs = "ai.allowDirectMessages"
        static let primaryEngine = "ai.primaryEngine"
        static let ollamaHost = "ai.ollamaHost"
        static let ollamaModel = "ai.ollamaModel"
        static let systemPrompt = "ai.systemPrompt"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("AI Bots")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                overviewCard
                MemoryOverviewView(viewModel: app.memoryViewModel)
                configurationCard
            }
            .padding(20)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .task {
            await app.refreshAIStatus()
            syncProviderSelectionFromPreference()
        }
        .onChange(of: app.settings.preferredAIProvider) { _, _ in
            syncProviderSelectionFromPreference()
            Task { await app.refreshAIStatus() }
            if app.settings.preferredAIProvider == .ollama {
                app.detectOllamaModel()
            }
        }
        .onChange(of: app.settings.ollamaBaseURL) { _, _ in
            Task { await app.refreshAIStatus() }
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI Engines")
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 12) {
                providerIcon(imageName: "AIAppleLogo", fallbackSystemImage: "apple.intelligence")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple Intelligence")
                        .font(.headline.weight(.semibold))
                    Text("System-native engine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusStack(isOnline: app.appleIntelligenceOnline, isPrimary: app.settings.preferredAIProvider == .apple)
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                providerIcon(imageName: "AIOllamaLogo", fallbackSystemImage: "server.rack")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ollama")
                        .font(.headline)
                    if let model = app.ollamaDetectedModel, !model.isEmpty {
                        Text("Active model: \(model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let host = app.settings.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !host.isEmpty {
                        Text("Server: \(host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                statusStack(isOnline: app.ollamaOnline, isPrimary: app.settings.preferredAIProvider == .ollama)
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 24, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configuration")
                .font(.title3.weight(.semibold))

            SettingsView(sections: aiSettingsSections, values: aiSettingsValues)
                .scrollContentBackground(.hidden)
                .background(Color.clear)

            if app.settings.preferredAIProvider == .ollama {
                HStack {
                    Spacer()
                    Button("Auto Detect Model") {
                        app.detectOllamaModel()
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack {
                Spacer()
                Button("Save AI Settings") {
                    app.saveSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 24, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }

    private var aiSettingsSections: [SettingSection] {
        var engineSettings: [Setting] = [
            Setting(
                key: AISettingKey.primaryEngine,
                title: "Primary AI Engine",
                description: "Select the preferred AI provider.",
                type: .picker(options: AIProviderPreference.allCases.map(\.rawValue))
            )
        ]

        if app.settings.preferredAIProvider == .ollama {
            engineSettings.append(
                Setting(
                    key: AISettingKey.ollamaHost,
                    title: "Ollama Host (localhost)",
                    description: "Base URL for your local Ollama server.",
                    type: .text
                )
            )
            engineSettings.append(
                Setting(
                    key: AISettingKey.ollamaModel,
                    title: "Model",
                    description: "Default Ollama model name for replies.",
                    type: .text
                )
            )
        }

        return [
            SettingSection(
                title: "AI Behavior",
                settings: [
                    Setting(
                        key: AISettingKey.enableReplies,
                        title: "Enable AI Replies",
                        description: "Allow SwiftBot to generate AI replies.",
                        type: .toggle
                    ),
                    Setting(
                        key: AISettingKey.guildChannels,
                        title: "Use AI in Guild Text Channels",
                        description: "Enable AI replies in server text channels.",
                        type: .toggle
                    )
                ]
            ),
            SettingSection(
                title: "Messaging",
                settings: [
                    Setting(
                        key: AISettingKey.allowDMs,
                        title: "Allow Direct Messages",
                        description: "Allow bot interactions over direct messages.",
                        type: .toggle
                    )
                ]
            ),
            SettingSection(title: "AI Engine", settings: engineSettings),
            SettingSection(
                title: "System Prompt",
                settings: [
                    Setting(
                        key: AISettingKey.systemPrompt,
                        title: "System Prompt",
                        description: "Base instruction used for AI responses.",
                        type: .text
                    )
                ]
            )
        ]
    }

    private var aiSettingsValues: Binding<[String: SettingValue]> {
        Binding(
            get: {
                [
                    AISettingKey.enableReplies: .toggle(app.settings.localAIDMReplyEnabled),
                    AISettingKey.guildChannels: .toggle(app.settings.behavior.useAIInGuildChannels),
                    AISettingKey.allowDMs: .toggle(app.settings.behavior.allowDMs),
                    AISettingKey.primaryEngine: .text(app.settings.preferredAIProvider.rawValue),
                    AISettingKey.ollamaHost: .text(app.settings.ollamaBaseURL),
                    AISettingKey.ollamaModel: .text(app.settings.localAIModel),
                    AISettingKey.systemPrompt: .text(app.settings.localAISystemPrompt)
                ]
            },
            set: { updated in
                if let enabled = updated[AISettingKey.enableReplies]?.boolValue {
                    app.settings.localAIDMReplyEnabled = enabled
                }
                if let useGuildChannels = updated[AISettingKey.guildChannels]?.boolValue {
                    app.settings.behavior.useAIInGuildChannels = useGuildChannels
                }
                if let allowDMs = updated[AISettingKey.allowDMs]?.boolValue {
                    app.settings.behavior.allowDMs = allowDMs
                }
                if let providerRaw = updated[AISettingKey.primaryEngine]?.textValue,
                   let provider = AIProviderPreference(rawValue: providerRaw) {
                    app.settings.preferredAIProvider = provider
                }
                if let ollamaHost = updated[AISettingKey.ollamaHost]?.textValue {
                    app.settings.ollamaBaseURL = ollamaHost
                }
                if let model = updated[AISettingKey.ollamaModel]?.textValue {
                    app.settings.localAIModel = model
                }
                if let prompt = updated[AISettingKey.systemPrompt]?.textValue {
                    app.settings.localAISystemPrompt = prompt
                }
            }
        )
    }

    @ViewBuilder
    private func providerIcon(imageName: String, fallbackSystemImage: String) -> some View {
        AIIconContainer {
            if Bundle.main.url(forResource: imageName, withExtension: "png") != nil {
                Image(imageName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(9)
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
    }

    private func statusRow(isOnline: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isOnline ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isOnline ? "Online" : "Offline")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusStack(isOnline: Bool, isPrimary: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            statusRow(isOnline: isOnline)
            Text(isPrimary ? "Primary" : "Fallback")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((isPrimary ? Color.accentColor : Color.white).opacity(0.14), in: Capsule())
                .foregroundStyle(isPrimary ? Color.accentColor : Color.secondary)
        }
    }

    private func syncProviderSelectionFromPreference() {
        let mapped: AIProvider = (app.settings.preferredAIProvider == .apple) ? .appleIntelligence : .ollama
        if app.settings.localAIProvider != mapped {
            app.settings.localAIProvider = mapped
        }
    }
}

struct MemoryOverviewView: View {
    @ObservedObject var viewModel: MemoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Conversation Memory")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(viewModel.totalMessages) messages")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button("Clear All") {
                    viewModel.clearAll()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.summaries.isEmpty)
            }

            if viewModel.summaries.isEmpty {
                Text("No channel memory yet. Messages will appear here as conversations are processed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.summaries.prefix(10)) { summary in
                    HStack(spacing: 12) {
                        Text(viewModel.displayName(for: summary))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(summary.messageCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            viewModel.clear(scope: summary.scope)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 24, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }
}

struct AIIconContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
            content
        }
        .frame(width: 44, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

struct StatusPill: View {
    let status: BotStatus

    private var color: Color {
        switch status {
        case .running: return .green
        case .connecting: return .orange
        case .reconnecting: return .yellow
        case .stopped: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(status.rawValue.capitalized)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        )
    }
}

struct DashboardMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 22, tint: color.opacity(0.10), stroke: color.opacity(0.28))
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

struct SwiftBotGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.08, blue: 0.11),
                        Color(red: 0.08, green: 0.12, blue: 0.17),
                        Color(red: 0.10, green: 0.09, blue: 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 520, height: 520)
                    .blur(radius: 80)
                    .offset(x: -260, y: -220)

                Circle()
                    .fill(Color.cyan.opacity(0.14))
                    .frame(width: 420, height: 420)
                    .blur(radius: 70)
                    .offset(x: 280, y: -160)

                Circle()
                    .fill(Color.blue.opacity(0.10))
                    .frame(width: 480, height: 480)
                    .blur(radius: 75)
                    .offset(x: 220, y: 260)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.95, green: 0.98, blue: 1.0),
                        Color(red: 0.89, green: 0.95, blue: 0.98),
                        Color(red: 0.96, green: 0.93, blue: 0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 520, height: 520)
                    .blur(radius: 70)
                    .offset(x: -260, y: -220)

                Circle()
                    .fill(Color.cyan.opacity(0.18))
                    .frame(width: 420, height: 420)
                    .blur(radius: 55)
                    .offset(x: 280, y: -160)

                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 480, height: 480)
                    .blur(radius: 65)
                    .offset(x: 220, y: 260)
            }
        }
        .ignoresSafeArea()
    }
}

private struct SwiftBotGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    let stroke: Color

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.55), .white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 10)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 18, tint: Color = .white.opacity(0.10), stroke: Color = .white.opacity(0.18)) -> some View {
        modifier(SwiftBotGlassCardModifier(cornerRadius: cornerRadius, tint: tint, stroke: stroke))
    }

    func sidebarProfileCard() -> some View {
        glassCard(cornerRadius: 24, tint: .white.opacity(0.10), stroke: .white.opacity(0.24))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.08), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            )
    }
}
