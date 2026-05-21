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
