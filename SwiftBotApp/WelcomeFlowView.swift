import SwiftUI

struct WelcomeFlowView: View {
    @EnvironmentObject private var app: AppModel
    @State private var selectedGuildID: String = ""
    @State private var testSendInFlight: Bool = false
    @State private var testSendFeedback: String?

    private func bindFlow<Value>(_ keyPath: WritableKeyPath<WelcomeFlowSettings, Value>) -> Binding<Value> {
        Binding(
            get: { app.settings.welcomeFlow[keyPath: keyPath] },
            set: { newValue in
                app.settings.welcomeFlow[keyPath: keyPath] = newValue
                saveSettingsAfterViewUpdate()
            }
        )
    }

    private var welcomeEnabled: Binding<Bool> {
        Binding(
            get: { app.settings.welcomeFlow.publicWelcomeEnabled },
            set: { newValue in
                app.settings.welcomeFlow.publicWelcomeEnabled = newValue
                saveSettingsAfterViewUpdate()
            }
        )
    }

    private var dmEnabled: Binding<Bool> {
        Binding(
            get: { app.settings.welcomeFlow.dmWelcomeEnabled },
            set: { newValue in
                app.settings.welcomeFlow.dmWelcomeEnabled = newValue
                saveSettingsAfterViewUpdate()
            }
        )
    }

    private var selectedChannelID: Binding<String> {
        Binding(
            get: { app.settings.welcomeFlow.publicChannelId },
            set: { newValue in
                app.settings.welcomeFlow.publicChannelId = newValue
                saveSettingsAfterViewUpdate()
            }
        )
    }

    private var welcomeTemplate: Binding<String> {
        Binding(
            get: { app.settings.welcomeFlow.publicMessageTemplate },
            set: { newValue in
                app.settings.welcomeFlow.publicMessageTemplate = newValue
                saveSettingsAfterViewUpdate()
            }
        )
    }

    private var publicMessageFormat: Binding<WelcomeFlowMessageFormat> {
        Binding(
            get: { app.settings.welcomeFlow.publicMessageFormat },
            set: { newValue in
                app.settings.welcomeFlow.publicMessageFormat = newValue
                saveSettingsAfterViewUpdate()
            }
        )
    }

    private var embedTitleTemplate: Binding<String> {
        Binding(
            get: { app.settings.welcomeFlow.publicEmbedTitleTemplate },
            set: { newValue in
                app.settings.welcomeFlow.publicEmbedTitleTemplate = newValue
                saveSettingsAfterViewUpdate()
            }
        )
    }

    private var embedFooterTemplate: Binding<String> {
        Binding(
            get: { app.settings.welcomeFlow.publicEmbedFooterTemplate },
            set: { newValue in
                app.settings.welcomeFlow.publicEmbedFooterTemplate = newValue
                saveSettingsAfterViewUpdate()
            }
        )
    }

    private var dmTemplate: Binding<String> {
        Binding(
            get: { app.settings.welcomeFlow.dmMessageTemplate },
            set: { newValue in
                app.settings.welcomeFlow.dmMessageTemplate = newValue
                saveSettingsAfterViewUpdate()
            }
        )
    }

    private var selectedGuildName: String {
        guard !selectedGuildID.isEmpty else { return "your server" }
        return app.connectedServers[selectedGuildID] ?? "your server"
    }

    private var selectedChannelName: String {
        let channelID = app.settings.welcomeFlow.publicChannelId
        guard !channelID.isEmpty else { return "No channel selected" }
        return app.availableTextChannelsByServer.values
            .joined()
            .first(where: { $0.id == channelID })
            .map { "#\($0.name)" } ?? "Unknown channel"
    }

    private var previewMessage: String {
        renderPreview(app.settings.welcomeFlow.publicMessageTemplate)
    }

    private var dmPreviewMessage: String {
        renderPreview(app.settings.welcomeFlow.dmMessageTemplate)
    }

    private func renderPreview(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{username}", with: "Taylor")
            .replacingOccurrences(of: "{userId}", with: "1234567890")
            .replacingOccurrences(of: "{userMention}", with: "@Taylor")
            .replacingOccurrences(of: "{server}", with: selectedGuildName)
            .replacingOccurrences(of: "{guildName}", with: selectedGuildName)
            .replacingOccurrences(of: "{memberCount}", with: "128")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    metrics
                    greetingSection
                    dmSection
                    safetySection
                    goodbyeSection
                    previewSection
                    roadmapSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: syncSelectedGuild)
        .onChange(of: app.settings.welcomeFlow.publicChannelId) { _, _ in
            syncSelectedGuild()
        }
        .onChange(of: app.settings.welcomeFlow.nextStepRules) { _, _ in
            syncSelectedGuild()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Welcome Flow")
                .font(.title2.weight(.bold))
            Spacer()
            Label(app.settings.welcomeFlow.handlesMemberJoin ? "Active" : "Paused",
                  systemImage: app.settings.welcomeFlow.handlesMemberJoin ? "checkmark.circle.fill" : "pause.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(app.settings.welcomeFlow.handlesMemberJoin ? .green : .secondary)
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: DashboardMetricGrid.columns, spacing: DashboardMetricGrid.spacing) {
            DashboardMetricCard(
                title: "Public Greeting",
                value: app.settings.welcomeFlow.publicWelcomeEnabled ? "On" : "Off",
                subtitle: selectedChannelName,
                symbol: "hand.wave.fill",
                color: app.settings.welcomeFlow.publicWelcomeEnabled ? .green : .orange
            )
            DashboardMetricCard(
                title: "Welcome DM",
                value: app.settings.welcomeFlow.dmWelcomeEnabled ? "On" : "Off",
                subtitle: app.settings.welcomeFlow.dmWelcomeEnabled ? "Private message" : "Not sent",
                symbol: "envelope.fill",
                color: app.settings.welcomeFlow.dmWelcomeEnabled ? .teal : .secondary
            )
            DashboardMetricCard(
                title: "Delivery",
                value: app.settings.welcomeFlow.publicChannelId.isEmpty ? "Unset" : "Channel",
                subtitle: selectedGuildName,
                symbol: "number",
                color: .blue
            )
            DashboardMetricCard(
                title: "Next Step",
                value: "\(app.settings.welcomeFlow.activeNextStepRules.count)",
                subtitle: "invite rule(s)",
                symbol: "person.badge.shield.checkmark.fill",
                color: app.settings.welcomeFlow.hasAutoRole ? .purple : .secondary
            )
        }
    }

    private var greetingSection: some View {
        SwiftMeshSection(title: "Greeting", symbol: "person.crop.circle.badge.plus") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: welcomeEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Send a welcome message")
                            .font(.subheadline.weight(.semibold))
                        Text("Posts when Discord sends a member join event for the server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                HStack(alignment: .top, spacing: 14) {
                    pickerField(label: "Server", selection: $selectedGuildID, options: serverOptions) { newValue in
                        let channels = app.availableTextChannelsByServer[newValue] ?? []
                        if !channels.contains(where: { $0.id == app.settings.welcomeFlow.publicChannelId }) {
                            app.settings.welcomeFlow.publicChannelId = channels.first?.id ?? ""
                            saveSettingsAfterViewUpdate()
                        }
                    }
                    pickerField(label: "Channel", selection: selectedChannelID, options: textChannelOptions) { _ in }
                }

                Picker("Message style", selection: publicMessageFormat) {
                    ForEach(WelcomeFlowMessageFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                if app.settings.welcomeFlow.publicMessageFormat == .embed {
                    HStack(alignment: .top, spacing: 14) {
                        templateField(label: "EMBED TITLE", placeholder: "Welcome to {server}", text: embedTitleTemplate, lineLimit: 1...2)
                        templateField(
                            label: "EMBED FOOTER",
                            placeholder: "Member #{memberCount}",
                            text: embedFooterTemplate,
                            lineLimit: 1...2
                        )
                    }
                    HStack(spacing: 18) {
                        Toggle("Show user avatar (thumbnail)", isOn: bindFlow(\.publicEmbedShowAvatar))
                            .toggleStyle(.checkbox)
                        Toggle("Show author line", isOn: bindFlow(\.publicEmbedShowAuthor))
                            .toggleStyle(.checkbox)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(app.settings.welcomeFlow.publicMessageFormat == .embed ? "EMBED DESCRIPTION" : "MESSAGE TEMPLATE")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    TextField("Welcome message", text: welcomeTemplate, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...6)
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                }

                variableRow

                rotationPoolEditor

                HStack(spacing: 8) {
                    Button {
                        runTestSend()
                    } label: {
                        if testSendInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Send Test", systemImage: "paperplane.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(testSendInFlight || !app.settings.welcomeFlow.hasPublicWelcome)
                    if let feedback = testSendFeedback {
                        Text(feedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var rotationPoolEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("RANDOM TEMPLATES")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    var pool = app.settings.welcomeFlow.publicMessageTemplatePool
                    pool.append("")
                    app.settings.welcomeFlow.publicMessageTemplatePool = pool
                    saveSettingsAfterViewUpdate()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            if app.settings.welcomeFlow.publicMessageTemplatePool.isEmpty {
                Text("Optional — when set, a random template is picked per join.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(app.settings.welcomeFlow.publicMessageTemplatePool.enumerated()), id: \.offset) { idx, _ in
                    HStack(spacing: 6) {
                        TextField("Template", text: poolBinding(at: idx))
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            removePoolEntry(at: idx)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func poolBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard app.settings.welcomeFlow.publicMessageTemplatePool.indices.contains(index) else { return "" }
                return app.settings.welcomeFlow.publicMessageTemplatePool[index]
            },
            set: { newValue in
                guard app.settings.welcomeFlow.publicMessageTemplatePool.indices.contains(index) else { return }
                app.settings.welcomeFlow.publicMessageTemplatePool[index] = newValue
                saveSettingsAfterViewUpdate()
            }
        )
    }

    private func removePoolEntry(at index: Int) {
        guard app.settings.welcomeFlow.publicMessageTemplatePool.indices.contains(index) else { return }
        app.settings.welcomeFlow.publicMessageTemplatePool.remove(at: index)
        saveSettingsAfterViewUpdate()
    }

    private func runTestSend() {
        guard !testSendInFlight else { return }
        testSendInFlight = true
        testSendFeedback = nil
        Task { @MainActor in
            let success = await app.sendWelcomeFlowTestMessage()
            testSendFeedback = success ? "Sent ✓" : "Failed — check channel & permissions"
            testSendInFlight = false
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            testSendFeedback = nil
        }
    }

    private var dmSection: some View {
        SwiftMeshSection(title: "Welcome DM", symbol: "envelope.fill") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: dmEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Send a private welcome")
                            .font(.subheadline.weight(.semibold))
                        Text("DMs are sent directly to the new member after they join.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 5) {
                    Text("DM TEMPLATE")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    TextField("Welcome DM", text: dmTemplate, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...6)
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                }

                Toggle(isOn: bindFlow(\.dmFallbackToChannelEnabled)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Fallback to channel when DM is blocked")
                            .font(.subheadline.weight(.semibold))
                        Text("If Discord refuses the DM (closed DMs), post a short notice in the welcome channel instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if app.settings.welcomeFlow.dmFallbackToChannelEnabled {
                    templateField(
                        label: "FALLBACK NOTICE",
                        placeholder: "👋 {userMention} — I tried to DM you...",
                        text: bindFlow(\.dmFallbackTemplate),
                        lineLimit: 1...3
                    )
                }

                variableRow
            }
        }
    }

    private var safetySection: some View {
        SwiftMeshSection(title: "Safety", symbol: "shield.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: bindFlow(\.skipBots)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Skip bot accounts")
                            .font(.subheadline.weight(.semibold))
                        Text("Bot accounts (flagged by Discord) get no welcome message, DM, or auto-role.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MIN ACCOUNT AGE (DAYS)")
                            .font(.caption2.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        Stepper(
                            value: bindFlow(\.minAccountAgeDays),
                            in: 0...365
                        ) {
                            Text(app.settings.welcomeFlow.minAccountAgeDays == 0
                                ? "Disabled"
                                : "\(app.settings.welcomeFlow.minAccountAgeDays) day(s)")
                                .font(.subheadline)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WHEN TOO NEW")
                            .font(.caption2.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        Picker("", selection: bindFlow(\.accountAgeAction)) {
                            ForEach(WelcomeFlowAccountAgeAction.allCases) { action in
                                Text(action.displayName).tag(action)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(app.settings.welcomeFlow.minAccountAgeDays == 0)
                    }
                }

                if app.settings.welcomeFlow.accountAgeAction == .alertModerators,
                   app.settings.welcomeFlow.minAccountAgeDays > 0 {
                    pickerField(
                        label: "Mod Alert Channel",
                        selection: bindFlow(\.modAlertChannelId),
                        options: textChannelOptions
                    ) { _ in }
                }
            }
        }
    }

    private var goodbyeSection: some View {
        SwiftMeshSection(title: "Goodbye", symbol: "door.left.hand.open") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: bindFlow(\.goodbyeEnabled)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Send a goodbye message")
                            .font(.subheadline.weight(.semibold))
                        Text("Posts in the chosen channel when a member leaves the server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                pickerField(
                    label: "Channel",
                    selection: bindFlow(\.goodbyeChannelId),
                    options: textChannelOptions
                ) { _ in }

                Picker("Message style", selection: bindFlow(\.goodbyeMessageFormat)) {
                    ForEach(WelcomeFlowMessageFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                if app.settings.welcomeFlow.goodbyeMessageFormat == .embed {
                    HStack(alignment: .top, spacing: 14) {
                        templateField(
                            label: "EMBED TITLE",
                            placeholder: "Goodbye from {server}",
                            text: bindFlow(\.goodbyeEmbedTitleTemplate),
                            lineLimit: 1...2
                        )
                        templateField(
                            label: "EMBED FOOTER",
                            placeholder: "{memberCount} members remaining",
                            text: bindFlow(\.goodbyeEmbedFooterTemplate),
                            lineLimit: 1...2
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(app.settings.welcomeFlow.goodbyeMessageFormat == .embed ? "EMBED DESCRIPTION" : "MESSAGE TEMPLATE")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    TextField("Goodbye message", text: bindFlow(\.goodbyeMessageTemplate), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...5)
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                }

                variableRow
            }
        }
    }

    private var previewSection: some View {
        SwiftMeshSection(title: "Preview", symbol: "text.bubble.fill") {
            VStack(alignment: .leading, spacing: 10) {
                if app.settings.welcomeFlow.publicMessageFormat == .embed {
                    previewEmbed(label: selectedChannelName)
                } else {
                    previewBubble(label: selectedChannelName, message: previewMessage)
                }
                previewBubble(label: "Direct Message", message: dmPreviewMessage)
            }
        }
    }

    private func previewBubble(label: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private func previewEmbed(label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 7) {
                    Text(renderPreview(app.settings.welcomeFlow.publicEmbedTitleTemplate))
                        .font(.subheadline.weight(.semibold))
                    Text(previewMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(renderPreview(app.settings.welcomeFlow.publicEmbedFooterTemplate))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var roadmapSection: some View {
        SwiftMeshSection(title: "Next Steps", symbol: "map.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Rules")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        addWelcomeRule()
                    } label: {
                        Label("New Rule", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                }

                if app.settings.welcomeFlow.nextStepRules.isEmpty {
                    PlaceholderPanelLine(text: "No invite rules yet. Add one for dabois, socials, partner links, or an Any invite fallback.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(app.settings.welcomeFlow.nextStepRules) { rule in
                            WelcomeFlowRuleRow(
                                rule: binding(forRuleID: rule.id),
                                roleOptions: roleOptions,
                                roleName: roleName(for: rule.roleId),
                                onSave: saveSettingsAfterViewUpdate,
                                onDelete: { deleteWelcomeRule(rule.id) }
                            )
                        }
                    }
                }

                Text("Invite-specific rules use Discord invite use counts. SwiftBot needs Manage Server to read invites; if Discord cannot resolve the invite, only Any invite rules run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var variableRow: some View {
        HStack(spacing: 6) {
            ForEach(["{username}", "{userMention}", "{server}", "{memberCount}"], id: \.self) { token in
                Text(token)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    private var serverOptions: [WelcomeFlowPickerOption] {
        var options = [WelcomeFlowPickerOption(id: "", label: "-- Pick a server --")]
        let sorted = app.connectedServers.sorted { $0.value.localizedCompare($1.value) == .orderedAscending }
        options.append(contentsOf: sorted.map { WelcomeFlowPickerOption(id: $0.key, label: $0.value) })
        return options
    }

    private var textChannelOptions: [WelcomeFlowPickerOption] {
        var options = [WelcomeFlowPickerOption(id: "", label: "-- Pick a text channel --")]
        let channels = app.availableTextChannelsByServer[selectedGuildID] ?? []
        options.append(contentsOf: channels.map { WelcomeFlowPickerOption(id: $0.id, label: "#\($0.name)") })
        return options
    }

    private var roleOptions: [WelcomeFlowPickerOption] {
        var options = [WelcomeFlowPickerOption(id: "", label: "-- Pick a role --")]
        let roles = (app.availableRolesByServer[selectedGuildID] ?? [])
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            .filter { $0.name != "@everyone" }
        options.append(contentsOf: roles.map { WelcomeFlowPickerOption(id: $0.id, label: "@\($0.name)") })
        return options
    }

    private func roleName(for roleID: String) -> String {
        guard !roleID.isEmpty else { return "No role selected" }
        return app.availableRolesByServer.values
            .joined()
            .first(where: { $0.id == roleID })
            .map { "@\($0.name)" } ?? "Unknown role"
    }

    private func syncSelectedGuild() {
        let channelID = app.settings.welcomeFlow.publicChannelId
        if let match = app.availableTextChannelsByServer.first(where: { _, channels in
            channels.contains(where: { $0.id == channelID })
        }) {
            selectedGuildID = match.key
        } else if let match = app.availableRolesByServer.first(where: { _, roles in
            roles.contains { role in
                app.settings.welcomeFlow.nextStepRules.contains { $0.roleId == role.id }
            }
        }) {
            selectedGuildID = match.key
        } else if selectedGuildID.isEmpty {
            selectedGuildID = app.connectedServers.keys.min() ?? ""
        }
    }

    private func addWelcomeRule() {
        let ruleNumber = app.settings.welcomeFlow.nextStepRules.count + 1
        app.settings.welcomeFlow.nextStepRules.append(WelcomeFlowRule(name: "Invite Rule \(ruleNumber)"))
        saveSettingsAfterViewUpdate()
    }

    private func deleteWelcomeRule(_ id: UUID) {
        app.settings.welcomeFlow.nextStepRules.removeAll { $0.id == id }
        saveSettingsAfterViewUpdate()
    }

    /// id-keyed binding to a rule. Safe across deletes: if the rule has been
    /// removed, get returns a sentinel and set is a no-op. This avoids the
    /// "Index out of range" crash you get from `ForEach($array)` element
    /// bindings when SwiftUI re-renders a deleted row one last time.
    private func binding(forRuleID id: UUID) -> Binding<WelcomeFlowRule> {
        Binding(
            get: {
                app.settings.welcomeFlow.nextStepRules.first(where: { $0.id == id })
                    ?? WelcomeFlowRule()
            },
            set: { newValue in
                guard let index = app.settings.welcomeFlow.nextStepRules
                    .firstIndex(where: { $0.id == id }) else { return }
                app.settings.welcomeFlow.nextStepRules[index] = newValue
            }
        )
    }

    private func saveSettingsAfterViewUpdate() {
        Task { @MainActor in
            await Task.yield()
            app.saveSettings()
        }
    }

    private func pickerField(
        label: String,
        selection: Binding<String>,
        options: [WelcomeFlowPickerOption],
        onChange: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(options) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: selection.wrappedValue) { _, newValue in
                onChange(newValue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func templateField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        lineLimit: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(lineLimit)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WelcomeFlowPickerOption: Identifiable, Hashable {
    let id: String
    let label: String
}

private struct WelcomeFlowRuleRow: View {
    @Binding var rule: WelcomeFlowRule
    let roleOptions: [WelcomeFlowPickerOption]
    let roleName: String
    let onSave: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: rule.isEnabled ? "link.badge.plus" : "link.badge.plus")
                    .font(.title3)
                    .foregroundStyle(rule.isEnabled ? .purple : .secondary)
                    .frame(width: 22)

                TextField("Rule name", text: binding(\.name))
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))

                Toggle("", isOn: binding(\.isEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete rule")
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("INVITE CODE")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    TextField("Any invite", text: binding(\.inviteCode))
                        .textFieldStyle(.roundedBorder)
                        .help("Use just the code, e.g. dabois. Leave empty to match any invite.")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("ROLE")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Picker("", selection: binding(\.roleId)) {
                        ForEach(roleOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(rule.isRunnable ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text("\(rule.inviteLabel) → \(roleName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .opacity(rule.isEnabled ? 1 : 0.65)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<WelcomeFlowRule, Value>) -> Binding<Value> {
        Binding(
            get: { rule[keyPath: keyPath] },
            set: { newValue in
                rule[keyPath: keyPath] = newValue
                rule.updatedAt = Date()
                onSave()
            }
        )
    }
}
