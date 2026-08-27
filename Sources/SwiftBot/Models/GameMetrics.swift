import Foundation

/// A single tracked statistic. Game Tracker started as a ranked-score notifier;
/// metrics generalise that so a provider can report whatever it actually has —
/// K/D, wins, playtime — without the model assuming a rating exists.
enum GameMetricID: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case rankedScore
    case rankTier
    case kills
    case deaths
    case assists
    case killDeathRatio
    case killsPerMinute
    case wins
    case losses
    case winRate
    case matchesPlayed
    case timePlayed
    case damage
    case accuracy
    case headshotRate
    case score

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rankedScore: return "Ranked Score"
        case .rankTier: return "Rank"
        case .kills: return "Kills"
        case .deaths: return "Deaths"
        case .assists: return "Assists"
        case .killDeathRatio: return "K/D"
        case .killsPerMinute: return "KPM"
        case .wins: return "Wins"
        case .losses: return "Losses"
        case .winRate: return "Win Rate"
        case .matchesPlayed: return "Matches"
        case .timePlayed: return "Time Played"
        case .damage: return "Damage"
        case .accuracy: return "Accuracy"
        case .headshotRate: return "Headshots"
        case .score: return "Score"
        }
    }

    /// How a metric behaves over time. This drives both formatting and whether
    /// a delta is meaningful, and it is the reason counters cannot be used as
    /// announcement triggers without producing a post after every match.
    enum Kind: Sendable {
        /// Monotonically increasing lifetime total (kills, matches, playtime).
        case counter
        /// A derived rate or ratio that moves in both directions (K/D, win rate).
        case ratio
        /// A rating that moves in both directions and is the headline number.
        case rating
    }

    var kind: Kind {
        switch self {
        case .rankedScore, .rankTier: return .rating
        case .killDeathRatio, .killsPerMinute, .winRate, .accuracy, .headshotRate: return .ratio
        case .kills, .deaths, .assists, .wins, .losses, .matchesPlayed, .timePlayed, .damage, .score:
            return .counter
        }
    }

    enum Format: Sendable {
        case integer
        case decimal(places: Int)
        case percent
        case duration
    }

    var format: Format {
        switch self {
        case .killDeathRatio, .killsPerMinute: return .decimal(places: 2)
        case .winRate, .accuracy, .headshotRate: return .percent
        case .timePlayed: return .duration
        case .rankTier: return .integer
        default: return .integer
        }
    }

    /// A counter always climbs, so announcing on one would fire after every
    /// match. Only two-directional metrics make sensible default triggers.
    var canTriggerAnnouncement: Bool {
        kind != .counter
    }

    func formatted(_ value: Double) -> String {
        switch format {
        case .integer:
            return Int(value.rounded()).formatted()
        case .decimal(let places):
            return String(format: "%.\(places)f", value)
        case .percent:
            // Accept either 0–1 or 0–100 from a provider.
            let percent = value <= 1.0 ? value * 100 : value
            return String(format: "%.1f%%", percent)
        case .duration:
            let totalMinutes = Int(value / 60)
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        }
    }

    /// Signed delta text, e.g. "+320" or "-0.04".
    func formattedDelta(_ delta: Double) -> String {
        let sign = delta > 0 ? "+" : (delta < 0 ? "-" : "")
        let magnitude = abs(delta)
        switch format {
        case .integer:
            return "\(sign)\(Int(magnitude.rounded()).formatted())"
        case .decimal(let places):
            return sign + String(format: "%.\(places)f", magnitude)
        case .percent:
            let percent = magnitude <= 1.0 ? magnitude * 100 : magnitude
            return sign + String(format: "%.1f pts", percent)
        case .duration:
            return sign + formatted(magnitude)
        }
    }
}

/// A set of metric readings for one player at one point in time.
struct GameMetricSet: Codable, Hashable, Sendable {
    private var storage: [String: Double]

    init(_ values: [GameMetricID: Double] = [:]) {
        storage = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        storage = (try? container.decode([String: Double].self)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }

    subscript(id: GameMetricID) -> Double? {
        get { storage[id.rawValue] }
        set { storage[id.rawValue] = newValue }
    }

    var presentMetrics: [GameMetricID] {
        storage.keys
            .compactMap(GameMetricID.init(rawValue:))
            .sorted { $0.rawValue < $1.rawValue }
    }

    var isEmpty: Bool { storage.isEmpty }

    /// Fills in ratios a provider reported only as raw counters, so a profile
    /// can track K/D even when the upstream API exposes only kills and deaths.
    func derivingRatios() -> GameMetricSet {
        var result = self
        if result[.killDeathRatio] == nil,
           let kills = result[.kills], let deaths = result[.deaths] {
            result[.killDeathRatio] = deaths > 0 ? kills / deaths : kills
        }
        if result[.winRate] == nil, let wins = result[.wins] {
            let losses = result[.losses] ?? 0
            let total = wins + losses
            if total > 0 { result[.winRate] = wins / total }
        }
        if result[.killsPerMinute] == nil,
           let kills = result[.kills], let seconds = result[.timePlayed], seconds > 0 {
            result[.killsPerMinute] = kills / (seconds / 60)
        }
        return result
    }
}

/// One metric's movement between two checks.
struct GameMetricChange: Hashable, Sendable {
    let metric: GameMetricID
    let previous: Double
    let current: Double

    var delta: Double { current - previous }
    var isIncrease: Bool { delta > 0 }

    var formattedCurrent: String { metric.formatted(current) }
    var formattedDelta: String { metric.formattedDelta(delta) }
}
