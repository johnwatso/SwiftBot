import Foundation

/// Problems (and role changes) SwiftBot can DM a Mac's operator about.
enum OperatorAlertKind: String, Codable, CaseIterable, Sendable {
    case discordDisconnected
    case nodeOffline
    case recordingsUnreachable
    case errorBurst
    case roleChanges

    var title: String {
        switch self {
        case .discordDisconnected: return "Discord disconnected"
        case .nodeOffline: return "Mac went offline"
        case .recordingsUnreachable: return "Recordings folder unreachable"
        case .errorBurst: return "Errors piling up"
        case .roleChanges: return "Role changes"
        }
    }
}

/// Who runs each Mac, and which alerts they get. Keyed by SwiftMesh node
/// name, so it syncs with the rest of the settings and every node knows
/// every other node's operator.
struct OperatorSettings: Codable, Hashable, Sendable {
    /// Node name → Discord user ID.
    var operatorsByNode: [String: String] = [:]
    var enabledAlerts: Set<OperatorAlertKind> = Set(OperatorAlertKind.allCases)

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operatorsByNode = try c.decodeIfPresent([String: String].self, forKey: .operatorsByNode) ?? [:]
        // Unknown alert names from a newer build are dropped, not fatal.
        let raw = try c.decodeIfPresent([String].self, forKey: .enabledAlerts)
        enabledAlerts = raw.map { Set($0.compactMap(OperatorAlertKind.init(rawValue:))) } ?? Set(OperatorAlertKind.allCases)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operatorsByNode, forKey: .operatorsByNode)
        try c.encode(enabledAlerts.map(\.rawValue).sorted(), forKey: .enabledAlerts)
    }

    private enum CodingKeys: String, CodingKey {
        case operatorsByNode, enabledAlerts
    }
}
