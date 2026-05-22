import Foundation
import XCTest
@testable import SwiftBot

final class WikiLookupServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.clear()
        super.tearDown()
    }

    func testLookupWikiFallsBackToSearchAndSummary() async {
        MockURLProtocol.setHandler { request in
            guard let url = request.url else {
                throw NSError(domain: "WikiLookupServiceTests", code: 1)
            }

            if url.path == "/wiki/AKM" {
                return (
                    HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }

            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

            if items["list"] == "search" {
                let body = """
                {"query":{"search":[{"title":"AKM"}]}}
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8)
                )
            }

            let body = """
            {
              "query": {
                "pages": {
                  "123": {
                    "title": "AKM",
                    "extract": " Reliable rifle. Strong at mid range. ",
                    "fullurl": "https://example.fandom.com/wiki/AKM"
                  }
                }
              }
            }
            """
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let service = WikiLookupService(session: makeSession())
        let source = WikiSource(name: "Example Wiki", baseURL: "https://example.fandom.com", apiPath: "/api.php")

        let result = await service.lookupWiki(query: "AKM", source: source)

        XCTAssertEqual(result?.title, "AKM")
        XCTAssertEqual(result?.extract, "Reliable rifle. Strong at mid range.")
        XCTAssertEqual(result?.url, "https://example.fandom.com/wiki/AKM")
    }

    func testLookupWikiExtractsImageAndInfoboxFieldsWithSwiftSoup() async {
        MockURLProtocol.setHandler { request in
            let html = """
            <html>
              <head>
                <title>AKM - Example Wiki</title>
                <link rel="canonical" href="https://example.fandom.com/wiki/AKM">
                <meta property="og:image" content="/images/akm.png">
              </head>
              <body>
                <h1 id="firstHeading">AKM</h1>
                <div class="mw-parser-output">
                  <p>The AKM is a reliable automatic rifle built for medium range fights.</p>
                  <table class="infobox">
                    <tr><th>Type</th><td>Assault Rifle</td></tr>
                    <tr><th>Damage</th><td>20</td></tr>
                    <tr><th>Magazine</th><td>36</td></tr>
                  </table>
                </div>
              </body>
            </html>
            """
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(html.utf8)
            )
        }

        let service = WikiLookupService(session: makeSession())
        let source = WikiSource(name: "Example Wiki", baseURL: "https://example.fandom.com", apiPath: "/api.php")

        let result = await service.lookupWiki(query: "AKM", source: source)

        XCTAssertEqual(result?.title, "AKM")
        XCTAssertEqual(result?.imageURL, "https://example.fandom.com/images/akm.png")
        XCTAssertEqual(result?.pageType, "weapon")
        XCTAssertTrue(result?.fields.contains(WikiResultField(name: "Type", value: "Assault Rifle")) == true)
        XCTAssertTrue(result?.fields.contains(WikiResultField(name: "Magazine", value: "36")) == true)
    }

    func testLookupWikiUsesParseAPIWhenFandomPageHidesInfoboxFields() async throws {
        MockURLProtocol.setHandler { request in
            guard let url = request.url else {
                throw NSError(domain: "WikiLookupServiceTests", code: 1)
            }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

            if url.path == "/wiki/MP5" {
                let html = """
                <html>
                  <head><link rel="canonical" href="https://callofduty.fandom.com/wiki/MP5"></head>
                  <body><h1>MP5</h1></body>
                </html>
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(html.utf8)
                )
            }

            if items["action"] == "parse" {
                let html = """
                <div class="mw-parser-output">
                  <p>The MP5 is a submachine gun featured in several Call of Duty games.</p>
                  <aside class="portable-infobox">
                    <section class="pi-item pi-data">
                      <h3 class="pi-data-label">Weapon Class</h3>
                      <div class="pi-data-value">Submachine Gun</div>
                    </section>
                    <section class="pi-item pi-data">
                      <h3 class="pi-data-label">Magazine Size</h3>
                      <div class="pi-data-value">30 rounds<br><i>40 with attachments</i></div>
                    </section>
                    <section class="pi-item pi-data">
                      <h3 class="pi-data-label">Damage</h3>
                      <div class="pi-data-value">32-23</div>
                    </section>
                  </aside>
                </div>
                """
                let object: [String: Any] = [
                    "parse": [
                        "title": "MP5",
                        "displaytitle": "MP5",
                        "text": ["*": html]
                    ]
                ]
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: object)
                )
            }

            throw NSError(domain: "WikiLookupServiceTests", code: 2)
        }

        let service = WikiLookupService(session: makeSession())
        let source = WikiSource(name: "Call of Duty Wiki", baseURL: "https://callofduty.fandom.com", apiPath: "/api.php")

        let result = await service.lookupWiki(query: "MP5", source: source)

        XCTAssertEqual(result?.title, "MP5")
        XCTAssertEqual(result?.extract, "The MP5 is a submachine gun featured in several Call of Duty games.")
        XCTAssertEqual(result?.pageType, "weapon")
        XCTAssertTrue(result?.fields.contains(WikiResultField(name: "Weapon Class", value: "Submachine Gun")) == true)
        XCTAssertTrue(result?.fields.contains(WikiResultField(name: "Magazine Size", value: "30 rounds 40 with attachments")) == true)
        XCTAssertTrue(result?.fields.contains(WikiResultField(name: "Damage", value: "32-23")) == true)
    }

    func testLookupWikiScopesBroadFandomPageToPreferredGameSection() async throws {
        MockURLProtocol.setHandler { request in
            guard let url = request.url else {
                throw NSError(domain: "WikiLookupServiceTests", code: 1)
            }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

            if url.path == "/wiki/MP5" {
                let html = """
                <html>
                  <head><link rel="canonical" href="https://callofduty.fandom.com/wiki/MP5"></head>
                  <body><h1>MP5</h1></body>
                </html>
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(html.utf8)
                )
            }

            if items["action"] == "parse" {
                let html = """
                <div class="mw-parser-output">
                  <h2>Call of Duty 4: Modern Warfare</h2>
                  <p>Older MP5 tuning.</p>
                  <aside class="portable-infobox">
                    <section class="pi-item pi-data">
                      <h3 class="pi-data-label">Damage</h3>
                      <div class="pi-data-value">40-20</div>
                    </section>
                  </aside>
                  <h2>Call of Duty: Modern Warfare</h2>
                  <p>The Modern Warfare MP5 is a close-range SMG.</p>
                  <aside class="portable-infobox">
                    <section class="pi-item pi-data">
                      <h3 class="pi-data-label">Weapon Class</h3>
                      <div class="pi-data-value">Submachine Gun</div>
                    </section>
                    <section class="pi-item pi-data">
                      <h3 class="pi-data-label">Damage</h3>
                      <div class="pi-data-value">34-19</div>
                    </section>
                    <section class="pi-item pi-data">
                      <h3 class="pi-data-label">Magazine Size</h3>
                      <div class="pi-data-value">30 rounds</div>
                    </section>
                  </aside>
                </div>
                """
                let object: [String: Any] = [
                    "parse": [
                        "title": "MP5",
                        "displaytitle": "MP5",
                        "text": ["*": html]
                    ]
                ]
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: object)
                )
            }

            throw NSError(domain: "WikiLookupServiceTests", code: 2)
        }

        let service = WikiLookupService(session: makeSession())
        let source = WikiSource(
            name: "Call of Duty Wiki",
            baseURL: "https://callofduty.fandom.com",
            apiPath: "/api.php",
            searchScope: "MW2019"
        )

        let result = await service.lookupWiki(query: "MP5", source: source)

        XCTAssertEqual(result?.title, "MP5")
        XCTAssertEqual(result?.extract, "The Modern Warfare MP5 is a close-range SMG.")
        XCTAssertTrue(result?.fields.contains(WikiResultField(name: "Weapon Class", value: "Submachine Gun")) == true)
        XCTAssertTrue(result?.fields.contains(WikiResultField(name: "Damage", value: "34-19")) == true)
        XCTAssertTrue(result?.fields.contains(WikiResultField(name: "Magazine Size", value: "30 rounds")) == true)
        XCTAssertFalse(result?.fields.contains(WikiResultField(name: "Damage", value: "40-20")) == true)
    }

    func testFetchFinalsMetaFromSkycoachParsesSections() async {
        MockURLProtocol.setHandler { request in
            let html = """
            <html>
              <body>
                <h2>Best Light Build</h2>
                <p>Best Weapon: XP-54 Best Specialization: Cloaking Device Best Gadgets: Gateway, Glitch Grenade, Vanishing Bomb</p>
                <h2>Best Heavy Build</h2>
                <ul>
                  <li>Best Weapon: Lewis Gun</li>
                  <li>Best Specialization: Mesh Shield</li>
                  <li>Best Gadgets: Dome Shield, RPG-7, C4</li>
                </ul>
              </body>
            </html>
            """
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(html.utf8)
            )
        }

        let service = WikiLookupService(session: makeSession())
        let summary = await service.fetchFinalsMetaFromSkycoach()

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("Light:") == true)
        XCTAssertTrue(summary?.contains("Best Weapon: XP-54") == true)
        XCTAssertTrue(summary?.contains("Best Specialization: Cloaking Device") == true)
        XCTAssertTrue(summary?.contains("Heavy:") == true)
        XCTAssertTrue(summary?.contains("Best Gadgets: Dome Shield, RPG-7, C4") == true)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(_ newHandler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        handler = newHandler
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
            client?.urlProtocol(self, didFailWithError: NSError(domain: "WikiLookupServiceTests", code: 2))
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
