import SwiftUI

struct WelcomeFlowView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case greeting, dm, safety, goodbye, nextSteps
        var id: String { rawValue }
        var title: String {
            switch self {
            case .greeting: return "Greeting"
            case .dm: return "DM"
            case .safety: return "Safety"
            case .goodbye: return "Goodbye"
            case .nextSteps: return "Next Steps"
            }
        }
        var symbol: String {
            switch self {
            case .greeting: return "person.crop.circle.badge.plus"
            case .dm: return "envelope.fill"
            case .safety: return "shield.lefthalf.filled"
            case .goodbye: return "door.left.hand.open"
            case .nextSteps: return "map.fill"
            }
        }
    }

    @EnvironmentObject private var app: AppModel
    @AppStorage("swiftbot.welcomeFlow.selectedTab") private var selectedTab: Tab = .greeting
    @State private var selectedGuildID: String = ""
    @State private var testSendInFlight: Bool = false
    @State private var testSendFeedback: String?
    @State private var showPreviewSheet: Bool = false
    @State private var inviteRefreshInFlight: Bool = false
    @State private var inviteRefreshFeedback: String?
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
                metrics
                tabbedCard
            }
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showPreviewSheet) {
            previewSheet
        }
        .onAppear(perform: syncSelectedGuild)
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
            Button {
                showPreviewSheet = true
            } label: {
                Label("Preview", systemImage: "text.bubble")
            }
            .buttonStyle(WelcomeFlowGlassButtonStyle())
        }
    }

    private var tabbedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabBar
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 6)
            Divider()
                .opacity(0.5)
            activeSection
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    @ViewBuilder
    private var activeSection: some View {
        Group {
            switch selectedTab {
            case .greeting: greetingSection
            case .dm: dmSection
            case .safety: safetySection
            case .goodbye: goodbyeSection
            case .nextSteps: roadmapSection
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.995)))
        .id(selectedTab)
        .animation(.easeInOut(duration: 0.16), value: selectedTab)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { tab in
                tabPill(tab)
            }
            Spacer(minLength: 0)
        }
    }

    private func tabPill(_ tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.caption2.weight(.semibold))
                Text(tab.title)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.white : .secondary)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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

                HStack(alignment: .top, spacing: 14) {
                    pickerField(label: "Server", selection: $selectedGuildID, options: serverOptions) { newValue in
                        let channels = app.availableTextChannelsByServer[newValue] ?? []
                        if !channels.contains(where: { $0.id == app.settings.welcomeFlow.publicChannelId }) {
                            app.settings.welcomeFlow.publicChannelId = defaultWelcomeChannelID(for: newValue) ?? channels.first?.id ?? ""
                            saveSettingsAfterViewUpdate()
                        }
                    }
                    pickerField(label: "Channel", selection: selectedChannelID, options: textChannelOptions) { _ in }
                }

                messageFormatSelector("Message style", selection: publicMessageFormat)

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
