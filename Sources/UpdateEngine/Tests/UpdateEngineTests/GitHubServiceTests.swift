import XCTest
@testable import UpdateEngine

final class GitHubServiceTests: XCTestCase {
    override func tearDown() {
        GitHubMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testLatestReleaseParsesMarkdownSections() async throws {
        let body = """
        ## Highlights
        - Added release-note section parsing.
        - Improved summaries with nested details:
          - Preserves child bullet content.

        ## Fixes
        - Fixed vague GitHub summaries.
        """

        GitHubMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/acme/widget/releases/latest")
            let payload: [String: Any] = [
                "tag_name": "v1.2.3",
                "name": "Widget 1.2.3",
                "body": body,
                "html_url": "https://github.com/acme/widget/releases/tag/v1.2.3",
                "published_at": "2026-06-01T12:00:00Z",
                "author": ["login": "release-bot"]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        let service = GitHubService(session: mockedSession())
        let info = try await service.fetchLatest(owner: "acme", repo: "widget", mode: .releases)

        XCTAssertEqual(info.displayVersion, "v1.2.3")
        XCTAssertTrue(info.summary.contains("Highlights"))
        XCTAssertTrue(info.summary.contains("- Added release-note section parsing."))
        XCTAssertTrue(info.summary.contains("  - Preserves child bullet content."))
        XCTAssertTrue(info.summary.contains("Fixes"))
        XCTAssertTrue(info.embedJSON.contains("Highlights"))
        XCTAssertTrue(info.embedJSON.contains("Fixes"))
    }

    private func mockedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class GitHubMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler for GitHubMockURLProtocol.")
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
