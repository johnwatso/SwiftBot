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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct DashboardSidebar: View {
    @EnvironmentObject var app: AppModel
    @Binding var selection: SidebarItem

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 56, height: 56)
                    Image(systemName: "cpu.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }

                VStack(spacing: 2) {
                    Text("OnlineBot")
                        .font(.headline)
                    Text("Native Assistant")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
    case voice = "Voice Activity"
    case commands = "Commands"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .voice: return "person.3.sequence.fill"
        case .commands: return "terminal.fill"
        case .logs: return "list.bullet.clipboard.fill"
        case .settings: return "gearshape.2.fill"
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

enum TriggerType: String, CaseIterable, Identifiable {
    case userJoinedVoice = "User Joins Voice"
    case userLeftVoice = "User Leaves Voice"
    case userMovedVoice = "User Moves Voice"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .userJoinedVoice: return "person.crop.circle.badge.plus"
        case .userLeftVoice: return "person.crop.circle.badge.xmark"
        case .userMovedVoice: return "arrow.left.arrow.right.circle"
        }
    }
}

enum ConditionType: String, CaseIterable, Identifiable {
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

enum ActionType: String, CaseIterable, Identifiable {
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

struct Condition: Identifiable {
    var id = UUID()
    var type: ConditionType
    var value: String = ""
    var secondaryValue: String = ""
    var enabled: Bool = true
}

struct RuleAction: Identifiable {
    var id = UUID()
    var type: ActionType = .sendMessage
    var serverId: String = ""
    var channelId: String = ""
    var mentionUser: Bool = true
    var message: String = "🔊 <@{userId}> connected to <#{channelId}>"
    var statusText: String = "Voice notifier active"
}

typealias Action = RuleAction

struct Rule: Identifiable {
    var id: UUID = UUID()
    var name: String = "New Notification"
    var trigger: TriggerType = .userJoinedVoice
    var conditions: [Condition] = []
    var actions: [Action] = [Action()]
    var isEnabled: Bool = true

    var triggerServerId: String = ""
    var triggerVoiceChannelId: String = ""
    var includeStageChannels: Bool = true

    var triggerSummary: String {
        switch trigger {
        case .userJoinedVoice: return "When user joins voice"
        case .userLeftVoice: return "When user leaves voice"
        case .userMovedVoice: return "When user moves voice"
        }
    }
}

struct VoiceView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            RuleListView(
                rules: rulesBinding,
                selectedRuleID: selectedRuleIDBinding,
                onAddNew: { app.ruleStore.addNewRule() },
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
        } detail: {
            if let selectedRule = selectedRuleBinding {
                RuleEditorView(
                    rule: selectedRule,
                    serverIds: serverIds,
                    serverName: serverName(for:),
                    voiceChannelsByServer: app.availableVoiceChannelsByServer,
                    textChannelsByServer: app.availableTextChannelsByServer
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Notification Rules")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
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

    private var serverIds: [String] {
        app.connectedServers.keys.sorted {
            (app.connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(app.connectedServers[$1] ?? $1) == .orderedAscending
        }
    }

    private var selectedRuleBinding: Binding<Rule>? {
        guard let selectedRuleID = app.ruleStore.selectedRuleID else { return nil }
        guard let idx = app.ruleStore.rules.firstIndex(where: { $0.id == selectedRuleID }) else { return nil }
        return Binding(
            get: { app.ruleStore.rules[idx] },
            set: { app.ruleStore.rules[idx] = $0 }
        )
    }

    private func serverName(for serverId: String) -> String {
        app.connectedServers[serverId] ?? "Server \(serverId.suffix(4))"
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
        .navigationTitle("Notifications")
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

    let serverIds: [String]
    let serverName: (String) -> String
    let voiceChannelsByServer: [String: [GuildVoiceChannel]]
    let textChannelsByServer: [String: [GuildTextChannel]]

    var body: some View {
        ScrollView {
            VStack {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Rule Name", text: $rule.name)
                        .textFieldStyle(.roundedBorder)

                    RuleGroupSection(title: "When", systemImage: "bolt.fill") {
                        TriggerSectionView(
                            triggerType: $rule.trigger,
                            triggerServerId: $rule.triggerServerId,
                            triggerVoiceChannelId: $rule.triggerVoiceChannelId,
                            includeStageChannels: $rule.includeStageChannels,
                            serverIds: serverIds,
                            serverName: serverName,
                            voiceChannels: voiceChannelsByServer[rule.triggerServerId] ?? []
                        )
                    }

                    RuleGroupSection(title: "If", systemImage: "line.3.horizontal.decrease.circle") {
                        ConditionsSectionView(
                            conditions: $rule.conditions,
                            serverIds: serverIds,
                            serverName: serverName,
                            voiceChannels: voiceChannelsByServer[rule.triggerServerId] ?? []
                        )
                    }

                    RuleGroupSection(title: "Do", systemImage: "paperplane.fill") {
                        ActionsSectionView(
                            actions: $rule.actions,
                            serverIds: serverIds,
                            serverName: serverName,
                            textChannelsByServer: textChannelsByServer
                        )
                    }
                }
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(24)
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(rule.name)
        .onAppear {
            if rule.triggerServerId.isEmpty {
                rule.triggerServerId = serverIds.first ?? ""
            }
            if rule.actions.isEmpty {
                var action = Action()
                action.serverId = serverIds.first ?? ""
                let channels = textChannelsByServer[action.serverId] ?? []
                action.channelId = channels.first?.id ?? ""
                rule.actions = [action]
            }
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
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct TriggerSectionView: View {
    @Binding var triggerType: TriggerType
    @Binding var triggerServerId: String
    @Binding var triggerVoiceChannelId: String
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

            if !voiceChannels.isEmpty {
                Picker("Voice Channel", selection: $triggerVoiceChannelId) {
                    Text("Any Channel").tag("")
                    ForEach(voiceChannels) { channel in
                        Text(channel.name).tag(channel.id)
                    }
                }
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
                    action: primaryActionBinding,
                    serverIds: serverIds,
                    serverName: serverName,
                    textChannels: textChannelsByServer[primaryActionBinding.wrappedValue.serverId] ?? []
                )
            }
        }
    }

    private var primaryActionBinding: Binding<Action> {
        Binding(
            get: { actions.first ?? Action() },
            set: { newValue in
                if actions.isEmpty {
                    actions = [newValue]
                } else {
                    actions[0] = newValue
                }
            }
        )
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

            Text("Use placeholders in messages: {userId}, {username}, {channelId}, {channelName}, {guildName}")
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

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @Binding var showToken: Bool
    @State private var prefixDraft = "!"
    @State private var notificationChannelDrafts: [String: String] = [:]
    @State private var ignoredChannelDrafts: [String: String] = [:]
    @State private var monitoredChannelDrafts: [String: String] = [:]
    @State private var notifyJoinDrafts: [String: Bool] = [:]
    @State private var notifyLeaveDrafts: [String: Bool] = [:]
    @State private var notifyMoveDrafts: [String: Bool] = [:]
    @State private var joinTemplateDrafts: [String: String] = [:]
    @State private var leaveTemplateDrafts: [String: String] = [:]
    @State private var moveTemplateDrafts: [String: String] = [:]

    private let allowedPrefixes = ["$", "#", "!", "?", "%"]

    private var editableServerIds: [String] {
        let ids = Set(app.connectedServers.keys).union(app.settings.guildSettings.keys)
        return ids.sorted { lhs, rhs in
            serverName(for: lhs).localizedCaseInsensitiveCompare(serverName(for: rhs)) == .orderedAscending
        }
    }

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

                Section("Server Notifications") {
                    if editableServerIds.isEmpty {
                        Text("Connect the bot to a server to configure voice notifications here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(editableServerIds, id: \.self) { serverId in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(serverName(for: serverId)) (\(serverId))")
                                    .font(.subheadline.weight(.semibold))

                                TextField(
                                    "Notification Channel ID",
                                    text: Binding(
                                        get: { notificationChannelDrafts[serverId, default: ""] },
                                        set: { notificationChannelDrafts[serverId] = $0 }
                                    )
                                )

                                Toggle(
                                    "Notify On Join",
                                    isOn: Binding(
                                        get: { notifyJoinDrafts[serverId, default: true] },
                                        set: { notifyJoinDrafts[serverId] = $0 }
                                    )
                                )

                                Toggle(
                                    "Notify On Leave",
                                    isOn: Binding(
                                        get: { notifyLeaveDrafts[serverId, default: true] },
                                        set: { notifyLeaveDrafts[serverId] = $0 }
                                    )
                                )

                                Toggle(
                                    "Notify On Move",
                                    isOn: Binding(
                                        get: { notifyMoveDrafts[serverId, default: true] },
                                        set: { notifyMoveDrafts[serverId] = $0 }
                                    )
                                )

                                TextField(
                                    "Join Message Template",
                                    text: Binding(
                                        get: { joinTemplateDrafts[serverId, default: GuildSettings().joinNotificationTemplate] },
                                        set: { joinTemplateDrafts[serverId] = $0 }
                                    )
                                )

                                TextField(
                                    "Leave Message Template",
                                    text: Binding(
                                        get: { leaveTemplateDrafts[serverId, default: GuildSettings().leaveNotificationTemplate] },
                                        set: { leaveTemplateDrafts[serverId] = $0 }
                                    )
                                )

                                TextField(
                                    "Move Message Template",
                                    text: Binding(
                                        get: { moveTemplateDrafts[serverId, default: GuildSettings().moveNotificationTemplate] },
                                        set: { moveTemplateDrafts[serverId] = $0 }
                                    )
                                )

                                TextField(
                                    "Notify Only Voice Channel IDs (comma separated, empty = all)",
                                    text: Binding(
                                        get: { monitoredChannelDrafts[serverId, default: ""] },
                                        set: { monitoredChannelDrafts[serverId] = $0 }
                                    )
                                )

                                TextField(
                                    "Ignored Voice Channel IDs (comma separated)",
                                    text: Binding(
                                        get: { ignoredChannelDrafts[serverId, default: ""] },
                                        set: { ignoredChannelDrafts[serverId] = $0 }
                                    )
                                )

                                let voiceChannels = app.availableVoiceChannelsByServer[serverId] ?? []
                                if voiceChannels.isEmpty {
                                    Text("No voice channels discovered yet.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Available Voice Channels")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    ForEach(voiceChannels) { channel in
                                        Text("• \(channel.name) (\(channel.id))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Text("Template placeholders: {userId} {username} {guildName} {channelId} {channelName} {fromChannelId} {toChannelId}")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Button("Save") {
                    app.settings.prefix = prefixDraft
                    applyServerDraftsToSettings()
                    app.saveSettings()
                    prefixDraft = app.settings.prefix
                }
                .buttonStyle(.borderedProminent)

                Link("Discord Developer Portal", destination: URL(string: "https://discord.com/developers/applications")!)
            }
            .onAppear {
                prefixDraft = allowedPrefixes.contains(app.settings.prefix) ? app.settings.prefix : "!"
                refreshServerDrafts()
            }
            .onChange(of: app.settings.prefix) { newValue in
                prefixDraft = allowedPrefixes.contains(newValue) ? newValue : "!"
            }
            .onChange(of: app.connectedServers.count) { _ in
                refreshServerDrafts()
            }
            .onChange(of: app.settings.guildSettings.count) { _ in
                refreshServerDrafts()
            }
            .formStyle(.grouped)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
    }

    private func serverName(for serverId: String) -> String {
        app.connectedServers[serverId] ?? "Server \(serverId.suffix(4))"
    }

    private func refreshServerDrafts() {
        for serverId in editableServerIds {
            let guildSettings = app.settings.guildSettings[serverId] ?? GuildSettings()
            notificationChannelDrafts[serverId] = guildSettings.notificationChannelId ?? ""
            ignoredChannelDrafts[serverId] = guildSettings.ignoredVoiceChannelIds.sorted().joined(separator: ",")
            monitoredChannelDrafts[serverId] = guildSettings.monitoredVoiceChannelIds.sorted().joined(separator: ",")
            notifyJoinDrafts[serverId] = guildSettings.notifyOnJoin
            notifyLeaveDrafts[serverId] = guildSettings.notifyOnLeave
            notifyMoveDrafts[serverId] = guildSettings.notifyOnMove
            joinTemplateDrafts[serverId] = guildSettings.joinNotificationTemplate
            leaveTemplateDrafts[serverId] = guildSettings.leaveNotificationTemplate
            moveTemplateDrafts[serverId] = guildSettings.moveNotificationTemplate
        }
    }

    private func applyServerDraftsToSettings() {
        for serverId in editableServerIds {
            var guildSettings = app.settings.guildSettings[serverId] ?? GuildSettings()

            let notification = notificationChannelDrafts[serverId, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            guildSettings.notificationChannelId = notification.isEmpty ? nil : notification

            let monitoredRaw = monitoredChannelDrafts[serverId, default: ""]
            let monitoredIds = monitoredRaw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap(parseChannelId)
            guildSettings.monitoredVoiceChannelIds = Set(monitoredIds)

            let ignoredRaw = ignoredChannelDrafts[serverId, default: ""]
            let ignoredIds = ignoredRaw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap(parseChannelId)
            guildSettings.ignoredVoiceChannelIds = Set(ignoredIds)

            guildSettings.notifyOnJoin = notifyJoinDrafts[serverId, default: true]
            guildSettings.notifyOnLeave = notifyLeaveDrafts[serverId, default: true]
            guildSettings.notifyOnMove = notifyMoveDrafts[serverId, default: true]

            let joinTemplate = joinTemplateDrafts[serverId, default: GuildSettings().joinNotificationTemplate].trimmingCharacters(in: .whitespacesAndNewlines)
            guildSettings.joinNotificationTemplate = joinTemplate.isEmpty ? GuildSettings().joinNotificationTemplate : joinTemplate

            let leaveTemplate = leaveTemplateDrafts[serverId, default: GuildSettings().leaveNotificationTemplate].trimmingCharacters(in: .whitespacesAndNewlines)
            guildSettings.leaveNotificationTemplate = leaveTemplate.isEmpty ? GuildSettings().leaveNotificationTemplate : leaveTemplate

            let moveTemplate = moveTemplateDrafts[serverId, default: GuildSettings().moveNotificationTemplate].trimmingCharacters(in: .whitespacesAndNewlines)
            guildSettings.moveNotificationTemplate = moveTemplate.isEmpty ? GuildSettings().moveNotificationTemplate : moveTemplate

            app.settings.guildSettings[serverId] = guildSettings
        }
    }

    private func parseChannelId(_ text: String) -> String? {
        if text.hasPrefix("<#") && text.hasSuffix(">") {
            return String(text.dropFirst(2).dropLast())
        }
        return text.allSatisfy(\.isNumber) ? text : nil
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
