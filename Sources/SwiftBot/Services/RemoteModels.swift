import Foundation

enum AppLaunchMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case standaloneBot
    case swiftMeshClusterNode
    case remoteControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standaloneBot:
            return "Standalone Bot"
        case .swiftMeshClusterNode:
            return "SwiftMesh Cluster Node"
        case .remoteControl:
            return "Remote Control Mode"
        }
    }

    var subtitle: String {
        switch self {
        case .standaloneBot:
            return "Run Discord, rules, and actions on this Mac."
        case .swiftMeshClusterNode:
            return "Join SwiftMesh as a primary or failover node."
        case .remoteControl:
            return "Manage a primary node over HTTPS without running the bot locally."
        }
    }

    var symbolName: String {
        switch self {
        case .standaloneBot:
            return "server.rack"
        case .swiftMeshClusterNode:
            return "point.3.connected.trianglepath.dotted"
        case .remoteControl:
            return "dot.radiowaves.left.and.right"
        }
    }
}

struct RemoteModeSettings: Codable, Hashable {
    var primaryNodeAddress: String = ""
    var accessToken: String = ""

    var normalizedPrimaryNodeAddress: String {
        Self.normalizeBaseURL(primaryNodeAddress)
    }

    var normalizedAccessToken: String {
        accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        !normalizedPrimaryNodeAddress.isEmpty && !normalizedAccessToken.isEmpty
    }

    mutating func normalize() {
        primaryNodeAddress = normalizedPrimaryNodeAddress
        accessToken = normalizedAccessToken
    }

    static func normalizeBaseURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme,
              let host = components.host,
              !scheme.isEmpty,
              !host.isEmpty else {
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        components.scheme = scheme.lowercased()
        components.host = host.lowercased()
        components.path = ""
        components.query = nil
        components.fragment = nil

        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? trimmed
    }
}

enum RemoteConnectionState: String, Equatable {
    case disconnected
    case connecting
    case connected
    case failed
}

struct RemoteStatusPayload: Codable {
    let botStatus: String
    let botUsername: String
    let connectedServerCount: Int
    let gatewayEventCount: Int
    let uptimeText: String?
    let webUIBaseURL: String
    let clusterMode: String
    let nodeRole: String
    let leaderName: String
    let generatedAt: Date
}

struct RemoteRulesPayload: Codable {
    let rules: [Rule]
    let servers: [AdminWebSimpleOption]
    let textChannelsByServer: [String: [AdminWebSimpleOption]]
    let voiceChannelsByServer: [String: [AdminWebSimpleOption]]
    let fetchedAt: Date
}

struct RemoteRuleUpsertRequest: Codable {
    let rule: Rule
}

struct RemoteActivityEventPayload: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let kind: String
    let message: String
}

struct RemoteEventsPayload: Codable {
    let activity: [RemoteActivityEventPayload]
    let logs: [String]
    let fetchedAt: Date
}

struct RemoteOKResponse: Codable {
    let ok: Bool
}
