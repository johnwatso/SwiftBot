import Foundation

// Provider-neutral Game Tracker model layer. Anything specific to one provider
// (finals.id today) lives in that provider's own file; this file must stay free
// of provider-specific types so a second provider is additive.

enum GameID: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case theFinals

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .theFinals: return "THE FINALS"
        }
    }

    var symbolName: String {
        switch self {
        case .theFinals: return "scope"
        }
    }

    /// Unit label for this game's ranked score. Game-specific rather than
    /// provider-specific — THE FINALS reports SR, other titles use RR/MMR — so
    /// announcement copy stays correct when a second game is added.
    var scoreUnit: String {
        switch self {
        case .theFinals: return "SR"
        }
    }
}

enum GameProviderID: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case finalsID

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .finalsID: return "finals.id"
        }
    }

    var supportedGames: Set<GameID> {
        switch self {
        case .finalsID: return [.theFinals]
        }
    }
}

enum GameTrackingCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case rankedScore
    case rankTier
    case latestSession
    case matchHistory
}

/// How a provider expects its credential to be presented. Kept on the provider
/// descriptor rather than in user settings because it is a property of the API,
/// not a choice the operator makes. Adding a case is additive — existing stored
/// connections keep decoding unchanged.
enum GameProviderAuth: Hashable, Sendable {
    /// `Authorization: Bearer <token>` — finals.id.
    case bearer
    /// A custom request header, e.g. tracker.gg's `TRN-Api-Key`.
    case header(name: String)
    /// A query-string parameter, e.g. Steam's `key=`.
    case query(name: String)

    /// Label for the credential field in Integrations.
    var credentialLabel: String {
        switch self {
        case .bearer: return "API Token"
        case .header: return "API Key"
        case .query: return "API Key"
        }
    }

    var summary: String {
        switch self {
        case .bearer: return "Sent as an Authorization: Bearer header."
        case .header(let name): return "Sent as the \(name) request header."
        case .query(let name): return "Sent as the \(name) query parameter."
        }
    }
}

struct GameProviderDescriptor: Hashable, Sendable {
    let id: GameProviderID
    let supportedGames: Set<GameID>
    let capabilities: Set<GameTrackingCapability>
    let auth: GameProviderAuth
    let defaultBaseURL: String

    /// Only providers that can report a ranked score need an endpoint template.
    /// A presence-only game such as Call of Duty has no rank API to point at.
    var requiresRankEndpointTemplate: Bool {
        capabilities.contains(.rankedScore)
    }
}

/// Single source of truth for what each provider can do. The provider clients
/// and every readiness/UI surface read from here so adding a provider is one
/// entry rather than a scattered set of switches.
enum GameProviderCatalog {
    static let descriptors: [GameProviderID: GameProviderDescriptor] = [
        .finalsID: GameProviderDescriptor(
            id: .finalsID,
            supportedGames: [.theFinals],
            capabilities: [.rankedScore, .rankTier, .latestSession, .matchHistory],
            auth: .bearer,
            defaultBaseURL: "https://api.finals.id"
        )
    ]

    static func descriptor(for id: GameProviderID) -> GameProviderDescriptor? {
        descriptors[id]
    }

    static func supports(_ capability: GameTrackingCapability, provider: GameProviderID) -> Bool {
        descriptors[provider]?.capabilities.contains(capability) ?? false
    }
}

/// Resolved, ready-to-use connection handed to a provider client at request time.
struct GameProviderConnection: Hashable, Sendable {
    let baseURL: String
    let token: String
    let auth: GameProviderAuth
    let rankEndpointTemplate: String

    /// Applies the provider's credential to a request in whichever way that
    /// provider expects, so client code never re-implements auth per provider.
    func authorize(_ request: inout URLRequest) {
        switch auth {
        case .bearer:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .header(let name):
            request.setValue(token, forHTTPHeaderField: name)
        case .query(let name):
            guard let url = request.url,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: name, value: token))
            components.queryItems = items
            request.url = components.url ?? url
        }
    }
}

/// Operator-supplied connection details for one provider. Stored per provider so
/// adding a provider is a new dictionary entry rather than a new settings field.
struct GameProviderConnectionSettings: Codable, Hashable, Sendable {
    var baseURL: String = ""
    /// Kept in the macOS Keychain by `ConfigStore`; never written to settings.json.
    var token: String = ""
    /// `{playerID}` is replaced with a percent-encoded player identifier at
    /// request time. Unused by providers that do not advertise `.rankedScore`.
    var rankEndpointTemplate: String = ""

    func resolvedBaseURL(for descriptor: GameProviderDescriptor) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? descriptor.defaultBaseURL : trimmed
    }

    func connection(for descriptor: GameProviderDescriptor) -> GameProviderConnection {
        GameProviderConnection(
            baseURL: resolvedBaseURL(for: descriptor),
            token: token,
            auth: descriptor.auth,
            rankEndpointTemplate: rankEndpointTemplate
        )
    }

    /// `nil` when this connection is usable for the given provider.
    func configurationIssue(for descriptor: GameProviderDescriptor) -> String? {
        let resolved = resolvedBaseURL(for: descriptor)
        guard let url = URL(string: resolved),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return "\(descriptor.id.displayName): API base URL is invalid."
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(descriptor.id.displayName): \(descriptor.auth.credentialLabel) is required."
        }
        if descriptor.requiresRankEndpointTemplate,
           !rankEndpointTemplate.contains("{playerID}") {
            return "\(descriptor.id.displayName): the rank endpoint contract has not been configured yet."
        }
        return nil
    }

    mutating func normalize() {
        baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        rankEndpointTemplate = rankEndpointTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Provider connections keyed by provider id. Backed by raw-value string keys so
/// the on-disk shape stays a plain JSON object and unknown providers written by a
/// newer build round-trip instead of being dropped.
struct GameProviderConnections: Codable, Hashable, Sendable {
    private var storage: [String: GameProviderConnectionSettings]

    init(_ storage: [String: GameProviderConnectionSettings] = [:]) {
        self.storage = storage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        storage = (try? container.decode([String: GameProviderConnectionSettings].self)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }

    subscript(id: GameProviderID) -> GameProviderConnectionSettings {
        get { storage[id.rawValue] ?? GameProviderConnectionSettings() }
        set { storage[id.rawValue] = newValue }
    }

    var configuredProviderIDs: [GameProviderID] {
        storage.keys.compactMap(GameProviderID.init(rawValue:)).sorted { $0.rawValue < $1.rawValue }
    }

    mutating func normalize() {
        for key in storage.keys {
            storage[key]?.normalize()
        }
    }

    /// Blanks every credential before the settings file is written to disk.
    mutating func clearTokens() {
        for key in storage.keys {
            storage[key]?.token = ""
        }
    }

    func token(for id: GameProviderID) -> String { self[id].token }

    mutating func setToken(_ token: String, for id: GameProviderID) {
        var entry = self[id]
        entry.token = token
        self[id] = entry
    }
}

protocol GameRankProvider: Sendable {
    var descriptor: GameProviderDescriptor { get }

    func fetchRankSnapshot(
        for target: GameTrackedPlayer,
        connection: GameProviderConnection
    ) async throws -> GameRankSnapshot
}

struct GameTrackedPlayer: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var game: GameID = .theFinals
    var provider: GameProviderID = .finalsID
    var playerID: String = ""
    var displayName: String = ""
    var destinationChannelID: String = ""
    var isEnabled: Bool = true
    /// Discord user whose rich presence marks this profile's play sessions.
    /// Optional: a profile can still be polled on a schedule without it.
    var discordUserID: String = ""

    var resolvedDisplayName: String {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? playerID.trimmingCharacters(in: .whitespacesAndNewlines) : trimmedName
    }

    mutating func normalize() {
        playerID = playerID.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        destinationChannelID = destinationChannelID.trimmingCharacters(in: .whitespacesAndNewlines)
        discordUserID = discordUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !provider.supportedGames.contains(game) {
            provider = GameProviderID.allCases.first(where: { $0.supportedGames.contains(game) }) ?? .finalsID
        }
    }
}

struct GameTrackingSettings: Codable, Hashable, Sendable {
    var enabled = false
    var checkHour = 9
    var checkMinute = 0
    var timeZoneIdentifier = TimeZone.current.identifier
    var players: [GameTrackedPlayer] = []

    /// Announce play sessions detected from Discord rich presence, in addition
    /// to (or instead of) the daily scheduled poll.
    var sessionTrackingEnabled = false
    /// Seconds a game activity must stay absent before the session is closed.
    var sessionAbsenceGraceSeconds = 180
    /// Sessions shorter than this are never announced.
    var sessionMinimumDurationSeconds = 300
    /// Delay after a session ends before querying the provider, giving the game
    /// backend time to publish the final match.
    var sessionSettleDelaySeconds = 120

    var sessionTrackerConfiguration: GameSessionTrackerConfiguration {
        GameSessionTrackerConfiguration(
            absenceGrace: TimeInterval(max(0, sessionAbsenceGraceSeconds)),
            minimumSessionDuration: TimeInterval(max(0, sessionMinimumDurationSeconds))
        )
    }

    /// Profiles that have a Discord user linked for presence detection.
    var presenceLinkedPlayers: [GameTrackedPlayer] {
        players.filter { $0.isEnabled && !$0.discordUserID.isEmpty }
    }

    func player(forDiscordUserID userID: String) -> GameTrackedPlayer? {
        presenceLinkedPlayers.first { $0.discordUserID == userID }
    }

    var enabledPlayers: [GameTrackedPlayer] {
        players.filter {
            $0.isEnabled
                && !$0.playerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.destinationChannelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Providers referenced by at least one enabled profile.
    func activeProviderIDs() -> [GameProviderID] {
        var seen: Set<GameProviderID> = []
        return players.filter(\.isEnabled).compactMap { seen.insert($0.provider).inserted ? $0.provider : nil }
    }

    func configurationIssue(connections: GameProviderConnections) -> String? {
        guard enabled else { return "Game Tracker is disabled." }
        let selectedPlayers = players.filter(\.isEnabled)
        guard !selectedPlayers.isEmpty else { return "Add or enable at least one player profile." }
        guard !selectedPlayers.contains(where: {
            $0.playerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return "Every enabled profile needs a provider player ID."
        }
        guard !selectedPlayers.contains(where: {
            $0.destinationChannelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return "Every enabled profile needs a Discord destination channel."
        }
        for providerID in activeProviderIDs() {
            guard let descriptor = GameProviderCatalog.descriptor(for: providerID) else {
                return "\(providerID.displayName) is not a supported provider in this build."
            }
            if let issue = connections[providerID].configurationIssue(for: descriptor) {
                return issue
            }
        }
        return nil
    }

    func isReady(connections: GameProviderConnections) -> Bool {
        enabled && configurationIssue(connections: connections) == nil
    }

    mutating func normalize() {
        checkHour = min(max(checkHour, 0), 23)
        checkMinute = min(max(checkMinute, 0), 59)
        if TimeZone(identifier: timeZoneIdentifier) == nil {
            timeZoneIdentifier = TimeZone.current.identifier
        }
        for index in players.indices {
            players[index].normalize()
        }
    }
}

// MARK: - Ranked score snapshots

struct GameRankSnapshot: Codable, Hashable, Sendable {
    let game: GameID
    let provider: GameProviderID
    let playerID: String
    let displayName: String
    let season: String
    let rankName: String?
    let score: Int
    let updatedAt: Date?
}

struct GameRankChange: Hashable, Sendable {
    let targetID: UUID
    let game: GameID
    let provider: GameProviderID
    let destinationChannelID: String
    let playerID: String
    let displayName: String
    let season: String
    let rankName: String?
    let previousScore: Int
    let currentScore: Int

    var delta: Int { currentScore - previousScore }
}

struct GameRankBaseline: Codable, Hashable, Sendable {
    let game: GameID
    let provider: GameProviderID
    let playerID: String
    let displayName: String
    let season: String
    let rankName: String?
    let score: Int
    let recordedAt: Date

    init(snapshot: GameRankSnapshot, displayName: String, recordedAt: Date) {
        game = snapshot.game
        provider = snapshot.provider
        playerID = snapshot.playerID
        self.displayName = displayName
        season = snapshot.season
        rankName = snapshot.rankName
        score = snapshot.score
        self.recordedAt = recordedAt
    }
}

enum GameTrackingHistoryKind: String, Codable, Hashable, Sendable {
    case check
    case announcement
    case seasonReset
    case sessionStarted
    case sessionEnded
    case error
}

struct GameTrackingHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    let timestamp: Date
    let kind: GameTrackingHistoryKind
    let title: String
    let detail: String
}

struct GameTrackingRuntimeState: Codable, Hashable, Sendable {
    var baselinesByTargetID: [String: GameRankBaseline] = [:]
    var lastAttemptAt: Date?
    var lastSuccessfulCheckAt: Date?
    var history: [GameTrackingHistoryEntry] = []

    private enum CodingKeys: String, CodingKey {
        case baselinesByTargetID
        case lastAttemptAt
        case lastSuccessfulCheckAt
        case history
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baselinesByTargetID = try container.decodeIfPresent(
            [String: GameRankBaseline].self,
            forKey: .baselinesByTargetID
        ) ?? [:]
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastSuccessfulCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulCheckAt)
        history = try container.decodeIfPresent([GameTrackingHistoryEntry].self, forKey: .history) ?? []
    }

    mutating func record(_ entry: GameTrackingHistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > 50 {
            history.removeLast(history.count - 50)
        }
    }
}

enum GameRankEvaluation: Hashable, Sendable {
    case establishBaseline
    case unchanged
    case seasonChanged
    case changed(GameRankChange)
}

enum GameRankEvaluator {
    static func evaluate(
        target: GameTrackedPlayer,
        current: GameRankSnapshot,
        previous: GameRankBaseline?
    ) -> GameRankEvaluation {
        guard let previous else { return .establishBaseline }
        guard previous.game == current.game,
              previous.provider == current.provider,
              previous.playerID == current.playerID else {
            return .establishBaseline
        }

        let previousSeason = previous.season.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSeason = current.season.trimmingCharacters(in: .whitespacesAndNewlines)
        if !previousSeason.isEmpty, !currentSeason.isEmpty, previousSeason != currentSeason {
            return .seasonChanged
        }
        guard previous.score != current.score else { return .unchanged }

        return .changed(
            GameRankChange(
                targetID: target.id,
                game: target.game,
                provider: target.provider,
                destinationChannelID: target.destinationChannelID,
                playerID: current.playerID,
                displayName: target.resolvedDisplayName,
                season: current.season,
                rankName: current.rankName,
                previousScore: previous.score,
                currentScore: current.score
            )
        )
    }
}

