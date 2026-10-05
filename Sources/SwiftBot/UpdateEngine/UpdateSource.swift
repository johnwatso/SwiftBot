import Foundation

/// Fetches the latest item from an upstream update feed.
public protocol UpdateSource: Sendable {
    /// Stable source key used for cache partitioning.
    var sourceKey: String { get }

    /// Fetch the latest item from the source.
    func fetchLatest() async throws -> any UpdateItem
}

