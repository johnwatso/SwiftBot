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

    func testStoppedIntentDoesNotAcquireDuringSettingsOrHandlerRefresh() async {
        actor Grants {
            var count = 0
            func acquire(_ term: Int) -> Int { count += 1; return term + 1 }
        }
        let grants = Grants()
        let node = ClusterCoordinator()
        await node.setDesiredBotRunning(false)
        await node.setOwnershipHandlers(acquire: { await grants.acquire($0) }, renew: { _ in .renewed }, release: { _ in })
        await node.setAutoReclaimPolicy(isConfiguredPrimary: true, afterHours: 0)
        await node.applySettings(mode: .leader, nodeName: "StoppedIntent", leaderAddress: "", listenPort: 0, sharedSecret: "mesh")
        await node.setOwnershipHandlers(acquire: { await grants.acquire($0) }, renew: { _ in .renewed }, release: { _ in })
        let initialCount = await grants.count
        let initialOwnership = await node.hasActiveOwnership()
        let initialSnapshot = await node.currentSnapshot()
        XCTAssertEqual(initialCount, 0, "Autostart off must not acquire during host configuration")
        XCTAssertFalse(initialOwnership)
        XCTAssertFalse(initialSnapshot.isOwnershipRecoveryActive)

        await node.setDesiredBotRunning(true)
        await node.applySettings(mode: .leader, nodeName: "StoppedIntent", leaderAddress: "", listenPort: 0, sharedSecret: "mesh")
        let startedCount = await grants.count
        let startedOwnership = await node.hasActiveOwnership()
        XCTAssertEqual(startedCount, 1, "An explicit Start still acquires with unchanged placement")
        XCTAssertTrue(startedOwnership)

        await node.stopAll()
        await node.applySettings(mode: .leader, nodeName: "StoppedIntent", leaderAddress: "", listenPort: 0, sharedSecret: "mesh")
        let stoppedCount = await grants.count
        let stoppedOwnership = await node.hasActiveOwnership()
        XCTAssertEqual(stoppedCount, 1, "A local settings save after Stop must not reacquire")
        XCTAssertFalse(stoppedOwnership)
        await node.stopAll()
    }

    func testStopDuringAcquireReturnsLateGrantWithoutOwnership() async {
        actor Grant {
            var pending: CheckedContinuation<Int, Never>?
            var finished = false
            var released: [Int] = []
            func wait() async -> Int {
                if finished { return 7 }
                return await withCheckedContinuation { pending = $0 }
            }
            func finish() {
                finished = true
                pending?.resume(returning: 7)
                pending = nil
            }
            func release(_ term: Int) { released.append(term) }
        }
        let grant = Grant()
        let node = ClusterCoordinator()
        let requested = expectation(description: "Lease request began")
        await node.setOwnershipHandlers(acquire: { _ in
            requested.fulfill()
            return await grant.wait()
        }, renew: { _ in .renewed }, release: { await grant.release($0) })
        let applying = Task {
            await node.applySettings(mode: .leader, nodeName: "LateGrant", leaderAddress: "", listenPort: 0, sharedSecret: "mesh")
        }
        await fulfillment(of: [requested], timeout: 3)
        await node.setDesiredBotRunning(false)
        await grant.finish()
        await applying.value
        let owns = await node.hasActiveOwnership()
        let snapshot = await node.currentSnapshot()
        let released = await grant.released
        XCTAssertFalse(owns)
        XCTAssertFalse(snapshot.isOwnershipRecoveryActive)
        XCTAssertEqual(released, [7])
        await node.stopAll()
    }

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

/// Ordinary backups compete only through the same bounded, exclusive authority.
/// No peer health observation grants ownership; all output callbacks are fakes.
final class OrdinaryStandbyTakeoverTests: XCTestCase {
    private actor Authority {
        var owner: String?
        var term = 0
        var deadline: ContinuousClock.Instant?
        var available = true
        var attempts: [String: Int] = [:]
        var grantTimes: [String: ContinuousClock.Instant] = [:]
        var releases: [String] = []
        let duration: Duration = .milliseconds(250)

        func acquire(_ node: String, minimum: Int) -> Int? {
            attempts[node, default: 0] += 1
            guard available else { return nil }
            if let deadline, ContinuousClock.now >= deadline { owner = nil }
            guard owner == nil || owner == node else { return nil }
            if owner == nil { term = max(term + 1, minimum) }
            owner = node
            deadline = ContinuousClock.now + duration
            grantTimes[node] = .now
            return term
        }
        func renew(_ node: String, term: Int) -> MeshOwnershipRenewal {
            guard available else { return .unreachable(stillValid: deadline.map { .now < $0 } ?? false) }
            guard owner == node, self.term == term, let deadline, ContinuousClock.now < deadline else { return .lost }
            self.deadline = ContinuousClock.now + duration
            return .renewed
        }
        func release(_ node: String, term: Int) {
            guard owner == node, self.term == term else { return }
            owner = nil
            releases.append(node)
        }
        func setAvailable(_ value: Bool) { available = value }
    }

    private actor Preflight {
        var reason: String?
        init(_ reason: String? = nil) { self.reason = reason }
        func set(_ value: String?) { reason = value }
    }

    private actor Effects {
        var opened: [String] = []
        func open(_ id: String) { opened.append(id) }
    }

    private func candidate(_ id: String, authority: Authority, preflight: Preflight = Preflight(),
                           effects: Effects = Effects(), running: Bool = true, mode: ClusterMode = .standby,
                           fingerprint: String? = "service@ruru.example.com") async -> ClusterCoordinator {
        let node = ClusterCoordinator()
        await node.setDesiredBotRunning(running)
        await node.setOwnershipTimingForTesting(renewal: .milliseconds(40), retry: .milliseconds(40), recovery: .milliseconds(40))
        await node.configureHandlers(aiHandler: { _, _, _, _ in nil }, wikiHandler: { _, _ in nil },
            onSnapshot: { _ in }, onJobLog: { _ in }, onSync: { _ in }, meshHandler: { _ in nil },
            conversationFetcher: { _, _ in ([], false) }, onPromotion: { await effects.open(id) })
        await node.setPromotionReadinessHandler { await preflight.reason }
        await node.setCredentialAuthorization(provider: { _ in nil }, localNodeID: id, localToken: "")
        await node.setOwnershipHandlers(acquire: { await authority.acquire(id, minimum: $0) },
            renew: { await authority.renew(id, term: $0) }, release: { await authority.release(id, term: $0) },
            witnessFingerprint: fingerprint)
        await node.applySettings(mode: mode, nodeName: id, leaderAddress: "", listenPort: 0, sharedSecret: "mesh")
        return node
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    func testNonPreferredBackupAutomaticallyTakesOverOnlyAfterOwnerLeaseExpires() async throws {
        let authority = Authority()
        let owner = await candidate("owner", authority: authority, mode: .leader)
        let effects = Effects()
        let backup = await candidate("backup", authority: authority, effects: effects)
        await backup.setPrimaryPreference(.init(status: .current,
            policy: .init(preferredPrimaryNodeID: "owner", revision: 1), receivedAt: .now, authorityReady: true))
        let attempted = await waitUntil { await authority.attempts["backup", default: 0] >= 2 }
        XCTAssertTrue(attempted)
        let before = await backup.hasActiveOwnership()
        let openedBefore = await effects.opened
        XCTAssertFalse(before)
        XCTAssertTrue(openedBefore.isEmpty)
        let waiting = await backup.currentSnapshot()
        XCTAssertEqual(waiting.takeoverReadiness, .ready)
        XCTAssertTrue(waiting.isOwnershipRecoveryActive)

        let firstTerm = await authority.term
        await owner.stopAll(releaseOwnership: false) // Abrupt loss leaves the grant outstanding.
        let deadlineValue = await authority.deadline
        let deadline = try XCTUnwrap(deadlineValue)
        let tookOver = await waitUntil { await backup.hasActiveOwnership() }
        XCTAssertTrue(tookOver)
        let grantedValue = await authority.grantTimes["backup"]
        let grantedAt = try XCTUnwrap(grantedValue)
        let nextTerm = await authority.term
        XCTAssertGreaterThanOrEqual(grantedAt, deadline)
        XCTAssertGreaterThan(nextTerm, firstTerm)
        let opened = await effects.opened
        XCTAssertEqual(opened, ["backup"])
        await backup.stopAll()
    }

    func testTwoReadyBackupsNeverActivateTogether() async {
        let authority = Authority()
        let owner = await candidate("owner", authority: authority, mode: .leader)
        let effects = Effects()
        let first = await candidate("first", authority: authority, effects: effects)
        let second = await candidate("second", authority: authority, effects: effects)
        await owner.stopAll(releaseOwnership: false)
        let promoted = await waitUntil { await effects.opened.count == 1 }
        XCTAssertTrue(promoted)
        try? await Task.sleep(for: .milliseconds(200))
        let firstOwns = await first.hasActiveOwnership()
        let secondOwns = await second.hasActiveOwnership()
        XCTAssertNotEqual(firstOwns, secondOwns)
        let opened = await effects.opened
        XCTAssertEqual(opened.count, 1)
        await first.setDesiredBotRunning(false)
        await second.setDesiredBotRunning(false)
        await first.stopAll()
        await second.stopAll()
    }

    func testBlockedBackupDoesNotRequestLeaseUntilLocalStateIsReady() async {
        let authority = Authority()
        let preflight = Preflight("shared configuration has not completed its first sync")
        let node = await candidate("backup", authority: authority, preflight: preflight)
        let blocked = await waitUntil {
            await node.currentSnapshot().takeoverReadiness == .blocked("shared configuration has not completed its first sync")
        }
        XCTAssertTrue(blocked)
        let attempts = await authority.attempts["backup", default: 0]
        XCTAssertEqual(attempts, 0)
        await preflight.set(nil)
        let owns = await waitUntil { await node.hasActiveOwnership() }
        XCTAssertTrue(owns)
        await node.stopAll()
    }

    func testUnavailableRuruDoesNotActivateAndRecoversWithoutPreferenceChange() async {
        let authority = Authority()
        await authority.setAvailable(false)
        let effects = Effects()
        let node = await candidate("backup", authority: authority, effects: effects)
        let retried = await waitUntil { await authority.attempts["backup", default: 0] >= 3 }
        XCTAssertTrue(retried)
        let ownsBefore = await node.hasActiveOwnership()
        let effectsBefore = await effects.opened
        XCTAssertFalse(ownsBefore)
        XCTAssertTrue(effectsBefore.isEmpty)
        await authority.setAvailable(true)
        let ownsAfter = await waitUntil { await node.hasActiveOwnership() }
        XCTAssertTrue(ownsAfter)
        await node.stopAll()
    }

    func testStoppedWorkerAndLegacyNodesDoNotAutomaticallyAcquire() async {
        let authority = Authority()
        let stopped = await candidate("stopped", authority: authority, running: false)
        let worker = await candidate("worker", authority: authority, mode: .worker)
        let legacy = await candidate("legacy", authority: authority, fingerprint: nil)
        try? await Task.sleep(for: .milliseconds(150))
        let attempts = await authority.attempts
        XCTAssertTrue(attempts.isEmpty)
        let stoppedSnapshot = await stopped.currentSnapshot()
        XCTAssertEqual(stoppedSnapshot.takeoverReadiness, .stopped)
        let legacySnapshot = await legacy.currentSnapshot()
        XCTAssertEqual(legacySnapshot.takeoverReadiness, .blocked("Connect this Mac to Ruru to enable automatic takeover."))
        await stopped.setDesiredBotRunning(true)
        let owns = await waitUntil { await stopped.hasActiveOwnership() }
        XCTAssertTrue(owns)
        await stopped.stopAll()
        await worker.stopAll()
        await legacy.stopAll()
    }

    func testRepeatedHandlerRefreshKeepsOneSerialRetryLoopAndStopCancelsIt() async {
        let authority = Authority()
        await authority.setAvailable(false)
        let node = await candidate("backup", authority: authority)
        for _ in 0..<10 {
            await node.setPromotionReadinessHandler { nil }
            await node.setOwnershipHandlers(acquire: { await authority.acquire("backup", minimum: $0) },
                renew: { await authority.renew("backup", term: $0) }, release: { await authority.release("backup", term: $0) },
                witnessFingerprint: "service@ruru.example.com")
        }
        try? await Task.sleep(for: .milliseconds(200))
        let attempts = await authority.attempts["backup", default: 0]
        XCTAssertGreaterThan(attempts, 1)
        XCTAssertLessThan(attempts, 12, "Refreshes must not multiply the five-second production retry loop")
        await node.setDesiredBotRunning(false)
        try? await Task.sleep(for: .milliseconds(80))
        let stoppedCount = await authority.attempts["backup", default: 0]
        await authority.setAvailable(true)
        try? await Task.sleep(for: .milliseconds(150))
        let finalCount = await authority.attempts["backup", default: 0]
        let owns = await node.hasActiveOwnership()
        XCTAssertEqual(finalCount, stoppedCount)
        XCTAssertFalse(owns)
        await node.stopAll()
    }

    func testStateChangingDuringAcquireReturnsGrantWithoutActivating() async {
        actor Gate {
            var continuation: CheckedContinuation<Void, Never>?
            var finished = false
            func wait() async {
                if finished { return }
                await withCheckedContinuation { continuation = $0 }
            }
            func finish() { finished = true; continuation?.resume(); continuation = nil }
        }
        let authority = Authority()
        let preflight = Preflight()
        let effects = Effects()
        let gate = Gate()
        let requested = expectation(description: "Candidate is waiting for Ruru")
        let node = ClusterCoordinator()
        await node.setOwnershipTimingForTesting(renewal: .milliseconds(40), retry: .milliseconds(40), recovery: .milliseconds(40))
        await node.configureHandlers(aiHandler: { _, _, _, _ in nil }, wikiHandler: { _, _ in nil },
            onSnapshot: { _ in }, onJobLog: { _ in }, onSync: { _ in }, meshHandler: { _ in nil },
            conversationFetcher: { _, _ in ([], false) }, onPromotion: { await effects.open("backup") })
        await node.setPromotionReadinessHandler { await preflight.reason }
        await node.setOwnershipHandlers(acquire: { term in
            requested.fulfill()
            await gate.wait()
            return await authority.acquire("backup", minimum: term)
        }, renew: { _ in .renewed }, release: { await authority.release("backup", term: $0) },
            witnessFingerprint: "service@ruru.example.com")
        await node.applySettings(mode: .standby, nodeName: "backup", leaderAddress: "", listenPort: 0, sharedSecret: "mesh")
        await fulfillment(of: [requested], timeout: 3)
        await preflight.set("shared configuration or credentials are being installed")
        await gate.finish()
        let blocked = await waitUntil {
            await node.currentSnapshot().takeoverReadiness == .blocked("shared configuration or credentials are being installed")
        }
        XCTAssertTrue(blocked)
        let owner = await authority.owner
        let releases = await authority.releases
        let opened = await effects.opened
        XCTAssertNil(owner)
        XCTAssertEqual(releases, ["backup"])
        XCTAssertTrue(opened.isEmpty)
        await node.stopAll()
    }
}
