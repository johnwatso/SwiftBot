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

        let healthNoSecret = await coordinator.testProcessHTTPRequest(
            makeRequest(method: "GET", path: "/health", headers: [:], body: Data())
        )
        XCTAssertEqual(statusCode(from: healthNoSecret), 200)

        let missingSecret = await coordinator.testProcessHTTPRequest(
            makeRequest(method: "POST", path: "/v1/ai-reply", headers: [:], body: Data("{}".utf8))
        )
        XCTAssertEqual(statusCode(from: missingSecret), 401)

        let wrongSecret = await coordinator.testProcessHTTPRequest(
            makeRequest(
                method: "POST",
                path: "/v1/ai-reply",
                headers: ["X-Cluster-Secret": "wrong"],
                body: Data("{}".utf8)
            )
        )
        XCTAssertEqual(statusCode(from: wrongSecret), 401)

        let correctSecret = await coordinator.testProcessHTTPRequest(
            makeRequest(
                method: "POST",
                path: "/v1/ai-reply",
                headers: ["X-Cluster-Secret": "hunter2"],
                body: Data("{}".utf8)
            )
        )
        XCTAssertEqual(statusCode(from: correctSecret), 503)
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
