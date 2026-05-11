import SwiftUI

/// IFTTT-style 3-step recipe wizard. Replaces the cold "blank rule" flow with:
///   1. Pick template (or "from scratch")
///   2. Configure required fields inline
///   3. Save → produces a runnable Rule
///
/// Power users can still drop into the canvas editor afterward to extend.
struct RecipeWizardView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Called with a fully-formed Rule the parent should append to its store.
    let onCreate: (Rule) -> Void

    enum Phase: Equatable {
        case chooseStart
        case configureTemplate(RecipeTemplate)
        case configureScratch(TriggerType)
    }

    @State private var phase: Phase = .chooseStart
    @State private var values: RecipeFieldValues = RecipeFieldValues()
    @State private var serverId: String = ""

    private var serverIds: [String] {
        app.connectedServers.keys.sorted {
            (app.connectedServers[$0] ?? $0)
                .localizedCaseInsensitiveCompare(app.connectedServers[$1] ?? $1) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView {
                Group {
                    switch phase {
                    case .chooseStart:
                        chooseStartContent
                    case .configureTemplate(let template):
                        configureTemplateContent(template)
                    case .configureScratch(let trigger):
                        configureScratchContent(trigger)
                    }
                }
                .padding(20)
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, idealHeight: 620)
        .onAppear {
            if serverId.isEmpty { serverId = serverIds.first ?? "" }
        }
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(spacing: 12) {
            if case .chooseStart = phase {
                Image(systemName: "wand.and.stars")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        phase = .chooseStart
                        values = RecipeFieldValues()
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle).font(.headline)
                Text(headerSubtitle).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel") { dismiss() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headerTitle: String {
        switch phase {
        case .chooseStart: return "Create a new automation"
        case .configureTemplate(let t): return t.title
        case .configureScratch(let t): return t.defaultRuleName
        }
    }

    private var headerSubtitle: String {
        switch phase {
        case .chooseStart: return "Pick a recipe to start fast, or build from scratch."
        case .configureTemplate(let t): return t.subtitle
        case .configureScratch: return "Pick a trigger to start. You'll add actions in the editor."
        }
    }

    private var footer: some View {
        HStack {
            if serverIds.count > 1, case .chooseStart = phase {
                Picker("Server", selection: $serverId) {
                    ForEach(serverIds, id: \.self) { id in
                        Text(app.connectedServers[id] ?? "Server \(id.suffix(4))").tag(id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
            }

            Spacer()

            switch phase {
            case .chooseStart:
                EmptyView()
            case .configureTemplate(let template):
                Button {
                    create(template: template)
                } label: {
                    Label("Create automation", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!values.isComplete(for: template))
            case .configureScratch(let trigger):
                Button {
                    createScratch(trigger: trigger)
                } label: {
                    Label("Open in editor", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Phase 1: choose start

    private var chooseStartContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            section(title: "Quick start", subtitle: "Tap a recipe — fill in 1–2 fields and you're done.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(RecipeTemplate.catalog) { template in
                        templateTile(template)
                    }
                }
            }

            section(title: "Build from scratch", subtitle: "Pick a trigger and configure everything in the canvas editor.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    ForEach(TriggerType.allCases) { trigger in
                        scratchTile(trigger)
                    }
                }
            }
        }
    }

    private func templateTile(_ template: RecipeTemplate) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                values = RecipeFieldValues()
                values.message = template.messageDraft
                phase = .configureTemplate(template)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: template.symbol)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(template.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Text(template.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func scratchTile(_ trigger: TriggerType) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                values = RecipeFieldValues()
                phase = .configureScratch(trigger)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: trigger.symbol)
                    .frame(width: 22)
                    .foregroundStyle(.yellow)
                Text(trigger.rawValue)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Phase 2a: configure template

    @ViewBuilder
    private func configureTemplateContent(_ template: RecipeTemplate) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            sentencePreview(template: template)

            if serverIds.count > 1 {
                fieldRow(title: "Server") {
                    Picker("", selection: $serverId) {
                        ForEach(serverIds, id: \.self) { id in
                            Text(app.connectedServers[id] ?? "Server \(id.suffix(4))").tag(id)
                        }
                    }
                    .labelsHidden()
                }
            }

            ForEach(template.fields, id: \.self) { field in
                fieldEditor(field, template: template)
            }
        }
    }

    private func sentencePreview(template: RecipeTemplate) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("When").foregroundStyle(.secondary)
            Text(template.trigger.rawValue)
                .font(.body.weight(.semibold))
                .foregroundStyle(.yellow)
            if let inPart = filterDescription(for: template) {
                Text("in").foregroundStyle(.secondary)
                Text(inPart)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.blue)
            }
            Text("→").foregroundStyle(.secondary)
            Text(template.actionType.rawValue)
                .font(.body.weight(.semibold))
                .foregroundStyle(.mint)
            if let targetPart = targetDescription(for: template) {
                Text("→").foregroundStyle(.secondary)
                Text(targetPart)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func filterDescription(for template: RecipeTemplate) -> String? {
        if template.fields.contains(.optionalVoiceFilter), !values.filterVoiceChannelId.isEmpty,
           let ch = voiceChannels.first(where: { $0.id == values.filterVoiceChannelId }) {
            return ch.name
        }
        if template.fields.contains(.optionalTextChannelFilter), !values.filterTextChannelId.isEmpty,
           let ch = textChannels.first(where: { $0.id == values.filterTextChannelId }) {
            return "#\(ch.name)"
        }
        if template.fields.contains(.keyword), !values.keyword.isEmpty {
            return "\"\(values.keyword)\""
        }
        return nil
    }

    private func targetDescription(for template: RecipeTemplate) -> String? {
        if template.actionType == .sendMessage, !values.textChannelId.isEmpty,
           let ch = textChannels.first(where: { $0.id == values.textChannelId }) {
            return "#\(ch.name)"
        }
        if template.actionType == .addRole || template.actionType == .removeRole,
           !values.roleId.isEmpty,
           let role = roles.first(where: { $0.id == values.roleId }) {
            return "@\(role.name)"
        }
        return nil
    }

    @ViewBuilder
    private func fieldEditor(_ field: RecipeTemplate.Field, template: RecipeTemplate) -> some View {
        switch field {
        case .optionalVoiceFilter:
            fieldRow(title: "Only when joining (optional)", helper: "Leave blank to fire for any voice channel.") {
                Picker("", selection: $values.filterVoiceChannelId) {
                    Text("Any voice channel").tag("")
                    ForEach(voiceChannels, id: \.id) { ch in
                        Text(ch.name).tag(ch.id)
                    }
                }
                .labelsHidden()
            }

        case .optionalTextChannelFilter:
            fieldRow(title: "Only in channel (optional)", helper: "Leave blank to match messages anywhere.") {
                Picker("", selection: $values.filterTextChannelId) {
                    Text("Any channel").tag("")
                    ForEach(textChannels, id: \.id) { ch in
                        Text("#\(ch.name)").tag(ch.id)
                    }
                }
                .labelsHidden()
            }

        case .textChannel:
            fieldRow(title: "Post to channel") {
                Picker("", selection: $values.textChannelId) {
                    Text("Select a channel…").tag("")
                    ForEach(textChannels, id: \.id) { ch in
                        Text("#\(ch.name)").tag(ch.id)
                    }
                }
                .labelsHidden()
            }

        case .voiceChannel:
            fieldRow(title: "Voice channel") {
                Picker("", selection: $values.voiceChannelId) {
                    Text("Select a channel…").tag("")
                    ForEach(voiceChannels, id: \.id) { ch in
                        Text(ch.name).tag(ch.id)
                    }
                }
                .labelsHidden()
            }

        case .role:
            fieldRow(title: "Role") {
                Picker("", selection: $values.roleId) {
                    Text("Select a role…").tag("")
                    ForEach(roles, id: \.id) { role in
                        Text(role.name).tag(role.id)
                    }
                }
                .labelsHidden()
            }

        case .keyword:
            fieldRow(title: "Keyword") {
                TextField("e.g. hello", text: $values.keyword)
                    .textFieldStyle(.roundedBorder)
            }

        case .emoji:
            fieldRow(title: "Emoji") {
                TextField("👍", text: $values.emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
            }

        case .message:
            fieldRow(title: messageLabel(for: template)) {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $values.message)
                        .font(.body)
                        .frame(minHeight: 80, maxHeight: 140)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                        )
                    placeholderHints(for: template.trigger)
                }
            }
        }
    }

    private func messageLabel(for template: RecipeTemplate) -> String {
        template.actionType == .sendDM ? "DM content" : "Message"
    }

    @ViewBuilder
    private func placeholderHints(for trigger: TriggerType) -> some View {
        let placeholders = placeholderSuggestions(for: trigger)
        if !placeholders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Insert variable")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(placeholders, id: \.self) { token in
                        PlaceholderChip(token: token) {
                            values.message.append(token)
                        }
                    }
                }
            }
        }
    }

    private func placeholderSuggestions(for trigger: TriggerType) -> [String] {
        switch trigger {
        case .userJoinedVoice, .userLeftVoice:
            return ["{userId}", "{channelId}", "{username}", "{duration}"]
        case .userMovedVoice:
            return ["{userId}", "{fromChannelId}", "{toChannelId}"]
        case .messageCreated:
            return ["{userId}", "{username}", "{message}", "{channelId}"]
        case .memberJoined, .memberLeft:
            return ["{userId}", "{username}", "{server}", "{memberCount}"]
        case .reactionAdded:
            return ["{userId}", "{username}", "{reaction.emoji}"]
        case .slashCommand:
            return ["{userId}", "{username}"]
        case .mediaAdded:
            return ["{media.file}"]
        }
    }

    // MARK: - Phase 2b: configure scratch (just confirm trigger)

    @ViewBuilder
    private func configureScratchContent(_ trigger: TriggerType) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: trigger.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text(trigger.rawValue).font(.title3.weight(.semibold))
                    Text(triggerDescription(trigger)).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.05))
            )

            if serverIds.count > 1 {
                fieldRow(title: "Server") {
                    Picker("", selection: $serverId) {
                        ForEach(serverIds, id: \.self) { id in
                            Text(app.connectedServers[id] ?? "Server \(id.suffix(4))").tag(id)
                        }
                    }
                    .labelsHidden()
                }
            }

            Text("This creates an empty rule with the trigger pre-selected. Add filters and actions in the canvas editor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func triggerDescription(_ trigger: TriggerType) -> String {
        switch trigger {
        case .userJoinedVoice: return "Fires when a user joins any voice channel."
        case .userLeftVoice: return "Fires when a user disconnects from voice."
        case .userMovedVoice: return "Fires when a user switches voice channels."
        case .messageCreated: return "Fires for every message in your servers."
        case .memberJoined: return "Fires when someone joins your server."
        case .memberLeft: return "Fires when someone leaves your server."
        case .reactionAdded: return "Fires when a reaction is added to a message."
        case .slashCommand: return "Fires when one of your slash commands is used."
        case .mediaAdded: return "Fires when new media is detected in a watched channel."
        }
    }

    // MARK: - Section / field helpers

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
    }

    @ViewBuilder
    private func fieldRow<Content: View>(
        title: String,
        helper: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.85))
            content()
            if let helper {
                Text(helper)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Channel/role data

    private var textChannels: [GuildTextChannel] {
        guard !serverId.isEmpty else {
            return app.availableTextChannelsByServer.values.flatMap { $0 }
        }
        return app.availableTextChannelsByServer[serverId] ?? []
    }

    private var voiceChannels: [GuildVoiceChannel] {
        guard !serverId.isEmpty else {
            return app.availableVoiceChannelsByServer.values.flatMap { $0 }
        }
        return app.availableVoiceChannelsByServer[serverId] ?? []
    }

    private var roles: [GuildRole] {
        guard !serverId.isEmpty else {
            return app.availableRolesByServer.values.flatMap { $0 }
        }
        return app.availableRolesByServer[serverId] ?? []
    }

    // MARK: - Actions

    private func create(template: RecipeTemplate) {
        let rule = RecipeBuilder.makeRule(template: template, values: values, serverId: serverId)
        onCreate(rule)
        dismiss()
    }

    private func createScratch(trigger: TriggerType) {
        let rule = RecipeBuilder.makeBlankRule(trigger: trigger, serverId: serverId)
        onCreate(rule)
        dismiss()
    }
}

// MARK: - Placeholder chip

private struct PlaceholderChip: View {
    let token: String
    let onTap: () -> Void
    @State private var hover: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(token)
                    .font(.caption.monospaced())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(hover ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.10))
            )
            .overlay(
                Capsule().strokeBorder(hover ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.18), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - FlowLayout (wraps chips across multiple lines)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let advance = size.width + (rows[rows.count - 1].isEmpty ? 0 : spacing)
            if rowWidth + advance > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([size])
                rowWidth = size.width
            } else {
                rows[rows.count - 1].append(size)
                rowWidth += advance
            }
        }
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let rowH: CGFloat = row.map(\.height).max() ?? 0
            let widths: CGFloat = row.map(\.width).reduce(0, +)
            let gaps: CGFloat = CGFloat(max(0, row.count - 1)) * spacing
            totalHeight += rowH
            if index < rows.count - 1 { totalHeight += spacing }
            maxRowWidth = max(maxRowWidth, widths + gaps)
        }
        return CGSize(width: max(0, maxRowWidth), height: max(0, totalHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
