import XCTest
@testable import SwiftBot

final class VoiceRecoveryBackoffTests: XCTestCase {
    func testAttemptsFollowScheduleThenExhaust() {
        var backoff = VoiceRecoveryBackoff(schedule: [.seconds(1), .seconds(2), .seconds(3)])

        XCTAssertEqual(backoff.beginAttempt(), .seconds(1))
        backoff.finish(success: false)
        XCTAssertEqual(backoff.beginAttempt(), .seconds(2))
        backoff.finish(success: false)
        XCTAssertEqual(backoff.beginAttempt(), .seconds(3))
        backoff.finish(success: false)
        XCTAssertNil(backoff.beginAttempt(), "budget must be exhausted after the schedule runs out")
    }

    func testNoConcurrentAttempts() {
        var backoff = VoiceRecoveryBackoff(schedule: [.seconds(1), .seconds(2)])

        XCTAssertNotNil(backoff.beginAttempt())
        XCTAssertNil(backoff.beginAttempt(), "a second attempt must not start while one is in flight")
    }

    func testSuccessRestoresFullBudget() {
        var backoff = VoiceRecoveryBackoff(schedule: [.seconds(1), .seconds(2)])

        XCTAssertNotNil(backoff.beginAttempt())
        backoff.finish(success: false)
        XCTAssertNotNil(backoff.beginAttempt())
        backoff.finish(success: true)

        XCTAssertEqual(backoff.attemptsMade, 0)
        XCTAssertEqual(backoff.beginAttempt(), .seconds(1))
    }

    func testCancelKeepsBudgetConsumed() {
        var backoff = VoiceRecoveryBackoff(schedule: [.seconds(1), .seconds(2)])

        XCTAssertNotNil(backoff.beginAttempt())
        backoff.cancel()
        XCTAssertFalse(backoff.inProgress)
        XCTAssertEqual(backoff.beginAttempt(), .seconds(2), "cancel must not refund the used attempt")
    }

    func testResetRestoresEverything() {
        var backoff = VoiceRecoveryBackoff(schedule: [.seconds(1)])

        XCTAssertNotNil(backoff.beginAttempt())
        backoff.reset()
        XCTAssertFalse(backoff.inProgress)
        XCTAssertEqual(backoff.beginAttempt(), .seconds(1))
    }
}
