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

    func testFetchLatestDriverIgnoresSpecialPurposeDriverPages() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AMDMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let sitemapURL = URL(string: "https://example.com/special-purpose-sitemap.xml")!
        let stableHTML = """
        <html>
          <body>
            <h1>AMD Software: Adrenalin Edition 26.7.1 Release Notes</h1>
            <p>Last Updated: July 30th, 2026.</p>
            <h2>Highlights</h2>
            <ul><li>Current public Adrenalin release.</li></ul>
          </body>
        </html>
        """

        AMDMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url == sitemapURL {
                let xml = """
                <urlset>
                  <url>
                    <loc>https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-26-7-1.html</loc>
                    <lastmod>2026-07-30T08:00:00Z</lastmod>
                  </url>
                  <url>
                    <loc>https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-26-10-02-01-DXCGC.html</loc>
                    <lastmod>2026-07-30T09:00:00Z</lastmod>
                  </url>
                </urlset>
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(xml.utf8)
                )
            }

            guard url.absoluteString.contains("RN-RAD-WIN-26-7-1") else {
                return (
                    HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(stableHTML.utf8)
            )
        }

        let service = AMDService(session: session, sitemapURL: sitemapURL)
        let driver = try await service.fetchLatestDriver()

        XCTAssertEqual(driver.releaseNotes.version, "26.7.1")
        XCTAssertEqual(driver.releaseIdentifier, "amd:26.7.1")
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

            counter.increment(url.absoluteString)

            if url == sitemapURL {
                Thread.sleep(forTimeInterval: 0.05)
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
                Thread.sleep(forTimeInterval: 0.05)
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
        let sitemapHits = counter.value(for: sitemapURL.absoluteString)
        let releaseHits = counter.value(
            for: "https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-26-3-1.html"
        )

        XCTAssertEqual(drivers.map(\.releaseIdentifier), ["amd:26.3.1", "amd:26.3.1"])
        XCTAssertEqual(sitemapHits, 1)
        XCTAssertEqual(releaseHits, 1)
    }

    /// AMD's sitemap has drifted months behind the live release notes (26-8-1
    /// was live while the sitemap still topped out at 26-7-1), which used to
    /// leave Patchy pinned to the stale entry and silently announcing nothing.
    func testFetchLatestDriverFindsReleaseMonthsAheadOfStaleSitemap() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AMDMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let sitemapURL = URL(string: "https://example.com/stale-sitemap.xml")!
        let html = releaseHTML(dottedVersion: "26.8.1", articleVersion: "26-8-1", lastUpdated: "August 20")

        AMDMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url == sitemapURL {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(sitemapXML(versions: ["26-3-1"], lastModified: "2026-03-19T08:00:00Z").utf8)
                )
            }

            guard url.absoluteString.contains("RN-RAD-WIN-26-8-1") else {
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html.utf8))
        }

        let service = AMDService(session: session, sitemapURL: sitemapURL, now: { Self.anchorDate })
        let driver = try await service.fetchLatestDriver()

        XCTAssertEqual(driver.releaseIdentifier, "amd:26.8.1")
        XCTAssertEqual(driver.releaseNotes.date, "August 20, 2026")
        XCTAssertTrue(
            driver.discoveryNotes.contains { $0.contains("26-3-1") },
            "A sitemap this far behind should be reported, not hidden: \(driver.discoveryNotes)"
        )
    }

    /// AMD ships patch numbers above 3 and skips numbers along the way: 26-6-4
    /// exists while 26-6-3 never did. The old window stopped at patch 3.
    func testFetchLatestDriverFindsHighPatchNumberAcrossAGap() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AMDMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let sitemapURL = URL(string: "https://example.com/gap-sitemap.xml")!
        let html = releaseHTML(dottedVersion: "26.8.4", articleVersion: "26-8-4", lastUpdated: "August 18")

        AMDMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url == sitemapURL {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(sitemapXML(versions: ["26-8-1"], lastModified: "2026-08-02T08:00:00Z").utf8)
                )
            }

            // 26-8-2 exists, 26-8-3 was never published, 26-8-4 is current.
            if url.absoluteString.contains("RN-RAD-WIN-26-8-4") {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html.utf8))
            }
            if url.absoluteString.contains("RN-RAD-WIN-26-8-2") {
                let older = releaseHTML(dottedVersion: "26.8.2", articleVersion: "26-8-2", lastUpdated: "August 10")
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(older.utf8))
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let service = AMDService(session: session, sitemapURL: sitemapURL, now: { Self.anchorDate })
        let driver = try await service.fetchLatestDriver()

        XCTAssertEqual(driver.releaseIdentifier, "amd:26.8.4")
    }

    /// AMD renamed the heading to "… 26.8.1 Driver Release Notes"; the old
    /// exact-title match rejected every probe once that landed.
    func testFetchLatestDriverAcceptsRenamedDriverReleaseNotesHeading() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AMDMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let sitemapURL = URL(string: "https://example.com/renamed-sitemap.xml")!
        // No "Article Number" block, so the heading is the only way in.
        let html = """
        <html>
          <body>
            <h1>AMD Software: Adrenalin Edition 26.8.1 Driver Release Notes</h1>
            <p><b>Last Updated</b>: August 20<sup>th</sup>, 2026.</p>
            <h2>Highlights</h2>
            <ul><li>Renamed heading still parses.</li></ul>
          </body>
        </html>
        """

        AMDMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url == sitemapURL {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(sitemapXML(versions: ["26-7-1"], lastModified: "2026-07-28T08:00:00Z").utf8)
                )
            }

            guard url.absoluteString.contains("RN-RAD-WIN-26-8-1") else {
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html.utf8))
        }

        let service = AMDService(session: session, sitemapURL: sitemapURL, now: { Self.anchorDate })
        let driver = try await service.fetchLatestDriver()

        XCTAssertEqual(driver.releaseIdentifier, "amd:26.8.1")
        XCTAssertEqual(driver.releaseNotes.title, "AMD Software: Adrenalin Edition 26.8.1 Driver Release Notes")
        XCTAssertEqual(driver.releaseNotes.date, "August 20, 2026")
    }

    /// Settling for a stale sitemap entry has to be reported. Without this the
    /// failure mode is a fetch that looks perfectly healthy while announcing a
    /// months-old driver forever.
    func testFetchLatestDriverReportsStaleSitemapWhenNothingNewerExists() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AMDMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let sitemapURL = URL(string: "https://example.com/nothing-newer-sitemap.xml")!
        let html = releaseHTML(dottedVersion: "26.3.1", articleVersion: "26-3-1", lastUpdated: "March 19")

        AMDMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url == sitemapURL {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(sitemapXML(versions: ["26-3-1"], lastModified: "2026-03-19T08:00:00Z").utf8)
                )
            }

            guard url.absoluteString.contains("RN-RAD-WIN-26-3-1") else {
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html.utf8))
        }

        let service = AMDService(session: session, sitemapURL: sitemapURL, now: { Self.anchorDate })
        let driver = try await service.fetchLatestDriver()

        XCTAssertEqual(driver.releaseIdentifier, "amd:26.3.1")
        XCTAssertTrue(
            driver.discoveryNotes.contains { $0.contains("days old") },
            "Expected a staleness warning, got: \(driver.discoveryNotes)"
        )
    }

    /// A 404 is an answer. Retrying it under two more User-Agents tripled the
    /// request count for every candidate that does not exist.
    func testFetchLatestDriverDoesNotRetryUserAgentProfilesOnA404() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AMDMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let sitemapURL = URL(string: "https://example.com/probe-count-sitemap.xml")!
        let html = releaseHTML(dottedVersion: "26.8.1", articleVersion: "26-8-1", lastUpdated: "August 20")
        let counter = RequestCounter()

        AMDMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            counter.increment(url.absoluteString)

            if url == sitemapURL {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(sitemapXML(versions: ["26-8-1"], lastModified: "2026-08-20T08:00:00Z").utf8)
                )
            }

            guard url.absoluteString.contains("RN-RAD-WIN-26-8-1") else {
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html.utf8))
        }

        let service = AMDService(session: session, sitemapURL: sitemapURL, now: { Self.anchorDate })
        _ = try await service.fetchLatestDriver()

        let missingURL = "https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-26-8-2.html"
        XCTAssertEqual(counter.value(for: missingURL), 1, "A missing release should cost exactly one request.")
        XCTAssertNil(
            counter.keys.first { $0.contains("/support/kb/release-notes/") },
            "The kb URL forms now redirect to the generic drivers page and must not be probed."
        )
    }

    /// Existence is probed with HEAD to keep the month scan cheap, but a CDN
    /// that stops answering HEAD must not read as "no releases exist".
    func testFetchLatestDriverFallsBackToGetWhenHeadIsRejected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AMDMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let sitemapURL = URL(string: "https://example.com/no-head-sitemap.xml")!
        let html = releaseHTML(dottedVersion: "26.8.1", articleVersion: "26-8-1", lastUpdated: "August 20")

        AMDMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url == sitemapURL {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(sitemapXML(versions: ["26-7-1"], lastModified: "2026-07-28T08:00:00Z").utf8)
                )
            }

            if request.httpMethod == "HEAD" {
                return (HTTPURLResponse(url: url, statusCode: 405, httpVersion: nil, headerFields: nil)!, Data())
            }

            guard url.absoluteString.contains("RN-RAD-WIN-26-8-1") else {
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html.utf8))
        }

        let service = AMDService(session: session, sitemapURL: sitemapURL, now: { Self.anchorDate })
        let driver = try await service.fetchLatestDriver()

        XCTAssertEqual(driver.releaseIdentifier, "amd:26.8.1")
    }

    // MARK: - Helpers

    /// 2026-08-21, so the month scan has a fixed idea of "now".
    private static let anchorDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 21
        components.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }()
}


/// Minimal stand-in for an AMD release-notes page, in the shape AMD currently
/// publishes: an "Article Number" block plus a heading that includes "Driver".
private func releaseHTML(dottedVersion: String, articleVersion: String, lastUpdated: String) -> String {
    """
    <html>
      <body>
        <h1>AMD Software: Adrenalin Edition \(dottedVersion) Driver Release Notes</h1>
        <p><strong>Article Number:</strong> RN-RAD-WIN-\(articleVersion)</p>
        <p><b>Last Updated</b>: \(lastUpdated)<sup>th</sup>, 2026.</p>
        <h2>Highlights</h2>
        <ul><li>New game support.</li></ul>
      </body>
    </html>
    """
}

private func sitemapXML(versions: [String], lastModified: String) -> String {
    let entries = versions.map { version in
        """
          <url>
            <loc>https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-\(version).html</loc>
            <lastmod>\(lastModified)</lastmod>
          </url>
        """
    }.joined(separator: "\n")

    return "<urlset>\n\(entries)\n</urlset>"
}

private final class AMDMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func increment(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        counts[key, default: 0] += 1
    }

    func value(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key, default: 0]
    }

    var keys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(counts.keys)
    }
}
