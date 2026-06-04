import XCTest
import CryptoKit
@testable import SwiftBot

@MainActor
final class SwiftMinerE2EIntegrationTests: XCTestCase {

    private let testSecret = "test_webhook_secret_key_32_bytes_long"
    private let testApiKey = "test_api_key_32_bytes_long_here_now"

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        MockURLProtocol.clear()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    func testWebhookDMLifecycleSuccess() async throws {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = AppModel(discordRESTSession: session)

        // Wait briefly for any async initialization tasks to run (e.g. restoring settings from disk)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Force standalone mode to make sure ActionDispatcher allows sending,
        // and override any local/disk settings that might have been loaded.
        await model.applyClusterSettingsRuntime(
            mode: .standalone,
            nodeName: "TestNode",
            leaderAddress: "",
            leaderPort: 0,
            listenPort: 38787,
            sharedSecret: ""
        )

        model.settings.clusterMode = .standalone
        model.settings.swiftMiner.enabled = true
        model.settings.swiftMiner.webhookSecret = testSecret
        model.settings.swiftMiner.apiKey = testApiKey
        model.settings.swiftMiner.baseURL = "http://127.0.0.1:8080"
        model.logs.clear()
        model.events.removeAll()

        await model.service.setBotTokenForTesting("bot-token-999")

        let projectionExpectation = expectation(description: "SwiftMiner projection requested")
        let dmChannelExpectation = expectation(description: "Discord DM channel created")
        let dmSendExpectation = expectation(description: "Discord DM message sent")

        MockURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            let host = request.url?.host ?? ""

            // Intercept SwiftMiner Client Lookups
            if host == "127.0.0.1" && path == "/v1/discord/users/user_123" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bot \(self.testApiKey)")
                projectionExpectation.fulfill()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = """
                {
                    "discordUserId": "user_123",
                    "state": "active",
                    "account": {
                        "twitchAccountId": "twitch_123",
                        "username": "bob"
                    },
                    "activeCampaign": {
                        "campaignId": "camp_456",
                        "game": "The Finals",
                        "progress": {
                            "current": 30,
                            "required": 60,
                            "unit": "minutes",
                            "pct": 50
                        },
                        "endsAt": "2026-05-27T16:28:22Z"
                    },
                    "issues": []
                }
                """.data(using: .utf8)!
                return (response, data)
            }

            // Intercept Discord REST DM channels creation
            if host == "discord.com" && path == "/api/v10/users/@me/channels" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bot bot-token-999")
                dmChannelExpectation.fulfill()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = #"{"id":"dm_channel_99","type":1}"#.data(using: .utf8)!
                return (response, data)
            }

            // Intercept Discord REST sendMessage
            if host == "discord.com" && path == "/api/v10/channels/dm_channel_99/messages" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bot bot-token-999")
                let bodyData = request.bodyStreamData() ?? request.httpBody ?? Data()
                let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
                XCTAssertTrue(bodyString.contains("SwiftMiner claimed a Drop"), "Expected claim message. Got: \(bodyString)")
                XCTAssertTrue(bodyString.contains("The Finals"), "Expected game name. Got: \(bodyString)")
                dmSendExpectation.fulfill()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = #"{"id":"msg-abc-123"}"#.data(using: .utf8)!
                return (response, data)
            }

            XCTFail("Unexpected request intercepted: \(host)\(path)")
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        // Construct Signed Webhook Payload
        let jsonPayload = """
        {
            "eventId": "evt_claim_01",
            "eventType": "user.dropClaimed",
            "subject": {
                "discordUserId": "user_123"
            }
        }
        """.data(using: .utf8)!

        let headers = makeHMACHeaders(secret: testSecret, body: jsonPayload)

        let result = await model.handleSwiftMinerWebhook(headers: headers, body: jsonPayload)
        XCTAssertEqual(result.status, "200 OK")

        await fulfillment(of: [projectionExpectation, dmChannelExpectation, dmSendExpectation], timeout: 2.0)

        // Verify state tracking
        XCTAssertTrue(
            model.events.contains { $0.message.contains("SwiftMiner event user.dropClaimed delivered") },
            "Expected activity event log. Events: \(model.events)"
        )
    }

    func testWebhookUnauthorizedWithInvalidSignature() async {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = AppModel(discordRESTSession: session)

        // Wait briefly for any async initialization tasks to run
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Force standalone mode
        await model.applyClusterSettingsRuntime(
            mode: .standalone,
            nodeName: "TestNode",
            leaderAddress: "",
            leaderPort: 0,
            listenPort: 38787,
            sharedSecret: ""
        )

        model.settings.clusterMode = .standalone
        model.settings.swiftMiner.enabled = true
        model.settings.swiftMiner.webhookSecret = testSecret

        let jsonPayload = """
        {
            "eventId": "evt_claim_01",
            "eventType": "user.dropClaimed",
            "subject": {
                "discordUserId": "user_123"
            }
        }
        """.data(using: .utf8)!

        let headers = [
            "x-swiftminer-timestamp": String(Int(Date().timeIntervalSince1970)),
            "x-swiftminer-signature": "v1=invalid_signature_hash_here"
        ]

        let result = await model.handleSwiftMinerWebhook(headers: headers, body: jsonPayload)
        XCTAssertEqual(result.status, "401 Unauthorized")
    }

    func testSwiftMinerStatusCommandRendersActiveCampaignClearly() async {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = AppModel(discordRESTSession: session)

        model.settings.swiftMiner.enabled = true
        model.settings.swiftMiner.apiKey = testApiKey
        model.settings.swiftMiner.baseURL = "http://127.0.0.1:8080"

        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/v1/discord/users/user_123")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {
                "discordUserId": "user_123",
                "state": "active",
                "account": {
                    "twitchAccountId": "twitch_123",
                    "username": "bob"
                },
                "activeCampaign": {
                    "campaignId": "camp_456",
                    "game": "The Finals",
                    "progress": {
                        "current": 30,
                        "required": 60,
                        "unit": "minutes",
                        "pct": 50
                    },
                    "endsAt": "2026-05-27T16:28:22Z"
                },
                "recentCompletedCampaigns": [
                    {
                        "campaignId": "camp_done_1",
                        "campaignName": "Finals Launch Drops",
                        "game": "The Finals",
                        "completedAt": "2026-05-26T10:00:00Z",
                        "claimedDrops": 4,
                        "totalDrops": 4
                    }
                ],
                "issues": []
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        let result = await model.swiftMinerCommand(action: "status", userId: "user_123", channelId: "channel_1")

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.message.contains("**SwiftMiner is mining The Finals.**"))
        XCTAssertTrue(result.message.contains("Progress: **50%** (30/60 minutes)"))
        XCTAssertTrue(result.message.contains("Ends: <t:1779899302:R>"))
        XCTAssertTrue(result.message.contains("Recently mined:"))
        XCTAssertTrue(result.message.contains("**The Finals** — Finals Launch Drops — 4/4 Drops claimed"))
    }

    func testSwiftMinerStatusCommandExplainsSetupWhenNotConfigured() async {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = AppModel(discordRESTSession: session)

        model.settings.swiftMiner.enabled = true
        model.settings.swiftMiner.apiKey = testApiKey
        model.settings.swiftMiner.baseURL = "http://127.0.0.1:8080"

        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/v1/discord/users/user_123")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {
                "discordUserId": "user_123",
                "state": "notConfigured",
                "account": null,
                "activeCampaign": null,
                "recentCompletedCampaigns": [],
                "issues": []
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        let result = await model.swiftMinerCommand(action: "status", userId: "user_123", channelId: "channel_1")

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.message.contains("**Twitch is not linked yet.**"))
        XCTAssertTrue(result.message.contains("`/miner action:setup`"))
    }

    func testSwiftMinerStatusCommandShowsIdleAsUpToDateWithRecentCampaigns() async {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = AppModel(discordRESTSession: session)

        model.settings.swiftMiner.enabled = true
        model.settings.swiftMiner.apiKey = testApiKey
        model.settings.swiftMiner.baseURL = "http://127.0.0.1:8080"

        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/v1/discord/users/user_123")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {
                "discordUserId": "user_123",
                "state": "idle",
                "account": {
                    "twitchAccountId": "twitch_123",
                    "username": "bob"
                },
                "activeCampaign": null,
                "recentCompletedCampaigns": [
                    {
                        "campaignId": "camp_done_1",
                        "campaignName": "Launch Drops",
                        "game": "The Finals",
                        "completedAt": "2026-05-26T10:00:00Z",
                        "claimedDrops": 4,
                        "totalDrops": 4
                    },
                    {
                        "campaignId": "camp_done_2",
                        "campaignName": "Rivalry Week",
                        "game": "Rocket League",
                        "completedAt": "2026-05-25T10:00:00Z",
                        "claimedDrops": 2,
                        "totalDrops": 2
                    }
                ],
                "issues": []
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        let result = await model.swiftMinerCommand(action: "status", userId: "user_123", channelId: "channel_1")

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.message.contains("**Your miner is fully up to date for @bob.**"))
        XCTAssertTrue(result.message.contains("There are no active Drops ready to mine right now."))
        XCTAssertTrue(result.message.contains("**The Finals** — Launch Drops — 4/4 Drops claimed"))
        XCTAssertTrue(result.message.contains("**Rocket League** — Rivalry Week — 2/2 Drops claimed"))
    }

    // MARK: - Helpers

    private func makeHMACHeaders(secret: String, body: Data) -> [String: String] {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let signed = Data("\(timestamp).".utf8) + body
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: signed, using: key)
            .map { String(format: "%02x", $0) }
            .joined()
        return [
            "x-swiftminer-timestamp": timestamp,
            "x-swiftminer-signature": "v1=\(signature)"
        ]
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func clear() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        let host = url.host ?? ""
        let path = url.path
        if host == "discord.com" { return true }
        if host == "127.0.0.1" && path.hasPrefix("/v1/discord/users/") { return true }
        return false
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            XCTFail("Missing request handler for MockURLProtocol.")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
