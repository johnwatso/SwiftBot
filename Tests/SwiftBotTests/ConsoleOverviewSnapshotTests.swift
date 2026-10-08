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
        watchActive: Bool = false,
        workerState: ClusterConnectionState = .connected,
        runtimeState: ClusterRuntimeState = .idle,
        recoveryActive: Bool = false,
        diagnostics: String = "",
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
            failoverWatchActive: watchActive,
            clusterWorkerState: workerState,
            clusterRuntimeState: runtimeState,
            primaryName: "DevMini",
            ownershipRecoveryActive: recoveryActive,
            clusterDiagnostics: diagnostics,
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
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, watchActive: true))
        XCTAssertEqual(snapshot[.discord]?.summary, "Standing By")
        XCTAssertEqual(snapshot[.discord]?.detail, "Connects only after takeover")
        XCTAssertEqual(snapshot[.discord]?.health, .unavailable, "The local gateway is intentionally closed")
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Monitoring")
        XCTAssertEqual(snapshot[.swiftMesh]?.detail, "Watching DevMini")
        XCTAssertEqual(snapshot[.swiftMesh]?.health, .healthy)
        XCTAssertEqual(snapshot.host.health, .healthy)
        XCTAssertEqual(snapshot.host.badge, "Monitoring")
        XCTAssertEqual(snapshot.host.headline, "SwiftBot is monitoring DevMini for failover.")
        XCTAssertTrue(snapshot.isMonitoringFailover)
        XCTAssertEqual(snapshot.servicesSummary, "Failover watch active")
    }

    func testReturningPrimaryWaitingForLeaseIsNotStopped() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, recoveryActive: true, diagnostics: "Takeover blocked: exclusive ownership unavailable"))
        XCTAssertTrue(snapshot.isWaitingForOwnership)
        XCTAssertFalse(snapshot.isMonitoringFailover)
        XCTAssertEqual(snapshot.host.badge, "Waiting for Ownership")
        XCTAssertEqual(snapshot.host.health, .pending)
        XCTAssertEqual(snapshot[.discord]?.summary, "Standing By")
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Waiting")
    }

    func testGrantedPrimaryShowsActivationUntilDiscordConnects() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .leader, clusterState: .listening, runtimeState: .promoting))
        XCTAssertEqual(snapshot.host.badge, "Taking Over…")
        XCTAssertEqual(snapshot[.discord]?.summary, "Starting…")
        XCTAssertFalse(snapshot.isMonitoringFailover)
    }

    func testRecoveryReadinessFailureIsVisible() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, recoveryActive: true, diagnostics: "Takeover blocked: shared configuration has not completed its first sync"))
        XCTAssertEqual(snapshot.host.health, .warning)
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Takeover Blocked")
        XCTAssertTrue(snapshot[.swiftMesh]?.detail.contains("first sync") == true)
    }

    func testStoppedWatchDoesNotClaimToMonitorEvenWithAListeningMesh() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening))
        XCTAssertFalse(snapshot.isMonitoringFailover)
        XCTAssertEqual(snapshot.host.badge, "Watch Stopped")
        XCTAssertNil(snapshot.host.startedAt)
        XCTAssertEqual(snapshot[.discord]?.summary, "Stopped")
    }

    func testActiveWatchStillShowsMeshAndWebFailures() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .failed, watchActive: true, webListening: false))
        XCTAssertTrue(snapshot.isMonitoringFailover)
        XCTAssertEqual(snapshot.host.health, .error)
        XCTAssertEqual(snapshot.host.badge, "Needs Attention")
        XCTAssertEqual(Set(snapshot.host.issues.map(\.kind)), [.swiftMesh, .webInterface])
    }

    func testWatchShowsPrimaryConnectionProblem() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, watchActive: true, workerState: .failed))
        XCTAssertEqual(snapshot.host.health, .warning)
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Degraded")
        XCTAssertTrue(snapshot.host.headline.contains("Failover watch is active"))
    }

    func testWatchShowsIsolationAndRecovery() {
        let isolated = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, watchActive: true, runtimeState: .isolated))
        XCTAssertEqual(isolated[.swiftMesh]?.summary, "Primary Unreachable")
        XCTAssertEqual(isolated.host.health, .warning)
        let recovering = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, watchActive: true, runtimeState: .recovering))
        XCTAssertEqual(recovering.host.badge, "Recovering…")
        XCTAssertEqual(recovering.host.health, .pending)
    }

    func testPromotedRuntimeShowsTheLocalDiscordConnection() {
        let snapshot = ConsoleOverviewSnapshot(inputs(clusterMode: .leader, clusterState: .listening, watchActive: true))
        XCTAssertFalse(snapshot.isMonitoringFailover)
        XCTAssertEqual(snapshot.host.badge, "Running")
        XCTAssertEqual(snapshot[.discord]?.summary, "Connected")
    }

    func testMissingTokenStillNeedsAttentionWhileMonitoring() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, hasToken: false, clusterMode: .standby, clusterState: .listening, watchActive: true))
        XCTAssertTrue(snapshot.isMonitoringFailover)
        XCTAssertEqual(snapshot.host.health, .warning)
        XCTAssertEqual(snapshot.host.issues.map(\.kind), [.discord])
    }

    func testOldGatewayRejectionDoesNotDescribeAClosedStandbyGateway() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, closeCode: 4004, clusterMode: .standby, clusterState: .listening, watchActive: true))
        XCTAssertEqual(snapshot[.discord]?.summary, "Standing By")
        XCTAssertEqual(snapshot.host.health, .healthy)
    }

    func testCoordinatorSnapshotTracksWatchStartupAndStop() async {
        let coordinator = ClusterCoordinator()
        await coordinator.applySettings(mode: .standby, nodeName: "OverviewWatch", leaderAddress: "", listenPort: 0, sharedSecret: "")
        let unconfigured = await coordinator.currentSnapshot()
        XCTAssertFalse(unconfigured.isFailoverWatchActive)

        await coordinator.applySettings(mode: .standby, nodeName: "OverviewWatch", leaderAddress: "http://127.0.0.1:1", listenPort: 0, sharedSecret: "")
        let watching = await coordinator.currentSnapshot()
        XCTAssertTrue(watching.isFailoverWatchActive)

        await coordinator.stopAll()
        let stopped = await coordinator.currentSnapshot()
        XCTAssertFalse(stopped.isFailoverWatchActive)
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
