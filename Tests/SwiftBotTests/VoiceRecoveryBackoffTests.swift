import XCTest
@testable import SwiftBot

final class VoiceRecoveryBackoffTests: XCTestCase {
    func testQueuedRecoveryBecomesStalledAfterThreshold() {
        var health = VoiceAnnouncerHealth()
        health.phase = .recovering
        health.queueDepth = 1
        health.isPaused = true
        health.lastFailureAt = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertFalse(health.isStalled(now: Date(timeIntervalSinceReferenceDate: 159), threshold: 60))
        XCTAssertTrue(health.isStalled(now: Date(timeIntervalSinceReferenceDate: 160), threshold: 60))
    }

    func testEmptyRecoveryDoesNotTriggerAReconnect() {
        var health = VoiceAnnouncerHealth()
        health.phase = .recovering
        health.lastRecoveryAt = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertFalse(health.isStalled(now: Date(timeIntervalSinceReferenceDate: 1_000), threshold: 60))
    }

    func testAttemptsFollowScheduleThenExhaust() {
        var backoff = VoiceRecoveryBackoff(schedule: [.seconds(1), .seconds(2), .seconds(3)])

        XCTAssertEqual(backoff.beginAttempt(), .seconds(1))
        backoff.finishAttempt()
        XCTAssertEqual(backoff.beginAttempt(), .seconds(2))
        backoff.finishAttempt()
        XCTAssertEqual(backoff.beginAttempt(), .seconds(3))
        backoff.finishAttempt()
        XCTAssertNil(backoff.beginAttempt(), "budget must be exhausted after the schedule runs out")
    }

    func testNoConcurrentAttempts() {
        var backoff = VoiceRecoveryBackoff(schedule: [.seconds(1), .seconds(2)])

        XCTAssertNotNil(backoff.beginAttempt())
        XCTAssertNil(backoff.beginAttempt(), "a second attempt must not start while one is in flight")
    }

    func testFinishedAttemptRemainsConsumedUntilStableReset() {
        var backoff = VoiceRecoveryBackoff(schedule: [.seconds(1), .seconds(2)])

        XCTAssertNotNil(backoff.beginAttempt())
        backoff.finishAttempt()
        XCTAssertNotNil(backoff.beginAttempt())
        backoff.finishAttempt()

        XCTAssertEqual(backoff.attemptsMade, 2)
        XCTAssertNil(backoff.beginAttempt(), "a short-lived connection must not refund a spent attempt")

        backoff.reset()
        XCTAssertEqual(backoff.beginAttempt(), .seconds(1), "the owner refunds attempts after its stability window")
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

    func testCircuitBreakerOpensThenResetsForManualRecovery() {
        var breaker = AnnouncerRecoveryCircuitBreaker()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        breaker.trip(reason: "voice recovery exhausted", attempts: 3, now: now, cooldown: 300)

        XCTAssertEqual(breaker.exhaustedAttempts, 3)
        XCTAssertEqual(breaker.reason, "voice recovery exhausted")
        XCTAssertEqual(breaker.remainingSeconds(now: now), 300)
        XCTAssertEqual(breaker.remainingSeconds(now: now.addingTimeInterval(301)), 0)

        breaker.reset()
        XCTAssertEqual(breaker.exhaustedAttempts, 0)
        XCTAssertNil(breaker.reason)
        XCTAssertEqual(breaker.remainingSeconds(now: now), 0)
    }
}
