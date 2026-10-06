import XCTest
@testable import SwiftBot

final class DiscordGuildRESTClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.clear()
        super.tearDown()
    }

    func testScheduledEventsDecodeAndRequestSubscriberCounts() async throws {
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v10/guilds/guild-1/scheduled-events")
            XCTAssertEqual(request.url?.query, "with_user_count=true")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bot token-123")
            let body = #"[{"id":"event-1","guild_id":"guild-1","name":"Season 12","scheduled_start_time":"2026-10-08T08:00:00+00:00","status":1,"user_count":42}]"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let events = try await DiscordGuildRESTClient(session: makeMockSession()).fetchScheduledEvents(guildID: "guild-1", token: "token-123")
        XCTAssertEqual(events.first?.name, "Season 12")
        XCTAssertEqual(events.first?.userCount, 42)
        XCTAssertNotNil(events.first?.startDate)
    }

    func testFetchGuildOwnerIDParsesOwnerField() async {
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v10/guilds/guild-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bot token-123")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = #"{"owner_id":"owner-42"}"#.data(using: .utf8)!
            return (response, data)
        }

        let client = DiscordGuildRESTClient(session: makeMockSession())
        let ownerId = await client.fetchGuildOwnerID(guildID: "guild-1", token: "token-123")

        XCTAssertEqual(ownerId, "owner-42")
    }

    func testFetchGuildMemberRoleIDsParsesRolesArray() async {
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v10/guilds/guild-1/members/user-7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bot token-123")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = #"{"roles":["admin-role","mod-role"]}"#.data(using: .utf8)!
            return (response, data)
        }

        let client = DiscordGuildRESTClient(session: makeMockSession())
        let roleIds = await client.fetchGuildMemberRoleIDs(guildID: "guild-1", userID: "user-7", token: "token-123")

        XCTAssertEqual(roleIds, ["admin-role", "mod-role"])
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testBanUsesAuditHeaderAndSecondsCleanup() async throws {
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/v10/guilds/guild-1/bans/user-7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bot token-123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Audit-Log-Reason")?.removingPercentEncoding, "Spam / scam & abuse")
            let body = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as? [String: Int]
            XCTAssertEqual(body?["delete_message_seconds"], 86400)
            XCTAssertNil(body?["delete_message_days"])
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await DiscordGuildRESTClient(session: makeMockSession()).banMember(
            guildId: "guild-1", userId: "user-7", reason: "Spam / scam & abuse", deleteMessageSeconds: 86400, token: "token-123")
    }

    func testRemovingTimeoutSendsExplicitNull() async throws {
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/api/v10/guilds/guild-1/members/user-7")
            let body = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as? [String: Any]
            XCTAssertTrue(body?["communication_disabled_until"] is NSNull)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await DiscordGuildRESTClient(session: makeMockSession()).removeTimeout(guildId: "guild-1", userId: "user-7", token: "token-123")
    }

    func testKickReasonUsesAuditHeaderRatherThanQuery() async throws {
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Audit-Log-Reason")?.removingPercentEncoding, "Repeated spam")
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await DiscordGuildRESTClient(session: makeMockSession()).kickMember(guildId: "guild-1", userId: "user-7", reason: "Repeated spam", token: "token-123")
    }

    func testBanReportsDiscordPermissionFailure() async {
        MockURLProtocol.setHandler { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            try await DiscordGuildRESTClient(session: makeMockSession()).banMember(guildId: "guild-1", userId: "user-7", reason: "spam", deleteMessageSeconds: 0, token: "token-123")
            XCTFail("A failed Discord ban must not be reported as success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Failed to ban"))
        }
    }

    func testModerationLimitsRejectBeforeSendingRequest() async {
        MockURLProtocol.setHandler { _ in
            XCTFail("Invalid moderation limits must not reach Discord")
            throw URLError(.badURL)
        }
        let client = DiscordGuildRESTClient(session: makeMockSession())
        for seconds in [-1, 604801] {
            do {
                try await client.banMember(guildId: "g", userId: "u", reason: "", deleteMessageSeconds: seconds, token: "t")
                XCTFail("Expected invalid cleanup duration to fail")
            } catch { XCTAssertTrue(error is ValidationError) }
        }
        for seconds in [0, 2419201] {
            do {
                try await client.timeoutMember(guildId: "g", userId: "u", durationSeconds: seconds, token: "t")
                XCTFail("Expected invalid timeout duration to fail")
            } catch { XCTAssertTrue(error is ValidationError) }
        }
    }

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
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
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

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
