import XCTest
@testable import SwiftBot

final class MeshJobReliabilityTests: XCTestCase {
    actor Counter {
        var count = 0
        func increment() { count += 1 }
    }
    actor Term {
        var value = 1
        func advance() { value += 1 }
    }
    private func job(id: UUID = UUID(), deadline: Date = Date().addingTimeInterval(10), payload: String = "input") -> MeshJobRequestEnvelope {
        MeshJobRequestEnvelope(jobID: id, originNodeName: "Primary", leaderTerm: 1, kind: .aiReply, deadline: deadline, payload: Data(payload.utf8))
    }

    func testConcurrentDuplicateRequestsComputeOnce() async {
        let ledger = MeshJobLedger()
        let counter = Counter()
        let request = job()
        let operation: MeshJobLedger.Operation = { _ in
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(50))
            return Data("result".utf8)
        }
        async let first = ledger.execute(request, currentLeaderTerm: { 1 }, operation: operation)
        async let second = ledger.execute(request.retry(attempt: 2), currentLeaderTerm: { 1 }, operation: operation)
        let results = await [first, second]
        let count = await counter.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(results.allSatisfy { $0.status == .completed && $0.result == Data("result".utf8) })
    }

    func testCompletedResultSurvivesWorkerRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let counter = Counter()
        let request = job()
        let original = MeshJobLedger(storageURL: url)
        _ = await original.execute(request, currentLeaderTerm: { 1 }, operation: { _ in await counter.increment(); return Data("saved".utf8) })
        let restored = MeshJobLedger(storageURL: url)
        let response = await restored.execute(request.retry(attempt: 2), currentLeaderTerm: { 1 }, operation: { _ in await counter.increment(); return Data("wrong".utf8) })
        let count = await counter.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(response.result, Data("saved".utf8))
    }

    func testConflictingInputCannotReuseJobID() async {
        let ledger = MeshJobLedger()
        let request = job()
        _ = await ledger.execute(request, currentLeaderTerm: { 1 }, operation: { _ in Data() })
        let conflict = job(id: request.jobID, deadline: request.deadline, payload: "different")
        let response = await ledger.execute(conflict, currentLeaderTerm: { 1 }, operation: { _ in XCTFail("Must not compute conflicting input"); return nil })
        XCTAssertEqual(response.status, .conflictingJob)
    }

    func testLeadershipChangeDiscardsLateComputation() async {
        let ledger = MeshJobLedger()
        let term = Term()
        let started = expectation(description: "computation starts")
        let request = job()
        let task = Task {
            await ledger.execute(request, currentLeaderTerm: { await term.value }, operation: { _ in
                started.fulfill()
                try? await Task.sleep(for: .milliseconds(100))
                return Data("obsolete".utf8)
            })
        }
        await fulfillment(of: [started], timeout: 2)
        await term.advance()
        await ledger.observeLeadership(term: 2)
        let response = await task.value
        XCTAssertEqual(response.status, .staleLeadership)
        XCTAssertNil(response.result)
    }

    func testDeadlineExpiresAndCapacityIsBounded() async {
        let ledger = MeshJobLedger(maximumConcurrentJobs: 1)
        let started = expectation(description: "first occupies capacity")
        let first = job(deadline: Date().addingTimeInterval(0.1))
        let task = Task {
            await ledger.execute(first, currentLeaderTerm: { 1 }, operation: { _ in
                started.fulfill()
                try? await Task.sleep(for: .milliseconds(200))
                return Data("too late".utf8)
            })
        }
        await fulfillment(of: [started], timeout: 2)
        let busy = await ledger.execute(job(), currentLeaderTerm: { 1 }, operation: { _ in XCTFail("Capacity exceeded"); return nil })
        let expired = await task.value
        XCTAssertEqual(busy.status, .busy)
        XCTAssertEqual(expired.status, .expired)
        XCTAssertNil(expired.result)
    }

    func testOutboundPollRestrictsAssignmentAndAcceptsIdempotentResult() async {
        let queue = MeshOutboundJobQueue()
        let request = job()
        let waiting = Task { await queue.enqueue(nodeName: "Backup", request: request, currentLeaderTerm: { 1 }) }
        for _ in 0..<100 {
            if await queue.pendingJobCount == 1 { break }
            await Task.yield()
        }
        let wrong = await queue.poll(MeshJobPollRequest(nodeName: "Other", leaderTerm: 1), currentLeaderTerm: 1)
        let assigned = await queue.poll(MeshJobPollRequest(nodeName: "Backup", leaderTerm: 1), currentLeaderTerm: 1)
        XCTAssertTrue(wrong.jobs.isEmpty)
        XCTAssertEqual(assigned.jobs.map(\.jobID), [request.jobID])
        let result = MeshJobResponseEnvelope(jobID: request.jobID, leaderTerm: 1, currentLeaderTerm: 1, status: .completed, result: Data("computed".utf8))
        let bad = await queue.complete(MeshJobResultSubmission(nodeName: "Other", inputHash: request.inputHash, response: result), currentLeaderTerm: 1)
        let accepted = await queue.complete(MeshJobResultSubmission(nodeName: "Backup", inputHash: request.inputHash, response: result), currentLeaderTerm: 1)
        let duplicate = await queue.complete(MeshJobResultSubmission(nodeName: "Backup", inputHash: request.inputHash, response: result), currentLeaderTerm: 1)
        let response = await waiting.value
        XCTAssertFalse(bad)
        XCTAssertTrue(accepted)
        XCTAssertTrue(duplicate)
        XCTAssertEqual(response.result, Data("computed".utf8))
    }
}
