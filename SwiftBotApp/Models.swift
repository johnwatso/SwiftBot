import Combine
import Foundation
import Network
import Security

#if DEBUG
/// Task-local overrides for AI timing and response behavior in unit tests.
/// Only available in DEBUG builds — release logic must not depend on this enum.
enum AITestOverrides {
    @TaskLocal static var softNoticeNs: UInt64?
    @TaskLocal static var hardTimeoutNs: UInt64?
    @TaskLocal static var typingRefreshNs: UInt64?
    @TaskLocal static var replyOverride: String?
    @TaskLocal static var replyDelaySeconds: Double = 0
}
#endif

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
    func subscribe<E: Event>(_ type: E.Type, handler: @escaping (E) async -> Void) async -> SubscriptionToken {
        let token = SubscriptionToken()
        let wrappedHandler: (Any) async -> Void = { anyEvent in
            guard let event = anyEvent as? E else { return }
            await handler(event)
        }
        await storage.add(type: ObjectIdentifier(type), token: token, handler: wrappedHandler)
        return token
    }

    /// Unsubscribes from an event using the given subscription token.
    func unsubscribe(_ token: SubscriptionToken) async {
        await storage.remove(token: token)
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
    var joinNotificationTemplate: String = "🔊 {username} joined {channelName}"
    var leaveNotificationTemplate: String = "🔌 {username} left {channelName}"
    var moveNotificationTemplate: String = "🔁 {username} moved: {fromChannelName} → {toChannelName}"
}

struct BotSettings: Codable, Hashable {
    var token: String = ""
    var prefix: String = "/"
    var autoStart: Bool = false
    var guildSettings: [String: GuildSettings] = [:]
    var clusterMode: ClusterMode = .standalone
    var clusterNodeName: String = Host.current().localizedName ?? "SwiftBot Node"
    var clusterLeaderAddress: String = ""
    var clusterListenPort: Int = 38787
    var clusterSharedSecret: String = ""
    var clusterLeaderTerm: Int = 0

    // Local AI reply settings for DMs and guild mentions.
    var localAIDMReplyEnabled: Bool = false
    var localAIProvider: AIProvider = .appleIntelligence
    var preferredAIProvider: AIProviderPreference = .apple
    var localAIEndpoint: String = "http://127.0.0.1:1234/v1/chat/completions"
    var localAIModel: String = "local-model"
    var ollamaBaseURL: String = "http://localhost:11434"
    var openAIEnabled: Bool = true
    var openAIAPIKey: String = ""
    var openAIModel: String = "gpt-4o-mini"
    var openAIImageGenerationEnabled: Bool = true
    var openAIImageModel: String = "gpt-image-1"
    var openAIImageMonthlyLimitPerUser: Int = 5
    var openAIImageUsageByUserMonth: [String: Int] = [:]
    var aiMemoryNotes: [AIMemoryNote] = []
    var localAISystemPrompt: String = "You are a friendly, casual Discord bot. Keep replies short and conversational — 1 to 3 sentences max unless asked for detail. Use contractions naturally. Don't restate what the user said. Don't open every reply the same way. Match the energy of the conversation."
    var behavior = BotBehaviorSettings()
    var wikiBot = WikiBotSettings()
    var patchy = PatchySettings()
    var help = HelpSettings()

    private enum CodingKeys: String, CodingKey {
        case token
        case prefix
        case autoStart
        case guildSettings
        case clusterMode
        case clusterNodeName
        case clusterLeaderAddress
        case clusterWorkerBaseURLLegacy = "clusterWorkerBaseURL"
        case clusterListenPort
        case clusterSharedSecret
        case clusterLeaderTerm
        case localAIDMReplyEnabled
        case localAIProvider
        case preferredAIProvider
        case localAIEndpoint
        case localAIModel
        case ollamaBaseURL
        case openAIEnabled
        case openAIAPIKey
        case openAIModel
        case openAIImageGenerationEnabled
        case openAIImageModel
        case openAIImageMonthlyLimitPerUser
        case openAIImageUsageByUserMonth
        case aiMemoryNotes
        case localAISystemPrompt
        case behavior
        case wikiBot
        case patchy
        case help
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? "/"
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        guildSettings = try container.decodeIfPresent([String: GuildSettings].self, forKey: .guildSettings) ?? [:]
        clusterMode = try container.decodeIfPresent(ClusterMode.self, forKey: .clusterMode) ?? .standalone
        clusterNodeName = try container.decodeIfPresent(String.self, forKey: .clusterNodeName) ?? (Host.current().localizedName ?? "SwiftBot Node")
        clusterLeaderAddress = try container.decodeIfPresent(String.self, forKey: .clusterLeaderAddress)
            ?? (try container.decodeIfPresent(String.self, forKey: .clusterWorkerBaseURLLegacy) ?? "")
        clusterListenPort = try container.decodeIfPresent(Int.self, forKey: .clusterListenPort) ?? 38787
        clusterSharedSecret = try container.decodeIfPresent(String.self, forKey: .clusterSharedSecret) ?? ""
        clusterLeaderTerm = try container.decodeIfPresent(Int.self, forKey: .clusterLeaderTerm) ?? 0
        localAIDMReplyEnabled = try container.decodeIfPresent(Bool.self, forKey: .localAIDMReplyEnabled) ?? false
        localAIProvider = try container.decodeIfPresent(AIProvider.self, forKey: .localAIProvider) ?? .appleIntelligence
        preferredAIProvider = try container.decodeIfPresent(AIProviderPreference.self, forKey: .preferredAIProvider) ?? .apple
        localAIEndpoint = try container.decodeIfPresent(String.self, forKey: .localAIEndpoint) ?? "http://127.0.0.1:1234/v1/chat/completions"
        localAIModel = try container.decodeIfPresent(String.self, forKey: .localAIModel) ?? "local-model"
        ollamaBaseURL = try container.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://localhost:11434"
        openAIEnabled = try container.decodeIfPresent(Bool.self, forKey: .openAIEnabled) ?? true
        openAIAPIKey = try container.decodeIfPresent(String.self, forKey: .openAIAPIKey) ?? ""
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? "gpt-4o-mini"
        openAIImageGenerationEnabled = try container.decodeIfPresent(Bool.self, forKey: .openAIImageGenerationEnabled) ?? true
        openAIImageModel = try container.decodeIfPresent(String.self, forKey: .openAIImageModel) ?? "gpt-image-1"
        openAIImageMonthlyLimitPerUser = try container.decodeIfPresent(Int.self, forKey: .openAIImageMonthlyLimitPerUser) ?? 5
        openAIImageUsageByUserMonth = try container.decodeIfPresent([String: Int].self, forKey: .openAIImageUsageByUserMonth) ?? [:]
        aiMemoryNotes = try container.decodeIfPresent([AIMemoryNote].self, forKey: .aiMemoryNotes) ?? []
        localAISystemPrompt = try container.decodeIfPresent(String.self, forKey: .localAISystemPrompt) ?? "You are a friendly, casual Discord bot. Keep replies short and conversational — 1 to 3 sentences max unless asked for detail. Use contractions naturally. Don't restate what the user said. Don't open every reply the same way. Match the energy of the conversation."
        behavior = try container.decodeIfPresent(BotBehaviorSettings.self, forKey: .behavior) ?? BotBehaviorSettings()
        wikiBot = try container.decodeIfPresent(WikiBotSettings.self, forKey: .wikiBot) ?? WikiBotSettings()
        patchy = try container.decodeIfPresent(PatchySettings.self, forKey: .patchy) ?? PatchySettings()
        help = try container.decodeIfPresent(HelpSettings.self, forKey: .help) ?? HelpSettings()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(prefix, forKey: .prefix)
        try container.encode(autoStart, forKey: .autoStart)
        try container.encode(guildSettings, forKey: .guildSettings)
        try container.encode(clusterMode, forKey: .clusterMode)
        try container.encode(clusterNodeName, forKey: .clusterNodeName)
        try container.encode(clusterLeaderAddress, forKey: .clusterLeaderAddress)
        try container.encode(clusterListenPort, forKey: .clusterListenPort)
        try container.encode(clusterSharedSecret, forKey: .clusterSharedSecret)
        try container.encode(clusterLeaderTerm, forKey: .clusterLeaderTerm)
        try container.encode(localAIDMReplyEnabled, forKey: .localAIDMReplyEnabled)

        try container.encode(localAIProvider, forKey: .localAIProvider)
        try container.encode(preferredAIProvider, forKey: .preferredAIProvider)
        try container.encode(localAIEndpoint, forKey: .localAIEndpoint)
        try container.encode(localAIModel, forKey: .localAIModel)
        try container.encode(ollamaBaseURL, forKey: .ollamaBaseURL)
        try container.encode(openAIEnabled, forKey: .openAIEnabled)
        try container.encode(openAIAPIKey, forKey: .openAIAPIKey)
        try container.encode(openAIModel, forKey: .openAIModel)
        try container.encode(openAIImageGenerationEnabled, forKey: .openAIImageGenerationEnabled)
        try container.encode(openAIImageModel, forKey: .openAIImageModel)
        try container.encode(openAIImageMonthlyLimitPerUser, forKey: .openAIImageMonthlyLimitPerUser)
        try container.encode(openAIImageUsageByUserMonth, forKey: .openAIImageUsageByUserMonth)
        try container.encode(aiMemoryNotes, forKey: .aiMemoryNotes)
        try container.encode(localAISystemPrompt, forKey: .localAISystemPrompt)
        try container.encode(behavior, forKey: .behavior)
        try container.encode(wikiBot, forKey: .wikiBot)
        try container.encode(patchy, forKey: .patchy)
        try container.encode(help, forKey: .help)
    }
}

struct BotBehaviorSettings: Codable, Hashable {
    var allowDMs: Bool = false
    var useAIInGuildChannels: Bool = true

    // Member join welcome (P0.5)
    var memberJoinWelcomeEnabled: Bool = false
    var memberJoinWelcomeChannelId: String = ""
    var memberJoinWelcomeTemplate: String = "👋 Welcome {username} to **{server}**!"

    // Voice activity log — global fallback channel when no per-guild channel is set (P0.5)
    var voiceActivityLogEnabled: Bool = false
    var voiceActivityLogChannelId: String = ""
}

struct WikiCommand: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var trigger: String = "!wiki"
    var endpoint: String = "search"
    var description: String = ""
    var enabled: Bool = true

    private enum CodingKeys: String, CodingKey {
        case id
        case trigger
        case endpoint
        case description
        case enabled
    }

    init(
        id: UUID = UUID(),
        trigger: String = "!wiki",
        endpoint: String = "search",
        description: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.trigger = trigger
        self.endpoint = endpoint
        self.description = description
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger) ?? "!wiki"
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? "search"
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct WikiFormatting: Codable, Hashable {
    var includeStatBlocks: Bool = true
    var useEmbeds: Bool = false
    var compactMode: Bool = false
}

struct WikiParsingRule: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var pageType: String = "weapon"
    var templateName: String = "Weapon"
}

struct WikiSource: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Wiki Source"
    var baseURL: String = "https://example.fandom.com"
    var apiPath: String = "/api.php"
    var enabled: Bool = true
    var isPrimary: Bool = false
    var commands: [WikiCommand] = []
    var formatting: WikiFormatting = WikiFormatting()
    var parsingRules: [WikiParsingRule] = []
    var lastLookupAt: Date?
    var lastStatus: String = "Never used"

    init(
        id: UUID = UUID(),
        name: String = "Wiki Source",
        baseURL: String = "https://example.fandom.com",
        apiPath: String = "/api.php",
        enabled: Bool = true,
        isPrimary: Bool = false,
        commands: [WikiCommand] = [],
        formatting: WikiFormatting = WikiFormatting(),
        parsingRules: [WikiParsingRule] = [],
        lastLookupAt: Date? = nil,
        lastStatus: String = "Never used"
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiPath = apiPath
        self.enabled = enabled
        self.isPrimary = isPrimary
        self.commands = commands
        self.formatting = formatting
        self.parsingRules = parsingRules
        self.lastLookupAt = lastLookupAt
        self.lastStatus = lastStatus
    }

    static func defaultFinals() -> WikiSource {
        WikiSource(
            id: UUID(),
            name: "THE FINALS Wiki",
            baseURL: "https://www.thefinals.wiki",
            apiPath: "/api.php",
            enabled: true,
            isPrimary: true,
            commands: [
                WikiCommand(trigger: "!wiki", endpoint: "search", description: "Search wiki pages", enabled: true),
                WikiCommand(trigger: "!weapon", endpoint: "weaponPage", description: "Lookup weapon stats", enabled: true),
                WikiCommand(trigger: "!finals", endpoint: "search", description: "Search THE FINALS wiki", enabled: true)
            ],
            formatting: WikiFormatting(
                includeStatBlocks: true,
                useEmbeds: false,
                compactMode: false
            ),
            parsingRules: [
                WikiParsingRule(pageType: "weapon", templateName: "Weapon")
            ],
            lastLookupAt: nil,
            lastStatus: "Ready"
        )
    }

    static func genericTemplate() -> WikiSource {
        WikiSource(
            id: UUID(),
            name: "New Wiki",
            baseURL: "https://example.fandom.com",
            apiPath: "/api.php",
            enabled: true,
            isPrimary: false,
            commands: [
                WikiCommand(trigger: "!wiki", endpoint: "search", description: "Search wiki pages", enabled: true)
            ],
            formatting: WikiFormatting(
                includeStatBlocks: false,
                useEmbeds: false,
                compactMode: false
            ),
            parsingRules: [],
            lastLookupAt: nil,
            lastStatus: "Ready"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case apiPath
        case enabled
        case isPrimary
        case commands
        case formatting
        case parsingRules
        case lastLookupAt
        case lastStatus
        // Legacy key
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Wiki Source"
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://example.fandom.com"
        apiPath = try container.decodeIfPresent(String.self, forKey: .apiPath) ?? "/api.php"
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? (try container.decodeIfPresent(Bool.self, forKey: .isEnabled))
            ?? true
        isPrimary = try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        commands = try container.decodeIfPresent([WikiCommand].self, forKey: .commands) ?? []
        formatting = try container.decodeIfPresent(WikiFormatting.self, forKey: .formatting) ?? WikiFormatting()
        parsingRules = try container.decodeIfPresent([WikiParsingRule].self, forKey: .parsingRules) ?? []
        lastLookupAt = try container.decodeIfPresent(Date.self, forKey: .lastLookupAt)
        lastStatus = try container.decodeIfPresent(String.self, forKey: .lastStatus) ?? "Never used"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(apiPath, forKey: .apiPath)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(isPrimary, forKey: .isPrimary)
        try container.encode(commands, forKey: .commands)
        try container.encode(formatting, forKey: .formatting)
        try container.encode(parsingRules, forKey: .parsingRules)
        try container.encodeIfPresent(lastLookupAt, forKey: .lastLookupAt)
        try container.encode(lastStatus, forKey: .lastStatus)
    }
}

private struct LegacyWikiBridgeSourceTarget: Decodable {
    enum LegacyKind: String, Decodable {
        case finals = "THE FINALS"
        case mediaWiki = "MediaWiki"
    }

    var id: UUID?
    var isEnabled: Bool?
    var name: String?
    var kind: LegacyKind?
    var baseURL: String?
    var apiPath: String?
    var lastLookupAt: Date?
    var lastStatus: String?
}

struct WikiBotSettings: Codable, Hashable {
    var isEnabled: Bool = true
    var sources: [WikiSource] = []

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case sources
        // Legacy key
        case defaultSourceID
        // Legacy keys
        case allowFinalsCommand
        case allowWikiAlias
        case allowWeaponCommand
        case includeWeaponStats
        case sourceTargets
    }

    init() {
        let defaultSource = WikiSource.defaultFinals()
        sources = [defaultSource]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true

        let allowFinalsCommand = try container.decodeIfPresent(Bool.self, forKey: .allowFinalsCommand) ?? true
        let allowWikiAlias = try container.decodeIfPresent(Bool.self, forKey: .allowWikiAlias) ?? true
        let allowWeaponCommand = try container.decodeIfPresent(Bool.self, forKey: .allowWeaponCommand) ?? true
        let includeWeaponStats = try container.decodeIfPresent(Bool.self, forKey: .includeWeaponStats) ?? true

        if let decodedSources = try container.decodeIfPresent([WikiSource].self, forKey: .sources) {
            sources = decodedSources
        } else if let legacyTargets = try container.decodeIfPresent([LegacyWikiBridgeSourceTarget].self, forKey: .sourceTargets) {
            sources = Self.sourcesFromLegacyTargets(
                legacyTargets,
                allowFinalsCommand: allowFinalsCommand,
                allowWikiAlias: allowWikiAlias,
                allowWeaponCommand: allowWeaponCommand,
                includeWeaponStats: includeWeaponStats
            )
        } else {
            sources = []
        }

        let legacyPrimaryID = try container.decodeIfPresent(UUID.self, forKey: .defaultSourceID)
        if let legacyPrimaryID, !sources.contains(where: { $0.isPrimary }) {
            sources = sources.map { source in
                var updated = source
                updated.isPrimary = source.id == legacyPrimaryID
                return updated
            }
        }
        normalizeSources()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(sources, forKey: .sources)
    }

    mutating func normalizeSources() {
        if sources.isEmpty {
            let defaultSource = WikiSource.defaultFinals()
            sources = [defaultSource]
            return
        }

        sources = sources.map { source in
            var updated = source
            updated.name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.baseURL = source.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.apiPath = source.apiPath.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.commands = source.commands.map { command in
                var normalized = command
                normalized.trigger = command.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                normalized.endpoint = command.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                normalized.description = command.description.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized
            }
            updated.parsingRules = source.parsingRules.map { rule in
                var normalized = rule
                normalized.pageType = rule.pageType.trimmingCharacters(in: .whitespacesAndNewlines)
                normalized.templateName = rule.templateName.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized
            }
            if updated.name.isEmpty {
                updated.name = "Wiki Source"
            }
            if updated.baseURL.isEmpty {
                updated.baseURL = "https://example.fandom.com"
            }
            if updated.apiPath.isEmpty {
                updated.apiPath = "/api.php"
            }
            if updated.commands.isEmpty {
                updated.commands = [WikiCommand(trigger: "!wiki", endpoint: "search", description: "Search wiki pages", enabled: true)]
            }
            return updated
        }

        let primaryID: UUID? = {
            if let primaryEnabled = sources.first(where: { $0.isPrimary && $0.enabled }) {
                return primaryEnabled.id
            }
            if let firstEnabled = sources.first(where: { $0.enabled }) {
                return firstEnabled.id
            }
            if let explicitPrimary = sources.first(where: { $0.isPrimary }) {
                return explicitPrimary.id
            }
            return sources.first?.id
        }()

        if let primaryID {
            sources = sources.map { source in
                var updated = source
                updated.isPrimary = source.id == primaryID
                return updated
            }
        }
    }

    mutating func setPrimarySource(_ sourceID: UUID) {
        guard sources.contains(where: { $0.id == sourceID }) else { return }
        sources = sources.map { source in
            var updated = source
            updated.isPrimary = source.id == sourceID
            return updated
        }
        normalizeSources()
    }

    func primarySource() -> WikiSource? {
        if let primaryEnabled = sources.first(where: { $0.isPrimary && $0.enabled }) {
            return primaryEnabled
        }
        if let firstEnabled = sources.first(where: { $0.enabled }) {
            return firstEnabled
        }
        return sources.first(where: { $0.isPrimary }) ?? sources.first
    }

    private static func sourcesFromLegacyTargets(
        _ legacyTargets: [LegacyWikiBridgeSourceTarget],
        allowFinalsCommand: Bool,
        allowWikiAlias: Bool,
        allowWeaponCommand: Bool,
        includeWeaponStats: Bool
    ) -> [WikiSource] {
        guard !legacyTargets.isEmpty else {
            return [finalsSourceFromLegacyFlags(
                allowFinalsCommand: allowFinalsCommand,
                allowWikiAlias: allowWikiAlias,
                allowWeaponCommand: allowWeaponCommand,
                includeWeaponStats: includeWeaponStats
            )]
        }

        return legacyTargets.map { legacy in
            let isFinals = legacy.kind == .finals ||
                (legacy.baseURL?.lowercased().contains("thefinals.wiki") ?? false)
            if isFinals {
                var finals = finalsSourceFromLegacyFlags(
                    allowFinalsCommand: allowFinalsCommand,
                    allowWikiAlias: allowWikiAlias,
                    allowWeaponCommand: allowWeaponCommand,
                    includeWeaponStats: includeWeaponStats
                )
                finals.id = legacy.id ?? finals.id
                finals.enabled = legacy.isEnabled ?? true
                finals.name = legacy.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? finals.name
                finals.baseURL = legacy.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? finals.baseURL
                finals.apiPath = legacy.apiPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? finals.apiPath
                finals.lastLookupAt = legacy.lastLookupAt
                finals.lastStatus = legacy.lastStatus ?? finals.lastStatus
                return finals
            }

            return WikiSource(
                id: legacy.id ?? UUID(),
                name: legacy.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Wiki Source",
                baseURL: legacy.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "https://example.fandom.com",
                apiPath: legacy.apiPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "/api.php",
                enabled: legacy.isEnabled ?? true,
                isPrimary: false,
                commands: [
                    WikiCommand(trigger: "!wiki", endpoint: "search", description: "Search wiki pages", enabled: allowWikiAlias)
                ],
                formatting: WikiFormatting(
                    includeStatBlocks: false,
                    useEmbeds: false,
                    compactMode: false
                ),
                parsingRules: [],
                lastLookupAt: legacy.lastLookupAt,
                lastStatus: legacy.lastStatus ?? "Ready"
            )
        }
    }

    private static func finalsSourceFromLegacyFlags(
        allowFinalsCommand: Bool,
        allowWikiAlias: Bool,
        allowWeaponCommand: Bool,
        includeWeaponStats: Bool
    ) -> WikiSource {
        var source = WikiSource.defaultFinals()
        source.isPrimary = false
        source.commands = source.commands.map { command in
            var updated = command
            let key = command.trigger.lowercased()
            if key == "!finals" {
                updated.enabled = allowFinalsCommand
            } else if key == "!wiki" {
                updated.enabled = allowWikiAlias
            } else if key == "!weapon" {
                updated.enabled = allowWeaponCommand
            }
            return updated
        }
        source.formatting.includeStatBlocks = includeWeaponStats
        return source
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

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

    func allRecords() -> [MemoryRecord] {
        messagesByScope.values.flatMap { $0 }
    }

    /// All records globally sorted by (timestamp ascending, id ascending) — deterministic sync order.
    func allRecordsSorted() -> [MemoryRecord] {
        allRecords().sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
    }

    /// Returns up to `limit` records that come after `fromRecordID` in sorted order.
    /// Returns `hasMore: true` if additional records exist beyond this page.
    func recordsSince(fromRecordID: String?, limit: Int) -> (records: [MemoryRecord], hasMore: Bool) {
        let sorted = allRecordsSorted()
        let startIndex: Int
        if let cursorID = fromRecordID,
           let idx = sorted.firstIndex(where: { $0.id == cursorID }) {
            startIndex = sorted.index(after: idx)
        } else {
            startIndex = sorted.startIndex
        }
        guard startIndex < sorted.endIndex else { return ([], false) }
        let slice = sorted[startIndex...]
        let batch = Array(slice.prefix(limit))
        let hasMore = slice.count > limit
        return (batch, hasMore)
    }

    /// Appends a record only if no record with the same id already exists (idempotent merge).
    func appendIfNotExists(scope: MemoryScope, messageID: String, userID: String, content: String, role: MessageRole, timestamp: Date) {
        let existing = messagesByScope[scope] ?? []
        guard !existing.contains(where: { $0.id == messageID }) else { return }
        let record = MemoryRecord(id: messageID, scope: scope, userID: userID, content: content, timestamp: timestamp, role: role)
        messagesByScope[scope, default: []].append(record)
        emitUpdate()
    }

    func allMessages() -> [Message] {
        messagesByScope.flatMap { scope, records in
            records.map { record in
                Message(
                    id: record.id,
                    channelID: record.scope.id,
                    userID: record.userID,
                    username: "", // will be resolved on other end
                    content: record.content,
                    timestamp: record.timestamp,
                    role: record.role
                )
            }
        }
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
    case standby = "Standby"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standalone: return "Standalone"
        case .leader:     return "Primary"
        case .worker:     return "Worker"
        case .standby:    return "Fail Over"
        }
    }

    var description: String {
        switch self {
        case .standalone:
            return "Runs Discord and all tasks locally. No clustering."
        case .leader:
            return "Primary node — owns Discord, distributes jobs to Workers, and coordinates the mesh."
        case .worker:
            return "Connects to the Primary node, receives and runs offloaded jobs."
        case .standby:
            return "Fail Over node — silently monitors the Primary and automatically promotes if it fails. Discord stays offline until promotion."
        }
    }
}

// MARK: - SwiftMesh Protocol Types (Phase 1)

/// Sent by the leader to notify workers and standbys that a new leader has taken over.
/// Workers must reject this if `term` is not newer than their current known term.
struct MeshLeaderChangedPayload: Codable, Sendable {
    let term: Int
    let leaderAddress: String
    let leaderNodeName: String
    let sharedSecret: String
}

/// Sent by the leader to the standby to replicate the registered worker list.
struct MeshWorkerRegistryPayload: Codable, Sendable {
    struct WorkerEntry: Codable, Sendable {
        let nodeName: String
        let baseURL: String
        let listenPort: Int
    }
    let workers: [WorkerEntry]
    let leaderTerm: Int
}

/// Incremental conversation sync payload sent leader → standby.
/// Records are ordered by (timestamp ascending, id ascending) for deterministic replay.
struct MeshSyncPayload: Codable, Sendable {
    let conversations: [MemoryRecord]
    let leaderTerm: Int
    /// ID of the last record in this batch — standby stores as its new cursor.
    let cursorRecordID: String?
    /// True if more records exist beyond this batch; standby should request resync for next page.
    let hasMore: Bool
    /// The cursor the leader assumed this node held when building this batch.
    /// Node compares against its own lastMergedRecordID to detect gaps.
    let fromCursorRecordID: String?

    init(conversations: [MemoryRecord], leaderTerm: Int, cursorRecordID: String? = nil, hasMore: Bool = false, fromCursorRecordID: String? = nil) {
        self.conversations = conversations
        self.leaderTerm = leaderTerm
        self.cursorRecordID = cursorRecordID
        self.hasMore = hasMore
        self.fromCursorRecordID = fromCursorRecordID
    }
}

/// Standby → leader: request a bounded checkpoint batch starting from a cursor.
struct MeshResyncRequest: Codable, Sendable {
    /// ID of the last successfully merged record (nil = start from beginning).
    let fromRecordID: String?
    let pageSize: Int
}

/// Leader tracks one cursor per registered node (keyed by node base URL).
/// Persisted to disk so leader restart does not force blind full-replay.
struct ReplicationCursor: Codable, Sendable {
    /// The leader term in which this cursor was last updated.
    var leaderTerm: Int
    /// ID of the last record successfully delivered to this node.
    var lastSentRecordID: String?
    /// When this cursor was last advanced.
    var updatedAt: Date
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

enum ClusterNodeRole: String, Codable, Hashable {
    case leader
    case worker

    var displayName: String {
        rawValue.capitalized
    }
}

enum ClusterNodeConnectionStatus: String, Codable, Hashable {
    case connected
    case disconnected
    case degraded
    case starting
    case failed

    var displayName: String {
        rawValue.capitalized
    }
}

enum ClusterNodeHealthStatus: String, Codable, Hashable {
    case healthy
    case degraded
    case disconnected

    var displayName: String {
        switch self {
        case .healthy: return "Healthy"
        case .degraded: return "Degraded"
        case .disconnected: return "Disconnected"
        }
    }

    init(connectionStatus: ClusterNodeConnectionStatus) {
        switch connectionStatus {
        case .connected:
            self = .healthy
        case .starting, .degraded:
            self = .degraded
        case .failed, .disconnected:
            self = .disconnected
        }
    }

    var connectionStatus: ClusterNodeConnectionStatus {
        switch self {
        case .healthy:
            return .connected
        case .degraded:
            return .degraded
        case .disconnected:
            return .disconnected
        }
    }
}

extension ClusterConnectionState {
    var nodeConnectionStatus: ClusterNodeConnectionStatus {
        switch self {
        case .connected, .listening:
            return .connected
        case .starting:
            return .starting
        case .degraded:
            return .degraded
        case .failed:
            return .failed
        case .inactive, .stopped:
            return .disconnected
        }
    }

    var nodeHealthStatus: ClusterNodeHealthStatus {
        ClusterNodeHealthStatus(connectionStatus: nodeConnectionStatus)
    }
}

struct ClusterNodeStatus: Identifiable, Codable, Hashable {
    var id: String
    var hostname: String
    var displayName: String
    var role: ClusterNodeRole
    var hardwareModel: String
    var cpu: Double
    var mem: Double
    var cpuName: String
    var physicalMemoryBytes: UInt64
    var uptime: TimeInterval
    var latencyMs: Double?
    var status: ClusterNodeHealthStatus
    var jobsActive: Int

    var hardwareName: String { displayName }
    var uptimeSeconds: TimeInterval { uptime }
    var connectionStatus: ClusterNodeConnectionStatus { status.connectionStatus }
    var connectionStatusText: String { status.displayName }

    init(
        id: String,
        hostname: String,
        displayName: String,
        role: ClusterNodeRole,
        hardwareModel: String,
        cpu: Double,
        mem: Double,
        cpuName: String = "Unknown CPU",
        physicalMemoryBytes: UInt64 = 0,
        uptime: TimeInterval,
        latencyMs: Double?,
        status: ClusterNodeHealthStatus,
        jobsActive: Int
    ) {
        self.id = id
        self.hostname = hostname
        self.displayName = displayName
        self.role = role
        self.hardwareModel = hardwareModel
        self.cpu = cpu
        self.mem = mem
        self.cpuName = cpuName
        self.physicalMemoryBytes = physicalMemoryBytes
        self.uptime = uptime
        self.latencyMs = latencyMs
        self.status = status
        self.jobsActive = jobsActive
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case hostname
        case displayName
        case role
        case hardwareModel
        case cpu
        case mem
        case cpuName
        case physicalMemoryBytes
        case uptime
        case latencyMs
        case status
        case jobsActive

        // Legacy decode compatibility.
        case hardwareName
        case uptimeSeconds
        case connectionStatus
        case connectionStatusText
        case cpuPercent
        case memoryPercent
        case memoryBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? "unknown-host"
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? (try container.decodeIfPresent(String.self, forKey: .hardwareName) ?? hostname)
        role = try container.decodeIfPresent(ClusterNodeRole.self, forKey: .role) ?? .worker
        hardwareModel = try container.decodeIfPresent(String.self, forKey: .hardwareModel) ?? "Mac"
        cpu = try container.decodeIfPresent(Double.self, forKey: .cpu)
            ?? (try container.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? 0)
        mem = try container.decodeIfPresent(Double.self, forKey: .mem)
            ?? (try container.decodeIfPresent(Double.self, forKey: .memoryPercent) ?? 0)
        cpuName = try container.decodeIfPresent(String.self, forKey: .cpuName) ?? "Unknown CPU"
        physicalMemoryBytes = try container.decodeIfPresent(UInt64.self, forKey: .physicalMemoryBytes)
            ?? (try container.decodeIfPresent(UInt64.self, forKey: .memoryBytes) ?? 0)
        uptime = try container.decodeIfPresent(TimeInterval.self, forKey: .uptime)
            ?? (try container.decodeIfPresent(TimeInterval.self, forKey: .uptimeSeconds) ?? 0)
        latencyMs = try container.decodeIfPresent(Double.self, forKey: .latencyMs)
        jobsActive = try container.decodeIfPresent(Int.self, forKey: .jobsActive) ?? 0

        if let decodedStatus = try container.decodeIfPresent(ClusterNodeHealthStatus.self, forKey: .status) {
            status = decodedStatus
        } else if let legacyConnection = try container.decodeIfPresent(ClusterNodeConnectionStatus.self, forKey: .connectionStatus) {
            status = ClusterNodeHealthStatus(connectionStatus: legacyConnection)
        } else {
            let legacyText = (try container.decodeIfPresent(String.self, forKey: .connectionStatusText) ?? "").lowercased()
            if legacyText.contains("degrad") || legacyText.contains("start") {
                status = .degraded
            } else if legacyText.contains("disconnect") || legacyText.contains("fail") || legacyText.contains("offline") || legacyText.contains("unavailable") {
                status = .disconnected
            } else {
                status = .healthy
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(role, forKey: .role)
        try container.encode(hardwareModel, forKey: .hardwareModel)
        try container.encode(cpu, forKey: .cpu)
        try container.encode(mem, forKey: .mem)
        try container.encode(cpuName, forKey: .cpuName)
        try container.encode(physicalMemoryBytes, forKey: .physicalMemoryBytes)
        try container.encode(uptime, forKey: .uptime)
        try container.encodeIfPresent(latencyMs, forKey: .latencyMs)
        try container.encode(status, forKey: .status)
        try container.encode(jobsActive, forKey: .jobsActive)
    }
}

struct ClusterStatusResponse: Codable, Hashable {
    var mode: ClusterMode
    var generatedAt: String
    var nodes: [ClusterNodeStatus]
}

struct ClusterSnapshot: Hashable {
    var mode: ClusterMode = .standalone
    var nodeName: String = Host.current().localizedName ?? "SwiftBot Node"
    var listenPort: Int = 38787
    var leaderAddress: String = ""
    var leaderTerm: Int = 0
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
        case memberJoin
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
        case (.memberJoined, .memberJoin):
            return true
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
            // Voice channel conditions don't apply to member join events — always pass.
            if event.kind == .memberJoin { return true }
            return value.isEmpty || event.channelId == value || event.fromChannelId == value || event.toChannelId == value
        case .usernameContains:
            guard !value.isEmpty else { return true }
            return event.username.localizedCaseInsensitiveContains(value)
        case .minimumDuration:
            // Duration conditions don't apply to member join events — always pass.
            if event.kind == .memberJoin { return true }
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
        let joinToken = await bus.subscribe(VoiceJoined.self) { _ in
            // No-op for accumulation; could log here if needed
        }
        tokens.append(joinToken)

        let leftToken = await bus.subscribe(VoiceLeft.self) { [weak self] event in
            guard let self = self else { return }
            self.voiceDurations[event.userId, default: 0] += max(0, event.durationSeconds)
        }
        tokens.append(leftToken)
    }
    
    func unregister(from bus: EventBus) async {
        for token in tokens {
            await bus.unsubscribe(token)
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

/// Single owner for AI prompt composition — tone prompt, context enrichment, and message shaping.
/// Both AppModel and DiscordService should go through this to ensure consistent prompt structure.
enum PromptComposer {
    static let defaultTonePrompt =
        "You are a friendly, casual Discord bot. Keep replies short and conversational — " +
        "1 to 3 sentences max unless asked for detail. Use contractions naturally. " +
        "Don't restate what the user said. Don't open every reply the same way. " +
        "Match the energy of the conversation."

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .medium
        return f
    }()

    /// Builds the fully-enriched system prompt string.
    static func buildSystemPrompt(
        base: String,
        serverName: String?,
        channelName: String?,
        wikiContext: String?
    ) -> String {
        var prompt = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultTonePrompt
            : base.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wiki = wikiContext, !wiki.isEmpty {
            prompt += "\n\n\(wiki)"
        }
        if let server = serverName, !server.isEmpty {
            prompt += "\nServer: \(server)"
        }
        if let channel = channelName, !channel.isEmpty {
            prompt += "\nChannel: \(channel)"
        }
        prompt += "\nCurrent Time: \(timeFormatter.string(from: Date()))"
        return prompt
    }

    /// Prepends a system message and filters empty/system-role messages from history.
    static func buildMessages(systemPrompt: String, history: [Message]) -> [Message] {
        let clean = history.filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.role != .system
        }
        let systemMessage = Message(
            channelID: "system",
            userID: "system",
            username: "System",
            content: systemPrompt,
            role: .system
        )
        return [systemMessage] + clean
    }
}

/// A simple helper for interacting with the macOS Keychain.
enum KeychainHelper {
    private static let service = "com.swiftbot.app"
    private static let account = "discord-token"

    /// Saves the token to the Keychain.
    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        // Delete any existing item before saving the new one.
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieves the token from the Keychain.
    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }

        return nil
    }

    /// Deletes the token from the Keychain.
    @discardableResult
    static func deleteToken() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
}
