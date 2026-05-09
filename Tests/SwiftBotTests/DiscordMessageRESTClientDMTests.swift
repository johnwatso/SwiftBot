import XCTest
@testable import SwiftBot

final class DiscordMessageRESTClientDMTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.clear()
        super.tearDown()
    }

    // MARK: - createDirectMessageChannel

    func testCreateDMChannelSuccessParsesChannelID() async throws {
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v10/users/@me/channels")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bot token-abc")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = #"{"id":"dm-channel-123","type":1}"#.data(using: .utf8)!
            return (response, data)
        }

        let client = DiscordMessageRESTClient(session: makeMockSession())
        let channelId = try await client.createDirectMessageChannel(userId: "user-7", token: "token-abc")

        XCTAssertEqual(channelId, "dm-channel-123")
    }

    func testCreateDMChannelForbiddenThrows() async {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = #"{"message":"Cannot send messages to this user"}"#.data(using: .utf8)!
            return (response, data)
        }

        let client = DiscordMessageRESTClient(session: makeMockSession())

        do {
            _ = try await client.createDirectMessageChannel(userId: "user-7", token: "token-abc")
            XCTFail("Expected createDirectMessageChannel to throw on 403")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "DiscordService")
            XCTAssertEqual(nsError.code, -1)
        }
    }

    func testCreateDMChannelMissingIdThrows() async {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = #"{"type":1}"#.data(using: .utf8)!
            return (response, data)
        }

        let client = DiscordMessageRESTClient(session: makeMockSession())

        do {
            _ = try await client.createDirectMessageChannel(userId: "user-7", token: "token-abc")
            XCTFail("Expected createDirectMessageChannel to throw when id is missing")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "DiscordService")
            XCTAssertEqual(nsError.code, -1)
        }
    }

    func testCreateDMChannelMalformedJSONThrows() async {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = #"not json"#.data(using: .utf8)!
            return (response, data)
        }

        let client = DiscordMessageRESTClient(session: makeMockSession())

        do {
            _ = try await client.createDirectMessageChannel(userId: "user-7", token: "token-abc")
            XCTFail("Expected createDirectMessageChannel to throw on malformed JSON")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "DiscordService")
            XCTAssertEqual(nsError.code, -1)
        }
    }

    // MARK: - Helpers

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
