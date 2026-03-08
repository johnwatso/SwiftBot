import SwiftUI

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
        VStack(spacing: 0) {
        if app.isFailoverManagedNode {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                Text("Read-only on Failover nodes. Action rules sync from Primary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        HSplitView {
            RuleListView(
                rules: rulesBinding,
                selectedRuleID: appSelectionBinding,
                onAddNew: {
                    let sid = serverIds.first ?? ""
                    let cid = app.availableTextChannelsByServer[sid]?.first?.id ?? ""
                    ruleStore.addNewRule(serverId: sid, channelId: cid)
                },
                onDeleteRuleID: { ruleID in
                    ruleStore.deleteRule(id: ruleID, undoManager: undoManager)
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
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .disabled(app.isFailoverManagedNode)
        .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        .onChange(of: ruleStore.rules) {
            if let selected = ruleStore.selectedRuleID,
               !ruleStore.rules.contains(where: { $0.id == selected }) {
                ruleStore.selectedRuleID = nil
            }
            ruleStore.scheduleAutoSave()
        }
        } // end VStack
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
        guard let selectedRuleID = ruleStore.selectedRuleID else {
            return nil
        }

        return Binding(
            get: {
                guard let currentSelectedID = ruleStore.selectedRuleID,
                      let index = ruleStore.rules.firstIndex(where: { $0.id == currentSelectedID }) else {
                    return Rule(id: selectedRuleID)
                }
                return ruleStore.rules[index]
            },
            set: { updatedRule in
                guard let currentSelectedID = ruleStore.selectedRuleID,
                      let index = ruleStore.rules.firstIndex(where: { $0.id == currentSelectedID }) else {
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
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.20), lineWidth: 1)
                    )
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
        .onChange(of: rule) {
            app.ruleStore.scheduleAutoSave()
        }
        .onChange(of: rule.trigger) { _, newTrigger in
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
        .frame(height: 46, alignment: .bottomLeading)
        .padding(.horizontal, 20)
        .padding(.top, 0)
        .padding(.bottom, 8)
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

            if triggerType != .messageContains, triggerType != .memberJoined, !voiceChannels.isEmpty {
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

                Toggle("Mention user in message", isOn: $action.mentionUser)
                Toggle("Reply to trigger message", isOn: $action.replyToTriggerMessage)
                Toggle("Reply with AI", isOn: $action.replyWithAI)

                if action.replyToTriggerMessage {
                    Text("Reply will be sent in the same channel as the triggering message.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
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
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(action.replyWithAI ? "AI Prompt" : "Message")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $action.message)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                        )
                }
                if action.replyWithAI {
                    Text("AI will generate the final reply from this prompt template.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .addLogEntry:
                TextField("Log message", text: $action.message)
            case .setStatus:
                Toggle("Reply with AI", isOn: $action.replyWithAI)
                TextField(action.replyWithAI ? "AI Prompt" : "Status text", text: $action.statusText)
                if action.replyWithAI {
                    Text("AI will generate the final status text from this prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        .onChange(of: action.serverId) {
            action.channelId = textChannels.first?.id ?? ""
        }
    }
}
