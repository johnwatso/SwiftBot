import Foundation

// MARK: - Driver Update Source

/// Wrapper that makes driver info conform to UpdateSource protocol
struct DriverUpdateSource: UpdateSource {
    let vendor: String
    let channel: String
    let version: String
    let releaseNotes: ReleaseNotes
    let embedJSON: String
    let rawDebug: String
    
    var cacheKey: String {
        CacheKeyBuilder.build(vendor: vendor, channel: channel)
    }
    
    // MARK: - Factory Methods
    
    static func nvidia(_ driverInfo: NVIDIAService.DriverInfo) -> DriverUpdateSource {
        DriverUpdateSource(
            vendor: "NVIDIA",
            channel: "gameReady",
            version: driverInfo.releaseNotes.version,
            releaseNotes: driverInfo.releaseNotes,
            embedJSON: driverInfo.embedJSON,
            rawDebug: driverInfo.rawDebug
        )
    }
    
    static func amd(_ driverInfo: AMDService.DriverInfo) -> DriverUpdateSource {
        DriverUpdateSource(
            vendor: "AMD",
            channel: "default",
            version: driverInfo.releaseNotes.version,
            releaseNotes: driverInfo.releaseNotes,
            embedJSON: driverInfo.embedJSON,
            rawDebug: driverInfo.rawDebug
        )
    }
    
    static func intel(_ driverInfo: NVIDIAService.DriverInfo) -> DriverUpdateSource {
        DriverUpdateSource(
            vendor: "Intel",
            channel: "default",
            version: driverInfo.releaseNotes.version,
            releaseNotes: driverInfo.releaseNotes,
            embedJSON: driverInfo.embedJSON,
            rawDebug: driverInfo.rawDebug
        )
    }
}
