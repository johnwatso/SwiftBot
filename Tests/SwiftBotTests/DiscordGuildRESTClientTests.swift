import XCTest
@testable import SwiftBot

final class DiscordGuildRESTClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.clear()
        super.tearDown()
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
}

private final class MockURLProtocol: URLProtocol {
    private static var lock = NSLock()
    private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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
