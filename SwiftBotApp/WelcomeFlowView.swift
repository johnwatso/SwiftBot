import SwiftUI

struct WelcomeFlowView: View {
    @EnvironmentObject private var app: AppModel
    @State private var selectedGuildID: String = ""
    @State private var testSendInFlight: Bool = false
    @State private var testSendFeedback: String?
    @State private var showPreviewSheet: Bool = false
    @State private var editingFlow: WelcomeFlowEditTarget?
    @State private var inviteRefreshInFlight: Bool = false
    @State private var inviteRefreshFeedback: String?
    @State private var welcomeRuleOrder: [WelcomeFlowEditTarget.Kind] = WelcomeFlowEditTarget.Kind.defaultOrder
    @State private var pendingRuleSortTask: Task<Void, Never>?
    @Namespace private var formatSelectorNamespace

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

    private var goodbyeChannelName: String {
        let channelID = app.settings.welcomeFlow.goodbyeChannelId
        guard !channelID.isEmpty else { return "No channel selected" }
        return app.availableTextChannelsByServer.values
            .joined()
            .first(where: { $0.id == channelID })
            .map { "#\($0.name)" } ?? "Unknown channel"
    }

    private var publicGreetingSubtitle: String {
        app.settings.welcomeFlow.publicWelcomeEnabled ? "Member joins -> \(selectedChannelName)" : "Not posted"
    }

    private var inviteRulesSubtitle: String {
        let count = app.settings.welcomeFlow.activeNextStepRules.count
        if count == 0 { return "No role steps configured" }
        return count == 1 ? "1 invite role rule" : "\(count) invite role rules"
    }

    private var safetyIsActive: Bool {
        app.settings.welcomeFlow.skipBots || app.settings.welcomeFlow.minAccountAgeDays > 0
    }

    private var safetySubtitle: String {
        let flow = app.settings.welcomeFlow
        if flow.skipBots, flow.minAccountAgeDays > 0 {
            return "Skip bots + require \(flow.minAccountAgeDays)d account age"
        }
        if flow.skipBots { return "Skip bot accounts" }
        if flow.minAccountAgeDays > 0 { return "Require \(flow.minAccountAgeDays)d account age" }
        return "No safety conditions"
    }

    private var welcomeRuleDescriptors: [WelcomeFlowRuleDescriptor] {
        let descriptors = [
            WelcomeFlowRuleDescriptor(
                order: 0,
                title: "Public greeting",
                subtitle: publicGreetingSubtitle,
                symbol: "hand.wave.fill",
                tint: app.settings.welcomeFlow.publicWelcomeEnabled ? .green : .secondary,
                isEnabled: app.settings.welcomeFlow.publicWelcomeEnabled,
                isVisible: app.settings.welcomeFlow.publicWelcomeEnabled,
                target: .publicGreeting
            ),
            WelcomeFlowRuleDescriptor(
                order: 1,
                title: "Welcome DM",
                subtitle: app.settings.welcomeFlow.dmWelcomeEnabled ? "DM the new member" : "Not sent",
                symbol: "envelope.fill",
                tint: app.settings.welcomeFlow.dmWelcomeEnabled ? .teal : .secondary,
                isEnabled: app.settings.welcomeFlow.dmWelcomeEnabled,
                isVisible: app.settings.welcomeFlow.dmWelcomeEnabled,
                target: .directMessage
            ),
            WelcomeFlowRuleDescriptor(
                order: 2,
                title: "Invite role rules",
                subtitle: inviteRulesSubtitle,
                symbol: "link.badge.plus",
                tint: app.settings.welcomeFlow.activeNextStepRules.isEmpty ? .secondary : .purple,
                isEnabled: !app.settings.welcomeFlow.activeNextStepRules.isEmpty,
                isVisible: app.settings.welcomeFlow.autoRoleEnabled || !app.settings.welcomeFlow.nextStepRules.isEmpty,
                target: .inviteRoles
            ),
            WelcomeFlowRuleDescriptor(
                order: 3,
                title: "Safety conditions",
                subtitle: safetySubtitle,
                symbol: "shield.lefthalf.filled",
                tint: safetyIsActive ? .orange : .secondary,
                isEnabled: safetyIsActive,
                isVisible: safetyIsActive,
                target: .safety
            ),
            WelcomeFlowRuleDescriptor(
                order: 4,
                title: "Goodbye message",
                subtitle: app.settings.welcomeFlow.goodbyeEnabled ? goodbyeChannelName : "Not sent",
                symbol: "door.left.hand.open",
                tint: app.settings.welcomeFlow.goodbyeEnabled ? .orange : .secondary,
                isEnabled: app.settings.welcomeFlow.goodbyeEnabled,
                isVisible: app.settings.welcomeFlow.goodbyeEnabled,
                target: .goodbye
            )
        ].filter(\.isVisible)

        let fallbackOrder = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.target, $0.order) })
        return descriptors.sorted {
            let left = welcomeRuleOrder.firstIndex(of: $0.target) ?? fallbackOrder[$0.target] ?? $0.order
            let right = welcomeRuleOrder.firstIndex(of: $1.target) ?? fallbackOrder[$1.target] ?? $1.order
            return left < right
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if app.isFailoverManagedNode {
                    PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. These settings sync from Primary.")
                }
                metrics
                welcomeRuleBuilderSurface
            }
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(app.isFailoverManagedNode)
        .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        .sheet(isPresented: $showPreviewSheet) {
            previewSheet
        }
        .sheet(item: $editingFlow) { target in
            flowEditorSheet(target)
                .frame(minWidth: 640, idealWidth: 760, minHeight: 560, idealHeight: 700)
        }
        .onAppear {
            syncSelectedGuild()
            sortWelcomeRules(animated: false)
        }
        .onDisappear {
            pendingRuleSortTask?.cancel()
            pendingRuleSortTask = nil
        }
        .onChange(of: app.settings.welcomeFlow.publicChannelId) { _, _ in
            syncSelectedGuild()
        }
        .onChange(of: app.settings.welcomeFlow.nextStepRules) { _, _ in
            syncSelectedGuild()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Welcome Flow")
                .font(.title2.weight(.bold))
            Label(app.settings.welcomeFlow.handlesMemberJoin ? "Active" : "Paused",
                  systemImage: app.settings.welcomeFlow.handlesMemberJoin ? "checkmark.circle.fill" : "pause.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(app.settings.welcomeFlow.handlesMemberJoin ? .green : .secondary)
            if !app.settings.welcomeFlow.activeNextStepRules.isEmpty {
                Label("\(app.settings.welcomeFlow.activeNextStepRules.count) invite rules",
                      systemImage: "person.badge.shield.checkmark.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
        }
    }

    private var welcomeRuleBuilderSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            AutomationsSection(title: "Start from a template", symbol: "square.grid.2x2") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        welcomeTemplateCard(
                            title: "Public Greeting",
                            subtitle: "Post a simple welcome in a selected channel when someone joins.",
                            symbol: "hand.wave.fill",
                            tint: .green,
                            preset: .publicGreeting
                        )
                        welcomeTemplateCard(
                            title: "Welcome Embed",
                            subtitle: "Post a richer welcome card with the member count and avatar.",
                            symbol: "rectangle.portrait.on.rectangle.portrait.angled",
                            tint: .blue,
                            preset: .publicEmbed
                        )
                        welcomeTemplateCard(
                            title: "Welcome DM",
                            subtitle: "Send a private welcome and fall back to the channel if blocked.",
                            symbol: "envelope.fill",
                            tint: .teal,
                            preset: .directMessage
                        )
                        welcomeTemplateCard(
                            title: "Invite Role",
                            subtitle: "Create a starter invite-based role assignment rule.",
                            symbol: "link.badge.plus",
                            tint: .purple,
                            preset: .inviteRoles
                        )
                        welcomeTemplateCard(
                            title: "New Account Safety",
                            subtitle: "Skip bots and alert moderators for very new accounts.",
                            symbol: "shield.lefthalf.filled",
                            tint: .orange,
                            preset: .safety
                        )
                        welcomeTemplateCard(
                            title: "Goodbye",
                            subtitle: "Post a departure message when someone leaves.",
                            symbol: "door.left.hand.open",
                            tint: .orange,
                            preset: .goodbye
                        )
                    }
                    .padding(.vertical, 2)
                }
            }

            AutomationsSection(title: "Rules", symbol: "list.bullet") {
                VStack(spacing: 6) {
                    if welcomeRuleDescriptors.isEmpty {
                        PlaceholderPanelLine(text: "No welcome flow rules yet. Start from a template above, or use Add rule.")
                    } else {
                        ForEach(welcomeRuleDescriptors) { rule in
                            welcomeRuleRow(
                                title: rule.title,
                                subtitle: rule.subtitle,
                                symbol: rule.symbol,
                                tint: rule.tint,
                                isEnabled: rule.isEnabled,
                                target: rule.target
                            )
                        }
                    }

                    Divider().padding(.vertical, 2)

                    HStack {
                        Menu {
                            Button("Public greeting") {
                                applyWelcomePreset(.publicGreeting)
                            }
                            Button("Welcome DM") {
                                applyWelcomePreset(.directMessage)
                            }
                            Button("Invite role rule") {
                                applyWelcomePreset(.inviteRoles)
                            }
                            Button("Safety conditions") {
                                applyWelcomePreset(.safety)
                            }
                            Button("Goodbye message") {
                                applyWelcomePreset(.goodbye)
                            }
                        } label: {
                            Label("Add rule", systemImage: "plus.circle")
                                .font(.subheadline)
                        }
                        .menuStyle(.borderlessButton)
                        Spacer()
                    }
                }
            }
        }
    }

    private func welcomeTemplateCard(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        preset: WelcomeFlowTemplatePreset
    ) -> some View {
        Button {
            applyWelcomePreset(preset)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.14)))

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
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

    private func welcomeRuleRow(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        isEnabled: Bool,
        target: WelcomeFlowEditTarget.Kind
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isEnabled ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isRuleEnabled(target) },
                set: { newValue in
                    newValue ? enableRule(target) : disableRule(target)
                    scheduleWelcomeRuleSort()
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            Button {
                editingFlow = WelcomeFlowEditTarget(kind: target)
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit")

            Button(role: .destructive) {
                deleteRule(target)
                scheduleWelcomeRuleSort()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Delete rule")
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
            editingFlow = WelcomeFlowEditTarget(kind: target)
        }
        .contextMenu {
            Button("Edit") {
                editingFlow = WelcomeFlowEditTarget(kind: target)
            }
            Button(isEnabled ? "Disable" : "Enable") {
                isEnabled ? disableRule(target) : enableRule(target)
                scheduleWelcomeRuleSort()
            }
            Button("Delete", role: .destructive) {
                deleteRule(target)
                scheduleWelcomeRuleSort()
            }
        }
    }

    private func flowEditorSheet(_ target: WelcomeFlowEditTarget) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            flowEditorHeader(target.kind)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch target.kind {
                    case .publicGreeting:
                        flowStage(title: "WHEN this happens", symbol: "bolt.fill", tint: .blue) {
                            joinTriggerStage
                        }
                        flowStage(title: "THEN do these steps", symbol: "arrow.triangle.branch", tint: .green) {
                            greetingSection
                        }

                    case .directMessage:
                        flowStage(title: "WHEN this happens", symbol: "bolt.fill", tint: .blue) {
                            joinTriggerStage
                        }
                        flowStage(title: "THEN do these steps", symbol: "arrow.triangle.branch", tint: .green) {
                            dmSection
                        }

                    case .inviteRoles:
                        flowStage(title: "WHEN this happens", symbol: "bolt.fill", tint: .blue) {
                            joinTriggerStage
                        }
                        flowStage(title: "IF this invite was used", symbol: "line.3.horizontal.decrease.circle", tint: .orange) {
                            roadmapSection
                        }

                    case .safety:
                        flowStage(title: "WHEN this happens", symbol: "bolt.fill", tint: .blue) {
                            joinTriggerStage
                        }
                        flowStage(title: "IF these conditions match", symbol: "line.3.horizontal.decrease.circle", tint: .orange) {
                            safetySection
                        }

                    case .goodbye:
                        flowStage(title: "WHEN this happens", symbol: "bolt.fill", tint: .blue) {
                            leaveTriggerStage
                        }
                        flowStage(title: "THEN do these steps", symbol: "arrow.triangle.branch", tint: .green) {
                            goodbyeSection
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }

            VStack(spacing: 0) {
                Divider().opacity(0.45)
                HStack {
                    Button(role: .destructive) {
                        deleteRule(target.kind)
                        scheduleWelcomeRuleSort()
                        editingFlow = nil
                    } label: {
                        Label("Delete rule", systemImage: "trash")
                    }

                    Spacer()

                    Button {
                        if isRuleEnabled(target.kind) {
                            disableRule(target.kind)
                        } else {
                            enableRule(target.kind)
                        }
                        scheduleWelcomeRuleSort()
                        editingFlow = nil
                    } label: {
                        Label(
                            isRuleEnabled(target.kind) ? "Disable rule" : "Enable rule",
                            systemImage: isRuleEnabled(target.kind) ? "pause.circle" : "play.circle"
                        )
                    }
                    Button("Done") {
                        editingFlow = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
            .background(.thinMaterial)
        }
    }

    private func flowEditorHeader(_ kind: WelcomeFlowEditTarget.Kind) -> some View {
        let meta = editorMetadata(for: kind)
        return HStack(alignment: .center, spacing: 16) {
            Image(systemName: meta.symbol)
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(meta.tint)
                .frame(width: 52, height: 52)
                .background(Circle().fill(meta.tint.opacity(0.14)))
                .overlay(Circle().stroke(meta.tint.opacity(0.18), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                Text(meta.title)
                    .font(.title2.weight(.bold))
                Text(meta.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private func editorMetadata(for kind: WelcomeFlowEditTarget.Kind) -> (title: String, subtitle: String, symbol: String, tint: Color) {
        switch kind {
        case .publicGreeting:
            return (
                "Public Greeting",
                "When a member joins, post a welcome message in a channel.",
                "hand.wave.fill",
                .green
            )
        case .directMessage:
            return (
                "Welcome DM",
                "When a member joins, send them a private welcome.",
                "envelope.fill",
                .teal
            )
        case .inviteRoles:
            return (
                "Invite Role Rules",
                "When a member joins through an invite, grant the matching role.",
                "link.badge.plus",
                .purple
            )
        case .safety:
            return (
                "Safety Conditions",
                "Gate welcome handling for bots and newly-created accounts.",
                "shield.lefthalf.filled",
                .orange
            )
        case .goodbye:
            return (
                "Goodbye Message",
                "When a member leaves, post a departure message.",
                "door.left.hand.open",
                .orange
            )
        }
    }

    private func applyWelcomePreset(_ preset: WelcomeFlowTemplatePreset) {
        let kind = preset.target
        applyWelcomePresetSettings(preset)
        scheduleWelcomeRuleSort()
        editingFlow = WelcomeFlowEditTarget(kind: kind)
    }

    private func applyWelcomePresetSettings(_ preset: WelcomeFlowTemplatePreset) {
        switch preset {
        case .publicGreeting:
            enableRule(.publicGreeting)
            app.settings.welcomeFlow.publicMessageFormat = .plainText
            app.settings.welcomeFlow.publicMessageTemplate = "👋 Welcome {userMention} to **{server}**! You are member #{memberCount}."
            if app.settings.welcomeFlow.publicMessageTemplatePool.isEmpty {
                app.settings.welcomeFlow.publicMessageTemplatePool = [
                    "👋 Welcome {userMention} to **{server}**!",
                    "Glad you made it, {username}. Welcome to **{server}**.",
                    "Everyone say hi to {userMention} - member #{memberCount}!"
                ]
            }
        case .publicEmbed:
            enableRule(.publicGreeting)
            app.settings.welcomeFlow.publicMessageFormat = .embed
            app.settings.welcomeFlow.publicEmbedTitleTemplate = "Welcome to {server}"
            app.settings.welcomeFlow.publicMessageTemplate = "Glad you made it, {userMention}. Take a look around and say hello when you are ready."
            app.settings.welcomeFlow.publicEmbedFooterTemplate = "Member #{memberCount}"
            app.settings.welcomeFlow.publicEmbedShowAvatar = true
            app.settings.welcomeFlow.publicEmbedShowAuthor = true
        case .directMessage:
            enableRule(.directMessage)
            app.settings.welcomeFlow.dmMessageTemplate = """
            Welcome to {server}, {username}!

            Please check the rules and introduce yourself when you are ready.
            """
            app.settings.welcomeFlow.dmFallbackToChannelEnabled = true
            app.settings.welcomeFlow.dmFallbackTemplate = "👋 {userMention}, welcome to **{server}**. I tried to DM you, but your DMs are closed."
        case .inviteRoles:
            if app.settings.welcomeFlow.nextStepRules.isEmpty {
                app.settings.welcomeFlow.nextStepRules = [
                    WelcomeFlowRule(name: "Invite role")
                ]
            }
            enableRule(.inviteRoles)
        case .safety:
            enableRule(.safety)
            app.settings.welcomeFlow.skipBots = true
            if app.settings.welcomeFlow.minAccountAgeDays == 0 {
                app.settings.welcomeFlow.minAccountAgeDays = 7
            }
            app.settings.welcomeFlow.accountAgeAction = .alertModerators
        case .goodbye:
            enableRule(.goodbye)
            app.settings.welcomeFlow.goodbyeMessageFormat = .plainText
            app.settings.welcomeFlow.goodbyeMessageTemplate = "{username} left **{server}**. We are now at {memberCount} members."
        }
        saveSettingsAfterViewUpdate()
    }

    private func scheduleWelcomeRuleSort() {
        pendingRuleSortTask?.cancel()
        pendingRuleSortTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            sortWelcomeRules(animated: true)
            pendingRuleSortTask = nil
        }
    }

    private func sortWelcomeRules(animated: Bool) {
        let sorted = welcomeRuleDescriptors
            .sorted {
                if $0.isEnabled != $1.isEnabled { return $0.isEnabled && !$1.isEnabled }
                return $0.order < $1.order
            }
            .map(\.target)

        guard welcomeRuleOrder != sorted else { return }
        if animated {
            withAnimation(.snappy(duration: 0.28)) {
                welcomeRuleOrder = sorted
            }
        } else {
            welcomeRuleOrder = sorted
        }
    }

    private func enableRule(_ kind: WelcomeFlowEditTarget.Kind) {
        switch kind {
        case .publicGreeting:
            app.settings.welcomeFlow.publicWelcomeEnabled = true
            if app.settings.welcomeFlow.publicChannelId.isEmpty {
                app.settings.welcomeFlow.publicChannelId =
                    defaultWelcomeChannelID(for: selectedGuildID)
                    ?? (app.availableTextChannelsByServer[selectedGuildID] ?? []).first?.id
                    ?? ""
            }
        case .directMessage:
            app.settings.welcomeFlow.dmWelcomeEnabled = true
        case .inviteRoles:
            if app.settings.welcomeFlow.nextStepRules.isEmpty {
                app.settings.welcomeFlow.nextStepRules.append(WelcomeFlowRule(name: "Invite Rule 1"))
            }
        case .safety:
            app.settings.welcomeFlow.skipBots = true
        case .goodbye:
            app.settings.welcomeFlow.goodbyeEnabled = true
            if app.settings.welcomeFlow.goodbyeChannelId.isEmpty {
                app.settings.welcomeFlow.goodbyeChannelId =
                    defaultWelcomeChannelID(for: selectedGuildID)
                    ?? (app.availableTextChannelsByServer[selectedGuildID] ?? []).first?.id
                    ?? ""
            }
        }
        saveSettingsAfterViewUpdate()
    }

    private func disableRule(_ kind: WelcomeFlowEditTarget.Kind) {
        switch kind {
        case .publicGreeting:
            app.settings.welcomeFlow.publicWelcomeEnabled = false
        case .directMessage:
            app.settings.welcomeFlow.dmWelcomeEnabled = false
        case .inviteRoles:
            app.settings.welcomeFlow.autoRoleEnabled = false
            app.settings.welcomeFlow.nextStepRules = app.settings.welcomeFlow.nextStepRules.map { rule in
                var disabled = rule
                disabled.isEnabled = false
                disabled.updatedAt = Date()
                return disabled
            }
        case .safety:
            app.settings.welcomeFlow.skipBots = false
            app.settings.welcomeFlow.minAccountAgeDays = 0
            app.settings.welcomeFlow.accountAgeAction = .skipWelcome
        case .goodbye:
            app.settings.welcomeFlow.goodbyeEnabled = false
        }
        saveSettingsAfterViewUpdate()
    }

    private func deleteRule(_ kind: WelcomeFlowEditTarget.Kind) {
        let defaults = WelcomeFlowSettings()
        switch kind {
        case .publicGreeting:
            app.settings.welcomeFlow.publicWelcomeEnabled = false
            app.settings.welcomeFlow.publicChannelId = ""
            app.settings.welcomeFlow.publicMessageFormat = defaults.publicMessageFormat
            app.settings.welcomeFlow.publicMessageTemplate = defaults.publicMessageTemplate
            app.settings.welcomeFlow.publicMessageTemplatePool = []
            app.settings.welcomeFlow.publicEmbedTitleTemplate = defaults.publicEmbedTitleTemplate
            app.settings.welcomeFlow.publicEmbedFooterTemplate = defaults.publicEmbedFooterTemplate
            app.settings.welcomeFlow.publicEmbedColor = defaults.publicEmbedColor
            app.settings.welcomeFlow.publicEmbedShowAvatar = defaults.publicEmbedShowAvatar
            app.settings.welcomeFlow.publicEmbedShowAuthor = defaults.publicEmbedShowAuthor
        case .directMessage:
            app.settings.welcomeFlow.dmWelcomeEnabled = false
            app.settings.welcomeFlow.dmMessageTemplate = defaults.dmMessageTemplate
            app.settings.welcomeFlow.dmFallbackToChannelEnabled = defaults.dmFallbackToChannelEnabled
            app.settings.welcomeFlow.dmFallbackTemplate = defaults.dmFallbackTemplate
        case .inviteRoles:
            app.settings.welcomeFlow.autoRoleEnabled = false
            app.settings.welcomeFlow.autoRoleId = ""
            app.settings.welcomeFlow.nextStepRules = []
        case .safety:
            app.settings.welcomeFlow.skipBots = false
            app.settings.welcomeFlow.minAccountAgeDays = 0
            app.settings.welcomeFlow.accountAgeAction = .skipWelcome
            app.settings.welcomeFlow.modAlertChannelId = ""
        case .goodbye:
            app.settings.welcomeFlow.goodbyeEnabled = false
            app.settings.welcomeFlow.goodbyeChannelId = ""
            app.settings.welcomeFlow.goodbyeMessageFormat = defaults.goodbyeMessageFormat
            app.settings.welcomeFlow.goodbyeMessageTemplate = defaults.goodbyeMessageTemplate
            app.settings.welcomeFlow.goodbyeEmbedTitleTemplate = defaults.goodbyeEmbedTitleTemplate
            app.settings.welcomeFlow.goodbyeEmbedFooterTemplate = defaults.goodbyeEmbedFooterTemplate
            app.settings.welcomeFlow.goodbyeEmbedColor = defaults.goodbyeEmbedColor
        }
        saveSettingsAfterViewUpdate()
    }

    private func isRuleEnabled(_ kind: WelcomeFlowEditTarget.Kind) -> Bool {
        switch kind {
        case .publicGreeting:
            return app.settings.welcomeFlow.publicWelcomeEnabled
        case .directMessage:
            return app.settings.welcomeFlow.dmWelcomeEnabled
        case .inviteRoles:
            return !app.settings.welcomeFlow.activeNextStepRules.isEmpty
        case .safety:
            return safetyIsActive
        case .goodbye:
            return app.settings.welcomeFlow.goodbyeEnabled
        }
    }

    private func flowStage<Content: View>(
        title: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(tint.opacity(0.13)))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var joinTriggerStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            flowSummaryRow(
                symbol: "person.badge.plus",
                title: "A member joins the server",
                detail: app.settings.welcomeFlow.handlesMemberJoin
                    ? "SwiftBot will evaluate the welcome conditions below."
                    : "Enable a greeting, DM, or invite role to activate this rule.",
                tint: app.settings.welcomeFlow.handlesMemberJoin ? .green : .secondary
            )

            pickerField(label: "Server", selection: $selectedGuildID, options: serverOptions) { newValue in
                let channels = app.availableTextChannelsByServer[newValue] ?? []
                if !channels.contains(where: { $0.id == app.settings.welcomeFlow.publicChannelId }) {
                    app.settings.welcomeFlow.publicChannelId = defaultWelcomeChannelID(for: newValue) ?? channels.first?.id ?? ""
                    saveSettingsAfterViewUpdate()
                }
            }
        }
    }

    private var leaveTriggerStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            flowSummaryRow(
                symbol: "person.crop.circle.badge.minus",
                title: "A member leaves the server",
                detail: app.settings.welcomeFlow.goodbyeEnabled
                    ? "SwiftBot will post the configured goodbye message."
                    : "Turn on the goodbye step below to activate this rule.",
                tint: app.settings.welcomeFlow.goodbyeEnabled ? .green : .secondary
            )

            pickerField(label: "Server", selection: $selectedGuildID, options: serverOptions) { _ in }
        }
    }

    private func flowSummaryRow(symbol: String, title: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.headline)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
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
        }
    }

    private var previewSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Preview")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { showPreviewSheet = false }
                    .keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if app.settings.welcomeFlow.publicMessageFormat == .embed {
                        previewEmbed(label: selectedChannelName)
                    } else {
                        previewBubble(label: selectedChannelName, message: previewMessage)
                    }
                    previewBubble(label: "Direct Message", message: dmPreviewMessage)
                }
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
    }

    private var greetingSection: some View {
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

                pickerField(label: "Channel", selection: selectedChannelID, options: textChannelOptions) { _ in }

                messageFormatSelector("Message style", selection: publicMessageFormat)

                if app.settings.welcomeFlow.publicMessageFormat == .embed {
                    HStack(spacing: 8) {
                        Text("EMBED CARD")
                            .font(.caption2.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button {
                            showPreviewSheet = true
                        } label: {
                            Label("Preview", systemImage: "text.bubble")
                        }
                        .buttonStyle(WelcomeFlowGlassButtonStyle(compact: true))
                    }

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
                    .buttonStyle(WelcomeFlowGlassButtonStyle(tint: .accentColor))
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

    private var rotationPoolEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("RANDOM TEMPLATES")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addPoolEntry()
                } label: {
                    Label("Add Template", systemImage: "plus")
                }
                .buttonStyle(WelcomeFlowGlassButtonStyle(compact: true))
            }
            if app.settings.welcomeFlow.publicMessageTemplatePool.isEmpty {
                HStack(spacing: 8) {
                    Text("No random templates yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        addPoolEntry()
                    } label: {
                        Label("Create Template", systemImage: "plus")
                    }
                    .buttonStyle(WelcomeFlowGlassButtonStyle(tint: .accentColor, compact: true))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            } else {
                ForEach(Array(app.settings.welcomeFlow.publicMessageTemplatePool.enumerated()), id: \.offset) { idx, _ in
                    HStack(spacing: 6) {
                        TextField("Random welcome template", text: poolBinding(at: idx), axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...4)
                            .padding(9)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                            )
                        Button(role: .destructive) {
                            removePoolEntry(at: idx)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(WelcomeFlowIconButtonStyle(tint: .red))
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

    private func addPoolEntry() {
        var pool = app.settings.welcomeFlow.publicMessageTemplatePool
        let template = app.settings.welcomeFlow.publicMessageTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pool.append(template.isEmpty ? "👋 Welcome {username} to **{server}**!" : template)
        app.settings.welcomeFlow.publicMessageTemplatePool = pool
        saveSettingsAfterViewUpdate()
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

    private var safetySection: some View {
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

    private var goodbyeSection: some View {
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

                messageFormatSelector("Message style", selection: bindFlow(\.goodbyeMessageFormat))

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
        VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Rules")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        refreshInvites()
                    } label: {
                        if inviteRefreshInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh Invites", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(WelcomeFlowGlassButtonStyle(compact: true))
                    .disabled(inviteRefreshInFlight || selectedGuildID.isEmpty)
                    Button {
                        addWelcomeRule()
                    } label: {
                        Label("New Rule", systemImage: "plus")
                    }
                    .buttonStyle(WelcomeFlowGlassButtonStyle(tint: .accentColor, compact: true))
                }

                if app.settings.welcomeFlow.nextStepRules.isEmpty {
                    PlaceholderPanelLine(text: "No invite rules yet. Add one for dabois, socials, partner links, or an Any invite fallback.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(app.settings.welcomeFlow.nextStepRules) { rule in
                            WelcomeFlowRuleRow(
                                rule: binding(forRuleID: rule.id),
                                inviteSnapshots: inviteSnapshots,
                                roleOptions: roleOptions,
                                roleName: roleName(for: rule.roleId),
                                onInviteSelected: { applyWelcomeChannel(forInviteCode: $0) },
                                onSave: saveSettingsAfterViewUpdate,
                                onDelete: { deleteWelcomeRule(rule.id) }
                            )
                        }
                    }
                }

                if let inviteRefreshFeedback {
                    Text(inviteRefreshFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Invite-specific rules use Discord invite use counts. SwiftBot needs Manage Server to read invites; if Discord cannot resolve the invite, only Any invite rules run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var inviteSnapshots: [WelcomeFlowService.InviteSnapshot] {
        app.welcomeFlowInvitesByServer[selectedGuildID] ?? []
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

    private func refreshInvites() {
        guard !inviteRefreshInFlight, !selectedGuildID.isEmpty else { return }
        inviteRefreshInFlight = true
        inviteRefreshFeedback = nil
        Task { @MainActor in
            let success = await app.refreshWelcomeFlowInvites(guildID: selectedGuildID)
            let count = inviteSnapshots.count
            let defaultedChannel = success ? applyDefaultWelcomeChannelFromInvites() : nil
            if let defaultedChannel {
                inviteRefreshFeedback = "Loaded \(count) invite\(count == 1 ? "" : "s") and set welcome channel to #\(defaultedChannel.name)."
            } else {
                inviteRefreshFeedback = success
                    ? "Loaded \(count) invite\(count == 1 ? "" : "s") from Discord."
                    : "Could not load invites. Check Manage Server permission."
            }
            inviteRefreshInFlight = false
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            inviteRefreshFeedback = nil
        }
    }

    private func defaultWelcomeChannelID(for guildID: String) -> String? {
        let channels = app.availableTextChannelsByServer[guildID] ?? []
        let channelIDs = Set(channels.map(\.id))
        return (app.welcomeFlowInvitesByServer[guildID] ?? [])
            .first { invite in
                guard let channelID = invite.channelID else { return false }
                return channelIDs.contains(channelID)
            }?
            .channelID
    }

    @discardableResult
    private func applyDefaultWelcomeChannelFromInvites() -> GuildTextChannel? {
        guard let channelID = defaultWelcomeChannelID(for: selectedGuildID) else { return nil }
        return setWelcomeChannelIfNeeded(channelID)
    }

    @discardableResult
    private func applyWelcomeChannel(forInviteCode inviteCode: String) -> GuildTextChannel? {
        let trimmed = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let channelID = inviteSnapshots.first(where: {
                  $0.code.caseInsensitiveCompare(trimmed) == .orderedSame
              })?.channelID
        else {
            return nil
        }
        return setWelcomeChannelIfNeeded(channelID)
    }

    @discardableResult
    private func setWelcomeChannelIfNeeded(_ channelID: String) -> GuildTextChannel? {
        let channels = app.availableTextChannelsByServer[selectedGuildID] ?? []
        guard let channel = channels.first(where: { $0.id == channelID }) else { return nil }

        let currentChannelID = app.settings.welcomeFlow.publicChannelId
        let currentIsValidForSelectedGuild = channels.contains { $0.id == currentChannelID }
        guard currentChannelID.isEmpty || !currentIsValidForSelectedGuild else { return nil }

        app.settings.welcomeFlow.publicChannelId = channelID
        saveSettingsAfterViewUpdate()
        return channel
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

    private func messageFormatSelector(
        _ label: String,
        selection: Binding<WelcomeFlowMessageFormat>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(WelcomeFlowMessageFormat.allCases) { format in
                    let isSelected = selection.wrappedValue == format
                    Button {
                        withAnimation(.smooth(duration: 0.18)) {
                            selection.wrappedValue = format
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: format == .plainText ? "text.alignleft" : "rectangle.fill")
                                .font(.caption.weight(.semibold))
                            Text(format.displayName)
                                .font(.caption.weight(.semibold))
                        }
                        .frame(minWidth: 112)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .foregroundStyle(isSelected ? Color.primary : .secondary)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(.thinMaterial)
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .fill(Color.accentColor.opacity(0.16))
                                    )
                                    .matchedGeometryEffect(id: "welcomeFlowFormatSelection", in: formatSelectorNamespace)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(format.displayName)
                }
            }
            .padding(3)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

private struct WelcomeFlowPickerOption: Identifiable, Hashable {
    let id: String
    let label: String
}

private struct WelcomeFlowEditTarget: Identifiable, Hashable {
    enum Kind: String, Hashable, CaseIterable {
        case publicGreeting
        case directMessage
        case inviteRoles
        case safety
        case goodbye

        static var defaultOrder: [Kind] {
            [.publicGreeting, .directMessage, .inviteRoles, .safety, .goodbye]
        }
    }

    let kind: Kind
    var id: String { kind.rawValue }
}

private enum WelcomeFlowTemplatePreset: Hashable {
    case publicGreeting
    case publicEmbed
    case directMessage
    case inviteRoles
    case safety
    case goodbye

    var target: WelcomeFlowEditTarget.Kind {
        switch self {
        case .publicGreeting, .publicEmbed:
            return .publicGreeting
        case .directMessage:
            return .directMessage
        case .inviteRoles:
            return .inviteRoles
        case .safety:
            return .safety
        case .goodbye:
            return .goodbye
        }
    }
}

private struct WelcomeFlowRuleDescriptor: Identifiable {
    let order: Int
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let isEnabled: Bool
    let isVisible: Bool
    let target: WelcomeFlowEditTarget.Kind

    var id: String { target.rawValue }
}

private struct WelcomeFlowGlassButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 5 : 7)
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(configuration.isPressed ? 0.22 : 0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(configuration.isPressed ? 0.01 : 0.035), radius: 4, y: 2)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct WelcomeFlowIconButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(
                Circle()
                    .fill(configuration.isPressed ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial))
            )
            .overlay(
                Circle()
                    .strokeBorder(tint.opacity(configuration.isPressed ? 0.22 : 0.10), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

private struct WelcomeFlowRuleRow: View {
    @Binding var rule: WelcomeFlowRule
    let inviteSnapshots: [WelcomeFlowService.InviteSnapshot]
    let roleOptions: [WelcomeFlowPickerOption]
    let roleName: String
    let onInviteSelected: (String) -> Void
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
                .buttonStyle(WelcomeFlowIconButtonStyle(tint: .red))
                .help("Delete rule")
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("INVITE")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Picker("", selection: inviteCodeBinding) {
                        Text("Any invite").tag("")
                        if !rule.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           !inviteSnapshots.contains(where: { $0.code.caseInsensitiveCompare(rule.inviteCode) == .orderedSame }) {
                            Text("Custom: \(rule.inviteCode)").tag(rule.inviteCode)
                        }
                        ForEach(inviteSnapshots, id: \.code) { invite in
                            Text(inviteLabel(invite)).tag(invite.code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .help("Choose a Discord invite SwiftBot can see, or leave as Any invite.")
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

    private var inviteCodeBinding: Binding<String> {
        Binding(
            get: { rule.inviteCode },
            set: { newValue in
                rule.inviteCode = newValue
                rule.updatedAt = Date()
                onInviteSelected(newValue)
                onSave()
            }
        )
    }

    private func inviteLabel(_ invite: WelcomeFlowService.InviteSnapshot) -> String {
        let channel = invite.channelName
            .map { "#\($0)" }
            ?? invite.channelID.map { "Channel \($0.suffix(4))" }
            ?? "Unknown channel"
        let uses = invite.uses == 1 ? "1 use" : "\(invite.uses) uses"
        return "\(channel) - discord.gg/\(invite.code) - \(uses)"
    }
}
