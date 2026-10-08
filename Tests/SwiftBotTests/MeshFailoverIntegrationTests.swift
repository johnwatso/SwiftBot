import XCTest
@testable import SwiftBot

/// Integration-style failover drills that complement `MeshFailoverTests`.
///
/// `MeshFailoverTests` proves the term/promotion/sync *contracts* with a single
/// in-memory coordinator. This file pushes a little further into the messy
/// handover seams that those contract tests don't exercise:
///
///   1. A newly-registered Standby must immediately pull a tail resync
///      (no waiting for the next scheduled Primary push).
///   2. A config-files payload pushed to a Standby must survive an immediate
///      Primary death — the Standby promotes with the config already applied,
///      no pull required.
///   3. A stale Primary that talks to a higher-term peer must mute its Discord
///      output (via the demotion handler) before it can send anything stale.
final class MeshFailoverIntegrationTests: XCTestCase {

    func testRecoveryActivationSurvivesSettingsRestartingItsPollingTask() async {
        actor State {
            var acquisitions = 0
            var activated = false
            func acquire(_ term: Int) -> Int? {
                acquisitions += 1
                return acquisitions == 1 ? nil : term + 1
            }
            func recordActivation(_ value: Bool) { activated = value }
        }
        let state = State()
        let node = ClusterCoordinator()
        let activation = expectation(description: "Discord activation callback finishes")
        await node.configureHandlers(
            aiHandler: { _, _, _, _ in nil }, wikiHandler: { _, _ in nil },
            onSnapshot: { _ in }, onJobLog: { _ in }, onSync: { _ in }, meshHandler: { _ in nil },
            conversationFetcher: { _, _ in ([], false) },
            onPromotion: {
                // Simulate token validation while the term save restarts polls.
                try? await Task.sleep(for: .milliseconds(100))
                await state.recordActivation(!Task.isCancelled)
                activation.fulfill()
            }
        )
        await node.setOwnershipHandlers(acquire: { await state.acquire($0) }, renew: { _ in .renewed }, release: { _ in })
        await node.setAutoReclaimPolicy(isConfiguredPrimary: true, afterHours: 0)
        await node.setTermChangedHandler { _ in
            Task {
                await node.applySettings(mode: .leader, nodeName: "Activation", leaderAddress: "", listenPort: 0, sharedSecret: "mesh")
            }
        }
        await node.applySettings(mode: .leader, nodeName: "Activation", leaderAddress: "", listenPort: 0, sharedSecret: "mesh")
        await fulfillment(of: [activation], timeout: 3)
        let activated = await state.activated
        XCTAssertTrue(activated, "Restarting recovery must not cancel the granted owner's Discord startup")
        let owns = await node.hasActiveOwnership()
        XCTAssertTrue(owns)
        await node.stopAll()
    }

    func testReinstallingSameWitnessPreservesGrantedOwnership() async {
        actor Calls {
            var count = 0
            func acquire(_ term: Int) -> Int { count += 1; return term + 1 }
        }
        let calls = Calls()
        let node = ClusterCoordinator()
        await node.applySettings(mode: .leader, nodeName: "StableOwner", leaderAddress: "", listenPort: 0, sharedSecret: "mesh")
        for _ in 0..<2 {
            await node.setOwnershipHandlers(acquire: { await calls.acquire($0) }, renew: { _ in .renewed }, release: { _ in }, witnessFingerprint: "same-authority")
        }
        let count = await calls.count
        let owns = await node.hasActiveOwnership()
        XCTAssertEqual(count, 1, "A settings refresh must not temporarily withdraw a valid lease")
        XCTAssertTrue(owns)
        await node.stopAll()
    }

    func testExplicitStopCancelsActivationAndClearsTransition() async {
        actor State {
            var cancelled = false
            func record(_ value: Bool) { cancelled = value }
        }
        let state = State()
        let node = ClusterCoordinator()
        let activating = expectation(description: "Activation has begun")
        await node.configureHandlers(
            aiHandler: { _, _, _, _ in nil }, wikiHandler: { _, _ in nil },
            onSnapshot: { _ in }, onJobLog: { _ in }, onSync: { _ in }, meshHandler: { _ in nil },
            conversationFetcher: { _, _ in ([], false) },
            onPromotion: {
                activating.fulfill()
                try? await Task.sleep(for: .seconds(5))
                await state.record(Task.isCancelled)
            }
        )
        await node.applySettings(mode: .standby, nodeName: "StopActivation", leaderAddress: "", listenPort: 0, sharedSecret: "mesh")
        let promotion = Task { await node.promoteToLeader() }
        await fulfillment(of: [activating], timeout: 3)
        await node.setDesiredBotRunning(false)
        await node.stopAll()
        await promotion.value
        let cancelled = await state.cancelled
        let snapshot = await node.currentSnapshot()
        let owns = await node.hasActiveOwnership()
        XCTAssertTrue(cancelled)
        XCTAssertEqual(snapshot.runtimeState, .idle)
        XCTAssertFalse(owns)
    }

    func testReturningPrimaryReportsRecoveryUntilStopped() async {
        let node = ClusterCoordinator()
        await node.setOwnershipHandlers(acquire: { _ in nil }, renew: { _ in .lost }, release: { _ in })
        await node.setAutoReclaimPolicy(isConfiguredPrimary: true, afterHours: 0)
        await node.applySettings(mode: .leader, nodeName: "Returning", leaderAddress: "", listenPort: 0, sharedSecret: "mesh", leaderTerm: 9)
        let waiting = await node.currentSnapshot()
        XCTAssertEqual(waiting.mode, .standby)
        XCTAssertTrue(waiting.isOwnershipRecoveryActive)
        XCTAssertFalse(waiting.isFailoverWatchActive)
        XCTAssertEqual(waiting.leaderTerm, 9)
        await node.setDesiredBotRunning(false)
        await node.stopAll()
        let stopped = await node.currentSnapshot()
        XCTAssertFalse(stopped.isOwnershipRecoveryActive)
    }

    func testRestoredTermAppearsInSnapshotWhenSettingsHaveTheSameTerm() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("recovery.json")
        try Data(#"{"term":9,"leaderAddress":"","knownPeers":{}}"#.utf8).write(to: url)
        let node = ClusterCoordinator(recoveryURL: url)
        await node.applySettings(mode: .standby, nodeName: "Restored", leaderAddress: "", listenPort: 0, sharedSecret: "mesh", leaderTerm: 9)
        let snapshot = await node.currentSnapshot()
        XCTAssertEqual(snapshot.leaderTerm, 9)
        await node.stopAll()
    }

    // MARK: - Test 1: Registration-triggered immediate resync

    /// A Standby that successfully registers with a Primary must trigger the
    /// "pull initial state now" hook exactly once, so config/wiki/conversations
    /// don't sit out-of-date until the next scheduled push.
    func testStandbyTriggersInitialResyncOnFirstRegistration() async {
        let secret = "resync-secret"
        let primaryPort = 39300
        let standbyPort = 39301
        let primaryURL = "http://127.0.0.1:\(primaryPort)"

        let primary = ClusterCoordinator()
        await primary.applySettings(
            mode: .leader,
            nodeName: "ResyncPrimary",
            leaderAddress: "",
            listenPort: primaryPort,
            sharedSecret: secret,
            leaderTerm: 1
        )

        // Wait briefly for Primary's listener to be ready before any Standby probes.
        try? await Task.sleep(nanoseconds: 250_000_000)

        let standby = ClusterCoordinator()

        let syncExpectation = expectation(description: "Registration-triggered resync handler fires")
        let receivedURL = ResyncURLBox()
        let callCount = CallCountBox()
        await standby.setLeaderRegistrationSyncHandler { url in
            await receivedURL.set(url)
            await callCount.increment()
            syncExpectation.fulfill()
        }

        await standby.applySettings(
            mode: .standby,
            nodeName: "ResyncStandby",
            leaderAddress: primaryURL,
            listenPort: standbyPort,
            sharedSecret: secret,
            leaderTerm: 1
        )

        await fulfillment(of: [syncExpectation], timeout: 5.0)

        let url = await receivedURL.get()
        XCTAssertEqual(url?.lowercased(), primaryURL.lowercased(),
                       "Standby must receive the leader URL it registered against")

        // Give the registration loop a moment to potentially fire again.
        // The handler must remain idempotent — initialSyncCompletedLeaderBaseURL
        // gates it to one invocation per leader URL.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let total = await callCount.get()
        XCTAssertEqual(total, 1, "Resync hook must fire exactly once per leader URL")

        await standby.stopAll()
        await primary.stopAll()
    }

    func testRegistrationNeverLowersStandbyTerm() async {
        let primary = ClusterCoordinator()
        await primary.applySettings(mode: .leader, nodeName: "TermPrimary", leaderAddress: "", listenPort: 39306, sharedSecret: "term-secret", leaderTerm: 3)
        let standby = ClusterCoordinator()
        await standby.applySettings(mode: .standby, nodeName: "TermStandby", leaderAddress: "http://127.0.0.1:39306", listenPort: 39307, sharedSecret: "term-secret", leaderTerm: 9)
        try? await Task.sleep(for: .milliseconds(600))
        let term = await standby.currentLeaderTerm()
        XCTAssertEqual(term, 9, "A registration response cannot roll back persisted leadership history")
        await standby.stopAll()
        await primary.stopAll()
    }

    func testInitialResyncCarriesLiveSnapshotForFailoverDashboard() async {
        let secret = "live-snapshot-secret"
        let primaryPort = 39308
        let standbyPort = 39309
        let primaryURL = "http://127.0.0.1:\(primaryPort)"

        let liveSnapshot = MeshLiveSnapshot(
            botUserId: "bot-1",
            botUsername: "SwiftBot",
            botDiscriminator: nil,
            botAvatarHash: "avatar",
            connectedServers: ["guild-1": "Test Guild"],
            gatewayEventCount: 42,
            voiceStateEventCount: 7,
            readyEventCount: 1,
            guildCreateEventCount: 1,
            lastGatewayEventName: "MESSAGE_CREATE",
            lastVoiceStateAt: Date(),
            lastVoiceStateSummary: "Voice activity",
            botStatusRaw: BotStatus.running.rawValue,
            uptimeStartedAt: Date().addingTimeInterval(-120),
            isHandoverTestActive: false,
            handoverTestEndsAt: nil,
            scheduledHandoverTestAt: nil,
            scheduledHandoverTargetNodeName: nil,
            primaryPublicURL: "https://swiftbot.example.test",
            runtimeState: ClusterRuntimeState.idle.rawValue
        )

        let primary = ClusterCoordinator()
        await primary.configureHandlers(
            aiHandler: { _, _, _, _ in nil },
            wikiHandler: { _, _ in nil },
            onSnapshot: { _ in },
            onJobLog: { _ in },
            onSync: { _ in },
            meshHandler: { type in
                type == "live-snapshot" ? try? JSONEncoder().encode(liveSnapshot) : nil
            },
            conversationFetcher: { _, _ in ([], false) }
        )
        await primary.applySettings(
            mode: .leader,
            nodeName: "LivePrimary",
            leaderAddress: "",
            listenPort: primaryPort,
            sharedSecret: secret,
            leaderTerm: 4
        )

        try? await Task.sleep(nanoseconds: 250_000_000)

        let standby = ClusterCoordinator()
        await standby.applySettings(
            mode: .standby,
            nodeName: "LiveStandby",
            leaderAddress: primaryURL,
            listenPort: standbyPort,
            sharedSecret: secret,
            leaderTerm: 4
        )

        let payload = await standby.fetchResyncPage(fromRecordID: nil, pageSize: 500)
        XCTAssertEqual(payload?.liveSnapshot?.botUsername, "SwiftBot")
        XCTAssertEqual(payload?.liveSnapshot?.connectedServers?["guild-1"], "Test Guild")
        XCTAssertEqual(payload?.liveSnapshot?.gatewayEventCount, 42)

        await standby.stopAll()
        await primary.stopAll()
    }

    // MARK: - Test 2: Config payload survives an immediate Primary death

    /// Primary pushes a config-files payload to the Standby; Primary dies
    /// before any further sync. Standby promotes and must already hold the
    /// pushed config — no need to pull /v1/mesh/sync/config-files on the way up.
    func testConfigPayloadAppliedBeforePrimaryDeathSurvivesPromotion() async {
        let secret = "config-payload-secret"
        let primaryPort = 39310
        let standbyPort = 39311
        let primaryURL = "http://127.0.0.1:\(primaryPort)"

        let standby = ClusterCoordinator()
        await standby.applySettings(
            mode: .standby,
            nodeName: "ConfigSurvivorStandby",
            leaderAddress: primaryURL,
            listenPort: standbyPort,
            sharedSecret: secret,
            leaderTerm: 1
        )

        let appliedConfigBytes = AppliedConfigBox()
        let configAppliedDuringStandby = AppliedFlagBox()

        await standby.configureHandlers(
            aiHandler: { _, _, _, _ in nil },
            wikiHandler: { _, _ in nil },
            onSnapshot: { _ in },
            onJobLog: { _ in },
            onSync: { payload in
                if payload.configFilesChanged, let data = payload.configFiles {
                    await appliedConfigBytes.set(data)
                }
            },
            meshHandler: { _ in nil },
            conversationFetcher: { _, _ in ([], false) },
            onPromotion: {
                // Snapshot whether config was already applied at the moment of promotion.
                let applied = await appliedConfigBytes.get() != nil
                await configAppliedDuringStandby.set(applied)
            }
        )

        // Primary pushes a config-files payload to the Standby.
        let fakeConfig = Data("config-blob-v1".utf8)
        let payload = MeshSyncPayload(
            conversations: [],
            configFilesChanged: true,
            configFiles: fakeConfig,
            leaderTerm: 1
        )
        let body = try! JSONEncoder().encode(payload)
        let path = "/v1/mesh/sync/conversations"
        let headers = await standby.testMakeHMACHeaders(path: path, body: body)
        let request = makeRequest(method: "POST", path: path, headers: headers, body: body)
        let response = await standby.testProcessHTTPRequest(request)
        XCTAssertEqual(statusCode(from: response), 200, "Sync push must be accepted")

        let stored = await appliedConfigBytes.get()
        XCTAssertEqual(stored, fakeConfig,
                       "Standby must apply the pushed config immediately, not defer it")

        // Primary dies. Standby promotes through the health-miss path.
        for _ in 0..<3 { await standby.testSimulateLeaderHealthMiss() }

        let mode = await standby.testCurrentMode()
        let term = await standby.testCurrentLeaderTerm()
        XCTAssertEqual(mode, .leader, "Standby must promote after threshold misses")
        XCTAssertEqual(term, 2, "Promotion must advance the term")

        // The critical assertion: at the instant of promotion, the config was
        // already present. The promoted node has no Primary to pull from.
        let wasAppliedBeforePromotion = await configAppliedDuringStandby.get()
        XCTAssertTrue(wasAppliedBeforePromotion == true,
                      "Config must already be applied at promotion time — no pull required")
        let finalConfig = await appliedConfigBytes.get()
        XCTAssertEqual(finalConfig, fakeConfig,
                       "Promoted node must still hold the pushed config bytes")

        await standby.stopAll()
    }

    // MARK: - Test 3: Split-brain output gate

    /// Two nodes briefly hold `.leader` mode at different terms. The old
    /// Primary's first outbound sync to the new (higher-term) leader returns
    /// 409, and the stale-self backstop must demote and fire `onDemotion`
    /// before any further Discord output can happen.
    func testStaleLeaderDemotesAndMutesOutputOnHigherTermResponse() async {
        let secret = "split-brain-secret"
        let oldPrimaryPort = 39320
        let newLeaderPort = 39321
        let newLeaderURL = "http://127.0.0.1:\(newLeaderPort)"

        // New leader on the higher term. Its /v1/mesh/sync/conversations
        // handler rejects with 409 because it's in leader mode (not standby).
        let newLeader = ClusterCoordinator()
        await newLeader.applySettings(
            mode: .leader,
            nodeName: "NewLeader",
            leaderAddress: "",
            listenPort: newLeaderPort,
            sharedSecret: secret,
            leaderTerm: 2
        )

        // Old primary still believes it's leader at the lower term.
        let oldPrimary = ClusterCoordinator()
        await oldPrimary.applySettings(
            mode: .leader,
            nodeName: "OldPrimary",
            leaderAddress: "",
            listenPort: oldPrimaryPort,
            sharedSecret: secret,
            leaderTerm: 1
        )

        // Wait briefly for both listeners to come up.
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Demotion is what mutes Discord output in AppModel — fulfill on it.
        let demotionExpectation = expectation(description: "Old primary fires demotion handler")
        await oldPrimary.setDemotionHandler {
            demotionExpectation.fulfill()
        }

        // Wire the new leader into the old primary's registered-workers table
        // so the real push path runs over HTTP and trips detectStaleSelfFromResponse.
        await oldPrimary.testInjectRegisteredWorker(
            nodeName: "NewLeader",
            baseURL: newLeaderURL,
            listenPort: newLeaderPort
        )

        let stalePayload = MeshSyncPayload(
            conversations: [],
            leaderTerm: 1
        )
        let succeeded = await oldPrimary.pushConversationsToSingleNode(newLeaderURL, stalePayload)
        XCTAssertFalse(succeeded, "Push to higher-term peer must report failure")

        await fulfillment(of: [demotionExpectation], timeout: 3.0)

        let oldMode = await oldPrimary.testCurrentMode()
        let oldTerm = await oldPrimary.testCurrentLeaderTerm()
        XCTAssertEqual(oldMode, .standby,
                       "Stale leader must demote itself after seeing a higher term")
        XCTAssertEqual(oldTerm, 2,
                       "Stale leader must adopt the observed higher term")

        // New leader must not have been affected.
        let newMode = await newLeader.testCurrentMode()
        let newTerm = await newLeader.testCurrentLeaderTerm()
        XCTAssertEqual(newMode, .leader)
        XCTAssertEqual(newTerm, 2)

        await oldPrimary.stopAll()
        await newLeader.stopAll()
    }

    // MARK: - Helpers

    private func makeRequest(method: String, path: String, headers: [String: String], body: Data) -> Data {
        var raw = "\(method) \(path) HTTP/1.1\r\n"
        raw += "Host: localhost\r\n"
        for (name, value) in headers { raw += "\(name): \(value)\r\n" }
        raw += "Content-Length: \(body.count)\r\n\r\n"
        var data = Data(raw.utf8)
        data.append(body)
        return data
    }

    private func statusCode(from response: Data) -> Int {
        guard let text = String(data: response, encoding: .utf8),
              let firstLine = text.components(separatedBy: "\r\n").first else { return -1 }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return -1 }
        return code
    }
}

// MARK: - Thread-safe boxes for cross-handler observation

private actor ResyncURLBox {
    private var value: String?
    func set(_ v: String) { value = v }
    func get() -> String? { value }
}

private actor CallCountBox {
    private var count = 0
    func increment() { count += 1 }
    func get() -> Int { count }
}

private actor AppliedConfigBox {
    private var value: Data?
    func set(_ v: Data) { value = v }
    func get() -> Data? { value }
}

private actor AppliedFlagBox {
    private var value: Bool?
    func set(_ v: Bool) { value = v }
    func get() -> Bool? { value }
}
