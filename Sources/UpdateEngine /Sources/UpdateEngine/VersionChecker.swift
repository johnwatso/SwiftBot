import Foundation

// MARK: - Update Source Protocol

/// Protocol for any update source (drivers, game patches, etc.)
/// Exposes a cache key for version tracking.
protocol UpdateSource {
    /// The base cache key for this update source.
    /// Examples: "nvidia-gameready", "amd-default", "intel-default"
    /// Guild context will be added externally by the runtime.
    var cacheKey: String { get }
    
    /// The current version from this source
    var version: String { get }
}

// MARK: - Version Change Result

enum VersionChangeResult {
    case changed(old: String?, new: String)
    case unchanged(version: String)
    case firstCheck(version: String)
    
    var isNewVersion: Bool {
        switch self {
        case .changed, .firstCheck:
            return true
        case .unchanged:
            return false
        }
    }
    
    var currentVersion: String {
        switch self {
        case .changed(_, let new):
            return new
        case .unchanged(let version):
            return version
        case .firstCheck(let version):
            return version
        }
    }
}

// MARK: - Update Checker

/// Core update checking logic.
/// Accepts full cache keys - does not assume any specific format.
/// Guild scoping must be handled externally.
final class UpdateChecker: Sendable {
    private let store: VersionStore
    
    init(store: VersionStore) {
        self.store = store
    }
    
    /// Check if a version has changed for a given cache key
    /// - Parameters:
    ///   - version: The current version string
    ///   - key: Full cache key (can include guild context)
    /// - Returns: Result indicating if version changed
    func check(version: String, for key: String) -> VersionChangeResult {
        guard let lastVersion = store.lastVersion(for: key) else {
            return .firstCheck(version: version)
        }
        
        if lastVersion != version {
            return .changed(old: lastVersion, new: version)
        }
        
        return .unchanged(version: version)
    }
    
    /// Save a version to the store
    /// - Parameters:
    ///   - version: The version string to store
    ///   - key: Full cache key (can include guild context)
    /// - Throws: Storage errors
    func save(version: String, for key: String) throws {
        try store.save(version: version, for: key)
    }
}

// MARK: - Cache Key Builder

/// Utility for building cache keys.
/// SwiftBot runtime can use this to construct guild-scoped keys.
struct CacheKeyBuilder {
    /// Build a simple cache key from vendor and channel
    /// - Parameters:
    ///   - vendor: Vendor name (e.g., "NVIDIA", "AMD")
    ///   - channel: Channel name (e.g., "gameReady", "default")
    /// - Returns: Cache key string (e.g., "nvidia-gameready")
    static func build(vendor: String, channel: String = "default") -> String {
        let vendorLower = vendor.lowercased().replacingOccurrences(of: " ", with: "-")
        let channelLower = channel.lowercased().replacingOccurrences(of: " ", with: "-")
        return "\(vendorLower)-\(channelLower)"
    }
    
    /// Build a guild-scoped cache key
    /// - Parameters:
    ///   - guildID: Guild identifier (e.g., "123456789")
    ///   - baseKey: Base cache key (e.g., "nvidia-gameready")
    /// - Returns: Guild-scoped cache key (e.g., "guild:123456789:nvidia-gameready")
    static func buildGuildScoped(guildID: String, baseKey: String) -> String {
        return "guild:\(guildID):\(baseKey)"
    }
    
    /// Build a guild-scoped cache key from vendor and channel
    /// - Parameters:
    ///   - guildID: Guild identifier
    ///   - vendor: Vendor name
    ///   - channel: Channel name
    /// - Returns: Guild-scoped cache key
    static func buildGuildScoped(guildID: String, vendor: String, channel: String = "default") -> String {
        let baseKey = build(vendor: vendor, channel: channel)
        return buildGuildScoped(guildID: guildID, baseKey: baseKey)
    }
}
