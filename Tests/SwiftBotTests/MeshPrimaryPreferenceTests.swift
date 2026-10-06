import CryptoKit
import XCTest
@testable import SwiftBot

/// Ruru's Preferred Primary (`POST /v1/service/policy`, v1). Fake sessions,
/// fixed instants and in-memory credentials; no Keychain, Ruru or live bot.
final class MeshPrimaryPolicyDecodingTests: XCTestCase {
    private func decode(_ json: String, cluster: String = "swiftmesh") -> MeshPrimaryPolicy? {
        MeshPrimaryPolicy.decode(Data(json.utf8), expectedClusterID: cluster)
    }

    func testValidSelectionAndExplicitNull() {
        XCTAssertEqual(decode(#"{"version":1,"clusterID":"swiftmesh","preferredPrimaryNodeID":"server-a","preferenceRevision":1}"#),
                       MeshPrimaryPolicy(preferredPrimaryNodeID: "server-a", revision: 1))
        XCTAssertEqual(decode(#"{"version":1,"clusterID":"swiftmesh","preferredPrimaryNodeID":null,"preferenceRevision":2}"#),
                       MeshPrimaryPolicy(preferredPrimaryNodeID: nil, revision: 2))
        XCTAssertEqual(decode(#"{"version":1,"clusterID":"swiftmesh","preferredPrimaryNodeID":null,"preferenceRevision":0,"future":true}"#)?.revision, 0)
    }

    func testMalformedOrUnknownPoliciesAreRejected() {
        let id = #""preferredPrimaryNodeID":"a""#
        for json in [
            #"{"version":1,"clusterID":"swiftmesh","preferenceRevision":1}"#,               // missing ID key ≠ null
            #"{"version":2,"clusterID":"swiftmesh",\#(id),"preferenceRevision":1}"#,         // unknown version
            #"{"version":"1","clusterID":"swiftmesh",\#(id),"preferenceRevision":1}"#,
            #"{"version":true,"clusterID":"swiftmesh",\#(id),"preferenceRevision":1}"#,
            #"{"clusterID":"swiftmesh",\#(id),"preferenceRevision":1}"#,
            #"{"version":1,"clusterID":"other",\#(id),"preferenceRevision":1}"#,             // cross-service
            #"{"version":1,"clusterID":"swiftmesh",\#(id),"preferenceRevision":-1}"#,
            #"{"version":1,"clusterID":"swiftmesh",\#(id),"preferenceRevision":1.5}"#,
            #"{"version":1,"clusterID":"swiftmesh",\#(id)}"#,
            #"{"version":1,"clusterID":"swiftmesh","preferredPrimaryNodeID":"","preferenceRevision":1}"#,
            #"{"version":1,"clusterID":"swiftmesh","preferredPrimaryNodeID":" a","preferenceRevision":1}"#,
            #"{"version":1,"clusterID":"swiftmesh","preferredPrimaryNodeID":"a\u0007","preferenceRevision":1}"#,
            #"{"version":1,"clusterID":"swiftmesh","preferredPrimaryNodeID":"\#(String(repeating: "a", count: 129))","preferenceRevision":1}"#,
            #"{"version":1,"clusterID":"swiftmesh","preferredPrimaryNodeID":7,"preferenceRevision":1}"#,
            "[]", "not json"
        ] {
            XCTAssertNil(decode(json), json)
        }
    }

    func testNodeIDsAreCaseSensitiveAndByteBounded() {
        XCTAssertEqual(decode(#"{"version":1,"clusterID":"c","preferredPrimaryNodeID":"Server-A","preferenceRevision":1}"#, cluster: "c")?.preferredPrimaryNodeID, "Server-A")
        XCTAssertTrue(MeshPrimaryPolicy.isValidNodeID(String(repeating: "a", count: 128)))
        XCTAssertFalse(MeshPrimaryPolicy.isValidNodeID(String(repeating: "é", count: 65)))
    }
}

final class MeshPrimaryPolicyClientTests: XCTestCase {
    private func client(status: Int?, body: String = "") async -> MeshWitnessClient {
        PolicyStubURLProtocol.response = status.map { ($0, Data(body.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PolicyStubURLProtocol.self]
        let client = MeshWitnessClient(session: URLSession(configuration: configuration))
        await client.configure(.init(endpoint: "https://ruru.example.com", clusterID: "swiftmesh", token: String(repeating: "t", count: 43)), nodeID: "node-a")
        return client
    }

    override func tearDown() {
        PolicyStubURLProtocol.response = nil
        PolicyStubURLProtocol.lastRequest = nil
        PolicyStubURLProtocol.lastBody = nil
        super.tearDown()
    }

    func testSendsAuthenticatedPolicyRequest() async throws {
        let fetch = await client(status: 200, body: #"{"version":1,"clusterID":"swiftmesh","preferredPrimaryNodeID":"node-b","preferenceRevision":4}"#).primaryPolicy()
        XCTAssertEqual(fetch, .policy(.init(preferredPrimaryNodeID: "node-b", revision: 4)))
        let request = try XCTUnwrap(PolicyStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://ruru.example.com/v1/service/policy")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "t", count: 43))
        XCTAssertLessThanOrEqual(request.timeoutInterval, 5)
        let body = try XCTUnwrap(PolicyStubURLProtocol.lastBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["clusterID": "swiftmesh"])
    }

    func testLegacyAndFailureResponses() async {
        let legacy = await client(status: 404).primaryPolicy()
        XCTAssertEqual(legacy, .unsupported)
        for status in [400, 401, 403, 500, 503] {
            let result = await client(status: status, body: #"{"error":"x"}"#).primaryPolicy()
            XCTAssertEqual(result, .unavailable, "\(status)")
        }
        let malformed = await client(status: 200, body: #"{"version":2,"clusterID":"swiftmesh","preferredPrimaryNodeID":null,"preferenceRevision":1}"#).primaryPolicy()
        XCTAssertEqual(malformed, .unavailable)
        let offline = await client(status: nil).primaryPolicy()
        XCTAssertEqual(offline, .unavailable)
    }

    func testUnconfiguredClientDoesNotPoll() async {
        let fetch = await MeshWitnessClient().primaryPolicy()
        XCTAssertNil(fetch)
    }
}

final class MeshPrimaryPreferenceTrackerTests: XCTestCase {
    private let t0 = ContinuousClock.now
    private func policy(_ id: String?, _ revision: Int64) -> MeshPrimaryPolicyFetch {
        .policy(.init(preferredPrimaryNodeID: id, revision: revision))
    }

    func testOutOfOrderAndContradictoryReadsAreIgnored() {
        var tracker = MeshPrimaryPreferenceTracker()
        let generation = tracker.reset(configured: true)
        XCTAssertEqual(tracker.preference.status, .checking)
        XCTAssertTrue(tracker.ingest(policy("b", 5), generation: generation, at: t0))
        XCTAssertFalse(tracker.ingest(policy("a", 4), generation: generation, at: t0))  // delayed older response
        XCTAssertEqual(tracker.preference.policy?.preferredPrimaryNodeID, "b")
        XCTAssertTrue(tracker.ingest(policy("b", 5), generation: generation, at: t0 + .seconds(5)))  // equal revision refreshes
        XCTAssertEqual(tracker.preference.receivedAt, t0 + .seconds(5))
        XCTAssertFalse(tracker.ingest(policy("c", 5), generation: generation, at: t0 + .seconds(6)))  // same revision, other answer
        XCTAssertEqual(tracker.preference.status, .unavailable)
        XCTAssertTrue(tracker.ingest(policy(nil, 6), generation: generation, at: t0 + .seconds(7)))  // clear
        XCTAssertEqual(tracker.preference.status, .current)
        XCTAssertNil(tracker.preference.policy?.preferredPrimaryNodeID)
    }

    func testConfigurationChangeDropsCachedIntentAndOldPolls() {
        var tracker = MeshPrimaryPreferenceTracker()
        let old = tracker.reset(configured: true)
        tracker.ingest(policy("b", 9), generation: old, at: t0)
        let new = tracker.reset(configured: true)
        XCTAssertNil(tracker.preference.policy)
        XCTAssertFalse(tracker.ingest(policy("b", 10), generation: old, at: t0))  // in-flight poll from old config
        // A re-added Ruru service restarts revisions at zero; accepted under the new config.
        XCTAssertTrue(tracker.ingest(policy("a", 0), generation: new, at: t0))
        XCTAssertEqual(tracker.preference.policy, .init(preferredPrimaryNodeID: "a", revision: 0))
        tracker.reset(configured: false)
        XCTAssertFalse(tracker.ingest(policy("a", 1), generation: tracker.generation, at: t0))
        XCTAssertEqual(tracker.preference.status, .notConfigured)
    }

    func testUnavailableKeepsLastForDisplayButIsNotFresh() {
        var tracker = MeshPrimaryPreferenceTracker()
        let generation = tracker.reset(configured: true)
        tracker.ingest(policy("b", 1), generation: generation, at: t0)
        XCTAssertTrue(tracker.preference.isFresh(at: t0 + .seconds(15)))
        XCTAssertFalse(tracker.preference.isFresh(at: t0 + .seconds(16)))
        tracker.ingest(.unavailable, generation: generation, at: t0 + .seconds(5))
        XCTAssertEqual(tracker.preference.policy?.preferredPrimaryNodeID, "b")
        XCTAssertNil(tracker.preference.freshPreferredNodeID(at: t0 + .seconds(5)))
        tracker.ingest(.unsupported, generation: generation, at: t0 + .seconds(6))
        XCTAssertEqual(tracker.preference.status, .unsupported)
        XCTAssertNil(tracker.preference.policy)
    }
}

final class MeshPrimaryPreferenceDecisionTests: XCTestCase {
    private let now = ContinuousClock.now
    private func current(_ id: String?, ready: Bool = true, age: Duration = .seconds(1)) -> MeshPrimaryPreference {
        MeshPrimaryPreference(status: .current, policy: .init(preferredPrimaryNodeID: id, revision: 3), receivedAt: now - age, authorityReady: ready)
    }
    private func may(_ preference: MeshPrimaryPreference, local: String = "node-b", mode: ClusterMode = .standby, configuredPrimary: Bool = false) -> Bool {
        MeshPrimaryPreferenceDecision.mayReclaimAutomatically(preference, localNodeID: local, localMode: mode, isConfiguredPrimary: configuredPrimary, now: now)
    }

    func testPreferredStandbyReclaimsAndConfiguredPrimaryDefers() {
        XCTAssertTrue(may(current("node-b")))
        // The old configured-Primary rule must not fight Ruru's choice.
        XCTAssertFalse(may(current("node-b"), local: "node-a", configuredPrimary: true))
    }

    func testClearedOrLegacyPolicyKeepsConfiguredPrimaryRule() {
        XCTAssertTrue(may(current(nil), configuredPrimary: true))
        XCTAssertFalse(may(current(nil), configuredPrimary: false))
        XCTAssertTrue(may(MeshPrimaryPreference(status: .unsupported), configuredPrimary: true))
        XCTAssertTrue(may(MeshPrimaryPreference(status: .notConfigured), configuredPrimary: true))
    }

    func testUnknownStaleOrQuarantinedIntentStartsNothing() {
        XCTAssertFalse(may(MeshPrimaryPreference(status: .checking), configuredPrimary: true))
        XCTAssertFalse(may(MeshPrimaryPreference(status: .unavailable, policy: .init(preferredPrimaryNodeID: "node-b", revision: 1)), configuredPrimary: true))
        XCTAssertFalse(may(current("node-b", age: .seconds(16))))
        XCTAssertFalse(may(current("node-b", ready: false)))  // Ruru unreachable or in restart quarantine
    }

    func testWorkersLeadersAndUnknownIdentityNeverReclaim() {
        XCTAssertFalse(may(current("node-b"), mode: .worker))
        XCTAssertFalse(may(current("node-b"), mode: .leader))
        XCTAssertFalse(may(current(""), local: ""))
    }

    func testOwnerAcceptsOnlyTheFreshPreferredTarget() {
        XCTAssertTrue(MeshPrimaryPreferenceDecision.acceptsAutomaticHandback(current("node-b"), verifiedTargetNodeID: "node-b", now: now))
        XCTAssertFalse(MeshPrimaryPreferenceDecision.acceptsAutomaticHandback(current("node-b"), verifiedTargetNodeID: "node-c", now: now))
        XCTAssertFalse(MeshPrimaryPreferenceDecision.acceptsAutomaticHandback(current("node-b"), verifiedTargetNodeID: nil, now: now))
        XCTAssertTrue(MeshPrimaryPreferenceDecision.acceptsAutomaticHandback(current(nil), verifiedTargetNodeID: "node-c", now: now))
        XCTAssertTrue(MeshPrimaryPreferenceDecision.acceptsAutomaticHandback(current("node-b", age: .seconds(30)), verifiedTargetNodeID: "node-c", now: now))
    }
}

/// Two real coordinators on loopback, with a fake lease authority that refuses
/// any second owner, so overlapping ownership would fail the test.
final class MeshPrimaryPreferenceHandbackTests: XCTestCase {
    private actor FakeAuthority {
        private(set) var owner: String?
        private(set) var term = 0
        private(set) var events: [String] = []
        /// False models Ruru being unreachable or in its restart quarantine.
        private(set) var available = true
        func setAvailable(_ value: Bool) { available = value }
        /// A Ruru restart: no current-epoch lease survives it.
        func restart() { owner = nil; events.append("restart") }
        func acquire(_ node: String, minimumTerm: Int) -> Int? {
            guard available else { return nil }
            guard owner == nil || owner == node else { events.append("refused:\(node)"); return nil }
            term = max(term + 1, minimumTerm)
            owner = node
            events.append("acquire:\(node):\(term)")
            return term
        }
        func renew(_ node: String, term: Int) -> MeshOwnershipRenewal {
            guard available else { return .unreachable(stillValid: false) }
            return owner == node && self.term == term ? .renewed : .lost
        }
        func release(_ node: String, term: Int) {
            guard owner == node, self.term == term else { return }
            owner = nil
            events.append("release:\(node)")
        }
    }

    private let keyB = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 11, count: 32))

    private func preference(_ id: String?, ready: Bool = true) -> MeshPrimaryPreference {
        MeshPrimaryPreference(status: .current, policy: .init(preferredPrimaryNodeID: id, revision: 1), receivedAt: .now, authorityReady: ready)
    }

    private func useAuthority(_ authority: FakeAuthority, node: ClusterCoordinator, id: String, witness: String? = nil) async {
        await node.setOwnershipHandlers(
            acquire: { await authority.acquire(id, minimumTerm: $0) },
            renew: { await authority.renew(id, term: $0) },
            release: { await authority.release(id, term: $0) },
            witnessFingerprint: witness
        )
    }

    private func pair(
        approveB: Bool = true, ownerWitness: String? = nil, returningWitness: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> (owner: ClusterCoordinator, returning: ClusterCoordinator, authority: FakeAuthority) {
        let ownerPort = MeshTestPorts.free()
        let returningPort = MeshTestPorts.free()
        let owner = ClusterCoordinator()
        let returning = ClusterCoordinator()
        let authority = FakeAuthority()
        let publicB = keyB.publicKey.rawRepresentation.base64EncodedString()
        await owner.configureHandlers(aiHandler: { _, _, _, _ in nil }, wikiHandler: { _, _ in nil }, onSnapshot: { _ in }, onJobLog: { _ in }, onSync: { _ in }, meshHandler: { _ in nil }, conversationFetcher: { _, _ in ([], false) })
        await owner.setHandbackDrainHandler { true }
        await owner.applySettings(mode: .leader, nodeName: "Owner", leaderAddress: "", listenPort: ownerPort, sharedSecret: "mesh", leaderTerm: 4)
        await owner.setCredentialAuthorization(provider: { approveB && $0 == "node-b" ? publicB : nil }, localNodeID: "node-a", localToken: "")
        await useAuthority(authority, node: owner, id: "node-a", witness: ownerWitness)
        // The Standby registers as soon as it is configured; with the owner
        // already listening, the first attempt succeeds instead of backing off.
        let ownerListening = await owner.waitUntilListeningForTesting()
        XCTAssertTrue(ownerListening, "Owner never listened on :\(ownerPort)", file: file, line: line)
        await returning.configureHandlers(aiHandler: { _, _, _, _ in nil }, wikiHandler: { _, _ in nil }, onSnapshot: { _ in }, onJobLog: { _ in }, onSync: { _ in }, meshHandler: { _ in nil }, conversationFetcher: { _, _ in ([], false) })
        await returning.setHandbackCatchupHandler { _, _ in true }
        await returning.applySettings(mode: .standby, nodeName: "Returning", leaderAddress: "http://127.0.0.1:\(ownerPort)", listenPort: returningPort, sharedSecret: "mesh", leaderTerm: 4)
        await returning.setCredentialAuthorization(provider: { _ in nil }, localNodeID: "node-b", localToken: keyB.rawRepresentation.base64EncodedString())
        await returning.setAutoReclaimPolicy(isConfiguredPrimary: false, afterHours: 0, automaticHandbackEnabled: true)
        await useAuthority(authority, node: returning, id: "node-b", witness: returningWitness)
        // The owner only prepares a handback for a registered target. A fixed
        // wait here made the handback tests flaky under load.
        for _ in 0..<60 where !(await owner.registeredWorkerNamesForTesting()).contains("Returning") {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let returningListening = await returning.waitUntilListeningForTesting()
        XCTAssertTrue(returningListening, "Returning never listened on :\(returningPort)", file: file, line: line)
        if approveB {
            let registered = await owner.registeredWorkerNamesForTesting().contains("Returning")
            let diagnostics = await returning.currentSnapshot().diagnostics
            XCTAssertTrue(registered, "Returning never registered: \(diagnostics)", file: file, line: line)
        }
        return (owner, returning, authority)
    }

    func testPreferredStandbyTakesBackThroughCoordinatedHandback() async {
        let (owner, returning, authority) = await pair()
        await owner.setPrimaryPreference(preference("node-b"))
        await returning.setPrimaryPreference(preference("node-b"))
        let startTerm = await authority.term

        let result = await returning.requestCoordinatedHandback(automatic: true)

        let ownerOwns = await owner.hasActiveOwnership()
        let returningOwns = await returning.hasActiveOwnership()
        let events = await authority.events
        let finalTerm = await authority.term
        let holder = await authority.owner
        XCTAssertTrue(result)
        XCTAssertFalse(ownerOwns)
        XCTAssertTrue(returningOwns)
        XCTAssertEqual(holder, "node-b")
        XCTAssertGreaterThan(finalTerm, startTerm)
        // The old owner released before the new one acquired; nothing was refused.
        XCTAssertEqual(Array(events.suffix(2)), ["release:node-a", "acquire:node-b:\(finalTerm)"])
        XCTAssertFalse(events.contains { $0.hasPrefix("refused") })
        await returning.stopAll()
        await owner.stopAll()
    }

    func testNonPreferredStandbyCannotReclaimAutomatically() async {
        let (owner, returning, authority) = await pair()
        // The owner is the preferred node; a configured Primary elsewhere must not oscillate it away.
        await owner.setPrimaryPreference(preference("node-a"))
        await returning.setAutoReclaimPolicy(isConfiguredPrimary: true, afterHours: 0, automaticHandbackEnabled: true)
        await returning.setPrimaryPreference(preference("node-a"))
        let blockedLocally = await returning.requestCoordinatedHandback(automatic: true)
        // Even with a stale local view naming itself, the owner refuses it.
        await returning.setPrimaryPreference(preference("node-b"))
        let refusedByOwner = await returning.requestCoordinatedHandback(automatic: true)

        let ownerOwns = await owner.hasActiveOwnership()
        let holder = await authority.owner
        XCTAssertFalse(blockedLocally)
        XCTAssertFalse(refusedByOwner)
        XCTAssertTrue(ownerOwns)
        XCTAssertEqual(holder, "node-a")
        await returning.stopAll()
        await owner.stopAll()
    }

    func testAutomaticHandbackNeedsVerifiedStableIdentity() async {
        let (owner, returning, authority) = await pair(approveB: false)
        await owner.setPrimaryPreference(preference("node-b"))
        await returning.setPrimaryPreference(preference("node-b"))
        let result = await returning.requestCoordinatedHandback(automatic: true)
        let ownerOwns = await owner.hasActiveOwnership()
        let holder = await authority.owner
        XCTAssertFalse(result)
        XCTAssertTrue(ownerOwns)
        XCTAssertEqual(holder, "node-a")
        await returning.stopAll()
        await owner.stopAll()
    }

    func testPreferenceChangeDuringTransferAbortsAndOwnerResumes() async {
        actor Flag { var set = false; func mark() { set = true } }
        let resumed = Flag()
        let (owner, returning, authority) = await pair()
        await owner.setHandbackResumeHandler { await resumed.mark() }
        await owner.setPrimaryPreference(preference("node-b"))
        await returning.setPrimaryPreference(preference("node-b"))
        // Ruru switches to another node while the returning Mac catches up.
        await returning.setHandbackCatchupHandler { [returning] _, _ in
            await returning.setPrimaryPreference(MeshPrimaryPreference(status: .current, policy: .init(preferredPrimaryNodeID: "node-c", revision: 2), receivedAt: .now, authorityReady: true))
            return true
        }
        let result = await returning.requestCoordinatedHandback(automatic: true)
        let didResume = await resumed.set
        let ownerOwns = await owner.hasActiveOwnership()
        let returningOwns = await returning.hasActiveOwnership()
        let holder = await authority.owner
        XCTAssertFalse(result)
        XCTAssertTrue(didResume)
        XCTAssertTrue(ownerOwns)
        XCTAssertFalse(returningOwns)
        XCTAssertEqual(holder, "node-a")
        await returning.stopAll()
        await owner.stopAll()
    }

    func testRuruQuarantineOrUnavailablePolicyStartsNoHandback() async {
        let (owner, returning, _) = await pair()
        await owner.setPrimaryPreference(preference("node-b"))
        await returning.setPrimaryPreference(preference("node-b", ready: false))
        let quarantined = await returning.requestCoordinatedHandback(automatic: true)
        await returning.setPrimaryPreference(MeshPrimaryPreference(status: .unavailable, policy: .init(preferredPrimaryNodeID: "node-b", revision: 1), authorityReady: true))
        let unavailable = await returning.requestCoordinatedHandback(automatic: true)
        let ownerOwns = await owner.hasActiveOwnership()
        XCTAssertFalse(quarantined)
        XCTAssertFalse(unavailable)
        XCTAssertTrue(ownerOwns)
        await returning.stopAll()
        await owner.stopAll()
    }

    /// The preference never blocks failover: a Standby that isn't preferred still
    /// takes over a dead Primary, through a witness lease.
    func testFailoverStillWorksWhenPreferredNodeIsOffline() async {
        let standby = ClusterCoordinator()
        let authority = FakeAuthority()
        await standby.applySettings(mode: .standby, nodeName: "Survivor", leaderAddress: "http://127.0.0.1:48299", listenPort: 48211, sharedSecret: "mesh", leaderTerm: 2)
        await useAuthority(authority, node: standby, id: "node-b")
        await standby.setPrimaryPreference(preference("node-offline"))
        await standby.promoteToLeader()
        let mode = await standby.currentSnapshot().mode
        let holder = await authority.owner
        let term = await standby.currentLeaderTerm()
        XCTAssertEqual(mode, .leader)
        XCTAssertEqual(holder, "node-b")
        XCTAssertGreaterThan(term, 2)
        await standby.stopAll()
    }

    // MARK: - Keeping and recovering the lease

    /// A configured Primary with no leader address, as in production.
    private func lonePrimary(port: Int, authority: FakeAuthority) async -> ClusterCoordinator {
        let node = ClusterCoordinator()
        await node.setOwnershipTimingForTesting(renewal: .milliseconds(100), retry: .milliseconds(50), recovery: .milliseconds(100))
        await node.applySettings(mode: .leader, nodeName: "Lone", leaderAddress: "", listenPort: port, sharedSecret: "mesh", leaderTerm: 4)
        await node.setCredentialAuthorization(provider: { _ in nil }, localNodeID: "node-a", localToken: "")
        return node
    }

    private func settle(_ node: ClusterCoordinator, until owns: Bool) async -> Bool {
        for _ in 0..<40 {
            if await node.hasActiveOwnership() == owns { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await node.hasActiveOwnership() == owns
    }

    /// One slow renewal used to demote at once, with most of the lease left.
    func testUnansweredRenewalKeepsTheLeaseWhileItIsValid() async {
        actor Replies { var queue: [MeshOwnershipRenewal] = [.unreachable(stillValid: true), .unreachable(stillValid: true)]
            func next() -> MeshOwnershipRenewal { queue.isEmpty ? .renewed : queue.removeFirst() } }
        let replies = Replies()
        let authority = FakeAuthority()
        let node = await lonePrimary(port: 48221, authority: authority)
        await node.setOwnershipHandlers(
            acquire: { await authority.acquire("node-a", minimumTerm: $0) },
            renew: { _ in await replies.next() },
            release: { await authority.release("node-a", term: $0) })
        try? await Task.sleep(for: .milliseconds(600))
        let owns = await node.hasActiveOwnership()
        let mode = await node.currentSnapshot().mode
        let events = await authority.events
        XCTAssertTrue(owns)
        XCTAssertEqual(mode, .leader)
        XCTAssertFalse(events.contains { $0.hasPrefix("release") }, "The lease is never given up for an unanswered renewal")
        await node.stopAll()
    }

    /// Ruru restarting ends the lease. A lone Primary used to stay demoted.
    func testLonePrimaryRecoversAfterRuruRestarts() async {
        let authority = FakeAuthority()
        let node = await lonePrimary(port: 48223, authority: authority)
        await node.setAutoReclaimPolicy(isConfiguredPrimary: true, afterHours: 0, automaticHandbackEnabled: true)
        await useAuthority(authority, node: node, id: "node-a")
        let startTerm = await authority.term
        await authority.setAvailable(false)
        await authority.restart()
        let demoted = await settle(node, until: false)
        await authority.setAvailable(true)
        let recovered = await settle(node, until: true)

        let holder = await authority.owner
        let term = await authority.term
        XCTAssertTrue(demoted, "Output closes once the lease can no longer be confirmed")
        XCTAssertTrue(recovered)
        XCTAssertEqual(holder, "node-a")
        XCTAssertGreaterThan(term, startTerm, "Recovery takes a new term")
        await node.stopAll()
    }

    /// Ruru unreachable or quarantined at startup used to leave the Primary passive.
    func testPrimaryStartedWithoutALeaseAcquiresOneWhenRuruReturns() async {
        let authority = FakeAuthority()
        await authority.setAvailable(false)
        let node = await lonePrimary(port: 48225, authority: authority)
        await useAuthority(authority, node: node, id: "node-a")
        let startedPassive = await node.currentSnapshot().mode == .standby
        // The configured-Primary policy arrives after the first refusal, as at launch.
        await node.setAutoReclaimPolicy(isConfiguredPrimary: true, afterHours: 0, automaticHandbackEnabled: true)
        await authority.setAvailable(true)
        let recovered = await settle(node, until: true)
        XCTAssertTrue(startedPassive)
        XCTAssertTrue(recovered)
        await node.stopAll()
    }

    func testLostLeaseToAnotherMacIsNotTakenBack() async {
        let authority = FakeAuthority()
        let node = await lonePrimary(port: 48227, authority: authority)
        await node.setAutoReclaimPolicy(isConfiguredPrimary: true, afterHours: 0, automaticHandbackEnabled: true)
        await useAuthority(authority, node: node, id: "node-a")
        await authority.restart()
        _ = await authority.acquire("node-b", minimumTerm: 0)
        let demoted = await settle(node, until: false)
        try? await Task.sleep(for: .milliseconds(400))
        let holder = await authority.owner
        let owns = await node.hasActiveOwnership()
        XCTAssertTrue(demoted)
        XCTAssertFalse(owns)
        XCTAssertEqual(holder, "node-b", "Retries are refused while another Mac holds the lease")
        await node.stopAll()
    }

    // MARK: - Matching Ruru settings

    func testStandbyWithoutTheOwnersRuruCannotTakeOver() async {
        let (owner, returning, authority) = await pair(ownerWitness: "swiftmesh@ruru.example.com")
        await returning.promoteToLeader()
        let handback = await returning.requestCoordinatedHandback()
        let diagnostics = await returning.currentSnapshot().diagnostics
        let returningMode = await returning.currentSnapshot().mode
        let ownerOwns = await owner.hasActiveOwnership()
        let holder = await authority.owner
        XCTAssertFalse(handback)
        XCTAssertEqual(returningMode, .standby)
        XCTAssertTrue(diagnostics.contains("no Ruru"), diagnostics)
        XCTAssertTrue(ownerOwns, "The owner was never frozen")
        XCTAssertEqual(holder, "node-a")
        await returning.stopAll()
        await owner.stopAll()
    }

    func testStandbyWithADifferentRuruCannotTakeOver() async {
        let (owner, returning, _) = await pair(ownerWitness: "swiftmesh@ruru.example.com", returningWitness: "swiftmesh@other.example.com")
        let handback = await returning.requestCoordinatedHandback()
        let diagnostics = await returning.currentSnapshot().diagnostics
        XCTAssertFalse(handback)
        XCTAssertTrue(diagnostics.contains("differs"), diagnostics)
        await returning.stopAll()
        await owner.stopAll()
    }

    func testMatchingRuruStillHandsBack() async {
        let fingerprint = "swiftmesh@ruru.example.com"
        let (owner, returning, authority) = await pair(ownerWitness: fingerprint, returningWitness: fingerprint)
        let handback = await returning.requestCoordinatedHandback()
        let holder = await authority.owner
        XCTAssertTrue(handback)
        XCTAssertEqual(holder, "node-b")
        await returning.stopAll()
        await owner.stopAll()
    }

    func testWorkerSelectedAsPreferredIsNeverPromotedByIt() async {
        let worker = ClusterCoordinator()
        await worker.applySettings(mode: .worker, nodeName: "Worker", leaderAddress: "http://127.0.0.1:48299", listenPort: 48213, sharedSecret: "mesh")
        await worker.setCredentialAuthorization(provider: { _ in nil }, localNodeID: "node-w", localToken: "")
        await worker.setAutoReclaimPolicy(isConfiguredPrimary: false, afterHours: 0, automaticHandbackEnabled: true)
        await worker.setPrimaryPreference(preference("node-w"))
        let result = await worker.requestCoordinatedHandback(automatic: true)
        let mode = await worker.currentSnapshot().mode
        XCTAssertFalse(result)
        XCTAssertEqual(mode, .worker)
        await worker.stopAll()
    }
}

/// Stop clears cached intent so a restart can't act on it.
@MainActor
final class MeshPrimaryPreferenceLifecycleTests: XCTestCase {
    func testStopClearsCachedPreference() async {
        let model = AppModel()
        model.settings.clusterMode = .leader
        let generation = model.meshPrimaryPreferenceTracker.reset(configured: true)
        model.meshPrimaryPreferenceTracker.ingest(.policy(.init(preferredPrimaryNodeID: "node-b", revision: 2)), generation: generation, at: .now)
        await model.publishMeshPrimaryPreference()
        XCTAssertEqual(model.meshPrimaryPreference.status, .current)

        await model.stopBot()

        XCTAssertNil(model.meshPrimaryPreference.policy)
        XCTAssertNotEqual(model.meshPrimaryPreference.status, .current)
        let coordinatorView = await model.cluster.currentPrimaryPreference()
        XCTAssertNil(coordinatorView.policy)
        XCTAssertFalse(model.meshPrimaryPreferenceTracker.ingest(.policy(.init(preferredPrimaryNodeID: "node-b", revision: 3)), generation: generation, at: .now))
    }
}

private final class PolicyStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (Int, Data)?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        guard let (status, body) = Self.response, let url = request.url,
              let reply = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
