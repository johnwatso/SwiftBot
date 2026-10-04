import SwiftUI

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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 24)
            accessory
        }
        .controlSize(.large)
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
    let kind: ConsoleServiceKind
    let status: ConsoleServiceStatus
    let facts: [(title: String, value: String)]
    var issues: [ConsoleServiceStatus] = []
    /// The page section where each issue is fixed; Show scrolls there.
    var issueSections: [ConsoleServiceKind: String] = [:]

    @Environment(\.consolePageScroll) private var scroll

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 22) {
                ConsoleIconTile(
                    symbol: kind.symbol,
                    brandAsset: kind.brandAsset,
                    isActive: status.health != .disabled && status.health != .unavailable,
                    size: 64
                )

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            Text(kind.title)
                                .font(.title2.weight(.semibold))
                            StatusBadge(health: status.health, text: status.summary)
                        }
                        Text(status.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(alignment: .top, spacing: 28) {
                        ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                            if index > 0 { Divider() }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(fact.title)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text(fact.value)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .fixedSize()
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
            },
            summary: {
                if let web, let tunnel {
                    ServiceSummaryCard(
                        kind: .webInterface,
                        status: web,
                        facts: [
                            ("This Mac", "\(app.settings.adminWebUI.bindHost):\(app.settings.adminWebUI.port)"),
                            ("Public Access", tunnel.health == .disabled ? "Off" : tunnel.summary),
                            ("HTTPS", app.settings.adminWebUI.httpsEnabled ? "On" : "Off")
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
        if isStandalone || tab == .settings {
            ConsoleSettingsPage(
                title: "SwiftMesh",
                subtitle: subtitle,
                accessory: { tabPicker },
                summary: { EmptyView() },
                content: { MeshPreferencesView() }
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ConsolePageHeader(title: "SwiftMesh", subtitle: subtitle) { tabPicker }
                    .padding(.horizontal, 36)
                    .padding(.top, 32)
                SwiftMeshView(showsHeader: false)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
