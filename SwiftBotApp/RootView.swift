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
                case .overview: OverviewView()
                case .voice: VoiceView()
                case .commands: CommandsView()
                case .logs: LogsView()
                case .settings: SettingsView(showToken: $showToken)
                case .aiBots: AIBotsView()
                case .status: StatusView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(windowTitle)
        }
        .navigationSplitViewStyle(.balanced)
    }
    
    private var windowTitle: String {
        if app.status == .running {
            return "\(app.botUsername) - Discord Bot"
        } else {
            return "Discord Bot Dashboard"
        }
    }
}

struct DashboardSidebar: View {
    @EnvironmentObject var app: AppModel
    @Binding var selection: SidebarItem

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
                            .fill(app.status == .running ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(app.status == .running ? "Online" : "Offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            List(selection: $selection) {
                Section("Main") {
                    SidebarRow(item: .overview, selection: $selection)
                    SidebarRow(item: .voice, selection: $selection, count: app.activeVoice.count)
                    SidebarRow(item: .commands, selection: $selection)
                    SidebarRow(item: .logs, selection: $selection)
                }

                Section("Config") {
                    SidebarRow(item: .settings, selection: $selection)
                    SidebarRow(item: .aiBots, selection: $selection)
                    SidebarRow(item: .status, selection: $selection)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Group {
                if app.status == .stopped {
                    Button {
                        Task { await app.startBot() }
                    } label: {
                        Label("Start Bot", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        app.stopBot()
                    } label: {
                        Label("Stop Bot", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .controlSize(.large)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}

struct SidebarRow: View {
    let item: SidebarItem
    @Binding var selection: SidebarItem
    var count: Int?

    var body: some View {
        Button {
            selection = item
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
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tag(item)
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case voice = "Server Notifier"
    case commands = "Commands"
    case logs = "Logs"
    case settings = "Settings"
    case aiBots = "AI Bots"
    case status = "Status"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .voice: return "bell.badge.fill"
        case .commands: return "terminal.fill"
        case .logs: return "list.bullet.clipboard.fill"
        case .settings: return "gearshape.2.fill"
        case .aiBots: return "sparkles.rectangle.stack.fill"
        case .status: return "waveform.path.ecg"
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject var app: AppModel

    private var recentVoice: [VoiceEventLogEntry] {
        Array(app.voiceLog.prefix(5))
    }

    private var recentCommands: [CommandLogEntry] {
        Array(app.commandLog.prefix(5))
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
                    DashboardPanel(title: "Currently In Voice") {
                        if app.activeVoice.isEmpty {
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
                        InfoRow(label: "Uptime", value: app.uptime?.text ?? "--")
                        InfoRow(label: "Prefix", value: app.settings.prefix)
                        InfoRow(label: "Errors", value: "\(app.stats.errors)")
                        InfoRow(label: "State", value: app.status.rawValue.capitalized)
                    }
                }
            }
            .padding(20)
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
        case .userJoinedVoice: return "Join Notification"
        case .userLeftVoice: return "Leave Notification"
        case .userMovedVoice: return "Move Notification"
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
    var name: String = "New Notification"
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
        case .userJoinedVoice: return "When user joins voice"
        case .userLeftVoice: return "When user leaves voice"
        case .userMovedVoice: return "When user moves voice"
        case .messageContains:
            return triggerMessageContains.isEmpty ? "When message contains text" : "When message contains \"\(triggerMessageContains)\""
        }
    }
}

struct VoiceView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HSplitView {
            RuleListView(
                rules: rulesBinding,
                selectedRuleID: selectedRuleIDBinding,
                onAddNew: {
                    let sid = serverIds.first ?? ""
                    let cid = app.availableTextChannelsByServer[sid]?.first?.id ?? ""
                    app.ruleStore.addNewRule(serverId: sid, channelId: cid)
                },
                onDeleteOffsets: { offsets in
                    app.ruleStore.deleteRules(at: offsets, undoManager: undoManager)
                },
                onDeleteRuleID: { ruleID in
                    app.ruleStore.deleteRule(id: ruleID, undoManager: undoManager)
                },
                onDeleteSelected: {
                    if let selected = app.ruleStore.selectedRuleID {
                        app.ruleStore.deleteRule(id: selected, undoManager: undoManager)
                    }
                }
            )
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            Group {
                if let selectedRuleBinding {
                    RuleEditorView(rule: selectedRuleBinding)
                        .id(app.ruleStore.selectedRuleID) // Force view recreation when selection changes
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Select a Notification Rule")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: app.ruleStore.rules) { _ in
            app.ruleStore.scheduleAutoSave()
        }
    }

    private var rulesBinding: Binding<[Rule]> {
        Binding(
            get: { app.ruleStore.rules },
            set: { app.ruleStore.rules = $0 }
        )
    }

    private var selectedRuleIDBinding: Binding<UUID?> {
        Binding(
            get: { app.ruleStore.selectedRuleID },
            set: { app.ruleStore.selectedRuleID = $0 }
        )
    }

    private var selectedRuleBinding: Binding<Rule>? {
        guard let selectedRuleID = app.ruleStore.selectedRuleID,
              app.ruleStore.rules.contains(where: { $0.id == selectedRuleID })
        else {
            return nil
        }

        return Binding(
            get: {
                // Always look up the current selected rule ID, not the captured one
                guard let currentSelectedID = app.ruleStore.selectedRuleID,
                      let idx = app.ruleStore.rules.firstIndex(where: { $0.id == currentSelectedID }) else {
                    return Rule(id: selectedRuleID)
                }
                return app.ruleStore.rules[idx]
            },
            set: { updatedRule in
                // Always look up the current selected rule ID, not the captured one
                guard let currentSelectedID = app.ruleStore.selectedRuleID,
                      let idx = app.ruleStore.rules.firstIndex(where: { $0.id == currentSelectedID }) else {
                    return
                }
                app.ruleStore.rules[idx] = updatedRule
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
        List(selection: $selectedRuleID) {
            ForEach($rules) { $rule in
                RuleRowView(rule: $rule)
                    .tag(rule.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            onDeleteRuleID(rule.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            .onDelete(perform: onDeleteOffsets)
        }
        .listStyle(.inset)
        .navigationTitle("Server Notifier")
        .toolbar {
            ToolbarItem {
                Button(action: onAddNew) {
                    Label("Add New Notification", systemImage: "plus")
                }
            }
            ToolbarItem {
                Button(role: .destructive, action: onDeleteSelected) {
                    Label("Delete", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(selectedRuleID == nil)
            }
        }
    }
}

struct RuleRowView: View {
    @Binding var rule: Rule

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
        }
        .padding(.vertical, 4)
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
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Rule Name", text: $rule.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.title2.weight(.semibold))

                    RuleGroupSection(title: "When", systemImage: "bolt.fill") {
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

                    RuleGroupSection(title: "If", systemImage: "line.3.horizontal.decrease.circle") {
                        ConditionsSectionView(
                            conditions: $rule.conditions,
                            serverIds: serverIds,
                            serverName: serverName(for:),
                            voiceChannels: app.availableVoiceChannelsByServer[rule.triggerServerId] ?? []
                        )
                    }

                    RuleGroupSection(title: "Do", systemImage: "paperplane.fill") {
                        ActionsSectionView(
                            actions: $rule.actions,
                            serverIds: serverIds,
                            serverName: serverName(for:),
                            textChannelsByServer: app.availableTextChannelsByServer
                        )
                    }
                }
                .frame(maxWidth: 700)
                .padding(.vertical, 24)
                .frame(width: geometry.size.width)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    app.ruleStore.save()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .help("Save all rules")
            }
        }
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

        let defaultNames = Set(TriggerType.allCases.map(\.defaultRuleName) + ["New Notification", "Join Notification"])
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    Label("Add Action", systemImage: "plus")
                }
            } else {
                ActionSectionView(
                    action: $actions[0],
                    serverIds: serverIds,
                    serverName: serverName,
                    textChannels: textChannelsByServer[actions[0].serverId] ?? []
                )
            }
        }
    }
}

struct ActionSectionView: View {
    @Binding var action: Action

    let serverIds: [String]
    let serverName: (String) -> String
    let textChannels: [GuildTextChannel]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Action", selection: $action.type) {
                ForEach(ActionType.allCases) { actionType in
                    Label(actionType.rawValue, systemImage: actionType.symbol).tag(actionType)
                }
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
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                TableColumn("Status") { entry in
                    Text(entry.ok ? "OK" : "ERROR")
                        .foregroundStyle(entry.ok ? .green : .red)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
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
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
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

struct StatusView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Status")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                RuleGroupSection(title: "Gateway", systemImage: "network") {
                    InfoRow(label: "Connection", value: app.status.rawValue.capitalized)
                    InfoRow(label: "Total Events", value: "\(app.gatewayEventCount)")
                    InfoRow(label: "Last Event", value: app.lastGatewayEventName)
                    InfoRow(label: "READY Events", value: "\(app.readyEventCount)")
                    InfoRow(label: "GUILD_CREATE Events", value: "\(app.guildCreateEventCount)")
                    InfoRow(label: "Servers", value: "\(app.connectedServers.count)")
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

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @Binding var showToken: Bool
    @State private var prefixDraft = "!"

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

                Button("Save") {
                    app.settings.prefix = prefixDraft
                    app.saveSettings()
                    prefixDraft = app.settings.prefix
                }
                .buttonStyle(.borderedProminent)

                Link("Discord Developer Portal", destination: URL(string: "https://discord.com/developers/applications")!)
            }
            .onAppear {
                prefixDraft = allowedPrefixes.contains(app.settings.prefix) ? app.settings.prefix : "!"
            }
            .onChange(of: app.settings.prefix) { newValue in
                prefixDraft = allowedPrefixes.contains(newValue) ? newValue : "!"
            }
            .formStyle(.grouped)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
    }
}

struct AIBotsView: View {
    @EnvironmentObject var app: AppModel
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("AI Bots")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                
                // Apple Intelligence Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        if let nsImage = NSImage(named: NSImage.Name("Apple_AI")) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 44, height: 44)
                                .cornerRadius(10)
                        } else {
                            // Fallback
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.blue.gradient)
                                    .frame(width: 44, height: 44)
                                
                                Image(systemName: "sparkles")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Intelligence")
                                .font(.headline)
                            Text("On-Device DM Replies")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: $app.settings.localAIDMReplyEnabled)
                            .labelsHidden()
                    }
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Configuration")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("System Prompt")
                                .font(.caption.weight(.medium))
                            TextEditor(text: $app.settings.localAISystemPrompt)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 120)
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                                )
                                .disabled(!app.settings.localAIDMReplyEnabled)
                                .opacity(app.settings.localAIDMReplyEnabled ? 1.0 : 0.5)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("How It Works", systemImage: "info.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• Uses Apple Intelligence Foundation Models running locally")
                            Text("• Requires macOS 26.0 or later with Apple Intelligence support")
                            Text("• Completely private - no data sent to external servers")
                            Text("• Responds intelligently to direct messages when enabled")
                            Text("• Custom system prompt defines the AI's personality and behavior")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    
                    HStack {
                        Spacer()
                        Button("Save AI Settings") {
                            app.saveSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                
                // Placeholder for future AI integrations
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .frame(width: 44, height: 44)
                            .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("External AI Services")
                                .font(.headline)
                            Text("Coming Soon")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                    }
                    
                    Text("Future support for external AI services like OpenAI, Anthropic, and local LLM servers will be added here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(0.6)
            }
            .padding(20)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(color.opacity(0.85), lineWidth: 1.5)
        )
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
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
        .background(tone.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
