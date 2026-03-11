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
                },
                isLoading: ruleStore.isLoading
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

    @AppStorage("hasSeenRuleOnboarding") private var hasSeenRuleOnboarding: Bool = false
    @State private var guidedStep: GuidedBuildStep = .none
    @State private var scrollToTriggersSignal: Bool = false

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

                RuleBuilderLibraryView(
                        serverIds: serverIds,
                        onAddCondition: addCondition(_:),
                        onAddAction: addAction(_:),
                        onSetTrigger: { type in
                            rule.trigger = type
                            rule.isEditingTrigger = false
                            hasSeenRuleOnboarding = true
                            applyTriggerDefaults(for: type)
                            if guidedStep == .trigger { guidedStep = .action }
                        },
                        focusTrigger: {
                            if let trigger = rule.trigger {
                                applyTriggerDefaults(for: trigger)
                            }
                        },
                        scrollToTriggersSignal: $scrollToTriggersSignal,
                        currentTrigger: rule.trigger,
                        isEditingTrigger: rule.isEditingTrigger
                    )
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

                if !rule.isEmptyRule && !rule.isEditingTrigger && !rule.validationIssues.isEmpty {
                    ValidationBannerView(issues: rule.validationIssues)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if rule.trigger == nil && !hasSeenRuleOnboarding {
                            EmptyRuleStateView(
                                icon: "bolt.circle",
                                title: "Choose a Trigger",
                                description: "Select a trigger from the Block Library to begin building this rule.",
                                onShowMe: {
                                    scrollToTriggersSignal = true
                                    guidedStep = .trigger
                                },
                                onContinue: {
                                    hasSeenRuleOnboarding = true
                                }
                            )
                            .padding(.top, 40)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                    removal: .opacity.combined(with: .scale(scale: 0.96))
                                )
                            )
                        } else {
                            RuleCanvasSection(title: "Trigger", systemImage: "bolt.fill", accent: .yellow,
                                              guidedHighlight: guidedStep == .trigger) {
                                TriggerSectionView(
                                    triggerType: rule.trigger
                                )
                                if guidedStep == .trigger {
                                    Label("Select a trigger from the Block Library to begin.", systemImage: "arrow.left")
                                        .font(.caption)
                                        .foregroundStyle(.yellow.opacity(0.8))
                                        .padding(.top, 4)
                                }
                                // Trigger can be replaced but not deleted
                                Button {
                                    rule.isEditingTrigger = true
                                    scrollToTriggersSignal = true
                                    guidedStep = .trigger
                                } label: {
                                    Label("Change Trigger", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                }
                                .buttonStyle(.bordered)
                                .tint(.yellow)
                                .padding(.top, 4)
                            }

                            RuleFlowArrow()

                            RuleCanvasSection(title: "Filters", systemImage: "line.3.horizontal.decrease.circle", accent: .cyan) {
                                ConditionsSectionView(
                                    conditions: $rule.conditions,
                                    hasTrigger: rule.trigger != nil,
                                    serverIds: serverIds,
                                    serverName: serverName(for:),
                                    voiceChannels: app.availableVoiceChannelsByServer.values.flatMap { $0 },
                                    incompatibleBlocks: rule.incompatibleBlocks,
                                    availableVariables: rule.trigger?.providedVariables ?? []
                                )
                            }

                            RuleFlowArrow()

                            RuleCanvasSection(title: "Message Modifiers", systemImage: "slider.horizontal.3", accent: .orange) {
                                ActionsSectionView(
                                    actions: $rule.modifiers,
                                    category: .messaging, // Used to be .modifiers
                                    allModifiers: rule.modifiers,
                                    hasTrigger: rule.trigger != nil,
                                    serverIds: serverIds,
                                    serverName: serverName(for:),
                                    textChannelsByServer: app.availableTextChannelsByServer,
                                    incompatibleBlocks: rule.incompatibleBlocks,
                                    availableVariables: rule.trigger?.providedVariables ?? []
                                )
                            }

                            RuleFlowArrow()

                            RuleCanvasSection(title: "Actions", systemImage: "paperplane.fill", accent: .mint,
                                              guidedHighlight: guidedStep == .action) {
                                ActionsSectionView(
                                    actions: $rule.actions,
                                    category: .actions, // Used to be .messaging
                                    allModifiers: rule.modifiers,
                                    hasTrigger: rule.trigger != nil,
                                    serverIds: serverIds,
                                    serverName: serverName(for:),
                                    textChannelsByServer: app.availableTextChannelsByServer,
                                    isGuided: guidedStep == .action,
                                    incompatibleBlocks: rule.incompatibleBlocks,
                                    availableVariables: rule.trigger?.providedVariables ?? []
                                )
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.22), value: rule.isEmptyRule)
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
        .onChange(of: rule.actions) { _, newActions in
            if guidedStep == .trigger && !newActions.isEmpty {
                guidedStep = .none
            }
        }
        .onChange(of: rule) {
            app.ruleStore.scheduleAutoSave()
        }
        .onChange(of: rule.trigger) { _, newTrigger in
            if let newTrigger = newTrigger {
                applyTriggerDefaults(for: newTrigger)
            }
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
        action.message = rule.trigger?.defaultMessage ?? ""

        switch type {
        case .sendMessage:
            break
        case .addLogEntry:
            action.message = "Rule fired for {username}"
        case .setStatus:
            action.statusText = "Handling \(rule.trigger?.rawValue.lowercased() ?? "action")"
        // Modifier blocks
        case .replyToTrigger, .mentionUser, .mentionRole, .disableMention, .sendToChannel:
            break
        // AI block
        case .generateAIResponse:
            action.message = "You are a helpful assistant. {message}"
        // Other action types
        case .sendDM, .deleteMessage, .addReaction, .addRole, .removeRole,
             .timeoutMember, .kickMember, .moveMember, .createChannel, .webhook, .delay,
             .setVariable, .randomChoice:
            break
        }

        // Fix: Route modifiers to rule.modifiers, actions to rule.actions
        if type.category == .messaging {
            rule.modifiers.append(action)
        } else {
            rule.actions.append(action)
        }
        app.ruleStore.scheduleAutoSave()
    }

    private func initializeRuleDefaultsIfNeeded() {
        var didChange = false

        // Fix missing server/channel IDs on existing actions (legacy rules).
        // Never pre-populate a default action — empty rules show the empty-state UI.
        if !rule.actions.isEmpty {
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

    private func applyExampleRule() {
        rule.name = "Hello World"
        rule.trigger = .messageCreated

        var filter = Condition(type: .messageContains)
        filter.value = "@swiftbot hello"
        rule.conditions = [filter]

        var action = RuleAction()
        action.type = .sendMessage
        action.serverId = serverIds.first ?? ""
        action.channelId = app.availableTextChannelsByServer[action.serverId]?.first?.id ?? ""
        action.message = "Hello World 👋"
        rule.actions = [action]

        app.ruleStore.scheduleAutoSave()
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

        // Auto-insert a messageContains filter when that trigger is selected (if not already present)
        if newTrigger == .messageCreated,
           !rule.conditions.contains(where: { $0.type == .messageContains }) {
            rule.conditions.append(Condition(type: .messageContains))
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
    let onSetTrigger: (TriggerType) -> Void
    let focusTrigger: () -> Void
    @Binding var scrollToTriggersSignal: Bool
    let currentTrigger: TriggerType?
    let isEditingTrigger: Bool

    @State private var triggerSectionHighlighted: Bool = false
    private let triggersSectionID = "library-triggers"

    private func types(for category: BlockCategory) -> [ActionType] {
        ActionType.allCases.filter { $0.category == category }
    }

    private func isCompatible(_ reqs: Set<ContextVariable>) -> Bool {
        guard let currentTrigger = currentTrigger else { return reqs.isEmpty }
        return reqs.isSubset(of: currentTrigger.providedVariables)
    }

    private func tooltipFor(_ reqs: Set<ContextVariable>) -> String? {
        guard !isCompatible(reqs) else { return nil }
        return "Requires \(reqs.friendlyRequirement)."
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if currentTrigger == nil || isEditingTrigger {
                        RuleLibrarySection(title: currentTrigger == nil ? "Select a Trigger" : "Triggers", highlighted: triggerSectionHighlighted) {
                            ForEach(TriggerType.allCases) { type in
                                RuleLibraryButton(
                                    title: type.rawValue,
                                    subtitle: "Set this as the rule trigger",
                                    systemImage: type.symbol,
                                    accent: .yellow,
                                    action: { onSetTrigger(type); focusTrigger() }
                                )
                            }
                        }
                        .id(triggersSectionID)
                    }

            RuleLibrarySection(title: "Filters") {
                ForEach(ConditionType.allCases) { type in
                    if type.isCompatible(with: currentTrigger) {
                        RuleLibraryButton(
                            title: type.rawValue,
                            subtitle: "Add a filter condition",
                            systemImage: type.symbol,
                            accent: .cyan,
                            action: { onAddCondition(type) }
                        )
                    }
                }
            }

            let messageTypes = types(for: .messaging)
            if !messageTypes.isEmpty {
                RuleLibrarySection(title: "Message") {
                    ForEach(messageTypes) { type in
                        if type.isCompatible(with: currentTrigger) {
                            RuleLibraryButton(
                                title: type.rawValue,
                                subtitle: "Formatting and routing modifiers",
                                systemImage: type.symbol,
                                accent: .orange,
                                action: { onAddAction(type) }
                            )
                        }
                    }
                }
            }

            let actionTypes = types(for: .actions)
            if !actionTypes.isEmpty {
                RuleLibrarySection(title: "Actions") {
                    ForEach(actionTypes) { type in
                        if type.isCompatible(with: currentTrigger) {
                            RuleLibraryButton(
                                title: type.rawValue,
                                subtitle: "Output blocks",
                                systemImage: type.symbol,
                                accent: .mint,
                                action: { onAddAction(type) }
                            )
                        }
                    }
                }
            }

            let moderationTypes = types(for: .moderation)
            if !moderationTypes.isEmpty {
                RuleLibrarySection(title: "Moderation") {
                    ForEach(moderationTypes) { type in
                        if type.isCompatible(with: currentTrigger) {
                            RuleLibraryButton(
                                title: type.rawValue,
                                subtitle: "Server management",
                                systemImage: type.symbol,
                                accent: .red,
                                action: { onAddAction(type) }
                            )
                        }
                    }
                }
            }

                    if serverIds.isEmpty {
                        Text("Connect the bot to Discord to unlock server and channel pickers in action blocks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 16)
            }
            .onChange(of: scrollToTriggersSignal) { _, newValue in
                guard newValue else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(triggersSectionID, anchor: .top)
                }
                triggerSectionHighlighted = true
                scrollToTriggersSignal = false
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    await MainActor.run { triggerSectionHighlighted = false }
                }
            }
        }
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
    var highlighted: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(highlighted ? .yellow : .secondary)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
        .padding(highlighted ? 8 : 0)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(highlighted ? Color.yellow.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(highlighted ? Color.yellow.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: highlighted)
    }
}

struct RuleLibraryButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    var isDisabled: Bool = false
    var disabledReason: String? = nil
    var dragItem: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(isDisabled ? .secondary : accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isDisabled ? .secondary : .primary)
                    Text(isDisabled ? (disabledReason ?? subtitle) : subtitle)
                        .font(.caption)
                        .foregroundStyle(isDisabled ? .red.opacity(0.8) : .secondary)
                }
                Spacer()
                Image(systemName: isDisabled ? "nosign" : "plus.circle.fill")
                    .foregroundStyle(isDisabled ? .secondary : accent)
            }
            .padding(12)
            .glassCard(cornerRadius: 18, tint: .white.opacity(0.05), stroke: .white.opacity(0.14))
            .opacity(isDisabled ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(isDisabled ? (disabledReason ?? "Incompatible") : "")
    }
}

struct RuleCanvasSection<Content: View>: View {
    let title: String
    let systemImage: String
    let accent: Color
    var guidedHighlight: Bool = false
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
        .glassCard(cornerRadius: 22, tint: .white.opacity(0.10), stroke: guidedHighlight ? accent.opacity(0.6) : .white.opacity(0.18))
        .animation(.easeInOut(duration: 0.3), value: guidedHighlight)
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
    let triggerType: TriggerType?

    var body: some View {
        if let type = triggerType {
            Label(type.rawValue, systemImage: type.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.yellow)
        } else {
            Text("No trigger selected.")
                .foregroundStyle(.secondary)
        }
    }
}

struct ConditionsSectionView: View {
    @Binding var conditions: [Condition]
    let hasTrigger: Bool

    let serverIds: [String]
    let serverName: (String) -> String
    let voiceChannels: [GuildVoiceChannel]
    var incompatibleBlocks: [UUID] = []
    var availableVariables: Set<ContextVariable> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if conditions.isEmpty {
                Text("No filters yet. Use the Block Library to add one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach($conditions) { $condition in
                    let isCompat = !incompatibleBlocks.contains(condition.id)
                    let missing = condition.type.requiredVariables.subtracting(availableVariables)

                    ConditionRowView(
                        condition: $condition,
                        isIncompatible: !isCompat,
                        missingContext: missing.isEmpty ? nil : "Requires \(missing.friendlyRequirement)",
                        serverIds: serverIds,
                        serverName: serverName,
                        voiceChannels: voiceChannels,
                        onDelete: {
                            conditions.removeAll { $0.id == condition.id }
                        }
                    )
                }
            }
        }
        .disabled(!hasTrigger)
        .opacity(hasTrigger ? 1.0 : 0.5)
    }
}

struct ConditionRowView: View {
    @Binding var condition: Condition
    var isIncompatible: Bool = false
    var missingContext: String? = nil

    let serverIds: [String]
    let serverName: (String) -> String
    let voiceChannels: [GuildVoiceChannel]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(condition.type.rawValue, systemImage: condition.type.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
                
                if isIncompatible {
                    Label(missingContext ?? "Incompatible with trigger", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.leading, 8)
                }

                Spacer()
                
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            conditionEditor
        }
        .padding(10)
        .glassCard(cornerRadius: 18, tint: .white.opacity(0.08), stroke: isIncompatible ? Color.orange.opacity(0.4) : .white.opacity(0.16))
        .opacity(isIncompatible ? 0.6 : 1.0)
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
            TextField("Enter username fragment…", text: $condition.value)
        case .minimumDuration:
            HStack {
                TextField("Minutes", text: $condition.value)
                    .frame(width: 80)
                Text("minutes in channel")
                    .foregroundStyle(.secondary)
            }
        // New condition types - placeholder UI
        case .channelIs:
            TextField("Enter channel name or ID…", text: $condition.value)
        case .channelCategory:
            TextField("Enter category name or ID…", text: $condition.value)
                .foregroundStyle(.secondary)
        case .userHasRole:
            TextField("Enter role name or ID…", text: $condition.value)
        case .userJoinedRecently:
            HStack {
                TextField("Minutes", text: $condition.value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Text("minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .messageContains:
            TextField("Enter text to match…", text: $condition.value)
        case .messageStartsWith:
            TextField("Enter prefix to match…", text: $condition.value)
        case .messageRegex:
            TextField("Enter regex pattern…", text: $condition.value)
        case .isDirectMessage:
            Text("Passes if the triggering message was sent in a DM.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .isFromBot:
            Text("Passes if the triggering user is a bot.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .isFromUser:
            Text("Passes if the triggering user is a human.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .channelType:
            Picker("Channel Type", selection: $condition.value) {
                Text("Text Channel").tag("0")
                Text("DM").tag("1")
                Text("Voice Channel").tag("2")
                Text("Group DM").tag("3")
                Text("Category").tag("4")
                Text("News").tag("5")
                Text("Stage").tag("13")
            }
        }
    }
}

struct ActionsSectionView: View {
    @Binding var actions: [Action]
    let category: BlockCategory
    let allModifiers: [Action]
    let hasTrigger: Bool

    let serverIds: [String]
    let serverName: (String) -> String
    let textChannelsByServer: [String: [GuildTextChannel]]
    var isGuided: Bool = false
    var incompatibleBlocks: [UUID] = []
    var availableVariables: Set<ContextVariable> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if actions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No blocks yet")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(isGuided
                         ? "Select a block from the Block Library to the left."
                         : "Use the Block Library to add your first block.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach($actions) { $action in
                    let isCompat = !incompatibleBlocks.contains(action.id)
                    let missing = action.type.requiredVariables.subtracting(availableVariables)

                    ActionSectionView(
                        action: $action,
                        category: category,
                        allModifiers: allModifiers,
                        isIncompatible: !isCompat,
                        missingContext: missing.isEmpty ? nil : "Requires \(missing.friendlyRequirement)",
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
        .disabled(!hasTrigger)
        .opacity(hasTrigger ? 1.0 : 0.5)
    }
}

struct ActionSectionView: View {
    @Binding var action: Action
    let category: BlockCategory
    let allModifiers: [Action]
    var isIncompatible: Bool = false
    var missingContext: String? = nil

    let serverIds: [String]
    let serverName: (String) -> String
    let textChannels: [GuildTextChannel]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Block header — immutable once created; type is fixed at drop time
            HStack {
                Label(action.type.rawValue, systemImage: action.type.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(category == .messaging ? .orange : .mint)
                
                if isIncompatible {
                    Label(missingContext ?? "Incompatible with trigger", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.leading, 8)
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
                    Text("Message")
                        .font(.subheadline.weight(.semibold))
                    VariableAwareTextEditor(text: $action.message)
                    if action.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label("Message content is required.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // UI refinement: show active modifiers that affect this action
                if category == .actions { // Action blocks section
                    VStack(alignment: .leading, spacing: 4) {
                        let activeModifiers = allModifiers.map { $0.type.rawValue }.joined(separator: ", ")
                        if !activeModifiers.isEmpty {
                            Label("Active Modifiers: \(activeModifiers)", systemImage: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.indigo)
                        } else {
                            Text("Add modifier blocks (Reply To Trigger, Send To Channel…) above this action to control message routing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
            case .sendDM:
                Toggle("Mention user", isOn: $action.mentionUser)
                VStack(alignment: .leading, spacing: 6) {
                    Text("DM Content")
                        .font(.subheadline.weight(.semibold))
                    VariableAwareTextEditor(text: $action.dmContent)
                }
            case .deleteMessage:
                Text("Delete the triggering message")
                    .foregroundStyle(.secondary)
            case .addReaction:
                TextField("Emoji", text: $action.emoji)
            case .addRole, .removeRole:
                TextField("Role ID", text: $action.roleId)
            case .timeoutMember:
                HStack {
                    TextField("Duration (seconds)", value: $action.timeoutDuration, format: .number)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            case .kickMember:
                TextField("Reason (optional)", text: $action.kickReason)
            case .moveMember:
                TextField("Target Voice Channel ID", text: $action.targetVoiceChannelId)
            case .createChannel:
                TextField("Channel Name", text: $action.newChannelName)
            case .webhook:
                TextField("Webhook URL", text: $action.webhookURL)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Payload Content")
                        .font(.subheadline.weight(.semibold))
                    VariableAwareTextEditor(text: $action.webhookContent)
                }
            case .delay:
                HStack {
                    TextField("Seconds", value: $action.delaySeconds, format: .number)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            case .setVariable:
                HStack {
                    TextField("Variable name", text: $action.variableName)
                    Text("=")
                    TextField("Value", text: $action.variableValue)
                }
            case .randomChoice:
                Text("Random options not yet configurable")
                    .foregroundStyle(.secondary)
            // Message Modifier blocks
            case .replyToTrigger:
                Text("Replies to the message that triggered this rule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .mentionUser:
                Text("Prefixes the message with a mention of the triggering user.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .mentionRole:
                TextField("Role ID to mention", text: $action.roleId)
            case .disableMention:
                Text("Strips any existing user mentions from the message template.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .sendToChannel:
                if textChannels.isEmpty {
                    Text("No text channels discovered for this server.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Target Channel", selection: $action.channelId) {
                        ForEach(textChannels) { channel in
                            Text("#\(channel.name)").tag(channel.id)
                        }
                    }
                }
            // AI block
            case .generateAIResponse:
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI Prompt")
                        .font(.subheadline.weight(.semibold))
                    VariableAwareTextEditor(text: $action.message)
                    Text("The AI response is available as {ai.response} in subsequent blocks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 18, tint: .white.opacity(0.08), stroke: isIncompatible ? Color.orange.opacity(0.4) : .white.opacity(0.16))
        .opacity(isIncompatible ? 0.6 : 1.0)
    }
}

// MARK: - Validation Banner

struct EmptyRuleStateView: View {
    let icon: String
    let title: String
    let description: String
    var onShowMe: (() -> Void)? = nil
    var onContinue: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
                .symbolEffect(.bounce, value: true)
            
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.bold))
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if onShowMe != nil || onContinue != nil {
                HStack(spacing: 12) {
                    if let onShowMe = onShowMe {
                        Button("Show Me", action: onShowMe)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                    if let onContinue = onContinue {
                        Button("Continue", action: onContinue)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 24, tint: .white.opacity(0.05), stroke: .white.opacity(0.1))
    }
}

struct ValidationBannerView: View {
    let issues: [ValidationIssue]

    private var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    private var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(errors) { issue in
                ValidationIssueRow(issue: issue)
            }
            ForEach(warnings) { issue in
                ValidationIssueRow(issue: issue)
            }
        }
    }
}

private struct ValidationIssueRow: View {
    let issue: ValidationIssue

    private var accent: Color { issue.severity == .error ? .red : .orange }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: issue.severity.icon)
                .foregroundStyle(accent)
                .font(.caption.weight(.semibold))
            Text(issue.message)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
            Text(issue.blockType.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent.opacity(0.30), lineWidth: 1)
        )
    }
}

// MARK: - Variable-Aware Text Editor

struct VariableAwareTextEditor: View {
    @Binding var text: String
    @State private var showPicker = false
    @State private var cursorAtEnd = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100)
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                )
                .onChange(of: text) { _, newValue in
                    if newValue.hasSuffix("{") {
                        showPicker = true
                    }
                }

            Button {
                showPicker = true
            } label: {
                Label("Insert Variable", systemImage: "curlybraces")
                    .font(.caption.weight(.medium))
                    .labelStyle(.iconOnly)
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(8)
            .popover(isPresented: $showPicker, arrowEdge: .top) {
                VariablePickerPopover { variable in
                    // Remove the trailing `{` that triggered the picker if present
                    if text.hasSuffix("{") {
                        text.removeLast()
                    }
                    text += variable.rawValue
                    showPicker = false
                }
            }
        }
    }
}

// MARK: - Variable Picker Popover

struct VariablePickerPopover: View {
    let onSelect: (ContextVariable) -> Void

    private var grouped: [(category: String, variables: [ContextVariable])] {
        let categories = ["User", "Message", "Channel", "Server", "Voice", "Reaction", "Other"]
        return categories.compactMap { cat in
            let vars = ContextVariable.allCases.filter { $0.category == cat }
            return vars.isEmpty ? nil : (category: cat, variables: vars)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Insert Variable")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(grouped, id: \.category) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.category.uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            ForEach(group.variables, id: \.self) { variable in
                                Button {
                                    onSelect(variable)
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(variable.rawValue)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.cyan)
                                            .frame(minWidth: 120, alignment: .leading)
                                        Text(variable.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 320, height: 340)
    }
}

// MARK: - Guided Build Step

enum GuidedBuildStep {
    case none, trigger, action
}
