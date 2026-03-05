import XCTest
@testable import SwiftBot

/// Forced failover drill — proves the full promotion path:
/// leader unavailable → standby promotes → worker accepts newer term → re-registers.
final class MeshFailoverTests: XCTestCase {

    // MARK: - Term Persistence

    func testTermRestoredOnApplySettings() async {
        let coordinator = ClusterCoordinator()
        await coordinator.applySettings(
            mode: .standby,
            nodeName: "RestoredNode",
            leaderAddress: "http://127.0.0.1:39100",
            listenPort: 39101,
            sharedSecret: "",
            leaderTerm: 5
        )
        let term = await coordinator.testCurrentLeaderTerm()
        XCTAssertEqual(term, 5)
    }

    func testTermNeverGoesBackwards() async {
        let coordinator = ClusterCoordinator()
        await coordinator.applySettings(
            mode: .standby,
            nodeName: "Node",
            leaderAddress: "http://127.0.0.1:39102",
            listenPort: 39103,
            sharedSecret: "",
            leaderTerm: 10
        )
        // Re-apply with a stale term — must not regress.
        await coordinator.applySettings(
            mode: .standby,
            nodeName: "Node",
            leaderAddress: "http://127.0.0.1:39102",
            listenPort: 39103,
            sharedSecret: "",
            leaderTerm: 3
        )
        let term = await coordinator.testCurrentLeaderTerm()
        XCTAssertEqual(term, 10)
    }

    func testTermPersistedOnPromotion() async {
        var persistedTerm: Int = 0
        let coordinator = ClusterCoordinator()
        await coordinator.applySettings(
            mode: .standby,
            nodeName: "StandbyNode",
            leaderAddress: "http://127.0.0.1:39104",
            listenPort: 39105,
            sharedSecret: "",
            leaderTerm: 2
        )
        await coordinator.setTermChangedHandler { newTerm in
            persistedTerm = newTerm
        }

        for _ in 0..<3 {
            await coordinator.testSimulateLeaderHealthMiss()
        }

        let mode = await coordinator.testCurrentMode()
        let term = await coordinator.testCurrentLeaderTerm()
        XCTAssertEqual(mode, .leader)
        XCTAssertEqual(term, 3)          // 2 + 1
        XCTAssertEqual(persistedTerm, 3) // callback fired with new term
    }

    // MARK: - Forced Failover Drill

    func testStandbyPromotesAfterThreeMisses() async {
        let standby = ClusterCoordinator()
        await standby.applySettings(
            mode: .standby,
            nodeName: "StandbyDrill",
            leaderAddress: "http://127.0.0.1:39106",
            listenPort: 39107,
            sharedSecret: "drill-secret",
            leaderTerm: 0
        )

        let initialMode = await standby.testCurrentMode()
        XCTAssertEqual(initialMode, .standby)

        await standby.testSimulateLeaderHealthMiss()
        await standby.testSimulateLeaderHealthMiss()
        let modeBeforeThreshold = await standby.testCurrentMode()
        XCTAssertEqual(modeBeforeThreshold, .standby, "Should not promote before 3 misses")

        await standby.testSimulateLeaderHealthMiss()
        let promotedMode = await standby.testCurrentMode()
        let promotedTerm = await standby.testCurrentLeaderTerm()
        XCTAssertEqual(promotedMode, .leader)
        XCTAssertEqual(promotedTerm, 1)
    }

    func testWorkerAcceptsNewerTermLeaderChanged() async {
        let worker = ClusterCoordinator()
        await worker.applySettings(
            mode: .worker,
            nodeName: "WorkerDrill",
            leaderAddress: "http://127.0.0.1:39108",
            listenPort: 39109,
            sharedSecret: "drill-secret",
            leaderTerm: 1
        )

        let payload = MeshLeaderChangedPayload(
            term: 2,
            leaderAddress: "http://127.0.0.1:39110",
            leaderNodeName: "PromotedStandby",
            sharedSecret: "drill-secret"
        )
        let body = (try? JSONEncoder().encode(payload)) ?? Data()
        let signedHeaders = await worker.testMakeHMACHeaders(path: "/v1/mesh/leader-changed", body: body)
        let request = makeRequest(
            method: "POST", path: "/v1/mesh/leader-changed",
            headers: signedHeaders, body: body
        )
        let response = await worker.testProcessHTTPRequest(request)

        let newAddress = await worker.testCurrentLeaderAddress()
        let newTerm = await worker.testCurrentLeaderTerm()
        XCTAssertEqual(statusCode(from: response), 200)
        XCTAssertEqual(newAddress, "http://127.0.0.1:39110")
        XCTAssertEqual(newTerm, 2)
    }

    func testWorkerRejectsStaleTermLeaderChanged() async {
        let worker = ClusterCoordinator()
        await worker.applySettings(
            mode: .worker,
            nodeName: "WorkerStale",
            leaderAddress: "http://127.0.0.1:39111",
            listenPort: 39112,
            sharedSecret: "drill-secret",
            leaderTerm: 5
        )

        let payload = MeshLeaderChangedPayload(
            term: 3,
            leaderAddress: "http://127.0.0.1:39113",
            leaderNodeName: "ZombieLeader",
            sharedSecret: "drill-secret"
        )
        let body = (try? JSONEncoder().encode(payload)) ?? Data()
        let signedHeaders = await worker.testMakeHMACHeaders(path: "/v1/mesh/leader-changed", body: body)
        let request = makeRequest(
            method: "POST", path: "/v1/mesh/leader-changed",
            headers: signedHeaders, body: body
        )
        let response = await worker.testProcessHTTPRequest(request)

        let addressAfter = await worker.testCurrentLeaderAddress()
        let termAfter = await worker.testCurrentLeaderTerm()
        XCTAssertEqual(statusCode(from: response), 409, "Stale term must be rejected")
        XCTAssertEqual(addressAfter, "http://127.0.0.1:39111", "Leader address must not change")
        XCTAssertEqual(termAfter, 5, "Term must not regress")
    }

    /// Full drill: standby promotes → broadcasts leader-changed → worker accepts and re-registers.
    func testFullFailoverDrillSequence() async {
        // Step 1: standby at term 0 reaches promotion threshold.
        let standby = ClusterCoordinator()
        await standby.applySettings(
            mode: .standby,
            nodeName: "FullDrillStandby",
            leaderAddress: "http://127.0.0.1:39114",
            listenPort: 39115,
            sharedSecret: "drill-secret",
            leaderTerm: 0
        )
        for _ in 0..<3 { await standby.testSimulateLeaderHealthMiss() }

        let standbyMode = await standby.testCurrentMode()
        let promotedTerm = await standby.testCurrentLeaderTerm()
        XCTAssertEqual(standbyMode, .leader, "Standby must promote")
        XCTAssertEqual(promotedTerm, 1)

        // Step 2: worker at term 0 receives leader-changed from promoted standby.
        let worker = ClusterCoordinator()
        await worker.applySettings(
            mode: .worker,
            nodeName: "FullDrillWorker",
            leaderAddress: "http://127.0.0.1:39114",  // old (dead) leader
            listenPort: 39116,
            sharedSecret: "drill-secret",
            leaderTerm: 0
        )

        let newLeaderAddress = "http://127.0.0.1:39115"
        let changedPayload = MeshLeaderChangedPayload(
            term: promotedTerm,
            leaderAddress: newLeaderAddress,
            leaderNodeName: "FullDrillStandby",
            sharedSecret: "drill-secret"
        )
        let body = (try? JSONEncoder().encode(changedPayload)) ?? Data()
        let signedHeaders = await worker.testMakeHMACHeaders(path: "/v1/mesh/leader-changed", body: body)
        let request = makeRequest(
            method: "POST", path: "/v1/mesh/leader-changed",
            headers: signedHeaders, body: body
        )
        let response = await worker.testProcessHTTPRequest(request)

        // Step 3: verify worker accepted and redirected.
        let finalAddress = await worker.testCurrentLeaderAddress()
        let finalTerm = await worker.testCurrentLeaderTerm()
        XCTAssertEqual(statusCode(from: response), 200, "Worker must accept valid promotion")
        XCTAssertEqual(finalAddress, newLeaderAddress, "Worker must point to new leader")
        XCTAssertEqual(finalTerm, promotedTerm, "Worker term must match promoted term")
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
