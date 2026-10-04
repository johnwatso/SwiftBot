import Foundation

/// How one part of SwiftBot is doing, as the console Overview shows it.
/// Platform-neutral; colors live in the view layer.
enum ServiceHealth: Int, Comparable, Sendable {
    /// Turned off on purpose. Not a problem.
    case disabled = 0
    /// Can't run right now because something it depends on is off or stopped
    /// (the tunnel while the Web Interface is off, Discord while the bot is stopped).
    case unavailable
    /// On its way up: connecting, enabling. Transient, so shown neutrally.
    case pending
    /// Up and doing its job.
    case healthy
    /// Running but not right, or needs setup: reconnecting, degraded, no token.
    case warning
    /// Tried to run and couldn't.
    case error

    /// Only warnings and errors pull the person's eye; off and starting don't.
    var needsAttention: Bool {
        self == .warning || self == .error
    }

    static func < (lhs: ServiceHealth, rhs: ServiceHealth) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The four services the Overview reports on. The order here is the order on screen.
enum ConsoleServiceKind: String, CaseIterable, Identifiable, Sendable {
    case discord
    case webInterface
    case swiftMesh
    case cloudflareTunnel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discord: return "Discord"
        case .webInterface: return "Web Interface"
        case .swiftMesh: return "SwiftMesh"
        case .cloudflareTunnel: return "Cloudflare Tunnel"
        }
    }

    /// The service's official logo in the asset catalog, used in place of
    /// `symbol` where one exists. Third-party marks belong to their owners and
    /// are shown only to identify the service.
    var brandAsset: String? {
        switch self {
        case .discord: return "DiscordLogo"
        case .cloudflareTunnel: return "CloudflareLogo"
        case .webInterface, .swiftMesh: return nil
        }
    }

    var symbol: String {
        switch self {
        case .discord: return "bubble.left.and.bubble.right.fill"
        case .webInterface: return "globe"
        case .swiftMesh: return "point.3.connected.trianglepath.dotted"
        case .cloudflareTunnel: return "cloud.fill"
        }
    }
}

/// One service's state: "Discord · Connected · As SwiftBot - Dev · 1 server".
struct ConsoleServiceStatus: Identifiable, Equatable, Sendable {
    let kind: ConsoleServiceKind
    let health: ServiceHealth
    /// Short state word shown beside the status dot ("Connected", "Disabled").
    let summary: String
    /// One line of context under it (an address, peer count, or what to check).
    let detail: String

    var id: ConsoleServiceKind { kind }
}

/// The summary card's headline: is SwiftBot itself up, and if not, why.
struct HostStatus: Equatable, Sendable {
    let health: ServiceHealth
    /// Badge text: "Running", "Needs Attention", "Stopped".
    let badge: String
    /// Subtitle under the page title.
    let headline: String
    /// When the bot last connected; drives the live uptime readout.
    let startedAt: Date?
    /// Services that need attention, worst first. Empty when all is well.
    let issues: [ConsoleServiceStatus]
}

/// Static facts about this Mac and this copy of SwiftBot. None of it changes
/// while the app runs, so it's read once.
struct HostDetails: Equatable, Sendable {
    let computerName: String
    let hardware: String
    let operatingSystem: String
    let appVersion: String
    let buildNumber: String
    /// "Release", "Beta" or "Development".
    let buildChannel: String
    let dataLocation: URL

    var versionWithBuild: String {
        buildNumber.isEmpty ? appVersion : "\(appVersion) (\(buildNumber))"
    }
}
