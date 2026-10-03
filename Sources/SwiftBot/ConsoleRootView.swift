import AppKit
import SwiftUI

struct ConsoleRootView: View {
    @EnvironmentObject private var app: AppModel
    @State private var selection: ConsoleItem = .thisMac
    @State private var macPane: MacPane = .overview

    enum MacPane: String, CaseIterable, Identifiable {
        case overview = "Overview", settings = "Settings", storage = "Storage"
        var id: String { rawValue }
    }

    private func makeHealth() -> OverviewHealthReport {
        OverviewHealthReport(.init(
            status: app.status, settings: app.settings, events: app.events,
            commandLog: app.commandLog, rules: app.ruleStore.rules, clusterNodes: app.clusterNodes,
            clusterSnapshot: app.clusterSnapshot, diagnostics: app.connectionDiagnostics,
            lastGatewayEventName: app.lastGatewayEventName, intentsAccepted: app.intentsAccepted,
            lastVoiceStateAt: app.lastVoiceStateAt, lastClusterStatusSuccessAt: app.lastClusterStatusSuccessAt,
            patchyLastCycleAt: app.patchyLastCycleAt, patchyIsCycleRunning: app.patchyIsCycleRunning,
            memoryText: OverviewHealthReport.memoryText(samples: [OverviewHealthReport.residentMemoryBytes()])
        ))
    }

    var body: some View {
        // Built once per render: the sidebar badge and the Alerts pane share it.
        let health = makeHealth()
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(ConsoleItem.sidebarSections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            Label(item.rawValue, systemImage: item.icon)
                                .badge(sidebarBadge(for: item, alertCount: health.attention.count))
                                .tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detailContent(health: health)
                .id(selection)
                .navigationTitle(selection == .thisMac ? hostName : selection.rawValue)
                .navigationSubtitle(subtitle(health: health))
                .toolbar { toolbarContent }
        }
        .autosavesPreferences(for: app)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if selection == .logs {
                Button("Export Logs…", systemImage: "square.and.arrow.up") {
                    Task { await LogExporter.presentSavePanel(app: app) }
                }
            }
            Button(app.consoleServiceRunning ? "Stop" : "Start",
                   systemImage: app.consoleServiceRunning ? "stop.fill" : "play.fill") {
                Task { if app.consoleServiceRunning { await app.stopBot() } else { await app.startBot() } }
            }
            .help(app.consoleServiceRunning ? "Stop SwiftBot on this Mac" : "Start SwiftBot on this Mac")
            .disabled(app.isRemoteLaunchMode || app.isFailoverManagedNode)

            Button("Open in Browser", systemImage: "safari") {
                app.openWebUI(route: selection.webRoute)
            }
            .labelStyle(.titleAndIcon)
            .help("Open \(selection.rawValue) in the web UI")
            .disabled(!app.settings.adminWebUI.enabled)
        }
    }

    private var hostName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    private func subtitle(health: OverviewHealthReport) -> String {
        switch selection {
        case .thisMac: "SwiftBot \(Self.appVersion)"
        case .access: "Credentials and web UI sign-in"
        case .logs: "Live activity on this Mac"
        case .alerts: health.attention.isEmpty ? "No issues" : "\(health.attention.count) need attention"
        default: ConsoleServiceState(item: selection, app: app).summary
        }
    }

    private func sidebarBadge(for item: ConsoleItem, alertCount: Int) -> Text? {
        if item == .alerts { return alertCount > 0 ? Text("\(alertCount)") : nil }
        guard item.isService else { return nil }
        return ConsoleServiceState(item: item, app: app).isOff ? Text("Off") : nil
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    // MARK: - Detail

    @ViewBuilder private func detailContent(health: OverviewHealthReport) -> some View {
        if selection.isService {
            ConsoleServicePane(item: selection, showLogs: { selection = .logs })
        } else if selection == .logs {
            // The log owns its scroll view, search and filters. Do not nest it in a Form.
            ActivityLogView()
        } else if selection == .thisMac {
            VStack(spacing: 0) {
                Picker("Pane", selection: $macPane) {
                    ForEach(MacPane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 16)
                Form { thisMacContent }
                    .formStyle(.grouped)
                    .environment(\.consoleFormContent, true)
            }
        } else {
            Form { serverContent(health: health) }
                .formStyle(.grouped)
                .environment(\.consoleFormContent, true)
        }
    }

    @ViewBuilder private var thisMacContent: some View {
        switch macPane {
        case .overview:
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SwiftBot").font(.headline)
                        Text(uptimeText).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ConsoleStatusLabel(text: app.primaryServiceStatusText, healthy: app.primaryServiceIsOnline)
                }
                .padding(.vertical, 4)
            }
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "safari").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manage SwiftBot in Your Browser").font(.headline)
                        Text("Commands, automations, moderation, Rewind and more live in the web UI.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Open in Browser") { app.openWebUI() }
                        .disabled(!app.settings.adminWebUI.enabled)
                }
                .padding(.vertical, 4)
            }
            Section("Status") {
                LabeledContent("Servers", value: String(app.connectedServers.count))
                LabeledContent("Gateway Latency", value: app.connectionDiagnostics.heartbeatLatencyMs.map { "\($0) ms" } ?? "—")
                LabeledContent("Mesh Nodes", value: String(app.clusterNodes.count))
                LabeledContent("Memory", value: OverviewHealthReport.memoryText(samples: [OverviewHealthReport.residentMemoryBytes()]))
            }
            Section {
                LabeledContent("Host Name", value: hostName)
                LabeledContent("Web UI Address", value: app.settings.adminWebUI.enabled ? app.adminWebBaseURL() : "Off")
                LabeledContent("Bot Account", value: app.resolvedBotUsername)
                LabeledContent("Hardware", value: MacHardwareInfo.summary)
            } header: { Text("Network") }
        case .settings:
            GeneralPreferencesView(consolePane: "settings").id(macPane)
            IntegrationsSettingsView().disabled(app.isFailoverManagedNode || app.runtimeClusterMode == .worker)
        case .storage:
            GeneralPreferencesView(consolePane: "storage").id(macPane)
        }
    }

    private var uptimeText: String {
        let mode = app.runtimeClusterMode.displayName
        guard let started = app.uptime?.startedAt else { return "Version \(Self.appVersion) · \(mode)" }
        let up = Date().timeIntervalSince(started)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = up >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return "Version \(Self.appVersion) · \(mode) · Up \(formatter.string(from: up) ?? "")"
    }

    @ViewBuilder private func serverContent(health: OverviewHealthReport) -> some View {
        switch selection {
        case .access:
            GeneralPreferencesView(consolePane: "access")
                .disabled(app.runtimeClusterMode == .worker)
            Section { AdminWebAuthenticationSection() }
                .disabled(app.isFailoverManagedNode || app.runtimeClusterMode == .worker)
            Section {
                LabeledContent("Operators") {
                    Button("Manage in Browser") { app.openWebUI(route: "/settings/operator") }
                        .disabled(!app.settings.adminWebUI.enabled)
                }
            } footer: { Text("Operator assignments and web access rules are managed in the web UI.") }
        case .alerts:
            Section {
                if health.attention.isEmpty {
                    Label("No warnings", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(health.attention) { item in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                            Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: item.severity.symbol)
                            .foregroundStyle(item.severity == .critical ? .red : .orange)
                    }
                    .padding(.vertical, 2)
                }
            } header: { Text("Health Warnings") } footer: {
                Text("Warnings use the same health checks as Overview and the web UI.")
            }
        default: EmptyView()
        }
    }
}

// MARK: - Service state

private extension AppModel {
    /// Whether this Mac's bot (or worker) process is running. Drives the toolbar Start/Stop.
    var consoleServiceRunning: Bool {
        settings.clusterMode == .worker ? isWorkerServiceRunning : status != .stopped
    }
}

/// Read-only status for one service, shared by the sidebar badge, toolbar subtitle and pane.
@MainActor
private struct ConsoleServiceState {
    let item: ConsoleItem
    let app: AppModel

    var summary: String {
        switch item {
        case .adminWeb: app.settings.adminWebUI.enabled ? app.adminWebBaseURL() : "Off"
        case .gateway: app.runtimeClusterMode == .worker ? "Not used on worker nodes" : app.primaryServiceStatusText
        case .swiftMesh: app.settings.clusterMode == .standalone ? "Off" : app.runtimeClusterMode.displayName
        case .voice: app.voiceConnectionStatus.displayLabel
        case .recordings:
            app.mediaLibrarySettings.sources.contains(where: \.isEnabled)
                ? "\(app.mediaLibrarySettings.sources.filter(\.isEnabled).count) folders monitored" : "Off"
        case .intelligence: app.appleIntelligenceOnline ? "Available" : "Unavailable"
        case .updates: "Version \(ConsoleRootView.appVersion)"
        default: ""
        }
    }

    var isHealthy: Bool {
        switch item {
        case .adminWeb: app.settings.adminWebUI.enabled && !app.adminWebResolvedBaseURL.isEmpty
        case .gateway: app.primaryServiceIsOnline && app.runtimeClusterMode != .worker
        case .swiftMesh: app.settings.clusterMode != .standalone && app.consoleServiceRunning
        case .voice: app.voiceConnectionStatus.isConnected
        case .recordings: !isOff
        case .intelligence: app.appleIntelligenceOnline
        case .updates: true
        default: false
        }
    }

    /// Only services with a real on/off state report "Off" in the sidebar.
    var isOff: Bool {
        switch item {
        case .adminWeb: !app.settings.adminWebUI.enabled
        case .swiftMesh: app.settings.clusterMode == .standalone
        case .recordings: !app.mediaLibrarySettings.sources.contains(where: \.isEnabled)
        default: false
        }
    }
}

// MARK: - Service pane

/// Every service pane has the same shape: an identity row (with a switch only when the
/// service has its own on/off state), a short essentials section, then Show Logs,
/// Advanced… and Open in Browser. Full preference forms live behind Advanced….
private struct ConsoleServicePane: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var updater: AppUpdater
    let item: ConsoleItem
    let showLogs: () -> Void
    @State private var showingPermissions = false
    @State private var showingAdvanced = false

    private var state: ConsoleServiceState { ConsoleServiceState(item: item, app: app) }
    private var primaryOnly: Bool {
        app.isFailoverManagedNode || app.runtimeClusterMode == .worker || app.isRemoteLaunchMode
    }

    /// Services whose switch means exactly "this service on or off". The gateway and
    /// SwiftMesh run with the bot itself, so they use the toolbar Start/Stop instead.
    private var serviceSwitch: Binding<Bool>? {
        switch item {
        case .adminWeb:
            return Binding(get: { app.settings.adminWebUI.enabled },
                           set: { app.settings.adminWebUI.enabled = $0 })
        case .voice:
            return Binding(get: { app.voiceConnectionStatus.isConnected }, set: { value in
                Task { if value { await app.connectVoice() } else { _ = await app.adminWebDisconnectAnnouncer() } }
            })
        case .recordings:
            guard !app.mediaLibrarySettings.sources.isEmpty else { return nil }
            return Binding(get: { app.mediaLibrarySettings.sources.contains(where: \.isEnabled) }, set: { value in
                for index in app.mediaLibrarySettings.sources.indices {
                    app.mediaLibrarySettings.sources[index].isEnabled = value
                }
            })
        default:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.rawValue).font(.headline)
                            Text(serviceDescription).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if let serviceSwitch {
                            Toggle(item.rawValue, isOn: serviceSwitch)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(primaryOnly)
                        } else {
                            ConsoleStatusLabel(text: state.summary, healthy: state.isHealthy)
                        }
                    }
                    .padding(.vertical, 2)
                } footer: {
                    if let note = switchNote { Text(note) }
                }
                essentials
            }
            .formStyle(.grouped)
            .environment(\.consoleFormContent, true)

            Divider()
            HStack {
                Button("Show Logs", action: showLogs)
                Spacer()
                if hasAdvanced {
                    Button("Advanced…") { showingAdvanced = true }
                }
                Button("Open in Browser") { app.openWebUI(route: item.webRoute) }
                    .disabled(!app.settings.adminWebUI.enabled)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showingPermissions) { BotPermissionsCheckView(token: app.settings.token) }
        .sheet(isPresented: $showingAdvanced) {
            ConsoleAdvancedSheet(title: item.rawValue) { advancedContent }
                .environmentObject(app)
                .environmentObject(updater)
        }
    }

    private var serviceDescription: String {
        switch item {
        case .adminWeb: "Manage SwiftBot from any browser"
        case .gateway: "The connection between this Mac and Discord"
        case .swiftMesh: "Keep your bot available across several Macs"
        case .voice: "Voice announcements in your Discord channels"
        case .recordings: "Share recordings from folders on this Mac"
        case .intelligence: "On-device replies with Apple Intelligence"
        case .updates: "Keep SwiftBot up to date on this Mac"
        default: ""
        }
    }

    private var switchNote: String? {
        switch item {
        case .gateway, .swiftMesh: "Runs with SwiftBot. Use Start or Stop in the toolbar."
        case .voice: "Turning this off pauses automatic reconnection for one hour."
        case .recordings where app.mediaLibrarySettings.sources.isEmpty: "Add a recordings folder to turn this on."
        default: primaryOnly && serviceSwitch != nil ? "Managed by the primary node." : nil
        }
    }

    // MARK: Essentials

    @ViewBuilder private var essentials: some View {
        switch item {
        case .adminWeb:
            Section("Access") {
                LabeledContent("Address", value: state.summary)
                LabeledContent("Internet Access", value: app.settings.adminWebUI.internetAccessEnabled ? "On" : "Off")
                Toggle("Require HTTPS", isOn: $app.settings.adminWebUI.requireHTTPS)
                    .disabled(primaryOnly)
            }
            Section("Sign In") { AdminWebAuthenticationSection() }
                .disabled(primaryOnly)
        case .gateway:
            Section("Health") {
                LabeledContent("Status") { ConsoleStatusLabel(text: state.summary, healthy: state.isHealthy) }
                LabeledContent("Latency", value: app.connectionDiagnostics.heartbeatLatencyMs.map { "\($0) ms" } ?? "—")
                if let startedAt = app.uptime?.startedAt {
                    LabeledContent("Started", value: startedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Toggle("Start Automatically", isOn: $app.settings.autoStart).disabled(primaryOnly)
            }
            Section {
                LabeledContent("Bot Permissions") {
                    Button("Check…") { showingPermissions = true }
                        .disabled(primaryOnly || app.settings.token.isEmpty)
                }
            }
        case .swiftMesh:
            Section("Cluster") {
                LabeledContent("Role", value: app.runtimeClusterMode.displayName)
                LabeledContent("Nodes", value: String(app.clusterNodes.count))
                LabeledContent("Status") { ConsoleStatusLabel(text: app.consoleServiceRunning ? "Running" : "Stopped",
                                                              healthy: app.consoleServiceRunning) }
            }
        case .voice:
            Section("Voice") {
                LabeledContent("Status") { ConsoleStatusLabel(text: state.summary, healthy: state.isHealthy) }
                LabeledContent("Channel", value: app.settings.voice.voiceChannelID.isEmpty ? "None" : app.settings.voice.voiceChannelID)
                LabeledContent("Voice", value: app.settings.voice.preferredVoiceIdentifier.isEmpty ? "Automatic" : app.settings.voice.preferredVoiceIdentifier)
                Toggle("Connect Automatically", isOn: $app.settings.voice.autoConnect).disabled(primaryOnly)
            }
        case .recordings:
            LocalRecordingsPreferencesSection()
        case .intelligence:
            Section("Apple Intelligence") {
                LabeledContent("Model", value: app.appleIntelligenceModelName ?? "Unavailable")
                Toggle("Reply to Direct Messages", isOn: $app.settings.localAIDMReplyEnabled)
                    .disabled(primaryOnly)
            }
        case .updates:
            Section("Software Update") {
                LabeledContent("Current Version", value: ConsoleRootView.appVersion)
                Toggle("Check Automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                .disabled(primaryOnly || !updater.isConfigured)
                LabeledContent("Updates") {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        default: EmptyView()
        }
    }

    // MARK: Advanced

    private var hasAdvanced: Bool { [.adminWeb, .swiftMesh, .updates].contains(item) }

    @ViewBuilder private var advancedContent: some View {
        switch item {
        case .adminWeb: WebUIPreferencesView().disabled(primaryOnly)
        case .swiftMesh: MeshPreferencesView()
        case .updates: UpdatesPreferencesView()
        default: EmptyView()
        }
    }
}

/// Hosts a full preferences form for a service in a sheet.
private struct ConsoleAdvancedSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 640)
        .navigationTitle("\(title) Advanced Settings")
    }
}

/// A status value with a coloured indicator; the text itself stays secondary.
private struct ConsoleStatusLabel: View {
    let text: String
    let healthy: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(healthy ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
