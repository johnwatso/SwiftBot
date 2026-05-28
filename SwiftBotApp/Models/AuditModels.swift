import Foundation

// MARK: - Audit feature models
//
// The Audit feature surfaces role/permission findings for a Discord server and
// uses the server's audit log as *supporting evidence* for those findings —
// never as the primary content. These models are deliberately distinct from the
// existing `AuditLogEntry` (which is SwiftBot's own admin/moderation log shown
// in the Activity view) and from the minimal `GuildRole` used elsewhere.
//
// Everything here is `Sendable` so a `ServerSnapshot` can cross into the
// `AuditAnalyzer` actor without data races.

/// An enriched snapshot of a Discord role. Richer than `GuildRole` because the
/// analyzer needs colour, position, hierarchy and flags to reason about roles.
struct AuditRole: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let name: String
    /// Packed 0xRRGGBB. 0 means "no colour" (Discord's default).
    let colorRGB: Int
    /// Higher = higher in the role list. `@everyone` is 0.
    let position: Int
    /// Parsed permission bitfield. Raw value retained so the inspector can
    /// expand the individual bits on demand.
    let permissions: UInt64
    let hoist: Bool
    let mentionable: Bool
    /// True for bot/integration/booster roles Discord manages automatically.
    let managed: Bool
    /// Resolved member count. `nil` when it hasn't (or can't) be resolved —
    /// "unused" detection treats that as low confidence rather than asserting.
    var memberCount: Int?

    var hasAdministrator: Bool {
        permissions & DiscordPermissionCatalog.administrator != 0
    }
}

// MARK: - Discord audit log

/// The subset of Discord audit-log action types the Audit feature ingests.
/// Raw values are Discord's numeric action-type codes.
enum AuditActionType: Int, Sendable, Codable {
    case roleCreate = 30
    case roleUpdate = 31
    case roleDelete = 32
    case memberRoleUpdate = 25
    case other = -1

    init(rawCode: Int) {
        self = AuditActionType(rawValue: rawCode) ?? .other
    }

    /// Action types worth fetching for role-centric analysis.
    static let roleRelevant: [AuditActionType] = [.roleCreate, .roleUpdate, .roleDelete, .memberRoleUpdate]
}

/// One field-level change recorded inside an audit-log entry.
struct AuditChange: Hashable, Sendable, Codable {
    let key: String
    let oldValue: String?
    let newValue: String?
}

/// A single decoded Discord audit-log event. Supporting evidence for a finding.
struct DiscordAuditEvent: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let actionType: AuditActionType
    let actorID: String?
    let actorName: String?
    let targetID: String?
    let createdAt: Date
    let changes: [AuditChange]
    let reason: String?
}

// MARK: - Snapshot

/// Immutable input to the analyzer. `Sendable` so it crosses the actor boundary.
struct ServerSnapshot: Sendable {
    let guildID: String
    let guildName: String
    let capturedAt: Date
    /// Highest role position the bot itself holds — used to gate whether a
    /// future action (merge/revert) would even be permitted. Stored now so the
    /// model is ready for Phase 3.
    let botHighestPosition: Int
    let roles: [AuditRole]
    let recentEvents: [DiscordAuditEvent]
}

// MARK: - Findings

enum Severity: Int, Comparable, Sendable, Codable {
    case info
    case notice
    case warning
    case critical

    static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum FindingCategory: String, Sendable, Codable, CaseIterable {
    case permissionRisk
    case duplicateRoles
    case unusedRole
    case hierarchyIssue
    case configDrift
    case recentChange

    var title: String {
        switch self {
        case .permissionRisk: return "Permission Risks"
        case .duplicateRoles: return "Duplicate Roles"
        case .unusedRole: return "Unused Roles"
        case .hierarchyIssue: return "Hierarchy Issues"
        case .configDrift: return "Configuration Drift"
        case .recentChange: return "Recent Changes"
        }
    }

    var symbol: String {
        switch self {
        case .permissionRisk: return "bolt.shield"
        case .duplicateRoles: return "square.on.square"
        case .unusedRole: return "person.crop.circle.badge.questionmark"
        case .hierarchyIssue: return "arrow.up.arrow.down.square"
        case .configDrift: return "arrow.triangle.swap"
        case .recentChange: return "clock.arrow.circlepath"
        }
    }
}

/// Actions a finding can offer. MVP only acts on `.review` and `.ignore`;
/// the mutating actions are declared so the UI and model are forward-ready.
enum FindingAction: String, Sendable, Codable, Hashable {
    case review
    case compare
    case merge
    case revert
    case ignore
    case archive

    var title: String {
        switch self {
        case .review: return "Review"
        case .compare: return "Compare"
        case .merge: return "Merge"
        case .revert: return "Revert"
        case .ignore: return "Ignore"
        case .archive: return "Archive"
        }
    }

    var symbol: String {
        switch self {
        case .review: return "sidebar.right"
        case .compare: return "rectangle.split.2x1"
        case .merge: return "arrow.triangle.merge"
        case .revert: return "arrow.uturn.backward"
        case .ignore: return "eye.slash"
        case .archive: return "archivebox"
        }
    }
}

/// Category-specific payload that drives the inspector body.
enum FindingDetail: Sendable, Hashable {
    case duplicate(primary: AuditRole, others: [AuditRole])
    case permissionRisk(role: AuditRole, flaggedBits: [UInt64])
    case generic
}

/// The unit of the Audit feed.
struct Finding: Identifiable, Hashable, Sendable {
    /// Stable content fingerprint (see AuditAnalyzer). NOT a UUID — this is what
    /// lets a dismissal survive a re-scan without freezing the finding's body.
    let id: String
    let category: FindingCategory
    let severity: Severity
    let title: String
    let summary: String
    let subjectRoleIDs: [String]
    var evidence: [DiscordAuditEvent]
    let actions: [FindingAction]
    let detail: FindingDetail
}
