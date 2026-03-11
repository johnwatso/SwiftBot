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

enum AdminWebUICertificateMode: String, Codable, Hashable, CaseIterable, Identifiable {
    case automatic
    case importCertificate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "Automatic (Let's Encrypt)"
        case .importCertificate:
            return "Import Certificate"
        }
    }
}

struct OAuthProviderSettings: Codable, Hashable {
    var enabled: Bool = false
    var clientID: String = ""
    var clientSecret: String = ""
}

struct AdminWebUISettings: Codable, Hashable {
    // Internal constants (not user-configurable)
    static let defaultBindHost = "127.0.0.1"
    static let defaultPort = 38888
    
    var enabled: Bool = false
    var publicBaseURL: String = ""
    var internetAccessEnabled: Bool = false
    var hostname: String = ""
    var subdomain: String = "swiftbot"
    var selectedZoneID: String = ""
    var selectedZoneName: String = ""
    var cloudflareAPIToken: String = ""
    
    // Legacy compatibility - always returns fixed values
    var bindHost: String { Self.defaultBindHost }
    var port: Int { Self.defaultPort }
    var httpsEnabled: Bool { false }
    var certificateMode: AdminWebUICertificateMode { .automatic }
    var publicAccessEnabled: Bool { internetAccessEnabled }
    var publicAccessTunnelID: String = ""
    var publicAccessTunnelName: String = ""
    var publicAccessTunnelAccountID: String = ""
    var publicAccessTunnelToken: String = ""
    var importedCertificateFile: String = ""
    var importedPrivateKeyFile: String = ""
    var importedCertificateChainFile: String = ""
    
    // OAuth Providers (Discord is active, others are placeholders)
    var discordOAuth = OAuthProviderSettings()
    var appleOAuth = OAuthProviderSettings()
    var steamOAuth = OAuthProviderSettings()
    var githubOAuth = OAuthProviderSettings()
    
    // Legacy compatibility - migrated to oauth providers
    var discordClientID: String { discordOAuth.clientID }
    var discordClientSecret: String { discordOAuth.clientSecret }
    var redirectPath: String = "/auth/discord/callback"
    var restrictAccessToSpecificUsers: Bool = false
    var allowedUserIDs: [String] = []

    var normalizedHostname: String {
        if !subdomain.isEmpty && !selectedZoneName.isEmpty {
            return "\(subdomain.lowercased()).\(selectedZoneName.lowercased())"
        }
        return normalizeHostname(hostname)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case publicBaseURL
        case internetAccessEnabled
        case hostname
        case subdomain
        case selectedZoneID
        case selectedZoneName
        case cloudflareAPIToken
        case publicAccessTunnelID
        case publicAccessTunnelName
        case publicAccessTunnelAccountID
        case publicAccessTunnelToken
        case discordOAuth
        case appleOAuth
        case steamOAuth
        case githubOAuth
        case redirectPath
        case restrictAccessToSpecificUsers
        case allowedUserIDs
        // Legacy keys for migration
        case bindHost
        case port
        case httpsEnabled
        case certificateMode
        case publicAccessEnabled
        case importedCertificateFile
        case importedPrivateKeyFile
        case importedCertificateChainFile
        case discordClientID
        case discordClientSecret
    }

    init() {
        self.discordOAuth.enabled = true
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        publicBaseURL = try container.decodeIfPresent(String.self, forKey: .publicBaseURL) ?? ""
        
        // Migration: prefer hostname
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        subdomain = try container.decodeIfPresent(String.self, forKey: .subdomain) ?? "swiftbot"
        selectedZoneID = try container.decodeIfPresent(String.self, forKey: .selectedZoneID) ?? ""
        selectedZoneName = try container.decodeIfPresent(String.self, forKey: .selectedZoneName) ?? ""
        
        cloudflareAPIToken = try container.decodeIfPresent(String.self, forKey: .cloudflareAPIToken) ?? ""
        
        // Migration: internetAccessEnabled replaces publicAccessEnabled
        let decodedInternetAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .internetAccessEnabled)
        let decodedPublicAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .publicAccessEnabled)
        internetAccessEnabled = decodedInternetAccessEnabled ?? decodedPublicAccessEnabled ?? false
        
        publicAccessTunnelID = try container.decodeIfPresent(String.self, forKey: .publicAccessTunnelID) ?? ""
        publicAccessTunnelName = try container.decodeIfPresent(String.self, forKey: .publicAccessTunnelName) ?? ""
        publicAccessTunnelAccountID = try container.decodeIfPresent(String.self, forKey: .publicAccessTunnelAccountID) ?? ""
        publicAccessTunnelToken = try container.decodeIfPresent(String.self, forKey: .publicAccessTunnelToken) ?? ""
        
        // OAuth Providers - decode or migrate from legacy fields
        discordOAuth = try container.decodeIfPresent(OAuthProviderSettings.self, forKey: .discordOAuth)
            ?? OAuthProviderSettings(
                enabled: (try? container.decodeIfPresent(String.self, forKey: .discordClientID))?.isEmpty == false,
                clientID: try container.decodeIfPresent(String.self, forKey: .discordClientID) ?? "",
                clientSecret: try container.decodeIfPresent(String.self, forKey: .discordClientSecret) ?? ""
            )
        appleOAuth = try container.decodeIfPresent(OAuthProviderSettings.self, forKey: .appleOAuth) ?? OAuthProviderSettings()
        steamOAuth = try container.decodeIfPresent(OAuthProviderSettings.self, forKey: .steamOAuth) ?? OAuthProviderSettings()
        githubOAuth = try container.decodeIfPresent(OAuthProviderSettings.self, forKey: .githubOAuth) ?? OAuthProviderSettings()
        
        redirectPath = try container.decodeIfPresent(String.self, forKey: .redirectPath) ?? "/auth/discord/callback"
        allowedUserIDs = try container.decodeIfPresent([String].self, forKey: .allowedUserIDs) ?? []
        restrictAccessToSpecificUsers = try container.decodeIfPresent(Bool.self, forKey: .restrictAccessToSpecificUsers)
            ?? !allowedUserIDs.isEmpty
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(publicBaseURL, forKey: .publicBaseURL)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(subdomain, forKey: .subdomain)
        try container.encode(selectedZoneID, forKey: .selectedZoneID)
        try container.encode(selectedZoneName, forKey: .selectedZoneName)
        try container.encode(cloudflareAPIToken, forKey: .cloudflareAPIToken)
        try container.encode(internetAccessEnabled, forKey: .internetAccessEnabled)
        try container.encode(publicAccessTunnelID, forKey: .publicAccessTunnelID)
        try container.encode(publicAccessTunnelName, forKey: .publicAccessTunnelName)
        try container.encode(publicAccessTunnelAccountID, forKey: .publicAccessTunnelAccountID)
        try container.encode(publicAccessTunnelToken, forKey: .publicAccessTunnelToken)
        try container.encode(importedCertificateFile, forKey: .importedCertificateFile)
        try container.encode(importedPrivateKeyFile, forKey: .importedPrivateKeyFile)
        try container.encode(importedCertificateChainFile, forKey: .importedCertificateChainFile)
        try container.encode(discordOAuth, forKey: .discordOAuth)
        try container.encode(appleOAuth, forKey: .appleOAuth)
        try container.encode(steamOAuth, forKey: .steamOAuth)
        try container.encode(githubOAuth, forKey: .githubOAuth)
        try container.encode(redirectPath, forKey: .redirectPath)
        try container.encode(restrictAccessToSpecificUsers, forKey: .restrictAccessToSpecificUsers)
        try container.encode(allowedUserIDs, forKey: .allowedUserIDs)
    }

    var normalizedAllowedUserIDs: [String] {
        allowedUserIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var normalizedImportedCertificateFile: String {
        importedCertificateFile.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedImportedPrivateKeyFile: String {
        importedPrivateKeyFile.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedImportedCertificateChainFile: String {
        importedCertificateChainFile.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeHostname(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let url = URL(string: trimmed), let host = url.host {
            return host.lowercased()
        }

        let normalized = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        if let slashIndex = normalized.firstIndex(of: "/") {
            return String(normalized[..<slashIndex])
        }

        return normalized
    }
}

struct BotSettings: Codable, Hashable {
    var token: String = ""
    var prefix: String = "/"
    var commandsEnabled: Bool = true
    var prefixCommandsEnabled: Bool = true
    var slashCommandsEnabled: Bool = true
    var bugTrackingEnabled: Bool = true
    var disabledCommandKeys: Set<String> = []
    var autoStart: Bool = false
    var guildSettings: [String: GuildSettings] = [:]
    var clusterMode: ClusterMode = .standalone
    var clusterNodeName: String = Host.current().localizedName ?? "SwiftBot Node"
    var clusterLeaderAddress: String = ""
    var clusterLeaderPort: Int = 38787
    var clusterListenPort: Int = 38787
    var clusterSharedSecret: String = ""
    var clusterLeaderTerm: Int = 0
    var clusterWorkerOffloadEnabled: Bool = false
    var clusterOffloadAIReplies: Bool = false
    var clusterOffloadWikiLookups: Bool = false

    // Local AI reply settings for DMs and guild mentions.
    var localAIDMReplyEnabled: Bool = false
    var localAIProvider: AIProvider = .appleIntelligence
    var preferredAIProvider: AIProviderPreference = .apple
    var localAIEndpoint: String = "http://127.0.0.1:1234/v1/chat/completions"
    var localAIModel: String = "local-model"
    var ollamaBaseURL: String = "http://localhost:11434"
    var ollamaEnabled: Bool = true
    var openAIEnabled: Bool = true
    var openAIAPIKey: String = ""
    var openAIModel: String = "gpt-4o-mini"
    var openAIImageGenerationEnabled: Bool = true
    var openAIImageModel: String = "gpt-image-1"
    var openAIImageMonthlyLimitPerUser: Int = 5
    var openAIImageMonthlyHardCap: Int = 100
    var openAIImageUsageByUserMonth: [String: Int] = [:]
    var devFeaturesEnabled: Bool = false
    var bugAutoFixEnabled: Bool = false
    var bugAutoFixTriggerEmoji: String = "🤖"
    var bugAutoFixCommandTemplate: String = "codex exec \"$SWIFTBOT_BUG_PROMPT\""
    var bugAutoFixRepoPath: String = ""
    var bugAutoFixGitBranch: String = "main"
    var bugAutoFixVersionBumpEnabled: Bool = true
    var bugAutoFixPushEnabled: Bool = true
    var bugAutoFixRequireApproval: Bool = true
    var bugAutoFixApproveEmoji: String = "🚀"
    var bugAutoFixRejectEmoji: String = "🛑"
    var bugAutoFixAllowedUsernames: [String] = []
    var aiMemoryNotes: [AIMemoryNote] = []
    var localAISystemPrompt: String = "You are a friendly, casual Discord bot. Keep replies short and conversational — 1 to 3 sentences max unless asked for detail. Use contractions naturally. Don't restate what the user said. Don't open every reply the same way. Match the energy of the conversation."
    var behavior = BotBehaviorSettings()
    var wikiBot = WikiBotSettings()
    var patchy = PatchySettings()
    var help = HelpSettings()
    var adminWebUI = AdminWebUISettings()

    var swiftMeshSettings: SwiftMeshSettings {
        get {
            SwiftMeshSettings(
                mode: clusterMode,
                nodeName: clusterNodeName,
                leaderAddress: clusterLeaderAddress,
                leaderPort: clusterLeaderPort,
                listenPort: clusterListenPort,
                sharedSecret: clusterSharedSecret,
                leaderTerm: clusterLeaderTerm
            )
        }
        set {
            clusterMode = newValue.mode
            clusterNodeName = newValue.nodeName
            clusterLeaderAddress = newValue.leaderAddress
            clusterLeaderPort = newValue.leaderPort
            clusterListenPort = newValue.listenPort
            clusterSharedSecret = newValue.sharedSecret
            clusterLeaderTerm = newValue.leaderTerm
        }
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case prefix
        case commandsEnabled
        case prefixCommandsEnabled
        case slashCommandsEnabled
        case bugTrackingEnabled
        case disabledCommandKeys
        case autoStart
        case guildSettings
        case clusterMode
        case clusterNodeName
        case clusterLeaderAddress
        case clusterLeaderPort
        case clusterWorkerBaseURLLegacy = "clusterWorkerBaseURL"
        case clusterListenPort
        case clusterSharedSecret
        case clusterLeaderTerm
        case clusterWorkerOffloadEnabled
        case clusterOffloadAIReplies
        case clusterOffloadWikiLookups
        case localAIDMReplyEnabled
        case localAIProvider
        case preferredAIProvider
        case localAIEndpoint
        case localAIModel
        case ollamaBaseURL
        case ollamaEnabled
        case openAIEnabled
        case openAIAPIKey
        case openAIModel
        case openAIImageGenerationEnabled
        case openAIImageModel
        case openAIImageMonthlyLimitPerUser
        case openAIImageMonthlyHardCap
        case openAIImageUsageByUserMonth
        case devFeaturesEnabled
        case bugAutoFixEnabled
        case bugAutoFixTriggerEmoji
        case bugAutoFixCommandTemplate
        case bugAutoFixRepoPath
        case bugAutoFixGitBranch
        case bugAutoFixVersionBumpEnabled
        case bugAutoFixPushEnabled
        case bugAutoFixRequireApproval
        case bugAutoFixApproveEmoji
        case bugAutoFixRejectEmoji
        case bugAutoFixAllowedUsernames
        case aiMemoryNotes
        case localAISystemPrompt
        case behavior
        case wikiBot
        case patchy
        case help
        case adminWebUI
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? "/"
        commandsEnabled = try container.decodeIfPresent(Bool.self, forKey: .commandsEnabled) ?? true
        prefixCommandsEnabled = try container.decodeIfPresent(Bool.self, forKey: .prefixCommandsEnabled) ?? true
        slashCommandsEnabled = try container.decodeIfPresent(Bool.self, forKey: .slashCommandsEnabled) ?? true
        bugTrackingEnabled = try container.decodeIfPresent(Bool.self, forKey: .bugTrackingEnabled) ?? true
        disabledCommandKeys = try container.decodeIfPresent(Set<String>.self, forKey: .disabledCommandKeys) ?? []
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        guildSettings = try container.decodeIfPresent([String: GuildSettings].self, forKey: .guildSettings) ?? [:]
        clusterMode = try container.decodeIfPresent(ClusterMode.self, forKey: .clusterMode) ?? .standalone
        clusterNodeName = try container.decodeIfPresent(String.self, forKey: .clusterNodeName) ?? (Host.current().localizedName ?? "SwiftBot Node")
        clusterLeaderAddress = try container.decodeIfPresent(String.self, forKey: .clusterLeaderAddress)
            ?? (try container.decodeIfPresent(String.self, forKey: .clusterWorkerBaseURLLegacy) ?? "")
        clusterLeaderPort = try container.decodeIfPresent(Int.self, forKey: .clusterLeaderPort) ?? 38787
        clusterListenPort = try container.decodeIfPresent(Int.self, forKey: .clusterListenPort) ?? 38787
        clusterSharedSecret = try container.decodeIfPresent(String.self, forKey: .clusterSharedSecret) ?? ""
        clusterLeaderTerm = try container.decodeIfPresent(Int.self, forKey: .clusterLeaderTerm) ?? 0
        let decodedOffloadAIReplies = try container.decodeIfPresent(Bool.self, forKey: .clusterOffloadAIReplies) ?? false
        let decodedOffloadWikiLookups = try container.decodeIfPresent(Bool.self, forKey: .clusterOffloadWikiLookups) ?? false
        clusterWorkerOffloadEnabled = try container.decodeIfPresent(Bool.self, forKey: .clusterWorkerOffloadEnabled)
            ?? (decodedOffloadAIReplies || decodedOffloadWikiLookups)
        clusterOffloadAIReplies = decodedOffloadAIReplies
        clusterOffloadWikiLookups = decodedOffloadWikiLookups
        localAIDMReplyEnabled = try container.decodeIfPresent(Bool.self, forKey: .localAIDMReplyEnabled) ?? false
        localAIProvider = try container.decodeIfPresent(AIProvider.self, forKey: .localAIProvider) ?? .appleIntelligence
        preferredAIProvider = try container.decodeIfPresent(AIProviderPreference.self, forKey: .preferredAIProvider) ?? .apple
        localAIEndpoint = try container.decodeIfPresent(String.self, forKey: .localAIEndpoint) ?? "http://127.0.0.1:1234/v1/chat/completions"
        localAIModel = try container.decodeIfPresent(String.self, forKey: .localAIModel) ?? "local-model"
        ollamaBaseURL = try container.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://localhost:11434"
        ollamaEnabled = try container.decodeIfPresent(Bool.self, forKey: .ollamaEnabled) ?? true
        openAIEnabled = try container.decodeIfPresent(Bool.self, forKey: .openAIEnabled) ?? true
        openAIAPIKey = try container.decodeIfPresent(String.self, forKey: .openAIAPIKey) ?? ""
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? "gpt-4o-mini"
        openAIImageGenerationEnabled = try container.decodeIfPresent(Bool.self, forKey: .openAIImageGenerationEnabled) ?? true
        openAIImageModel = try container.decodeIfPresent(String.self, forKey: .openAIImageModel) ?? "gpt-image-1"
        openAIImageMonthlyLimitPerUser = try container.decodeIfPresent(Int.self, forKey: .openAIImageMonthlyLimitPerUser) ?? 5
        openAIImageMonthlyHardCap = try container.decodeIfPresent(Int.self, forKey: .openAIImageMonthlyHardCap) ?? 100
        openAIImageUsageByUserMonth = try container.decodeIfPresent([String: Int].self, forKey: .openAIImageUsageByUserMonth) ?? [:]
        devFeaturesEnabled = try container.decodeIfPresent(Bool.self, forKey: .devFeaturesEnabled) ?? false
        bugAutoFixEnabled = try container.decodeIfPresent(Bool.self, forKey: .bugAutoFixEnabled) ?? false
        bugAutoFixTriggerEmoji = try container.decodeIfPresent(String.self, forKey: .bugAutoFixTriggerEmoji) ?? "🤖"
        bugAutoFixCommandTemplate = try container.decodeIfPresent(String.self, forKey: .bugAutoFixCommandTemplate) ?? "codex exec \"$SWIFTBOT_BUG_PROMPT\""
        bugAutoFixRepoPath = try container.decodeIfPresent(String.self, forKey: .bugAutoFixRepoPath) ?? ""
        bugAutoFixGitBranch = try container.decodeIfPresent(String.self, forKey: .bugAutoFixGitBranch) ?? "main"
        bugAutoFixVersionBumpEnabled = try container.decodeIfPresent(Bool.self, forKey: .bugAutoFixVersionBumpEnabled) ?? true
        bugAutoFixPushEnabled = try container.decodeIfPresent(Bool.self, forKey: .bugAutoFixPushEnabled) ?? true
        bugAutoFixRequireApproval = try container.decodeIfPresent(Bool.self, forKey: .bugAutoFixRequireApproval) ?? true
        bugAutoFixApproveEmoji = try container.decodeIfPresent(String.self, forKey: .bugAutoFixApproveEmoji) ?? "🚀"
        bugAutoFixRejectEmoji = try container.decodeIfPresent(String.self, forKey: .bugAutoFixRejectEmoji) ?? "🛑"
        bugAutoFixAllowedUsernames = try container.decodeIfPresent([String].self, forKey: .bugAutoFixAllowedUsernames) ?? []
        aiMemoryNotes = try container.decodeIfPresent([AIMemoryNote].self, forKey: .aiMemoryNotes) ?? []
        localAISystemPrompt = try container.decodeIfPresent(String.self, forKey: .localAISystemPrompt) ?? "You are a friendly, casual Discord bot. Keep replies short and conversational — 1 to 3 sentences max unless asked for detail. Use contractions naturally. Don't restate what the user said. Don't open every reply the same way. Match the energy of the conversation."
        behavior = try container.decodeIfPresent(BotBehaviorSettings.self, forKey: .behavior) ?? BotBehaviorSettings()
        wikiBot = try container.decodeIfPresent(WikiBotSettings.self, forKey: .wikiBot) ?? WikiBotSettings()
        patchy = try container.decodeIfPresent(PatchySettings.self, forKey: .patchy) ?? PatchySettings()
        help = try container.decodeIfPresent(HelpSettings.self, forKey: .help) ?? HelpSettings()
        adminWebUI = try container.decodeIfPresent(AdminWebUISettings.self, forKey: .adminWebUI) ?? AdminWebUISettings()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(prefix, forKey: .prefix)
        try container.encode(commandsEnabled, forKey: .commandsEnabled)
        try container.encode(prefixCommandsEnabled, forKey: .prefixCommandsEnabled)
        try container.encode(slashCommandsEnabled, forKey: .slashCommandsEnabled)
        try container.encode(bugTrackingEnabled, forKey: .bugTrackingEnabled)
        try container.encode(disabledCommandKeys, forKey: .disabledCommandKeys)
        try container.encode(autoStart, forKey: .autoStart)
        try container.encode(guildSettings, forKey: .guildSettings)
        try container.encode(clusterMode, forKey: .clusterMode)
        try container.encode(clusterNodeName, forKey: .clusterNodeName)
        try container.encode(clusterLeaderAddress, forKey: .clusterLeaderAddress)
        try container.encode(clusterListenPort, forKey: .clusterListenPort)
        try container.encode(clusterSharedSecret, forKey: .clusterSharedSecret)
        try container.encode(clusterLeaderTerm, forKey: .clusterLeaderTerm)
        try container.encode(clusterWorkerOffloadEnabled, forKey: .clusterWorkerOffloadEnabled)
        try container.encode(clusterOffloadAIReplies, forKey: .clusterOffloadAIReplies)
        try container.encode(clusterOffloadWikiLookups, forKey: .clusterOffloadWikiLookups)
        try container.encode(localAIDMReplyEnabled, forKey: .localAIDMReplyEnabled)

        try container.encode(localAIProvider, forKey: .localAIProvider)
        try container.encode(preferredAIProvider, forKey: .preferredAIProvider)
        try container.encode(localAIEndpoint, forKey: .localAIEndpoint)
        try container.encode(localAIModel, forKey: .localAIModel)
        try container.encode(ollamaBaseURL, forKey: .ollamaBaseURL)
        try container.encode(ollamaEnabled, forKey: .ollamaEnabled)
        try container.encode(openAIEnabled, forKey: .openAIEnabled)
        try container.encode(openAIAPIKey, forKey: .openAIAPIKey)
        try container.encode(openAIModel, forKey: .openAIModel)
        try container.encode(openAIImageGenerationEnabled, forKey: .openAIImageGenerationEnabled)
        try container.encode(openAIImageModel, forKey: .openAIImageModel)
        try container.encode(openAIImageMonthlyLimitPerUser, forKey: .openAIImageMonthlyLimitPerUser)
        try container.encode(openAIImageMonthlyHardCap, forKey: .openAIImageMonthlyHardCap)
        try container.encode(openAIImageUsageByUserMonth, forKey: .openAIImageUsageByUserMonth)
        try container.encode(devFeaturesEnabled, forKey: .devFeaturesEnabled)
        try container.encode(bugAutoFixEnabled, forKey: .bugAutoFixEnabled)
        try container.encode(bugAutoFixTriggerEmoji, forKey: .bugAutoFixTriggerEmoji)
        try container.encode(bugAutoFixCommandTemplate, forKey: .bugAutoFixCommandTemplate)
        try container.encode(bugAutoFixRepoPath, forKey: .bugAutoFixRepoPath)
        try container.encode(bugAutoFixGitBranch, forKey: .bugAutoFixGitBranch)
        try container.encode(bugAutoFixVersionBumpEnabled, forKey: .bugAutoFixVersionBumpEnabled)
        try container.encode(bugAutoFixPushEnabled, forKey: .bugAutoFixPushEnabled)
        try container.encode(bugAutoFixRequireApproval, forKey: .bugAutoFixRequireApproval)
        try container.encode(bugAutoFixApproveEmoji, forKey: .bugAutoFixApproveEmoji)
        try container.encode(bugAutoFixRejectEmoji, forKey: .bugAutoFixRejectEmoji)
        try container.encode(bugAutoFixAllowedUsernames, forKey: .bugAutoFixAllowedUsernames)
        try container.encode(aiMemoryNotes, forKey: .aiMemoryNotes)
        try container.encode(localAISystemPrompt, forKey: .localAISystemPrompt)
        try container.encode(behavior, forKey: .behavior)
        try container.encode(wikiBot, forKey: .wikiBot)
        try container.encode(patchy, forKey: .patchy)
        try container.encode(help, forKey: .help)
        try container.encode(adminWebUI, forKey: .adminWebUI)
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

struct SwiftMeshSettings: Codable, Hashable {
    var mode: ClusterMode = .standalone
    var nodeName: String = Host.current().localizedName ?? "SwiftBot Node"
    var leaderAddress: String = ""
    var leaderPort: Int = 38787
    var listenPort: Int = 38787
    var sharedSecret: String = ""
    var leaderTerm: Int = 0
}

struct MeshSyncedFile: Codable, Hashable {
    let fileName: String
    let base64Data: String
}

struct MeshSyncedFilesPayload: Codable, Hashable {
    let generatedAt: Date
    let files: [MeshSyncedFile]
}

enum ClusterMode: String, Codable, CaseIterable, Identifiable {
    case standalone = "Standalone"
    case leader = "Leader"
    case worker = "Worker"
    case standby = "Standby"

    var id: String { rawValue }

    static var selectableCases: [ClusterMode] {
        [.standalone, .leader, .standby]
    }

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
        case .standalone: return "Normal operation. All bot features are managed locally."
        case .leader:     return "This node acts as the Primary controller for the SwiftMesh cluster."
        case .worker:     return "Deprecated. This node performs offloaded compute tasks for the Primary."
        case .standby:    return "This node will automatically promote to Primary if the current Leader fails."
        }
    }
}

/// Central authority for Discord output actions in a SwiftMesh cluster.
///
/// All outbound Discord actions must pass through this gate before execution.
/// Only Primary nodes (`.standalone` or `.leader`) are permitted to perform
/// Discord side-effects. Worker and Standby nodes are blocked at this layer.
///
/// This design is intentionally extensible: in future, `canSend` can be updated
/// to route blocked actions to a Primary node via SwiftMesh HTTP instead of
/// simply discarding them, enabling distributed task delegation.
enum ActionDispatcher {

    /// Returns `true` if the current node is permitted to send Discord output.
    ///
    /// - Parameters:
    ///   - clusterMode: The current SwiftMesh cluster role of this node.
    ///   - action: A descriptive label for the action being attempted (used in logs).
    ///   - log: A closure that receives warning messages when an action is blocked.
    /// - Returns: `true` if the node may proceed; `false` if the action is blocked.
    static func canSend(
        clusterMode: ClusterMode,
        action: String,
        log: (String) -> Void
    ) -> Bool {
        guard clusterMode == .standalone || clusterMode == .leader else {
            log("⚠️ [ActionDispatcher] Blocked '\(action)' — node role '\(clusterMode.rawValue)' is not authorised to send Discord output. Only Primary (Standalone/Leader) may perform Discord side-effects.")
            return false
        }
        return true
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
    let imageUsage: [String: Int]?
    let leaderTerm: Int
    /// ID of the last record in this batch — standby stores as its new cursor.
    let cursorRecordID: String?
    /// True if more records exist beyond this batch; standby should request resync for next page.
    let hasMore: Bool
    /// The cursor the leader assumed this node held when building this batch.
    /// Node compares against its own lastMergedRecordID to detect gaps.
    let fromCursorRecordID: String?

    init(conversations: [MemoryRecord], imageUsage: [String: Int]? = nil, leaderTerm: Int, cursorRecordID: String? = nil, hasMore: Bool = false, fromCursorRecordID: String? = nil) {
        self.conversations = conversations
        self.imageUsage = imageUsage
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

enum BugStatus: String, Codable, Hashable {
    case new = "New"
    case workingOn = "Working On"
    case inProgress = "In Progress"
    case blocked = "Blocked"
    case resolved = "Resolved"

    var emoji: String {
        switch self {
        case .new:
            return "🐞"
        case .workingOn:
            return "🔧"
        case .inProgress:
            return "🟡"
        case .blocked:
            return "⛔"
        case .resolved:
            return "✅"
        }
    }
}

struct BugEntry: Hashable, Codable {
    let bugMessageID: String
    let sourceMessageID: String
    let channelID: String
    let guildID: String
    let reporterID: String
    let createdBy: String
    var status: BugStatus
    var timestamp: Date
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
    let permissions: String?
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
        case memberLeave
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
    let messageId: String?
    let triggerMessageId: String?
    let triggerChannelId: String?
    let triggerGuildId: String
    let triggerUserId: String
    let isDirectMessage: Bool
    let authorIsBot: Bool?
    let joinedAt: Date?
}

@MainActor
final class RuleStore: ObservableObject {
    @Published var rules: [Rule] = []
    @Published var selectedRuleID: UUID?
    @Published var lastSavedAt: Date?
    @Published var isLoading: Bool = false

    private let store = RuleConfigStore()
    private var autoSaveTask: Task<Void, Never>?

    init() {
        Task {
            isLoading = true
            let loaded = await store.load()
            rules = loaded ?? []
            selectedRuleID = nil
            isLoading = false
        }
    }

    func addNewRule(serverId: String = "", channelId: String = "") {
        var rule = Rule.empty()
        rule.triggerServerId = serverId
        // New rules start empty - users add blocks via Block Library
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

    func reloadFromDisk() async {
        isLoading = true
        let loaded = await store.load()
        rules = loaded ?? []
        if let selected = selectedRuleID,
           !rules.contains(where: { $0.id == selected }) {
            selectedRuleID = nil
        }
        isLoading = false
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

/// Context maintained during a single rule execution pipeline
struct PipelineContext: CustomStringConvertible {
    var aiResponse: String?
    var aiSummary: String?
    var aiClassification: String?
    var aiEntities: String?
    var aiRewrite: String?
    var triggerGuildId: String?
    var triggerChannelId: String?
    var triggerMessageId: String?
    var targetChannelId: String?
    var targetServerId: String?
    var mentionUser: Bool = true
    var prependUserMention: Bool = false
    var replyToTriggerMessage: Bool = false
    var mentionRole: String?
    var isDirectMessage: Bool = false
    var sendToDM: Bool = false
    var eventHandled: Bool = false

    var description: String {
        let ai = aiResponse != nil ? "AI(\(aiResponse!.count) chars)" : "nil"
        let summary = aiSummary != nil ? "Summary(\(aiSummary!.count) chars)" : "nil"
        let target = targetChannelId ?? "default"
        let trigger = triggerChannelId ?? "none"
        return "[PipelineContext target: \(target), trigger: \(trigger), mentionUser: \(mentionUser), prepend: \(prependUserMention), reply: \(replyToTriggerMessage), role: \(mentionRole ?? "nil"), ai: \(ai), summary: \(summary), handled: \(eventHandled)]"
    }
}

@MainActor
final class RuleEngine {
    private var cancellable: AnyCancellable?
    private var activeRules: [Rule] = []

    init(store: RuleStore) {
        activeRules = store.rules.filter(\.isEnabled)
        cancellable = store.$rules.sink { [weak self] rules in
            self?.activeRules = rules.filter(\.isEnabled)
        }
    }

    func evaluateRules(event: VoiceRuleEvent) -> [Rule] {
        activeRules
            .filter { rule in matchesTrigger(rule: rule, event: event) && matchesConditions(rule: rule, event: event) }
    }

    private func matchesTrigger(rule: Rule, event: VoiceRuleEvent) -> Bool {
        guard let trigger = rule.trigger else { return false }
        switch (trigger, event.kind) {
        case (.userJoinedVoice, .join),
             (.userLeftVoice, .leave),
             (.userMovedVoice, .move),
             (.messageCreated, .message),
             (.memberJoined, .memberJoin):
            return true
        default:
            return false
        }
    }

    private func matchesConditions(rule: Rule, event: VoiceRuleEvent) -> Bool {
        for condition in rule.conditions {
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
            // Voice channel conditions don't apply to member join/leave events — always pass.
            if event.kind == .memberJoin || event.kind == .memberLeave { return true }
            return value.isEmpty || event.channelId == value || event.fromChannelId == value || event.toChannelId == value
        case .usernameContains:
            guard !value.isEmpty else { return true }
            return event.username.localizedCaseInsensitiveContains(value)
        case .minimumDuration:
            // Duration conditions don't apply to member join events — always pass.
            if event.kind == .memberJoin || event.kind == .memberLeave { return true }
            guard let minimum = Int(value), minimum > 0 else { return true }
            guard let durationSeconds = event.durationSeconds else { return false }
            return durationSeconds >= (minimum * 60)
        case .channelIs:
            // Channel conditions don't apply to voice events — always pass for now
            return value.isEmpty || event.channelId == value
        case .channelCategory:
            // Channel category matching logic: typically we'd need channel metadata
            // For now, treat as placeholder that always passes if not configured
            return true
        case .userHasRole:
            // Role conditions not yet implemented for voice events — always pass
            return true
        case .userJoinedRecently:
            guard let minutes = Int(value), minutes > 0 else { return true }
            guard let joinedAt = event.joinedAt else { return false }
            return Date().timeIntervalSince(joinedAt) <= Double(minutes * 60)
        case .messageContains:
            guard !value.isEmpty, let content = event.messageContent else { return true }
            return content.localizedCaseInsensitiveContains(value)
        case .messageStartsWith:
            guard !value.isEmpty, let content = event.messageContent else { return true }
            return content.lowercased().hasPrefix(value.lowercased())
        case .messageRegex:
            guard !value.isEmpty, let content = event.messageContent else { return true }
            // Basic regex matching - returns true on invalid regex to avoid breaking rules
            guard let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { return true }
            let range = NSRange(content.startIndex..., in: content)
            return regex.firstMatch(in: content, options: [], range: range) != nil
        case .isDirectMessage:
            return event.isDirectMessage
        case .isFromBot:
            return event.authorIsBot ?? false
        case .isFromUser:
            // Filter out bot messages if value is empty or "true"
            return !(event.authorIsBot ?? false)
        case .channelType:
            // Channel type matching - placeholder for now
            // Would need channel type metadata from Discord
            return true
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
        save(token, account: account)
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

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
        load(account: account)
    }

    static func load(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

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
        delete(account: account)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
}

// MARK: - Navigation Models

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case patchy = "Patchy"
    case voice = "Actions"
    case commands = "Commands"
    case commandLog = "Command Log"
    case wikiBridge = "WikiBridge"
    case logs = "Logs"
    case aiBots = "AI Bots"
    case diagnostics = "Diagnostics"
    case swiftMesh = "SwiftMesh"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .patchy: return "hammer.fill"
        case .voice: return "bolt.circle"
        case .commands: return "terminal.fill"
        case .commandLog: return "list.bullet.clipboard.fill"
        case .wikiBridge: return "book.pages.fill"
        case .logs: return "list.bullet.clipboard.fill"
        case .aiBots: return "sparkles.rectangle.stack.fill"
        case .diagnostics: return "waveform.path.ecg"
        case .swiftMesh: return "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: - Automation Models

// MARK: - Context Variables

/// Variables available in rule templates based on trigger context
enum ContextVariable: String, CaseIterable, Codable, Hashable {
    case user = "{user}"
    case userId = "{user.id}"
    case username = "{user.name}"
    case userNickname = "{user.nickname}"
    case userMention = "{user.mention}"
    case message = "{message}"
    case messageId = "{message.id}"
    case channel = "{channel}"
    case channelId = "{channel.id}"
    case channelName = "{channel.name}"
    case guild = "{guild}"
    case guildId = "{guild.id}"
    case guildName = "{guild.name}"
    case voiceChannel = "{voice.channel}"
    case voiceChannelId = "{voice.channel.id}"
    case reaction = "{reaction}"
    case reactionEmoji = "{reaction.emoji}"
    case duration = "{duration}"
    case memberCount = "{memberCount}"
    case aiResponse = "{ai.response}"
    case aiSummary = "{ai.summary}"
    case aiClassification = "{ai.classification}"
    case aiEntities = "{ai.entities}"
    case aiRewrite = "{ai.rewrite}"
    
    var displayName: String {
        switch self {
        case .user: return "User"
        case .userId: return "User ID"
        case .username: return "Username"
        case .userNickname: return "Nickname"
        case .userMention: return "@Mention"
        case .message: return "Message Content"
        case .messageId: return "Message ID"
        case .channel: return "Channel"
        case .channelId: return "Channel ID"
        case .channelName: return "Channel Name"
        case .guild: return "Server"
        case .guildId: return "Server ID"
        case .guildName: return "Server Name"
        case .voiceChannel: return "Voice Channel"
        case .voiceChannelId: return "Voice Channel ID"
        case .reaction: return "Reaction"
        case .reactionEmoji: return "Emoji"
        case .duration: return "Duration"
        case .memberCount: return "Member Count"
        case .aiResponse: return "AI Response"
        case .aiSummary: return "AI Summary"
        case .aiClassification: return "AI Classification"
        case .aiEntities: return "AI Entities"
        case .aiRewrite: return "AI Rewrite"
        }
    }
    
    var category: String {
        switch self {
        case .user, .userId, .username, .userNickname, .userMention:
            return "User"
        case .message, .messageId:
            return "Message"
        case .channel, .channelId, .channelName:
            return "Channel"
        case .guild, .guildId, .guildName:
            return "Server"
        case .voiceChannel, .voiceChannelId:
            return "Voice"
        case .reaction, .reactionEmoji:
            return "Reaction"
        case .duration, .memberCount:
            return "Other"
        case .aiResponse, .aiSummary, .aiClassification, .aiEntities, .aiRewrite:
            return "AI"
        }
    }
}

extension Set where Element == ContextVariable {
    /// Returns a user-friendly description of the required context (Task 1)
    var friendlyRequirement: String {
        if self.isEmpty { return "" }
        
        // Priority based on trigger types
        if self.contains(where: { $0.category == "Message" || $0.category == "Reaction" }) {
            return "a message trigger"
        }
        if self.contains(where: { $0.category == "Channel" || $0.category == "Voice" }) {
            return "a channel event"
        }
        if self.contains(where: { $0.category == "User" }) {
            return "a user trigger"
        }
        
        return "additional context"
    }
}

// MARK: - Discord Permissions

/// Discord permission flags for validation
enum DiscordPermission: String, CaseIterable, Codable, Hashable {
    case createInstantInvite = "CREATE_INSTANT_INVITE"
    case kickMembers = "KICK_MEMBERS"
    case banMembers = "BAN_MEMBERS"
    case administrator = "ADMINISTRATOR"
    case manageChannels = "MANAGE_CHANNELS"
    case manageGuild = "MANAGE_GUILD"
    case addReactions = "ADD_REACTIONS"
    case viewAuditLog = "VIEW_AUDIT_LOG"
    case prioritySpeaker = "PRIORITY_SPEAKER"
    case stream = "STREAM"
    case viewChannel = "VIEW_CHANNEL"
    case sendMessages = "SEND_MESSAGES"
    case sendTTSMessages = "SEND_TTS_MESSAGES"
    case manageMessages = "MANAGE_MESSAGES"
    case embedLinks = "EMBED_LINKS"
    case attachFiles = "ATTACH_FILES"
    case readMessageHistory = "READ_MESSAGE_HISTORY"
    case mentionEveryone = "MENTION_EVERYONE"
    case useExternalEmojis = "USE_EXTERNAL_EMOJIS"
    case connect = "CONNECT"
    case speak = "SPEAK"
    case muteMembers = "MUTE_MEMBERS"
    case deafenMembers = "DEAFEN_MEMBERS"
    case moveMembers = "MOVE_MEMBERS"
    case useVAD = "USE_VAD"
    case changeNickname = "CHANGE_NICKNAME"
    case manageNicknames = "MANAGE_NICKNAMES"
    case manageRoles = "MANAGE_ROLES"
    case manageWebhooks = "MANAGE_WEBHOOKS"
    case manageEmojis = "MANAGE_EMOJIS_AND_STICKERS"
    case useApplicationCommands = "USE_APPLICATION_COMMANDS"
    case requestToSpeak = "REQUEST_TO_SPEAK"
    case manageEvents = "MANAGE_EVENTS"
    case manageThreads = "MANAGE_THREADS"
    case createPublicThreads = "CREATE_PUBLIC_THREADS"
    case createPrivateThreads = "CREATE_PRIVATE_THREADS"
    case useExternalStickers = "USE_EXTERNAL_STICKERS"
    case sendMessagesInThreads = "SEND_MESSAGES_IN_THREADS"
    case useEmbeddedActivities = "USE_EMBEDDED_ACTIVITIES"
    case moderateMembers = "MODERATE_MEMBERS"
    
    var displayName: String {
        switch self {
        case .createInstantInvite: return "Create Invite"
        case .kickMembers: return "Kick Members"
        case .banMembers: return "Ban Members"
        case .administrator: return "Administrator"
        case .manageChannels: return "Manage Channels"
        case .manageGuild: return "Manage Server"
        case .addReactions: return "Add Reactions"
        case .viewAuditLog: return "View Audit Log"
        case .prioritySpeaker: return "Priority Speaker"
        case .stream: return "Video/Stream"
        case .viewChannel: return "View Channel"
        case .sendMessages: return "Send Messages"
        case .sendTTSMessages: return "Send TTS"
        case .manageMessages: return "Manage Messages"
        case .embedLinks: return "Embed Links"
        case .attachFiles: return "Attach Files"
        case .readMessageHistory: return "Read History"
        case .mentionEveryone: return "Mention @everyone"
        case .useExternalEmojis: return "Use External Emojis"
        case .connect: return "Connect"
        case .speak: return "Speak"
        case .muteMembers: return "Mute Members"
        case .deafenMembers: return "Deafen Members"
        case .moveMembers: return "Move Members"
        case .useVAD: return "Use Voice Activity"
        case .changeNickname: return "Change Nickname"
        case .manageNicknames: return "Manage Nicknames"
        case .manageRoles: return "Manage Roles"
        case .manageWebhooks: return "Manage Webhooks"
        case .manageEmojis: return "Manage Emojis"
        case .useApplicationCommands: return "Use Commands"
        case .requestToSpeak: return "Request to Speak"
        case .manageEvents: return "Manage Events"
        case .manageThreads: return "Manage Threads"
        case .createPublicThreads: return "Create Public Threads"
        case .createPrivateThreads: return "Create Private Threads"
        case .useExternalStickers: return "Use External Stickers"
        case .sendMessagesInThreads: return "Send in Threads"
        case .useEmbeddedActivities: return "Use Activities"
        case .moderateMembers: return "Timeout Members"
        }
    }
    
    var bitValue: UInt64 {
        switch self {
        case .createInstantInvite: return 1 << 0
        case .kickMembers: return 1 << 1
        case .banMembers: return 1 << 2
        case .administrator: return 1 << 3
        case .manageChannels: return 1 << 4
        case .manageGuild: return 1 << 5
        case .addReactions: return 1 << 6
        case .viewAuditLog: return 1 << 7
        case .prioritySpeaker: return 1 << 8
        case .stream: return 1 << 9
        case .viewChannel: return 1 << 10
        case .sendMessages: return 1 << 11
        case .sendTTSMessages: return 1 << 12
        case .manageMessages: return 1 << 13
        case .embedLinks: return 1 << 14
        case .attachFiles: return 1 << 15
        case .readMessageHistory: return 1 << 16
        case .mentionEveryone: return 1 << 17
        case .useExternalEmojis: return 1 << 18
        case .connect: return 1 << 20
        case .speak: return 1 << 21
        case .muteMembers: return 1 << 22
        case .deafenMembers: return 1 << 23
        case .moveMembers: return 1 << 24
        case .useVAD: return 1 << 25
        case .changeNickname: return 1 << 26
        case .manageNicknames: return 1 << 27
        case .manageRoles: return 1 << 28
        case .manageWebhooks: return 1 << 29
        case .manageEmojis: return 1 << 30
        case .useApplicationCommands: return 1 << 31
        case .requestToSpeak: return 1 << 32
        case .manageEvents: return 1 << 33
        case .manageThreads: return 1 << 34
        case .createPublicThreads: return 1 << 35
        case .createPrivateThreads: return 1 << 36
        case .useExternalStickers: return 1 << 37
        case .sendMessagesInThreads: return 1 << 38
        case .useEmbeddedActivities: return 1 << 39
        case .moderateMembers: return 1 << 40
        }
    }
}

// MARK: - Trigger Types

enum TriggerType: String, CaseIterable, Identifiable, Codable {
    case userJoinedVoice = "Voice Joined"
    case userLeftVoice = "Voice Left"
    case userMovedVoice = "Voice Moved"
    case messageCreated = "Message Created"
    case memberJoined = "Member Joined"
    case memberLeft = "Member Left"
    case reactionAdded = "Reaction Added"
    case slashCommand = "Slash Command"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let match = TriggerType(rawValue: raw) {
            self = match
        } else if raw == "Message Contains" {
            self = .messageCreated
        } else if raw == "User Joins Voice" {
            self = .userJoinedVoice
        } else if raw == "User Leaves Voice" {
            self = .userLeftVoice
        } else if raw == "User Moves Voice" {
            self = .userMovedVoice
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid TriggerType: \(raw)")
        }
    }

    var symbol: String {
        switch self {
        case .userJoinedVoice: return "person.crop.circle.badge.plus"
        case .userLeftVoice: return "person.crop.circle.badge.xmark"
        case .userMovedVoice: return "arrow.left.arrow.right.circle"
        case .messageCreated: return "text.bubble"
        case .memberJoined: return "person.badge.plus"
        case .memberLeft: return "person.badge.minus"
        case .reactionAdded: return "face.smiling"
        case .slashCommand: return "slash.circle"
        }
    }

    var defaultMessage: String {
        switch self {
        case .userJoinedVoice: return "🔊 <@{userId}> connected to <#{channelId}>"
        case .userLeftVoice: return "🔌 <@{userId}> disconnected from <#{channelId}> (Online for {duration})"
        case .userMovedVoice: return "🔀 <@{userId}> moved from <#{fromChannelId}> to <#{toChannelId}>"
        case .messageCreated: return "nm you?"
        case .memberJoined: return "👋 Welcome to {server}, {username}! You're member #{memberCount}."
        case .memberLeft: return "👋 {username} left the server."
        case .reactionAdded: return "👍 Reaction added!"
        case .slashCommand: return "Command received!"
        }
    }

    var defaultRuleName: String {
        switch self {
        case .userJoinedVoice: return "Join Action"
        case .userLeftVoice: return "Leave Action"
        case .userMovedVoice: return "Move Action"
        case .messageCreated: return "Message Reply"
        case .memberJoined: return "Member Join Welcome"
        case .memberLeft: return "Member Leave Log"
        case .reactionAdded: return "Reaction Handler"
        case .slashCommand: return "Command Handler"
        }
    }
    
    /// Variables provided by this trigger type
    var providedVariables: Set<ContextVariable> {
        switch self {
        case .userJoinedVoice, .userLeftVoice, .userMovedVoice:
            return [.user, .userId, .username, .userMention, .voiceChannel, .voiceChannelId, .guild, .guildId, .guildName, .duration]
        case .messageCreated:
            return [.user, .userId, .username, .userMention, .message, .messageId, .channel, .channelId, .channelName, .guild, .guildId, .guildName]
        case .memberJoined, .memberLeft:
            return [.user, .userId, .username, .userMention, .guild, .guildId, .guildName, .memberCount]
        case .reactionAdded:
            return [.user, .userId, .username, .userMention, .message, .messageId, .channel, .channelId, .reaction, .reactionEmoji, .guild, .guildId]
        case .slashCommand:
            return [.user, .userId, .username, .userMention, .channel, .channelId, .guild, .guildId, .guildName]
        }
    }

    static var allDefaultMessages: Set<String> {
        var messages = Set(allCases.map(\.defaultMessage))
        // Include legacy defaults so trigger changes still auto-populate
        messages.insert("🔊 <@{userId}> connected to <#{channelId}>")
        messages.insert("🔌 <@{userId}> disconnected from <#{channelId}>")
        messages.insert("🔀 <@{userId}> moved from <#{fromChannelId}> to <#{toChannelId}>")
        return messages
    }
}

enum ConditionType: String, CaseIterable, Identifiable, Codable {
    case server = "Server Is"
    case voiceChannel = "Voice Channel Is"
    case usernameContains = "Username Contains"
    case minimumDuration = "Duration In Channel"
    case channelIs = "Channel Is"
    case channelCategory = "Channel Category Is"
    case userHasRole = "User Has Role"
    case userJoinedRecently = "User Joined Recently"
    case messageContains = "Message Contains"
    case messageStartsWith = "Message Starts With"
    case messageRegex = "Message Matches Regex"
    case isDirectMessage = "Message Is DM"
    case isFromBot = "Message Is From Bot"
    case isFromUser = "Message Is From User"
    case channelType = "Channel Type Is"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .server: return "building.2"
        case .voiceChannel: return "waveform"
        case .usernameContains: return "text.magnifyingglass"
        case .minimumDuration: return "timer"
        case .channelIs: return "number"
        case .channelCategory: return "folder"
        case .userHasRole: return "person.crop.circle.badge.checkmark"
        case .userJoinedRecently: return "clock.arrow.circlepath"
        case .messageContains: return "text.quote"
        case .messageStartsWith: return "text.alignleft"
        case .messageRegex: return "asterisk.circle"
        case .isDirectMessage: return "envelope.badge.shield.half.filled"
        case .isFromBot: return "bot"
        case .isFromUser: return "person"
        case .channelType: return "number.square"
        }
    }
    
    /// Variables required to evaluate this condition
    var requiredVariables: Set<ContextVariable> {
        switch self {
        case .server:
            return [.guild, .guildId]
        case .voiceChannel:
            return [.voiceChannel, .voiceChannelId]
        case .usernameContains:
            return [.user, .username]
        case .minimumDuration:
            return [.duration]
        case .channelIs, .channelCategory:
            return [.channel, .channelId]
        case .userHasRole, .userJoinedRecently:
            return [.user, .userId]
        case .messageContains, .messageStartsWith, .messageRegex:
            return [.message]
        case .isDirectMessage, .isFromBot, .isFromUser:
            return [.message, .channel]
        case .channelType:
            return [.channel, .channelId]
        }
    }
}

enum ActionType: String, CaseIterable, Identifiable, Codable {
    case sendMessage = "Send Message"
    case addLogEntry = "Add Log Entry"
    case setStatus = "Set Bot Status"
    case sendDM = "Send DM"
    case deleteMessage = "Delete Message"
    case addReaction = "Add Reaction"
    case addRole = "Add Role"
    case removeRole = "Remove Role"
    case timeoutMember = "Timeout Member"
    case kickMember = "Kick Member"
    case moveMember = "Move Member"
    case createChannel = "Create Channel"
    case webhook = "Send Webhook"
    case delay = "Delay"
    case setVariable = "Set Variable"
    case randomChoice = "Random"
    
    // New Modifier Types
    case replyToTrigger = "Reply To Trigger Message"
    case mentionUser = "Mention User"
    case mentionRole = "Mention Role"
    case disableMention = "Disable User Mentions"
    case sendToChannel = "Send To Channel"
    case sendToDM = "Send To DM"
    
    // AI Types
    case generateAIResponse = "Generate AI Response"
    case summariseMessage = "Summarise Message"
    case classifyMessage = "Classify Message"
    case extractEntities = "Extract Entities"
    case rewriteMessage = "Rewrite Message"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .sendMessage: return "paperplane.fill"
        case .addLogEntry: return "list.bullet.clipboard"
        case .setStatus: return "dot.radiowaves.left.and.right"
        case .sendDM: return "envelope.fill"
        case .deleteMessage: return "trash.fill"
        case .addReaction: return "face.smiling"
        case .addRole: return "person.crop.circle.badge.plus"
        case .removeRole: return "person.crop.circle.badge.minus"
        case .timeoutMember: return "clock.badge.exclamationmark"
        case .kickMember: return "door.left.hand.open"
        case .moveMember: return "arrow.right.circle"
        case .createChannel: return "plus.rectangle"
        case .webhook: return "link"
        case .delay: return "clock.arrow.circlepath"
        case .setVariable: return "character.textbox"
        case .randomChoice: return "shuffle"
        case .replyToTrigger: return "arrowshape.turn.up.left.fill"
        case .mentionUser: return "at"
        case .mentionRole: return "at.badge.plus"
        case .disableMention: return "at.badge.minus"
        case .sendToChannel: return "number.circle.fill"
        case .sendToDM: return "envelope.fill"
        case .generateAIResponse: return "sparkles"
        case .summariseMessage: return "text.alignleft"
        case .classifyMessage: return "tag.fill"
        case .extractEntities: return "list.bullet.clipboard"
        case .rewriteMessage: return "pencil"
        }
    }
    
    /// Variables required by this action type
    var requiredVariables: Set<ContextVariable> {
        switch self {
        case .sendMessage, .sendDM, .setStatus, .addLogEntry, .delay, .setVariable, .randomChoice, .createChannel, .webhook:
            return []
        case .deleteMessage, .addReaction, .replyToTrigger:
            return [.message, .messageId]

        case .addRole, .removeRole, .timeoutMember, .kickMember, .moveMember, .mentionUser, .disableMention, .sendToDM:
            return [.user, .userId]
        case .sendToChannel:
            return [.channel]
        case .generateAIResponse, .mentionRole, .summariseMessage, .classifyMessage, .extractEntities, .rewriteMessage:
            return []
        }
    }
    
    /// Variables provided/output by this action type
    var outputVariables: Set<ContextVariable> {
        switch self {
        case .generateAIResponse:
            return [.aiResponse]
        case .summariseMessage:
            return [.aiSummary]
        case .classifyMessage:
            return [.aiClassification]
        case .extractEntities:
            return [.aiEntities]
        case .rewriteMessage:
            return [.aiRewrite]
        case .sendMessage, .sendDM, .deleteMessage, .addReaction, .addRole, 
             .removeRole, .timeoutMember, .kickMember, .moveMember, .createChannel, .webhook,
             .setStatus, .addLogEntry, .delay, .setVariable, .randomChoice, .replyToTrigger,
             .mentionUser, .mentionRole, .disableMention, .sendToChannel, .sendToDM:
            return []
        }
    }
    
    /// Discord permissions required for this action
    var requiredPermissions: Set<DiscordPermission> {
        switch self {
        case .sendMessage, .sendDM, .addLogEntry, .setStatus, .delay, .setVariable, .randomChoice, .generateAIResponse, .replyToTrigger, .mentionUser, .mentionRole, .disableMention, .sendToChannel, .sendToDM, .summariseMessage, .classifyMessage, .extractEntities, .rewriteMessage:
            return []
        case .deleteMessage:
            return [.manageMessages]
        case .addReaction:
            return [.addReactions]
        case .addRole, .removeRole:
            return [.manageRoles]
        case .timeoutMember:
            return [.moderateMembers]
        case .kickMember:
            return [.kickMembers]
        case .moveMember:
            return [.moveMembers]
        case .createChannel:
            return [.manageChannels]
        case .webhook:
            return [.manageWebhooks]
        }
    }
    
    /// Category for block library organization
    var category: BlockCategory {
        switch self {
        case .replyToTrigger, .disableMention, .sendToChannel, .sendToDM, .mentionUser, .mentionRole:
            return .messaging
        case .sendMessage, .sendDM, .addReaction, .deleteMessage, .createChannel, .webhook, 
             .addLogEntry, .setStatus, .delay, .setVariable, .randomChoice:
            return .actions
        case .generateAIResponse, .summariseMessage, .classifyMessage, .extractEntities, .rewriteMessage:
            return .ai
        case .addRole, .removeRole, .timeoutMember, .kickMember, .moveMember:
            return .moderation
        }
    }
}

/// Block categories for library organization (Task 5)
enum BlockCategory: String, CaseIterable, Identifiable {
    case triggers = "Triggers"
    case filters = "Filters"
    case ai = "AI Blocks"
    case messaging = "Message"
    case actions = "Actions"
    case moderation = "Moderation"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .triggers: return "bolt.fill"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .ai: return "sparkles"
        case .messaging: return "text.bubble.fill"
        case .actions: return "paperplane.fill"
        case .moderation: return "shield.fill"
        }
    }
}

extension ConditionType {
    /// Returns true if this condition is compatible with the given trigger (Task 4)
    func isCompatible(with trigger: TriggerType?) -> Bool {
        guard let trigger = trigger else { return true } // No trigger means everything is potentially visible
        return self.requiredVariables.isSubset(of: trigger.providedVariables)
    }
}

extension ActionType {
    /// Returns true if this action is compatible with the given trigger (Task 4)
    func isCompatible(with trigger: TriggerType?) -> Bool {
        guard let trigger = trigger else { return true }
        return self.requiredVariables.isSubset(of: trigger.providedVariables)
    }
}
struct Condition: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: ConditionType
    var value: String = ""
    var secondaryValue: String = ""
}

struct RuleAction: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: ActionType = .sendMessage
    var serverId: String = ""
    var channelId: String = ""
    var mentionUser: Bool = true
    var replyToTriggerMessage: Bool = false
    var replyWithAI: Bool = false
    var message: String = "🔊 <@{userId}> connected to <#{channelId}>"
    var statusText: String = "Voice notifier active"
    
    // New fields for extended action types
    var dmContent: String = ""              // For sendDM
    var emoji: String = "👍"                // For addReaction
    var roleId: String = ""                 // For addRole/removeRole
    var timeoutDuration: Int = 3600         // For timeoutMember (seconds)
    var kickReason: String = ""             // For kickMember
    var targetVoiceChannelId: String = ""   // For moveMember
    var newChannelName: String = ""         // For createChannel
    var webhookURL: String = ""             // For webhook
    var webhookContent: String = ""         // For webhook
    var delaySeconds: Int = 5               // For delay
    var variableName: String = ""           // For setVariable
    var variableValue: String = ""          // For setVariable
    var randomOptions: [String] = []        // For randomChoice
    var deleteDelaySeconds: Int = 0         // For deleteMessage (delayed delete)
    
    // AI Processing block fields
    var categories: String = ""              // For classifyMessage (comma-separated categories)
    var entityTypes: String = ""             // For extractEntities (comma-separated entity types)
    var rewriteStyle: String = ""            // For rewriteMessage (style description)
    
    // Unified Send Message content source (replaces replyWithAI, etc.)
    var contentSource: ContentSource = .custom
    
    // Message destination mode (per UX spec: replyToTrigger, sameChannel, specificChannel)
    var destinationMode: MessageDestination? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case serverId
        case channelId
        case mentionUser
        case replyToTriggerMessage
        case replyWithAI
        case message
        case statusText
        // New fields
        case dmContent
        case emoji
        case roleId
        case timeoutDuration
        case kickReason
        case targetVoiceChannelId
        case newChannelName
        case webhookURL
        case webhookContent
        case delaySeconds
        case variableName
        case variableValue
        case randomOptions
        case deleteDelaySeconds
        case categories
        case entityTypes
        case rewriteStyle
        case contentSource
        case destinationMode
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try container.decodeIfPresent(ActionType.self, forKey: .type) ?? .sendMessage
        serverId = try container.decodeIfPresent(String.self, forKey: .serverId) ?? ""
        channelId = try container.decodeIfPresent(String.self, forKey: .channelId) ?? ""
        mentionUser = try container.decodeIfPresent(Bool.self, forKey: .mentionUser) ?? true
        replyToTriggerMessage = try container.decodeIfPresent(Bool.self, forKey: .replyToTriggerMessage) ?? false
        replyWithAI = try container.decodeIfPresent(Bool.self, forKey: .replyWithAI) ?? false
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? "🔊 <@{userId}> connected to <#{channelId}>"
        statusText = try container.decodeIfPresent(String.self, forKey: .statusText) ?? "Voice notifier active"
        // New fields with defaults
        dmContent = try container.decodeIfPresent(String.self, forKey: .dmContent) ?? ""
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "👍"
        roleId = try container.decodeIfPresent(String.self, forKey: .roleId) ?? ""
        timeoutDuration = try container.decodeIfPresent(Int.self, forKey: .timeoutDuration) ?? 3600
        kickReason = try container.decodeIfPresent(String.self, forKey: .kickReason) ?? ""
        targetVoiceChannelId = try container.decodeIfPresent(String.self, forKey: .targetVoiceChannelId) ?? ""
        newChannelName = try container.decodeIfPresent(String.self, forKey: .newChannelName) ?? ""
        webhookURL = try container.decodeIfPresent(String.self, forKey: .webhookURL) ?? ""
        webhookContent = try container.decodeIfPresent(String.self, forKey: .webhookContent) ?? ""
        delaySeconds = try container.decodeIfPresent(Int.self, forKey: .delaySeconds) ?? 5
        variableName = try container.decodeIfPresent(String.self, forKey: .variableName) ?? ""
        variableValue = try container.decodeIfPresent(String.self, forKey: .variableValue) ?? ""
        randomOptions = try container.decodeIfPresent([String].self, forKey: .randomOptions) ?? []
        deleteDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .deleteDelaySeconds) ?? 0
        categories = try container.decodeIfPresent(String.self, forKey: .categories) ?? ""
        entityTypes = try container.decodeIfPresent(String.self, forKey: .entityTypes) ?? ""
        rewriteStyle = try container.decodeIfPresent(String.self, forKey: .rewriteStyle) ?? ""
        
        // Decode contentSource with legacy migration
        let decodedContentSource = try container.decodeIfPresent(ContentSource.self, forKey: .contentSource)
        let decodedReplyWithAI = try container.decodeIfPresent(Bool.self, forKey: .replyWithAI) ?? false
        
        // Migration: replyWithAI true -> contentSource = aiResponse
        if decodedContentSource == nil && decodedReplyWithAI && type == .sendMessage {
            contentSource = .aiResponse
        } else {
            contentSource = decodedContentSource ?? .custom
        }
        
        // Decode destinationMode with legacy migration
        let decodedDestinationMode = try container.decodeIfPresent(MessageDestination.self, forKey: .destinationMode)
        let decodedReplyToTrigger = try container.decodeIfPresent(Bool.self, forKey: .replyToTriggerMessage) ?? false
        let hasExplicitChannel = !(try container.decodeIfPresent(String.self, forKey: .channelId) ?? "").isEmpty
        
        // Migration logic per UX spec:
        // - Existing destinationMode -> keep it
        // - Legacy replyToTriggerMessage=true -> replyToTrigger
        // - Explicit serverId/channelId -> specificChannel
        // - Message trigger + no explicit IDs -> sameChannel (handled in UI defaults)
        // - Non-message trigger + no IDs -> specificChannel (conservative default)
        if let existingMode = decodedDestinationMode {
            destinationMode = existingMode
        } else if decodedReplyToTrigger {
            destinationMode = .replyToTrigger
        } else if hasExplicitChannel {
            destinationMode = .specificChannel
        } else {
            // Default: nil means conservative behavior (will be set by UI based on trigger type)
            destinationMode = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let legacyReplyToTrigger = type == .sendMessage ? (destinationMode == .replyToTrigger) : replyToTriggerMessage
        let legacyReplyWithAI = type == .sendMessage ? (contentSource == .aiResponse) : replyWithAI
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(channelId, forKey: .channelId)
        try container.encode(mentionUser, forKey: .mentionUser)
        try container.encode(legacyReplyToTrigger, forKey: .replyToTriggerMessage)
        try container.encode(legacyReplyWithAI, forKey: .replyWithAI)
        try container.encode(message, forKey: .message)
        try container.encode(statusText, forKey: .statusText)
        // New fields
        try container.encode(dmContent, forKey: .dmContent)
        try container.encode(emoji, forKey: .emoji)
        try container.encode(roleId, forKey: .roleId)
        try container.encode(timeoutDuration, forKey: .timeoutDuration)
        try container.encode(kickReason, forKey: .kickReason)
        try container.encode(targetVoiceChannelId, forKey: .targetVoiceChannelId)
        try container.encode(newChannelName, forKey: .newChannelName)
        try container.encode(webhookURL, forKey: .webhookURL)
        try container.encode(webhookContent, forKey: .webhookContent)
        try container.encode(delaySeconds, forKey: .delaySeconds)
        try container.encode(variableName, forKey: .variableName)
        try container.encode(variableValue, forKey: .variableValue)
        try container.encode(randomOptions, forKey: .randomOptions)
        try container.encode(deleteDelaySeconds, forKey: .deleteDelaySeconds)
        try container.encode(categories, forKey: .categories)
        try container.encode(entityTypes, forKey: .entityTypes)
        try container.encode(rewriteStyle, forKey: .rewriteStyle)
        try container.encode(contentSource, forKey: .contentSource)
        try container.encode(destinationMode, forKey: .destinationMode)
    }
}

/// Content source options for Send Message action
enum ContentSource: String, Codable, CaseIterable {
    case custom = "custom"
    case aiResponse = "ai.response"
    case aiSummary = "ai.summary"
    case aiClassification = "ai.classification"
    case aiEntities = "ai.entities"
    case aiRewrite = "ai.rewrite"
    
    var displayName: String {
        switch self {
        case .custom: return "Custom Message"
        case .aiResponse: return "AI Response"
        case .aiSummary: return "AI Summary"
        case .aiClassification: return "AI Classification"
        case .aiEntities: return "AI Entities"
        case .aiRewrite: return "AI Rewrite"
        }
    }
}

/// Destination mode for Send Message action
enum MessageDestination: String, Codable, CaseIterable {
    case replyToTrigger = "replyToTrigger"
    case sameChannel = "sameChannel"
    case specificChannel = "specificChannel"
    
    var displayName: String {
        switch self {
        case .replyToTrigger: return "Reply to Trigger"
        case .sameChannel: return "Same Channel"
        case .specificChannel: return "Specific Channel"
        }
    }
}

extension MessageDestination {
    static func defaultMode(for trigger: TriggerType?) -> MessageDestination {
        switch trigger {
        case .messageCreated, .reactionAdded:
            return .replyToTrigger
        case .slashCommand:
            return .sameChannel
        case .userJoinedVoice, .userLeftVoice, .userMovedVoice, .memberJoined, .memberLeft, .none:
            return .specificChannel
        }
    }

    static func defaultMode(for event: VoiceRuleEvent, context: PipelineContext) -> MessageDestination {
        if context.triggerMessageId != nil || event.triggerMessageId != nil {
            return .replyToTrigger
        }
        if context.triggerChannelId != nil || event.triggerChannelId != nil {
            return .sameChannel
        }
        return .specificChannel
    }
}

typealias Action = RuleAction

struct Rule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = "New Action"
    var trigger: TriggerType?
    var conditions: [Condition] = []
    var modifiers: [RuleAction] = []
    var actions: [RuleAction] = []
    var aiBlocks: [RuleAction] = []
    var isEnabled: Bool = true

    // Legacy trigger properties - preserved for JSON compatibility, migrated to conditions on load
    var triggerServerId: String = ""
    var triggerVoiceChannelId: String = ""
    var triggerMessageContains: String = ""
    var replyToDMs: Bool = false
    var includeStageChannels: Bool = true

    /// UI state indicating trigger selection is in progress (Validation suspended)
    var isEditingTrigger: Bool = false

    /// Memberwise initializer (explicit due to custom Codable conformance)
    init(
        id: UUID = UUID(),
        name: String = "New Action",
        trigger: TriggerType? = nil,
        conditions: [Condition] = [],
        modifiers: [RuleAction] = [],
        actions: [RuleAction] = [],
        isEnabled: Bool = true,
        triggerServerId: String = "",
        triggerVoiceChannelId: String = "",
        triggerMessageContains: String = "",
        replyToDMs: Bool = false,
        includeStageChannels: Bool = true,
        isEditingTrigger: Bool = false
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.conditions = conditions
        self.modifiers = modifiers
        self.actions = actions
        self.isEnabled = isEnabled
        self.triggerServerId = triggerServerId
        self.triggerVoiceChannelId = triggerVoiceChannelId
        self.triggerMessageContains = triggerMessageContains
        self.replyToDMs = replyToDMs
        self.includeStageChannels = includeStageChannels
        self.isEditingTrigger = isEditingTrigger
    }

    var isEmptyRule: Bool {
        trigger == nil && conditions.isEmpty && actions.isEmpty && modifiers.isEmpty
    }

    static func empty() -> Rule {
        Rule(trigger: nil, conditions: [], modifiers: [], actions: [])
    }

    // MARK: - Codable Migration
    
    /// Coding keys for Rule
    enum CodingKeys: String, CodingKey {
        case id, name, trigger, conditions, modifiers, actions, aiBlocks, isEnabled
        case triggerServerId, triggerVoiceChannelId, triggerMessageContains, replyToDMs, includeStageChannels
    }
    
    /// Custom decoder that migrates legacy properties and separates AI blocks from actions
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        trigger = try container.decodeIfPresent(TriggerType.self, forKey: .trigger)
        conditions = try container.decode([Condition].self, forKey: .conditions)
        modifiers = try container.decode([RuleAction].self, forKey: .modifiers)
        actions = try container.decode([RuleAction].self, forKey: .actions)
        aiBlocks = try container.decodeIfPresent([RuleAction].self, forKey: .aiBlocks) ?? []
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        
        // Legacy properties - keep for backwards compatibility but migrate to conditions
        triggerServerId = try container.decodeIfPresent(String.self, forKey: .triggerServerId) ?? ""
        triggerVoiceChannelId = try container.decodeIfPresent(String.self, forKey: .triggerVoiceChannelId) ?? ""
        triggerMessageContains = try container.decodeIfPresent(String.self, forKey: .triggerMessageContains) ?? ""
        replyToDMs = try container.decodeIfPresent(Bool.self, forKey: .replyToDMs) ?? false
        includeStageChannels = try container.decodeIfPresent(Bool.self, forKey: .includeStageChannels) ?? true
        
        // Migration: Convert legacy trigger properties to filter conditions
        // Only add if not already present to avoid duplicates on repeated saves
        var migratedConditions: [Condition] = []
        
        // Migrate triggerServerId -> Condition.server
        if !triggerServerId.isEmpty && !conditions.contains(where: { $0.type == .server }) {
            migratedConditions.append(Condition(type: .server, value: triggerServerId))
        }
        
        // Migrate triggerVoiceChannelId -> Condition.voiceChannel
        if !triggerVoiceChannelId.isEmpty && !conditions.contains(where: { $0.type == .voiceChannel }) {
            migratedConditions.append(Condition(type: .voiceChannel, value: triggerVoiceChannelId))
        }
        
        // Migrate triggerMessageContains -> Condition.messageContains
        if !triggerMessageContains.isEmpty && triggerMessageContains != "up to?" && !conditions.contains(where: { $0.type == .messageContains }) {
            migratedConditions.append(Condition(type: .messageContains, value: triggerMessageContains))
        }
        
        // Append migrated conditions to existing conditions
        if !migratedConditions.isEmpty {
            conditions.append(contentsOf: migratedConditions)
        }
        
        // Migration: Move AI blocks from actions to aiBlocks for backwards compatibility
        let aiBlockTypes: [ActionType] = [.generateAIResponse, .summariseMessage, .classifyMessage, .extractEntities, .rewriteMessage]
        let (aiBlocksFromActions, remainingActions) = actions.reduce(into: ([RuleAction](), [RuleAction]())) { result, action in
            if aiBlockTypes.contains(action.type) {
                result.0.append(action)
            } else {
                result.1.append(action)
            }
        }
        if !aiBlocksFromActions.isEmpty {
            aiBlocks.append(contentsOf: aiBlocksFromActions)
            actions = remainingActions
        }

        actions = actions.map { action in
            guard action.type == .sendMessage, action.destinationMode == nil else { return action }
            var updated = action
            if action.replyToTriggerMessage {
                updated.destinationMode = .replyToTrigger
            } else if !action.channelId.isEmpty || !action.serverId.isEmpty {
                updated.destinationMode = .specificChannel
            } else {
                updated.destinationMode = MessageDestination.defaultMode(for: trigger)
            }
            return updated
        }
    }

    /// Provides the full pipeline of blocks for the rule engine in execution order:
    /// AI Processing → Message Modifiers → Actions
    var processedActions: [RuleAction] {
        var pipeline: [RuleAction] = []
        
        // 1. AI Processing blocks first
        pipeline.append(contentsOf: aiBlocks)
        
        // 2. Message Modifiers
        pipeline.append(contentsOf: modifiers)
        
        // 3. Actions (excluding AI blocks and extracting embedded modifiers)
        for action in actions {
            var actionWithModifiers = action
            
            // Legacy: replyWithAI toggle creates an AI block
            if action.type == .sendMessage && action.replyWithAI && action.contentSource == .custom {
                var aiBlock = RuleAction()
                aiBlock.type = .generateAIResponse
                // Insert AI block at the beginning (before modifiers)
                pipeline.insert(aiBlock, at: aiBlocks.count)
                actionWithModifiers.replyWithAI = false
            }
            
            // Extract reply-to-trigger as a modifier
            if action.type == .sendMessage && action.replyToTriggerMessage && action.destinationMode == nil {
                var replyBlock = RuleAction()
                replyBlock.type = .replyToTrigger
                pipeline.append(replyBlock)
                actionWithModifiers.replyToTriggerMessage = false
            }
            
            // Extract mention disable as a modifier
            if !action.mentionUser { // Default was true in legacy
                var disableMentionBlock = RuleAction()
                disableMentionBlock.type = .disableMention
                pipeline.append(disableMentionBlock)
                actionWithModifiers.mentionUser = true // Reset so we don't repeat
            }
            
            pipeline.append(actionWithModifiers)
        }
        
        return pipeline
    }

    var triggerSummary: String {
        guard let trigger = trigger else { return "No trigger set" }
        switch trigger {
        case .userJoinedVoice: return "When someone joins voice"
        case .userLeftVoice: return "When someone leaves voice"
        case .userMovedVoice: return "When someone moves voice"
        case .messageCreated: return "When a message is received"
        case .memberJoined: return "When a member joins the server"
        case .memberLeft: return "When a member leaves the server"
        case .reactionAdded: return "When a reaction is added"
        case .slashCommand: return "When a slash command is used"
        }
    }
    
    /// Returns any blocks that are incompatible with the current trigger
    var incompatibleBlocks: [UUID] {
        guard let trigger = trigger else { return [] }
        let available = trigger.providedVariables
        var ids: [UUID] = []
        
        for condition in conditions {
            if !condition.type.requiredVariables.isSubset(of: available) {
                ids.append(condition.id)
            }
        }
        for modifier in modifiers {
            if !modifier.type.requiredVariables.isSubset(of: available) {
                ids.append(modifier.id)
            }
        }
        for action in actions {
            if !action.type.requiredVariables.isSubset(of: available) {
                ids.append(action.id)
            }
        }
        return ids
    }

    var validationIssues: [ValidationIssue] {
        guard let trigger = trigger, !isEditingTrigger else {
            return []
        }
        
        var issues: [ValidationIssue] = []
        let availableVariables = trigger.providedVariables
        
        // Check conditions for variable availability
        for condition in conditions {
            let requiredVars = condition.type.requiredVariables
            let missingVars = requiredVars.subtracting(availableVariables)
            if !missingVars.isEmpty {
                issues.append(.init(
                    severity: .warning, // Task 1: Use warning style
                    message: "Requires \(requiredVars.friendlyRequirement)", // Task 1: User-friendly wording
                    blockType: .condition,
                    blockId: condition.id
                ))
            }
        }

        // Check modifiers for variable availability and permissions
        for modifier in modifiers {
            let requiredVars = modifier.type.requiredVariables
            let missingVars = requiredVars.subtracting(availableVariables)
            if !missingVars.isEmpty {
                issues.append(.init(
                    severity: .warning, // Task 1: Use warning style
                    message: "Requires \(requiredVars.friendlyRequirement)", // Task 1: User-friendly wording
                    blockType: .modifier,
                    blockId: modifier.id
                ))
            }

            let requiredPerms = modifier.type.requiredPermissions
            if !requiredPerms.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    message: "Requires permissions: \(requiredPerms.map(\.displayName).joined(separator: ", "))",
                    blockType: .modifier,
                    blockId: modifier.id
                ))
            }
        }
        
        // Check actions for variable availability and permissions
        for action in actions {
            let requiredVars = action.type.requiredVariables
            let missingVars = requiredVars.subtracting(availableVariables)
            if !missingVars.isEmpty {
                issues.append(.init(
                    severity: .warning, // Task 1: Use warning style
                    message: "Requires \(requiredVars.friendlyRequirement)", // Task 1: User-friendly wording
                    blockType: .action,
                    blockId: action.id
                ))
            }
            
            // Task 5: Prevent empty Send Message actions
            if action.type == .sendMessage,
               action.contentSource == .custom,
               action.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "Message content is required for 'Send Message' actions.",
                    blockType: .action,
                    blockId: action.id
                ))
            }

            if action.type == .sendMessage,
               (action.destinationMode ?? MessageDestination.defaultMode(for: trigger)) == .specificChannel,
               action.channelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "Select a channel when destination is set to 'Specific Channel'.",
                    blockType: .action,
                    blockId: action.id
                ))
            }
            
            // Check permissions (warnings, not errors - bot may have permissions)
            let requiredPerms = action.type.requiredPermissions
            if !requiredPerms.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    message: "Requires permissions: \(requiredPerms.map(\.displayName).joined(separator: ", "))",
                    blockType: .action,
                    blockId: action.id
                ))
            }
            }

            // Rule must contain at least one Action
            if actions.isEmpty {
            issues.append(.init(
                severity: .warning,
                message: "This rule has no actions and will not produce any output. Add an Action such as “Send Message”.",
                blockType: .rule,
                blockId: id
            ))
            }

            return issues
    }
    
    /// Checks if rule has any blocking errors
    var hasBlockingErrors: Bool {
        validationIssues.contains { $0.severity == .error }
    }
    
    /// Returns just the errors (not warnings)
    var validationErrors: [ValidationIssue] {
        validationIssues.filter { $0.severity == .error }
    }
    
    /// Returns just the warnings
    var validationWarnings: [ValidationIssue] {
        validationIssues.filter { $0.severity == .warning }
    }
}

/// Represents a validation issue with a rule
struct ValidationIssue: Identifiable, Hashable {
    let id = UUID()
    let severity: ValidationSeverity
    let message: String
    let blockType: BlockType
    let blockId: UUID
    
    enum ValidationSeverity: String, Codable, CaseIterable {
        case warning = "Warning"
        case error = "Error"
        
        var icon: String {
            switch self {
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
        
        var color: String {
            switch self {
            case .warning: return "orange"
            case .error: return "red"
            }
        }
    }
    
    enum BlockType: String, Codable, CaseIterable {
        case rule = "Rule"
        case trigger = "Trigger"
        case condition = "Filter"
        case modifier = "Modifier"
        case action = "Action"
    }
}
