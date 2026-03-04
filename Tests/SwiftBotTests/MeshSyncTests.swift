import XCTest
@testable import SwiftBot

/// Phase 2 conversation-replication tests.
/// Covers: incremental-only, duplicate no-op, gap detection, paginated convergence, cursor reset on promotion.
final class MeshSyncTests: XCTestCase {

    // MARK: - Helpers

    private func makeScope() -> MemoryScope { .guildTextChannel("test-ch") }

    private func seed(_ store: ConversationStore, ids: [String], base: Date = Date()) async {
        let scope = makeScope()
        for (i, id) in ids.enumerated() {
            await store.append(
                scope: scope,
                messageID: id,
                userID: "user1",
                content: "msg-\(id)",
                timestamp: base.addingTimeInterval(Double(i)),
                role: .user
            )
        }
    }

    private func makeLeader(port: Int) async -> ClusterCoordinator {
        let c = ClusterCoordinator()
        await c.applySettings(
            mode: .leader,
            nodeName: "Leader",
            leaderAddress: "",
            listenPort: port,
            sharedSecret: "s",
            leaderTerm: 1
        )
        return c
    }

    private func configureLeader(_ c: ClusterCoordinator, fetcher: @escaping ClusterCoordinator.ConversationFetcher) async {
        await c.configureHandlers(
            aiHandler: { _, _, _, _ in nil },
            wikiHandler: { _, _ in nil },
            onSnapshot: { _ in },
            onJobLog: { _ in },
            onSync: { _ in },
            meshHandler: { _ in nil },
            conversationFetcher: fetcher,
            onPromotion: {}
        )
    }

    private func resyncRequest(fromRecordID: String?, pageSize: Int) -> Data {
        let req = MeshResyncRequest(fromRecordID: fromRecordID, pageSize: pageSize)
        return (try? JSONEncoder().encode(req)) ?? Data()
    }

    private func sendResync(to coordinator: ClusterCoordinator, fromRecordID: String?, pageSize: Int) async -> MeshSyncPayload? {
        let body = resyncRequest(fromRecordID: fromRecordID, pageSize: pageSize)
        let raw = makeHTTPRequest(method: "POST", path: "/v1/mesh/sync/conversations/resync",
                                  headers: ["X-Cluster-Secret": "s"], body: body)
        let resp = await coordinator.testProcessHTTPRequest(raw)
        let statusCode = self.statusCode(from: resp)
        guard statusCode == 200 else { return nil }
        // extract body after \r\n\r\n
        guard let marker = resp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let bodyData = Data(resp[marker.upperBound...])
        return try? JSONDecoder().decode(MeshSyncPayload.self, from: bodyData)
    }

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

    // MARK: - Test 1: Incremental-only delivery

    /// Second push must contain only new records, not those already delivered.
    func testIncrementalSyncOnlyNewRecords() async {
        let store = ConversationStore()
        await seed(store, ids: ["r1", "r2", "r3"])

        // First batch: from start
        let (batch1, more1) = await store.recordsSince(fromRecordID: nil, limit: 2)
        XCTAssertEqual(batch1.map(\.id), ["r1", "r2"])
        XCTAssertTrue(more1, "3 records / limit 2 → hasMore should be true")

        // Second batch: incremental from last delivered
        let cursor1 = batch1.last?.id
        let (batch2, more2) = await store.recordsSince(fromRecordID: cursor1, limit: 500)
        XCTAssertEqual(batch2.map(\.id), ["r3"])
        XCTAssertFalse(more2)

        // Third batch: fully caught up — nothing new
        let (batch3, more3) = await store.recordsSince(fromRecordID: batch2.last?.id, limit: 500)
        XCTAssertTrue(batch3.isEmpty, "No new records after full sync")
        XCTAssertFalse(more3)
    }

    // MARK: - Test 2: Duplicate delivery is a no-op

    func testDuplicateAppendIsNoop() async {
        let store = ConversationStore()
        let scope = makeScope()
        let base = Date()

        await store.appendIfNotExists(scope: scope, messageID: "dup-1", userID: "u1",
                                content: "hello", role: .user, timestamp: base)
        await store.appendIfNotExists(scope: scope, messageID: "dup-1", userID: "u1",
                                content: "hello again", role: .user, timestamp: base)

        let all = await store.allRecordsSorted()
        XCTAssertEqual(all.count, 1, "Duplicate ID must be deduplicated")
        XCTAssertEqual(all.first?.content, "hello", "First write wins")
    }

    // MARK: - Test 3: Resync handler serves from cursor

    func testResyncHandlerServesFromCursor() async {
        let store = ConversationStore()
        let base = Date()
        await seed(store, ids: ["a", "b", "c", "d", "e"], base: base)
        let sorted = await store.allRecordsSorted()

        let leader = await makeLeader(port: 39200)
        await configureLeader(leader) { fromID, limit in
            await store.recordsSince(fromRecordID: fromID, limit: limit)
        }

        // Request records after "b"
        let cursorAfterB = sorted.first(where: { $0.id == "b" })?.id
        let payload = await sendResync(to: leader, fromRecordID: cursorAfterB, pageSize: 500)

        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.conversations.map(\.id), ["c", "d", "e"])
        XCTAssertFalse(payload?.hasMore ?? true)
        XCTAssertEqual(payload?.fromCursorRecordID, cursorAfterB)
    }

    // MARK: - Test 4: Paginated resync converges

    /// Three pages of 2 records each → standby ends with all 6 in sorted order.
    func testPaginatedResyncConverges() async {
        let store = ConversationStore()
        let base = Date()
        await seed(store, ids: ["p1", "p2", "p3", "p4", "p5", "p6"], base: base)

        let leader = await makeLeader(port: 39202)
        await configureLeader(leader) { fromID, limit in
            await store.recordsSince(fromRecordID: fromID, limit: limit)
        }

        var mergedIDs: [String] = []
        var cursor: String? = nil

        for _ in 0..<5 {   // max iterations guard
            let payload = await sendResync(to: leader, fromRecordID: cursor, pageSize: 2)
            XCTAssertNotNil(payload)
            guard let p = payload else { break }
            mergedIDs.append(contentsOf: p.conversations.map(\.id))
            cursor = p.cursorRecordID
            if !p.hasMore { break }
        }

        XCTAssertEqual(mergedIDs, ["p1", "p2", "p3", "p4", "p5", "p6"],
                       "Paginated resync must deliver all records in order")
    }

    // MARK: - Test 5: Cursor resets on promotion to leader

    func testCursorResetOnPromotion() async {
        let standby = ClusterCoordinator()
        await standby.applySettings(
            mode: .standby,
            nodeName: "StandbyReset",
            leaderAddress: "http://127.0.0.1:39204",
            listenPort: 39205,
            sharedSecret: "s",
            leaderTerm: 1
        )
        // Pre-load a cursor so we can verify it gets wiped.
        await standby.applyRestoredCursors([
            "Worker-1": ReplicationCursor(leaderTerm: 1, lastSentRecordID: "old-rec", updatedAt: Date())
        ])

        
        let cursorExpectation = expectation(description: "Cursors changed handler called")
        await standby.setCursorsChangedHandler { cursors in
            if cursors.isEmpty {
                cursorExpectation.fulfill()
            }
        }

        // Trigger promotion.
        for _ in 0..<3 { await standby.testSimulateLeaderHealthMiss() }

        let mode = await standby.testCurrentMode()
        XCTAssertEqual(mode, .leader, "Standby must promote")

        let cursors = await standby.testReplicationCursors()
        XCTAssertTrue(cursors.isEmpty, "All cursors must be cleared on promotion (new term = new epoch)")
        
        await fulfillment(of: [cursorExpectation], timeout: 2.0)
    }
}
