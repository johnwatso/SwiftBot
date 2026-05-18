import SwiftUI

/// Sheet-style editor for one Automations.Rule. Mirrors the visual pattern
/// of `SweepPolicyEditor` from SweepView.swift: hero header, form sections
/// in `.thinMaterial`, footer bar with Cancel/Save.
struct AutomationRuleEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var rule: Automations.Rule
    let isNew: Bool
    let serverContext: AutomationDrafter.ServerContext
    let onSave: (Automations.Rule) -> Void
    let onDelete: (String) -> Void

    init(
        rule: Automations.Rule,
        isNew: Bool,
        serverContext: AutomationDrafter.ServerContext,
        onSave: @escaping (Automations.Rule) -> Void,
        onDelete: @escaping (String) -> Void
    ) {
        self._rule = State(initialValue: rule)
        self.isNew = isNew
        self.serverContext = serverContext
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AutomationFormSection(title: "Name", symbol: "tag") {
                        formRow(label: "Name") {
                            TextField("Welcome new members", text: $rule.name)
                                .textFieldStyle(.roundedBorder)
                        }
                        formRow(label: "Enabled") {
                            Toggle("", isOn: $rule.enabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                            Spacer()
                        }
                    }

                    AutomationFormSection(title: "WHEN this happens", symbol: "bolt.fill") {
                        triggerEditor
                    }

                    AutomationFormSection(title: "IF these conditions match", symbol: "line.3.horizontal.decrease.circle") {
                        filtersEditor
                    }

                    AutomationFormSection(title: "THEN do these steps", symbol: "arrow.triangle.branch") {
                        stepsEditor
                    }

                    if !isNew {
                        Button(role: .destructive) {
                            onDelete(rule.id)
                            dismiss()
                        } label: {
                            Label("Delete rule", systemImage: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }

            footerBar
        }
    }

    // MARK: - Hero header

    private var heroHeader: some View {
        let isModeration = rule.category == .moderation
        let icon = isModeration ? "shield.lefthalf.filled" : "bolt.badge.automatic.fill"
        let noun = isModeration ? "Moderation Rule" : "Automation"
        let subtitle = isModeration
            ? "Pick a trigger, then add conditions and steps that block or punish bad behaviour."
            : "Pick a trigger, then add steps that run when it fires."
        let tint: Color = isModeration ? .red : .accentColor

        return HStack(alignment: .center, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(Circle().fill(tint.opacity(0.14)))
                .overlay(Circle().stroke(tint.opacity(0.18), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                Text(isNew ? "New \(noun)" : "Edit \(noun)")
                    .font(.title2.weight(.bold))
                Text(isNew ? subtitle : rule.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    // MARK: - Footer bar

    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.45)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button {
                    onSave(rule)
                    dismiss()
                } label: {
                    Text(isNew ? "Create" : "Save")
                        .frame(minWidth: 86)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isReady)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(.thinMaterial)
    }

    private var isReady: Bool {
        !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rule.steps.isEmpty
    }

    // MARK: - Trigger editor

    private var triggerEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            formRow(label: "When") {
                Picker("", selection: $rule.trigger.kind) {
                    ForEach(Automations.TriggerKind.allCases, id: \.self) { kind in
                        Text(AutomationLabels.trigger(kind)).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            // Slash command name lives on the trigger itself (it defines
            // *which* slash command fires this rule; not a filter).
            if rule.trigger.kind == .slashCommand {
                stringRow(label: "Command", value: $rule.trigger.commandName, placeholder: "report")
            }
        }
    }

    // MARK: - Filters editor

    private var filtersEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if rule.filters.isEmpty {
                Text("No conditions — this rule fires every time the trigger happens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Logic toggle only matters when there's >1 filter.
                if rule.filters.count > 1 {
                    formRow(label: "Match") {
                        Picker("", selection: $rule.filterLogic) {
                            Text("All of these (AND)").tag(Automations.FilterLogic.all)
                            Text("Any of these (OR)").tag(Automations.FilterLogic.any)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320, alignment: .leading)
                        Spacer()
                    }
                }

                ForEach(Array(rule.filters.enumerated()), id: \.element.id) { idx, _ in
                    filterCard(index: idx)
                }
            }

            Menu {
                ForEach(filterMenuOrder(for: rule.trigger.kind), id: \.self) { kind in
                    Button(filterAddLabel(kind)) {
                        rule.filters.append(blankFilter(for: kind))
                    }
                }
            } label: {
                Label("Add condition", systemImage: "plus.circle")
                    .font(.subheadline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func filterCard(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: filterIcon(rule.filters[index].kind))
                    .foregroundStyle(.tint)
                    .font(.subheadline)
                Text(filterTitle(rule.filters[index].kind))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    rule.filters.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove condition")
            }

            filterFields(index: index)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func filterFields(index: Int) -> some View {
        let kind = rule.filters[index].kind
        switch kind {
        case .inChannel:
            multiChannelRow(label: "Channels", ids: $rule.filters[index].channelIds,
                            voiceOnly: triggerIsVoice)

        case .directMessage:
            formRow(label: "Where") {
                Picker("", selection: Binding(
                    get: { rule.filters[index].boolValue ?? true },
                    set: { rule.filters[index].boolValue = $0 }
                )) {
                    Text("DMs only").tag(true)
                    Text("Channels only").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
                Spacer()
            }

        case .userIsOneOf:
            // Editing user-ID lists by hand isn't a great UX; in practice
            // we expect a future user-picker. For now, allow paste of
            // comma-separated IDs.
            stringRow(
                label: "User IDs",
                value: stringListBinding(for: $rule.filters[index].userIds),
                placeholder: "comma-separated IDs"
            )

        case .userHasAnyRole, .userHasAllRoles, .userHasNoneOfRoles:
            multiRoleRow(label: "Roles", ids: $rule.filters[index].roleIds)
            Text("Role membership checks aren't fully wired up yet — they currently always pass.")
                .font(.caption2)
                .foregroundStyle(.orange)

        case .messageContains, .messageEquals, .messageDoesNotContain, .messageMatchesRegex:
            stringRow(
                label: "Text",
                value: $rule.filters[index].text,
                placeholder: kind == .messageMatchesRegex ? "regex" : "text"
            )

        case .messageContainsAny:
            stringRow(
                label: "Any of",
                value: stringListBinding(for: $rule.filters[index].textValues),
                placeholder: "comma-separated phrases"
            )

        case .messageIsReply:
            formRow(label: "Reply") {
                Picker("", selection: Binding(
                    get: { rule.filters[index].boolValue ?? true },
                    set: { rule.filters[index].boolValue = $0 }
                )) {
                    Text("Is a reply").tag(true)
                    Text("Is not a reply").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
                Spacer()
            }

        case .fromBot:
            formRow(label: "Author") {
                Picker("", selection: Binding(
                    get: { rule.filters[index].boolValue ?? false },
                    set: { rule.filters[index].boolValue = $0 }
                )) {
                    Text("From a bot").tag(true)
                    Text("From a person").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
                Spacer()
            }

        case .minVoiceDurationSeconds:
            intRow(label: "Minimum (s)", value: $rule.filters[index].intValue)

        case .reactionEmoji:
            stringRow(label: "Emoji", value: $rule.filters[index].text, placeholder: "👀 or :name:")

        case .mediaSource:
            stringRow(label: "Source", value: $rule.filters[index].text, placeholder: "Local")
        }
    }

    private var triggerIsVoice: Bool {
        switch rule.trigger.kind {
        case .userJoinedVoice, .userLeftVoice, .userMovedVoice: return true
        default: return false
        }
    }

    /// Comma-separated text ↔ String array binding for list-style filters.
    private func stringListBinding(for source: Binding<[String]?>) -> Binding<String?> {
        Binding(
            get: { (source.wrappedValue ?? []).joined(separator: ", ") },
            set: { newValue in
                let trimmed = newValue?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty } ?? []
                source.wrappedValue = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    // MARK: - Filter metadata

    private func filterMenuOrder(for kind: Automations.TriggerKind) -> [Automations.FilterKind] {
        switch kind {
        case .messageCreated:
            return [.inChannel, .directMessage, .messageContains, .messageContainsAny,
                    .messageEquals, .messageDoesNotContain, .messageMatchesRegex,
                    .messageIsReply, .fromBot, .userIsOneOf,
                    .userHasAnyRole, .userHasAllRoles, .userHasNoneOfRoles]
        case .userJoinedVoice, .userLeftVoice, .userMovedVoice:
            return [.inChannel, .minVoiceDurationSeconds, .userIsOneOf,
                    .userHasAnyRole, .userHasAllRoles, .userHasNoneOfRoles]
        case .memberJoined, .memberLeft:
            return [.userIsOneOf]
        case .reactionAdded:
            return [.inChannel, .reactionEmoji, .userHasAnyRole, .userHasNoneOfRoles]
        case .slashCommand:
            return [.inChannel, .userIsOneOf, .userHasAnyRole]
        case .mediaAdded:
            return [.mediaSource]
        }
    }

    private func filterAddLabel(_ kind: Automations.FilterKind) -> String {
        switch kind {
        case .inChannel:                return "In a channel"
        case .directMessage:            return "Where (DM vs channel)"
        case .userIsOneOf:              return "User is one of"
        case .userHasAnyRole:           return "User has any of these roles"
        case .userHasAllRoles:          return "User has all of these roles"
        case .userHasNoneOfRoles:       return "User has none of these roles"
        case .messageContains:          return "Message contains"
        case .messageContainsAny:       return "Message contains any of"
        case .messageEquals:            return "Message is exactly"
        case .messageDoesNotContain:    return "Message does NOT contain"
        case .messageMatchesRegex:      return "Message matches regex"
        case .messageIsReply:           return "Message is a reply"
        case .fromBot:                  return "Posted by bot / person"
        case .minVoiceDurationSeconds:  return "Voice duration ≥"
        case .reactionEmoji:            return "Reaction emoji"
        case .mediaSource:              return "Media source"
        }
    }

    private func filterTitle(_ kind: Automations.FilterKind) -> String {
        filterAddLabel(kind)
    }

    private func filterIcon(_ kind: Automations.FilterKind) -> String {
        switch kind {
        case .inChannel:                return "number"
        case .directMessage:            return "envelope"
        case .userIsOneOf:              return "person"
        case .userHasAnyRole,
             .userHasAllRoles,
             .userHasNoneOfRoles:       return "person.badge.shield.checkmark"
        case .messageContains,
             .messageContainsAny,
             .messageEquals,
             .messageDoesNotContain,
             .messageMatchesRegex:      return "text.magnifyingglass"
        case .messageIsReply:           return "arrowshape.turn.up.left"
        case .fromBot:                  return "person.crop.square"
        case .minVoiceDurationSeconds:  return "timer"
        case .reactionEmoji:            return "face.smiling"
        case .mediaSource:              return "music.note"
        }
    }

    private func blankFilter(for kind: Automations.FilterKind) -> Automations.Filter {
        switch kind {
        case .inChannel:                return Automations.Filter(kind: kind, channelIds: [])
        case .directMessage:            return Automations.Filter(kind: kind, boolValue: true)
        case .userIsOneOf:              return Automations.Filter(kind: kind, userIds: [])
        case .userHasAnyRole,
             .userHasAllRoles,
             .userHasNoneOfRoles:       return Automations.Filter(kind: kind, roleIds: [])
        case .messageContains,
             .messageEquals,
             .messageDoesNotContain,
             .messageMatchesRegex,
             .reactionEmoji,
             .mediaSource:              return Automations.Filter(kind: kind, text: "")
        case .messageContainsAny:       return Automations.Filter(kind: kind, textValues: [])
        case .messageIsReply:           return Automations.Filter(kind: kind, boolValue: true)
        case .fromBot:                  return Automations.Filter(kind: kind, boolValue: false)
        case .minVoiceDurationSeconds:  return Automations.Filter(kind: kind, intValue: 60)
        }
    }

    // MARK: - Steps editor

    private var stepsEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rule.steps.enumerated()), id: \.element.id) { idx, _ in
                stepCard(index: idx)
            }
            HStack {
                Button {
                    rule.steps.append(Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .replyToTrigger,
                        content: ""
                    ))
                } label: {
                    Label("Add step", systemImage: "plus.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func stepCard(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Step \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if rule.steps.count > 1 {
                    Button {
                        rule.steps.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove step")
                }
            }

            formRow(label: "Action") {
                Picker("", selection: $rule.steps[index].kind) {
                    ForEach(Automations.StepKind.allCases, id: \.self) { kind in
                        Text(AutomationLabels.stepKind(kind)).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            stepFields(index: index)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func stepFields(index: Int) -> some View {
        let step = rule.steps[index]
        switch step.kind {
        case .sendMessage:
            formRow(label: "Send to") {
                Picker("", selection: Binding(
                    get: { rule.steps[index].sendTarget ?? .replyToTrigger },
                    set: { rule.steps[index].sendTarget = $0 }
                )) {
                    Text("Reply").tag(Automations.SendTarget.replyToTrigger)
                    Text("Same channel").tag(Automations.SendTarget.sameChannel)
                    Text("DM the user").tag(Automations.SendTarget.directMessage)
                    Text("Specific channel").tag(Automations.SendTarget.specificChannel)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            if (rule.steps[index].sendTarget ?? .replyToTrigger) == .specificChannel {
                channelRow(label: "Channel", id: $rule.steps[index].channelId)
            }
            multilineRow(label: "Message", value: $rule.steps[index].content,
                         placeholder: "Hey {username}!")
            multilineRow(label: "AI prompt", value: $rule.steps[index].aiPrompt,
                         placeholder: "Optional — AI writes the message if set",
                         help: "When set, the AI generates the message body using this prompt. Leaves Message blank.")

        case .modifyMember:
            formRow(label: "Operation") {
                Picker("", selection: Binding(
                    get: { rule.steps[index].memberOp ?? .addRole },
                    set: { rule.steps[index].memberOp = $0 }
                )) {
                    ForEach(Automations.MemberOp.allCases, id: \.self) { op in
                        Text(AutomationLabels.memberOp(op)).tag(op)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            switch step.memberOp ?? .addRole {
            case .addRole, .removeRole:
                roleRow(label: "Role", id: $rule.steps[index].roleId)
            case .timeout:
                intRow(label: "Seconds", value: $rule.steps[index].timeoutSeconds)
            case .kick:
                stringRow(label: "Reason", value: $rule.steps[index].kickReason, placeholder: "(optional)")
            case .moveVoice:
                channelRow(label: "Voice channel", id: $rule.steps[index].targetVoiceChannelId, voiceOnly: true)
            }

        case .modifyMessage:
            formRow(label: "Operation") {
                Picker("", selection: Binding(
                    get: { rule.steps[index].messageOp ?? .delete },
                    set: { rule.steps[index].messageOp = $0 }
                )) {
                    Text("Delete the triggering message").tag(Automations.MessageOp.delete)
                    Text("React to the message").tag(Automations.MessageOp.react)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            if (step.messageOp ?? .delete) == .react {
                stringRow(label: "Emoji", value: $rule.steps[index].reactEmoji, placeholder: "👀")
            }

        case .log:
            multilineRow(label: "Log text", value: $rule.steps[index].logText,
                         placeholder: "{username} did something")

        case .webhook:
            stringRow(label: "URL", value: $rule.steps[index].webhookUrl, placeholder: "https://…")
            multilineRow(label: "Body", value: $rule.steps[index].webhookContent, placeholder: "{message}")

        case .delay:
            intRow(label: "Seconds", value: $rule.steps[index].delaySeconds)
        }
    }

    // MARK: - Form rows (match Sweep's pattern)

    @ViewBuilder
    private func formRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            content()
        }
    }

    @ViewBuilder
    private func stringRow(label: String, value: Binding<String?>, placeholder: String) -> some View {
        formRow(label: label) {
            TextField(placeholder, text: Binding(
                get: { value.wrappedValue ?? "" },
                set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func multilineRow(label: String, value: Binding<String?>,
                              placeholder: String, help: String? = nil,
                              variablesEnabled: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let help {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(help)
                }
            }
            .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                TextField(placeholder, text: Binding(
                    get: { value.wrappedValue ?? "" },
                    set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)

                if variablesEnabled {
                    variablePickerMenu(value: value)
                }
            }
        }
    }

    /// "Insert variable" menu — populates whatever variables the current
    /// trigger actually produces. Tapping appends `{token}` to the field.
    @ViewBuilder
    private func variablePickerMenu(value: Binding<String?>) -> some View {
        let applicable = Automations.Variable.allCases.filter { $0.appliesTo(rule.trigger.kind) }
        Menu {
            ForEach(applicable, id: \.self) { v in
                Button {
                    let current = value.wrappedValue ?? ""
                    let needsSpace = !current.isEmpty && !current.hasSuffix(" ")
                    value.wrappedValue = current + (needsSpace ? " " : "") + v.rawValue
                } label: {
                    HStack {
                        Text(v.label)
                        Spacer()
                        Text(v.rawValue)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            Label("Insert variable", systemImage: "curlybraces")
                .font(.caption)
                .foregroundStyle(.tint)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func intRow(label: String, value: Binding<Int?>) -> some View {
        formRow(label: label) {
            TextField("", value: Binding(
                get: { value.wrappedValue ?? 0 },
                set: { value.wrappedValue = $0 > 0 ? $0 : nil }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 120, alignment: .leading)
            Spacer()
        }
    }

    @ViewBuilder
    private func tristateRow(label: String, value: Binding<Bool?>,
                             trueLabel: String, falseLabel: String, noneLabel: String) -> some View {
        formRow(label: label) {
            Picker("", selection: Binding<Int>(
                get: {
                    if value.wrappedValue == true { return 1 }
                    if value.wrappedValue == false { return 2 }
                    return 0
                },
                set: {
                    switch $0 {
                    case 1: value.wrappedValue = true
                    case 2: value.wrappedValue = false
                    default: value.wrappedValue = nil
                    }
                }
            )) {
                Text(noneLabel).tag(0)
                Text(trueLabel).tag(1)
                Text(falseLabel).tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private func channelRow(label: String, id: Binding<String?>, voiceOnly: Bool = false) -> some View {
        let pool = voiceOnly ? serverContext.voiceChannels : serverContext.textChannels
        formRow(label: label) {
            Picker("", selection: Binding(
                get: { id.wrappedValue ?? "" },
                set: { id.wrappedValue = $0.isEmpty ? nil : $0 }
            )) {
                Text("Any").tag("")
                ForEach(pool, id: \.id) { c in
                    Text(voiceOnly ? c.name : "#\(c.name)").tag(c.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    /// Multi-select channel chips. `voiceOnly` filters to voice channels.
    @ViewBuilder
    private func multiChannelRow(label: String, ids: Binding<[String]?>, voiceOnly: Bool) -> some View {
        let pool = voiceOnly ? serverContext.voiceChannels : serverContext.textChannels
        let selected = Set(ids.wrappedValue ?? [])
        formRow(label: label) {
            Menu {
                ForEach(pool, id: \.id) { c in
                    Button {
                        toggleSelection(c.id, in: ids)
                    } label: {
                        HStack {
                            if selected.contains(c.id) {
                                Image(systemName: "checkmark")
                            }
                            Text(voiceOnly ? c.name : "#\(c.name)")
                        }
                    }
                }
            } label: {
                if selected.isEmpty {
                    Text("Pick channel(s)").foregroundStyle(.secondary)
                } else {
                    Text(pool
                        .filter { selected.contains($0.id) }
                        .map { voiceOnly ? $0.name : "#\($0.name)" }
                        .joined(separator: ", "))
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func multiRoleRow(label: String, ids: Binding<[String]?>) -> some View {
        let pool = serverContext.roles
        let selected = Set(ids.wrappedValue ?? [])
        formRow(label: label) {
            Menu {
                ForEach(pool, id: \.id) { r in
                    Button {
                        toggleSelection(r.id, in: ids)
                    } label: {
                        HStack {
                            if selected.contains(r.id) { Image(systemName: "checkmark") }
                            Text("@\(r.name)")
                        }
                    }
                }
            } label: {
                if selected.isEmpty {
                    Text("Pick role(s)").foregroundStyle(.secondary)
                } else {
                    Text(pool
                        .filter { selected.contains($0.id) }
                        .map { "@\($0.name)" }
                        .joined(separator: ", "))
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleSelection(_ id: String, in binding: Binding<[String]?>) {
        var current = binding.wrappedValue ?? []
        if let i = current.firstIndex(of: id) {
            current.remove(at: i)
        } else {
            current.append(id)
        }
        binding.wrappedValue = current.isEmpty ? nil : current
    }

    @ViewBuilder
    private func roleRow(label: String, id: Binding<String?>) -> some View {
        formRow(label: label) {
            Picker("", selection: Binding(
                get: { id.wrappedValue ?? "" },
                set: { id.wrappedValue = $0.isEmpty ? nil : $0 }
            )) {
                Text("(none)").tag("")
                ForEach(serverContext.roles, id: \.id) { r in
                    Text("@\(r.name)").tag(r.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}

// MARK: - Form section (matches SweepFormSection styling)

private struct AutomationFormSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.black.opacity(0.18), lineWidth: 1)
                .blendMode(.plusDarker)
        )
    }
}
