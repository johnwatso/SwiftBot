import XCTest
@testable import SwiftBot

final class DiscordRESTTransportTests: XCTestCase {
    override func tearDown() {
        TransportMockURLProtocol.clear()
        super.tearDown()
    }

    func testRetriesThrough429AndReturnsTheEventualSuccess() async throws {
        let attempts = Counter()
        TransportMockURLProtocol.setHandler { request in
            let attempt = attempts.increment()
            if attempt == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "0", "X-RateLimit-Scope": "user"]
                )!
                return (response, #"{"message":"You are being rate limited.","retry_after":0.01}"#.data(using: .utf8)!)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"id":"7"}"#.data(using: .utf8)!)
        }

        let transport = DiscordRESTTransport(session: makeMockSession(), limiter: DiscordRateLimiter())
        let (data, response) = try await transport.perform(
            request("POST", "https://discord.com/api/v10/channels/111111111111111111/messages")
        )

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Callers should never see the 429")
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"id":"7"}"#)
        XCTAssertEqual(attempts.value, 2)
    }

    func testGivesUpAndSurfacesThe429AfterExhaustingRetries() async throws {
        let attempts = Counter()
        TransportMockURLProtocol.setHandler { request in
            _ = attempts.increment()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "0"]
            )!
            return (response, #"{"retry_after":0.01}"#.data(using: .utf8)!)
        }

        let transport = DiscordRESTTransport(session: makeMockSession(), limiter: DiscordRateLimiter())
        let (_, response) = try await transport.perform(
            request("POST", "https://discord.com/api/v10/channels/111111111111111111/messages")
        )

        // The 429 is handed back in the shape callers already handle, rather than
        // being retried forever.
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual(attempts.value, DiscordRESTTransport.maxRateLimitRetries + 1)
    }

    func testResponseHeadersSeedTheBucketBudget() async throws {
        TransportMockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "X-RateLimit-Bucket": "bucket-a",
                    "X-RateLimit-Limit": "5",
                    "X-RateLimit-Remaining": "4",
                    "X-RateLimit-Reset-After": "5"
                ]
            )!
            return (response, Data("{}".utf8))
        }

        let limiter = DiscordRateLimiter()
        let transport = DiscordRESTTransport(session: makeMockSession(), limiter: limiter)
        let request = request("POST", "https://discord.com/api/v10/channels/111111111111111111/messages")
        _ = try await transport.perform(request)

        let remaining = await limiter.remaining(for: DiscordRoute(request: request))
        XCTAssertEqual(remaining, 4)
    }

    // MARK: - Helpers

    private func request(_ method: String, _ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        return request
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Thread-safe attempt counter — the handler runs on URLSession's queue.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class TransportMockURLProtocol: URLProtocol {
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
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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
