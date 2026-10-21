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

    func testReadyOrdinaryStandbyDoesNotOfferStartupRecoveryAsItsMainState() {
        var input = inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, recoveryActive: true)
        input.configuredClusterMode = .standby
        input.takeoverReadiness = .ready
        let snapshot = ConsoleOverviewSnapshot(input)
        XCTAssertFalse(snapshot.isWaitingForOwnership)
        XCTAssertTrue(snapshot.isStandbyServicesActive)
        XCTAssertEqual(snapshot.host.badge, "Standby Ready")
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Standby Ready")
        XCTAssertTrue(snapshot.host.headline.contains("until Ruru grants ownership"))
    }

    func testTakeoverBlockerDoesNotDependOnAnOverwrittenDiagnosticMessage() {
        var input = inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, recoveryActive: true)
        input.configuredClusterMode = .standby
        input.takeoverReadiness = .blocked("Discord token has not been paired")
        input.clusterDiagnostics = "Worker server listening"
        let snapshot = ConsoleOverviewSnapshot(input)
        XCTAssertEqual(snapshot.host.health, .warning)
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Takeover Blocked")
        XCTAssertEqual(snapshot[.swiftMesh]?.detail, "Discord token has not been paired")
    }

    func testServicesAreListedInDisplayOrder() {
        let snapshot = ConsoleOverviewSnapshot(inputs())
        XCTAssertEqual(snapshot.services.map(\.kind), [.discord, .webInterface, .swiftMesh, .cloudflareTunnel])
    }

    func testRuruOutageReachesOverviewEvenWhileDiscordIsConnected() {
        var input = inputs(clusterMode: .leader, clusterState: .listening)
        input.witnessHealth = .unreachable
        input.witnessLeaseValid = true
        let snapshot = ConsoleOverviewSnapshot(input)
        XCTAssertEqual(snapshot.host.badge, "Needs Attention")
        XCTAssertEqual(snapshot[.discord]?.health, .healthy)
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Ruru Unreachable")
        XCTAssertTrue(snapshot[.swiftMesh]?.detail.contains("local deadline") == true)
    }

    func testStandbyReportsRuruOutageWithoutSuggestingPromotion() {
        var input = inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening)
        input.witnessHealth = .unreachable
        let snapshot = ConsoleOverviewSnapshot(input)
        XCTAssertEqual(snapshot.host.health, .warning)
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Ruru Unreachable")
        XCTAssertTrue(snapshot[.swiftMesh]?.detail.contains("cannot take ownership") == true)
        XCTAssertEqual(snapshot[.discord]?.summary, "Standing By")
    }

    func testRuruQuarantineIsReportedAsReachableAndRecovering() {
        var input = inputs(clusterMode: .leader, clusterState: .listening)
        input.witnessHealth = .recovering
        let snapshot = ConsoleOverviewSnapshot(input)
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Ruru Recovering")
        XCTAssertTrue(snapshot[.swiftMesh]?.detail.contains("reachable") == true)
        input.witnessHealth = .ready
        XCTAssertEqual(ConsoleOverviewSnapshot(input)[.swiftMesh]?.health, .healthy)
        input.clusterMode = .standalone
        input.witnessHealth = .unreachable
        XCTAssertEqual(ConsoleOverviewSnapshot(input)[.swiftMesh]?.health, .disabled)
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
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening))
        XCTAssertEqual(snapshot[.discord]?.summary, "Standing By")
        XCTAssertEqual(snapshot[.discord]?.detail, "Connects only with ownership")
        XCTAssertEqual(snapshot[.discord]?.health, .unavailable, "The local gateway is intentionally closed")
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Standby")
        XCTAssertEqual(snapshot[.swiftMesh]?.detail, "Services running · ownership required for Discord")
        XCTAssertEqual(snapshot[.swiftMesh]?.health, .healthy)
        XCTAssertEqual(snapshot.host.health, .healthy)
        XCTAssertEqual(snapshot.host.badge, "Standby")
        XCTAssertEqual(snapshot.host.headline, "This Mac is standing by. Discord connects only with ownership.")
        XCTAssertTrue(snapshot.isStandbyServicesActive)
        XCTAssertEqual(snapshot.servicesSummary, "Standby services active")
    }

    func testReturningPrimaryWaitingForLeaseIsNotStopped() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, recoveryActive: true, diagnostics: "Takeover blocked: exclusive ownership unavailable"))
        XCTAssertTrue(snapshot.isWaitingForOwnership)
        XCTAssertTrue(snapshot.isStandbyServicesActive)
        XCTAssertEqual(snapshot.host.badge, "Waiting for Ownership")
        XCTAssertEqual(snapshot.host.health, .pending)
        XCTAssertEqual(snapshot[.discord]?.summary, "Standing By")
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Waiting")
    }

    func testGrantedPrimaryShowsActivationUntilDiscordConnects() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .leader, clusterState: .listening, runtimeState: .promoting))
        XCTAssertEqual(snapshot.host.badge, "Taking Over…")
        XCTAssertEqual(snapshot[.discord]?.summary, "Starting…")
        XCTAssertFalse(snapshot.isStandbyServicesActive)
    }

    func testRecoveryReadinessFailureIsVisible() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, recoveryActive: true, diagnostics: "Takeover blocked: shared configuration has not completed its first sync"))
        XCTAssertEqual(snapshot.host.health, .warning)
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Takeover Blocked")
        XCTAssertTrue(snapshot[.swiftMesh]?.detail.contains("first sync") == true)
    }

    func testListeningStandbyDoesNotClaimToWatchPrimary() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening))
        XCTAssertTrue(snapshot.isStandbyServicesActive)
        XCTAssertEqual(snapshot.host.badge, "Standby")
        XCTAssertNil(snapshot.host.startedAt)
        XCTAssertEqual(snapshot[.discord]?.summary, "Standing By")
    }

    func testStandbyStillShowsMeshAndWebFailures() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .failed, webListening: false))
        XCTAssertFalse(snapshot.isStandbyServicesActive)
        XCTAssertEqual(snapshot.host.health, .error)
        XCTAssertEqual(snapshot.host.badge, "Needs Attention")
        XCTAssertEqual(Set(snapshot.host.issues.map(\.kind)), [.swiftMesh, .webInterface])
    }

    func testStandbyShowsPrimaryConnectionProblem() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, workerState: .failed))
        XCTAssertEqual(snapshot.host.health, .warning)
        XCTAssertEqual(snapshot[.swiftMesh]?.summary, "Degraded")
        XCTAssertTrue(snapshot.host.headline.contains("standing by"))
    }

    func testStandbyShowsIsolationAndRecovery() {
        let isolated = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, runtimeState: .isolated))
        XCTAssertEqual(isolated[.swiftMesh]?.summary, "Connection Unavailable")
        XCTAssertEqual(isolated.host.health, .warning)
        let recovering = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, clusterMode: .standby, clusterState: .listening, runtimeState: .recovering))
        XCTAssertEqual(recovering.host.badge, "Recovering…")
        XCTAssertEqual(recovering.host.health, .pending)
    }

    func testPromotedRuntimeShowsTheLocalDiscordConnection() {
        let snapshot = ConsoleOverviewSnapshot(inputs(clusterMode: .leader, clusterState: .listening))
        XCTAssertFalse(snapshot.isStandbyServicesActive)
        XCTAssertEqual(snapshot.host.badge, "Running")
        XCTAssertEqual(snapshot[.discord]?.summary, "Connected")
    }

    func testMissingTokenStillNeedsAttentionOnStandby() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, hasToken: false, clusterMode: .standby, clusterState: .listening))
        XCTAssertTrue(snapshot.isStandbyServicesActive)
        XCTAssertEqual(snapshot.host.health, .warning)
        XCTAssertEqual(snapshot.host.issues.map(\.kind), [.discord])
    }

    func testOldGatewayRejectionDoesNotDescribeAClosedStandbyGateway() {
        let snapshot = ConsoleOverviewSnapshot(inputs(botStatus: .stopped, closeCode: 4004, clusterMode: .standby, clusterState: .listening))
        XCTAssertEqual(snapshot[.discord]?.summary, "Standing By")
        XCTAssertEqual(snapshot.host.health, .healthy)
    }

    func testCoordinatorDoesNotClaimRemovedPeerWatch() async {
        let coordinator = ClusterCoordinator()
        await coordinator.applySettings(mode: .standby, nodeName: "OverviewWatch", leaderAddress: "", listenPort: 0, sharedSecret: "")
        let unconfigured = await coordinator.currentSnapshot()
        XCTAssertFalse(unconfigured.isFailoverWatchActive)

        await coordinator.applySettings(mode: .standby, nodeName: "OverviewWatch", leaderAddress: "http://127.0.0.1:1", listenPort: 0, sharedSecret: "")
        let watching = await coordinator.currentSnapshot()
        XCTAssertFalse(watching.isFailoverWatchActive, "Peer monitoring was removed; a configured Primary address does not establish an active watch")

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
