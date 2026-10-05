import SwiftUI

struct DiscordPage: View {
    @EnvironmentObject private var app: AppModel
    @State private var isConfirmingStop = false
    @State private var isConfirmingRestart = false
    @State private var isTesting = false

    private var hasToken: Bool {
        !app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ConsoleSettingsPage(title: "Discord", subtitle: "Bot identity, connection, and server access.") {
            HStack(spacing: 12) {
                if app.status == .stopped {
                    Button("Start", systemImage: "play.fill") {
                        Task { await app.startBot() }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!hasToken)
                } else {
                    Button("Restart", systemImage: "arrow.clockwise") { isConfirmingRestart = true }
                        .buttonStyle(.glass)
                        .disabled(app.status == .connecting)
                    Button("Stop", systemImage: "stop.fill") { isConfirmingStop = true }
                        .buttonStyle(.glass)
                }
            }
        } summary: {
            if let status = app.consoleOverviewSnapshot[.discord] {
                ServiceSummaryCard(
                    kind: .discord,
                    status: status,
                    facts: [
                        ("Bot", app.resolvedBotUsername),
                        ("Role", app.settings.clusterMode.displayName),
                        ("Known Servers", String(app.connectedServers.count)),
                        ("Bot Token", hasToken ? "Configured" : "Not configured")
                    ],
                    footnote: app.isFailoverManagedNode ? "The Primary node manages Discord settings and sends messages." : nil
                )
            }
        } content: {
            DiscordPreferencesView()
            statusSections
        }
        .confirmationDialog("Stop \(app.resolvedBotUsername)?", isPresented: $isConfirmingStop) {
            Button(app.settings.clusterMode == .standby ? "Stop Failover Watch" : "Stop Bot", role: .destructive) {
                Task { await app.stopBot() }
            }
        } message: {
            Text(app.settings.clusterMode == .standby
                 ? "This Mac stops watching the Primary and won’t take over if the Primary goes down."
                 : "The bot disconnects from Discord and leaves voice channels. Commands, automations, and monitors pause until you start it again.")
        }
        .confirmationDialog("Restart \(app.resolvedBotUsername)?", isPresented: $isConfirmingRestart) {
            Button("Restart") {
                Task {
                    await app.stopBot()
                    await app.startBot()
                }
            }
        } message: {
            Text(app.settings.clusterMode == .leader
                 ? "SwiftBot disconnects briefly. A Fail Over node may take over while it restarts."
                 : "SwiftBot disconnects briefly and then reconnects.")
        }
    }

    /// Servers and diagnostics, as rows in the same section cards as the
    /// settings above them.
    private var statusSections: some View {
        SettingsForm {
            Section {
                if app.connectedServers.isEmpty {
                    ConsoleSettingRow(
                        title: "No servers yet",
                        symbol: "person.3",
                        subtitle: "Use Invite Bot to add SwiftBot to a server."
                    )
                } else {
                    ForEach(app.connectedServers.keys.sorted(), id: \.self) { id in
                        ConsoleSettingRow(
                            title: app.connectedServers[id] ?? id,
                            symbol: "person.3.fill",
                            imageURL: app.guildIconHashes[id].flatMap {
                                URL(string: "https://cdn.discordapp.com/icons/\(id)/\($0).png?size=64")
                            }
                        ) {
                            Text(id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text("Servers")
            } footer: {
                if app.status != .running || app.isFailoverManagedNode {
                    Text("Last known servers. Connect to Discord to refresh this list.")
                }
            }

            Section {
                ConsoleSettingRow(title: "Gateway Latency", symbol: "waveform.path.ecg") {
                    Text(app.connectionDiagnostics.heartbeatLatencyMs.map { "\($0) ms" } ?? "—")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let code = app.connectionDiagnostics.lastGatewayCloseCode {
                    ConsoleSettingRow(
                        title: "Gateway Closed (\(code))",
                        symbol: "exclamationmark.triangle",
                        symbolTint: .orange,
                        subtitle: ConnectionDiagnostics.gatewayCloseRemedy(for: code)
                    )
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    ConsoleSettingRow(
                        title: "Test Connection",
                        symbol: "antenna.radiowaves.left.and.right",
                        subtitle: testConnectionSubtitle
                    ) {
                        HStack(spacing: 8) {
                            Button("View Activity") { app.requestedSidebarItem = .activity }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                            Button(isTesting ? "Testing…" : "Test") {
                                isTesting = true
                                Task {
                                    await app.runTestConnection()
                                    isTesting = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .disabled(!hasToken || !app.canRunTestConnection || isTesting || app.isFailoverManagedNode)
                        }
                    }
                }
            } header: {
                Text("Diagnostics")
            }
        }
    }

    private var testConnectionSubtitle: String {
        if !isTesting && !app.canRunTestConnection {
            return "Wait a few seconds before testing again."
        }
        let message = app.connectionDiagnostics.lastTestMessage
        return message.isEmpty ? "Check that Discord accepts the bot token." : message
    }
}

// Sidebar pages for this Mac's services. Their settings used to be tabs in the
// Settings window; Settings now keeps only app-level preferences (General and
// Updates), and each service's configuration lives on its own sidebar page.

/// The header every console page shares with the Overview: a large title, a
/// one-line subtitle, and trailing controls.
struct ConsolePageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                heading
                Spacer(minLength: 24)
                accessory
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 16) {
                heading
                accessory
            }
        }
        .controlSize(.large)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension ConsolePageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A settings form shown as a sidebar page: the shared header, an optional
/// status card, then the form's sections as Overview-style cards
/// (`ConsoleFormStyle`), all on one scrolling page at the Overview's width.
/// It saves as it's edited, exactly as the Settings window does.
struct ConsoleSettingsPage<Accessory: View, Summary: View, Content: View>: View {
    @EnvironmentObject private var app: AppModel

    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var summary: Summary
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ConsolePageHeader(title: title, subtitle: subtitle) { accessory }
                        .padding(.bottom, 4)
                    summary
                    content
                        .environment(\.settingsFormPresentation, .console)
                }
                .padding(.horizontal, 36)
                .padding(.top, 32)
                .padding(.bottom, 40)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .environment(\.consolePageScroll, ConsolePageScroll(proxy: proxy))
        }
        .fadingEdges(top: 12, bottom: 20)
        .autosavesPreferences(for: app)
    }
}

extension ConsoleSettingsPage where Accessory == EmptyView, Summary == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, summary: { EmptyView() }, content: content)
    }
}

/// Scrolls a console page to a section, for "Show" and "Configure" buttons
/// that point further down the same page. Give the target an `.id(_:)`.
struct ConsolePageScroll {
    fileprivate var proxy: ScrollViewProxy?

    func callAsFunction(_ id: String) {
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy?.scrollTo(id, anchor: .top)
        }
    }
}

private struct ConsolePageScrollKey: EnvironmentKey {
    static var defaultValue: ConsolePageScroll { ConsolePageScroll(proxy: nil) }
}

extension EnvironmentValues {
    var consolePageScroll: ConsolePageScroll {
        get { self[ConsolePageScrollKey.self] }
        set { self[ConsolePageScrollKey.self] = newValue }
    }
}

/// A service's state at the top of its page, in the Overview's summary-card
/// style: icon, name and status pill, a line of context, a row of facts,
/// and quiet issue lines when something needs attention.
struct ServiceSummaryCard: View {
    let title: String
    var symbol: String
    var brandAsset: String?
    let health: ServiceHealth
    let summary: String
    let detail: String
    let facts: [(title: String, value: String)]
    var issues: [ConsoleServiceStatus] = []
    var footnote: String?
    /// The page section where each issue is fixed; Show scrolls there.
    var issueSections: [ConsoleServiceKind: String] = [:]

    init(
        kind: ConsoleServiceKind,
        status: ConsoleServiceStatus,
        facts: [(title: String, value: String)],
        issues: [ConsoleServiceStatus] = [],
        footnote: String? = nil,
        issueSections: [ConsoleServiceKind: String] = [:]
    ) {
        self.init(
            title: kind.title, symbol: kind.symbol, brandAsset: kind.brandAsset,
            health: status.health, summary: status.summary, detail: status.detail,
            facts: facts, issues: issues, footnote: footnote, issueSections: issueSections
        )
    }

    /// For a page whose subject isn't one of the Overview's services.
    init(
        title: String,
        symbol: String,
        brandAsset: String? = nil,
        health: ServiceHealth,
        summary: String,
        detail: String,
        facts: [(title: String, value: String)],
        issues: [ConsoleServiceStatus] = [],
        footnote: String? = nil,
        issueSections: [ConsoleServiceKind: String] = [:]
    ) {
        self.title = title
        self.symbol = symbol
        self.brandAsset = brandAsset
        self.health = health
        self.summary = summary
        self.detail = detail
        self.facts = facts
        self.issues = issues
        self.footnote = footnote
        self.issueSections = issueSections
    }

    @Environment(\.consolePageScroll) private var scroll

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 22) {
                ConsoleIconTile(
                    symbol: symbol,
                    brandAsset: brandAsset,
                    isActive: health != .disabled && health != .unavailable,
                    size: 64
                )

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            Text(title)
                                .font(.title2.weight(.semibold))
                            StatusBadge(health: health, text: summary)
                        }
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 14) {
                        ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(fact.title)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text(fact.value)
                                    .font(.body.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    if let footnote {
                        Text(footnote)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)

            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(issues) { issue in
                        ConsoleIssueRow(issue: issue, onShow: issueSections[issue.kind].map { id in { scroll(id) } })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, -8)
            }
        }
        .consoleSurface(cornerRadius: 22)
    }
}

// MARK: - Web Interface

struct WebInterfacePage: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let snapshot = app.consoleOverviewSnapshot
        let web = snapshot[.webInterface]
        let tunnel = snapshot[.cloudflareTunnel]

        ConsoleSettingsPage(
            title: "Web Interface",
            subtitle: "The browser dashboard where bot features are managed.",
            accessory: {
                Button("Open Web Interface", systemImage: "arrow.up.forward.app") {
                    app.launchAdminWebUI()
                }
                .buttonStyle(.glassProminent)
                .disabled(!app.settings.adminWebUI.enabled)
                .help(app.settings.adminWebUI.enabled ? app.adminWebBaseURL() : "Enable Admin Web UI below to open the dashboard.")
            },
            summary: {
                if let web, let tunnel {
                    ServiceSummaryCard(
                        kind: .webInterface,
                        status: web,
                        facts: [
                            addressFact,
                            ("Local Transport", app.settings.adminWebUI.httpsEnabled ? "HTTPS" : "HTTP"),
                            ("Public Access", publicAccessSummary(tunnel)),
                            ("HTTPS Policy", app.settings.adminWebUI.requireHTTPS ? "Required" : "Optional")
                        ],
                        issues: [web, tunnel].filter(\.health.needsAttention),
                        issueSections: [
                            .webInterface: WebUISectionID.adminWebUI,
                            .cloudflareTunnel: WebUISectionID.internetAccess
                        ]
                    )
                }
            },
            content: { WebUIPreferencesView() }
        )
    }

    private var addressFact: (title: String, value: String) {
        let settings = app.settings.adminWebUI
        if settings.internetAccessEnabled {
            if app.adminWebPublicAccessStatus.isEnabled,
               let host = URL(string: app.adminWebPublicAccessStatus.publicURL)?.host,
               !host.isEmpty {
                return ("Website", host)
            }
            // Keep the configured website visible while the tunnel starts or
            // recovers; its availability is shown separately under Public Access.
            if !settings.normalizedHostname.isEmpty {
                return ("Website", settings.normalizedHostname)
            }
        }
        return ("Local Address", "\(settings.bindHost):\(settings.port)")
    }

    private func publicAccessSummary(_ tunnel: ConsoleServiceStatus) -> String {
        guard tunnel.health == .healthy else {
            return tunnel.health == .disabled ? "Off" : tunnel.summary
        }
        let scheme = URL(string: app.adminWebPublicAccessStatus.publicURL)?.scheme?.uppercased()
        return scheme.map { "\($0) via tunnel" } ?? tunnel.summary
    }
}

// MARK: - Integrations

struct IntegrationsPage: View {
    var body: some View {
        ConsoleSettingsPage(
            title: "Integrations",
            subtitle: "Accounts and services SwiftBot connects to from this Mac."
        ) {
            IntegrationsSettingsView()
        }
    }
}

// MARK: - SwiftMesh

/// Cluster status and mesh settings on one page. A standalone Mac has no
/// cluster to show, so it opens on the settings needed to join one.
struct SwiftMeshPage: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage("swiftMesh.page.tab") private var tab: Tab = .status

    enum Tab: String, CaseIterable {
        case status = "Status"
        case settings = "Settings"
    }

    private var isStandalone: Bool {
        app.settings.clusterMode == .standalone
    }

    var body: some View {
        ConsoleSettingsPage(
            title: "SwiftMesh",
            subtitle: subtitle,
            accessory: { tabPicker },
            summary: {
                if let status = app.consoleOverviewSnapshot[.swiftMesh] {
                    ServiceSummaryCard(
                        kind: .swiftMesh,
                        status: status,
                        facts: [
                            ("This Node", app.settings.clusterNodeName.isEmpty ? HostDetails.current.computerName : app.settings.clusterNodeName),
                            ("Configured Role", app.settings.clusterMode.displayName),
                            ("Runtime Role", app.clusterSnapshot.mode.displayName),
                            ("Leader Term", "\(app.clusterSnapshot.leaderTerm)")
                        ],
                        footnote: membershipSummary
                    )
                }
            },
            content: {
                if isStandalone || tab == .settings {
                    MeshPreferencesView()
                } else {
                    SwiftMeshView(showsHeader: false, embeddedInConsole: true)
                }
            }
        )
    }

    private var membershipSummary: String? {
        guard !isStandalone else { return nil }
        let nodes = app.clusterNodes
        guard !nodes.isEmpty else { return "Waiting for nodes to report their status." }
        let healthy = nodes.filter { $0.status == .healthy }.count
        let offline = nodes.filter { $0.status == .disconnected }.count
        return "\(nodes.count) node\(nodes.count == 1 ? "" : "s") · \(healthy) healthy · \(offline) offline"
    }

    @ViewBuilder
    private var tabPicker: some View {
        if !isStandalone {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var subtitle: String {
        isStandalone
            ? "This Mac runs on its own. Choose a role to join a mesh."
            : "\(app.settings.clusterMode.displayName) node · failover and work sharing across Macs."
    }
}
