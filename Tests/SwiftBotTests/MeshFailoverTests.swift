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
        let termPersisted = expectation(description: "Accepted leader-changed term is persisted")
        await worker.setTermChangedHandler { newTerm in
            if newTerm == 2 {
                termPersisted.fulfill()
            }
        }

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
        await fulfillment(of: [termPersisted], timeout: 2.0)
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

    // MARK: - Startup Reconciliation

    func testReturningPrimaryStartsAsStandbyWhenHealthyLeaderExists() async {
        let sharedSecret = "reconcile-secret"
        let activeLeaderAddress = "http://127.0.0.1:39220"

        let activeLeader = ClusterCoordinator()
        await activeLeader.applySettings(
            mode: .leader,
            nodeName: "ActiveLeader",
            leaderAddress: "",
            listenPort: 39220,
            sharedSecret: sharedSecret,
            leaderTerm: 7
        )

        // Give listener a brief moment to be ready before probing.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let returningPrimary = ClusterCoordinator()
        await returningPrimary.applySettings(
            mode: .leader,
            nodeName: "ReturningPrimary",
            leaderAddress: activeLeaderAddress,
            listenPort: 39221,
            sharedSecret: sharedSecret,
            leaderTerm: 3
        )

        let reconciledMode = await returningPrimary.testCurrentMode()
        XCTAssertEqual(reconciledMode, .standby, "Returning node must demote to standby when a healthy leader already exists")

        var registered = false
        for _ in 0..<15 {
            let nodes = await activeLeader.registeredNodeInfo()
            if nodes.contains(where: { $0.nodeName == "ReturningPrimary" }) {
                registered = true
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(registered, "Reconciled standby should register with the active leader")

        await returningPrimary.stopAll()
        await activeLeader.stopAll()
    }

    func testConfiguredLeaderUnreachableKeepsLeaderModeAtStartup() async {
        let coordinator = ClusterCoordinator()
        await coordinator.applySettings(
            mode: .leader,
            nodeName: "ColdStartPrimary",
            leaderAddress: "http://127.0.0.1:39222",
            listenPort: 39223,
            sharedSecret: "reconcile-secret",
            leaderTerm: 1
        )

        let mode = await coordinator.testCurrentMode()
        XCTAssertEqual(mode, .leader, "Node should remain leader when no healthy configured leader responds")
        await coordinator.stopAll()
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
