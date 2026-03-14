import Foundation

/// Represents a single fetched update entry from an upstream source.
public protocol UpdateItem: Sendable {
    /// Stable source key used as the base cache partition.
    var sourceKey: String { get }

    /// Stable identifier for the specific update item.
    /// This should not be a display version unless no better identifier exists.
    var identifier: String { get }

    /// Human-readable version shown to users.
    var version: String { get }
}

/// Generic update item for simple sources.
public struct BasicUpdateItem: UpdateItem, Sendable, Codable, Hashable {
    public let sourceKey: String
    public let identifier: String
    public let version: String

    public init(sourceKey: String, identifier: String, version: String) {
        self.sourceKey = sourceKey
        self.identifier = identifier
        self.version = version
    }
}

/// Rich update item used by driver vendors.
public struct DriverUpdateItem: UpdateItem, Sendable {
    public let sourceKey: String
    public let identifier: String
    public let version: String
    public let releaseNotes: ReleaseNotes
    public let embedJSON: String
    public let rawDebug: String

    public init(
        sourceKey: String,
        identifier: String,
        version: String,
        releaseNotes: ReleaseNotes,
        embedJSON: String,
        rawDebug: String
    ) {
        self.sourceKey = sourceKey
        self.identifier = identifier
        self.version = version
        self.releaseNotes = releaseNotes
        self.embedJSON = embedJSON
        self.rawDebug = rawDebug
    }
}

/// Rich update item used by Steam news sources.
public struct SteamUpdateItem: UpdateItem, Sendable {
    public let sourceKey: String
    public let identifier: String
    public let version: String
    public let newsItem: SteamNewsItem
    public let embedJSON: String
    public let rawDebug: String

    public init(
        sourceKey: String,
        identifier: String,
        version: String,
        newsItem: SteamNewsItem,
        embedJSON: String,
        rawDebug: String
    ) {
        self.sourceKey = sourceKey
        self.identifier = identifier
        self.version = version
        self.newsItem = newsItem
        self.embedJSON = embedJSON
        self.rawDebug = rawDebug
    }
}
