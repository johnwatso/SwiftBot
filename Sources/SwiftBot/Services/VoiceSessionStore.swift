import Foundation

struct VoiceSession: Codable, Identifiable {
    var id: String
    let userId: String
    let username: String
    let guildId: String
    let channelId: String
    let channelName: String
    let joinedAt: Date
    var leftAt: Date?
    var durationSeconds: Int?

    init(userId: String, username: String, guildId: String, channelId: String, channelName: String, joinedAt: Date) {
        self.id = "\(guildId)-\(userId)-\(Int(joinedAt.timeIntervalSince1970))"
        self.userId = userId
        self.username = username
        self.guildId = guildId
        self.channelId = channelId
        self.channelName = channelName
        self.joinedAt = joinedAt
    }
}

struct VoiceUserRollingAverage: Codable, Hashable, Sendable {
    let userId: String
    let username: String
    let averageSecondsPerDay: Int
    let totalSeconds: Int
    let sessionCount: Int
}

/// Voice activity over an `AnalyticsPeriod`, for the Analytics page.
struct VoicePeriodReport: Sendable {
    struct Bucket: Sendable {
        let label: String
        let start: Date
        let sessions: Int
        let seconds: Int
    }
    struct UserTotal: Sendable {
        let userId: String
        let username: String
        let seconds: Int
        let sessions: Int
    }
    var buckets: [Bucket] = []
    var hourly: [Int] = Array(repeating: 0, count: 24)
    var topUsers: [UserTotal] = []
    var channels: [(name: String, seconds: Int)] = []
    var totalSeconds = 0
    var sessionCount = 0
    var previousTotalSeconds = 0
    var previousSessionCount = 0
    /// Longest run of consecutive days in voice that is still going.
    var currentStreak: (username: String, days: Int)?
}

struct VoiceUserReport: Sendable {
    var seconds = 0
    var sessions = 0
    var longestSessionSeconds = 0
    var favouriteChannel: String?
}

actor VoiceSessionStore {
    private let activeURL: URL
    private let historyURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Keyed by "guildId-userId"
    private var activeSessions: [String: VoiceSession] = [:]
    private var history: [VoiceSession] = []
    private var isLoaded = false
    private let maxHistoryCount = 10_000

    init(
        activeURL: URL = SwiftBotStorage.folderURL().appendingPathComponent(SwiftBotStorage.voiceActiveSessionsFileName),
        historyURL: URL = SwiftBotStorage.folderURL().appendingPathComponent(SwiftBotStorage.voiceSessionHistoryFileName)
    ) {
        self.activeURL = activeURL
        self.historyURL = historyURL
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    func load() {
        if let data = try? Data(contentsOf: activeURL),
           let sessions = try? decoder.decode([String: VoiceSession].self, from: data) {
            activeSessions = sessions
        }
        if let data = try? Data(contentsOf: historyURL),
           let hist = try? decoder.decode([VoiceSession].self, from: data) {
            history = hist
        }
        isLoaded = true
    }

    func waitForLoad() async {
        while !isLoaded {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }

    // MARK: - Session Recording

    func recordJoin(userId: String, username: String, guildId: String, channelId: String, channelName: String, at time: Date) {
        let key = sessionKey(guildId: guildId, userId: userId)
        activeSessions[key] = VoiceSession(
            userId: userId, username: username,
            guildId: guildId, channelId: channelId,
            channelName: channelName, joinedAt: time
        )
        persistActive()
    }

    @discardableResult
    func recordLeave(userId: String, guildId: String, at time: Date) -> VoiceSession? {
        let key = sessionKey(guildId: guildId, userId: userId)
        guard var session = activeSessions.removeValue(forKey: key) else { return nil }
        session.leftAt = time
        session.durationSeconds = Int(time.timeIntervalSince(session.joinedAt))
        history.append(session)
        trimHistory()
        persistActive()
        persistHistory()
        return session
    }

    func recordChannelSwitch(userId: String, username: String, guildId: String, newChannelId: String, newChannelName: String, at time: Date) {
        recordLeave(userId: userId, guildId: guildId, at: time)
        recordJoin(userId: userId, username: username, guildId: guildId, channelId: newChannelId, channelName: newChannelName, at: time)
    }

    /// Called after GUILD_CREATE to reconcile persisted sessions with Discord's actual voice state.
    func reconcileOnStartup(currentVoiceMembers: [VoiceMemberPresence], now: Date) {
        let activeKeys = Set(currentVoiceMembers.map { sessionKey(guildId: $0.guildId, userId: $0.userId) })

        // Sessions on disk but user no longer in voice → close them
        let stale = activeSessions.filter { !activeKeys.contains($0.key) }
        for (key, session) in stale {
            var completed = session
            completed.leftAt = now
            completed.durationSeconds = max(0, Int(now.timeIntervalSince(session.joinedAt)))
            activeSessions.removeValue(forKey: key)
            history.append(completed)
        }

        // Users in voice but not in active store → create session with startup time
        for member in currentVoiceMembers {
            let key = sessionKey(guildId: member.guildId, userId: member.userId)
            if activeSessions[key] == nil {
                activeSessions[key] = VoiceSession(
                    userId: member.userId, username: member.username,
                    guildId: member.guildId, channelId: member.channelId,
                    channelName: member.channelName, joinedAt: now
                )
            }
        }
        trimHistory()
        persistActive()
        persistHistory()
    }

    /// A member's sessions that started on or after `start`, plus any still
    /// running, oldest first. All servers when `guildId` is nil.
    func sessions(userId: String, guildId: String?, since start: Date) -> [VoiceSession] {
        allSessions()
            .filter { $0.userId == userId && (guildId == nil || $0.guildId == guildId) && ($0.joinedAt >= start || $0.leftAt == nil) }
            .sorted { $0.joinedAt < $1.joinedAt }
    }

    /// Sessions that overlap a window at all, including ones that started
    /// before it or are still running.
    func sessions(overlapping window: DateInterval, now: Date = Date()) -> [VoiceSession] {
        allSessions().filter { $0.joinedAt < window.end && ($0.leftAt ?? now) > window.start }
    }

    /// Every session that started on or after `start`, for server-wide patterns.
    func sessions(guildId: String?, since start: Date) -> [VoiceSession] {
        allSessions().filter { (guildId == nil || $0.guildId == guildId) && $0.joinedAt >= start }
    }

    /// Returns the persisted join date for a user if an active session exists.
    func persistedJoinDate(guildId: String, userId: String) -> Date? {
        activeSessions[sessionKey(guildId: guildId, userId: userId)]?.joinedAt
    }

    // MARK: - Analytics

    func getVoiceActivityLast7Days() -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let now = Date()
        let recentSessions = sessionsOverlappingLast7Days(relativeTo: now)
        return (0..<7).reversed().map { daysAgo in
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let startOfDay = calendar.startOfDay(for: day)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
            let count = recentSessions.filter { session in
                session.joinedAt < endOfDay && (session.leftAt ?? now) >= startOfDay
            }.count
            return (startOfDay, count)
        }
    }

    func getVoiceActivityByHour() -> [(hour: Int, count: Int)] {
        let calendar = Calendar.current
        var counts = [Int: Int]()
        for session in sessionsOverlappingLast7Days() {
            let hour = calendar.component(.hour, from: session.joinedAt)
            counts[hour, default: 0] += 1
        }
        return (0..<24).map { (hour: $0, count: counts[$0, default: 0]) }
    }

    func getTopVoiceUsers(limit: Int = 5, relativeTo now: Date = Date()) -> [(username: String, seconds: Int)] {
        var totals = [String: (username: String, seconds: Int)]()
        for contribution in voiceSessionContributionsLast7Days(relativeTo: now) {
            var current = totals[contribution.session.userId, default: (username: contribution.session.username, seconds: 0)]
            current.username = contribution.session.username
            current.seconds += contribution.seconds
            totals[contribution.session.userId] = current
        }
        return totals.values
            .sorted {
                if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
                return $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
            }
            .prefix(limit)
            .map { ($0.username, $0.seconds) }
    }

    func getTopVoiceUserRollingAveragesLast7Days(
        guildId: String? = nil,
        limit: Int = 5,
        relativeTo now: Date = Date()
    ) -> [VoiceUserRollingAverage] {
        var totals = [String: (username: String, seconds: Int, sessions: Int)]()
        for contribution in voiceSessionContributionsLast7Days(guildId: guildId, relativeTo: now) {
            let session = contribution.session
            if let guildId, session.guildId != guildId { continue }
            let duration = max(0, contribution.seconds)
            guard duration > 0 else { continue }
            var current = totals[session.userId, default: (username: session.username, seconds: 0, sessions: 0)]
            current.username = session.username
            current.seconds += duration
            current.sessions += 1
            totals[session.userId] = current
        }

        let ranked = totals
            .map { userId, value in
                VoiceUserRollingAverage(
                    userId: userId,
                    username: value.username,
                    averageSecondsPerDay: Int((Double(value.seconds) / 7.0).rounded()),
                    totalSeconds: value.seconds,
                    sessionCount: value.sessions
                )
            }
            .filter { $0.averageSecondsPerDay > 0 }
            .sorted {
                if $0.totalSeconds != $1.totalSeconds {
                    return $0.totalSeconds > $1.totalSeconds
                }
                return $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
            }

        return Array(ranked.prefix(max(0, limit)))
    }

    func getTopUserStreakLast7Days() -> (username: String, days: Int)? {
        let calendar = Calendar.current
        let recentSessions = sessionsOverlappingLast7Days()
        let groupedDays = Dictionary(grouping: recentSessions, by: \.username).mapValues { sessions in
            Set(sessions.map { calendar.startOfDay(for: $0.joinedAt) })
        }

        let ranked = groupedDays.compactMap { username, days -> (username: String, days: Int)? in
            let streak = currentDayStreak(from: days, calendar: calendar)
            guard streak > 0 else { return nil }
            return (username, streak)
        }
        .sorted {
            if $0.days != $1.days { return $0.days > $1.days }
            return $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
        }

        return ranked.first
    }

    func getMostActiveDay() -> String? {
        let calendar = Calendar.current
        var counts = [Int: Int]()
        for session in history {
            let weekday = calendar.component(.weekday, from: session.joinedAt)
            counts[weekday, default: 0] += 1
        }
        guard let maxWeekday = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return calendar.weekdaySymbols[maxWeekday - 1]
    }

    func getTotalVoiceTimeThisWeek() -> TimeInterval {
        return TimeInterval(
            voiceSessionContributionsLast7Days()
                .map(\.seconds)
                .reduce(0, +)
        )
    }

    func getSessionCountThisWeek() -> Int {
        sessionsOverlappingLast7Days().count
    }

    func report(period: AnalyticsPeriod, now: Date = Date(), topLimit: Int = 5) -> VoicePeriodReport {
        report(
            window: period.window(now: now),
            buckets: period.buckets(now: now),
            previous: period.previousWindow(now: now),
            now: now,
            topLimit: topLimit
        )
    }

    /// Voice activity over any window (Analytics periods, Replay months and
    /// years), optionally limited to one guild and leaving out some users.
    func report(
        window: DateInterval,
        buckets: [AnalyticsBucket],
        previous: DateInterval?,
        guildId: String? = nil,
        excludingUsers excluded: Set<String> = [],
        now: Date = Date(),
        topLimit: Int = 5
    ) -> VoicePeriodReport {
        let calendar = Calendar.current
        let sessions = allSessions().filter { session in
            (guildId == nil || session.guildId == guildId) && !excluded.contains(session.userId)
        }

        // Seconds a session spent inside [start, end).
        func overlap(_ session: VoiceSession, _ start: Date, _ end: Date) -> Int {
            let from = max(session.joinedAt, start)
            let to = min(session.leftAt ?? now, end, now)
            return max(0, Int(to.timeIntervalSince(from)))
        }

        var report = VoicePeriodReport()
        var users: [String: (username: String, seconds: Int, sessions: Int)] = [:]
        var channels: [String: Int] = [:]
        var bucketSessions = Array(repeating: 0, count: buckets.count)
        var bucketSeconds = Array(repeating: 0, count: buckets.count)

        for session in sessions {
            let inWindow = overlap(session, window.start, window.end)
            if inWindow > 0 {
                report.totalSeconds += inWindow
                report.sessionCount += 1
                report.hourly[calendar.component(.hour, from: max(session.joinedAt, window.start))] += 1
                var user = users[session.userId, default: (session.username, 0, 0)]
                user.username = session.username
                user.seconds += inWindow
                user.sessions += 1
                users[session.userId] = user
                if !session.channelName.isEmpty { channels[session.channelName, default: 0] += inWindow }
                for (index, bucket) in buckets.enumerated() {
                    let seconds = overlap(session, bucket.start, bucket.end)
                    guard seconds > 0 else { continue }
                    bucketSessions[index] += 1
                    bucketSeconds[index] += seconds
                }
            }
            let inPrevious = previous.map { overlap(session, $0.start, $0.end) } ?? 0
            if inPrevious > 0 {
                report.previousTotalSeconds += inPrevious
                report.previousSessionCount += 1
            }
        }

        report.buckets = buckets.enumerated().map { index, bucket in
            .init(label: bucket.label, start: bucket.start, sessions: bucketSessions[index], seconds: bucketSeconds[index])
        }
        report.topUsers = users
            .map { .init(userId: $0.key, username: $0.value.username, seconds: $0.value.seconds, sessions: $0.value.sessions) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.username < $1.username }
            .prefix(topLimit)
            .map { $0 }
        report.channels = channels
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(topLimit)
            .map { (name: $0.key, seconds: $0.value) }

        // Streaks look at all history, not just the window.
        let daysByUser = Dictionary(grouping: sessions, by: \.username).mapValues { list in
            Set(list.map { calendar.startOfDay(for: $0.joinedAt) })
        }
        report.currentStreak = daysByUser
            .compactMap { name, days -> (username: String, days: Int)? in
                let streak = currentDayStreak(from: days, calendar: calendar)
                return streak > 1 ? (name, streak) : nil
            }
            .max { $0.days != $1.days ? $0.days < $1.days : $0.username > $1.username }
        return report
    }

    /// One member's voice time over a window, for Personal Replay.
    func userReport(userId: String, guildId: String?, window: DateInterval, now: Date = Date()) -> VoiceUserReport {
        var report = VoiceUserReport()
        var channels: [String: Int] = [:]
        for session in allSessions() where session.userId == userId && (guildId == nil || session.guildId == guildId) {
            let from = max(session.joinedAt, window.start)
            let to = min(session.leftAt ?? now, window.end, now)
            let seconds = max(0, Int(to.timeIntervalSince(from)))
            guard seconds > 0 else { continue }
            report.seconds += seconds
            report.sessions += 1
            report.longestSessionSeconds = max(report.longestSessionSeconds, seconds)
            if !session.channelName.isEmpty { channels[session.channelName, default: 0] += seconds }
        }
        report.favouriteChannel = channels.max { $0.value < $1.value }?.key
        return report
    }

    // MARK: - Private

    private func sessionKey(guildId: String, userId: String) -> String {
        "\(guildId)-\(userId)"
    }

    private func sessionsOverlappingLast7Days(relativeTo now: Date = Date()) -> [VoiceSession] {
        let windowStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        return allSessions().filter { session in
            session.joinedAt <= now && (session.leftAt ?? now) >= windowStart
        }
    }

    private func voiceSessionContributionsLast7Days(
        guildId: String? = nil,
        relativeTo now: Date = Date()
    ) -> [(session: VoiceSession, seconds: Int)] {
        let windowStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        return allSessions().compactMap { session in
            if let guildId, session.guildId != guildId { return nil }
            let end = min(session.leftAt ?? now, now)
            let start = max(session.joinedAt, windowStart)
            let seconds = max(0, Int(end.timeIntervalSince(start)))
            guard seconds > 0 else { return nil }
            return (session, seconds)
        }
    }

    private func allSessions() -> [VoiceSession] {
        history + Array(activeSessions.values)
    }

    private func currentDayStreak(from activeDays: Set<Date>, calendar: Calendar) -> Int {
        guard !activeDays.isEmpty else { return 0 }
        var streak = 0
        var day = calendar.startOfDay(for: Date())

        while activeDays.contains(day) {
            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previousDay
        }

        return streak
    }

    private func trimHistory() {
        if history.count > maxHistoryCount {
            history.removeFirst(history.count - maxHistoryCount)
        }
    }

    private func persistActive() {
        try? encoder.encode(activeSessions).write(to: activeURL, options: .atomic)
    }

    private func persistHistory() {
        try? encoder.encode(history).write(to: historyURL, options: .atomic)
    }
}
