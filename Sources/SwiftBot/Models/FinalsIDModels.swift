import Foundation

// finals.id-specific models. The provider-neutral Game Tracker types live in
// `GameTrackingModels.swift`.

// MARK: - Legacy settings migration

/// The pre-multi-provider shape of finals.id settings. Retained purely so an
/// existing settings.json migrates into `GameProviderConnections` on first load;
/// nothing writes this type any more.
struct LegacyFinalsIDSettings: Codable, Hashable, Sendable {
    var apiBaseURL: String = ""
    var apiToken: String = ""
    var rankEndpointTemplate: String = ""

    var migratedConnection: GameProviderConnectionSettings {
        GameProviderConnectionSettings(
            baseURL: apiBaseURL,
            token: apiToken,
            rankEndpointTemplate: rankEndpointTemplate
        )
    }
}

// MARK: - Proposed latest-round contract

/// Models the "Latest Played Round Result" proposal shared by finals.id.
/// Fields not needed for the first SR notifier remain optional so additions to
/// the upstream payload do not make SwiftBot's decoder brittle.
struct FinalsIDLatestRoundResponse: Codable, Hashable, Sendable {
    let season: String
    let count: Int
    let results: [FinalsIDPlayedRound]
    let nextCursor: String?
}

struct FinalsIDPlayedRound: Codable, Hashable, Sendable {
    let matchID: String
    /// Queue type — `casual`, and presumably `ranked` for rated play. This is
    /// how a session summary tells rated matches from unrated ones.
    let mode: String?
    let gameMode: String
    let startedAt: String
    let endedAt: String
    let roundCount: Int
    let kills: Int
    let deaths: Int
    let damage: Double
    let scorecard: FinalsIDScorecard?

    // Collections are decoded optionally and surfaced non-optional: a mode that
    // omits one of them should not fail the whole payload.
    private let roundsRaw: [FinalsIDRoundDetail]?
    private let itemsRaw: [FinalsIDRoundItem]?
    private let rosterRaw: [FinalsIDRosterMember]?

    var rounds: [FinalsIDRoundDetail] { roundsRaw ?? [] }
    var items: [FinalsIDRoundItem] { itemsRaw ?? [] }
    var roster: [FinalsIDRosterMember] { rosterRaw ?? [] }

    /// True when this match was played in a rated queue.
    var isRanked: Bool {
        (mode ?? "").lowercased().contains("rank")
    }

    private enum CodingKeys: String, CodingKey {
        case matchID = "matchId"
        case mode
        case gameMode
        case startedAt
        case endedAt
        case roundCount
        case kills
        case deaths
        case damage
        case scorecard
        case roundsRaw = "rounds"
        case itemsRaw = "items"
        case rosterRaw = "roster"
    }
}

struct FinalsIDRoundDetail: Codable, Hashable, Sendable {
    let roundID: String
    let matchID: String
    let map: String?
    private let twistsRaw: [FinalsIDNamedSlug]?
    var twists: [FinalsIDNamedSlug] { twistsRaw ?? [] }
    let gameMode: String?
    let startedAt: String?
    let endedAt: String?
    let squadName: String?
    let placedAt: Int?
    let kills: Int?
    let deaths: Int?
    let dbnos: Int?
    let damage: Double?
    let respawns: Int?
    let respawnsDone: Int?
    let revivesDone: Int?
    let roundWon: Bool?

    private let partyMembersRaw: FinalsIDPartyMemberList?
    var partyMembers: [FinalsIDPartyMember] { partyMembersRaw?.entries ?? [] }

    private enum CodingKeys: String, CodingKey {
        case roundID = "roundId"
        case matchID = "matchId"
        case map
        case twistsRaw = "twists"
        case gameMode
        case startedAt
        case endedAt
        case squadName
        case placedAt
        case kills
        case deaths
        case dbnos
        case damage
        case respawns
        case respawnsDone
        case revivesDone
        case roundWon
        case partyMembersRaw = "partyMembers"
    }
}

struct FinalsIDNamedSlug: Codable, Hashable, Sendable {
    let name: String
    let slug: String
}

/// `partyMembers` has been seen both as a single object and as an array of
/// them, so accept either rather than failing the whole round on shape drift.
struct FinalsIDPartyMemberList: Codable, Hashable, Sendable {
    let entries: [FinalsIDPartyMember]

    init(entries: [FinalsIDPartyMember]) {
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let many = try? container.decode([FinalsIDPartyMember].self) {
            entries = many
        } else if let single = try? container.decode(FinalsIDPartyMember.self) {
            entries = [single]
        } else {
            entries = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}

struct FinalsIDPartyMember: Codable, Hashable, Sendable {
    let leader: String?
    private let membersRaw: [FinalsIDRosterMember]?
    var members: [FinalsIDRosterMember] { membersRaw ?? [] }

    private enum CodingKeys: String, CodingKey {
        case leader
        case membersRaw = "members"
    }
}

struct FinalsIDRosterMember: Codable, Hashable, Sendable {
    let name: String
}

struct FinalsIDRoundItem: Codable, Hashable, Sendable {
    let id: String?
    let kind: String?
    let name: String?
    let slug: String?
    let xp: Int?
    let kills: Int?
    let damage: Double?
}

struct FinalsIDScorecard: Codable, Hashable, Sendable {
    let assists: Int?
    let combatScore: Double?
    let eliminationStreak: Int?
    let eliminations: Int?
    let killDeathRatio: Double?
    let support: Double?

    private enum CodingKeys: String, CodingKey {
        case assists
        case combatScore = "combat-score"
        case eliminationStreak = "elimination-streak"
        case eliminations
        case killDeathRatio = "kill-death-ratio"
        case support
    }
}
