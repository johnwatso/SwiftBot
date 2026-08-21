import Foundation

/// A Discord REST route reduced to its rate-limit identity.
///
/// Discord buckets by route *shape* plus the "major parameter" — the guild,
/// channel or webhook the call acts on. `/channels/111/messages` and
/// `/channels/222/messages` are separate budgets; `/channels/111/messages/A` and
/// `/channels/111/messages/B` are the same one. So major parameters stay literal
/// in the key and every other snowflake collapses to a placeholder.
struct DiscordRoute: Sendable, Hashable {
    let key: String

    /// Interaction callbacks are exempt from Discord's global request limit, and
    /// they carry a hard three-second deadline. Holding one behind the global
    /// window would trade a rate-limit warning for a failed interaction.
    let ignoresGlobalLimit: Bool

    /// Path segments whose *following* segment is a major parameter.
    private static let majorParameterParents: Set<String> = ["channels", "guilds", "webhooks"]

    init(key: String, ignoresGlobalLimit: Bool = false) {
        self.key = key
        self.ignoresGlobalLimit = ignoresGlobalLimit
    }

    /// Derives the route from a prepared request. Falls back to the raw path if
    /// the URL is missing, which only costs us key precision, never correctness.
    init(request: URLRequest) {
        let method = request.httpMethod ?? "GET"
        let segments = Self.normalizedSegments(from: request.url)

        var key = "\(method) /\(segments.joined(separator: "/"))"

        // Deleting a message has its own, much stricter bucket than every other
        // call on the same channel — Discord documents it as a special case.
        if method == "DELETE",
           segments.count == 4,
           segments[0] == "channels",
           segments[2] == "messages" {
            key = "DELETE-MESSAGE " + key
        }

        self.key = key
        self.ignoresGlobalLimit = segments.first == "interactions"
    }

    /// Strips the `/api/v10` prefix and replaces non-major identifiers with
    /// placeholders so one key covers the whole family of calls in a bucket.
    private static func normalizedSegments(from url: URL?) -> [String] {
        guard let url else { return ["unknown"] }

        var segments = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        if segments.first == "api" {
            segments.removeFirst()
            if let first = segments.first, first.count > 1, first.hasPrefix("v"), Int(first.dropFirst()) != nil {
                segments.removeFirst()
            }
        }

        return segments.enumerated().map { index, segment in
            let parent = index > 0 ? segments[index - 1] : nil

            // Major parameter — keep it, it is part of the bucket identity.
            if let parent, majorParameterParents.contains(parent) {
                return segment
            }
            if isSnowflake(segment) {
                return "{id}"
            }
            // Webhook and interaction tokens: long opaque strings sitting directly
            // after the ID they belong to. They vary per call, so left alone they
            // would fan the key space out to one bucket per request.
            if let parent, isSnowflake(parent),
               segment.count >= 24,
               segment.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) != nil {
                return "{token}"
            }
            return segment
        }
    }

    private static func isSnowflake(_ segment: String) -> Bool {
        segment.count >= 15 && segment.allSatisfy(\.isNumber)
    }
}

/// The single send path for Discord REST calls.
///
/// Everything routed through here shares one `DiscordRateLimiter`, so the bucket
/// budget learned by a message send is respected by the next audit-log fetch on
/// the same guild. It also absorbs 429s: callers see either a real response or a
/// thrown error, never a rate-limit status they have to retry themselves.
struct DiscordRESTTransport: Sendable {
    /// How many times a single call will be replayed after a 429 before giving up.
    static let maxRateLimitRetries = 3

    let session: URLSession
    let limiter: DiscordRateLimiter

    /// Sends `request`, waiting for bucket budget first and retrying through 429s.
    ///
    /// Returns `URLResponse` rather than `HTTPURLResponse` so call sites keep their
    /// existing `as? HTTPURLResponse` checks and status-code error paths unchanged.
    ///
    /// - Parameter reserveSlot: Pass `false` for health probes and diagnostics,
    ///   which should report the live state of the API rather than block on our
    ///   own bookkeeping. Their response headers are still folded back in.
    func perform(_ request: URLRequest, reserveSlot: Bool = true) async throws -> (Data, URLResponse) {
        let route = DiscordRoute(request: request)
        var attempt = 0

        while true {
            if reserveSlot {
                await limiter.waitTurn(route: route)
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "DiscordService",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Invalid response",
                        "statusCode": -1,
                        "responseBody": ""
                    ]
                )
            }

            let headers = Self.headerFields(from: http)

            guard http.statusCode == 429 else {
                await limiter.update(route: route, headers: headers)
                return (data, http)
            }

            let delay = await limiter.noteRateLimited(route: route, headers: headers, body: data)
            attempt += 1
            guard attempt <= Self.maxRateLimitRetries, let delay else {
                // Out of retries, or Discord did not tell us how long to wait.
                // Hand the 429 back in the shape callers already expect.
                return (data, http)
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private static func headerFields(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(response.allHeaderFields.count)
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            result[key] = String(describing: value)
        }
        return result
    }
}
