import XCTest
@testable import SwiftBot

final class ConsoleOverviewSnapshotTests: XCTestCase {
    private func inputs(
        botStatus: BotStatus = .running,
        hasToken: Bool = true,
        closeCode: Int? = nil,
        clusterMode: ClusterMode = .standalone,
        clusterState: ClusterConnectionState = .inactive,
        unhealthyNodes: Int = 0,
        webEnabled: Bool = true,
        webListening: Bool = true,
        tunnelEnabled: Bool = false,
        tunnelState: AdminWebPublicAccessRuntimeStatus.State = .disabled
    ) -> ConsoleOverviewSnapshot.Inputs {
        .init(
            botStatus: botStatus,
            hasToken: hasToken,
            botUsername: "SwiftBot",
            connectedServerCount: 3,
            lastGatewayCloseCode: closeCode,
            uptimeStartedAt: Date(timeIntervalSince1970: 0),
            clusterMode: clusterMode,
            clusterServerState: clusterState,
            clusterNodeCount: 2,
            clusterUnhealthyNodeCount: unhealthyNodes,
            webEnabled: webEnabled,
            webListening: webListening,
            webAddress: "http://127.0.0.1:38888",
            tunnelEnabled: tunnelEnabled,
            tunnelStatus: AdminWebPublicAccessRuntimeStatus(state: tunnelState, publicURL: "https://bot.example.com", detail: "")
        )
    }

    func testServicesAreListedInDisplayOrder() {
        let snapshot = ConsoleOverviewSnapshot(inputs())
        XCTAssertEqual(snapshot.services.map(\.kind), [.discord, .webInterface, .swiftMesh, .cloudflareTunnel])
    }

    func testHealthyStandaloneHostIsRunningWithOptionalServicesDisabled() {
        let snapshot = ConsoleOverviewSnapshot(inputs())
        XCTAssertEqual(snapshot.host.health, .healthy)
        XCTAssertEqual(snapshot[.discord]?.health, .healthy)
        XCTAssertEqual(snapshot[.swiftMesh]?.health, .disabled)
        XCTAssertEqual(snapshot[.cloudflareTunnel]?.health, .disabled)
    }

    func testMissingTokenNeedsSetup() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, hasToken: false))
        XCTAssertEqual(snapshot.host.health, .warning)
        XCTAssertEqual(snapshot[.discord]?.health, .warning)
    }

    func testRejectedTokenFailsDiscord() {
        let snapshot = ConsoleOverviewSnapshot(inputs(closeCode: 4004))
        XCTAssertEqual(snapshot[.discord]?.health, .error)
        XCTAssertEqual(snapshot.host.health, .error)
        XCTAssertEqual(snapshot.host.issues.map(\.kind), [.discord])
    }

    func testWebServerNotListeningDegradesTheHost() {
        let snapshot = ConsoleOverviewSnapshot(inputs(webListening: false))
        XCTAssertEqual(snapshot[.webInterface]?.health, .error)
        XCTAssertEqual(snapshot.host.badge, "Needs Attention")
        XCTAssertEqual(snapshot.host.issues.map(\.kind), [.webInterface])
    }

    func testTunnelIsUnavailableWhenTheWebInterfaceIsOff() {
        let snapshot = ConsoleOverviewSnapshot(inputs(webEnabled: false, tunnelEnabled: true, tunnelState: .enabled))
        XCTAssertEqual(snapshot[.cloudflareTunnel]?.health, .unavailable)
        XCTAssertFalse(snapshot.host.health.needsAttention)
    }

    func testConnectedTunnelShowsItsHost() {
        let snapshot = ConsoleOverviewSnapshot(inputs(tunnelEnabled: true, tunnelState: .enabled))
        XCTAssertEqual(snapshot[.cloudflareTunnel]?.health, .healthy)
        XCTAssertEqual(snapshot[.cloudflareTunnel]?.detail, "bot.example.com")
    }

    func testStandbyNodeReportsStandingBy() {
        let snapshot = ConsoleOverviewSnapshot(inputs(clusterMode: .standby, clusterState: .connected))
        XCTAssertEqual(snapshot[.discord]?.summary, "Standing By")
        XCTAssertEqual(snapshot[.swiftMesh]?.health, .healthy)
        XCTAssertEqual(snapshot.host.health, .healthy)
    }

    func testStoppedBotIsStoppedNotAProblem() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped))
        XCTAssertEqual(snapshot.host.health, .disabled)
        XCTAssertEqual(snapshot.host.badge, "Stopped")
        XCTAssertFalse(snapshot.host.health.needsAttention)
    }

    func testUnreachableMeshPeerIsAWarning() {
        let snapshot = ConsoleOverviewSnapshot(inputs(clusterMode: .leader, clusterState: .connected, unhealthyNodes: 1))
        XCTAssertEqual(snapshot[.swiftMesh]?.health, .warning)
        XCTAssertEqual(snapshot.servicesSummary, "1 needs attention")
    }

    func testHealthyStandaloneSummaryCountsRunningServices() {
        XCTAssertEqual(ConsoleOverviewSnapshot(inputs()).servicesSummary, "2 of 4 running")
    }
}
