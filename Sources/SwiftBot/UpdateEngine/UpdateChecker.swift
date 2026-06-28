import Foundation

public enum UpdateChangeResult: Equatable, Sendable {
    case firstSeen(identifier: String)
    case changed(old: String, new: String)
    case unchanged(identifier: String)

    public var isNewItem: Bool {
        switch self {
        case .firstSeen, .changed:
            return true
        case .unchanged:
            return false
        }
    }

    public var currentIdentifier: String {
        switch self {
        case .firstSeen(let identifier):
            return identifier
        case .changed(_, let new):
            return new
        case .unchanged(let identifier):
            return identifier
        }
    }
}

/// Identifier-based update comparison.
/// The checker has no knowledge of guilds/vendors and only operates on cache keys.
public actor UpdateChecker {
    private let store: any VersionStore

    public init(store: any VersionStore) {
        self.store = store
    }

    /// Compare the latest identifier against the cached identifier for a key.
    public func check(identifier: String, for key: String) async throws -> UpdateChangeResult {
        let normalizedKey = CacheKeyBuilder.normalizeCacheKey(key)
        guard let lastIdentifier = try await store.lastIdentifier(for: normalizedKey) else {
            return .firstSeen(identifier: identifier)
        }

        if lastIdentifier != identifier {
            return .changed(old: lastIdentifier, new: identifier)
        }

        return .unchanged(identifier: identifier)
    }

    /// Convenience API that checks an UpdateItem using its source key by default.
    public func check(item: any UpdateItem, for keyOverride: String? = nil) async throws -> UpdateChangeResult {
        let key = keyOverride ?? item.sourceKey
        return try await check(identifier: item.identifier, for: key)
    }

    /// Persist an identifier for a cache key.
    public func save(identifier: String, for key: String) async throws {
        let normalizedKey = CacheKeyBuilder.normalizeCacheKey(key)
        try await store.save(identifier: identifier, for: normalizedKey)
    }

    /// Convenience API to persist an UpdateItem identifier.
    public func save(item: any UpdateItem, for keyOverride: String? = nil) async throws {
        let key = keyOverride ?? item.sourceKey
        try await save(identifier: item.identifier, for: key)
    }
}
