#if DEBUG
import SwiftUI

/// Sample data for the Overview's canvas previews. The sections take plain
/// values, so they preview without an AppModel or a running bot.
private enum ConsoleOverviewPreviewData {
    static let details = HostDetails(
        computerName: "Mac Studio",
        hardware: "Mac Studio (2025) · Apple M4 Max · 64 GB memory",
        operatingSystem: "macOS 26.1",
        appVersion: "1.4.0",
        buildNumber: "2026100514",
        buildChannel: "Development",
        dataLocation: URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support/SwiftBot")
    )

    static func snapshot(
        webListening: Bool = true,
        tunnel: AdminWebPublicAccessRuntimeStatus.State = .enabled,
        standby: Bool = false
    ) -> ConsoleOverviewSnapshot {
        ConsoleOverviewSnapshot(.init(
            botStatus: standby ? .stopped : .running,
            hasToken: true,
            botUsername: "SwiftBot - Dev",
            connectedServerCount: 1,
            lastGatewayCloseCode: nil,
            uptimeStartedAt: Date().addingTimeInterval(-(4 * 86_400 + 7 * 3_600 + 12 * 60)),
            clusterMode: standby ? .standby : .leader,
            clusterServerState: .connected,
            clusterNodeCount: 2,
            clusterUnhealthyNodeCount: 0,
            failoverWatchActive: standby,
            clusterWorkerState: .connected,
            primaryName: "DevMini",
            webEnabled: !standby,
            webListening: webListening,
            webAddress: "https://test.swiftbot.dev",
            tunnelEnabled: !standby,
            tunnelStatus: .init(state: tunnel, publicURL: "https://test.swiftbot.dev", detail: "cloudflared exited (code 1)")
        ))
    }

    @MainActor static let actions: [QuickAction] = [
        QuickAction(id: "token", title: "Edit Bot Token", subtitle: "Replace the Discord bot token", symbol: "key", perform: {}),
        QuickAction(id: "test", title: "Test Connection", subtitle: "Check that Discord accepts the bot token",
                    symbol: "antenna.radiowaves.left.and.right", perform: {}),
        QuickAction(id: "logs", title: "View Logs", subtitle: "Recent runtime activity", symbol: "doc.text.magnifyingglass", perform: {})
    ]
}

private struct ConsoleOverviewPreviewPage: View {
    let snapshot: ConsoleOverviewSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                ConsolePageHeader(title: "Overview", subtitle: snapshot.host.headline, accessoriesBesideTitle: true) {
                    if snapshot.isMonitoringFailover {
                        Button("View Failover Watch", systemImage: "point.3.connected.trianglepath.dotted") {}
                            .buttonStyle(.glass)
                    }
                }
                HostSummaryCard(
                    botName: "SwiftBot - Dev",
                    status: snapshot.host,
                    details: ConsoleOverviewPreviewData.details,
                    meshRole: snapshot.isMonitoringFailover ? "Fail Over" : "Primary",
                    uptimeTitle: snapshot.isMonitoringFailover ? "Primary Uptime" : "Uptime",
                    onReviewIssue: { _ in }
                )
                ServiceStatusSection(services: snapshot.services, summary: snapshot.servicesSummary, onSelect: { _ in })
                HStack(alignment: .top, spacing: 28) {
                    QuickActionsSection(actions: ConsoleOverviewPreviewData.actions)
                    SystemDetailsSection(details: ConsoleOverviewPreviewData.details, meshRole: snapshot.isMonitoringFailover ? "Fail Over" : "Primary")
                }
            }
            .padding(36)
        }
        .frame(width: 1040, height: 1000)
        .background(SwiftBotGlassBackground())
    }
}

#Preview("Overview · Healthy") {
    ConsoleOverviewPreviewPage(snapshot: ConsoleOverviewPreviewData.snapshot())
}

#Preview("Overview · Needs Attention") {
    ConsoleOverviewPreviewPage(snapshot: ConsoleOverviewPreviewData.snapshot(webListening: false, tunnel: .error))
}

#Preview("Overview · Failover Monitoring") {
    ConsoleOverviewPreviewPage(snapshot: ConsoleOverviewPreviewData.snapshot(tunnel: .disabled, standby: true))
}
#endif
