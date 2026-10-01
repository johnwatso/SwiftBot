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

// MARK: - Rounds

/// `GET /v1/profiles/{username}/rounds` — one entry per round, newest first.
/// A match is one round, or several rounds sharing a `matchId` for ranked and
/// tournament modes; `matches` groups them.
struct FinalsIDLatestRoundResponse: Codable, Hashable, Sendable {
    let season: String?
    let count: Int
    let results: [FinalsIDRoundDetail]
    let nextCursor: String?

    var matches: [FinalsIDPlayedMatch] {
        FinalsIDPlayedMatch.group(results)
    }
}

/// A match built from its rounds. Not decoded: finals.id only lists rounds.
struct FinalsIDPlayedMatch: Hashable, Sendable {
    let matchID: String
    let gameMode: String?
    let startedAt: String?
    let rounds: [FinalsIDRoundDetail]

    var kills: Int { rounds.reduce(0) { $0 + ($1.kills ?? 0) } }
    var deaths: Int { rounds.reduce(0) { $0 + ($1.deaths ?? 0) } }
    var damage: Double { rounds.reduce(0) { $0 + ($1.damage ?? 0) } }

    /// finals.id labels rated play `gameMode: "Ranked"`.
    var isRanked: Bool {
        (gameMode ?? "").lowercased().contains("rank")
    }

    /// Multi-round modes are won by winning the tournament; single-round
    /// modes by winning the round.
    var isWin: Bool {
        rounds.count > 1
            ? rounds.contains { $0.tournamentWon == true }
            : rounds.contains { $0.roundWon == true }
    }

    static func group(_ rounds: [FinalsIDRoundDetail]) -> [FinalsIDPlayedMatch] {
        var order: [String] = []
        var byMatch: [String: [FinalsIDRoundDetail]] = [:]
        for round in rounds where round.isPrivate != true {
            if byMatch[round.matchID] == nil { order.append(round.matchID) }
            byMatch[round.matchID, default: []].append(round)
        }
        return order.compactMap { id in
            guard let rounds = byMatch[id] else { return nil }
            let sorted = rounds.sorted { ($0.startedAt ?? "") < ($1.startedAt ?? "") }
            return FinalsIDPlayedMatch(
                matchID: id,
                gameMode: sorted.compactMap(\.gameMode).first,
                startedAt: sorted.compactMap(\.startedAt).first,
                rounds: sorted
            )
        }
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
    /// Won the whole tournament (multi-round modes only).
    let tournamentWon: Bool?
    /// The player hid this round's details; only ids and timing are present.
    let isPrivate: Bool?

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
        case tournamentWon
        case isPrivate = "private"
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
