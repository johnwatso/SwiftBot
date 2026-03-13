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
    private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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
