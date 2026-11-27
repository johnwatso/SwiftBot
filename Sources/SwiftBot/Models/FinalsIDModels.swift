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


// MARK: - Clubs

/// `GET /v1/clubs/{clubId}`: a club and its roster. A personal key can read
/// this for the key owner's own club even though other members' profiles
/// answer 403, so it is the fallback source of their SR.
struct FinalsIDClubRoster: Codable, Hashable, Sendable {
    let clubId: String?
    let name: String?
    let tag: String?
    let refreshedAt: String?
    let members: [FinalsIDClubMember]
}

struct FinalsIDClubMember: Codable, Hashable, Sendable {
    /// Always present; `username` is set when a profile is behind the slot.
    let displayName: String
    let username: String?
    /// Public id (`p-…`); absent for slots with no linked profile.
    let id: String?
    /// Canonical ranked score; nil when hidden or not on ranked.
    let score: Int?
    /// Dense canonical ranked place for that score.
    let rank: Int?

    /// Matches a tracked player's identifier (name#tag or `p-…` id),
    /// ignoring case.
    func matches(_ lowercasedIdentifier: String) -> Bool {
        [username, id, displayName]
            .compactMap { $0?.lowercased() }
            .contains(lowercasedIdentifier)
    }
}

// MARK: - Club sync

/// Works out how Game Tracker's player list changes to match the club roster.
/// Pure, so the rules can be tested without the network:
/// - roster members with a name#tag are added (leaderboard-mirror names only
///   when `includeLeaderboardMembers` is on; "Anonymous" slots never);
/// - players already tracked, whoever added them, are left alone;
/// - a player the sync added who is no longer on the roster is paused, and
///   resumed if they come back; players the operator added are never paused;
/// - names the operator deleted after a sync added them are not re-added.
enum GameClubSyncPlanner {
    struct Outcome: Equatable {
        var players: [GameTrackedPlayer]
        var sync: GameClubSyncSettings
        var added: [String] = []
        var paused: [String] = []
        var resumed: [String] = []

        var hasChanges: Bool { !added.isEmpty || !paused.isEmpty || !resumed.isEmpty }
    }

    static func identifier(for member: FinalsIDClubMember, includeLeaderboardMembers: Bool) -> String? {
        if let username = member.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            return username
        }
        guard includeLeaderboardMembers else { return nil }
        let name = member.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leaderboard names carry their #tag; "Anonymous" and other bare
        // placeholders can't be looked up.
        guard name.contains("#"), !name.hasPrefix("#") else { return nil }
        return name
    }

    static func plan(
        rosters: [FinalsIDClubRoster],
        players: [GameTrackedPlayer],
        sync: GameClubSyncSettings
    ) -> Outcome {
        var outcome = Outcome(players: players, sync: sync)
        // An empty answer is far more likely a glitch than everyone leaving.
        let members = rosters.flatMap(\.members)
        guard !members.isEmpty else { return outcome }

        var seen: Set<String> = []
        var present: Set<UUID> = []
        for member in members {
            guard let name = identifier(for: member, includeLeaderboardMembers: sync.includeLeaderboardMembers),
                  seen.insert(name.lowercased()).inserted else { continue }

            if let index = outcome.players.firstIndex(where: {
                $0.provider == .finalsID && member.matches($0.playerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }) {
                let id = outcome.players[index].id
                present.insert(id)
                if outcome.sync.departedPlayerIDs.contains(id) {
                    outcome.players[index].isEnabled = true
                    outcome.sync.departedPlayerIDs.removeAll { $0 == id }
                    outcome.resumed.append(outcome.players[index].resolvedDisplayName)
                }
                continue
            }
            guard !outcome.sync.excludedIdentifiers.contains(name.lowercased()) else { continue }

            var player = GameTrackedPlayer()
            player.game = .theFinals
            player.provider = .finalsID
            player.playerID = name
            player.destinationChannelID = sync.destinationChannelID
            player.isEnabled = true
            outcome.players.append(player)
            outcome.sync.syncedPlayerIDs.append(player.id)
            present.insert(player.id)
            outcome.added.append(name)
        }

        for id in outcome.sync.syncedPlayerIDs where !present.contains(id) {
            guard let index = outcome.players.firstIndex(where: { $0.id == id }),
                  outcome.players[index].isEnabled,
                  !outcome.sync.departedPlayerIDs.contains(id) else { continue }
            outcome.players[index].isEnabled = false
            outcome.sync.departedPlayerIDs.append(id)
            outcome.paused.append(outcome.players[index].resolvedDisplayName)
        }

        // Forget players that no longer exist.
        let existing = Set(outcome.players.map(\.id))
        outcome.sync.syncedPlayerIDs.removeAll { !existing.contains($0) }
        outcome.sync.departedPlayerIDs.removeAll { !existing.contains($0) }
        return outcome
    }
}

// MARK: - Play sessions

/// `GET /v1/profiles/{username}/sessions` — finals.id's own play sessions,
/// newest first, with totals it has already worked out (SR change included).
struct FinalsIDSessionsResponse: Codable, Hashable, Sendable {
    let results: [FinalsIDPlaySession]
    /// The open session; finals.id only sends it to the account's owner.
    let current: FinalsIDPlaySession?

    var allSessions: [FinalsIDPlaySession] {
        (current.map { [$0] } ?? []) + results
    }
}

struct FinalsIDPlaySession: Codable, Hashable, Sendable {
    let sessionId: String
    /// Still in progress on finals.id's side.
    let live: Bool?
    let startedAt: String?
    let endedAt: String?
    let matchCount: Int?
    let wins: Int?
    let losses: Int?
    /// Ranked score gained (+) or lost (−) across the session.
    let rsDelta: Int?
    let rankedMatches: Int?
    let kills: Int?
    let deaths: Int?
    let damage: Double?
    let items: [FinalsIDSessionItem]?
}

/// A weapon, gadget or specialization used in a session.
struct FinalsIDSessionItem: Codable, Hashable, Sendable {
    let displayName: String?
    let name: String?
    let kind: String?
    let kills: Double?
    let damage: Double?
}

// MARK: - Club analytics

/// `GET /v1/analytics/clubs/{clubId}?window=7d`: a club's totals over a
/// window. Numbers are decoded as Double so a provider switching an integer
/// to a float can't fail the whole recap.
struct FinalsIDClubAnalytics: Codable, Hashable, Sendable {
    struct Club: Codable, Hashable, Sendable {
        let clubID: String?
        let tag: String?
        let name: String?

        private enum CodingKeys: String, CodingKey {
            case clubID = "club_id", tag, name
        }
    }

    struct Standing: Codable, Hashable, Sendable {
        let rank: Double?
        let combinedRankedScore: Double?
        let rankedMembers: Double?

        private enum CodingKeys: String, CodingKey {
            case rank, combinedRankedScore = "combined_rs", rankedMembers = "ranked_members"
        }
    }

    struct Totals: Codable, Hashable, Sendable {
        let matches: Double?
        let wins: Double?
        let winRate: Double?
        let kills: Double?
        let deaths: Double?
        let kd: Double?
        let damage: Double?
        let revives: Double?

        private enum CodingKeys: String, CodingKey {
            case matches, wins, winRate = "win_rate", kills, deaths, kd, damage, revives
        }
    }

    struct QueueSplit: Codable, Hashable, Sendable {
        let totals: Totals?
    }

    struct ByQueue: Codable, Hashable, Sendable {
        let ranked: QueueSplit?
        let casual: QueueSplit?
    }

    struct Item: Codable, Hashable, Sendable {
        let displayName: String?
        let name: String?
        let kills: Double?
        let uses: Double?

        private enum CodingKeys: String, CodingKey {
            case displayName = "display_name", name, kills, uses
        }
    }

    struct TopItems: Codable, Hashable, Sendable {
        let weapon: [Item]?
    }

    let club: Club?
    let standing: Standing?
    let totals: Totals?
    let byQueue: ByQueue?
    let topItems: TopItems?

    private enum CodingKeys: String, CodingKey {
        case club, standing, totals, byQueue = "by_queue", topItems = "top_items"
    }
}
