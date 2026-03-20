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
        XCTAssertTrue(driver.releaseNotes.url.contains("26-3-1"))
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

    func testFetchLatestDriverRetriesWithBrowserLikeHeadersAfter403() async throws {
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
              <li>Retry worked with browser-like headers.</li>
            </ul>
          </body>
        </html>
        """

        AMDMockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let userAgent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            let isBrowserProfile = userAgent.contains("Safari/605.1.15") || userAgent.contains("Chrome/134.0.0.0")

            if url == sitemapURL {
                if !isBrowserProfile {
                    return (
                        HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                        Data("denied".utf8)
                    )
                }

                let xml = """
                <urlset>
                  <url>
                    <loc>https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-26-3-1.html</loc>
                    <lastmod>2026-03-19T08:00:00Z</lastmod>
                  </url>
                </urlset>
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(xml.utf8)
                )
            }

            if url.absoluteString.contains("RN-RAD-WIN-26-3-1") {
                if !isBrowserProfile {
                    return (
                        HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                        Data("denied".utf8)
                    )
                }

                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "en-US,en;q=0.9")
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(html.utf8)
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
        XCTAssertEqual(driver.releaseIdentifier, "amd:26.3.1")
    }

    func testFetchLatestDriverFallsBackToRecentReleaseCandidatesWhenSitemapBlocked() async throws {
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
              <li>Direct fallback probe succeeded.</li>
            </ul>
          </body>
        </html>
        """

        var requestedURLs: [String] = []
        AMDMockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            requestedURLs.append(url.absoluteString)

            if url == sitemapURL {
                return (
                    HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                    Data("denied".utf8)
                )
            }

            if url.absoluteString.contains("RN-RAD-WIN-26-3-1") || url.absoluteString.contains("rn-rad-win-26-3-1") {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(html.utf8)
                )
            }

            return (
                HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let anchorDate = try XCTUnwrap(formatter.date(from: "2026-03-20"))

        let service = AMDService(
            session: session,
            sitemapURL: sitemapURL,
            now: { anchorDate }
        )
        let driver = try await service.fetchLatestDriver()

        XCTAssertEqual(driver.releaseNotes.version, "26.3.1")
        XCTAssertTrue(requestedURLs.contains("https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-26-3-1.html"))
    }

    func testFetchLatestDriverSharesInFlightRequestAcrossConcurrentCallers() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AMDMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let sitemapURL = URL(string: "https://example.com/concurrent-sitemap.xml")!
        let html = """
        <html>
          <body>
            <h1>AMD Software: Adrenalin Edition 26.3.1 Release Notes</h1>
            <p>Last Updated: March 19th, 2026.</p>
            <h2>Highlights</h2>
            <ul>
              <li>Shared in-flight fetch.</li>
            </ul>
          </body>
        </html>
        """

        let counter = RequestCounter()
        AMDMockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            await counter.increment(url.absoluteString)

            if url == sitemapURL {
                try await Task.sleep(nanoseconds: 50_000_000)
                let xml = """
                <urlset>
                  <url>
                    <loc>https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-26-3-1.html</loc>
                    <lastmod>2026-03-19T08:00:00Z</lastmod>
                  </url>
                </urlset>
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(xml.utf8)
                )
            }

            if url.absoluteString.contains("RN-RAD-WIN-26-3-1") {
                try await Task.sleep(nanoseconds: 50_000_000)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(html.utf8)
                )
            }

            return (
                HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let service = AMDService(session: session, sitemapURL: sitemapURL)
        async let first = service.fetchLatestDriver()
        async let second = service.fetchLatestDriver()
        let drivers = try await [first, second]
        let sitemapHits = await counter.value(for: sitemapURL.absoluteString)
        let releaseHits = await counter.value(
            for: "https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-26-3-1.html"
        )

        XCTAssertEqual(drivers.map(\.releaseIdentifier), ["amd:26.3.1", "amd:26.3.1"])
        XCTAssertEqual(sitemapHits, 1)
        XCTAssertEqual(releaseHits, 1)
    }
}

private final class AMDMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) async throws -> (HTTPURLResponse, Data))?

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

        Task {
            do {
                let (response, data) = try await handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

private actor RequestCounter {
    private var counts: [String: Int] = [:]

    func increment(_ key: String) {
        counts[key, default: 0] += 1
    }

    func value(for key: String) -> Int {
        counts[key, default: 0]
    }
}
