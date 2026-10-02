import Foundation

/// The span a Replay covers: a calendar year or a calendar month.
enum ReplayPeriod: Hashable, Sendable {
    case year(Int)
    case month(year: Int, month: Int)

    /// "2026" or "2026-09".
    init?(key: String) {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        switch parts.count {
        case 1 where (2015...2100).contains(parts[0]):
            self = .year(parts[0])
        case 2 where (2015...2100).contains(parts[0]) && (1...12).contains(parts[1]):
            self = .month(year: parts[0], month: parts[1])
        default:
            return nil
        }
    }

    var key: String {
        switch self {
        case .year(let year): return String(year)
        case .month(let year, let month): return String(format: "%04d-%02d", year, month)
        }
    }

    var isYear: Bool {
        if case .year = self { return true }
        return false
    }

    func title(calendar: Calendar = .current) -> String {
        switch self {
        case .year(let year): return String(year)
        case .month(let year, let month):
            let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
            return date.formatted(.dateTime.month(.wide).year())
        }
    }

    /// From the start of the period to its end, or to `now` while it's
    /// still running.
    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let start: Date
        let end: Date
        switch self {
        case .year(let year):
            start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
            end = calendar.date(byAdding: .year, value: 1, to: start) ?? now
        case .month(let year, let month):
            start = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
            end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
        }
        return DateInterval(start: start, end: max(start, min(end, now)))
    }

    /// Months of a year, or days of a month.
    func buckets(calendar: Calendar = .current) -> [AnalyticsBucket] {
        switch self {
        case .year(let year):
            return (1...12).compactMap { month in
                guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                      let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
                return AnalyticsBucket(start: start, end: end, label: start.formatted(.dateTime.month(.abbreviated)))
            }
        case .month(let year, let month):
            guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let days = calendar.range(of: .day, in: .month, for: first) else { return [] }
            return days.compactMap { day in
                guard let start = calendar.date(byAdding: .day, value: day - 1, to: first),
                      let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
                return AnalyticsBucket(start: start, end: end, label: String(day))
            }
        }
    }

    /// The period of the same kind just before this one.
    var previous: ReplayPeriod {
        switch self {
        case .year(let year): return .year(year - 1)
        case .month(let year, let month): return month == 1 ? .month(year: year - 1, month: 12) : .month(year: year, month: month - 1)
        }
    }

    /// The month before the one containing `date`.
    static func previousMonth(before date: Date, calendar: Calendar = .current) -> ReplayPeriod {
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: date) ?? date
        let parts = calendar.dateComponents([.year, .month], from: lastMonth)
        return .month(year: parts.year ?? 2026, month: parts.month ?? 1)
    }
}

/// A server's Replay: everything the recap story, the web page and the
/// Discord drop show. Codable so the WebUI can read it directly.
struct ServerReplay: Codable, Sendable {
    struct Ranked: Codable, Sendable, Hashable {
        let title: String
        let count: Int
        var id: String?
    }
    struct Bucket: Codable, Sendable {
        let label: String
        let messages: Int
        let voiceMinutes: Int
    }
    struct RankChange: Codable, Sendable {
        let name: String
        let game: String
        let from: Int
        let to: Int
        let rankName: String?
    }

    let guildID: String
    let guildName: String
    let periodKey: String
    let periodTitle: String
    let isYear: Bool
    let isComplete: Bool

    var messages = 0
    var words = 0
    var activeDays = 0
    var chattingMembers = 0
    var busiestDay: String?
    var busiestDayMessages = 0
    var peakHour: Int?
    var timeline: [Bucket] = []
    var hourly: [Int] = Array(repeating: 0, count: 24)
    var topMembers: [Ranked] = []
    var topChannels: [Ranked] = []
    /// Fragments of members' messages: admin-only on the web.
    var topWords: [Ranked]?
    var topPhrases: [Ranked]?
    var topEmoji: [Ranked]?

    var voiceSeconds = 0
    var voiceSessions = 0
    var topVoiceMembers: [Ranked] = []
    var topVoiceChannels: [Ranked] = []

    /// Community-wide stats SwiftBot keeps for all servers together. Only
    /// included when this is the only connected server, so one server's
    /// recap never shows another's numbers.
    var commands: Int?
    var topCommands: [Ranked]?
    var joins: Int?
    var leaves: Int?
    var clipsByGame: [Ranked]?
    var rankChanges: [RankChange]?

    var hasMessages: Bool { messages > 0 }
}

/// One member's Replay for a server.
struct PersonalReplay: Codable, Sendable {
    let guildID: String
    let guildName: String
    let userID: String
    var name: String
    let periodKey: String
    let periodTitle: String

    var messages = 0
    var words = 0
    var activeDays = 0
    var busiestDay: String?
    var busiestDayMessages = 0
    var rank: Int?
    var rankedMembers = 0
    var voiceSeconds = 0
    var voiceSessions = 0
    var longestSessionSeconds = 0
    var favouriteVoiceChannel: String?
    var voiceRank: Int?
    var commands: Int?
    /// The same numbers for the period before, for "vs last month" lines.
    var previousPeriodTitle: String?
    var previousMessages = 0
    var previousVoiceSeconds = 0

    /// "Top 5%" style placing, when there are enough members for it to mean something.
    var topPercent: Int? {
        guard let rank, rankedMembers >= 10 else { return nil }
        return max(1, Int((Double(rank) / Double(rankedMembers) * 100).rounded(.up)))
    }
}

/// A personal-Replay DM run, shown on the Rewind page while it's sending.
struct ReplayDMProgress: Codable, Sendable {
    let guildID: String
    let periodKey: String
    let total: Int
    /// Members gone through so far, including ones skipped or with DMs closed.
    var processed = 0
    var sent = 0
    var failed = 0
    var startedAt = Date()
    var finishedAt: Date?
}
