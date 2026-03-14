import Foundation

// MARK: - Help Engine Settings

enum HelpMode: String, Codable, CaseIterable, Identifiable {
    case classic = "Classic"
    case smart   = "Smart"
    case hybrid  = "Hybrid"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .classic: return "Plain structured text — no AI."
        case .smart:   return "AI rewrites the response. Falls back to Classic if unavailable."
        case .hybrid:  return "AI on first attempt; Classic on failure."
        }
    }
}

enum HelpTone: String, Codable, CaseIterable, Identifiable {
    case concise  = "Concise"
    case friendly = "Friendly"
    case detailed = "Detailed"

    var id: String { rawValue }
}

struct HelpSettings: Codable, Hashable {
    var mode: HelpMode = .classic
    var tone: HelpTone = .concise
    var customIntro: String = ""
    var customFooter: String = ""
    var showAdvanced: Bool = false
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case appleIntelligence = "Apple Intelligence"
    case ollama = "Ollama"
    case openAI = "OpenAI (ChatGPT)"

    var id: String { rawValue }
}

enum AIProviderPreference: String, Codable, CaseIterable, Identifiable {
    case apple = "Apple Intelligence"
    case ollama = "Ollama"
    case openAI = "OpenAI (ChatGPT)"

    var id: String { rawValue }
}

enum MessageRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case system
}

struct AIMemoryNote: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let createdByUserID: String
    let createdByUsername: String
    let text: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        createdByUserID: String,
        createdByUsername: String,
        text: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.createdByUserID = createdByUserID
        self.createdByUsername = createdByUsername
        self.text = text
    }
}

enum MemoryScopeType: String, Codable, Hashable, Sendable {
    case guildTextChannel
    case directMessageUser
}

struct MemoryScope: Hashable, Codable, Sendable {
    let id: String
    let type: MemoryScopeType

    static func guildTextChannel(_ channelID: String) -> MemoryScope {
        MemoryScope(id: channelID, type: .guildTextChannel)
    }

    static func directMessageUser(_ userID: String) -> MemoryScope {
        MemoryScope(id: userID, type: .directMessageUser)
    }
}

struct Message: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let channelID: String
    let userID: String
    let username: String
    let content: String
    let timestamp: Date
    let role: MessageRole

    init(
        id: String = UUID().uuidString,
        channelID: String,
        userID: String,
        username: String,
        content: String,
        timestamp: Date = Date(),
        role: MessageRole
    ) {
        self.id = id
        self.channelID = channelID
        self.userID = userID
        self.username = username
        self.content = content
        self.timestamp = timestamp
        self.role = role
    }
}

struct MemorySummary: Identifiable, Hashable, Sendable {
    let scope: MemoryScope
    let messageCount: Int
    let lastMessageAt: Date?

    var id: String { "\(scope.type.rawValue):\(scope.id)" }
}

struct MemoryRecord: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let scope: MemoryScope
    let userID: String
    let content: String
    let timestamp: Date
    let role: MessageRole
}

actor ConversationStore {
    private var messagesByScope: [MemoryScope: [MemoryRecord]] = [:]
    private var updateContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    var updates: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            updateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeUpdateContinuation(id) }
            }
        }
    }

    func append(_ message: Message) {
        let scope = MemoryScope.guildTextChannel(message.channelID)
        let record = MemoryRecord(
            id: message.id,
            scope: scope,
            userID: message.userID,
            content: message.content,
            timestamp: message.timestamp,
            role: message.role
        )
        messagesByScope[scope, default: []].append(record)
        emitUpdate()
    }

    func append(_ messages: [Message]) {
        guard !messages.isEmpty else { return }
        for message in messages {
            let scope = MemoryScope.guildTextChannel(message.channelID)
            let record = MemoryRecord(
                id: message.id,
                scope: scope,
                userID: message.userID,
                content: message.content,
                timestamp: message.timestamp,
                role: message.role
            )
            messagesByScope[scope, default: []].append(record)
        }
        emitUpdate()
    }

    func append(
        scope: MemoryScope,
        messageID: String = UUID().uuidString,
        userID: String,
        content: String,
        timestamp: Date = Date(),
        role: MessageRole
    ) {
        let record = MemoryRecord(
            id: messageID,
            scope: scope,
            userID: userID,
            content: content,
            timestamp: timestamp,
            role: role
        )
        messagesByScope[scope, default: []].append(record)
        emitUpdate()
    }

    func messages(in scope: MemoryScope) -> [MemoryRecord] {
        messagesByScope[scope] ?? []
    }

    func allMessages() -> [MemoryRecord] {
        messagesByScope.values.flatMap { $0 }
    }

    func clear(scope: MemoryScope) {
        messagesByScope.removeValue(forKey: scope)
        emitUpdate()
    }

    func clearAll() {
        messagesByScope.removeAll()
        emitUpdate()
    }

    func summaries() -> [MemorySummary] {
        messagesByScope.map { scope, records in
            MemorySummary(
                scope: scope,
                messageCount: records.count,
                lastMessageAt: records.max(by: { $0.timestamp < $1.timestamp })?.timestamp
            )
        }
    }

    func allRecordsSorted() -> [MemoryRecord] {
        allMessages().sorted { $0.timestamp < $1.timestamp }
    }

    func recordsSince(fromRecordID: String?, limit: Int) -> (records: [MemoryRecord], hasMore: Bool) {
        let all = allRecordsSorted()
        guard let fromRecordID else {
            return (Array(all.prefix(limit)), all.count > limit)
        }
        guard let startIndex = all.firstIndex(where: { $0.id > fromRecordID }) else {
            return ([], false)
        }
        let remaining = Array(all[startIndex...])
        return (Array(remaining.prefix(limit)), remaining.count > limit)
    }

    func appendIfNotExists(_ message: Message) {
        let scope = MemoryScope.guildTextChannel(message.channelID)
        let existing = messagesByScope[scope] ?? []
        guard !existing.contains(where: { $0.id == message.id }) else { return }
        append(message)
    }

    func appendIfNotExists(
        scope: MemoryScope,
        messageID: String,
        userID: String,
        content: String,
        role: MessageRole,
        timestamp: Date
    ) {
        let existing = messagesByScope[scope] ?? []
        guard !existing.contains(where: { $0.id == messageID }) else { return }
        append(scope: scope, messageID: messageID, userID: userID, content: content, timestamp: timestamp, role: role)
    }

    func recentMessages(in scope: MemoryScope, limit: Int) -> [MemoryRecord] {
        let messages = messagesByScope[scope] ?? []
        return messages.sorted { $0.timestamp > $1.timestamp }.prefix(limit).map { $0 }
    }

    private func emitUpdate() {
        for continuation in updateContinuations.values {
            continuation.yield()
        }
    }

    private func removeUpdateContinuation(_ id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }
}

// MARK: - Wiki Context Cache

struct WikiContextEntry: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let sourceName: String
    let query: String
    let title: String
    let extract: String
    let url: String
    let cachedAt: Date
}

actor WikiContextCache {
    private var entries: [WikiContextEntry] = []
    private let maxEntries = 120

    func store(sourceName: String, query: String, result: FinalsWikiLookupResult) {
        let key = normalizedKey(sourceName) + "|" + normalizedKey(result.title)
        let entry = WikiContextEntry(
            id: key,
            sourceName: sourceName,
            query: query,
            title: result.title,
            extract: result.extract,
            url: result.url,
            cachedAt: Date()
        )

        upsertEntry(entry)
    }

    func upsertEntry(_ entry: WikiContextEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    func contextEntries(for prompt: String, limit: Int = 3) -> [WikiContextEntry] {
        let tokens = promptTokens(prompt)
        let now = Date()
        let freshnessCutoff = now.addingTimeInterval(-(60 * 60 * 24 * 7))
        let candidates = entries.filter { $0.cachedAt >= freshnessCutoff }
        guard !candidates.isEmpty else { return [] }

        let scored: [(WikiContextEntry, Int)] = candidates.map { entry in
            let haystack = [
                normalizedKey(entry.sourceName),
                normalizedKey(entry.query),
                normalizedKey(entry.title),
                normalizedKey(entry.extract)
            ].joined(separator: " ")

            let score = tokens.reduce(0) { partial, token in
                partial + (haystack.contains(token) ? 1 : 0)
            }
            return (entry, score)
        }

        let matched = scored
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.cachedAt > rhs.0.cachedAt
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)

        if !matched.isEmpty {
            return Array(matched.prefix(limit))
        }

        return Array(candidates.prefix(limit))
    }

    func allEntries() -> [WikiContextEntry] {
        entries
    }

    private func promptTokens(_ raw: String) -> [String] {
        raw
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    private func normalizedKey(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
