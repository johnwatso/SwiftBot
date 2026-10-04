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

    /// Channels excluded from collection entirely.
    var ignoredChannelIDs: Set<String> = []

    /// Leave everyday words, numbers and laughter out of top words and top
    /// phrases (`RewindTokenizer.isNotable`). Phrase queries are never
    /// filtered — `/rewind "how often is"` has to match literally.
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

    /// Replay recap drops, keyed by guild ID.
    var recapDrops: [String: RewindRecapDrop] = [:]

    /// Members who asked not to get personal Replay DMs (from the DM's button
    /// or `/replay dms:stop`). The only opt-out: everyone's activity counts
    /// towards Rewind, and anyone can see their own Replay.
    var replayDMOptOutUserIDs: Set<String> = []

    /// When the nightly catch-up last finished; the next one fetches from here.
    var lastCatchUpAt: Date?

    init() {}

    /// Every field is optional on disk so settings written by an older build,
    /// or before Rewind was persisted at all, load instead of resetting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RewindSettings()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        retainMessageContent = try c.decodeIfPresent(Bool.self, forKey: .retainMessageContent) ?? d.retainMessageContent
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        includeBotMessages = try c.decodeIfPresent(Bool.self, forKey: .includeBotMessages) ?? d.includeBotMessages
        ignoredChannelIDs = try c.decodeIfPresent(Set<String>.self, forKey: .ignoredChannelIDs) ?? d.ignoredChannelIDs
        filterStopWords = try c.decodeIfPresent(Bool.self, forKey: .filterStopWords) ?? d.filterStopWords
        restrictToAdmins = try c.decodeIfPresent(Bool.self, forKey: .restrictToAdmins) ?? d.restrictToAdmins
        excludeFromBackups = try c.decodeIfPresent(Bool.self, forKey: .excludeFromBackups) ?? d.excludeFromBackups
        recapDrops = try c.decodeIfPresent([String: RewindRecapDrop].self, forKey: .recapDrops) ?? d.recapDrops
        replayDMOptOutUserIDs = try c.decodeIfPresent(Set<String>.self, forKey: .replayDMOptOutUserIDs) ?? d.replayDMOptOutUserIDs
        lastCatchUpAt = try c.decodeIfPresent(Date.self, forKey: .lastCatchUpAt)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, retainMessageContent, retentionDays, includeBotMessages
        case ignoredChannelIDs, filterStopWords, restrictToAdmins, excludeFromBackups, recapDrops
        case replayDMOptOutUserIDs, lastCatchUpAt
    }

    func collects(channelID: String) -> Bool {
        isEnabled && !ignoredChannelIDs.contains(channelID)
    }

    func collects(userID: String, isBot: Bool) -> Bool {
        guard isEnabled else { return false }
        return !isBot || includeBotMessages
    }
}

/// Where and when a guild's Replay recaps are posted to Discord.
struct RewindRecapDrop: Codable, Hashable, Sendable {
    var channelID: String = ""
    var monthly: Bool = false
    var yearly: Bool = false
    /// Last period posted ("2026-09", "2026"), so a drop never repeats.
    var lastMonthlyKey: String?
    var lastYearlyKey: String?
    /// Also DM each active member their own Replay on the same schedule.
    var personalDMs: Bool = false
    /// Limit unsolicited DMs to members who regularly chat in this server.
    var onlyDMActiveMembers: Bool = true
    var lastPersonalMonthlyKey: String?
    var lastPersonalYearlyKey: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        monthly = try c.decodeIfPresent(Bool.self, forKey: .monthly) ?? false
        yearly = try c.decodeIfPresent(Bool.self, forKey: .yearly) ?? false
        lastMonthlyKey = try c.decodeIfPresent(String.self, forKey: .lastMonthlyKey)
        lastYearlyKey = try c.decodeIfPresent(String.self, forKey: .lastYearlyKey)
        personalDMs = try c.decodeIfPresent(Bool.self, forKey: .personalDMs) ?? false
        onlyDMActiveMembers = try c.decodeIfPresent(Bool.self, forKey: .onlyDMActiveMembers) ?? true
        lastPersonalMonthlyKey = try c.decodeIfPresent(String.self, forKey: .lastPersonalMonthlyKey)
        lastPersonalYearlyKey = try c.decodeIfPresent(String.self, forKey: .lastPersonalYearlyKey)
    }

    private enum CodingKeys: String, CodingKey {
        case channelID, monthly, yearly, lastMonthlyKey, lastYearlyKey
        case personalDMs, onlyDMActiveMembers, lastPersonalMonthlyKey, lastPersonalYearlyKey
    }

    /// Something is scheduled: a channel post or member DMs, monthly or yearly.
    var isScheduled: Bool {
        (monthly || yearly) && (!channelID.isEmpty || personalDMs)
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
    /// Archived days outside a range needed before its words are ranked
    /// against them; with less, there is no "usual" to compare to and the
    /// range falls back to plain frequency.
    static let distinctiveBaselineDays = 30
    /// A term must be at least this many times more common than usual.
    static let distinctiveMinimumLift = 1.5
    /// Words a member must have written in a range before they get a
    /// signature, and words everyone else must have written to compare with.
    static let signatureMinimumWords = 100
    static let signatureMinimumBaselineWords = 500
    /// How long a range's per-member word counts are reused. A personal-Replay
    /// DM run asks for every member in turn; one scan serves them all.
    static let signatureCacheLifetime: TimeInterval = 600
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
    /// Set when the term was ranked against the rest of the archive: how many
    /// times more often this period used it than usual (by share of words),
    /// and how often it was said outside the period. A `baselineCount` of 0
    /// means the period introduced it.
    var lift: Double? = nil
    var baselineCount: Int? = nil

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

/// A guild's messages over a Replay range.
struct RewindRangeSummary: Sendable {
    var totalMessages = 0
    var totalWords = 0
    var activeDays = 0
    var memberCount = 0
    var busiestDay: RewindDayCount?
    var peakHour: Int?
    var bucketCounts: [Int]
    var hourly: [Int] = Array(repeating: 0, count: 24)
    var topUsers: [RewindUserCount] = []
    var topWords: [RewindTermCount] = []
    var topBigrams: [RewindTermCount] = []
    var topEmoji: [RewindTermCount] = []
    /// Channel IDs; resolved to names by the caller.
    var topChannels: [RewindTermCount] = []
    /// `topWords` and `topBigrams` are what set this range apart from the rest
    /// of the archive, not simply what was said most.
    var termsAreDistinctive = false
}

/// One member's messages over a Replay range.
struct RewindUserRangeSummary: Sendable {
    var userName: String?
    var messages = 0
    var words = 0
    var activeDays = 0
    var busiestDay: RewindDayCount?
    var rank: Int?
    var rankedMembers = 0
}

/// Message activity over an Analytics period, across all archived servers.
struct RewindPeriodSummary: Sendable {
    var totalMessages = 0
    var previousMessages = 0
    var bucketCounts: [Int]
    var hourly: [Int] = Array(repeating: 0, count: 24)
    var topUsers: [RewindUserCount] = []
    var topWords: [RewindTermCount] = []
    var topEmoji: [RewindTermCount] = []
    /// Channel IDs; names are resolved by the caller.
    var topChannels: [RewindTermCount] = []
    var hasArchive = false
}

/// The words and phrases one member uses far more than the rest of the
/// server over a range — their "signature". Terms carry `lift` against
/// everyone else and a `baselineCount` of 0 when nobody else said them.
struct RewindSignature: Sendable {
    var words: [RewindTermCount] = []
    var phrases: [RewindTermCount] = []

    var isEmpty: Bool { words.isEmpty && phrases.isEmpty }
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

    /// Words too common to say anything about a server: grammar, contractions,
    /// everyday conversational verbs and adjectives, and the generic gaming
    /// vocabulary every server shares. What's left is what makes a server
    /// sound like itself — names, games, in-jokes, "gg".
    static let stopWords: Set<String> = [
        // Grammar
        "a", "about", "above", "after", "again", "against", "all", "also", "am", "an", "and", "any",
        "are", "around", "as", "at", "away", "back", "be", "because", "been", "before", "being",
        "below", "between", "both", "but", "by", "can", "could", "did", "do", "does", "doing",
        "done", "down", "during", "each", "either", "else", "enough", "etc", "even", "ever",
        "every", "few", "for", "from", "further", "had", "has", "have", "having", "he", "her",
        "here", "hers", "herself", "him", "himself", "his", "how", "i", "if", "in", "into", "is",
        "it", "its", "itself", "just", "least", "less", "many", "may", "me", "might", "mine",
        "more", "most", "much", "must", "my", "myself", "neither", "never", "no", "nor", "not",
        "now", "of", "off", "often", "on", "once", "one", "only", "onto", "or", "other", "others",
        "our", "ours", "out", "over", "own", "per", "same", "shall", "she", "should", "since", "so",
        "some", "such", "than", "that", "the", "their", "theirs", "them", "themselves", "then",
        "there", "these", "they", "this", "those", "though", "through", "thru", "till", "to",
        "too", "under", "until", "up", "upon", "us", "very", "via", "was", "we", "were", "what",
        "whatever", "when", "where", "whether", "which", "while", "who", "whom", "whose", "why",
        "will", "with", "within", "without", "would", "yet", "you", "your", "yours", "yourself",
        // Contractions, with and without the apostrophe
        "ain't", "aren't", "can't", "cant", "couldn't", "couldnt", "didn't", "didnt", "doesn't",
        "doesnt", "don't", "dont", "hadn't", "hasn't", "haven't", "havent", "he'd", "he'll",
        "he's", "hes", "here's", "how's", "i'd", "i'll", "ill", "i'm", "im", "i've", "ive",
        "isn't", "isnt", "it'd", "it'll", "it's", "let's", "lets", "she'd", "she'll", "she's",
        "shouldn't", "shouldnt", "that'd", "that'll", "that's", "thats", "there's", "theres",
        "they'd", "they'll", "they're", "theyre", "they've", "wasn't", "wasnt", "we'd", "we'll",
        "we're", "we've", "weren't", "what's", "whats", "where's", "who's", "won't", "wont",
        "wouldn't", "wouldnt", "y'all", "you'd", "you'll", "you're", "youre", "you've",
        // Everyday verbs
        "ask", "asked", "come", "comes", "coming", "came", "feel", "find", "found", "get", "gets",
        "getting", "give", "go", "goes", "going", "gone", "gonna", "got", "gotta", "guess",
        "keep", "know", "knew", "leave", "let", "look", "looks", "looking", "made", "make",
        "makes", "making", "mean", "need", "needs", "put", "said", "say", "says", "see", "seen",
        "seems", "tell", "take", "takes", "taking", "think", "thinking", "thought", "told",
        "took", "try", "trying", "tried", "use", "used", "using", "wait", "want", "wanna",
        "wants", "went", "work", "works", "working",
        // Everyday adjectives, adverbs and nouns
        "actually", "already", "always", "another", "anyone", "anything", "bad", "best", "better",
        "big", "bit", "day", "days", "different", "else", "everyone", "everything", "first", "good",
        "great", "kind", "last", "little", "long", "lot", "lots", "maybe", "new", "next", "nice",
        "old", "people", "pretty", "probably", "quite", "real", "really", "right", "someone",
        "something", "soon", "sure", "thing", "things", "time", "times", "today", "tomorrow",
        "tonight", "way", "week", "well", "whole", "year", "years", "yesterday",
        // Chat filler
        "ah", "ahh", "aight", "alright", "bro", "btw", "cool", "eh", "fine", "hey", "hi",
        "hm", "hmm", "idk", "imo", "k", "kk", "like", "mhm", "nah", "nope", "ok", "okay", "oh",
        "omg", "please", "pls", "plz", "rn", "tbh", "thanks", "thank", "thx", "u", "uh", "um",
        "ur", "wow", "ya", "yea", "yeah", "yep", "yes", "yo", "yup",
        // Generic gaming talk every server shares
        "game", "games", "play", "played", "player", "players", "playing", "plays"
    ]

    static func isStopWord(_ word: String) -> Bool {
        stopWords.contains(word)
    }

    /// Worth a place in a "top words" list: not a stop word, a number, a
    /// single character or a laugh. Phrase queries never go through this.
    static func isNotable(word: String) -> Bool {
        guard word.count > 1, !isStopWord(word), !isLaughter(word) else { return false }
        return !word.allSatisfy(\.isNumber)
    }

    /// A top phrase must be two notable words: "in the" and "i think" are
    /// grammar, not something the server says.
    static func isNotable(bigram: String) -> Bool {
        let parts = bigram.split(separator: " ")
        return parts.count == 2 && parts.allSatisfy { isNotable(word: String($0)) }
    }

    /// "haha", "hahahaha", "hehe", "lol", "lmao", "xd" and their stretched-out
    /// spellings. Everyone laughs; it says nothing about a server.
    static func isLaughter(_ word: String) -> Bool {
        let range = NSRange(word.startIndex..<word.endIndex, in: word)
        return laughterExpression?.firstMatch(in: word, options: [.anchored], range: range)?.range == range
    }

    private static let laughterExpression: NSRegularExpression? = try? NSRegularExpression(
        pattern: "a?(?:h+[aeiou]+)+h*|lo+l+(?:o+l+)*z?|lm+f?a+o+|rofl+|xd+|kekw?|ja(?:ja)+",
        options: [.caseInsensitive]
    )
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
