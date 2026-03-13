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
    var localAuthEnabled: Bool = false
    var localAuthUsername: String = "admin"
    var localAuthPassword: String = ""
    
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
        case localAuthEnabled
        case localAuthUsername
        case localAuthPassword
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
        localAuthEnabled = try container.decodeIfPresent(Bool.self, forKey: .localAuthEnabled) ?? false
        localAuthUsername = try container.decodeIfPresent(String.self, forKey: .localAuthUsername) ?? "admin"
        localAuthPassword = try container.decodeIfPresent(String.self, forKey: .localAuthPassword) ?? ""

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
        try container.encode(localAuthEnabled, forKey: .localAuthEnabled)
        try container.encode(localAuthUsername, forKey: .localAuthUsername)
        try container.encode(localAuthPassword, forKey: .localAuthPassword)
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

func generatedRemoteAccessToken() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

struct BotSettings: Codable, Hashable {
    var token: String = ""
    var launchMode: AppLaunchMode = .standaloneBot
    var remoteMode = RemoteModeSettings()
    var remoteAccessToken: String = generatedRemoteAccessToken()
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
        case launchMode
        case remoteMode
        case remoteAccessToken
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
        launchMode = try container.decodeIfPresent(AppLaunchMode.self, forKey: .launchMode) ?? .standaloneBot
        remoteMode = try container.decodeIfPresent(RemoteModeSettings.self, forKey: .remoteMode) ?? RemoteModeSettings()
        remoteAccessToken = try container.decodeIfPresent(String.self, forKey: .remoteAccessToken) ?? generatedRemoteAccessToken()
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
        remoteMode.normalize()
        remoteAccessToken = remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if remoteAccessToken.isEmpty {
            remoteAccessToken = generatedRemoteAccessToken()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(launchMode, forKey: .launchMode)
        try container.encode(remoteMode, forKey: .remoteMode)
        try container.encode(remoteAccessToken, forKey: .remoteAccessToken)
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

