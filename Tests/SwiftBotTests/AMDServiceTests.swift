import XCTest
@testable import SwiftBot

final class AMDServiceTests: XCTestCase {
    override func tearDown() {
        AMDServiceMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testAMDServiceIgnoresSpecialPurposeDriverPages() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AMDServiceMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let sitemapURL = URL(string: "https://example.com/swiftbot-amd-sitemap.xml")!

        AMDServiceMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url == sitemapURL {
                let xml = """
                <urlset>
                  <url><loc>https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-26-7-1.html</loc><lastmod>2026-07-30T08:00:00Z</lastmod></url>
                  <url><loc>https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-26-10-02-01-DXCGC.html</loc><lastmod>2026-07-30T09:00:00Z</lastmod></url>
                </urlset>
                """
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(xml.utf8))
            }

            let html = """
            <html><body><h1>AMD Software: Adrenalin Edition 26.7.1 Release Notes</h1><h2>Highlights</h2><ul><li>Current public release.</li></ul></body></html>
            """
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html.utf8))
        }

        let driver = try await AMDService(session: session, sitemapURL: sitemapURL).fetchLatestDriver()

        XCTAssertEqual(driver.releaseNotes.version, "26.7.1")
        XCTAssertEqual(driver.releaseIdentifier, "amd:26.7.1")
    }
}

private final class AMDServiceMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing AMD mock request handler.")
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
