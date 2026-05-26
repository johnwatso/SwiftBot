import XCTest
@testable import SwiftBot

final class DiscordServiceDMTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.clear()
        super.tearDown()
    }

    func testSendDMBlockedOnStandby() async {
        let service = DiscordService(session: makeMockSession())
        await service.setOutputAllowed(false)

        do {
            try await service.sendDM(userId: "user-7", content: "hello")
            XCTFail("Expected sendDM to throw when outputAllowed is false")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "DiscordService")
            XCTAssertEqual(nsError.code, 403)
        }
    }

    func testSendDMEmbedSuccess() async throws {
        let createExpectation = expectation(description: "createDirectMessageChannel called")
        let sendExpectation = expectation(description: "sendMessage called with embed payload")

        MockURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path == "/api/v10/users/@me/channels" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bot test-token")
                createExpectation.fulfill()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = #"{"id":"dm-99","type":1}"#.data(using: .utf8)!
                return (response, data)
            }
            if path == "/api/v10/channels/dm-99/messages" {
                XCTAssertEqual(request.httpMethod, "POST")
                let bodyData = request.bodyStreamData() ?? request.httpBody ?? Data()
                let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
                XCTAssertNotNil(json?["embeds"], "Expected embed payload in request body")
                sendExpectation.fulfill()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = #"{"id":"msg-1"}"#.data(using: .utf8)!
                return (response, data)
            }
            XCTFail("Unexpected request path: \(path)")
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let service = DiscordService(session: makeMockSession())
        await service.setBotTokenForTesting("test-token")

        try await service.sendDMEmbed(
            userId: "user-7",
            embed: ["title": "Hello", "description": "from the test"]
        )

        await fulfillment(of: [createExpectation, sendExpectation], timeout: 2.0)
    }

    // MARK: - Helpers

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
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

    override class func canInit(with request: URLRequest) -> Bool { true }
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
    /// URLSession with custom URLProtocol streams the body via `httpBodyStream`
    /// rather than populating `httpBody`. Drain the stream so tests can inspect it.
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
