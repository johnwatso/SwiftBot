import SwiftUI

private enum RemoteSection: String, CaseIterable, Identifiable {
    case status = "Status"
    case rules = "Rules"
    case events = "Events"
    case settings = "Settings"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .status:
            return "waveform.path.ecg"
        case .rules:
            return "slider.horizontal.3"
        case .events:
            return "list.bullet.rectangle.portrait"
        case .settings:
            return "gearshape.2"
        }
    }
}

private struct RemoteSettingsDraft: Equatable {
    var commandsEnabled = true
    var prefixCommandsEnabled = true
    var slashCommandsEnabled = true
    var bugTrackingEnabled = true
    var prefix = "/"
    var localAIDMReplyEnabled = false
    var preferredProvider = AIProviderPreference.apple.rawValue
    var openAIEnabled = false
    var openAIModel = ""
    var openAIImageGenerationEnabled = false
    var openAIImageMonthlyLimitPerUser = 0
    var wikiBridgeEnabled = false
    var patchyMonitoringEnabled = false
    var clusterMode = ClusterMode.standalone.rawValue
    var clusterNodeName = ""
    var clusterLeaderAddress = ""
    var clusterListenPort = 38787
    var clusterOffloadAIReplies = false
    var clusterOffloadWikiLookups = false
    var autoStart = false

    init() {}

    init(payload: AdminWebConfigPayload) {
        commandsEnabled = payload.commands.enabled
        prefixCommandsEnabled = payload.commands.prefixEnabled
        slashCommandsEnabled = payload.commands.slashEnabled
        bugTrackingEnabled = payload.commands.bugTrackingEnabled
        prefix = payload.commands.prefix
        localAIDMReplyEnabled = payload.aiBots.localAIDMReplyEnabled
        preferredProvider = payload.aiBots.preferredProvider
        openAIEnabled = payload.aiBots.openAIEnabled
        openAIModel = payload.aiBots.openAIModel
        openAIImageGenerationEnabled = payload.aiBots.openAIImageGenerationEnabled
        openAIImageMonthlyLimitPerUser = payload.aiBots.openAIImageMonthlyLimitPerUser
        wikiBridgeEnabled = payload.wikiBridge.enabled
        patchyMonitoringEnabled = payload.patchy.monitoringEnabled
        clusterMode = payload.swiftMesh.mode
        clusterNodeName = payload.swiftMesh.nodeName
        clusterLeaderAddress = payload.swiftMesh.leaderAddress
        clusterListenPort = payload.swiftMesh.listenPort
        clusterOffloadAIReplies = payload.swiftMesh.offloadAIReplies
        clusterOffloadWikiLookups = payload.swiftMesh.offloadWikiLookups
        autoStart = payload.general.autoStart
    }

    var patch: AdminWebConfigPatch {
        AdminWebConfigPatch(
            commandsEnabled: commandsEnabled,
            prefixCommandsEnabled: prefixCommandsEnabled,
            slashCommandsEnabled: slashCommandsEnabled,
            bugTrackingEnabled: bugTrackingEnabled,
            prefix: prefix,
            localAIDMReplyEnabled: localAIDMReplyEnabled,
            preferredAIProvider: preferredProvider,
            openAIEnabled: openAIEnabled,
            openAIModel: openAIModel,
            openAIImageGenerationEnabled: openAIImageGenerationEnabled,
            openAIImageMonthlyLimitPerUser: openAIImageMonthlyLimitPerUser,
            wikiBridgeEnabled: wikiBridgeEnabled,
            patchyMonitoringEnabled: patchyMonitoringEnabled,
            clusterMode: clusterMode,
            clusterNodeName: clusterNodeName,
            clusterLeaderAddress: clusterLeaderAddress,
            clusterListenPort: clusterListenPort,
            clusterOffloadAIReplies: clusterOffloadAIReplies,
            clusterOffloadWikiLookups: clusterOffloadWikiLookups,
            autoStart: autoStart
        )
    }
}

struct RemoteModeRootView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var remoteService = RemoteControlService()
    @State private var selection: RemoteSection = .status
    @State private var showingConnectionSheet = false
    @State private var selectedRuleID: UUID?
    @State private var ruleEditorText = ""
    @State private var settingsDraft = RemoteSettingsDraft()
    @State private var isSavingRule = false
    @State private var isSavingSettings = false

    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .background(SwiftBotGlassBackground())
        .toolbar {
            toolbarContent
        }
        .sheet(isPresented: $showingConnectionSheet, content: connectionSheet)
        .onAppear {
            remoteService.updateConfiguration(app.settings.remoteMode)
            if app.settings.remoteMode.isConfigured {
                remoteService.startMonitoring()
            }
        }
        .onDisappear {
            remoteService.stopMonitoring()
        }
        .onChange(of: app.settings.remoteMode) { _, newValue in
            remoteService.updateConfiguration(newValue)
            if newValue.isConfigured {
                remoteService.startMonitoring()
            } else {
                remoteService.stopMonitoring()
            }
        }
        .onChange(of: remoteService.rulesPayload?.fetchedAt) { _, _ in
            syncRuleSelection()
        }
        .onChange(of: selectedRuleID) { _, _ in
            restoreSelectedRule()
        }
        .onChange(of: remoteService.settingsPayload?.general.webUIBaseURL) { _, _ in
            if let payload = remoteService.settingsPayload {
                settingsDraft = RemoteSettingsDraft(payload: payload)
            }
        }
    }

    private var sidebarView: some View {
        List(selection: $selection) {
            ForEach(RemoteSection.allCases) { section in
                Label(section.rawValue, systemImage: section.symbolName)
                    .tag(section)
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        .scrollContentBackground(.hidden)
        .background(.clear)
    }

    private var detailView: some View {
        Group {
            if !remoteService.configuration.isConfigured {
                RemoteDisconnectedStateView {
                    showingConnectionSheet = true
                }
            } else {
                selectedSectionView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SwiftBotGlassBackground())
    }

    @ViewBuilder
    private var selectedSectionView: some View {
        switch selection {
        case .status:
            statusView
        case .rules:
            rulesView
        case .events:
            eventsView
        case .settings:
            settingsView
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Connection") {
                showingConnectionSheet = true
            }

            Button {
                Task { await remoteService.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!remoteService.configuration.isConfigured || remoteService.isRefreshing)
        }
    }

    @ViewBuilder
    private func connectionSheet() -> some View {
        RemoteConnectionEditorView(initialConfiguration: app.settings.remoteMode) { configuration in
            app.updateRemoteModeConnection(
                primaryNodeAddress: configuration.primaryNodeAddress,
                accessToken: configuration.accessToken
            )
            remoteService.updateConfiguration(configuration)
            Task { await remoteService.refreshAll() }
            showingConnectionSheet = false
        }
    }

    private var statusView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                remoteErrorBanner

                PreferencesCard(
                    "Connection",
                    systemImage: "dot.radiowaves.left.and.right",
                    subtitle: "Remote Control Mode talks only to the primary node API. No local Discord gateway or SwiftMesh runtime is started on this Mac."
                ) {
                    HStack(spacing: 18) {
                        RemoteMetricTile(
                            title: "Primary Node",
                            value: remoteService.configuration.normalizedPrimaryNodeAddress.isEmpty
                                ? "Not configured"
                                : remoteService.configuration.normalizedPrimaryNodeAddress,
                            accent: .cyan
                        )
                        RemoteMetricTile(
                            title: "Connection",
                            value: remoteService.connectionState.rawValue.capitalized,
                            accent: remoteService.connectionState == .connected ? .green : .orange
                        )
                        RemoteMetricTile(
                            title: "Latency",
                            value: remoteService.lastLatencyMs.map {
                                "\($0.formatted(.number.precision(.fractionLength(0)))) ms"
                            } ?? "--",
                            accent: .blue
                        )
                    }
                }

                PreferencesCard("Primary Status", systemImage: "server.rack") {
                    let payload = remoteService.status
                    LazyVGrid(columns: [.init(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                        RemoteMetricTile(title: "Bot", value: payload?.botStatus.capitalized ?? "--", accent: .green)
                        RemoteMetricTile(title: "Identity", value: payload?.botUsername ?? "SwiftBot", accent: .blue)
                        RemoteMetricTile(title: "Node Role", value: payload?.nodeRole.capitalized ?? "--", accent: .orange)
                        RemoteMetricTile(title: "Leader", value: payload?.leaderName ?? "--", accent: .mint)
                        RemoteMetricTile(title: "Servers", value: payload.map { "\($0.connectedServerCount)" } ?? "--", accent: .indigo)
                        RemoteMetricTile(title: "Gateway Events", value: payload.map { "\($0.gatewayEventCount)" } ?? "--", accent: .purple)
                        RemoteMetricTile(title: "Uptime", value: payload?.uptimeText ?? "--", accent: .teal)
                        RemoteMetricTile(title: "Mode", value: payload?.clusterMode ?? "--", accent: .pink)
                    }
                }
            }
            .padding(24)
        }
    }

    private var rulesView: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Rules")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        createDraftRule()
                    } label: {
                        Label("New Rule", systemImage: "plus")
                    }
                }

                if let payload = remoteService.rulesPayload {
                    List(payload.rules, selection: $selectedRuleID) { rule in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(rule.name)
                                    .font(.headline)
                                Spacer()
                                Circle()
                                    .fill(rule.isEnabled ? Color.green : Color.secondary)
                                    .frame(width: 8, height: 8)
                            }
                            Text(rule.trigger?.rawValue ?? "No trigger")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(rule.id)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                } else {
                    ContentUnavailableView("No Rules Loaded", systemImage: "slider.horizontal.3")
                }
            }
            .frame(minWidth: 260, idealWidth: 300)
            .padding(20)
            .glassCard()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Rule Editor")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Restore") {
                        restoreSelectedRule()
                    }
                    .disabled(selectedRule() == nil)

                    Button {
                        Task { await saveEditedRule() }
                    } label: {
                        if isSavingRule {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Save Rule", systemImage: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(GlassActionButtonStyle())
                    .disabled(ruleEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingRule)
                }

                Text("Rules are edited as JSON and saved back through `/api/remote/rules/update`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $ruleEditorText)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    )
            }
            .padding(20)
            .glassCard()
        }
        .padding(24)
    }

    private var eventsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                remoteErrorBanner

                PreferencesCard("Activity Events", systemImage: "waveform.path.ecg") {
                    if let payload = remoteService.eventsPayload, !payload.activity.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(payload.activity) { event in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 90, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.kind.capitalized)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Text(event.message)
                                            .font(.body)
                                    }
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView("No Recent Events", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }

                PreferencesCard("Recent Logs", systemImage: "list.bullet.rectangle.portrait") {
                    if let logs = remoteService.eventsPayload?.logs, !logs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 2)
                            }
                        }
                    } else {
                        ContentUnavailableView("No Recent Logs", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            .padding(24)
        }
    }

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                remoteErrorBanner

                PreferencesCard("Automation", systemImage: "terminal") {
                    Toggle("Enable Commands", isOn: $settingsDraft.commandsEnabled)
                    Toggle("Enable Prefix Commands", isOn: $settingsDraft.prefixCommandsEnabled)
                    Toggle("Enable Slash Commands", isOn: $settingsDraft.slashCommandsEnabled)
                    Toggle("Enable Bug Tracking", isOn: $settingsDraft.bugTrackingEnabled)
                    Toggle("Auto Start Bot", isOn: $settingsDraft.autoStart)
                    TextField("Command Prefix", text: $settingsDraft.prefix)
                }

                PreferencesCard("AI + Integrations", systemImage: "sparkles.rectangle.stack.fill") {
                    Toggle("Enable Local AI DM Replies", isOn: $settingsDraft.localAIDMReplyEnabled)
                    Picker("Preferred Provider", selection: $settingsDraft.preferredProvider) {
                        ForEach(AIProviderPreference.allCases, id: \.rawValue) { provider in
                            Text(provider.rawValue).tag(provider.rawValue)
                        }
                    }
                    Toggle("Enable OpenAI", isOn: $settingsDraft.openAIEnabled)
                    TextField("OpenAI Model", text: $settingsDraft.openAIModel)
                    Toggle("Enable Image Generation", isOn: $settingsDraft.openAIImageGenerationEnabled)
                    Stepper(
                        value: $settingsDraft.openAIImageMonthlyLimitPerUser,
                        in: 0...500
                    ) {
                        Text("Monthly Image Limit Per User: \(settingsDraft.openAIImageMonthlyLimitPerUser)")
                    }
                    Toggle("Enable WikiBridge", isOn: $settingsDraft.wikiBridgeEnabled)
                    Toggle("Enable Patchy Monitoring", isOn: $settingsDraft.patchyMonitoringEnabled)
                }

                PreferencesCard("SwiftMesh", systemImage: "point.3.connected.trianglepath.dotted") {
                    Picker("Mode", selection: $settingsDraft.clusterMode) {
                        ForEach(ClusterMode.selectableCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    TextField("Node Name", text: $settingsDraft.clusterNodeName)
                    TextField("Leader Address", text: $settingsDraft.clusterLeaderAddress)
                    Stepper(value: $settingsDraft.clusterListenPort, in: 1...65535) {
                        Text("Listen Port: \(settingsDraft.clusterListenPort)")
                    }
                    Toggle("Offload AI Replies", isOn: $settingsDraft.clusterOffloadAIReplies)
                    Toggle("Offload Wiki Lookups", isOn: $settingsDraft.clusterOffloadWikiLookups)
                }

                HStack {
                    Spacer()
                    Button {
                        if let payload = remoteService.settingsPayload {
                            settingsDraft = RemoteSettingsDraft(payload: payload)
                        }
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }

                    Button {
                        Task { await saveSettingsDraft() }
                    } label: {
                        if isSavingSettings {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Save Remote Settings", systemImage: "square.and.arrow.down.fill")
                        }
                    }
                    .buttonStyle(GlassActionButtonStyle())
                    .disabled(isSavingSettings)
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var remoteErrorBanner: some View {
        if let error = remoteService.lastError, !error.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func syncRuleSelection() {
        let rules = remoteService.rulesPayload?.rules ?? []
        guard !rules.isEmpty else {
            selectedRuleID = nil
            ruleEditorText = ""
            return
        }

        if let selectedRuleID,
           rules.contains(where: { $0.id == selectedRuleID }) {
            return
        }

        selectedRuleID = rules.first?.id
        if let rule = rules.first {
            ruleEditorText = encodeRule(rule)
        }
    }

    private func selectedRule() -> Rule? {
        remoteService.rulesPayload?.rules.first(where: { $0.id == selectedRuleID })
    }

    private func restoreSelectedRule() {
        guard let rule = selectedRule() else { return }
        ruleEditorText = encodeRule(rule)
    }

    private func createDraftRule() {
        var rule = Rule.empty()
        rule.name = "Remote Rule"
        selectedRuleID = rule.id
        ruleEditorText = encodeRule(rule)
    }

    private func saveEditedRule() async {
        guard let rule = decodeRule(from: ruleEditorText) else {
            remoteService.lastError = "The rule JSON is invalid."
            return
        }

        isSavingRule = true
        defer { isSavingRule = false }
        let didSave = await remoteService.upsertRule(rule)
        if didSave {
            selectedRuleID = rule.id
        }
    }

    private func saveSettingsDraft() async {
        isSavingSettings = true
        defer { isSavingSettings = false }
        _ = await remoteService.updateSettings(settingsDraft.patch)
    }

    private func encodeRule(_ rule: Rule) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(rule)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func decodeRule(from json: String) -> Rule? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Rule.self, from: data)
    }
}

private struct RemoteMetricTile: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accent.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct RemoteDisconnectedStateView: View {
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Configure Remote Control")
                .font(.title2.weight(.semibold))
            Text("Add the primary node address and bearer token to manage SwiftBot remotely.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(action: onConnect) {
                Label("Open Connection Setup", systemImage: "link.badge.plus")
            }
            .buttonStyle(GlassActionButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RemoteConnectionEditorView: View {
    @State private var address: String
    @State private var accessToken: String
    @State private var showToken = false
    @StateObject private var tester: RemoteControlService

    let onSave: (RemoteModeSettings) -> Void

    init(initialConfiguration: RemoteModeSettings, onSave: @escaping (RemoteModeSettings) -> Void) {
        _address = State(initialValue: initialConfiguration.primaryNodeAddress)
        _accessToken = State(initialValue: initialConfiguration.accessToken)
        _tester = StateObject(wrappedValue: RemoteControlService(configuration: initialConfiguration))
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Remote Setup")
                .font(.title2.weight(.semibold))

            TextField("https://mybot.example.com", text: $address)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Group {
                    if showToken {
                        TextField("Access Token", text: $accessToken)
                    } else {
                        SecureField("Access Token", text: $accessToken)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

                Button {
                    showToken.toggle()
                } label: {
                    Image(systemName: showToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
            }

            if let error = tester.lastError, !error.isEmpty {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if let latency = tester.lastLatencyMs, tester.connectionState == .connected {
                Text("Connected in \(latency.formatted(.number.precision(.fractionLength(0)))) ms")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button {
                    let configuration = currentConfiguration()
                    tester.updateConfiguration(configuration)
                    Task { _ = await tester.testConnection() }
                } label: {
                    if tester.isTestingConnection {
                        ProgressView()
                    } else {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(!currentConfiguration().isConfigured || tester.isTestingConnection)

                Button {
                    onSave(currentConfiguration())
                } label: {
                    Label("Save", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(GlassActionButtonStyle())
                .disabled(!currentConfiguration().isConfigured)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(SwiftBotGlassBackground())
    }

    private func currentConfiguration() -> RemoteModeSettings {
        var configuration = RemoteModeSettings(primaryNodeAddress: address, accessToken: accessToken)
        configuration.normalize()
        return configuration
    }
}
