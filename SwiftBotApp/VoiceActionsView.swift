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
    @State private var showRecipeWizard: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if app.isFailoverManagedNode {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                    Text("Read-only on Failover nodes. Action rules sync from Primary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            ActionsWorkspaceHeader(
                rules: ruleStore.rules,
                commandLog: app.commandLog
            )

            ActionsWorkspaceSurface {
                HSplitView {
                    RuleListView(
                        rules: rulesBinding,
                        selectedRuleID: appSelectionBinding,
                        onAddNew: {
                            showRecipeWizard = true
                        },
                        onDeleteRuleID: { ruleID in
                            ruleStore.deleteRule(id: ruleID, undoManager: undoManager)
                        },
                        isLoading: ruleStore.isLoading
                    )
                    .frame(minWidth: 204, idealWidth: 224, maxWidth: 256)

                    Group {
                        if let selectedRuleBinding {
                            RuleEditorView(rule: selectedRuleBinding)
                                .id(ruleStore.selectedRuleID)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Selected Workflow")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.5)

                                VStack(spacing: 8) {
                                    Image(systemName: "list.bullet.rectangle")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                    Text("Select an Action Rule")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                    Text("Choose a rule from the navigator to open its workflow and inspector in this workspace.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(.clear)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)
            .sheet(isPresented: $showRecipeWizard) {
                RecipeWizardView { rule in
                    ruleStore.addRule(rule)
                }
                .environmentObject(app)
            }
            .onChange(of: ruleStore.rules) {
                if let selected = ruleStore.selectedRuleID,
                   !ruleStore.rules.contains(where: { $0.id == selected }) {
                    ruleStore.selectedRuleID = nil
                }
                ruleStore.scheduleAutoSave()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

}

private struct ActionsWorkspaceHeader: View {
    let rules: [Rule]
    let commandLog: [CommandLogEntry]

    private var activeRuleCount: Int {
        rules.filter(\.isEnabled).count
    }

    private var commandsToday: Int {
        commandLog.filter { Calendar.current.isDateInToday($0.time) }.count
    }

    private var globalValidationSummary: String {
        if rules.flatMap(\.validationIssues).contains(where: { $0.severity == .error }) { return "Errors" }
        if rules.flatMap(\.validationIssues).contains(where: { $0.severity == .warning }) { return "Warnings" }
        return "Healthy"
    }

    private var globalValidationSubtitle: String {
        let issueCount = rules.flatMap(\.validationIssues).count
        return issueCount == 0 ? "All rules" : "\(issueCount) issue\(issueCount == 1 ? "" : "s")"
    }

    private var validationColor: Color {
        switch globalValidationSummary {
        case "Errors": return .red
        case "Warnings": return .orange
        default: return .green
        }
    }

    private var lastTriggeredRuleTitle: String {
        "Not tracked"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.badge.automatic.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)

                Text("Automations")
                    .font(.title3.weight(.semibold))
            }

            Text("Build automations that react to Discord events.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ActionsOverviewMetricCard(
                    title: "Active Rules",
                    value: "\(activeRuleCount)",
                    subtitle: "\(rules.count) total rules",
                    symbol: "checkmark.circle.fill",
                    color: .green
                )
                ActionsOverviewMetricCard(
                    title: "Validation Status",
                    value: globalValidationSummary,
                    subtitle: globalValidationSubtitle,
                    symbol: "checkmark.seal.fill",
                    color: validationColor
                )
                ActionsOverviewMetricCard(
                    title: "Last Triggered Rule",
                    value: lastTriggeredRuleTitle,
                    subtitle: "Runtime history",
                    symbol: "clock",
                    color: .orange
                )
                ActionsOverviewMetricCard(
                    title: "Commands Today",
                    value: "\(commandsToday)",
                    subtitle: "Executed today",
                    symbol: "terminal.fill",
                    color: .blue
                )
            }
        }
    }
}

private struct ActionsOverviewMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    let color: Color
    @State private var isHovering = false

    private let cornerRadius: CGFloat = 22

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
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(
            cornerRadius: cornerRadius,
            tint: color.opacity(isHovering ? 0.15 : 0.10),
            stroke: color.opacity(isHovering ? 0.38 : 0.24)
        )
        .scaleEffect(isHovering ? 1.012 : 1)
        .shadow(color: color.opacity(isHovering ? 0.14 : 0.06), radius: isHovering ? 14 : 8, y: isHovering ? 8 : 4)
        .animation(.smooth(duration: 0.18), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct ActionsWorkspaceSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(Color.primary.opacity(0.016))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.065), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.025), radius: 2, x: 0, y: 1)
    }
}

private enum WorkflowInspectorSelection: Equatable {
    case overview
    case trigger
    case condition(UUID)
    case ai(UUID)
    case modifier(UUID)
    case action(UUID)
}

private enum WorkflowStageKind {
    case condition
    case ai
    case modifier
    case action
}

struct RuleEditorView: View {
    @Binding var rule: Rule
    @EnvironmentObject var app: AppModel

    @State private var hasSeenRuleOnboarding: Bool = false
    @State private var guidedStep: GuidedBuildStep = .none
    @State private var scrollToTriggersSignal: Bool = false
    @State private var showBlockLibrary: Bool = false
    @State private var inspectorSelection: WorkflowInspectorSelection = .overview

    private var serverIds: [String] {
        app.connectedServers.keys.sorted {
            (app.connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(app.connectedServers[$1] ?? $1) == .orderedAscending
        }
    }

    private func serverName(for serverId: String) -> String {
        app.connectedServers[serverId] ?? "Server \(serverId.suffix(4))"
    }

    private var primaryServerName: String? {
        if let serverCondition = rule.conditions.first(where: { $0.type == .server && !$0.value.isEmpty }) {
            return serverName(for: serverCondition.value)
        }

        if !rule.triggerServerId.isEmpty {
            return serverName(for: rule.triggerServerId)
        }

        if let actionServerId = rule.actions.first(where: { !$0.serverId.isEmpty })?.serverId {
            return serverName(for: actionServerId)
        }

        return nil
    }

    private var workflowBlockCount: Int {
        rule.conditions.count + rule.aiBlocks.count + rule.modifiers.count + rule.actions.count
    }

    private var workflowPermissionCount: Int {
        let actionPermissions = rule.actions.flatMap { $0.type.requiredPermissions }
        let modifierPermissions = rule.modifiers.flatMap { $0.type.requiredPermissions }
        return Set(actionPermissions + modifierPermissions).count
    }

    private var workflowValidationSummary: String {
        if rule.validationIssues.contains(where: { $0.severity == .error }) { return "Errors" }
        if rule.validationIssues.contains(where: { $0.severity == .warning }) { return "Warnings" }
        return "Healthy"
    }

    private var ruleCanvasContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if rule.trigger == nil && !hasSeenRuleOnboarding {
                EmptyRuleStateView(
                    icon: "bolt.circle",
                    title: "Choose a Trigger",
                    description: "Select a trigger from the Blocks library to begin building this rule.",
                    onShowMe: {
                        openBlockLibrary(focusTrigger: true)
                    },
                    onContinue: {
                        hasSeenRuleOnboarding = true
                        inspectorSelection = .trigger
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
                WorkflowStageView(
                    title: "Trigger",
                    systemImage: "bolt.fill",
                    accent: .yellow,
                    subtitle: "The event that starts this automation",
                    trailingMeta: "Stage 1",
                    isFocused: inspectorSelection == .trigger || guidedStep == .trigger
                ) {
                    WorkflowStepSummaryRow(
                        title: rule.trigger?.rawValue ?? "Choose Trigger",
                        subtitle: rule.trigger == nil ? "Select the event that starts this automation." : rule.triggerSummary,
                        systemImage: rule.trigger?.symbol ?? "bolt.badge.questionmark",
                        accent: .yellow,
                        isSelected: inspectorSelection == .trigger,
                        badge: rule.trigger == nil ? "Required" : nil,
                        action: {
                            inspectorSelection = .trigger
                        }
                    )
                }

                WorkflowInsertionLane(title: "Add Filter", accent: .blue) {
                    inspectorSelection = .overview
                    openBlockLibrary()
                }

                WorkflowStageView(
                    title: "Filters",
                    systemImage: "line.3.horizontal.decrease.circle",
                    accent: .blue,
                    subtitle: "Conditions that gate execution",
                    trailingMeta: "Stage 2",
                    isFocused: isInspectorFocused(in: rule.conditions.map(\.id), matching: .condition)
                ) {
                    if rule.conditions.isEmpty {
                        WorkflowStagePlaceholder(
                            title: "No filters configured",
                            subtitle: "Add conditions to narrow when the rule should run.",
                            accent: .blue
                        )
                    } else {
                        ForEach(rule.conditions) { condition in
                            WorkflowStepSummaryRow(
                                title: condition.type.rawValue,
                                subtitle: summary(for: condition),
                                systemImage: condition.type.symbol,
                                accent: .blue,
                                isSelected: inspectorSelection == .condition(condition.id),
                                badge: rule.incompatibleBlocks.contains(condition.id) ? "Review" : nil,
                                action: {
                                    inspectorSelection = .condition(condition.id)
                                },
                                onDelete: {
                                    deleteCondition(condition.id)
                                }
                            )
                        }
                    }
                }

                WorkflowInsertionLane(title: "Add AI Block", accent: .purple) {
                    inspectorSelection = .overview
                    openBlockLibrary()
                }

                WorkflowStageView(
                    title: "AI Processing",
                    systemImage: "sparkles",
                    accent: .purple,
                    subtitle: "Optional processing that runs before message output",
                    trailingMeta: "Optional",
                    isFocused: isInspectorFocused(in: rule.aiBlocks.map(\.id), matching: .ai)
                ) {
                    if rule.aiBlocks.isEmpty {
                        WorkflowStagePlaceholder(
                            title: "No AI stage configured",
                            subtitle: "Add AI blocks when the rule needs generation, classification, or extraction.",
                            accent: .purple
                        )
                    } else {
                        ForEach(rule.aiBlocks) { action in
                            WorkflowStepSummaryRow(
                                title: action.type.rawValue,
                                subtitle: summary(for: action, category: .ai),
                                systemImage: action.type.symbol,
                                accent: .purple,
                                isSelected: inspectorSelection == .ai(action.id),
                                action: {
                                    inspectorSelection = .ai(action.id)
                                },
                                onDelete: {
                                    deleteAction(action.id, from: \.aiBlocks)
                                }
                            )
                        }
                    }
                }

                WorkflowInsertionLane(title: "Add Modifier", accent: .orange) {
                    inspectorSelection = .overview
                    openBlockLibrary()
                }

                WorkflowStageView(
                    title: "Modifiers",
                    systemImage: "slider.horizontal.3",
                    accent: .orange,
                    subtitle: "Routing and formatting changes applied before outputs",
                    trailingMeta: "Stage 3",
                    isFocused: isInspectorFocused(in: rule.modifiers.map(\.id), matching: .modifier)
                ) {
                    if rule.modifiers.isEmpty {
                        WorkflowStagePlaceholder(
                            title: "No modifiers configured",
                            subtitle: "Add message routing and formatting changes here.",
                            accent: .orange
                        )
                    } else {
                        ForEach(rule.modifiers) { action in
                            WorkflowStepSummaryRow(
                                title: action.type.rawValue,
                                subtitle: summary(for: action, category: .messaging),
                                systemImage: action.type.symbol,
                                accent: .orange,
                                isSelected: inspectorSelection == .modifier(action.id),
                                action: {
                                    inspectorSelection = .modifier(action.id)
                                },
                                onDelete: {
                                    deleteAction(action.id, from: \.modifiers)
                                }
                            )
                        }
                    }
                }

                WorkflowInsertionLane(title: "Add Action", accent: .mint) {
                    inspectorSelection = .overview
                    openBlockLibrary()
                }

                WorkflowStageView(
                    title: "Actions",
                    systemImage: "paperplane.fill",
                    accent: .mint,
                    subtitle: "Outputs executed in order",
                    trailingMeta: "Stage 4",
                    isFocused: isInspectorFocused(in: rule.actions.map(\.id), matching: .action) || guidedStep == .action
                ) {
                    if rule.actions.isEmpty {
                        WorkflowStagePlaceholder(
                            title: "No output actions configured",
                            subtitle: "Add at least one action so the rule produces an effect.",
                            accent: .mint
                        )
                    } else {
                        ForEach(rule.actions) { action in
                            WorkflowStepSummaryRow(
                                title: action.type.rawValue,
                                subtitle: summary(for: action, category: action.type.category),
                                systemImage: action.type.symbol,
                                accent: .mint,
                                isSelected: inspectorSelection == .action(action.id),
                                badge: rule.incompatibleBlocks.contains(action.id) ? "Review" : nil,
                                action: {
                                    inspectorSelection = .action(action.id)
                                },
                                onDelete: {
                                    deleteAction(action.id, from: \.actions)
                                }
                            )
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: rule.isEmptyRule)
        .frame(maxWidth: 940, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch inspectorSelection {
        case .overview:
            RuleInspectorOverview(
                issues: rule.validationIssues,
                availableVariables: availableVariables,
                hasTrigger: rule.trigger != nil,
                previewMessage: previewMessage,
                onShowBlocks: {
                    openBlockLibrary(focusTrigger: rule.trigger == nil)
                }
            )
        case .trigger:
            TriggerInspectorView(
                trigger: rule.trigger,
                triggerSummary: rule.triggerSummary,
                providedVariables: availableVariables,
                onChangeTrigger: {
                    rule.isEditingTrigger = true
                    openBlockLibrary(focusTrigger: true)
                }
            )
        case .condition(let id):
            if let binding = conditionBinding(for: id) {
                ConditionRowView(
                    condition: binding,
                    isIncompatible: rule.incompatibleBlocks.contains(id),
                    missingContext: missingContextText(forConditionID: id),
                    serverIds: serverIds,
                    serverName: serverName(for:),
                    voiceChannels: app.availableVoiceChannelsByServer.values.flatMap { $0 },
                    textChannels: app.availableTextChannelsByServer.values.flatMap { $0 },
                    roles: app.availableRolesByServer.values.flatMap { $0 },
                    onDelete: {
                        deleteCondition(id)
                    }
                )
            } else {
                RuleInspectorOverview(
                    issues: rule.validationIssues,
                    availableVariables: availableVariables,
                    hasTrigger: rule.trigger != nil,
                    previewMessage: previewMessage,
                    onShowBlocks: {
                        openBlockLibrary(focusTrigger: rule.trigger == nil)
                    }
                )
            }
        case .ai(let id):
            inspectorActionView(id: id, keyPath: \.aiBlocks, category: .ai, title: "AI Block")
        case .modifier(let id):
            inspectorActionView(id: id, keyPath: \.modifiers, category: .messaging, title: "Modifier")
        case .action(let id):
            inspectorActionView(id: id, keyPath: \.actions, category: .actions, title: "Action")
        }
    }

    private var inspectorTitle: String {
        switch inspectorSelection {
        case .overview:
            return "Inspector"
        case .trigger:
            return "Trigger"
        case .condition(let id):
            return rule.conditions.first(where: { $0.id == id })?.type.rawValue ?? "Filter"
        case .ai(let id):
            return rule.aiBlocks.first(where: { $0.id == id })?.type.rawValue ?? "AI Block"
        case .modifier(let id):
            return rule.modifiers.first(where: { $0.id == id })?.type.rawValue ?? "Modifier"
        case .action(let id):
            return rule.actions.first(where: { $0.id == id })?.type.rawValue ?? "Action"
        }
    }

    private var inspectorSubtitle: String {
        switch inspectorSelection {
        case .overview:
            return "Select a workflow step to edit its configuration."
        case .trigger:
            return "Choose the event that starts this automation."
        case .condition:
            return "Filter configuration lives here so the canvas can stay focused on flow."
        case .ai:
            return "Tune AI prompts and processing options for this stage."
        case .modifier:
            return "Adjust message routing and formatting for this step."
        case .action:
            return "Configure how this workflow produces its final output."
        }
    }

    private var inspectorSymbol: String {
        switch inspectorSelection {
        case .overview:
            return "sidebar.right"
        case .trigger:
            return "bolt.fill"
        case .condition:
            return "line.3.horizontal.decrease.circle"
        case .ai:
            return "sparkles"
        case .modifier:
            return "slider.horizontal.3"
        case .action:
            return "paperplane.fill"
        }
    }

    private var inspectorAccent: Color {
        switch inspectorSelection {
        case .overview:
            return .secondary
        case .trigger:
            return .yellow
        case .condition:
            return .blue
        case .ai:
            return .purple
        case .modifier:
            return .orange
        case .action:
            return .mint
        }
    }

    private var availableVariables: [ContextVariable] {
        Array(rule.trigger?.providedVariables ?? []).sorted { $0.rawValue < $1.rawValue }
    }

    private var previewMessage: String? {
        guard let messageAction = rule.actions.first(where: { $0.type == .sendMessage }) else { return nil }
        switch messageAction.contentSource {
        case .custom:
            let trimmed = messageAction.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return "Uses \(messageAction.contentSource.displayName) at runtime."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            RuleEditorSummaryHeader(
                ruleSymbol: rule.trigger?.symbol ?? "bolt.circle",
                ruleName: $rule.name,
                ruleSubtitle: rule.triggerSummary,
                workflowStatus: rule.isEnabled ? "Enabled" : "Disabled",
                triggerLabel: rule.trigger?.rawValue,
                serverLabel: primaryServerName,
                lastTriggeredLabel: "Not yet",
                blockCount: workflowBlockCount,
                permissionCount: workflowPermissionCount,
                validationLabel: workflowValidationSummary,
                onShowLibrary: {
                    openBlockLibrary(focusTrigger: rule.trigger == nil)
                }
            )
            .padding(.horizontal, 16)
            .frame(height: 76)

            HSplitView {
                ScrollView {
                    ruleCanvasContent
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.006))

                VStack(spacing: 0) {
                    RulePaneHeader(
                        title: inspectorTitle,
                        subtitle: inspectorSubtitle,
                        systemImage: inspectorSymbol
                    )

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            InspectorSelectionContextView(
                                title: inspectorTitle,
                                subtitle: inspectorSubtitle,
                                systemImage: inspectorSymbol,
                                accent: inspectorAccent
                            )

                            inspectorContent
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                    }
                }
                .frame(minWidth: 280, idealWidth: 312, maxWidth: 360)
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(Color.primary.opacity(0.018))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: 1)
                        }
                )
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .popover(isPresented: $showBlockLibrary, arrowEdge: .top) {
            VStack(spacing: 0) {
                RulePaneHeader(
                    title: "Blocks",
                    subtitle: "Add compatible stages and outputs to this workflow.",
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
                        inspectorSelection = .trigger
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
            .frame(width: 340, height: 620)
            .background(.thinMaterial)
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

    @ViewBuilder
    private func inspectorActionView(
        id: UUID,
        keyPath: WritableKeyPath<Rule, [Action]>,
        category: BlockCategory,
        title: String
    ) -> some View {
        if let binding = actionBinding(for: id, in: keyPath) {
            ActionSectionView(
                action: binding,
                category: category,
                allModifiers: rule.modifiers,
                currentTrigger: rule.trigger,
                isIncompatible: rule.incompatibleBlocks.contains(id),
                missingContext: missingContextText(forActionID: id, in: keyPath),
                serverIds: serverIds,
                serverName: serverName(for:),
                textChannelsByServer: app.availableTextChannelsByServer,
                voiceChannelsByServer: app.availableVoiceChannelsByServer,
                rolesByServer: app.availableRolesByServer,
                knownUsers: app.knownUsersById,
                onDelete: {
                    deleteAction(id, from: keyPath)
                }
            )
        } else {
            RuleInspectorOverview(
                issues: rule.validationIssues,
                availableVariables: availableVariables,
                hasTrigger: rule.trigger != nil,
                previewMessage: previewMessage,
                onShowBlocks: {
                    openBlockLibrary(focusTrigger: rule.trigger == nil)
                }
            )
        }
    }

    private func openBlockLibrary(focusTrigger: Bool = false) {
        showBlockLibrary = true
        if focusTrigger {
            scrollToTriggersSignal = true
            guidedStep = .trigger
        }
    }

    private func isInspectorFocused(in ids: [UUID], matching stage: WorkflowStageKind) -> Bool {
        switch (stage, inspectorSelection) {
        case (.condition, .condition(let selected)):
            return ids.contains(selected)
        case (.ai, .ai(let selected)):
            return ids.contains(selected)
        case (.modifier, .modifier(let selected)):
            return ids.contains(selected)
        case (.action, .action(let selected)):
            return ids.contains(selected)
        default:
            return false
        }
    }

    private func conditionBinding(for id: UUID) -> Binding<Condition>? {
        guard rule.conditions.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                rule.conditions.first(where: { $0.id == id }) ?? Condition(type: .server)
            },
            set: { updatedCondition in
                guard let index = rule.conditions.firstIndex(where: { $0.id == id }) else { return }
                rule.conditions[index] = updatedCondition
            }
        )
    }

    private func actionBinding(for id: UUID, in keyPath: WritableKeyPath<Rule, [Action]>) -> Binding<Action>? {
        guard rule[keyPath: keyPath].contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                rule[keyPath: keyPath].first(where: { $0.id == id }) ?? Action()
            },
            set: { updatedAction in
                guard let index = rule[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { return }
                rule[keyPath: keyPath][index] = updatedAction
            }
        )
    }

    private func deleteCondition(_ id: UUID) {
        rule.conditions.removeAll { $0.id == id }
        inspectorSelection = .overview
        app.ruleStore.scheduleAutoSave()
    }

    private func deleteAction(_ id: UUID, from keyPath: WritableKeyPath<Rule, [Action]>) {
        rule[keyPath: keyPath].removeAll { $0.id == id }
        inspectorSelection = .overview
        app.ruleStore.scheduleAutoSave()
    }

    private func missingContextText(forConditionID id: UUID) -> String? {
        guard
            let condition = rule.conditions.first(where: { $0.id == id }),
            let trigger = rule.trigger
        else { return nil }
        let missing = condition.type.requiredVariables.subtracting(trigger.providedVariables)
        return missing.isEmpty ? nil : "Requires \(missing.friendlyRequirement)"
    }

    private func missingContextText(forActionID id: UUID, in keyPath: KeyPath<Rule, [Action]>) -> String? {
        guard
            let action = rule[keyPath: keyPath].first(where: { $0.id == id }),
            let trigger = rule.trigger
        else { return nil }
        let missing = action.type.requiredVariables.subtracting(trigger.providedVariables)
        return missing.isEmpty ? nil : "Requires \(missing.friendlyRequirement)"
    }

    private func summary(for condition: Condition) -> String {
        switch condition.type {
        case .server:
            return condition.value.isEmpty ? "Runs in any server." : "Limited to \(serverName(for: condition.value))."
        case .voiceChannel:
            return condition.value.isEmpty ? "Applies to any voice channel." : "Matches a specific voice channel."
        case .usernameContains:
            return condition.value.isEmpty ? "Checks for a username fragment." : "Matches users containing “\(condition.value)”."
        case .minimumDuration:
            return condition.value.isEmpty ? "Minimum time not configured." : "Requires at least \(condition.value) minute(s) in channel."
        case .channelIs:
            return condition.value.isEmpty ? "Matches a specific text channel." : "Limited to one text channel."
        case .channelCategory:
            return condition.value.isEmpty ? "Matches a channel category." : "Category filter: \(condition.value)."
        case .userHasRole:
            return condition.value.isEmpty ? "Checks for a required role." : "Requires a selected role."
        case .userJoinedRecently:
            return condition.value.isEmpty ? "Checks how recently the user joined." : "User must have joined within \(condition.value) minute(s)."
        case .messageContains:
            return condition.value.isEmpty ? "Matches message text." : "Requires text matching “\(condition.value)”."
        case .messageStartsWith:
            return condition.value.isEmpty ? "Matches a message prefix." : "Requires prefix “\(condition.value)”."
        case .messageRegex:
            return condition.value.isEmpty ? "Matches a regex pattern." : "Uses regex pattern “\(condition.value)”."
        case .isDirectMessage:
            return "Only runs for messages sent in DMs."
        case .isFromBot:
            return "Only runs for bot-authored events."
        case .isFromUser:
            return "Only runs for human-authored events."
        case .channelType:
            return condition.value.isEmpty ? "Matches a channel type." : "Channel type filter is configured."
        }
    }

    private func summary(for action: Action, category: BlockCategory) -> String {
        switch action.type {
        case .sendMessage:
            switch action.contentSource {
            case .custom:
                let snippet = action.message.trimmingCharacters(in: .whitespacesAndNewlines)
                return snippet.isEmpty ? "Sends a custom message." : String(snippet.prefix(70))
            default:
                return "Uses \(action.contentSource.displayName) as the message content."
            }
        case .replyToTrigger:
            return "Replies directly to the event that triggered the rule."
        case .mentionUser:
            return "Mentions the triggering user before the message body."
        case .mentionRole:
            return "Mentions a selected role in the output."
        case .disableMention:
            return "Prevents user mentions in the final message."
        case .sendToChannel:
            return "Routes output to a specific text channel."
        case .sendToDM:
            return "Sends the output to the user via direct message."
        case .generateAIResponse:
            return "Generates text with AI before later stages run."
        case .summariseMessage:
            return "Summarises the triggering message into AI summary output."
        case .classifyMessage:
            return "Classifies the message into predefined categories."
        case .extractEntities:
            return "Extracts named entities for later steps."
        case .rewriteMessage:
            return "Rewrites incoming text in a configured style."
        case .addRole:
            return "Adds a server role to the member."
        case .removeRole:
            return "Removes a server role from the member."
        case .timeoutMember:
            return "Temporarily restricts the member."
        case .kickMember:
            return "Removes the member from the server."
        case .moveMember:
            return "Moves the member into a voice channel."
        case .deleteMessage:
            return "Deletes the triggering message."
        case .addReaction:
            return action.emoji.isEmpty ? "Adds a reaction." : "Adds the \(action.emoji) reaction."
        case .sendDM:
            return "Sends a direct message to the user."
        case .createChannel:
            return action.newChannelName.isEmpty ? "Creates a channel." : "Creates the channel “\(action.newChannelName)”."
        case .webhook:
            return "Posts the payload to a webhook endpoint."
        case .setStatus:
            return "Updates the bot status text."
        case .addLogEntry:
            return "Writes a log entry for this automation."
        case .delay:
            return "Waits before later actions execute."
        case .setVariable:
            return action.variableName.isEmpty ? "Sets a workflow variable." : "Sets the variable \(action.variableName)."
        case .randomChoice:
            return "Chooses one option at random."
        }
    }

    private func addCondition(_ type: ConditionType) {
        let condition = Condition(type: type)
        rule.conditions.append(condition)
        inspectorSelection = .condition(condition.id)
        app.ruleStore.scheduleAutoSave()
    }

    private func addAction(_ type: ActionType) {
        var action = RuleAction()
        action.type = type
        action.message = rule.trigger?.defaultMessage ?? ""

        switch type {
        case .sendMessage:
            action.destinationMode = MessageDestination.defaultMode(for: rule.trigger)
            if action.destinationMode == .specificChannel {
                action.serverId = serverIds.first ?? ""
                action.channelId = app.availableTextChannelsByServer[action.serverId]?.first?.id ?? ""
            }
        case .addLogEntry:
            action.message = "Rule fired for {username}"
        case .setStatus:
            action.statusText = "Handling \(rule.trigger?.rawValue.lowercased() ?? "action")"
        // Modifier blocks
        case .replyToTrigger, .mentionUser, .mentionRole, .disableMention, .sendToChannel, .sendToDM:
            break
        // AI blocks
        case .generateAIResponse:
            action.message = "You are a helpful assistant. {message}"
        case .summariseMessage:
            action.message = ""
        case .classifyMessage:
            action.message = ""
            action.categories = "question, feedback, spam, other"
        case .extractEntities:
            action.message = ""
            action.entityTypes = "names, dates, locations, organizations"
        case .rewriteMessage:
            action.message = ""
            action.rewriteStyle = "professional"
        // Other action types
        case .sendDM, .deleteMessage, .addReaction, .addRole, .removeRole,
             .timeoutMember, .kickMember, .moveMember, .createChannel, .webhook, .delay,
             .setVariable, .randomChoice:
            break
        }

        // Route blocks to their correct section based on category
        switch type.category {
        case .ai:
            rule.aiBlocks.append(action)
            inspectorSelection = .ai(action.id)
        case .messaging:
            rule.modifiers.append(action)
            inspectorSelection = .modifier(action.id)
        case .actions, .moderation:
            rule.actions.append(action)
            inspectorSelection = .action(action.id)
        default:
            rule.actions.append(action)
            inspectorSelection = .action(action.id)
        }
        app.ruleStore.scheduleAutoSave()
    }

    private func initializeRuleDefaultsIfNeeded() {
        var didChange = false

        for index in rule.actions.indices where rule.actions[index].type == .sendMessage {
            if rule.actions[index].destinationMode == nil {
                rule.actions[index].destinationMode = MessageDestination.defaultMode(for: rule.trigger)
                didChange = true
            }

            let destinationMode = rule.actions[index].destinationMode ?? MessageDestination.defaultMode(for: rule.trigger)
            guard destinationMode == .specificChannel else { continue }

            if rule.actions[index].serverId.isEmpty, let first = serverIds.first {
                rule.actions[index].serverId = first
                didChange = true
            }

            let channels = app.availableTextChannelsByServer[rule.actions[index].serverId] ?? []
            if !channels.contains(where: { $0.id == rule.actions[index].channelId }),
               let first = channels.first {
                rule.actions[index].channelId = first.id
                didChange = true
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
        action.destinationMode = .replyToTrigger
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
        Color.clear
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

            let aiTypes = types(for: .ai)
            if !aiTypes.isEmpty {
                RuleLibrarySection(title: "AI Blocks") {
                    ForEach(aiTypes) { type in
                        if type.isCompatible(with: currentTrigger) {
                            RuleLibraryButton(
                                title: type.rawValue,
                                subtitle: "Process input with AI",
                                systemImage: type.symbol,
                                accent: .purple,
                                action: { onAddAction(type) }
                            )
                        }
                    }
                }
            }

            let messageTypes = types(for: .messaging)
            if !messageTypes.isEmpty {
                RuleLibrarySection(title: "Message Modifiers") { // Changed title from "Message"
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
        .background(.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.primary.opacity(0.055))
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
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(highlighted ? .yellow : .secondary)
                    .tracking(0.4)
                Capsule()
                    .fill(.primary.opacity(0.08))
                    .frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
        .padding(10)
        .glassCard(
            cornerRadius: 18,
            tint: highlighted ? Color.yellow.opacity(0.12) : .white.opacity(0.045),
            stroke: highlighted ? Color.yellow.opacity(0.35) : .white.opacity(0.08)
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
    var disabledReason: String?
    var dragItem: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isDisabled ? .secondary : accent)
                    .frame(width: 26, height: 26)
                    .background(accent.opacity(isHovering ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovering ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accent.opacity(isHovering ? 0.18 : 0.00), lineWidth: 1)
            )
            .opacity(isDisabled ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(isDisabled ? (disabledReason ?? "Incompatible") : "")
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.18)) {
                isHovering = hovering
            }
        }
    }
}

struct RuleCanvasSection<Content: View>: View {
    let title: String
    let systemImage: String
    let accent: Color
    var subtitle: String? = nil
    var trailingMeta: String? = nil
    var guidedHighlight: Bool = false
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let trailingMeta, !trailingMeta.isEmpty {
                    Text(trailingMeta)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.08), in: Capsule())
                }
            }
            Rectangle()
                .fill(.primary.opacity(0.07))
                .frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .glassCard(
            cornerRadius: 22,
            tint: accent.opacity(isHovering || guidedHighlight ? 0.085 : 0.045),
            stroke: guidedHighlight ? accent.opacity(0.50) : .white.opacity(isHovering ? 0.16 : 0.10)
        )
        .shadow(color: accent.opacity(guidedHighlight ? 0.12 : 0.04), radius: guidedHighlight ? 18 : 8, y: guidedHighlight ? 8 : 3)
        .animation(.easeInOut(duration: 0.3), value: guidedHighlight)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.18)) {
                isHovering = hovering
            }
        }
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
    let textChannels: [GuildTextChannel]
    let roles: [GuildRole]
    var incompatibleBlocks: [UUID] = []
    var availableVariables: Set<ContextVariable> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if conditions.isEmpty {
                Text("No filters yet. Open Blocks to add one.")
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
                        textChannels: textChannels,
                        roles: roles,
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
    var missingContext: String?

    let serverIds: [String]
    let serverName: (String) -> String
    let voiceChannels: [GuildVoiceChannel]
    let textChannels: [GuildTextChannel]
    let roles: [GuildRole]
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: condition.type.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 28, height: 28)
                    .background(.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(condition.type.rawValue)
                        .font(.subheadline.weight(.semibold))
                    Text("Filter condition")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

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
        .padding(12)
        .glassCard(
            cornerRadius: 17,
            tint: Color.cyan.opacity(isHovering ? 0.075 : 0.035),
            stroke: isIncompatible ? Color.orange.opacity(0.35) : .white.opacity(isHovering ? 0.15 : 0.08)
        )
        .shadow(color: Color.cyan.opacity(isHovering ? 0.10 : 0.025), radius: isHovering ? 12 : 5, y: isHovering ? 5 : 1)
        .opacity(isIncompatible ? 0.6 : 1.0)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.18)) {
                isHovering = hovering
            }
        }
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
            SearchableIDPicker(
                title: "Channel",
                selectionID: $condition.value,
                items: textChannels.map { .init(id: $0.id, name: "#\($0.name)") },
                prompt: "Select a channel..."
            )
        case .channelCategory:
            TextField("Enter category name or ID…", text: $condition.value)
                .foregroundStyle(.secondary)
        case .userHasRole:
            SearchableIDPicker(
                title: "Role",
                selectionID: $condition.value,
                items: roles.map { .init(id: $0.id, name: $0.name) },
                prompt: "Select a role..."
            )
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
    let currentTrigger: TriggerType?
    let hasTrigger: Bool

    let serverIds: [String]
    let serverName: (String) -> String
    let textChannelsByServer: [String: [GuildTextChannel]]
    let voiceChannelsByServer: [String: [GuildVoiceChannel]]
    let rolesByServer: [String: [GuildRole]]
    let knownUsers: [String: String]
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
                    Text(textForEmptyState(category: category, isGuided: isGuided))
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
                        currentTrigger: currentTrigger,
                        isIncompatible: !isCompat,
                        missingContext: missing.isEmpty ? nil : "Requires \(missing.friendlyRequirement)",
                        serverIds: serverIds,
                        serverName: serverName,
                        textChannelsByServer: textChannelsByServer,
                        voiceChannelsByServer: voiceChannelsByServer,
                        rolesByServer: rolesByServer,
                        knownUsers: knownUsers,
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

    private func textForEmptyState(category: BlockCategory, isGuided: Bool) -> String {
        switch category {
        case .ai:
            return "No AI processing blocks yet. Open Blocks to add one.\n\nExamples:\nGenerate AI Response\nSummarise Message\nClassify Message"
        default:
            return isGuided
                 ? "Open Blocks and choose the next block for this rule."
                 : "Open Blocks to add your first block."
        }
    }
}

struct ActionSectionView: View {
    @Binding var action: Action
    let category: BlockCategory
    let allModifiers: [Action]
    let currentTrigger: TriggerType?
    var isIncompatible: Bool = false
    var missingContext: String?

    let serverIds: [String]
    let serverName: (String) -> String
    let textChannelsByServer: [String: [GuildTextChannel]]
    let voiceChannelsByServer: [String: [GuildVoiceChannel]]
    let rolesByServer: [String: [GuildRole]]
    let knownUsers: [String: String]
    let onDelete: () -> Void
    @State private var isHovering = false

    private var resolvedDestinationMode: MessageDestination {
        action.destinationMode ?? MessageDestination.defaultMode(for: currentTrigger)
    }

    private var resolvedServerId: String {
        if !action.serverId.isEmpty {
            return action.serverId
        }
        return serverIds.first ?? ""
    }

    private var textChannels: [GuildTextChannel] {
        textChannelsByServer[resolvedServerId] ?? []
    }

    private var voiceChannels: [GuildVoiceChannel] {
        voiceChannelsByServer[resolvedServerId] ?? []
    }

    private var roles: [GuildRole] {
        rolesByServer[resolvedServerId] ?? []
    }

    private var blockAccent: Color {
        if isIncompatible { return .orange }
        switch category {
        case .ai: return .purple
        case .messaging: return .orange
        case .moderation: return .red
        case .actions: return .mint
        default: return .accentColor
        }
    }

    private var blockMetadata: String {
        switch category {
        case .ai: return "AI block"
        case .messaging: return "Modifier"
        case .moderation: return "Moderation"
        case .actions: return "Action"
        default: return "Block"
        }
    }

    private var destinationBinding: Binding<MessageDestination> {
        Binding(
            get: { resolvedDestinationMode },
            set: { newValue in
                action.destinationMode = newValue
                if newValue == .specificChannel {
                    ensureSpecificChannelSelection()
                }
            }
        )
    }

    private func ensureSpecificChannelSelection() {
        if action.serverId.isEmpty {
            action.serverId = serverIds.first ?? ""
        }
        let availableChannels = textChannelsByServer[action.serverId] ?? []
        if !availableChannels.contains(where: { $0.id == action.channelId }) {
            action.channelId = availableChannels.first?.id ?? ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Block header — immutable once created; type is fixed at drop time
            HStack {
                Image(systemName: action.type.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(blockAccent)
                    .frame(width: 28, height: 28)
                    .background(blockAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.type.rawValue)
                        .font(.subheadline.weight(.semibold))
                    Text(blockMetadata)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

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
            Rectangle()
                .fill(.primary.opacity(0.06))
                .frame(height: 1)

            switch action.type {
            case .sendMessage:
                Picker("Destination", selection: destinationBinding) {
                    ForEach(MessageDestination.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                switch resolvedDestinationMode {
                case .replyToTrigger:
                    Label("Replies to the triggering message automatically.", systemImage: "arrowshape.turn.up.left.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .sameChannel:
                    Label("Uses the trigger channel automatically.", systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .specificChannel:
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
                }

                Picker("Content Source", selection: $action.contentSource) {
                    ForEach(ContentSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }

                if action.contentSource == .custom {
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
                } else {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.indigo)
                        Text("Uses AI output from \(action.contentSource.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if category == .actions {
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
            case .deleteMessage:
                Text("Delete the triggering message")
                    .foregroundStyle(.secondary)
            case .addReaction:
                TextField("Emoji", text: $action.emoji)
            case .addRole, .removeRole:
                SearchableIDPicker(
                    title: "Role",
                    selectionID: $action.roleId,
                    items: roles.map { .init(id: $0.id, name: $0.name) },
                    prompt: "Select a role..."
                )
            case .timeoutMember:
                HStack {
                    TextField("Duration (seconds)", value: $action.timeoutDuration, format: .number)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            case .kickMember:
                TextField("Reason (optional)", text: $action.kickReason)
            case .moveMember:
                SearchableIDPicker(
                    title: "Target Voice Channel",
                    selectionID: $action.targetVoiceChannelId,
                    items: voiceChannels.map { .init(id: $0.id, name: $0.name) },
                    prompt: "Select a voice channel..."
                )
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
                SearchableIDPicker(
                    title: "Role to Mention",
                    selectionID: $action.roleId,
                    items: roles.map { .init(id: $0.id, name: $0.name) },
                    prompt: "Select a role..."
                )
            case .disableMention:
                Text("Strips any existing user mentions from the message template.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .sendToChannel:
                SearchableIDPicker(
                    title: "Target Channel",
                    selectionID: $action.channelId,
                    items: textChannels.map { .init(id: $0.id, name: "#\($0.name)") },
                    prompt: "Select a channel..."
                )
            case .sendToDM:
                Text("Sends the message as a DM to the triggering user.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            // AI blocks
            case .generateAIResponse:
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI Prompt")
                        .font(.subheadline.weight(.semibold))
                    VariableAwareTextEditor(text: $action.message)
                    Text("The AI response is available as {ai.response} in later modifiers and actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .summariseMessage:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Summarization Prompt (Optional)")
                        .font(.subheadline.weight(.semibold))
                    VariableAwareTextEditor(text: $action.message)
                    Text("The AI summary is available as {ai.summary} in later modifiers and actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .classifyMessage:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Classification Prompt")
                        .font(.subheadline.weight(.semibold))
                    VariableAwareTextEditor(text: $action.message)
                    Text("The AI classification is available as {ai.classification} in later modifiers and actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .extractEntities:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Entity Extraction Prompt")
                        .font(.subheadline.weight(.semibold))
                    VariableAwareTextEditor(text: $action.message)
                    Text("The extracted entities are available as {ai.entities} in later modifiers and actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .rewriteMessage:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rewriting Prompt")
                        .font(.subheadline.weight(.semibold))
                    VariableAwareTextEditor(text: $action.message)
                    Text("The rewritten message is available as {ai.rewrite} in later modifiers and actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .glassCard(
            cornerRadius: 17,
            tint: blockAccent.opacity(isHovering ? 0.075 : 0.035),
            stroke: isIncompatible ? Color.orange.opacity(0.34) : .white.opacity(isHovering ? 0.15 : 0.08)
        )
        .shadow(color: blockAccent.opacity(isHovering ? 0.10 : 0.025), radius: isHovering ? 12 : 5, y: isHovering ? 5 : 1)
        .opacity(isIncompatible ? 0.6 : 1.0)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.18)) {
                isHovering = hovering
            }
        }
        .onAppear {
            if action.type == .sendMessage, resolvedDestinationMode == .specificChannel {
                ensureSpecificChannelSelection()
            }
        }
        .onChange(of: action.serverId) { _, _ in
            if action.type == .sendMessage, resolvedDestinationMode == .specificChannel {
                ensureSpecificChannelSelection()
            }
        }
    }
}

private struct RuleEditorSummaryHeader: View {
    let ruleSymbol: String
    @Binding var ruleName: String
    let ruleSubtitle: String
    let workflowStatus: String
    let triggerLabel: String?
    let serverLabel: String?
    let lastTriggeredLabel: String
    let blockCount: Int
    let permissionCount: Int
    let validationLabel: String
    let onShowLibrary: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: ruleSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField("Rule Name", text: $ruleName)
                            .textFieldStyle(.plain)
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: 240)

                        WorkflowContextPill(title: workflowStatus, systemImage: workflowStatus == "Enabled" ? "checkmark.circle.fill" : "pause.circle.fill")
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Text(ruleSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if let triggerLabel, !triggerLabel.isEmpty {
                                WorkflowContextPill(title: "Trigger: \(triggerLabel)", systemImage: "bolt.fill")
                            }
                            if let serverLabel, !serverLabel.isEmpty {
                                WorkflowContextPill(title: serverLabel, systemImage: "server.rack")
                            }
                            WorkflowContextPill(title: "Last: \(lastTriggeredLabel)", systemImage: "clock")
                            WorkflowContextPill(title: "\(blockCount) block\(blockCount == 1 ? "" : "s")", systemImage: "square.stack.3d.up.fill")
                            WorkflowContextPill(title: validationLabel, systemImage: validationLabel == "Healthy" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            if permissionCount > 0 {
                                WorkflowContextPill(title: "\(permissionCount) permission\(permissionCount == 1 ? "" : "s")", systemImage: "lock.shield.fill")
                            }
                        }
                    }
                    .frame(height: 22)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            Button(action: onShowLibrary) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.primary.opacity(0.055))
                .frame(height: 1)
        }
    }
}

private struct WorkflowContextPill: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.045), in: Capsule())
    }
}

private struct WorkflowStageView<Content: View>: View {
    let title: String
    let systemImage: String
    let accent: Color
    let subtitle: String
    let trailingMeta: String
    let isFocused: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    Circle()
                        .fill(accent.opacity(isFocused ? 0.15 : 0.085))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: systemImage)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(accent)
                        }

                    Rectangle()
                        .fill(.primary.opacity(0.055))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.headline.weight(.semibold))
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Text(trailingMeta)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isFocused ? accent : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        content
                    }
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(isFocused ? accent.opacity(0.22) : .primary.opacity(0.055))
                            .frame(width: 2)
                            .padding(.vertical, 6)
                    }
                    .padding(.leading, 12)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? accent.opacity(0.16) : Color.primary.opacity(0.045), lineWidth: 1)
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.primary.opacity(0.012)))
        )
    }
}

private struct WorkflowStepSummaryRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    var isSelected: Bool = false
    var badge: String? = nil
    let action: () -> Void
    var onDelete: (() -> Void)? = nil
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let badge, !badge.isEmpty {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.10), in: Capsule())
            }

            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove block")
                .opacity(isHovering || isSelected ? 1 : 0)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(accent.opacity(0.075)) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? accent.opacity(0.14) : .clear, lineWidth: 1)
        )
        .onTapGesture(perform: action)
        .contextMenu {
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Remove Block", systemImage: "trash")
                }
            }
        }
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.14)) {
                isHovering = hovering
            }
        }
    }
}

private struct WorkflowStagePlaceholder: View {
    let title: String
    let subtitle: String
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.dotted")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct WorkflowInsertionLane: View {
    let title: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(.primary.opacity(0.07))
                .frame(height: 1)
            Button(action: action) {
                Label(title, systemImage: "plus")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                .background(accent.opacity(0.065), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(accent.opacity(0.10), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            Rectangle()
                .fill(.primary.opacity(0.07))
                .frame(height: 1)
        }
        .padding(.leading, 47)
    }
}

private struct InspectorSelectionContextView: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent.opacity(0.88))
                .frame(width: 24, height: 24)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("Editing in Inspector")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.026))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct RuleInspectorOverview: View {
    let issues: [ValidationIssue]
    let availableVariables: [ContextVariable]
    let hasTrigger: Bool
    let previewMessage: String?
    let onShowBlocks: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSection(title: "Workflow") {
                Text("Select a stage in the canvas to edit its configuration here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(action: onShowBlocks) {
                    Label("Open Blocks", systemImage: "square.stack.3d.up.fill")
                }
                .buttonStyle(.bordered)
            }

            InspectorSection(title: "Validation") {
                if issues.isEmpty {
                    Label("No validation issues", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    ValidationBannerView(issues: issues)
                }
            }

            InspectorSection(title: "Variables") {
                if hasTrigger && !availableVariables.isEmpty {
                    ForEach(availableVariables, id: \.self) { variable in
                        HStack {
                            Text(variable.rawValue)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(variable.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Choose a trigger to unlock context variables for later stages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let previewMessage, !previewMessage.isEmpty {
                InspectorSection(title: "Preview") {
                    Text(previewMessage)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct TriggerInspectorView: View {
    let trigger: TriggerType?
    let triggerSummary: String
    let providedVariables: [ContextVariable]
    let onChangeTrigger: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSection(title: "Trigger") {
                HStack(spacing: 10) {
                    Image(systemName: trigger?.symbol ?? "bolt.badge.questionmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .frame(width: 28, height: 28)
                        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(trigger?.rawValue ?? "No trigger selected")
                            .font(.subheadline.weight(.semibold))
                        Text(triggerSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(action: onChangeTrigger) {
                    Label(trigger == nil ? "Choose Trigger" : "Change Trigger", systemImage: "square.stack.3d.up.fill")
                }
                .buttonStyle(.bordered)
            }

            InspectorSection(title: "Provided Variables") {
                if providedVariables.isEmpty {
                    Text("This trigger has not been chosen yet, so no workflow variables are available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(providedVariables, id: \.self) { variable in
                        HStack {
                            Text(variable.rawValue)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(variable.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.4)

            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.024))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

// MARK: - Validation Banner

struct EmptyRuleStateView: View {
    let icon: String
    let title: String
    let description: String
    var onShowMe: (() -> Void)?
    var onContinue: (() -> Void)?

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

// MARK: - Searchable ID Picker

struct SearchablePickerItem: Identifiable {
    let id: String
    let name: String
}

struct SearchableIDPicker: View {
    let title: String
    @Binding var selectionID: String
    let items: [SearchablePickerItem]
    let prompt: String

    @State private var showPopover = false
    @State private var searchText = ""

    private var filteredItems: [SearchablePickerItem] {
        if searchText.isEmpty {
            return items
        }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var selectedName: String {
        items.first { $0.id == selectionID }?.name ?? (selectionID.isEmpty ? prompt : selectionID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                showPopover = true
            } label: {
                HStack {
                    Text(selectedName)
                        .font(.subheadline)
                        .foregroundStyle(selectionID.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(.white.opacity(0.05))

                Divider()

                if filteredItems.isEmpty {
                    Text("No results found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(filteredItems) { (item: SearchablePickerItem) in
                                Button {
                                    selectionID = item.id
                                    showPopover = false
                                } label: {
                                    HStack {
                                        Text(item.name)
                                            .font(.subheadline)
                                        Spacer()
                                        if selectionID == item.id {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(minWidth: 220, maxHeight: 300)
                }
            }
        }
    }
}

// MARK: - Guided Build Step

enum GuidedBuildStep {
    case none, trigger, action
}
