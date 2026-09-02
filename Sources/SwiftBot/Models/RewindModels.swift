import Foundation

// MARK: - Settings

/// Rewind is off by default. It is the only SwiftBot subsystem that retains
/// message text, so every switch here starts in the least-collecting position
/// and the operator opts in explicitly from Analytics → Rewind.
struct RewindSettings: Codable, Hashable, Sendable {
    /// Master switch. When false nothing is written and `/rewind` reports that
    /// collection is off.
    var isEnabled: Bool = false

    /// Tier 3. Keeps normalized message text on disk so arbitrary phrases can
    /// be counted retroactively. With this off, Rewind still records the daily
    /// aggregates (counts, top words, leaderboards) but a phrase that wasn't
    /// already a tracked term or a common word cannot be looked up after the
    /// fact.
    var retainMessageContent: Bool = true

    /// Days of message text to keep. `0` keeps everything, which is the point
    /// of a year-end rewind. Aggregates are never trimmed — they are small and
    /// are what the yearly summary reads.
    var retentionDays: Int = 0

    /// Archive messages posted by bots (including SwiftBot itself). Off by
    /// default because bot output would otherwise dominate every word count.
    var includeBotMessages: Bool = false

    /// Users who asked not to be counted. Their messages are dropped at ingest,
    /// never written, and `/rewind forget` also purges what was already stored.
    var optedOutUserIDs: Set<String> = []

    /// Channels excluded from collection entirely.
    var ignoredChannelIDs: Set<String> = []

    /// Filter "the/and/a" out of top-word results. Phrase queries are never
    /// stop-word filtered — `/rewind "how often is"` has to match literally.
    var filterStopWords: Bool = true

    /// Restrict `/rewind` to guild owners and administrators.
    var restrictToAdmins: Bool = false

    /// Keep the archive out of Time Machine and other backups.
    ///
    /// On by default: a backup target is usually less protected than the machine
    /// itself, and an archive of everything the server said is the last thing
    /// that should be copied somewhere with weaker access control. The cost is
    /// that the archive cannot be restored from a backup after a disk failure.
    var excludeFromBackups: Bool = true

    func collects(channelID: String) -> Bool {
        isEnabled && !ignoredChannelIDs.contains(channelID)
    }

    func collects(userID: String, isBot: Bool) -> Bool {
        guard isEnabled else { return false }
        if isBot && !includeBotMessages { return false }
        return !optedOutUserIDs.contains(userID)
    }
}

// MARK: - Stored records

/// One archived guild message — the raw record Rewind keeps on disk. Word
/// counts, leaderboards and phrase lookups are all derived from these, either
/// at query time or via the rolled-up daily aggregates.
///
/// Coding keys are single letters on purpose: these are written one-per-line to
/// an append-only shard and the key names would otherwise be roughly a third of
/// the file. `createdAt` is stored as epoch seconds for the same reason.
struct RewindMessage: Codable, Sendable, Hashable {
    let id: String
    let guildID: String
    let channelID: String
    let authorID: String
    let authorName: String
    let isBot: Bool
    let content: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "i"
        case guildID = "g"
        case channelID = "c"
        case authorID = "u"
        case authorName = "n"
        case isBot = "b"
        case content = "t"
        case createdAt = "d"
    }

    init(
        id: String,
        guildID: String,
        channelID: String,
        authorID: String,
        authorName: String,
        isBot: Bool,
        content: String,
        createdAt: Date
    ) {
        self.id = id
        self.guildID = guildID
        self.channelID = channelID
        self.authorID = authorID
        self.authorName = authorName
        self.isBot = isBot
        self.content = content
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        guildID = try container.decode(String.self, forKey: .guildID)
        channelID = try container.decode(String.self, forKey: .channelID)
        authorID = try container.decode(String.self, forKey: .authorID)
        authorName = try container.decode(String.self, forKey: .authorName)
        isBot = try container.decodeIfPresent(Bool.self, forKey: .isBot) ?? false
        content = try container.decode(String.self, forKey: .content)
        createdAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .createdAt))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(guildID, forKey: .guildID)
        try container.encode(channelID, forKey: .channelID)
        try container.encode(authorID, forKey: .authorID)
        try container.encode(authorName, forKey: .authorName)
        if isBot { try container.encode(true, forKey: .isBot) }
        try container.encode(content, forKey: .content)
        try container.encode(createdAt.timeIntervalSince1970.rounded(), forKey: .createdAt)
    }
}

/// Precomputed counters for a single guild-day. Written alongside the message
/// shards so the yearly summary and the leaderboards never have to touch the
/// raw archive.
///
/// The term maps are trimmed to `RewindLimits.termsPerDay` on flush, so the
/// long tail of once-said words is approximate across a full year. That is fine
/// for "top words of 2026"; anything needing exactness (a specific phrase) is
/// answered by scanning the shards instead.
struct RewindDailyAggregate: Codable, Sendable {
    var day: String
    var messageCount: Int = 0
    var wordCount: Int = 0
    var messagesByUser: [String: Int] = [:]
    var wordsByUser: [String: Int] = [:]
    var messagesByChannel: [String: Int] = [:]
    var messagesByHour: [Int] = Array(repeating: 0, count: 24)
    var wordCounts: [String: Int] = [:]
    var bigramCounts: [String: Int] = [:]
    var emojiCounts: [String: Int] = [:]
    var userNames: [String: String] = [:]

    init(day: String) {
        self.day = day
    }

    mutating func absorb(_ message: RewindMessage, calendar: Calendar) {
        messageCount += 1
        messagesByUser[message.authorID, default: 0] += 1
        messagesByChannel[message.channelID, default: 0] += 1
        userNames[message.authorID] = message.authorName

        let hour = calendar.component(.hour, from: message.createdAt)
        if messagesByHour.count == 24, hour >= 0, hour < 24 {
            messagesByHour[hour] += 1
        }

        let words = RewindTokenizer.words(in: message.content)
        wordCount += words.count
        wordsByUser[message.authorID, default: 0] += words.count
        for word in words {
            wordCounts[word, default: 0] += 1
        }
        for bigram in RewindTokenizer.bigrams(from: words) {
            bigramCounts[bigram, default: 0] += 1
        }
        for emoji in RewindTokenizer.emoji(in: message.content) {
            emojiCounts[emoji, default: 0] += 1
        }
    }

    /// Bounds the on-disk size of a day. Called before the aggregate is written.
    mutating func trim(to limit: Int = RewindLimits.termsPerDay) {
        wordCounts = Self.trimmed(wordCounts, to: limit)
        bigramCounts = Self.trimmed(bigramCounts, to: limit)
        emojiCounts = Self.trimmed(emojiCounts, to: limit)
    }

    private static func trimmed(_ counts: [String: Int], to limit: Int) -> [String: Int] {
        guard counts.count > limit else { return counts }
        let kept = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

enum RewindLimits {
    /// Distinct terms kept per day, per term map.
    static let termsPerDay = 2_000
    /// Messages buffered in memory before an append is forced.
    static let flushMessageThreshold = 25
    /// Seconds between automatic flushes of the pending buffer.
    static let flushInterval: TimeInterval = 20
    /// Hard ceiling on messages examined by one phrase query, so a pathological
    /// archive can't wedge a slash command.
    static let phraseScanCeiling = 5_000_000
}

// MARK: - Query results

struct RewindTermCount: Sendable, Hashable, Identifiable {
    let term: String
    let count: Int

    var id: String { term }
}

struct RewindUserCount: Sendable, Hashable, Identifiable {
    let userID: String
    let userName: String
    let count: Int

    var id: String { userID }
}

/// Answer to `/rewind phrase:"gg guys"`.
struct RewindPhraseReport: Sendable {
    let phrase: String
    /// Total times the phrase appears, counting repeats within one message.
    let totalOccurrences: Int
    /// Distinct messages containing it at least once.
    let messageCount: Int
    let firstSeen: Date?
    let lastSeen: Date?
    let byUser: [RewindUserCount]
    let byMonth: [RewindTermCount]
    let topChannelID: String?
    /// Messages examined, so the caller can say "across 182,441 messages".
    let scannedMessages: Int
    /// A verbatim example, useful for the year-end card.
    let sampleMessage: RewindMessage?

    static func empty(phrase: String) -> RewindPhraseReport {
        RewindPhraseReport(
            phrase: phrase,
            totalOccurrences: 0,
            messageCount: 0,
            firstSeen: nil,
            lastSeen: nil,
            byUser: [],
            byMonth: [],
            topChannelID: nil,
            scannedMessages: 0,
            sampleMessage: nil
        )
    }
}

struct RewindDayCount: Sendable, Hashable {
    let day: String
    let count: Int
}

/// Answer to `/rewind year:2026` — the end-of-year card.
struct RewindYearSummary: Sendable {
    let year: Int
    let totalMessages: Int
    let totalWords: Int
    let activeDays: Int
    let busiestDay: RewindDayCount?
    let peakHour: Int?
    let topUsers: [RewindUserCount]
    let topWords: [RewindTermCount]
    let topBigrams: [RewindTermCount]
    let topEmoji: [RewindTermCount]
    let topChannels: [RewindTermCount]

    var isEmpty: Bool { totalMessages == 0 }

    static func empty(year: Int) -> RewindYearSummary {
        RewindYearSummary(
            year: year,
            totalMessages: 0,
            totalWords: 0,
            activeDays: 0,
            busiestDay: nil,
            peakHour: nil,
            topUsers: [],
            topWords: [],
            topBigrams: [],
            topEmoji: [],
            topChannels: []
        )
    }
}

/// Per-user slice of a year, for `/rewind me`.
struct RewindUserSummary: Sendable {
    let userID: String
    let userName: String
    let year: Int
    let messageCount: Int
    let wordCount: Int
    let activeDays: Int
    let rank: Int?
    let totalRankedUsers: Int
    let busiestDay: RewindDayCount?

    var averageWordsPerMessage: Double {
        messageCount > 0 ? Double(wordCount) / Double(messageCount) : 0
    }
}

/// What Rewind currently holds, for the settings screen and `/rewind status`.
struct RewindArchiveStats: Sendable {
    let guildCount: Int
    let messageCount: Int
    let diskBytes: Int64
    let earliestDay: String?
    let latestDay: String?

    static let empty = RewindArchiveStats(
        guildCount: 0,
        messageCount: 0,
        diskBytes: 0,
        earliestDay: nil,
        latestDay: nil
    )
}

// MARK: - Tokenizer

/// Turns raw Discord message text into the word/emoji tokens Rewind counts.
///
/// Phrase matching runs over the same token stream rather than over raw
/// substrings, so `"how often is"` matches `"How often IS this?"` but `"is"`
/// never matches inside `"island"`.
enum RewindTokenizer {
    /// `https://…`, `<@123>`, `<@!123>`, `<@&123>`, `<#123>`, `<:name:123>`,
    /// `<a:name:123>`. Stripped before tokenizing so raw IDs never become words.
    private static let noiseExpression: NSRegularExpression? = try? NSRegularExpression(
        pattern: "https?://\\S+|<a?:[A-Za-z0-9_]+:\\d+>|<@[!&]?\\d+>|<#\\d+>",
        options: [.caseInsensitive]
    )

    private static let customEmojiExpression: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<a?:([A-Za-z0-9_]+):\\d+>",
        options: []
    )

    /// Lowercased text with URLs, mentions and custom-emoji markup removed.
    static func normalize(_ content: String) -> String {
        let lowered = content.lowercased()
        guard let expression = noiseExpression else { return lowered }
        let range = NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
        return expression.stringByReplacingMatches(in: lowered, options: [], range: range, withTemplate: " ")
    }

    /// Word tokens. Letters and digits form words; an apostrophe is kept when it
    /// sits between two letters so `don't` stays one token rather than two.
    static func words(in content: String) -> [String] {
        tokenize(normalize(content))
    }

    /// Tokens for a search phrase. Identical treatment to message text so the
    /// two sides always agree.
    static func phraseTokens(_ phrase: String) -> [String] {
        tokenize(normalize(phrase))
    }

    private static func tokenize(_ normalized: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var pendingApostrophe = false

        for character in normalized {
            if character.isLetter || character.isNumber {
                if pendingApostrophe {
                    current.append("'")
                    pendingApostrophe = false
                }
                current.append(character)
                continue
            }

            let isApostrophe = character == "'" || character == "\u{2019}"
            if isApostrophe, !current.isEmpty, !pendingApostrophe {
                pendingApostrophe = true
                continue
            }

            pendingApostrophe = false
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func bigrams(from words: [String]) -> [String] {
        guard words.count > 1 else { return [] }
        return (0..<(words.count - 1)).map { "\(words[$0]) \(words[$0 + 1])" }
    }

    /// Unicode emoji plus `:custom_name:` for guild emoji, so both show up in
    /// the yearly "most used emoji" list.
    static func emoji(in content: String) -> [String] {
        var found: [String] = []

        for scalar in content.unicodeScalars where scalar.properties.isEmojiPresentation {
            found.append(String(scalar))
        }

        if let expression = customEmojiExpression {
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            for match in expression.matches(in: content, options: [], range: range) {
                guard match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: content) else { continue }
                found.append(":\(content[nameRange]):")
            }
        }

        return found
    }

    /// Occurrences of `phrase` in `haystack`, both already tokenized. Counts
    /// repeats, so "gg gg gg" against ["gg"] returns 3. Overlapping matches are
    /// not double counted: the scan advances past a match.
    static func occurrences(of phrase: [String], in haystack: [String]) -> Int {
        guard !phrase.isEmpty, haystack.count >= phrase.count else { return 0 }

        var count = 0
        var index = 0
        let limit = haystack.count - phrase.count

        while index <= limit {
            var matched = true
            for offset in 0..<phrase.count where haystack[index + offset] != phrase[offset] {
                matched = false
                break
            }
            if matched {
                count += 1
                index += phrase.count
            } else {
                index += 1
            }
        }

        return count
    }

    /// Words too common to be interesting in a "top words" list. Deliberately
    /// short — this filters plumbing, not personality, so "lol", "gg" and
    /// "actually" all survive.
    static let stopWords: Set<String> = [
        "a", "about", "after", "all", "also", "am", "an", "and", "any", "are", "as", "at",
        "back", "be", "because", "been", "before", "being", "but", "by",
        "can", "could", "did", "do", "does", "doing", "don't", "down",
        "even", "for", "from", "get", "go", "going", "got",
        "had", "has", "have", "he", "her", "here", "him", "his", "how",
        "i", "if", "in", "into", "is", "it", "it's", "its",
        "just", "know", "like", "me", "more", "most", "my",
        "no", "not", "now", "of", "off", "on", "one", "only", "or", "other", "our", "out", "over",
        "really", "said", "same", "see", "she", "should", "so", "some", "still", "such",
        "than", "that", "the", "their", "them", "then", "there", "these", "they", "this", "those",
        "through", "to", "too", "up", "us", "use",
        "very", "want", "was", "way", "we", "well", "were", "what", "when", "where", "which",
        "while", "who", "why", "will", "with", "would",
        "yeah", "you", "your", "you're"
    ]

    static func isStopWord(_ word: String) -> Bool {
        stopWords.contains(word)
    }
}

// MARK: - Day keys

/// Rewind keys everything by local calendar day and month. Both formatters are
/// fixed-locale so a user's region can never change how shards are named.
enum RewindCalendar {
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func monthKey(for date: Date) -> String {
        monthFormatter.string(from: date)
    }

    static func year(from dayKey: String) -> Int? {
        Int(dayKey.prefix(4))
    }

    /// Month keys covering `range`, oldest first, so a query only opens the
    /// shards it actually needs.
    static func monthKeys(from start: Date, to end: Date) -> [String] {
        guard start <= end else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")

        var keys: [String] = []
        var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
        while cursor <= end {
            keys.append(monthKey(for: cursor))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
    }
}

// MARK: - Backfill

/// Live progress for a historical import, surfaced in Analytics → Rewind.
struct RewindBackfillProgress: Sendable, Equatable {
    var guildID: String
    var guildName: String
    var channelsTotal: Int
    var channelsCompleted: Int
    var currentChannelName: String
    var messagesImported: Int
    var messagesScanned: Int
    var startedAt: Date
    var finishedAt: Date?
    var lastError: String?
    var isCancelled: Bool = false

    var isRunning: Bool { finishedAt == nil && !isCancelled }

    var fractionComplete: Double {
        guard channelsTotal > 0 else { return 0 }
        return min(1, Double(channelsCompleted) / Double(channelsTotal))
    }
}
