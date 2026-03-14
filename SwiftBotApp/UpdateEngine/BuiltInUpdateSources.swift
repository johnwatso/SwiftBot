import Foundation

/// NVIDIA Game Ready update source.
public struct NVIDIAUpdateSource: UpdateSource, Sendable {
    public let sourceKey: String
    private let service: NVIDIAService

    public init(
        sourceKey: String = CacheKeyBuilder.build(vendor: "NVIDIA", channel: "gameReady"),
        service: NVIDIAService = NVIDIAService()
    ) {
        self.sourceKey = sourceKey
        self.service = service
    }

    public func fetchLatest() async throws -> any UpdateItem {
        let info = try await service.fetchLatestDriver()
        return DriverUpdateItem(
            sourceKey: sourceKey,
            identifier: info.releaseIdentifier,
            version: info.releaseNotes.version,
            releaseNotes: info.releaseNotes,
            embedJSON: info.embedJSON,
            rawDebug: info.rawDebug
        )
    }
}

/// AMD Radeon update source.
public struct AMDUpdateSource: UpdateSource, Sendable {
    public let sourceKey: String
    private let service: AMDService

    public init(
        sourceKey: String = CacheKeyBuilder.build(vendor: "AMD", channel: "default"),
        service: AMDService = AMDService()
    ) {
        self.sourceKey = sourceKey
        self.service = service
    }

    public func fetchLatest() async throws -> any UpdateItem {
        let info = try await service.fetchLatestDriver()
        return DriverUpdateItem(
            sourceKey: sourceKey,
            identifier: info.releaseIdentifier,
            version: info.releaseNotes.version,
            releaseNotes: info.releaseNotes,
            embedJSON: info.embedJSON,
            rawDebug: info.rawDebug
        )
    }
}

/// Intel Arc driver update source.
public struct IntelUpdateSource: UpdateSource, Sendable {
    public let sourceKey: String
    private let service: IntelService

    public init(
        sourceKey: String = CacheKeyBuilder.build(vendor: "Intel", channel: "default"),
        service: IntelService = IntelService()
    ) {
        self.sourceKey = sourceKey
        self.service = service
    }

    public func fetchLatest() async throws -> any UpdateItem {
        let info = try await service.fetchLatestDriver()
        return DriverUpdateItem(
            sourceKey: sourceKey,
            identifier: info.releaseIdentifier,
            version: info.releaseNotes.version,
            releaseNotes: info.releaseNotes,
            embedJSON: info.embedJSON,
            rawDebug: info.rawDebug
        )
    }
}

/// Steam news update source for a specific app.
public struct SteamNewsUpdateSource: UpdateSource, Sendable {
    public let appID: String
    public let sourceKey: String
    private let service: SteamService

    public init(appID: String, service: SteamService = SteamService()) {
        self.appID = appID
        self.sourceKey = CacheKeyBuilder.build(vendor: "steam", channel: appID)
        self.service = service
    }

    public func fetchLatest() async throws -> any UpdateItem {
        let info = try await service.fetchLatestNews(for: appID)
        return SteamUpdateItem(
            sourceKey: sourceKey,
            identifier: info.releaseIdentifier,
            version: info.newsItem.dateFormatted,
            newsItem: info.newsItem,
            embedJSON: info.embedJSON,
            rawDebug: info.rawDebug
        )
    }
}
