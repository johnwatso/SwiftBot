import Foundation
import OSLog

/// Bucket-aware rate limiter shared by every Discord REST client.
///
/// Discord partitions its REST limits into *buckets*. A bucket is not the same
/// thing as a route: several routes can share one bucket, and one route can map
/// to different buckets depending on its major parameter. The server tells us
/// which bucket a request landed in via `X-RateLimit-Bucket`, so we start out
/// keyed by our own route string and re-key onto the real bucket ID as soon as
/// we learn it.
///
/// Three limits are enforced here:
///
/// 1. **Per-bucket** — `X-RateLimit-Remaining` / `X-RateLimit-Reset-After`.
/// 2. **Global (reactive)** — a 429 carrying `X-RateLimit-Global: true` pauses
///    every route until `Retry-After` elapses.
/// 3. **Global (proactive)** — Discord allows ~50 requests/second per bot across
///    all routes. We hold a sliding one-second window so bursts across unrelated
///    routes (a sweep plus a DM fan-out, say) throttle themselves instead of
///    earning a 429.
///
/// Callers reserve a slot with `waitTurn(route:)` before sending and feed the
/// response headers back with `update(route:headers:)`. `DiscordRESTTransport`
/// does both, so most code never touches this type directly.
///
/// The bucket/scope handling follows the approach used by SwiftDisc
/// (github.com/M1tsumi/SwiftDisc, MIT); the optimistic reservation below is ours.
actor DiscordRateLimiter {

    /// What we know about one bucket, as of the last response we saw from it.
    private struct BucketState {
        var remaining: Int?
        var limit: Int?
        var resetAt: Date?
    }

    /// Discord's budgets are per bot token and the app runs one bot, so every
    /// REST client shares this instance. Tests inject their own.
    static let shared = DiscordRateLimiter()

    /// Discord's documented global ceiling: 50 requests/second per bot.
    static let globalRequestsPerSecond = 50

    /// Never sleep longer than this in one hop. A nonsense `Reset-After` (clock
    /// skew, a proxy rewriting headers) should slow us down, not wedge the app.
    private static let maxSingleWait: TimeInterval = 60

    /// Bucket state keyed by Discord's bucket ID once known, by route string until then.
    private var buckets: [String: BucketState] = [:]

    /// route string → Discord bucket ID, learned from `X-RateLimit-Bucket`.
    private var routeToBucket: [String: String] = [:]

    /// Set by a global 429; blocks every route until it passes.
    private var globalResetAt: Date?

    /// Send times inside the proactive one-second window.
    private var recentSendTimes: [Date] = []

    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let logger = Logger(subsystem: "com.swiftbot", category: "discord.ratelimit")

    /// - Parameters:
    ///   - now: Clock source. Injectable so tests don't depend on wall time.
    ///   - sleep: Suspension primitive. Injectable so tests don't actually wait.
    init(
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Reserving a slot

    /// Blocks until it is this caller's turn to send `route`, then reserves a slot.
    ///
    /// Each `await` inside re-enters the actor, so state is re-read from the top
    /// after every sleep rather than acted on stale.
    func waitTurn(route: DiscordRoute) async {
        while true {
            let instant = now()

            if !route.ignoresGlobalLimit {
                // 1. Reactive global pause from a previous 429.
                if let globalResetAt {
                    if globalResetAt > instant {
                        let delay = globalResetAt.timeIntervalSince(instant)
                        logger.debug("Global rate limit — holding \(delay, format: .fixed(precision: 2))s")
                        await sleep(min(delay, Self.maxSingleWait))
                        continue
                    }
                    self.globalResetAt = nil
                }

                // 2. Proactive 50/s sliding window.
                recentSendTimes.removeAll { instant.timeIntervalSince($0) >= 1 }
                if recentSendTimes.count >= Self.globalRequestsPerSecond, let oldest = recentSendTimes.first {
                    await sleep(max(0, 1 - instant.timeIntervalSince(oldest)))
                    continue
                }
            }

            // 3. Per-bucket budget.
            let key = bucketKey(for: route)
            if let state = buckets[key], let remaining = state.remaining, remaining <= 0 {
                if let resetAt = state.resetAt, resetAt > instant {
                    let delay = resetAt.timeIntervalSince(instant)
                    logger.debug("Bucket \(key, privacy: .public) exhausted — holding \(delay, format: .fixed(precision: 2))s")
                    await sleep(min(delay, Self.maxSingleWait))
                    continue
                }
                // Window elapsed. Clear the count and let the next response reseed it.
                buckets[key]?.remaining = nil
            }

            // Reserve. Decrementing here — rather than waiting for the response —
            // is what stops N concurrent callers from all reading `remaining == 1`
            // and sending together.
            if !route.ignoresGlobalLimit {
                recentSendTimes.append(instant)
            }
            if let remaining = buckets[key]?.remaining {
                buckets[key]?.remaining = remaining - 1
            }
            return
        }
    }

    // MARK: - Learning from responses

    /// Folds a response's rate-limit headers into the bucket state.
    func update(route: DiscordRoute, headers: [String: String]) {
        let header = Self.caseInsensitive(headers)

        // `X-RateLimit-Scope` distinguishes `user` (our own per-route budget),
        // `global` (our whole-bot budget) and `shared` (a per-resource limit that
        // every bot touching that resource shares). A shared-scope 429 must not
        // stall our other routes, so it never promotes to the global pause.
        let scope = header("X-RateLimit-Scope")?.lowercased()

        if header("X-RateLimit-Global")?.lowercased() == "true",
           scope != "shared",
           let retryAfter = header("Retry-After").flatMap(Double.init) {
            globalResetAt = now().addingTimeInterval(retryAfter)
            logger.warning("Global rate limit from Discord — pausing all routes for \(retryAfter, format: .fixed(precision: 2))s")
        }

        let key = resolveBucketKey(route: route, bucketID: header("X-RateLimit-Bucket"))

        let headerReset: Date? = {
            if let resetAfter = header("X-RateLimit-Reset-After").flatMap(Double.init) {
                return now().addingTimeInterval(resetAfter)
            }
            // Absolute unix seconds; only trustworthy if our clock agrees with Discord's.
            if let epoch = header("X-RateLimit-Reset").flatMap(Double.init) {
                return Date(timeIntervalSince1970: epoch)
            }
            return nil
        }()

        var state = buckets[key] ?? BucketState()
        let headerRemaining = header("X-RateLimit-Remaining").flatMap(Int.init)

        if let headerReset {
            // A later reset means Discord rolled us into a fresh window, so the
            // header count supersedes whatever we had. Within the same window,
            // responses can land out of order — keep the lower count so a stale
            // response can't hand budget back that a newer one already spent.
            let isNewWindow = state.resetAt.map { headerReset > $0.addingTimeInterval(0.001) } ?? true
            if isNewWindow {
                state.remaining = headerRemaining
            } else if let headerRemaining {
                state.remaining = min(headerRemaining, state.remaining ?? headerRemaining)
            }
            state.resetAt = headerReset
        } else if let headerRemaining {
            state.remaining = min(headerRemaining, state.remaining ?? headerRemaining)
        }

        if let limit = header("X-RateLimit-Limit").flatMap(Int.init) {
            state.limit = limit
        }
        buckets[key] = state
    }

    /// Records a 429 and returns how long the caller should wait before retrying,
    /// or `nil` if Discord gave us nothing usable to wait on.
    func noteRateLimited(route: DiscordRoute, headers: [String: String], body: Data?) -> TimeInterval? {
        update(route: route, headers: headers)

        let header = Self.caseInsensitive(headers)
        var retryAfter = header("Retry-After").flatMap(Double.init)

        // Discord's REST 429 body carries a fractional `retry_after`; the header is
        // whole seconds. Prefer the body when both are present.
        if let body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let seconds = json["retry_after"] as? Double {
                retryAfter = seconds
            } else if let seconds = json["retry_after"] as? Int {
                retryAfter = Double(seconds)
            }
        }

        guard let retryAfter else { return nil }
        let delay = min(max(0, retryAfter), Self.maxSingleWait)

        // Park the bucket for the retry window so *other* callers on it wait too,
        // instead of piling on and collecting their own 429s.
        let key = bucketKey(for: route)
        var state = buckets[key] ?? BucketState()
        state.remaining = 0
        state.resetAt = now().addingTimeInterval(delay)
        buckets[key] = state

        logger.warning("429 on \(route.key, privacy: .public) — retrying in \(delay, format: .fixed(precision: 2))s")
        return delay
    }

    // MARK: - Bucket keys

    private func bucketKey(for route: DiscordRoute) -> String {
        routeToBucket[route.key] ?? route.key
    }

    /// Maps `route` onto Discord's bucket ID, migrating any state we accumulated
    /// under the provisional key so routes that share a bucket share one budget.
    private func resolveBucketKey(route: DiscordRoute, bucketID: String?) -> String {
        guard let bucketID, !bucketID.isEmpty else { return bucketKey(for: route) }

        let previousKey = bucketKey(for: route)
        guard previousKey != bucketID else { return bucketID }

        routeToBucket[route.key] = bucketID
        if let carried = buckets.removeValue(forKey: previousKey), buckets[bucketID] == nil {
            buckets[bucketID] = carried
        }
        return bucketID
    }

    private static func caseInsensitive(_ headers: [String: String]) -> (String) -> String? {
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        return { lowered[$0.lowercased()] }
    }

    // MARK: - Introspection

    /// Remaining requests known for `route`'s bucket, for diagnostics UI.
    func remaining(for route: DiscordRoute) -> Int? {
        buckets[bucketKey(for: route)]?.remaining
    }

    /// Whether a global rate limit is currently in force.
    var isGloballyLimited: Bool {
        guard let globalResetAt else { return false }
        return globalResetAt > now()
    }
}
