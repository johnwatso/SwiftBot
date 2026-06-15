import SwiftUI

/// The Automations tab. List of rules + NL drafting box. Editing happens
/// in a sheet (`AutomationRuleEditor`), styled after `SweepPolicyEditor`
/// from SweepView.swift — hero header, form sections in `.thinMaterial`,
/// footer bar with Cancel/Save.
struct AutomationsView: View {
    @EnvironmentObject private var app: AppModel

    let category: Automations.Category

    init(category: Automations.Category = .automation) {
        self.category = category
    }

    @State private var editingRule: AutomationEditTarget?
    @State private var draftPrompt: String = ""
    @State private var isDrafting: Bool = false
    @State private var draftError: String?

    private var rulesInCategory: [Automations.Rule] {
        app.automationStore.rules.filter { $0.category == category }
    }

    private var conflictFindingsInCategory: [AutomationConflictDetector.Finding] {
        let ruleIds = Set(rulesInCategory.map(\.id))
        return AutomationConflictDetector.findings(in: app.automationStore.rules)
            .filter { !Set($0.ruleIds).isDisjoint(with: ruleIds) }
    }

    private var copy: ViewCopy { ViewCopy.for(category) }

    private struct ViewCopy {
        let title: String
        let singularNoun: String     // "automation"
        let pluralNoun: String       // "automations"
        let metricTitle: String      // "Automations"
        let describePrompt: String   // header for the NL drafter
        let placeholderExample: String
        let listSection: String
        let emptyHint: String
        let addButton: String
        let headerIcon: String

        static func `for`(_ category: Automations.Category) -> ViewCopy {
            switch category {
            case .automation:
                return ViewCopy(
                    title: "Automations",
                    singularNoun: "automation",
                    pluralNoun: "automations",
                    metricTitle: "Automations",
                    describePrompt: "Describe a new automation",
                    placeholderExample: "e.g. When someone says they're tired, react with 😴",
                    listSection: "Rules",
                    emptyHint: "No automations yet. Describe one above, or click Add rule to build manually.",
                    addButton: "Add rule",
                    headerIcon: "bolt.badge.automatic.fill"
                )
            case .moderation:
                return ViewCopy(
                    title: "Moderation",
                    singularNoun: "moderation rule",
                    pluralNoun: "moderation rules",
                    metricTitle: "Moderation",
                    describePrompt: "Describe a new moderation rule",
                    placeholderExample: "e.g. Delete messages containing 'spam.com'",
                    listSection: "Moderation rules",
                    emptyHint: "No moderation rules yet. Describe one above, or click Add rule to build manually.",
                    addButton: "Add rule",
                    headerIcon: "shield.lefthalf.filled"
                )
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)

            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. \(copy.title) sync from Primary.")
                    .padding(.horizontal, 16)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    metricTileRow
                    naturalLanguageSection
                    templatesSection
                    rulesListSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 16)
            }
            .fadingEdges(top: 16, bottom: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(app.isFailoverManagedNode)
        .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        .onAppear {
            if !app.automationStore.isLoaded { app.automationStore.load() }
        }
        .sheet(item: $editingRule) { target in
            AutomationRuleEditor(
                rule: target.rule,
                isNew: target.isNew,
                allRules: app.automationStore.rules,
                serverContext: app.automationServerContext(),
                onSave: { updated in
                    app.automationStore.upsert(updated)
                },
                onDelete: { id in
                    app.automationStore.remove(id: id)
                }
            )
            .frame(minWidth: 640, idealWidth: 760, minHeight: 560, idealHeight: 700)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            ViewSectionHeader(title: copy.title, symbol: copy.headerIcon)
            Spacer()
            if !app.automationDrafter.isAvailable {
                Label("AI unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(app.automationDrafter.unavailabilityReason ?? "")
            }
        }
    }

    // MARK: - Metric tiles

    private var metricTileRow: some View {
        LazyVGrid(columns: DashboardMetricGrid.columns, spacing: DashboardMetricGrid.spacing) {
            ForEach(AutomationDashboardSummary.metrics(app: app, category: category)) { metric in
                DashboardMetricCard(metric: metric)
            }
        }
    }

    // MARK: - Natural language drafting

    private var naturalLanguageSection: some View {
        AutomationsSection(title: copy.describePrompt, symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    copy.placeholderExample,
                    text: $draftPrompt,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )

                HStack {
                    if let err = draftError {
                        Label(err, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        Task { await draft() }
                    } label: {
                        if isDrafting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Create with AI", systemImage: "wand.and.stars")
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isDrafting
                              || draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || !app.automationDrafter.isAvailable)
                }
            }
        }
    }

    private func draft() async {
        let prompt = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isDrafting = true
        draftError = nil
        defer { isDrafting = false }

        do {
            var rule = try await app.automationDrafter.draft(
                prompt: prompt,
                context: app.automationServerContext()
            )
            // Tag the rule with the current view's category so it lands in
            // the right tab, regardless of what the drafter picked.
            rule.category = category
            app.automationStore.upsert(rule)
            draftPrompt = ""
            // Open the editor on the freshly drafted rule so the user can tweak.
            editingRule = AutomationEditTarget(rule: rule, isNew: false)
        } catch {
            draftError = error.localizedDescription
        }
    }

    // MARK: - Templates

    private var templatesSection: some View {
        AutomationsSection(title: "Start from a template", symbol: "square.grid.2x2") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(AutomationTemplate.catalog(for: category)) { tpl in
                        templateCard(tpl)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func templateCard(_ tpl: AutomationTemplate) -> some View {
        Button {
            // Clone with fresh IDs so each instance is independent.
            var rule = tpl.rule
            rule.id = UUID().uuidString
            rule.category = category
            rule.steps = rule.steps.map { step in
                var s = step
                s.id = UUID().uuidString
                return s
            }
            editingRule = AutomationEditTarget(rule: rule, isNew: true)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: tpl.symbol)
                    .font(.title3.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(templateColor(tpl.tint))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(templateColor(tpl.tint).opacity(0.14)))

                Text(tpl.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(tpl.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(width: 210, height: 150, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func templateColor(_ tint: AutomationTemplate.TemplateTint) -> Color {
        switch tint {
        case .blue:    return .blue
        case .green:   return .green
        case .purple:  return .purple
        case .orange:  return .orange
        case .red:     return .red
        case .indigo:  return .indigo
        }
    }

    // MARK: - Rules list

    private var rulesListSection: some View {
        AutomationsSection(title: copy.listSection, symbol: "list.bullet") {
            VStack(spacing: 6) {
                if !conflictFindingsInCategory.isEmpty {
                    conflictSummary(findings: conflictFindingsInCategory)
                        .padding(.bottom, 4)
                }
                if rulesInCategory.isEmpty {
                    Text(copy.emptyHint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ForEach(rulesInCategory) { rule in
                        ruleRow(rule)
                    }
                }
                Divider().padding(.vertical, 2)
                HStack {
                    Button {
                        addBlankRule()
                    } label: {
                        Label(copy.addButton, systemImage: "plus.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
    }

    private func ruleRow(_ rule: Automations.Rule) -> some View {
        let findings = AutomationConflictDetector.findings(for: rule, in: app.automationStore.rules)
        return HStack(spacing: 10) {
            Circle()
                .fill(rule.enabled ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Image(systemName: ruleSymbol(rule))
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ruleTint(rule))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name.isEmpty ? "Untitled" : rule.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(ruleSubtitle(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !findings.isEmpty {
                Label("\(findings.count)", systemImage: conflictIcon(for: findings))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(conflictColor(for: findings))
                    .labelStyle(.iconOnly)
                    .help(findings.map(\.title).joined(separator: "\n"))
            }
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in app.automationStore.toggleEnabled(id: rule.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            Button {
                editingRule = AutomationEditTarget(rule: rule, isNew: false)
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            editingRule = AutomationEditTarget(rule: rule, isNew: false)
        }
        .contextMenu {
            Button(rule.enabled ? "Disable" : "Enable") {
                app.automationStore.toggleEnabled(id: rule.id)
            }
            Button("Delete", role: .destructive) {
                app.automationStore.remove(id: rule.id)
            }
        }
    }

    private func conflictSummary(findings: [AutomationConflictDetector.Finding]) -> some View {
        let warnings = findings.filter { $0.severity == .warning }.count
        let title = warnings > 0 ? "\(warnings) conflict warning\(warnings == 1 ? "" : "s")" : "\(findings.count) overlap note\(findings.count == 1 ? "" : "s")"
        let detail = findings.first?.title ?? "Review overlapping rules"

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: warnings > 0 ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(warnings > 0 ? .orange : .blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((warnings > 0 ? Color.orange : Color.blue).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke((warnings > 0 ? Color.orange : Color.blue).opacity(0.18), lineWidth: 1)
        )
    }

    private func conflictIcon(for findings: [AutomationConflictDetector.Finding]) -> String {
        findings.contains { $0.severity == .warning } ? "exclamationmark.triangle.fill" : "info.circle.fill"
    }

    private func conflictColor(for findings: [AutomationConflictDetector.Finding]) -> Color {
        findings.contains { $0.severity == .warning } ? .orange : .blue
    }

    // MARK: - Mutations

    private func addBlankRule() {
        let defaultName = category == .moderation ? "New moderation rule" : "New automation"
        let rule = Automations.Rule(
            name: defaultName,
            category: category,
            trigger: Automations.Trigger(kind: .messageCreated),
            steps: [
                category == .moderation
                    ? Automations.Step(kind: .modifyMessage, messageOp: .delete)
                    : Automations.Step(kind: .sendMessage, sendTarget: .replyToTrigger, content: "")
            ]
        )
        editingRule = AutomationEditTarget(rule: rule, isNew: true)
    }

    // MARK: - Display helpers

    private func ruleSubtitle(_ rule: Automations.Rule) -> String {
        let t = AutomationLabels.trigger(rule.trigger.kind)
        let s = rule.steps.first.map { AutomationLabels.stepKind($0.kind) } ?? "—"
        return "\(t) → \(s)"
    }

    private func ruleSymbol(_ rule: Automations.Rule) -> String {
        if rule.category == .moderation {
            if rule.steps.contains(where: { $0.kind == .modifyMember }) {
                return "person.fill.xmark"
            }
            if rule.steps.contains(where: { $0.kind == .modifyMessage }) {
                return "text.badge.xmark"
            }
            if rule.steps.contains(where: { $0.kind == .log }) {
                return "list.clipboard"
            }
            return "shield.lefthalf.filled"
        }

        switch rule.trigger.kind {
        case .userJoinedVoice: return "speaker.wave.2.fill"
        case .userLeftVoice:   return "speaker.slash.fill"
        case .userMovedVoice:  return "arrow.triangle.swap"
        case .messageCreated:
            if rule.steps.contains(where: { $0.kind == .modifyMessage }) {
                return "face.smiling"
            }
            return "text.bubble.fill"
        case .memberJoined:    return "person.crop.circle.badge.plus"
        case .memberLeft:      return "door.left.hand.open"
        case .reactionAdded:   return "face.smiling"
        case .slashCommand:    return "terminal.fill"
        case .mediaAdded:      return "movieclapper.fill"
        }
    }

    private func ruleTint(_ rule: Automations.Rule) -> Color {
        guard rule.enabled else { return .secondary }
        if rule.category == .moderation {
            return rule.steps.contains(where: { $0.kind == .log }) ? .orange : .red
        }

        switch rule.trigger.kind {
        case .userJoinedVoice: return .green
        case .userLeftVoice:   return .orange
        case .userMovedVoice:  return .indigo
        case .messageCreated:  return .blue
        case .memberJoined:    return .green
        case .memberLeft:      return .orange
        case .reactionAdded:   return .blue
        case .slashCommand:    return .purple
        case .mediaAdded:      return .indigo
        }
    }
}

// MARK: - Sheet identity wrapper

struct AutomationEditTarget: Identifiable {
    let id: String
    let rule: Automations.Rule
    let isNew: Bool

    init(rule: Automations.Rule, isNew: Bool) {
        self.id = rule.id
        self.rule = rule
        self.isNew = isNew
    }
}

// MARK: - Section wrapper (matches SwiftMeshSection styling)

struct AutomationsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline.weight(.semibold))
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.03), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Labels

enum AutomationLabels {
    static func trigger(_ kind: Automations.TriggerKind) -> String {
        switch kind {
        case .userJoinedVoice: return "Someone joins voice"
        case .userLeftVoice:   return "Someone leaves voice"
        case .userMovedVoice:  return "Someone switches voice channels"
        case .messageCreated:  return "A message is posted"
        case .memberJoined:    return "A member joins the server"
        case .memberLeft:      return "A member leaves the server"
        case .reactionAdded:   return "Someone reacts"
        case .slashCommand:    return "A slash command runs"
        case .mediaAdded:      return "Media is added"
        }
    }

    static func stepKind(_ kind: Automations.StepKind) -> String {
        switch kind {
        case .sendMessage:   return "Send a message"
        case .modifyMember:  return "Member action"
        case .modifyMessage: return "Message action"
        case .log:           return "Write to the log"
        case .webhook:       return "Call a webhook"
        case .delay:         return "Wait"
        case .aiTransform:   return "AI transform"
        }
    }

    static func memberOp(_ op: Automations.MemberOp) -> String {
        switch op {
        case .addRole:    return "Add role to user"
        case .removeRole: return "Remove role from user"
        case .timeout:    return "Timeout user"
        case .kick:       return "Kick user"
        case .moveVoice:  return "Move voice user"
        }
    }
}

enum AutomationDashboardSummary {
    @MainActor
    static func metrics(app: AppModel, category: Automations.Category) -> [DashboardMetricDescriptor] {
        let rules = app.automationStore.rules.filter { $0.category == category }
        let enabledCount = rules.filter(\.enabled).count
        let triggerKindCount = Set(rules.map(\.trigger.kind)).count
        let isModeration = category == .moderation
        let title = isModeration ? "Moderation" : "Automations"
        let symbol = isModeration ? "shield.lefthalf.filled" : "bolt.badge.automatic.fill"
        let idPrefix = isModeration ? "moderation" : "actions"

        var metrics = [
            DashboardMetricDescriptor(
                id: idPrefix,
                title: title,
                value: "\(rules.count)",
                subtitle: rules.isEmpty ? "None yet" : "\(rules.count == 1 ? "1 rule" : "\(rules.count) rules")",
                symbol: symbol,
                color: isModeration ? .red : .accentColor
            ),
            DashboardMetricDescriptor(
                id: "\(idPrefix)-enabled",
                title: "Enabled",
                value: "\(enabledCount)",
                subtitle: rules.isEmpty ? "-" : "\(rules.count - enabledCount) disabled",
                symbol: "checkmark.circle.fill",
                color: enabledCount > 0 ? .green : .gray
            ),
            DashboardMetricDescriptor(
                id: "\(idPrefix)-triggers",
                title: "Trigger Types",
                value: "\(triggerKindCount)",
                subtitle: triggerKindCount == 0 ? "-" : "across all rules",
                symbol: "bolt.fill",
                color: .blue
            )
        ]

        metrics.append(AppleIntelligenceDashboardSummary.appleIntelligenceMetric(app: app, id: "\(idPrefix)-apple-intelligence"))
        return metrics
    }
}
