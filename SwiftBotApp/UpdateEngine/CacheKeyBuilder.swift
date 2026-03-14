import Foundation

/// Utility for deterministic cache key generation.
public enum CacheKeyBuilder {
    /// Build a normalized base key from vendor/channel.
    public static func build(vendor: String, channel: String = "default") -> String {
        let vendorPart = normalizeComponent(vendor)
        let channelPart = normalizeComponent(channel)
        return "\(vendorPart)-\(channelPart)"
    }

    /// Build a guild-scoped cache key.
    public static func buildGuildScoped(guildID: String, baseKey: String) -> String {
        buildScoped(scopeType: "guild", scopeID: guildID, baseKey: baseKey)
    }

    /// Build an arbitrary scoped cache key.
    /// Example output: `guild:123456:nvidia-gameready`.
    public static func buildScoped(scopeType: String, scopeID: String, baseKey: String) -> String {
        let typePart = normalizeComponent(scopeType)
        let idPart = sanitizeScopeID(scopeID)
        let keyPart = normalizeCacheKey(baseKey)
        return "\(typePart):\(idPart):\(keyPart)"
    }

    /// Normalize a prebuilt cache key.
    public static func normalizeCacheKey(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    private static func normalizeComponent(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private static func sanitizeScopeID(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "-")
    }
}
