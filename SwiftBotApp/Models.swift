import Combine
import Foundation
import Combine
import Network

// MARK: - EventBus System

/// A marker protocol for events that can be published and subscribed through `EventBus`.
protocol Event {}

/// A token representing a subscription to an event.
/// Use this token to unsubscribe from the event.
struct SubscriptionToken: Hashable, Identifiable {
    let id: UUID
    init() {
        self.id = UUID()
    }
}

/// A thread-safe event bus supporting typed publish/subscribe with async handlers.
final class EventBus {
    private actor Storage {
        private var subscribers: [ObjectIdentifier: [SubscriptionToken: (Any) async -> Void]] = [:]
        
        func add(type: ObjectIdentifier, token: SubscriptionToken, handler: @escaping (Any) async -> Void) {
            if subscribers[type] != nil {
                subscribers[type]![token] = handler
            } else {
                subscribers[type] = [token: handler]
            }
        }
        
        func remove(token: SubscriptionToken) {
            for (key, var dict) in subscribers {
                dict[token] = nil
                if dict.isEmpty {
                    subscribers[key] = nil
                } else {
                    subscribers[key] = dict
                }
            }
        }
        
        func snapshotHandlers(for type: ObjectIdentifier) -> [(Any) async -> Void] {
            guard let dict = subscribers[type] else { return [] }
            return Array(dict.values)
        }
    }
    
    private let storage = Storage()
    
    /// Subscribes to events of the specified type.
    @discardableResult
    func subscribe<E: Event>(_ type: E.Type, handler: @escaping (E) async -> Void) -> SubscriptionToken {
        let token = SubscriptionToken()
        let wrappedHandler: (Any) async -> Void = { anyEvent in
            guard let event = anyEvent as? E else { return }
            await handler(event)
        }
        Task {
            await storage.add(type: ObjectIdentifier(type), token: token, handler: wrappedHandler)
        }
        return token
    }
    
    /// Unsubscribes from an event using the given subscription token.
    func unsubscribe(_ token: SubscriptionToken) {
        Task {
            await storage.remove(token: token)
        }
    }
    
    /// Publishes an event to all subscribers of its type.
    func publish<E: Event>(_ event: E) async {
        let handlers = await storage.snapshotHandlers(for: ObjectIdentifier(E.self))
        for handler in handlers {
            await handler(event)
        }
    }
}

/// An event signaling a user has joined a voice channel.
struct VoiceJoined: Event {
    let guildId: String
    let userId: String
    let username: String
    let channelId: String
    
    init(guildId: String, userId: String, username: String, channelId: String) {
        self.guildId = guildId
        self.userId = userId
        self.username = username
        self.channelId = channelId
    }
}

/// An event signaling a user has left a voice channel.
struct VoiceLeft: Event {
    let guildId: String
    let userId: String
    let username: String
    let channelId: String
    let durationSeconds: Int
    
    init(guildId: String, userId: String, username: String, channelId: String, durationSeconds: Int) {
        self.guildId = guildId
        self.userId = userId
        self.username = username
        self.channelId = channelId
        self.durationSeconds = durationSeconds
    }
}

/// An event signaling that a message was received.
struct MessageReceived: Event {
    let guildId: String?
    let channelId: String
    let userId: String
    let username: String
    let content: String
    let isDirectMessage: Bool
    
    init(guildId: String?, channelId: String, userId: String, username: String, content: String, isDirectMessage: Bool) {
        self.guildId = guildId
        self.channelId = channelId
        self.userId = userId
        self.username = username
        self.content = content
        self.isDirectMessage = isDirectMessage
    }
}

// MARK: - Core Models

struct GuildSettings: Codable, Hashable {
    var notificationChannelId: String?
    var ignoredVoiceChannelIds: Set<String> = []
    var monitoredVoiceChannelIds: Set<String> = []
    var notifyOnJoin: Bool = true
    var notifyOnLeave: Bool = true
    var notifyOnMove: Bool = true
    var joinNotificationTemplate: String = "🔊 <@{userId}> connected to <#{channelId}>"
    var leaveNotificationTemplate: String = "🔌 <@{userId}> disconnected from <#{channelId}>"
    var moveNotificationTemplate: String = "🔁 <@{userId}> switched voice channels: <#{fromChannelId}> → <#{toChannelId}>"
}

struct BotSettings: Codable, Hashable {
    var token: String = ""
    var prefix: String = "!"
    var autoStart: Bool = false
    var guildSettings: [String: GuildSettings] = [:]
    var clusterMode: ClusterMode = .standalone
    var clusterNodeName: String = Host.current().localizedName ?? "SwiftBot Node"
    var clusterWorkerBaseURL: String = ""
    var clusterListenPort: Int = 38787

    // Local AI reply settings for DMs and guild mentions.
    var localAIDMReplyEnabled: Bool = false
    var localAIProvider: AIProvider = .appleIntelligence
    var preferredAIProvider: AIProviderPreference = .apple
    var localAIEndpoint: String = "http://127.0.0.1:1234/v1/chat/completions"
    var localAIModel: String = "local-model"
    var ollamaBaseURL: String = "http://localhost:11434"
    var localAISystemPrompt: String = "You are a friendly Discord assistant. Reply briefly and naturally."
    var behavior = BotBehaviorSettings()
    var wikiBot = WikiBotSettings()
    var patchy = PatchySettings()

    private enum CodingKeys: String, CodingKey {
        case token
        case prefix
        case autoStart
        case guildSettings
        case clusterMode
        case clusterNodeName
        case clusterWorkerBaseURL
        case clusterListenPort
        case localAIDMReplyEnabled
        case localAIProvider
        case preferredAIProvider
        case localAIEndpoint
        case localAIModel
        case ollamaBaseURL
        case localAISystemPrompt
        case behavior
        case wikiBot
        case patchy
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? "!"
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        guildSettings = try container.decodeIfPresent([String: GuildSettings].self, forKey: .guildSettings) ?? [:]
        clusterMode = try container.decodeIfPresent(ClusterMode.self, forKey: .clusterMode) ?? .standalone
        clusterNodeName = try container.decodeIfPresent(String.self, forKey: .clusterNodeName) ?? (Host.current().localizedName ?? "SwiftBot Node")
        clusterWorkerBaseURL = try container.decodeIfPresent(String.self, forKey: .clusterWorkerBaseURL) ?? ""
        clusterListenPort = try container.decodeIfPresent(Int.self, forKey: .clusterListenPort) ?? 38787
        localAIDMReplyEnabled = try container.decodeIfPresent(Bool.self, forKey: .localAIDMReplyEnabled) ?? false
        localAIProvider = try container.decodeIfPresent(AIProvider.self, forKey: .localAIProvider) ?? .appleIntelligence
        preferredAIProvider = try container.decodeIfPresent(AIProviderPreference.self, forKey: .preferredAIProvider) ?? .apple
        localAIEndpoint = try container.decodeIfPresent(String.self, forKey: .localAIEndpoint) ?? "http://127.0.0.1:1234/v1/chat/completions"
        localAIModel = try container.decodeIfPresent(String.self, forKey: .localAIModel) ?? "local-model"
        ollamaBaseURL = try container.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://localhost:11434"
        localAISystemPrompt = try container.decodeIfPresent(String.self, forKey: .localAISystemPrompt) ?? "You are a friendly Discord assistant. Reply briefly and naturally."
        behavior = try container.decodeIfPresent(BotBehaviorSettings.self, forKey: .behavior) ?? BotBehaviorSettings()
        wikiBot = try container.decodeIfPresent(WikiBotSettings.self, forKey: .wikiBot) ?? WikiBotSettings()
        patchy = try container.decodeIfPresent(PatchySettings.self, forKey: .patchy) ?? PatchySettings()
    }
}

struct BotBehaviorSettings: Codable, Hashable {
    var allowDMs: Bool = false
    var useAIInGuildChannels: Bool = true
}

enum WikiBridgeSourceKind: String, Codable, CaseIterable, Identifiable {
    case finals = "THE FINALS"
    case mediaWiki = "MediaWiki"

    var id: String { rawValue }
}

struct WikiBridgeSourceTarget: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var isEnabled: Bool = true
    var name: String = "THE FINALS Wiki"
    var kind: WikiBridgeSourceKind = .finals
    var baseURL: String = "https://www.thefinals.wiki"
    var apiPath: String = "/api.php"
    var lastLookupAt: Date?
    var lastStatus: String = "Never used"

    static func defaultFinals() -> WikiBridgeSourceTarget {
        WikiBridgeSourceTarget(
            id: UUID(),
            isEnabled: true,
            name: "THE FINALS Wiki",
            kind: .finals,
            baseURL: "https://www.thefinals.wiki",
            apiPath: "/api.php",
            lastLookupAt: nil,
            lastStatus: "Ready"
        )
    }
}

struct WikiBotSettings: Codable, Hashable {
    var isEnabled: Bool = true
    var allowFinalsCommand: Bool = true
    var allowWikiAlias: Bool = true
    var allowWeaponCommand: Bool = true
    var includeWeaponStats: Bool = true
    var sourceTargets: [WikiBridgeSourceTarget] = []
    var defaultSourceID: UUID?

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case allowFinalsCommand
        case allowWikiAlias
        case allowWeaponCommand
        case includeWeaponStats
        case sourceTargets
        case defaultSourceID
    }

    init() {
        let defaultTarget = WikiBridgeSourceTarget.defaultFinals()
        sourceTargets = [defaultTarget]
        defaultSourceID = defaultTarget.id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        allowFinalsCommand = try container.decodeIfPresent(Bool.self, forKey: .allowFinalsCommand) ?? true
        allowWikiAlias = try container.decodeIfPresent(Bool.self, forKey: .allowWikiAlias) ?? true
        allowWeaponCommand = try container.decodeIfPresent(Bool.self, forKey: .allowWeaponCommand) ?? true
        includeWeaponStats = try container.decodeIfPresent(Bool.self, forKey: .includeWeaponStats) ?? true
        sourceTargets = try container.decodeIfPresent([WikiBridgeSourceTarget].self, forKey: .sourceTargets) ?? []
        defaultSourceID = try container.decodeIfPresent(UUID.self, forKey: .defaultSourceID)
        normalizeSources()
    }

    mutating func normalizeSources() {
        if sourceTargets.isEmpty {
            let defaultTarget = WikiBridgeSourceTarget.defaultFinals()
            sourceTargets = [defaultTarget]
            defaultSourceID = defaultTarget.id
            return
        }

        if let defaultSourceID,
           sourceTargets.contains(where: { $0.id == defaultSourceID }) {
            return
        }

        if let firstEnabled = sourceTargets.first(where: { $0.isEnabled }) {
            defaultSourceID = firstEnabled.id
        } else {
            defaultSourceID = sourceTargets.first?.id
        }
    }

    func defaultSource() -> WikiBridgeSourceTarget? {
        if let defaultSourceID,
           let explicit = sourceTargets.first(where: { $0.id == defaultSourceID }) {
            return explicit
        }
        if let firstEnabled = sourceTargets.first(where: { $0.isEnabled }) {
            return firstEnabled
        }
        return sourceTargets.first
    }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case appleIntelligence = "Apple Intelligence"
    case ollama = "Ollama"

    var id: String { rawValue }
}

enum AIProviderPreference: String, Codable, CaseIterable, Identifiable {
    case apple = "Apple Intelligence"
    case ollama = "Ollama"

    var id: String { rawValue }
}

enum MessageRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case system
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

struct MemoryRecord: Identifiable, Hashable, Sendable {
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

    func messages(for scope: MemoryScope) -> [MemoryRecord] {
        messagesByScope[scope] ?? []
    }

    func recentMessages(for scope: MemoryScope, limit: Int) -> [MemoryRecord] {
        guard limit > 0 else { return [] }
        let scopedMessages = messagesByScope[scope] ?? []
        return Array(scopedMessages.suffix(limit))
    }

    func messages(for channelID: String) -> [MemoryRecord] {
        messages(for: .guildTextChannel(channelID))
    }

    func recentMessages(for channelID: String, limit: Int) -> [MemoryRecord] {
        recentMessages(for: .guildTextChannel(channelID), limit: limit)
    }

    func summaries() -> [MemorySummary] {
        messagesByScope.map { scope, messages in
            MemorySummary(
                scope: scope,
                messageCount: messages.count,
                lastMessageAt: messages.last?.timestamp
            )
        }
        .sorted { lhs, rhs in
            if lhs.messageCount != rhs.messageCount {
                return lhs.messageCount > rhs.messageCount
            }
            if lhs.lastMessageAt != rhs.lastMessageAt {
                switch (lhs.lastMessageAt, rhs.lastMessageAt) {
                case let (left?, right?):
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
            }
            if lhs.scope.type != rhs.scope.type {
                return lhs.scope.type.rawValue < rhs.scope.type.rawValue
            }
            return lhs.scope.id < rhs.scope.id
        }
    }

    func clear(scope: MemoryScope) {
        guard messagesByScope[scope] != nil else { return }
        messagesByScope.removeValue(forKey: scope)
        emitUpdate()
    }

    func clear(channelID: String) {
        clear(scope: .guildTextChannel(channelID))
    }

    func clearAll() {
        guard !messagesByScope.isEmpty else { return }
        messagesByScope.removeAll()
        emitUpdate()
    }

    private func emitUpdate() {
        for continuation in updateContinuations.values {
            continuation.yield(())
        }
    }

    private func removeUpdateContinuation(_ id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }
}

struct WikiContextEntry: Identifiable, Hashable, Sendable {
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

        entries.removeAll { $0.id == key }
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

enum PatchySourceKind: String, Codable, CaseIterable, Identifiable {
    case nvidia = "NVIDIA"
    case amd = "AMD"
    case intel = "Intel Arc"
    case steam = "Steam"

    var id: String { rawValue }
}

struct PatchyDeliveryTarget: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var isEnabled: Bool = true
    var name: String = "Target"
    var serverId: String = ""
    var channelId: String = ""
    var roleIDs: [String] = []
}

struct PatchySourceTarget: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var isEnabled: Bool = true
    var source: PatchySourceKind = .nvidia
    var steamAppID: String = "570"
    var serverId: String = ""
    var channelId: String = ""
    var roleIDs: [String] = []
    var lastCheckedAt: Date?
    var lastRunAt: Date?
    var lastStatus: String = "Never checked"
}

struct PatchySettings: Codable, Hashable {
    var monitoringEnabled: Bool = false
    var showDebug: Bool = false
    var sourceTargets: [PatchySourceTarget] = []
    var steamAppNames: [String: String] = [:]

    // Legacy fields kept for migration compatibility.
    var source: PatchySourceKind = .nvidia
    var steamAppID: String = "570"
    var saveAfterFetch: Bool = true
    var targets: [PatchyDeliveryTarget] = []
}

enum ClusterMode: String, Codable, CaseIterable, Identifiable {
    case standalone = "Standalone"
    case leader = "Leader"
    case worker = "Worker"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .standalone:
            return "Runs Discord and heavy tasks locally."
        case .leader:
            return "Owns Discord traffic and can offload heavy work to a worker."
        case .worker:
            return "Runs job services only. No Discord connection."
        }
    }
}

enum ClusterConnectionState: String {
    case inactive
    case starting
    case listening
    case connected
    case degraded
    case stopped
    case failed
}

enum ClusterJobRoute: String {
    case local
    case remote
    case unavailable
}

struct ClusterSnapshot: Hashable {
    var mode: ClusterMode = .standalone
    var nodeName: String = Host.current().localizedName ?? "SwiftBot Node"
    var listenPort: Int = 38787
    var workerBaseURL: String = ""
    var serverState: ClusterConnectionState = .inactive
    var workerState: ClusterConnectionState = .inactive
    var serverStatusText: String = "Disabled"
    var workerStatusText: String = "Local only"
    var lastJobRoute: ClusterJobRoute = .local
    var lastJobSummary: String = "No remote jobs yet"
    var lastJobNode: String = Host.current().localizedName ?? "SwiftBot Node"
    var diagnostics: String = "No diagnostics yet"
}

enum BotStatus: String {
    case stopped
    case connecting
    case running
    case reconnecting
}

struct StatCounter {
    var commandsRun = 0
    var voiceJoins = 0
    var voiceLeaves = 0
    var errors = 0
}

struct ActivityEvent: Identifiable, Hashable {
    enum Kind: String {
        case voiceJoin
        case voiceLeave
        case voiceMove
        case command
        case info
        case warning
        case error
    }

    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let message: String
}

struct CommandLogEntry: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let user: String
    let server: String
    let command: String
    let channel: String
    let executionRoute: String
    let executionNode: String
    let ok: Bool
}

struct VoiceMemberPresence: Identifiable, Hashable {
    let id: String
    let userId: String
    let username: String
    let guildId: String
    let channelId: String
    let channelName: String
    let joinedAt: Date
}

struct VoiceEventLogEntry: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let description: String
}

struct FinalsWikiLookupResult: Codable, Hashable {
    let title: String
    let extract: String
    let url: String
    let weaponStats: FinalsWeaponStats?
}

struct FinalsWeaponStats: Codable, Hashable {
    let type: String?
    let bodyDamage: String?
    let headshotDamage: String?
    let fireRate: String?
    let dropoffStart: String?
    let dropoffEnd: String?
    let minimumDamage: String?
    let magazineSize: String?
    let shortReload: String?
    let longReload: String?
}

struct GuildVoiceChannel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
}

struct GuildTextChannel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
}

struct GuildRole: Identifiable, Hashable, Codable {
    let id: String
    let name: String
}

struct DiscordCacheSnapshot: Codable, Hashable {
    var updatedAt: Date = Date()
    var connectedServers: [String: String] = [:]
    var availableVoiceChannelsByServer: [String: [GuildVoiceChannel]] = [:]
    var availableTextChannelsByServer: [String: [GuildTextChannel]] = [:]
    var availableRolesByServer: [String: [GuildRole]] = [:]
    var usernamesById: [String: String] = [:]
    var channelTypesById: [String: Int] = [:]

    private enum CodingKeys: String, CodingKey {
        case updatedAt
        case connectedServers
        case availableVoiceChannelsByServer
        case availableTextChannelsByServer
        case availableRolesByServer
        case usernamesById
        case channelTypesById
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        connectedServers = try container.decodeIfPresent([String: String].self, forKey: .connectedServers) ?? [:]
        availableVoiceChannelsByServer = try container.decodeIfPresent([String: [GuildVoiceChannel]].self, forKey: .availableVoiceChannelsByServer) ?? [:]
        availableTextChannelsByServer = try container.decodeIfPresent([String: [GuildTextChannel]].self, forKey: .availableTextChannelsByServer) ?? [:]
        availableRolesByServer = try container.decodeIfPresent([String: [GuildRole]].self, forKey: .availableRolesByServer) ?? [:]
        usernamesById = try container.decodeIfPresent([String: String].self, forKey: .usernamesById) ?? [:]
        channelTypesById = try container.decodeIfPresent([String: Int].self, forKey: .channelTypesById) ?? [:]
    }
}

actor DiscordCache {
    private var snapshot: DiscordCacheSnapshot
    private var updateContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(snapshot: DiscordCacheSnapshot = DiscordCacheSnapshot()) {
        self.snapshot = snapshot
    }

    var updates: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            updateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeUpdateContinuation(id) }
            }
        }
    }

    func replace(with snapshot: DiscordCacheSnapshot) {
        self.snapshot = snapshot
        emitUpdate()
    }

    func currentSnapshot() -> DiscordCacheSnapshot {
        var copy = snapshot
        copy.updatedAt = Date()
        return copy
    }

    func guildName(for guildID: String) -> String? {
        snapshot.connectedServers[guildID]
    }

    func userName(for userID: String) -> String? {
        snapshot.usernamesById[userID]
    }

    func channelName(for channelID: String) -> String? {
        for channels in snapshot.availableTextChannelsByServer.values {
            if let channel = channels.first(where: { $0.id == channelID }) {
                return channel.name
            }
        }
        for channels in snapshot.availableVoiceChannelsByServer.values {
            if let channel = channels.first(where: { $0.id == channelID }) {
                return channel.name
            }
        }
        return nil
    }

    func channelType(for channelID: String) -> Int? {
        snapshot.channelTypesById[channelID]
    }

    func setChannelType(channelID: String, type: Int) {
        snapshot.channelTypesById[channelID] = type
        emitUpdate()
    }

    func mergeChannelTypes(_ channelTypes: [String: Int]) {
        guard !channelTypes.isEmpty else { return }
        var didChange = false
        for (channelID, type) in channelTypes {
            if snapshot.channelTypesById[channelID] != type {
                snapshot.channelTypesById[channelID] = type
                didChange = true
            }
        }
        if didChange {
            emitUpdate()
        }
    }

    func allGuildNames() -> [String: String] {
        snapshot.connectedServers
    }

    func voiceChannelsByGuild() -> [String: [GuildVoiceChannel]] {
        snapshot.availableVoiceChannelsByServer
    }

    func textChannelsByGuild() -> [String: [GuildTextChannel]] {
        snapshot.availableTextChannelsByServer
    }

    func rolesByGuild() -> [String: [GuildRole]] {
        snapshot.availableRolesByServer
    }

    func allUserNames() -> [String: String] {
        snapshot.usernamesById
    }

    func upsertGuild(id guildID: String, name: String?) {
        let fallback = "Server \(guildID.suffix(4))"
        let candidate = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !candidate.isEmpty {
            if snapshot.connectedServers[guildID] != candidate {
                snapshot.connectedServers[guildID] = candidate
                emitUpdate()
            }
            return
        }

        // Preserve any known guild name when only an ID is available.
        if snapshot.connectedServers[guildID] == nil {
            snapshot.connectedServers[guildID] = fallback
            emitUpdate()
        }
    }

    func removeGuild(id guildID: String) {
        let textChannels = snapshot.availableTextChannelsByServer[guildID] ?? []
        let voiceChannels = snapshot.availableVoiceChannelsByServer[guildID] ?? []
        for channel in textChannels {
            snapshot.channelTypesById[channel.id] = nil
        }
        for channel in voiceChannels {
            snapshot.channelTypesById[channel.id] = nil
        }
        snapshot.connectedServers[guildID] = nil
        snapshot.availableVoiceChannelsByServer[guildID] = nil
        snapshot.availableTextChannelsByServer[guildID] = nil
        snapshot.availableRolesByServer[guildID] = nil
        emitUpdate()
    }

    func setGuildVoiceChannels(guildID: String, channels: [GuildVoiceChannel]) {
        let oldChannels = snapshot.availableVoiceChannelsByServer[guildID] ?? []
        for channel in oldChannels {
            snapshot.channelTypesById[channel.id] = nil
        }
        snapshot.availableVoiceChannelsByServer[guildID] = channels
        for channel in channels {
            snapshot.channelTypesById[channel.id] = 2
        }
        emitUpdate()
    }

    func setGuildTextChannels(guildID: String, channels: [GuildTextChannel]) {
        let oldChannels = snapshot.availableTextChannelsByServer[guildID] ?? []
        for channel in oldChannels {
            snapshot.channelTypesById[channel.id] = nil
        }
        snapshot.availableTextChannelsByServer[guildID] = channels
        for channel in channels {
            snapshot.channelTypesById[channel.id] = 0
        }
        emitUpdate()
    }

    func setGuildRoles(guildID: String, roles: [GuildRole]) {
        snapshot.availableRolesByServer[guildID] = roles
        emitUpdate()
    }

    func upsertChannel(guildID: String?, channelID: String, name: String, type: Int) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        snapshot.channelTypesById[channelID] = type

        if type == 1 || type == 3 {
            emitUpdate()
            return
        }
        guard let guildID else {
            emitUpdate()
            return
        }

        if type == 0 || type == 5 {
            var channels = snapshot.availableTextChannelsByServer[guildID] ?? []
            if let index = channels.firstIndex(where: { $0.id == channelID }) {
                channels[index] = GuildTextChannel(id: channelID, name: cleaned)
            } else {
                channels.append(GuildTextChannel(id: channelID, name: cleaned))
            }
            channels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            snapshot.availableTextChannelsByServer[guildID] = channels
            emitUpdate()
            return
        }

        if type == 2 || type == 13 {
            var channels = snapshot.availableVoiceChannelsByServer[guildID] ?? []
            if let index = channels.firstIndex(where: { $0.id == channelID }) {
                channels[index] = GuildVoiceChannel(id: channelID, name: cleaned)
            } else {
                channels.append(GuildVoiceChannel(id: channelID, name: cleaned))
            }
            channels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            snapshot.availableVoiceChannelsByServer[guildID] = channels
            emitUpdate()
        }
    }

    func upsertUser(id userID: String, preferredName: String?) {
        let cleaned = (preferredName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if snapshot.usernamesById[userID] == cleaned { return }
        snapshot.usernamesById[userID] = cleaned
        emitUpdate()
    }

    private func emitUpdate() {
        for continuation in updateContinuations.values {
            continuation.yield(())
        }
    }

    private func removeUpdateContinuation(_ id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }
}

struct UptimeInfo {
    let startedAt: Date

    var text: String {
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%02dh %02dm %02ds", h, m, s) }
        return String(format: "%02dm %02ds", m, s)
    }
}

struct GatewayPayload: Codable {
    let op: Int
    let d: DiscordJSON?
    let s: Int?
    let t: String?
}

enum DiscordJSON: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: DiscordJSON])
    case array([DiscordJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode([String: DiscordJSON].self) { self = .object(value) }
        else if let value = try? container.decode([DiscordJSON].self) { self = .array(value) }
        else { throw DecodingError.typeMismatch(DiscordJSON.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type")) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

struct VoiceRuleEvent {
    enum Kind {
        case join
        case leave
        case move
        case message
    }

    let kind: Kind
    let guildId: String
    let userId: String
    let username: String
    let channelId: String
    let fromChannelId: String?
    let toChannelId: String?
    let durationSeconds: Int?
    let messageContent: String?
    let isDirectMessage: Bool
}

@MainActor
final class RuleStore: ObservableObject {
    @Published var rules: [Rule] = []
    @Published var selectedRuleID: UUID?
    @Published var lastSavedAt: Date?

    private let store = RuleConfigStore()
    private var autoSaveTask: Task<Void, Never>?

    init() {
        Task {
            let loaded = await store.load()
            if let loaded, !loaded.isEmpty {
                rules = loaded
            } else {
                rules = [Rule(name: "Join Action")]
            }
            selectedRuleID = nil
        }
    }

    func addNewRule(serverId: String = "", channelId: String = "") {
        var action = RuleAction()
        action.serverId = serverId
        action.channelId = channelId
        var rule = Rule(name: "New Action")
        rule.triggerServerId = serverId
        rule.actions = [action]
        rules.append(rule)
        selectedRuleID = rule.id
        scheduleAutoSave()
    }

    func deleteRules(at offsets: IndexSet, undoManager: UndoManager?) {
        let sortedOffsets = offsets.sorted()
        guard !sortedOffsets.isEmpty else { return }
        let removed = sortedOffsets.map { ($0, rules[$0]) }
        let previousSelection = selectedRuleID

        for index in sortedOffsets.reversed() {
            rules.remove(at: index)
        }
        reseatSelection(previousSelection: previousSelection)
        scheduleAutoSave()

        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreRules(removed, previousSelection: previousSelection, undoManager: undoManager)
        }
    }

    func deleteRule(id: UUID, undoManager: UndoManager?) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        deleteRules(at: IndexSet(integer: idx), undoManager: undoManager)
    }

    func save() {
        let snapshot = rules
        Task {
            try? await store.save(snapshot)
            lastSavedAt = Date()
        }
    }

    func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func restoreRules(_ removed: [(Int, Rule)], previousSelection: UUID?, undoManager: UndoManager?) {
        for (index, rule) in removed.sorted(by: { $0.0 < $1.0 }) {
            let insertIndex = min(index, rules.count)
            rules.insert(rule, at: insertIndex)
        }
        selectedRuleID = previousSelection ?? removed.first?.1.id
        scheduleAutoSave()

        undoManager?.registerUndo(withTarget: self) { target in
            let offsets = IndexSet(removed.map(\.0))
            target.deleteRules(at: offsets, undoManager: undoManager)
        }
    }

    private func reseatSelection(previousSelection: UUID?) {
        guard let previousSelection else {
            selectedRuleID = nil
            return
        }

        if rules.contains(where: { $0.id == previousSelection }) {
            selectedRuleID = previousSelection
        } else {
            selectedRuleID = nil
        }
    }
}

@MainActor
final class RuleEngine {
    private var cancellable: AnyCancellable?
    private var activeRules: [Rule] = []

    init(store: RuleStore) {
        cancellable = store.$rules.sink { [weak self] rules in
            self?.activeRules = rules.filter(\.isEnabled)
        }
    }

    func evaluate(event: VoiceRuleEvent) -> [Action] {
        activeRules
            .filter { rule in matchesTrigger(rule: rule, event: event) && matchesConditions(rule: rule, event: event) }
            .flatMap(\.actions)
    }

    private func matchesTrigger(rule: Rule, event: VoiceRuleEvent) -> Bool {
        switch (rule.trigger, event.kind) {
        case (.userJoinedVoice, .join):
            return true
        case (.userLeftVoice, .leave):
            return true
        case (.userMovedVoice, .move):
            return true
        case (.messageContains, .message):
            let needle = rule.triggerMessageContains.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty, let content = event.messageContent else { return false }
            if event.isDirectMessage {
                return rule.replyToDMs && content.localizedCaseInsensitiveContains(needle)
            }
            return content.localizedCaseInsensitiveContains(needle)
        default:
            return false
        }
    }

    private func matchesConditions(rule: Rule, event: VoiceRuleEvent) -> Bool {
        for condition in rule.conditions where condition.enabled {
            if !matches(condition: condition, event: event) { return false }
        }
        return true
    }

    private func matches(condition: Condition, event: VoiceRuleEvent) -> Bool {
        let value = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch condition.type {
        case .server:
            return value.isEmpty || event.guildId == value
        case .voiceChannel:
            return value.isEmpty || event.channelId == value || event.fromChannelId == value || event.toChannelId == value
        case .usernameContains:
            guard !value.isEmpty else { return true }
            return event.username.localizedCaseInsensitiveContains(value)
        case .minimumDuration:
            guard let minimum = Int(value), minimum > 0 else { return true }
            guard let durationSeconds = event.durationSeconds else { return false }
            return durationSeconds >= (minimum * 60)
        }
    }
}

protocol BotPlugin {
    var name: String { get }
    func register(on bus: EventBus) async
    func unregister(from bus: EventBus) async
}

final class PluginManager {
    private var plugins: [BotPlugin] = []
    private let bus: EventBus

    init(bus: EventBus) { self.bus = bus }

    func add(_ plugin: BotPlugin) async {
        plugins.append(plugin)
        await plugin.register(on: bus)
    }

    func removeAll() async {
        for p in plugins { await p.unregister(from: bus) }
        plugins.removeAll()
    }
}

final class WeeklySummaryPlugin: BotPlugin {
    let name = "WeeklySummary"
    
    private var tokens: [SubscriptionToken] = []
    private var voiceDurations: [String: Int] = [:] // userId -> accumulated seconds
    
    init() {}
    
    func register(on bus: EventBus) async {
        let joinToken = bus.subscribe(VoiceJoined.self) { _ in
            // No-op for accumulation; could log here if needed
        }
        tokens.append(joinToken)
        
        let leftToken = bus.subscribe(VoiceLeft.self) { [weak self] event in
            guard let self = self else { return }
            self.voiceDurations[event.userId, default: 0] += max(0, event.durationSeconds)
        }
        tokens.append(leftToken)
    }
    
    func unregister(from bus: EventBus) async {
        for token in tokens {
            bus.unsubscribe(token)
        }
        tokens.removeAll()
    }
    
    func snapshotSummary() -> String {
        let sortedUsers = voiceDurations.sorted { $0.value > $1.value }
        guard !sortedUsers.isEmpty else {
            return "No voice activity recorded yet."
        }
        
        let summaryLines = sortedUsers.prefix(5).map { userId, seconds in
            let minutes = seconds / 60
            return "\(userId): \(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        
        return "Weekly Voice Summary:\n" + summaryLines.joined(separator: "\n")
    }
}
