import XCTest
@testable import SwiftBot

final class ClusterSecurityTests: XCTestCase {
    func testSSRFSafeHostValidation() async {
        let coordinator = ClusterCoordinator()

        let localhost = await coordinator.testIsSSRFSafeHost("localhost")
        let loopback = await coordinator.testIsSSRFSafeHost("127.0.0.1")
        let ipv6Loopback = await coordinator.testIsSSRFSafeHost("::1")
        let private192 = await coordinator.testIsSSRFSafeHost("192.168.1.50")
        let private10 = await coordinator.testIsSSRFSafeHost("10.0.0.1")
        let bonjour = await coordinator.testIsSSRFSafeHost("node.local")

        let metadata = await coordinator.testIsSSRFSafeHost("169.254.169.254")
        let anyHost = await coordinator.testIsSSRFSafeHost("0.0.0.0")
        let publicHost = await coordinator.testIsSSRFSafeHost("evil.com")

        XCTAssertTrue(localhost)
        XCTAssertTrue(loopback)
        XCTAssertTrue(ipv6Loopback)
        XCTAssertTrue(private192)
        XCTAssertTrue(private10)
        XCTAssertTrue(bonjour)
        XCTAssertFalse(metadata)
        XCTAssertFalse(anyHost)
        XCTAssertFalse(publicHost)
    }

    func testNormalizedBaseURLRejectsPublicHosts() async {
        let coordinator = ClusterCoordinator()

        let privateURL = await coordinator.testNormalizedBaseURL("192.168.1.50:38787")
        let localhostURL = await coordinator.testNormalizedBaseURL("http://localhost:8080")
        let publicURL = await coordinator.testNormalizedBaseURL("https://evil.com")
        let metadataURL = await coordinator.testNormalizedBaseURL("169.254.169.254")

        XCTAssertEqual(privateURL, "http://192.168.1.50:38787")
        XCTAssertEqual(localhostURL, "http://localhost:8080")
        XCTAssertNil(publicURL)
        XCTAssertNil(metadataURL)
    }

    func testClusterSecretAuthRoutes() async {
        let coordinator = ClusterCoordinator()
        await coordinator.applySettings(
            mode: .standalone,
            nodeName: "Test",
            leaderAddress: "",
            listenPort: 39000,
            sharedSecret: "hunter2"
        )

        // /health is always open regardless of auth
        let healthNoSecret = await coordinator.testProcessHTTPRequest(
            makeRequest(method: "GET", path: "/health", headers: [:], body: Data())
        )
        XCTAssertEqual(statusCode(from: healthNoSecret), 200)

        // Missing HMAC headers → 401
        let missingSecret = await coordinator.testProcessHTTPRequest(
            makeRequest(method: "POST", path: "/v1/ai-reply", headers: [:], body: Data("{}".utf8))
        )
        XCTAssertEqual(statusCode(from: missingSecret), 401)

        // Old X-Cluster-Secret header (wrong scheme) → 401
        let wrongSecret = await coordinator.testProcessHTTPRequest(
            makeRequest(
                method: "POST",
                path: "/v1/ai-reply",
                headers: ["X-Cluster-Secret": "hunter2"],
                body: Data("{}".utf8)
            )
        )
        XCTAssertEqual(statusCode(from: wrongSecret), 401)

        // Valid HMAC signature → auth passes, 503 because no AI handler is wired in test
        let body = Data("{}".utf8)
        let signedHeaders = await coordinator.testMakeHMACHeaders(path: "/v1/ai-reply", body: body)
        let validSig = await coordinator.testProcessHTTPRequest(
            makeRequest(method: "POST", path: "/v1/ai-reply", headers: signedHeaders, body: body)
        )
        XCTAssertEqual(statusCode(from: validSig), 503)
    }

    func testClusterSecretBackwardCompatWhenEmpty() async {
        let coordinator = ClusterCoordinator()
        await coordinator.applySettings(
            mode: .standalone,
            nodeName: "Test",
            leaderAddress: "",
            listenPort: 39001,
            sharedSecret: ""
        )

        let noSecret = await coordinator.testProcessHTTPRequest(
            makeRequest(method: "GET", path: "/cluster/status", headers: [:], body: Data())
        )
        XCTAssertEqual(statusCode(from: noSecret), 200)
    }

    func testBodySizeCapThreshold() async {
        let coordinator = ClusterCoordinator()

        let oneMeg = await coordinator.testExceedsHTTPRequestSizeCap(1_048_576)
        let oneMegPlusOne = await coordinator.testExceedsHTTPRequestSizeCap(1_048_577)

        XCTAssertFalse(oneMeg)
        XCTAssertTrue(oneMegPlusOne)
    }

    func testEventBusSubscribeThenPublishNoRace() async {
        struct TestEvent: Event {
            let value: Int
        }

        let bus = EventBus()
        let exp = expectation(description: "event-delivered")
        _ = await bus.subscribe(TestEvent.self) { event in
            XCTAssertEqual(event.value, 42)
            exp.fulfill()
        }

        await bus.publish(TestEvent(value: 42))
        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testNonceReplayRejected() async {
        let coordinator = ClusterCoordinator()
        await coordinator.applySettings(
            mode: .standalone,
            nodeName: "ReplayTest",
            leaderAddress: "",
            listenPort: 39010,
            sharedSecret: "replay-secret"
        )

        let body = Data("{}".utf8)
        // Generate a single signed header set — same nonce will be reused.
        let signedHeaders = await coordinator.testMakeHMACHeaders(method: "POST", path: "/v1/ai-reply", body: body)

        let first = await coordinator.testProcessHTTPRequest(
            makeRequest(method: "POST", path: "/v1/ai-reply", headers: signedHeaders, body: body)
        )
        // First request: auth passes, handler absent → 503
        XCTAssertEqual(statusCode(from: first), 503, "First request with valid HMAC should pass auth")

        let second = await coordinator.testProcessHTTPRequest(
            makeRequest(method: "POST", path: "/v1/ai-reply", headers: signedHeaders, body: body)
        )
        // Second request: same nonce → replay → 401
        XCTAssertEqual(statusCode(from: second), 401, "Replayed nonce must be rejected")
    }

    func testStaleTimestampRejected() async {
        let coordinator = ClusterCoordinator()
        await coordinator.applySettings(
            mode: .standalone,
            nodeName: "StaleTest",
            leaderAddress: "",
            listenPort: 39011,
            sharedSecret: "stale-secret"
        )

        // Build headers manually with a timestamp 301s in the past.
        let staleTimestamp = Int(Date().timeIntervalSince1970) - 301
        let nonce = "stale-nonce-\(staleTimestamp)"
        let body = Data("{}".utf8)
        // We can't call meshSignature directly, so use testMakeHMACHeaders and
        // then overwrite the timestamp to simulate a stale request.
        var headers = await coordinator.testMakeHMACHeaders(method: "POST", path: "/v1/ai-reply", body: body)
        headers["X-Mesh-Timestamp"] = String(staleTimestamp)
        // Signature is now invalid for the stale timestamp — but skew check fires first.
        headers["X-Mesh-Nonce"] = nonce

        let response = await coordinator.testProcessHTTPRequest(
            makeRequest(method: "POST", path: "/v1/ai-reply", headers: headers, body: body)
        )
        XCTAssertEqual(statusCode(from: response), 401, "Stale timestamp must be rejected")
    }

    func testMethodMismatchRejected() async {
        let coordinator = ClusterCoordinator()
        await coordinator.applySettings(
            mode: .standalone,
            nodeName: "MethodTest",
            leaderAddress: "",
            listenPort: 39012,
            sharedSecret: "method-secret"
        )

        let body = Data("{}".utf8)
        // Sign as GET, send as POST — method mismatch should fail signature verification.
        let signedHeaders = await coordinator.testMakeHMACHeaders(method: "GET", path: "/v1/ai-reply", body: body)
        let response = await coordinator.testProcessHTTPRequest(
            makeRequest(method: "POST", path: "/v1/ai-reply", headers: signedHeaders, body: body)
        )
        XCTAssertEqual(statusCode(from: response), 401, "Method mismatch must be rejected")
    }

    private func makeRequest(method: String, path: String, headers: [String: String], body: Data) -> Data {
        var raw = "\(method) \(path) HTTP/1.1\r\n"
        raw += "Host: localhost\r\n"
        for (name, value) in headers {
            raw += "\(name): \(value)\r\n"
        }
        raw += "Content-Length: \(body.count)\r\n"
        raw += "\r\n"

        var data = Data(raw.utf8)
        data.append(body)
        return data
    }

    private func statusCode(from response: Data) -> Int {
        guard let text = String(data: response, encoding: .utf8),
              let firstLine = text.components(separatedBy: "\r\n").first else {
            return -1
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else {
            return -1
        }
        return code
    }
}
