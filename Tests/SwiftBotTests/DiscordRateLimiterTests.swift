import XCTest
@testable import SwiftBot

final class DiscordRateLimiterTests: XCTestCase {

    // MARK: - Route keys

    func testRouteKeepsMajorParameterAndCollapsesMessageID() {
        let route = DiscordRoute(request: request("POST", "https://discord.com/api/v10/channels/111111111111111111/messages"))
        XCTAssertEqual(route.key, "POST /channels/111111111111111111/messages")

        let edit = DiscordRoute(request: request("PATCH", "https://discord.com/api/v10/channels/111111111111111111/messages/222222222222222222"))
        XCTAssertEqual(edit.key, "PATCH /channels/111111111111111111/messages/{id}")
    }

    func testDifferentChannelsGetDifferentBuckets() {
        let first = DiscordRoute(request: request("POST", "https://discord.com/api/v10/channels/111111111111111111/messages"))
        let second = DiscordRoute(request: request("POST", "https://discord.com/api/v10/channels/999999999999999999/messages"))
        XCTAssertNotEqual(first.key, second.key)
    }

    func testMessageDeleteGetsItsOwnBucket() {
        let delete = DiscordRoute(request: request("DELETE", "https://discord.com/api/v10/channels/111111111111111111/messages/222222222222222222"))
        let edit = DiscordRoute(request: request("PATCH", "https://discord.com/api/v10/channels/111111111111111111/messages/222222222222222222"))
        XCTAssertTrue(delete.key.hasPrefix("DELETE-MESSAGE "))
        XCTAssertNotEqual(delete.key, edit.key)
    }

    func testWebhookTokenCollapsesToPlaceholder() {
        let route = DiscordRoute(request: request(
            "PATCH",
            "https://discord.com/api/v10/webhooks/111111111111111111/aVeryLongInteractionTokenValue123456/messages/@original"
        ))
        XCTAssertEqual(route.key, "PATCH /webhooks/111111111111111111/{token}/messages/@original")
    }

    func testInteractionCallbackIsExemptFromGlobalLimit() {
        let callback = DiscordRoute(request: request(
            "POST",
            "https://discord.com/api/v10/interactions/111111111111111111/aVeryLongInteractionTokenValue123456/callback"
        ))
        XCTAssertTrue(callback.ignoresGlobalLimit)
        XCTAssertEqual(callback.key, "POST /interactions/{id}/{token}/callback")

        let send = DiscordRoute(request: request("POST", "https://discord.com/api/v10/channels/111111111111111111/messages"))
        XCTAssertFalse(send.ignoresGlobalLimit)
    }

    // MARK: - Bucket budget

    func testExhaustedBucketWaitsForItsReset() async {
        let clock = TestClock()
        let limiter = DiscordRateLimiter(now: clock.now, sleep: clock.sleep)
        let route = DiscordRoute(key: "POST /channels/1/messages")

        await limiter.update(route: route, headers: [
            "X-RateLimit-Bucket": "bucket-a",
            "X-RateLimit-Limit": "1",
            "X-RateLimit-Remaining": "1",
            "X-RateLimit-Reset-After": "5"
        ])

        await limiter.waitTurn(route: route)
        XCTAssertEqual(clock.recordedSleeps.count, 0, "Budget was available — should not have waited")

        await limiter.waitTurn(route: route)
        let sleeps = clock.recordedSleeps
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps.first ?? 0, 5, accuracy: 0.01)
    }

    func testReservationSpendsBudgetBeforeTheResponseArrives() async {
        let clock = TestClock()
        let limiter = DiscordRateLimiter(now: clock.now, sleep: clock.sleep)
        let route = DiscordRoute(key: "POST /channels/1/messages")

        await limiter.update(route: route, headers: [
            "X-RateLimit-Bucket": "bucket-a",
            "X-RateLimit-Limit": "5",
            "X-RateLimit-Remaining": "2",
            "X-RateLimit-Reset-After": "5"
        ])

        // Two sends fit in the window. Nothing reports back in between, so only a
        // limiter that decrements on reservation knows the third must wait.
        await limiter.waitTurn(route: route)
        await limiter.waitTurn(route: route)
        XCTAssertEqual(clock.recordedSleeps.count, 0)

        await limiter.waitTurn(route: route)
        XCTAssertEqual(clock.recordedSleeps.count, 1)
    }

    func testConcurrentCallersDoNotAllSailThroughOnAStaleCount() async {
        let clock = TestClock()
        let limiter = DiscordRateLimiter(now: clock.now, sleep: clock.sleep)
        let route = DiscordRoute(key: "POST /channels/1/messages")

        await limiter.update(route: route, headers: [
            "X-RateLimit-Bucket": "bucket-a",
            "X-RateLimit-Limit": "5",
            "X-RateLimit-Remaining": "2",
            "X-RateLimit-Reset-After": "5"
        ])

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { await limiter.waitTurn(route: route) }
            }
        }

        // How many end up waiting depends on interleaving — the clock jumps to the
        // reset on the first sleep, releasing the rest. The invariant that matters
        // is that five callers could not all spend a budget of two.
        XCTAssertGreaterThanOrEqual(clock.recordedSleeps.count, 1)
    }

    func testRoutesSharingADiscordBucketShareOneBudget() async {
        let clock = TestClock()
        let limiter = DiscordRateLimiter(now: clock.now, sleep: clock.sleep)
        let first = DiscordRoute(key: "GET /guilds/1/roles")
        let second = DiscordRoute(key: "GET /guilds/1/members/{id}")

        // Discord reports both routes as the same bucket.
        await limiter.update(route: first, headers: [
            "X-RateLimit-Bucket": "shared-bucket",
            "X-RateLimit-Remaining": "1",
            "X-RateLimit-Reset-After": "3"
        ])
        await limiter.update(route: second, headers: [
            "X-RateLimit-Bucket": "shared-bucket",
            "X-RateLimit-Remaining": "1",
            "X-RateLimit-Reset-After": "3"
        ])

        await limiter.waitTurn(route: first)
        await limiter.waitTurn(route: second)

        XCTAssertEqual(clock.recordedSleeps.count, 1, "Second route should have seen the first route's spend")
    }

    // MARK: - Global limits

    func testGlobalRateLimitPausesEveryRoute() async {
        let clock = TestClock()
        let limiter = DiscordRateLimiter(now: clock.now, sleep: clock.sleep)
        let limited = DiscordRoute(key: "POST /channels/1/messages")
        let unrelated = DiscordRoute(key: "GET /guilds/2/roles")

        await limiter.update(route: limited, headers: [
            "X-RateLimit-Global": "true",
            "Retry-After": "4"
        ])

        let isLimited = await limiter.isGloballyLimited
        XCTAssertTrue(isLimited)
        await limiter.waitTurn(route: unrelated)

        let sleeps = clock.recordedSleeps
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps.first ?? 0, 4, accuracy: 0.01)
    }

    func testSharedScopeDoesNotTriggerAGlobalPause() async {
        let clock = TestClock()
        let limiter = DiscordRateLimiter(now: clock.now, sleep: clock.sleep)
        let route = DiscordRoute(key: "POST /channels/1/messages")

        // A `shared` scope limit belongs to the resource, not to our bot's global
        // budget, so unrelated routes must keep flowing.
        await limiter.update(route: route, headers: [
            "X-RateLimit-Global": "true",
            "X-RateLimit-Scope": "shared",
            "Retry-After": "4"
        ])

        let isLimited = await limiter.isGloballyLimited
        XCTAssertFalse(isLimited)
        await limiter.waitTurn(route: DiscordRoute(key: "GET /guilds/2/roles"))
        XCTAssertEqual(clock.recordedSleeps.count, 0)
    }

    func testProactiveGlobalWindowThrottlesBurstsAcrossRoutes() async {
        let clock = TestClock()
        let limiter = DiscordRateLimiter(now: clock.now, sleep: clock.sleep)

        // 50 sends on distinct routes fit in the window; the 51st must wait.
        for index in 0..<DiscordRateLimiter.globalRequestsPerSecond {
            await limiter.waitTurn(route: DiscordRoute(key: "GET /route-\(index)"))
        }
        XCTAssertEqual(clock.recordedSleeps.count, 0)

        await limiter.waitTurn(route: DiscordRoute(key: "GET /route-overflow"))
        XCTAssertEqual(clock.recordedSleeps.count, 1)
    }

    func testInteractionCallbacksBypassTheGlobalPause() async {
        let clock = TestClock()
        let limiter = DiscordRateLimiter(now: clock.now, sleep: clock.sleep)

        await limiter.update(route: DiscordRoute(key: "POST /channels/1/messages"), headers: [
            "X-RateLimit-Global": "true",
            "Retry-After": "4"
        ])

        let callback = DiscordRoute(key: "POST /interactions/{id}/{token}/callback", ignoresGlobalLimit: true)
        await limiter.waitTurn(route: callback)

        XCTAssertEqual(clock.recordedSleeps.count, 0, "Interaction callbacks have a 3s deadline and are globally exempt")
    }

    // MARK: - 429 handling

    func testNoteRateLimitedPrefersTheBodyRetryAfterAndParksTheBucket() async {
        let clock = TestClock()
        let limiter = DiscordRateLimiter(now: clock.now, sleep: clock.sleep)
        let route = DiscordRoute(key: "POST /channels/1/messages")

        let body = #"{"message":"You are being rate limited.","retry_after":0.75,"global":false}"#.data(using: .utf8)
        let delay = await limiter.noteRateLimited(route: route, headers: ["Retry-After": "1"], body: body)

        XCTAssertEqual(delay ?? 0, 0.75, accuracy: 0.001, "Body carries fractional seconds; header rounds up to 1")
        let remaining = await limiter.remaining(for: route)
        XCTAssertEqual(remaining, 0, "Bucket should be parked so other callers wait too")
    }

    func testStaleResponseCannotHandBackSpentBudget() async {
        let clock = TestClock()
        let limiter = DiscordRateLimiter(now: clock.now, sleep: clock.sleep)
        let route = DiscordRoute(key: "POST /channels/1/messages")

        let window = ["X-RateLimit-Bucket": "bucket-a", "X-RateLimit-Reset-After": "5"]
        await limiter.update(route: route, headers: window.merging(["X-RateLimit-Remaining": "2"]) { _, new in new })
        // An out-of-order response from the same window reporting a higher count.
        await limiter.update(route: route, headers: window.merging(["X-RateLimit-Remaining": "4"]) { _, new in new })

        let remaining = await limiter.remaining(for: route)
        XCTAssertEqual(remaining, 2)
    }

    func testNewWindowRestoresTheFullBudget() async {
        let clock = TestClock()
        let limiter = DiscordRateLimiter(now: clock.now, sleep: clock.sleep)
        let route = DiscordRoute(key: "POST /channels/1/messages")

        await limiter.update(route: route, headers: [
            "X-RateLimit-Bucket": "bucket-a",
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset-After": "5"
        ])
        await limiter.update(route: route, headers: [
            "X-RateLimit-Bucket": "bucket-a",
            "X-RateLimit-Remaining": "5",
            "X-RateLimit-Reset-After": "10"
        ])

        let remaining = await limiter.remaining(for: route)
        XCTAssertEqual(remaining, 5)
    }

    // MARK: - Helpers

    private func request(_ method: String, _ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        return request
    }
}

/// Deterministic clock: records what the limiter asked to sleep for and advances
/// its own notion of time by that much, so tests never wait on wall time.
///
/// Time only moves when the limiter sleeps, which is also what keeps a blocked
/// caller from spinning forever against a reset that never arrives.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
    private var sleeps: [TimeInterval] = []

    var recordedSleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return sleeps
    }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return currentTime
        }
    }

    var sleep: @Sendable (TimeInterval) async -> Void {
        { [self] seconds in record(seconds) }
    }

    /// Kept synchronous: `NSLock` is unavailable directly inside an async context.
    private func record(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        sleeps.append(seconds)
        currentTime = currentTime.addingTimeInterval(seconds)
    }
}
