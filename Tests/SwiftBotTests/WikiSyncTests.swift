import XCTest
@testable import SwiftBot

/// Phase 3 Wiki-cache replication tests.
final class WikiSyncTests: XCTestCase {

    func testWikiCacheSync() async {
        let leaderCache = WikiContextCache()
        let standbyCache = WikiContextCache()
        
        let entry1 = WikiContextEntry(
            id: "src1|title1",
            sourceName: "src1",
            query: "q1",
            title: "title1",
            extract: "ext1",
            url: "url1",
            cachedAt: Date()
        )
        await leaderCache.upsertEntry(entry1)
        
        let leader = ClusterCoordinator()
        await leader.applySettings(
            mode: .leader,
            nodeName: "Leader",
            leaderAddress: "",
            listenPort: 39300,
            sharedSecret: "s",
            leaderTerm: 1
        )
        
        await leader.configureHandlers(
            aiHandler: { _, _, _, _ in nil },
            wikiHandler: { _, _ in nil },
            onSnapshot: { _ in },
            onJobLog: { _ in },
            onSync: { _ in },
            meshHandler: { type in
                if type == "wiki-cache" {
                    let entries = await leaderCache.allEntries()
                    return try? JSONEncoder().encode(entries)
                }
                return nil
            },
            conversationFetcher: { _, _ in ([], false) },
            onPromotion: {}
        )
        
        // Simulate Standby pull
        let signedHeaders = await leader.testMakeHMACHeaders(method: "GET", path: "/v1/mesh/sync/wiki-cache", body: Data())
        let raw = makeHTTPRequest(method: "GET", path: "/v1/mesh/sync/wiki-cache", headers: signedHeaders, body: Data())
        let resp = await leader.testProcessHTTPRequest(raw)
        XCTAssertEqual(statusCode(from: resp), 200)
        
        guard let marker = resp.range(of: Data("\r\n\r\n".utf8)) else {
            XCTFail("Response missing header/body separator")
            return
        }
        let bodyData = Data(resp[marker.upperBound...])
        let pulledEntries = try? JSONDecoder().decode([WikiContextEntry].self, from: bodyData)
        
        XCTAssertNotNil(pulledEntries)
        XCTAssertEqual(pulledEntries?.count, 1)
        XCTAssertEqual(pulledEntries?.first?.title, "title1")
        
        // Merge into standby
        if let entries = pulledEntries {
            for entry in entries {
                await standbyCache.upsertEntry(entry)
            }
        }
        
        let standbyAll = await standbyCache.allEntries()
        XCTAssertEqual(standbyAll.count, 1)
        XCTAssertEqual(standbyAll.first?.id, "src1|title1")
    }

    // MARK: - Helpers

    private func makeHTTPRequest(method: String, path: String, headers: [String: String], body: Data) -> Data {
        var raw = "\(method) \(path) HTTP/1.1\r\n"
        raw += "Host: localhost\r\n"
        for (k, v) in headers { raw += "\(k): \(v)\r\n" }
        raw += "Content-Length: \(body.count)\r\n\r\n"
        var data = Data(raw.utf8)
        data.append(body)
        return data
    }

    private func statusCode(from response: Data) -> Int {
        guard let text = String(data: response, encoding: .utf8),
              let first = text.components(separatedBy: "\r\n").first else { return -1 }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return -1 }
        return code
    }
}
