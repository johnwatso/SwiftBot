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

    init() {
        let folder = SwiftBotStorage.folderURL()
        self.activeURL = folder.appendingPathComponent(SwiftBotStorage.voiceActiveSessionsFileName)
        self.historyURL = folder.appendingPathComponent(SwiftBotStorage.voiceSessionHistoryFileName)
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

    /// Returns the persisted join date for a user if an active session exists.
    func persistedJoinDate(guildId: String, userId: String) -> Date? {
        activeSessions[sessionKey(guildId: guildId, userId: userId)]?.joinedAt
    }

    // MARK: - Analytics

    func getVoiceActivityLast7Days() -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let now = Date()
        return (0..<7).reversed().map { daysAgo in
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let startOfDay = calendar.startOfDay(for: day)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
            let count = history.filter { $0.joinedAt >= startOfDay && $0.joinedAt < endOfDay }.count
            return (startOfDay, count)
        }
    }

    func getVoiceActivityByHour() -> [(hour: Int, count: Int)] {
        let calendar = Calendar.current
        var counts = [Int: Int]()
        for session in history {
            let hour = calendar.component(.hour, from: session.joinedAt)
            counts[hour, default: 0] += 1
        }
        return (0..<24).map { (hour: $0, count: counts[$0, default: 0]) }
    }

    func getTopVoiceUsers(limit: Int = 5) -> [(username: String, seconds: Int)] {
        var totals = [String: Int]()
        for session in history {
            totals[session.username, default: 0] += session.durationSeconds ?? 0
        }
        return totals.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
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
        let calendar = Calendar.current
        let now = Date()
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        return TimeInterval(
            history
                .filter { $0.joinedAt >= startOfWeek }
                .compactMap { $0.durationSeconds }
                .reduce(0, +)
        )
    }

    func getSessionCountThisWeek() -> Int {
        let calendar = Calendar.current
        let now = Date()
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        return history.filter { $0.joinedAt >= startOfWeek }.count
    }

    // MARK: - Private

    private func sessionKey(guildId: String, userId: String) -> String {
        "\(guildId)-\(userId)"
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
