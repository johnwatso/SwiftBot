import AppKit
import SwiftUI

/// The host console's Overview: is SwiftBot up, how are its four services, and
/// a few actions that belong on the Mac rather than in the Web Interface.
///
/// Service state is derived on every render from AppModel (see
/// `ConsoleOverviewSnapshot`), so it is always live. Host facts are read once
/// (`HostDetails.current`). Preferences that change how
/// the app behaves, such as Launch at Login, live in Settings › General.
struct ConsoleOverviewView: View {
    @EnvironmentObject private var app: AppModel

    private let details = HostDetails.current
    @State private var isTestingConnection = false
    @State private var isConfirmingRestart = false
    @State private var isConfirmingStop = false

    /// Shows another sidebar page (a service's settings, the log).
    var onNavigate: (SidebarItem) -> Void = { _ in }
    var onShowClassicDashboard: () -> Void = {}

    var body: some View {
        let snapshot = app.consoleOverviewSnapshot
        let meshRole = app.settings.clusterMode.displayName

        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header(snapshot.host)
                    .padding(.bottom, 4)

                HostSummaryCard(
                    botName: app.resolvedBotUsername,
                    status: snapshot.host,
                    details: details,
                    meshRole: meshRole,
                    onReviewIssue: open
                )

                ServiceStatusSection(
                    services: snapshot.services,
                    summary: snapshot.servicesSummary,
                    onSelect: open
                )

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        quickActionsPanel
                            .frame(minWidth: 280, maxWidth: .infinity)
                        SystemDetailsSection(details: details, meshRole: meshRole)
                            .frame(minWidth: 340, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 32) {
                        quickActionsPanel
                        SystemDetailsSection(details: details, meshRole: meshRole)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 32)
            .padding(.bottom, 40)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .fadingEdges(top: 12, bottom: 20)
        .confirmationDialog("Restart \(app.resolvedBotUsername)?", isPresented: $isConfirmingRestart) {
            Button("Restart") { restart() }
        } message: {
            Text(app.settings.clusterMode == .leader
                 ? "SwiftBot disconnects from Discord for a moment. A Fail Over node may take over while it restarts."
                 : "SwiftBot disconnects from Discord for a moment and then reconnects.")
        }
        .confirmationDialog("Stop \(app.resolvedBotUsername)?", isPresented: $isConfirmingStop) {
            Button(stopTitle, role: .destructive) {
                Task { await app.stopBot() }
            }
        } message: {
            Text(stopMessage)
        }
    }

    // MARK: - Header

    private func header(_ status: HostStatus) -> some View {
        ConsolePageHeader(title: "Overview", subtitle: status.headline) {
            HStack(spacing: 12) {
                overflowMenu
                lifecycleButton(for: status)

                Button("Open Web Interface", systemImage: "arrow.up.forward.app") {
                    app.launchAdminWebUI()
                }
                .buttonStyle(.glassProminent)
                .disabled(!app.settings.adminWebUI.enabled)
                .help(app.settings.adminWebUI.enabled ? app.adminWebBaseURL() : "Turn on the Web Interface on its page in the sidebar")
            }
        }
    }

    private var overflowMenu: some View {
        Menu {
            if app.status != .stopped {
                Button("\(stopTitle)…", systemImage: "stop.fill", role: .destructive) {
                    isConfirmingStop = true
                }
                Divider()
            }
            Button("Show Data Folder in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([details.dataLocation])
            }
            Button("Export Diagnostic Logs…", systemImage: "square.and.arrow.up") {
                Task { await LogExporter.presentSavePanel(app: app) }
            }
            Divider()
            Button("Show Classic Dashboard", systemImage: "square.grid.2x2", action: onShowClassicDashboard)
        } label: {
            Label("More", systemImage: "wrench.and.screwdriver")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .fixedSize()
        .help("More")
    }

    @ViewBuilder
    private func lifecycleButton(for status: HostStatus) -> some View {
        switch app.status {
        case .stopped:
            Button("Start", systemImage: "play.fill") {
                Task { await app.startBot() }
            }
            .buttonStyle(.glass)
            .disabled(app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  ? "Add a bot token on the Discord page before starting."
                  : "Connect SwiftBot to Discord.")
        case .connecting, .reconnecting, .running:
            Button("Restart", systemImage: "arrow.clockwise") {
                isConfirmingRestart = true
            }
            .buttonStyle(.glass)
            .disabled(app.status == .connecting)
        }
    }

    private var stopTitle: String {
        app.settings.clusterMode == .standby ? "Stop Failover Watch" : "Stop Bot"
    }

    private var stopMessage: String {
        app.settings.clusterMode == .standby
            ? "This Mac stops watching the Primary and won’t take over if the Primary goes down."
            : "The bot disconnects from Discord and leaves any voice channels. Commands, automations, and monitors stay paused until you start it again."
    }

    // MARK: - Quick actions

    private var quickActionsPanel: some View {
        // Re-evaluate the short connection-test cooldown even on a quiet bot.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            QuickActionsSection(actions: quickActions)
        }
    }

    private var quickActions: [QuickAction] {
        [
            QuickAction(
                id: "token",
                title: "Edit Bot Token",
                subtitle: "Replace the Discord bot token",
                symbol: "key",
                perform: { onNavigate(.discord) }
            ),
            QuickAction(
                id: "test",
                title: "Test Connection",
                subtitle: testConnectionSubtitle,
                symbol: "antenna.radiowaves.left.and.right",
                isEnabled: !app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && app.canRunTestConnection,
                isBusy: isTestingConnection,
                perform: testConnection
            ),
            QuickAction(
                id: "logs",
                title: "View Logs",
                subtitle: "Recent runtime activity",
                symbol: "doc.text.magnifyingglass",
                perform: { onNavigate(.activity) }
            )
        ]
    }

    private var testConnectionSubtitle: String {
        if app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a bot token on the Discord page first"
        }
        if !isTestingConnection && !app.canRunTestConnection {
            return "Wait a few seconds before testing again"
        }
        let diagnostics = app.connectionDiagnostics
        guard let at = diagnostics.lastTestAt, !diagnostics.lastTestMessage.isEmpty else {
            return "Check that Discord accepts the bot token"
        }
        return "\(diagnostics.lastTestMessage) \(at.formatted(.relative(presentation: .named)))"
    }

    private func testConnection() {
        guard app.canRunTestConnection else { return }
        isTestingConnection = true
        Task {
            await app.runTestConnection()
            isTestingConnection = false
        }
    }

    // MARK: - Navigation

    private func open(_ kind: ConsoleServiceKind) {
        switch kind {
        case .discord: onNavigate(.discord)
        case .webInterface, .cloudflareTunnel: onNavigate(.webInterface)
        case .swiftMesh: onNavigate(.swiftMesh)
        }
    }

    private func restart() {
        Task {
            await app.stopBot()
            await app.startBot()
        }
    }
}
