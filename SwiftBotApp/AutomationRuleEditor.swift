import SwiftUI

/// Sheet-style editor for one Automations.Rule. Mirrors the visual pattern
/// of `SweepPolicyEditor` from SweepView.swift: hero header, form sections
/// in `.thinMaterial`, footer bar with Cancel/Save.
struct AutomationRuleEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var rule: Automations.Rule
    @State private var aiPromptHelpStepID: String?
    @State private var testMessageContent: String = "Hello world!"
    @State private var testVoiceDuration: Int = 300
    @State private var testChannelId: String = "chan-123"
    @State private var testUsername: String = "john_doe"
    @State private var simulationResult: Automations.SimulationResult? = nil
    @State private var isShowingSimulation: Bool = false
    @State private var isSimulatorExpanded: Bool = false
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

        // Intelligently extract defaults from trigger and filters
        var defaultChannelId = "chan-123"
        if let tc = rule.trigger.channelId, !tc.isEmpty {
            defaultChannelId = tc
        } else if let inChanFilter = rule.filters.first(where: { $0.kind == .inChannel }),
                  let firstChan = inChanFilter.channelIds?.first, !firstChan.isEmpty {
            defaultChannelId = firstChan
        }
        self._testChannelId = State(initialValue: defaultChannelId)

        var defaultVoiceDuration = 300
        if let threshold = rule.trigger.voiceDurationThreshold {
            defaultVoiceDuration = threshold
        } else if let durationFilter = rule.filters.first(where: { $0.kind == .minVoiceDurationSeconds }),
                  let minSeconds = durationFilter.intValue {
            defaultVoiceDuration = minSeconds
        }
        self._testVoiceDuration = State(initialValue: defaultVoiceDuration)

        var defaultMessageContent = "Hello world!"
        if rule.filters.contains(where: { $0.kind == .messageContainsSpamLink }) {
            defaultMessageContent = "FREE-DISCORD-NITRO PHISHING LINK HERE: HTTPS://GIFT-NITRO.COM"
        } else if rule.filters.contains(where: { $0.kind == .messageCapsPercentage }) {
            defaultMessageContent = "HELLO WORLD THIS IS A LOUD SHOUTING MESSAGE"
        } else if let mentionsFilter = rule.filters.first(where: { $0.kind == .messageMentionsCount }) {
            let count = mentionsFilter.intValue ?? 5
            var mentionsList: [String] = []
            for i in 1...max(1, count + 1) {
                mentionsList.append("<@user\(i)>")
            }
            defaultMessageContent = mentionsList.joined(separator: " ") + " wake up!"
        } else if let equalsFilter = rule.filters.first(where: { $0.kind == .messageEquals }),
                  let t = equalsFilter.text, !t.isEmpty {
            defaultMessageContent = t
        } else if let containsFilter = rule.filters.first(where: { $0.kind == .messageContains }),
                  let t = containsFilter.text, !t.isEmpty {
            defaultMessageContent = t
        } else if let containsAnyFilter = rule.filters.first(where: { $0.kind == .messageContainsAny }),
                  let t = containsAnyFilter.textValues?.first, !t.isEmpty {
            defaultMessageContent = t
        } else if let regexFilter = rule.filters.first(where: { $0.kind == .messageMatchesRegex }),
                  let t = regexFilter.text, !t.isEmpty {
            defaultMessageContent = "Sample matching string for regex: \(t)"
        }
        self._testMessageContent = State(initialValue: defaultMessageContent)

        self._testUsername = State(initialValue: "john_doe")
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

                    AutomationFormSection(title: "Rule Simulator (Dry Run)", symbol: "play.circle.fill") {
                        DisclosureGroup(isExpanded: $isSimulatorExpanded) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Configure test event parameters to simulate your rule:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                stringRow(label: "Username", value: Binding(
                                    get: { testUsername },
                                    set: { testUsername = $0 ?? "john_doe" }
                                ), placeholder: "john_doe")
                                
                                stringRow(label: "Channel ID", value: Binding(
                                    get: { testChannelId },
                                    set: { testChannelId = $0 ?? "chan-123" }
                                ), placeholder: "chan-123")
                                
                                if rule.trigger.kind == .userLeftVoice || rule.trigger.kind == .userMovedVoice {
                                    intRow(label: "Duration (s)", value: Binding(
                                        get: { testVoiceDuration },
                                        set: { testVoiceDuration = $0 ?? 300 }
                                    ))
                                } else {
                                    multilineRow(label: "Message Content", value: Binding(
                                        get: { testMessageContent },
                                        set: { testMessageContent = $0 ?? "" }
                                    ), placeholder: "Enter sample message content here...")
                                }
                                
                                HStack(spacing: 8) {
                                    Button(action: runDryRun) {
                                        Label("Simulate", systemImage: "play.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.large)
                                    .tint(.green)
                                    
                                    Button(action: autofillFromRule) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .help("Autofill parameters from rule conditions")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                }
                                .padding(.top, 6)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text(isSimulatorExpanded ? "Click to collapse" : "Click to expand and configure parameters")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
        .sheet(isPresented: $isShowingSimulation) {
            if let res = simulationResult {
                AutomationSimulationResultView(ruleName: rule.name, result: res)
            }
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
            && allRequiredChannelsSet
    }

    /// Steps that target a specific channel must have one chosen before the
    /// rule can be saved — the channel picker no longer auto-fills a default.
    private var allRequiredChannelsSet: Bool {
        for step in rule.steps {
            switch step.kind {
            case .sendMessage:
                if (step.sendTarget ?? .replyToTrigger) == .specificChannel,
                   (step.channelId ?? "").isEmpty {
                    return false
                }
            case .modifyMember:
                if (step.memberOp ?? .addRole) == .moveVoice,
                   (step.targetVoiceChannelId ?? "").isEmpty {
                    return false
                }
            default:
                break
            }
        }
        return true
    }

    // MARK: - Trigger editor

    private var triggerEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            formRow(label: "When") {
                Picker("", selection: $rule.trigger.kind) {
                    ForEach(Automations.TriggerKind.visibleCases(for: rule.category), id: \.self) { kind in
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

        case .messageContainsSpamLink:
            formRow(label: "Filter") {
                Text("Scans message content for common web links and spam keywords.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .messageCapsPercentage:
            intRow(label: "Caps Threshold (%)", value: $rule.filters[index].intValue)

        case .messageMentionsCount:
            intRow(label: "Max Mentions", value: $rule.filters[index].intValue)
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
            var list: [Automations.FilterKind] = [
                .inChannel, .directMessage, .messageContains, .messageContainsAny,
                .messageEquals, .messageDoesNotContain, .messageMatchesRegex,
                .messageIsReply, .fromBot, .userIsOneOf,
                .userHasAnyRole, .userHasAllRoles, .userHasNoneOfRoles
            ]
            if rule.category == .moderation {
                list.append(contentsOf: [.messageContainsSpamLink, .messageCapsPercentage, .messageMentionsCount])
            }
            return list
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
        case .messageContainsSpamLink:  return "Spam Link Filter"
        case .messageCapsPercentage:   return "Caps/SHOUT Filter"
        case .messageMentionsCount:    return "Mass Ping Filter"
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
        case .messageContainsSpamLink:  return "link.badge.plus"
        case .messageCapsPercentage:   return "textformat.size"
        case .messageMentionsCount:    return "at"
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
        case .messageContainsSpamLink:  return Automations.Filter(kind: kind)
        case .messageCapsPercentage:   return Automations.Filter(kind: kind, intValue: 70)
        case .messageMentionsCount:    return Automations.Filter(kind: kind, intValue: 5)
        }
    }

    // MARK: - Steps editor

    private var stepsEditor: some View {
        let pipelineColor: Color = Color.accentColor
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(rule.steps.enumerated()), id: \.element.id) { idx, _ in
                stepCard(index: idx)
            }
            
            // Add step button picker
            Menu {
                ForEach(stepPresets(for: rule.category), id: \.id) { preset in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            rule.steps.append(preset.step)
                        }
                    } label: {
                        Label(preset.title, systemImage: preset.symbol)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Add step")
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(pipelineColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(pipelineColor.opacity(0.08))
                )
            }
            .menuStyle(.borderlessButton)
            .padding(.top, 4)
        }
    }

    private struct StepPreset: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let step: Automations.Step
    }

    private func stepPresets(for category: Automations.Category) -> [StepPreset] {
        switch category {
        case .automation:
            return [
                StepPreset(
                    id: "send-message",
                    title: "Send message",
                    symbol: "text.bubble",
                    step: Automations.Step(kind: .sendMessage, sendTarget: .replyToTrigger, content: "")
                ),
                StepPreset(
                    id: "wait",
                    title: "Wait",
                    symbol: "clock",
                    step: Automations.Step(kind: .delay, delaySeconds: 10)
                ),
                StepPreset(
                    id: "write-log",
                    title: "Write to log",
                    symbol: "list.clipboard",
                    step: Automations.Step(kind: .log, logText: "{username} triggered {guildName}")
                ),
                StepPreset(
                    id: "call-webhook",
                    title: "Call webhook",
                    symbol: "network",
                    step: Automations.Step(kind: .webhook, webhookUrl: "", webhookContent: "{message}")
                )
            ]
        case .moderation:
            return [
                StepPreset(
                    id: "delete-message",
                    title: "Delete message",
                    symbol: "text.badge.xmark",
                    step: Automations.Step(kind: .modifyMessage, messageOp: .delete)
                ),
                StepPreset(
                    id: "timeout-user",
                    title: "Timeout user",
                    symbol: "timer",
                    step: Automations.Step(kind: .modifyMember, memberOp: .timeout, timeoutSeconds: 300)
                ),
                StepPreset(
                    id: "kick-user",
                    title: "Kick user",
                    symbol: "person.fill.xmark",
                    step: Automations.Step(kind: .modifyMember, memberOp: .kick, kickReason: "Rule violation")
                ),
                StepPreset(
                    id: "add-role",
                    title: "Add role",
                    symbol: "person.badge.plus",
                    step: Automations.Step(kind: .modifyMember, memberOp: .addRole)
                ),
                StepPreset(
                    id: "remove-role",
                    title: "Remove role",
                    symbol: "person.badge.minus",
                    step: Automations.Step(kind: .modifyMember, memberOp: .removeRole)
                ),
                StepPreset(
                    id: "move-voice",
                    title: "Move voice user",
                    symbol: "arrow.triangle.swap",
                    step: Automations.Step(kind: .modifyMember, memberOp: .moveVoice)
                ),
                StepPreset(
                    id: "dm-warning",
                    title: "DM warning",
                    symbol: "envelope",
                    step: Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .directMessage,
                        content: "Hi {username}, please review the server rules."
                    )
                ),
                StepPreset(
                    id: "write-mod-log",
                    title: "Write to moderation log",
                    symbol: "list.clipboard",
                    step: Automations.Step(kind: .log, logText: "{username}: {message}")
                ),
                StepPreset(
                    id: "wait",
                    title: "Wait",
                    symbol: "clock",
                    step: Automations.Step(kind: .delay, delaySeconds: 10)
                )
            ]
        }
    }

    private func visibleStepKinds(for category: Automations.Category) -> [Automations.StepKind] {
        switch category {
        case .automation:
            return [.sendMessage, .delay, .log, .webhook]
        case .moderation:
            return [.sendMessage, .modifyMember, .modifyMessage, .log, .webhook, .delay]
        }
    }

    @ViewBuilder
    private func stepCard(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack(spacing: 8) {
                // Operation icon badge
                Image(systemName: stepIcon(for: rule.steps[index].kind))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(stepAccentColor(for: rule.steps[index].kind))
                    .frame(width: 22, height: 22)
                    .background(stepAccentColor(for: rule.steps[index].kind).opacity(0.12))
                    .clipShape(Circle())
                
                Text("Step \(index + 1): \(AutomationLabels.stepKind(rule.steps[index].kind))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                
                Spacer()
                
                // Reorder controls
                HStack(spacing: 4) {
                    Button {
                        moveStep(from: index, to: index - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .help("Move step up")
                    
                    Button {
                        moveStep(from: index, to: index + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == rule.steps.count - 1)
                    .help("Move step down")
                }
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
                
                // Delete button
                if rule.steps.count > 1 {
                    Button {
                        deleteStep(at: index)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red.opacity(0.8))
                            .frame(width: 22, height: 22)
                            .background(Color.red.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove step")
                }
            }
            .padding(.bottom, 4)

            formRow(label: "Action") {
                Picker("", selection: Binding(
                    get: { rule.steps[index].kind },
                    set: { newKind in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            rule.steps[index].kind = newKind
                        }
                    }
                )) {
                    ForEach(visibleStepKinds(for: rule.category), id: \.self) { kind in
                        Text(AutomationLabels.stepKind(kind)).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            stepFields(index: index)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(stepCardBackground(for: rule.steps[index].kind))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(white: 1.0, opacity: 0.06), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(stepCardBorder(for: rule.steps[index].kind), lineWidth: 1)
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
                channelRow(label: "Channel", id: $rule.steps[index].channelId, requireValue: true)
            }
            multilineRow(label: "Message", value: $rule.steps[index].content,
                         placeholder: "Hey {username}!")
            aiPromptRow(index: index)

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
                channelRow(label: "Voice channel",
                           id: $rule.steps[index].targetVoiceChannelId,
                           voiceOnly: true,
                           requireValue: true)
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

        case .aiTransform:
            multilineRow(label: "AI prompt",
                         value: $rule.steps[index].aiPrompt,
                         placeholder: "Summarise this in one sentence: {message}")
            Text("Result is available to later steps as **{ai_output}**.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 122)
                .padding(.top, -4)
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
                VariableAutocompleteField(
                    text: Binding(
                        get: { value.wrappedValue ?? "" },
                        set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
                    ),
                    placeholder: placeholder,
                    triggerKind: rule.trigger.kind,
                    multiline: true
                )

                if variablesEnabled {
                    variablePickerMenu(value: value)
                }
            }
        }
    }

    @ViewBuilder
    private func aiPromptRow(index: Int) -> some View {
        let stepID = rule.steps[index].id

        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 5) {
                Text("AI prompt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    aiPromptHelpStepID = stepID
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Explain AI prompts")
                .popover(isPresented: Binding(
                    get: { aiPromptHelpStepID == stepID },
                    set: { if !$0 { aiPromptHelpStepID = nil } }
                ), arrowEdge: .top) {
                    AutomationAIPromptHelpPopover()
                }
            }
            .frame(width: 110, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                VariableAutocompleteField(
                    text: Binding(
                        get: { rule.steps[index].aiPrompt ?? "" },
                        set: { rule.steps[index].aiPrompt = $0.isEmpty ? nil : $0 }
                    ),
                    placeholder: "Optional - AI writes the message if set",
                    triggerKind: rule.trigger.kind,
                    multiline: true
                )

                variablePickerMenu(value: $rule.steps[index].aiPrompt)
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
    private func channelRow(label: String, id: Binding<String?>,
                            voiceOnly: Bool = false,
                            requireValue: Bool = false) -> some View {
        let pool = voiceOnly ? serverContext.voiceChannels : serverContext.textChannels
        // For required fields we no longer auto-pick the first channel — a new
        // rule (not seeded from a preview) starts on a "Select channel…"
        // placeholder so the user makes a deliberate choice. Save stays
        // disabled until they do (see `isReady`). A rule loaded from a preview
        // already carries a channelId, so it shows that real channel.
        let resolved = id.wrappedValue ?? ""
        let effective: String = {
            if !requireValue { return resolved }
            if !resolved.isEmpty, pool.contains(where: { $0.id == resolved }) { return resolved }
            return ""
        }()

        formRow(label: label) {
            Picker("", selection: Binding(
                get: { effective },
                set: { id.wrappedValue = $0.isEmpty ? nil : $0 }
            )) {
                if requireValue {
                    Text("Select channel…").tag("")
                } else {
                    Text("Any").tag("")
                }
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

extension AutomationRuleEditor {
    private func autofillFromRule() {
        if let tc = rule.trigger.channelId, !tc.isEmpty {
            testChannelId = tc
        } else if let inChanFilter = rule.filters.first(where: { $0.kind == .inChannel }),
                  let firstChan = inChanFilter.channelIds?.first, !firstChan.isEmpty {
            testChannelId = firstChan
        }

        if let threshold = rule.trigger.voiceDurationThreshold {
            testVoiceDuration = threshold
        } else if let durationFilter = rule.filters.first(where: { $0.kind == .minVoiceDurationSeconds }),
                  let minSeconds = durationFilter.intValue {
            testVoiceDuration = minSeconds
        }

        if rule.filters.contains(where: { $0.kind == .messageContainsSpamLink }) {
            testMessageContent = "FREE-DISCORD-NITRO PHISHING LINK HERE: HTTPS://GIFT-NITRO.COM"
        } else if rule.filters.contains(where: { $0.kind == .messageCapsPercentage }) {
            testMessageContent = "HELLO WORLD THIS IS A LOUD SHOUTING MESSAGE"
        } else if let mentionsFilter = rule.filters.first(where: { $0.kind == .messageMentionsCount }) {
            let count = mentionsFilter.intValue ?? 5
            var mentionsList: [String] = []
            for i in 1...max(1, count + 1) {
                mentionsList.append("<@user\(i)>")
            }
            testMessageContent = mentionsList.joined(separator: " ") + " wake up!"
        } else if let equalsFilter = rule.filters.first(where: { $0.kind == .messageEquals }),
                  let t = equalsFilter.text, !t.isEmpty {
            testMessageContent = t
        } else if let containsFilter = rule.filters.first(where: { $0.kind == .messageContains }),
                  let t = containsFilter.text, !t.isEmpty {
            testMessageContent = t
        } else if let containsAnyFilter = rule.filters.first(where: { $0.kind == .messageContainsAny }),
                  let t = containsAnyFilter.textValues?.first, !t.isEmpty {
            testMessageContent = t
        } else if let regexFilter = rule.filters.first(where: { $0.kind == .messageMatchesRegex }),
                  let t = regexFilter.text, !t.isEmpty {
            testMessageContent = "Sample matching string for regex: \(t)"
        }
    }

    private func runDryRun() {
        let mockEvent: SwiftBotEvent
        
        switch rule.trigger.kind {
        case .userJoinedVoice:
            mockEvent = SwiftBotEvent.join(
                guildId: "guild-123",
                userId: "user-123",
                username: testUsername,
                channelId: testChannelId
            )
        case .userLeftVoice:
            mockEvent = SwiftBotEvent.leave(
                guildId: "guild-123",
                userId: "user-123",
                username: testUsername,
                channelId: testChannelId,
                durationSeconds: testVoiceDuration
            )
        case .userMovedVoice:
            mockEvent = SwiftBotEvent.move(
                guildId: "guild-123",
                userId: "user-123",
                username: testUsername,
                channelId: testChannelId,
                fromChannelId: "voice-old",
                toChannelId: testChannelId,
                durationSeconds: testVoiceDuration
            )
        case .memberJoined:
            mockEvent = SwiftBotEvent.memberJoin(
                guildId: "guild-123",
                userId: "user-123",
                username: testUsername,
                joinedAt: Date()
            )
        case .memberLeft:
            mockEvent = SwiftBotEvent.memberLeave(
                guildId: "guild-123",
                userId: "user-123",
                username: testUsername
            )
        case .mediaAdded:
            mockEvent = SwiftBotEvent.mediaAdded(SwiftBotEvent.MediaPayload(
                guildId: "guild-123",
                userId: "user-123",
                username: testUsername,
                fileName: "audio.mp3",
                relativePath: nil,
                sourceName: "Local",
                nodeName: "node-1"
            ))
        default:
            mockEvent = SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
                guildId: "guild-123",
                userId: "user-123",
                username: testUsername,
                channelId: testChannelId,
                messageId: "msg-123",
                content: testMessageContent,
                isDirectMessage: false,
                authorIsBot: false
            ))
        }
        
        let dummyDeps = AutomationService.Dependencies(
            sendMessage: { _, _, _ in },
            sendPayloadMessage: { _, _, _ in },
            sendDM: { _, _ in },
            addReaction: { _, _, _, _ in },
            deleteMessage: { _, _, _ in },
            addRole: { _, _, _, _ in },
            removeRole: { _, _, _, _ in },
            timeoutMember: { _, _, _, _ in },
            kickMember: { _, _, _, _ in },
            moveMember: { _, _, _, _ in },
            sendWebhook: { _, _ in },
            resolveChannelName: { _, _ in "simulated-channel" },
            resolveGuildName: { _ in "simulated-guild" },
            log: { _ in },
            recordAutomationRun: { _, _, _, _, _, _ in }
        )
        
        let simService = AutomationService(
            aiService: DiscordAIService(session: URLSession.shared),
            dependencies: dummyDeps
        )
        
        Task {
            let res = await simService.simulate(rule: rule, event: mockEvent)
            await MainActor.run {
                self.simulationResult = res
                self.isShowingSimulation = true
            }
        }
    }

    private func stepAccentColor(for kind: Automations.StepKind) -> Color {
        switch kind {
        case .sendMessage: return .blue
        case .modifyMember: return .red
        case .modifyMessage: return .orange
        case .log: return .purple
        case .webhook: return .teal
        case .delay: return .gray
        case .aiTransform: return .indigo
        }
    }

    private func stepCardBackground(for kind: Automations.StepKind) -> Color {
        stepAccentColor(for: kind).opacity(0.04)
    }

    private func stepCardBorder(for kind: Automations.StepKind) -> Color {
        stepAccentColor(for: kind).opacity(0.12)
    }

    private func stepIcon(for kind: Automations.StepKind) -> String {
        switch kind {
        case .sendMessage: return "bubble.left.and.bubble.right.fill"
        case .modifyMember: return "person.badge.shield.checkmark.fill"
        case .modifyMessage: return "square.and.pencil"
        case .log: return "doc.text.fill"
        case .webhook: return "network"
        case .delay: return "hourglass"
        case .aiTransform: return "apple.intelligence"
        }
    }

    private func moveStep(from src: Int, to dest: Int) {
        guard dest >= 0 && dest < rule.steps.count else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.76)) {
            let temp = rule.steps[src]
            rule.steps[src] = rule.steps[dest]
            rule.steps[dest] = temp
        }
    }

    private func deleteStep(at index: Int) {
        guard index >= 0 && index < rule.steps.count else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            rule.steps.remove(at: index)
        }
    }
}

private struct AutomationAIPromptHelpPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI Prompt")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("How it works")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                helpRow(symbol: "text.bubble", color: .blue, title: "Message empty or static",
                        description: "If AI prompt is blank, SwiftBot sends the Message field exactly as written after replacing variables.")
                helpRow(symbol: "sparkles", color: .purple, title: "AI prompt set",
                        description: "If AI prompt has text, SwiftBot uses it to generate the message body at runtime. This takes priority over Message.")
                helpRow(symbol: "curlybraces", color: .teal, title: "Variables work here",
                        description: "Use Insert variable to add tokens like {username}, {guildName}, {message}, or {channelName} when the trigger supports them.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Example")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Write a short friendly reply to {username} about: {message}")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }

    private func helpRow(symbol: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
