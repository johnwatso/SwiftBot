import Foundation

/// Fetches the latest item from an upstream update feed.
public protocol UpdateSource: Sendable {
    /// Stable source key used for cache partitioning.
    var sourceKey: String { get }

    /// Fetch the latest item from the source.
    func fetchLatest() async throws -> any UpdateItem
}

/// Type-erased update source for heterogeneous collections.
public struct AnyUpdateSource: UpdateSource, Sendable {
    public let sourceKey: String
    private let fetchClosure: @Sendable () async throws -> any UpdateItem

    public init(
        sourceKey: String,
        fetch: @escaping @Sendable () async throws -> any UpdateItem
    ) {
        self.sourceKey = sourceKey
        self.fetchClosure = fetch
    }

    public func fetchLatest() async throws -> any UpdateItem {
        try await fetchClosure()
    }
}
