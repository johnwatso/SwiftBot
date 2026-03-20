import Foundation
import XCTest
@testable import UpdateEngine

final class AMDServiceTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        AMDMockURLProtocol.requestHandler = nil
    }

    func testFetchLatestDriverProbesBeyondLaggingSitemap() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AMDMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let sitemapURL = URL(string: "https://example.com/en.sitemap.xml")!
        let fallbackHTML = """
        <html>
          <body>
            <h1>AMD Software: Adrenalin Edition 26.3.1 Release Notes</h1>
            <p>Last Updated: March 19th, 2026.</p>
            <h2>Highlights</h2>
            <ul>
              <li>New Game Support</li>
            </ul>
          </body>
        </html>
        """

        AMDMockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url == sitemapURL {
                let xml = """
                <urlset>
                  <url>
                    <loc>https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-26-2-2.html</loc>
                    <lastmod>2026-02-28T12:00:00Z</lastmod>
                  </url>
                </urlset>
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(xml.utf8)
                )
            }

            let path = url.absoluteString
            if request.httpMethod == "HEAD" {
                if path.contains("RN-RAD-WIN-26-3-1") || path.contains("rn-rad-win-26-3-1") {
                    return (
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data()
                    )
                }

                return (
                    HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }

            if path.contains("RN-RAD-WIN-26-3-1") || path.contains("rn-rad-win-26-3-1") {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(fallbackHTML.utf8)
                )
            }

            return (
                HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let service = AMDService(session: session, sitemapURL: sitemapURL)
        let driver = try await service.fetchLatestDriver()

        XCTAssertEqual(driver.releaseNotes.version, "26.3.1")
        XCTAssertEqual(driver.releaseNotes.date, "March 19, 2026")
        XCTAssertEqual(driver.releaseIdentifier, "amd:26.3.1")
        XCTAssertEqual(
            driver.releaseNotes.url,
            "https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-26-3-1.html"
        )
    }

    func testFetchLatestDriverParsesKbSitemapURLs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AMDMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let sitemapURL = URL(string: "https://example.com/en.sitemap.xml")!
        let html = """
        <html>
          <body>
            <h1>AMD Software: Adrenalin Edition 26.3.1 Release Notes</h1>
            <p>Last Updated: March 19th, 2026.</p>
            <h2>Highlights</h2>
            <ul>
              <li>FSR Upscaling 4.1 support.</li>
            </ul>
          </body>
        </html>
        """

        AMDMockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url == sitemapURL {
                let xml = """
                <urlset>
                  <url>
                    <loc>https://www.amd.com/en/support/kb/release-notes/rn-rad-win-26-3-1</loc>
                    <lastmod>2026-03-19T08:00:00Z</lastmod>
                  </url>
                </urlset>
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(xml.utf8)
                )
            }

            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(html.utf8)
            )
        }

        let service = AMDService(session: session, sitemapURL: sitemapURL)
        let driver = try await service.fetchLatestDriver()

        XCTAssertEqual(driver.releaseNotes.version, "26.3.1")
        XCTAssertEqual(driver.releaseNotes.date, "March 19, 2026")
        XCTAssertEqual(
            driver.releaseNotes.url,
            "https://www.amd.com/en/support/kb/release-notes/rn-rad-win-26-3-1"
        )
    }
}

private final class AMDMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler for AMDMockURLProtocol.")
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
