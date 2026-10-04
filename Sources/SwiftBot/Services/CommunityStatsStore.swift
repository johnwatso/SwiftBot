import Foundation

/// Per-day community counters for Analytics: commands (by name, person and
/// channel), member joins and leaves, and Game Tracker rank readings.
///
/// Day totals rather than raw events, so a year of history stays small and
/// the year view is cheap. Commands are recorded here as well as in the
/// Activity command log, so clearing Activity doesn't reset the leaderboards.
struct CommunityDayStats: Codable, Sendable {
    var commands: [String: Int] = [:]
    /// Keyed by the command log's raw user value; names are resolved at read time.
    var users: [String: Int] = [:]
    /// Keyed "server|channel" from the command log, resolved at read time.
    var channels: [String: Int] = [:]
    /// Optional so historical day records continue to decode.
    var featureUses: [String: Int]? = nil
    var commandCount = 0
    var failedCommands = 0
    var joins = 0
    var leaves = 0
}

struct CommunityRankPoint: Codable, Sendable, Hashable {
    let date: Date
    let score: Int
    let rankName: String?
    /// Every stat the provider reported at this check, keyed by
    /// `GameMetricID` raw value. Nil for points recorded before stats were.
    var metrics: [String: Double]?
}

/// One finished play session, kept whether or not it was announced.
struct CommunitySessionRecord: Codable, Sendable, Hashable {
    let startedAt: Date
    let endedAt: Date
    let game: String
    let matches: Int
    let rankedMatches: Int
    let wins: Int
    let kills: Int
    let deaths: Int
    let damage: Double
}

struct CommunityRankSeries: Codable, Sendable {
    var displayName: String
    var game: String
    var points: [CommunityRankPoint] = []
}

struct CommunityStatsSummary: Sendable {
    var featureUses: [String: Int] = [:]
    var commandCount = 0
    var failedCommands = 0
    var joins = 0
    var leaves = 0
    var commands: [String: Int] = [:]
    var users: [String: Int] = [:]
    var channels: [String: Int] = [:]
    /// Per bucket, in the order the buckets were given.
    var commandsPerBucket: [Int] = []
    var joinsPerBucket: [Int] = []
    var leavesPerBucket: [Int] = []
}

actor CommunityStatsStore {
    private struct FileContents: Codable {
        var days: [String: CommunityDayStats] = [:]
        /// Keyed by the tracked player's UUID.
        var rankHistory: [String: CommunityRankSeries] = [:]
        /// Keyed by the tracked player's UUID.
        var sessionHistory: [String: [CommunitySessionRecord]] = [:]
        /// Set once the command log has been folded in, so it only happens once.
        var backfilledCommandLog = false

        init() {}

        /// Every key is optional so adding a field never fails an existing
        /// file — a failed decode would silently start the stats from empty.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            days = try c.decodeIfPresent([String: CommunityDayStats].self, forKey: .days) ?? [:]
            rankHistory = try c.decodeIfPresent([String: CommunityRankSeries].self, forKey: .rankHistory) ?? [:]
            sessionHistory = try c.decodeIfPresent([String: [CommunitySessionRecord]].self, forKey: .sessionHistory) ?? [:]
            backfilledCommandLog = try c.decodeIfPresent(Bool.self, forKey: .backfilledCommandLog) ?? false
        }
    }

    private let url: URL
    private let calendar: Calendar
    private var contents = FileContents()
    private var isLoaded = false
    private var saveTask: Task<Void, Never>?
    private let retainedDays = 400
    private let maxRankPointsPerPlayer = 500
    private let maxSessionsPerPlayer = 500

    init(url: URL = SwiftBotStorage.folderURL().appendingPathComponent(SwiftBotStorage.communityStatsFileName)) {
        self.url = url
        self.calendar = .current
    }

    func load() {
        guard !isLoaded else { return }
        if let data = try? Data(contentsOf: url),
           let decoded = try? Self.decoder.decode(FileContents.self, from: data) {
            contents = decoded
        }
        isLoaded = true
    }

    /// Folds the existing command log into the day totals the first time the
    /// store runs, so history from before this store existed still counts.
    func backfillIfNeeded(from commandLog: [CommandLogEntry]) {
        load()
        guard !contents.backfilledCommandLog else { return }
        for entry in commandLog {
            apply(command: entry)
        }
        contents.backfilledCommandLog = true
        scheduleSave()
    }

    // MARK: - Recording

    func recordCommand(_ entry: CommandLogEntry) {
        load()
        apply(command: entry)
        scheduleSave()
    }

    /// Completed work, rather than enabled settings or attempted outputs.
    func recordFeatureUse(_ feature: String, count: Int = 1, at date: Date = Date()) {
        guard count > 0 else { return }
        load()
        let key = dayKey(date)
        var day = contents.days[key, default: CommunityDayStats()]
        var uses = day.featureUses ?? [:]
        uses[feature, default: 0] += count
        day.featureUses = uses
        contents.days[key] = day
        scheduleSave()
    }

    func recordMemberJoin(at date: Date = Date()) {
        load()
        contents.days[dayKey(date), default: CommunityDayStats()].joins += 1
        scheduleSave()
    }

    func recordMemberLeave(at date: Date = Date()) {
        load()
        contents.days[dayKey(date), default: CommunityDayStats()].leaves += 1
        scheduleSave()
    }

    func recordRank(
        playerID: String,
        displayName: String,
        game: String,
        score: Int,
        rankName: String?,
        metrics: GameMetricSet = GameMetricSet(),
        at date: Date = Date()
    ) {
        load()
        guard score > 0 else { return }
        var series = contents.rankHistory[playerID] ?? CommunityRankSeries(displayName: displayName, game: game)
        series.displayName = displayName
        series.game = game
        let readings = Dictionary(uniqueKeysWithValues: metrics.presentMetrics.compactMap { metric in
            metrics[metric].map { (metric.rawValue, $0) }
        })
        // One reading per change: skip a check where nothing moved.
        let last = series.points.last
        if last?.score != score || (last?.metrics ?? [:]) != readings {
            series.points.append(CommunityRankPoint(
                date: date, score: score, rankName: rankName,
                metrics: readings.isEmpty ? nil : readings
            ))
            if series.points.count > maxRankPointsPerPlayer {
                series.points.removeFirst(series.points.count - maxRankPointsPerPlayer)
            }
        }
        contents.rankHistory[playerID] = series
        scheduleSave()
    }

    func recordSession(playerID: String, _ record: CommunitySessionRecord) {
        load()
        var sessions = contents.sessionHistory[playerID] ?? []
        sessions.append(record)
        if sessions.count > maxSessionsPerPlayer {
            sessions.removeFirst(sessions.count - maxSessionsPerPlayer)
        }
        contents.sessionHistory[playerID] = sessions
        recordFeatureUse("gametracker", at: record.endedAt)
    }

    // MARK: - Reading

    func summary(buckets: [AnalyticsBucket], in window: DateInterval) -> CommunityStatsSummary {
        load()
        var summary = CommunityStatsSummary(
            commandsPerBucket: Array(repeating: 0, count: buckets.count),
            joinsPerBucket: Array(repeating: 0, count: buckets.count),
            leavesPerBucket: Array(repeating: 0, count: buckets.count)
        )
        for (key, day) in contents.days {
            guard let date = Self.dayFormatter.date(from: key), date >= window.start, date <= window.end else { continue }
            (day.featureUses ?? [:]).forEach { summary.featureUses[$0.key, default: 0] += $0.value }
            summary.commandCount += day.commandCount
            summary.failedCommands += day.failedCommands
            summary.joins += day.joins
            summary.leaves += day.leaves
            day.commands.forEach { summary.commands[$0.key, default: 0] += $0.value }
            day.users.forEach { summary.users[$0.key, default: 0] += $0.value }
            day.channels.forEach { summary.channels[$0.key, default: 0] += $0.value }
            if let index = buckets.firstIndex(where: { $0.contains(date) }) {
                summary.commandsPerBucket[index] += day.commandCount
                summary.joinsPerBucket[index] += day.joins
                summary.leavesPerBucket[index] += day.leaves
            }
        }
        return summary
    }

    /// Rank readings since `start`, plus the latest earlier reading so a line
    /// can start at the left edge of the chart.
    func rankHistory(since start: Date) -> [String: CommunityRankSeries] {
        load()
        return contents.rankHistory.compactMapValues { series in
            let inWindow = series.points.filter { $0.date >= start }
            let lead = series.points.last { $0.date < start }
            let points = (lead.map { [$0] } ?? []) + inWindow
            guard !points.isEmpty else { return nil }
            var trimmed = series
            trimmed.points = points
            return trimmed
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        persist()
    }

    // MARK: - Private

    private func apply(command entry: CommandLogEntry) {
        var day = contents.days[dayKey(entry.time), default: CommunityDayStats()]
        let name = Self.commandName(entry.command)
        day.commandCount += 1
        if !entry.ok { day.failedCommands += 1 }
        day.commands[name, default: 0] += 1
        let user = entry.user.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty { day.users[user, default: 0] += 1 }
        let channel = entry.channel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !channel.isEmpty { day.channels["\(entry.server)|\(channel)", default: 0] += 1 }
        contents.days[dayKey(entry.time)] = day
    }

    static func commandName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Command" }
        return trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
    }

    private func dayKey(_ date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    /// Writes are batched: a busy server can log many commands a minute.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask = nil
        persist()
    }

    private func persist() {
        prune()
        guard let data = try? Self.encoder.encode(contents) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func prune() {
        guard let cutoff = calendar.date(byAdding: .day, value: -retainedDays, to: Date()) else { return }
        let cutoffKey = dayKey(cutoff)
        contents.days = contents.days.filter { $0.key >= cutoffKey }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
