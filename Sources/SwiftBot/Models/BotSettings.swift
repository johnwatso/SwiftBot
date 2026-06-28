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

enum AppPresenceMode: String, Codable, Hashable, CaseIterable, Identifiable {
    case dock
    case dockAndMenuBar
    case menuBar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dock:
            return "Dock Icon"
        case .dockAndMenuBar:
            return "Dock Icon + Menu Bar Icon"
        case .menuBar:
            return "Menu Bar Icon"
        }
    }

    var showsDockIcon: Bool {
        self != .menuBar
    }

    var showsMenuBarIcon: Bool {
        self != .dock
    }
}

/// An extra public hostname carried on SwiftBot's Cloudflare tunnel, routed to
/// a companion app's local service (e.g. SwiftMiner's web dashboard). Persisted
/// so tunnel reconfiguration always re-applies it instead of clobbering it.
struct AdditionalTunnelHostname: Codable, Hashable {
    /// Full hostname, e.g. "swiftminer.example.com".
    var hostname: String = ""
    /// Local origin the tunnel routes to, e.g. "http://localhost:8080".
    var service: String = ""
    /// Human-readable owner shown in logs/UI, e.g. "SwiftMiner".
    var label: String = ""
}

struct AdminWebUISettings: Codable, Hashable {
    // Internal constants (not user-configurable)
    static let defaultBindHost = "127.0.0.1"
    static let defaultPort = 38888
#if DEBUG
    static let defaultSubdomain = "test"
#else
    static let defaultSubdomain = "swiftbot"
#endif

    var enabled: Bool = false
    /// When `true`, the Admin Web UI server refuses to start if HTTPS isn't
    /// configured. Prevents accidental plain-HTTP serving of the admin panel.
    /// Defaults to `false` to preserve behavior of existing installs.
    /// This setting is intentionally not editable via the Web UI itself — only
    /// the macOS desktop GUI can change it.
    var requireHTTPS: Bool = false
    var publicBaseURL: String = ""
    var internetAccessEnabled: Bool = false
    /// When `true`, SwiftBot periodically GETs `{publicURL}/live` and restarts
    /// the Cloudflare tunnel after several consecutive failures. Catches the
    /// "process alive but edge stopped routing" case that the existing
    /// terminate/network-change recovery paths can't see.
    var tunnelHealthCheckEnabled: Bool = true
    var hostname: String = ""
    var subdomain: String = Self.defaultSubdomain
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
    var dismissedDNSConflictHostnames: [String] = []
    /// Extra hostnames companion apps registered on the tunnel (see
    /// `AdditionalTunnelHostname`). Always merged into tunnel ingress on
    /// reconfiguration so SwiftBot's own setup never wipes them.
    var additionalTunnelHostnames: [AdditionalTunnelHostname] = []

    // OAuth Providers (Discord is active; older archived providers are ignored on decode)
    var discordOAuth = OAuthProviderSettings()
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
        case requireHTTPS
        case publicBaseURL
        case internetAccessEnabled
        case tunnelHealthCheckEnabled
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
        case dismissedDNSConflictHostnames
        case additionalTunnelHostnames
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
        requireHTTPS = try container.decodeIfPresent(Bool.self, forKey: .requireHTTPS) ?? false
        publicBaseURL = try container.decodeIfPresent(String.self, forKey: .publicBaseURL) ?? ""

        // Migration: prefer hostname
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        subdomain = try container.decodeIfPresent(String.self, forKey: .subdomain) ?? Self.defaultSubdomain
        selectedZoneID = try container.decodeIfPresent(String.self, forKey: .selectedZoneID) ?? ""
        selectedZoneName = try container.decodeIfPresent(String.self, forKey: .selectedZoneName) ?? ""

        cloudflareAPIToken = try container.decodeIfPresent(String.self, forKey: .cloudflareAPIToken) ?? ""

        // Migration: internetAccessEnabled replaces publicAccessEnabled
        let decodedInternetAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .internetAccessEnabled)
        let decodedPublicAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .publicAccessEnabled)
        internetAccessEnabled = decodedInternetAccessEnabled ?? decodedPublicAccessEnabled ?? false
        tunnelHealthCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .tunnelHealthCheckEnabled) ?? true

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
        localAuthEnabled = try container.decodeIfPresent(Bool.self, forKey: .localAuthEnabled) ?? false
        localAuthUsername = try container.decodeIfPresent(String.self, forKey: .localAuthUsername) ?? "admin"
        localAuthPassword = try container.decodeIfPresent(String.self, forKey: .localAuthPassword) ?? ""

        redirectPath = try container.decodeIfPresent(String.self, forKey: .redirectPath) ?? "/auth/discord/callback"
        allowedUserIDs = try container.decodeIfPresent([String].self, forKey: .allowedUserIDs) ?? []
        restrictAccessToSpecificUsers = try container.decodeIfPresent(Bool.self, forKey: .restrictAccessToSpecificUsers)
            ?? !allowedUserIDs.isEmpty
        dismissedDNSConflictHostnames = try container.decodeIfPresent([String].self, forKey: .dismissedDNSConflictHostnames) ?? []
        additionalTunnelHostnames = try container.decodeIfPresent([AdditionalTunnelHostname].self, forKey: .additionalTunnelHostnames) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(requireHTTPS, forKey: .requireHTTPS)
        try container.encode(publicBaseURL, forKey: .publicBaseURL)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(subdomain, forKey: .subdomain)
        try container.encode(selectedZoneID, forKey: .selectedZoneID)
        try container.encode(selectedZoneName, forKey: .selectedZoneName)
        try container.encode(cloudflareAPIToken, forKey: .cloudflareAPIToken)
        try container.encode(internetAccessEnabled, forKey: .internetAccessEnabled)
        try container.encode(tunnelHealthCheckEnabled, forKey: .tunnelHealthCheckEnabled)
        try container.encode(publicAccessTunnelID, forKey: .publicAccessTunnelID)
        try container.encode(publicAccessTunnelName, forKey: .publicAccessTunnelName)
        try container.encode(publicAccessTunnelAccountID, forKey: .publicAccessTunnelAccountID)
        try container.encode(publicAccessTunnelToken, forKey: .publicAccessTunnelToken)
        try container.encode(importedCertificateFile, forKey: .importedCertificateFile)
        try container.encode(importedPrivateKeyFile, forKey: .importedPrivateKeyFile)
        try container.encode(importedCertificateChainFile, forKey: .importedCertificateChainFile)
        try container.encode(discordOAuth, forKey: .discordOAuth)
        try container.encode(localAuthEnabled, forKey: .localAuthEnabled)
        try container.encode(localAuthUsername, forKey: .localAuthUsername)
        try container.encode(localAuthPassword, forKey: .localAuthPassword)
        try container.encode(redirectPath, forKey: .redirectPath)
        try container.encode(restrictAccessToSpecificUsers, forKey: .restrictAccessToSpecificUsers)
        try container.encode(allowedUserIDs, forKey: .allowedUserIDs)
        try container.encode(dismissedDNSConflictHostnames, forKey: .dismissedDNSConflictHostnames)
        try container.encode(additionalTunnelHostnames, forKey: .additionalTunnelHostnames)
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
    var launchMode: AppLaunchMode = .standaloneBot
    var remoteMode = RemoteModeSettings()
    var prefix: String = "/"
    var commandsEnabled: Bool = true
    var prefixCommandsEnabled: Bool = true
    var slashCommandsEnabled: Bool = true
    var bugTrackingEnabled: Bool = true
    var disabledCommandKeys: Set<String> = []
    var autoStart: Bool = true
    var presenceMode: AppPresenceMode = .dock
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
    /// Hours of continuous healthy standby state required before the
    /// originally-configured primary (i.e. `clusterMode == .leader` that has
    /// been runtime-demoted to standby) will automatically reclaim leadership.
    /// `0` disables auto-reclaim. Manual promote always works regardless.
    ///
    /// Defaults to **off** (0). Auto-reclaim assumes the originally-configured
    /// Primary should always be the canonical one — risky in production where
    /// the cluster swinging back automatically may not be desired. Opt-in via
    /// SwiftMesh preferences.
    var clusterAutoReclaimAfterHours: Int = 0
    /// Persisted "last Handover Test" outcome shown in the SwiftMesh GUI tile.
    /// nil = never run on this node.
    var clusterLastHandoverTestAt: Date?
    /// True if the most recent handover test completed end-to-end (Failover
    /// took over, original Primary reclaimed automatically). False if it
    /// errored partway through.
    var clusterLastHandoverTestOK: Bool = false
    /// Per-node SF Symbol override, keyed by `displayName` (i.e. the user's
    /// node name). Empty map = use the hardware-model-driven auto-detection.
    /// Edited via the SwiftMesh cluster map's contextual menu.
    var clusterNodeIconOverrides: [String: String] = [:]

    // AI reply settings for DMs and guild mentions. SwiftBot uses Apple
    // Intelligence (FoundationModels) exclusively; previous multi-provider
    // fields are preserved in Archive/MultiProviderAI.swift.
    var localAIDMReplyEnabled: Bool = false
    /// Per-Discord-user IANA timezone identifier (e.g. "America/New_York")
    /// used to interpret natural-language times in `/timestamp`.
    /// Missing entries fall back to the bot host's `TimeZone.current`.
    var userTimezones: [String: String] = [:]

    var aiMemoryNotes: [AIMemoryNote] = []
    var localAISystemPrompt: String = "You are a friendly, casual Discord bot. Keep replies short and conversational — 1 to 3 sentences max unless asked for detail. Use contractions naturally. Don't restate what the user said. Don't open every reply the same way. Match the energy of the conversation." // swiftlint:disable:this line_length
    var behavior = BotBehaviorSettings()
    var welcomeFlow = WelcomeFlowSettings()
    var wikiBot = WikiBotSettings()
    var patchy = PatchySettings()
    var swiftMiner = SwiftMinerSettings()
    var cachedBotIdentity = CachedBotIdentity()
    var help = HelpSettings()
    var adminWebUI = AdminWebUISettings()
    var voice = VoiceSettings()

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
        case prefix
        case commandsEnabled
        case prefixCommandsEnabled
        case slashCommandsEnabled
        case bugTrackingEnabled
        case disabledCommandKeys
        case autoStart
        case presenceMode
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
        case clusterAutoReclaimAfterHours
        case clusterLastHandoverTestAt
        case clusterLastHandoverTestOK
        case clusterNodeIconOverrides
        case localAIDMReplyEnabled
        case aiMemoryNotes
        case localAISystemPrompt
        case behavior
        case welcomeFlow
        case wikiBot
        case patchy
        case swiftMiner
        case cachedBotIdentity
        case help
        case adminWebUI
        case voice
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        launchMode = try container.decodeIfPresent(AppLaunchMode.self, forKey: .launchMode) ?? .standaloneBot
        remoteMode = try container.decodeIfPresent(RemoteModeSettings.self, forKey: .remoteMode) ?? RemoteModeSettings()
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? "/"
        commandsEnabled = try container.decodeIfPresent(Bool.self, forKey: .commandsEnabled) ?? true
        prefixCommandsEnabled = try container.decodeIfPresent(Bool.self, forKey: .prefixCommandsEnabled) ?? true
        slashCommandsEnabled = try container.decodeIfPresent(Bool.self, forKey: .slashCommandsEnabled) ?? true
        bugTrackingEnabled = try container.decodeIfPresent(Bool.self, forKey: .bugTrackingEnabled) ?? true
        disabledCommandKeys = try container.decodeIfPresent(Set<String>.self, forKey: .disabledCommandKeys) ?? []
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? true
        presenceMode = try container.decodeIfPresent(AppPresenceMode.self, forKey: .presenceMode) ?? .dock
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
        // Default 0 (off) for fresh installs. Existing users who explicitly
        // saved a non-zero value keep theirs — decodeIfPresent handles that.
        clusterAutoReclaimAfterHours = try container.decodeIfPresent(Int.self, forKey: .clusterAutoReclaimAfterHours) ?? 0
        clusterLastHandoverTestAt = try container.decodeIfPresent(Date.self, forKey: .clusterLastHandoverTestAt)
        clusterLastHandoverTestOK = try container.decodeIfPresent(Bool.self, forKey: .clusterLastHandoverTestOK) ?? false
        clusterNodeIconOverrides = try container.decodeIfPresent([String: String].self, forKey: .clusterNodeIconOverrides) ?? [:]
        localAIDMReplyEnabled = try container.decodeIfPresent(Bool.self, forKey: .localAIDMReplyEnabled) ?? false
        aiMemoryNotes = try container.decodeIfPresent([AIMemoryNote].self, forKey: .aiMemoryNotes) ?? []
        localAISystemPrompt = try container.decodeIfPresent(String.self, forKey: .localAISystemPrompt) ?? "You are a friendly, casual Discord bot. Keep replies short and conversational — 1 to 3 sentences max unless asked for detail. Use contractions naturally. Don't restate what the user said. Don't open every reply the same way. Match the energy of the conversation." // swiftlint:disable:this line_length
        behavior = try container.decodeIfPresent(BotBehaviorSettings.self, forKey: .behavior) ?? BotBehaviorSettings()
        welcomeFlow = try container.decodeIfPresent(WelcomeFlowSettings.self, forKey: .welcomeFlow)
            ?? WelcomeFlowSettings(legacyBehavior: behavior)
        wikiBot = try container.decodeIfPresent(WikiBotSettings.self, forKey: .wikiBot) ?? WikiBotSettings()
        patchy = try container.decodeIfPresent(PatchySettings.self, forKey: .patchy) ?? PatchySettings()
        swiftMiner = try container.decodeIfPresent(SwiftMinerSettings.self, forKey: .swiftMiner) ?? SwiftMinerSettings()
        cachedBotIdentity = try container.decodeIfPresent(CachedBotIdentity.self, forKey: .cachedBotIdentity) ?? CachedBotIdentity()
        help = try container.decodeIfPresent(HelpSettings.self, forKey: .help) ?? HelpSettings()
        adminWebUI = try container.decodeIfPresent(AdminWebUISettings.self, forKey: .adminWebUI) ?? AdminWebUISettings()
        voice = try container.decodeIfPresent(VoiceSettings.self, forKey: .voice) ?? VoiceSettings()
        remoteMode.normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(launchMode, forKey: .launchMode)
        try container.encode(remoteMode, forKey: .remoteMode)
        try container.encode(prefix, forKey: .prefix)
        try container.encode(commandsEnabled, forKey: .commandsEnabled)
        try container.encode(prefixCommandsEnabled, forKey: .prefixCommandsEnabled)
        try container.encode(slashCommandsEnabled, forKey: .slashCommandsEnabled)
        try container.encode(bugTrackingEnabled, forKey: .bugTrackingEnabled)
        try container.encode(disabledCommandKeys, forKey: .disabledCommandKeys)
        try container.encode(autoStart, forKey: .autoStart)
        try container.encode(presenceMode, forKey: .presenceMode)
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
        try container.encode(clusterAutoReclaimAfterHours, forKey: .clusterAutoReclaimAfterHours)
        try container.encodeIfPresent(clusterLastHandoverTestAt, forKey: .clusterLastHandoverTestAt)
        try container.encode(clusterLastHandoverTestOK, forKey: .clusterLastHandoverTestOK)
        try container.encode(clusterNodeIconOverrides, forKey: .clusterNodeIconOverrides)
        try container.encode(localAIDMReplyEnabled, forKey: .localAIDMReplyEnabled)
        try container.encode(aiMemoryNotes, forKey: .aiMemoryNotes)
        try container.encode(localAISystemPrompt, forKey: .localAISystemPrompt)
        try container.encode(behavior, forKey: .behavior)
        try container.encode(welcomeFlow, forKey: .welcomeFlow)
        try container.encode(wikiBot, forKey: .wikiBot)
        try container.encode(patchy, forKey: .patchy)
        try container.encode(swiftMiner, forKey: .swiftMiner)
        try container.encode(cachedBotIdentity, forKey: .cachedBotIdentity)
        try container.encode(help, forKey: .help)
        try container.encode(adminWebUI, forKey: .adminWebUI)
        try container.encode(voice, forKey: .voice)
    }
}

struct CachedBotIdentity: Codable, Hashable {
    var userId: String = ""
    var username: String = ""
    var discriminator: String = ""
    var avatarHash: String = ""

    var hasValue: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !avatarHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct SwiftMinerDMNotificationPreferences: Codable, Hashable, Sendable {
    /// Whether drop claimed DMs are enabled.
    var dropClaimedEnabled: Bool = true
    /// Whether campaign complete DMs are enabled.
    var campaignCompletedEnabled: Bool = true
    /// Whether connection expired (re-auth) DMs are enabled.
    var connectionExpiredEnabled: Bool = true
    /// Whether welcome back DMs are enabled.
    var welcomeBackEnabled: Bool = true
    /// Whether prioritised game needs linking DMs are enabled.
    var linkRequiredEnabled: Bool = true
    /// Whether new campaign detected DMs are enabled.
    var campaignDetectedEnabled: Bool = true
    /// Whether account action required DMs are enabled.
    var accountActionRequiredEnabled: Bool = true
}

struct SwiftMinerSettings: Codable, Hashable {
    var enabled: Bool = false
    var baseURL: String = "http://127.0.0.1:8080"
    var apiKey: String = ""
    var webhookSecret: String = ""
    var webhookHint: String = ""
    var artworkURL: String = ""
    var cachedArtworkFileName: String = ""
    /// User IDs who have already received a SwiftMiner welcome DM.
    /// Used to ensure welcome messages are only sent once per user.
    var welcomeMessageSentUserIds: Set<String> = []
    /// User IDs who have completed the initial SwiftMiner DM onboarding flow.
    var completedInitialDMFlowUserIds: Set<String> = []
    /// Controls which event DM types are sent. Onboarding messages always pass through.
    var notificationPreferences: SwiftMinerDMNotificationPreferences = SwiftMinerDMNotificationPreferences()
    /// Event signatures already delivered, to suppress duplicates across relaunches.
    /// Format: "<discordUserId>|<eventId>"
    var sentEventSignatures: Set<String> = []

    var normalizedBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "http://127.0.0.1:8080" }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// `true` once a SwiftMiner pairing bundle has been applied — without
    /// these credentials the integration can't authenticate or verify webhook
    /// signatures, so enabling it would just produce errors.
    var isPaired: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !webhookSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func apply(pairingBundle: SwiftMinerPairingBundle) {
        enabled = true
        let apiEndpoint = pairingBundle.swiftMinerEndpoint.nonEmpty ?? pairingBundle.endpoint.nonEmpty
        if let apiEndpoint {
            baseURL = apiEndpoint
        }
        apiKey = pairingBundle.apiKey
        webhookSecret = pairingBundle.hmacSecret
        webhookHint = pairingBundle.webhookHint
        artworkURL = pairingBundle.artworkURL
    }
}

struct SwiftMinerPairingBundle: Codable, Hashable {
    let version: Int?
    let endpoint: String
    let swiftMinerEndpoint: String
    let swiftBotEndpoint: String
    let apiKey: String
    let hmacSecret: String
    let webhookHint: String
    let artworkURL: String
    let artworkDataBase64: String

    private enum CodingKeys: String, CodingKey {
        case version
        case endpoint
        case swiftMinerEndpoint
        case swiftBotEndpoint
        case apiKey
        case hmacSecret
        case webhookHint
        case artworkURL
        case imageURL
        case iconURL
        case logoURL
        case artwork
        case image
        case icon
        case logo
        case artworkData
        case imageData
        case iconData
        case logoData
    }

    init(
        version: Int? = nil,
        endpoint: String,
        swiftMinerEndpoint: String = "",
        swiftBotEndpoint: String = "",
        apiKey: String,
        hmacSecret: String,
        webhookHint: String,
        artworkURL: String = "",
        artworkDataBase64: String = ""
    ) {
        self.version = version
        self.endpoint = endpoint
        self.swiftMinerEndpoint = swiftMinerEndpoint
        self.swiftBotEndpoint = swiftBotEndpoint
        self.apiKey = apiKey
        self.hmacSecret = hmacSecret
        self.webhookHint = webhookHint
        self.artworkURL = artworkURL
        self.artworkDataBase64 = artworkDataBase64
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        swiftMinerEndpoint = try container.decodeIfPresent(String.self, forKey: .swiftMinerEndpoint) ?? ""
        swiftBotEndpoint = try container.decodeIfPresent(String.self, forKey: .swiftBotEndpoint) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        hmacSecret = try container.decodeIfPresent(String.self, forKey: .hmacSecret) ?? ""
        webhookHint = try container.decodeIfPresent(String.self, forKey: .webhookHint) ?? ""
        let artworkValue = try Self.firstDecodedString(
            in: container,
            keys: [.artworkURL, .imageURL, .iconURL, .logoURL, .artwork, .image, .icon, .logo]
        )
        if artworkValue.localizedCaseInsensitiveContains(";base64,"),
           let base64 = artworkValue.components(separatedBy: ";base64,").last {
            artworkURL = ""
            artworkDataBase64 = base64
        } else {
            artworkURL = artworkValue
            artworkDataBase64 = try Self.firstDecodedString(
                in: container,
                keys: [.artworkData, .imageData, .iconData, .logoData]
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(swiftMinerEndpoint, forKey: .swiftMinerEndpoint)
        try container.encode(swiftBotEndpoint, forKey: .swiftBotEndpoint)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(hmacSecret, forKey: .hmacSecret)
        try container.encode(webhookHint, forKey: .webhookHint)
        try container.encode(artworkURL, forKey: .artworkURL)
        try container.encode(artworkDataBase64, forKey: .artworkData)
    }

    private static func firstDecodedString(
        in container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> String {
        for key in keys {
            let value = try container.decodeIfPresent(String.self, forKey: key) ?? ""
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }
}

struct BotBehaviorSettings: Codable, Hashable {
    var allowDMs: Bool = false
    var useAIInGuildChannels: Bool = true

    // Legacy member join welcome fields. New UI/runtime uses WelcomeFlowSettings.
    var memberJoinWelcomeEnabled: Bool = false
    var memberJoinWelcomeChannelId: String = ""
    var memberJoinWelcomeTemplate: String = "👋 Welcome {username} to **{server}**!"

    // Voice activity log — global fallback channel when no per-guild channel is set (P0.5)
    var voiceActivityLogEnabled: Bool = false
    var voiceActivityLogChannelId: String = ""
}

enum WelcomeFlowMessageFormat: String, Codable, Hashable, CaseIterable, Identifiable {
    case plainText
    case embed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plainText: return "Plain Text"
        case .embed: return "Embed"
        }
    }
}

/// What to do when a joining member's account is younger than `minAccountAgeDays`.
enum WelcomeFlowAccountAgeAction: String, Codable, Hashable, CaseIterable, Identifiable {
    /// Silently skip all welcome handling (no message, no DM, no roles).
    case skipWelcome
    /// Send a notice to the configured mod-alert channel and skip welcome handling.
    case alertModerators

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .skipWelcome: return "Skip silently"
        case .alertModerators: return "Alert moderators"
        }
    }
}

struct WelcomeFlowSettings: Codable, Hashable {
    var publicWelcomeEnabled: Bool = false
    var publicChannelId: String = ""
    var publicMessageFormat: WelcomeFlowMessageFormat = .plainText
    var publicMessageTemplate: String = "👋 Welcome {username} to **{server}**!"
    /// Optional pool of message templates. When non-empty, one is picked at random per join.
    /// Falls back to `publicMessageTemplate` when empty.
    var publicMessageTemplatePool: [String] = []
    var publicEmbedTitleTemplate: String = "Welcome to {server}"
    var publicEmbedFooterTemplate: String = "Member #{memberCount}"
    var publicEmbedColor: Int = 5_793_266
    /// When true, the embed includes the joining member's avatar as a thumbnail.
    var publicEmbedShowAvatar: Bool = true
    /// When true, the embed includes a "{username} joined" author line with the avatar icon.
    var publicEmbedShowAuthor: Bool = false
    var dmWelcomeEnabled: Bool = false
    var dmMessageTemplate: String = """
    Welcome to {server}, {username}! Glad to have you here.
    """
    /// When true, a public fallback line is posted in the welcome channel when the DM is blocked.
    var dmFallbackToChannelEnabled: Bool = true
    var dmFallbackTemplate: String = "👋 {userMention} — I tried to send you a welcome DM but your DMs are closed."
    var autoRoleEnabled: Bool = false
    var autoRoleId: String = ""
    var nextStepRules: [WelcomeFlowRule] = []
    var burstThreshold: Int = 10
    /// When true, members flagged as bots by Discord are ignored entirely.
    var skipBots: Bool = true
    /// Minimum account age in days. 0 disables the gate.
    var minAccountAgeDays: Int = 0
    var accountAgeAction: WelcomeFlowAccountAgeAction = .skipWelcome
    /// Channel used for "low-age account" alerts when `accountAgeAction == .alertModerators`.
    var modAlertChannelId: String = ""

    // MARK: Goodbye
    var goodbyeEnabled: Bool = false
    var goodbyeChannelId: String = ""
    var goodbyeMessageFormat: WelcomeFlowMessageFormat = .plainText
    var goodbyeMessageTemplate: String = "👋 {username} just left **{server}**."
    var goodbyeEmbedTitleTemplate: String = "Goodbye from {server}"
    var goodbyeEmbedFooterTemplate: String = "{memberCount} members remaining"
    var goodbyeEmbedColor: Int = 14_633_293

    var hasGoodbyeMessage: Bool {
        let hasBody = !goodbyeMessageTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTitle = !goodbyeEmbedTitleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return goodbyeEnabled &&
            !goodbyeChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (goodbyeMessageFormat == .plainText ? hasBody : (hasBody || hasTitle))
    }

    var hasPublicWelcome: Bool {
        let hasMessageBody = !publicMessageTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasEmbedTitle = !publicEmbedTitleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return publicWelcomeEnabled &&
            !publicChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (publicMessageFormat == .plainText ? hasMessageBody : (hasMessageBody || hasEmbedTitle))
    }

    var hasDMWelcome: Bool {
        dmWelcomeEnabled &&
            !dmMessageTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasAutoRole: Bool {
        !activeNextStepRules.isEmpty
    }

    var handlesMemberJoin: Bool {
        hasPublicWelcome || hasDMWelcome || hasAutoRole
    }

    var activeNextStepRules: [WelcomeFlowRule] {
        let configuredRules = nextStepRules.filter(\.isRunnable)
        if !configuredRules.isEmpty {
            return configuredRules
        }
        guard autoRoleEnabled, !autoRoleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return [
            WelcomeFlowRule(
                name: "Auto Role",
                inviteCode: "",
                roleId: autoRoleId,
                isEnabled: true
            )
        ]
    }

    init() {}

    init(legacyBehavior: BotBehaviorSettings) {
        publicWelcomeEnabled = legacyBehavior.memberJoinWelcomeEnabled
        publicChannelId = legacyBehavior.memberJoinWelcomeChannelId
        publicMessageTemplate = legacyBehavior.memberJoinWelcomeTemplate
    }
}

struct WelcomeFlowRule: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "New Rule"
    var inviteCode: String = ""
    var roleId: String = ""
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var isRunnable: Bool {
        isEnabled &&
            !roleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var inviteLabel: String {
        let trimmed = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Any invite" : "discord.gg/\(trimmed)"
    }

    func matches(inviteCode detectedCode: String?) -> Bool {
        let expected = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return true }
        guard let detectedCode else { return false }
        return expected.caseInsensitiveCompare(detectedCode.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}

struct WikiCommand: Codable, Hashable, Identifiable {
    var id = UUID()
    var trigger: String = "/lookup"
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
        trigger: String = "/lookup",
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
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger) ?? "/lookup"
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? "search"
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct WikiFormatting: Codable, Hashable {
    var includeStatBlocks: Bool = true
    var useEmbeds: Bool = true
    var compactMode: Bool = false
    var hiddenEmbedFields: Set<String> = []

    init(
        includeStatBlocks: Bool = true,
        useEmbeds: Bool = true,
        compactMode: Bool = false,
        hiddenEmbedFields: Set<String> = []
    ) {
        self.includeStatBlocks = includeStatBlocks
        self.useEmbeds = useEmbeds
        self.compactMode = compactMode
        self.hiddenEmbedFields = hiddenEmbedFields
    }

    private enum CodingKeys: String, CodingKey {
        case includeStatBlocks
        case useEmbeds
        case compactMode
        case hiddenEmbedFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includeStatBlocks = try container.decodeIfPresent(Bool.self, forKey: .includeStatBlocks) ?? true
        useEmbeds = try container.decodeIfPresent(Bool.self, forKey: .useEmbeds) ?? true
        compactMode = try container.decodeIfPresent(Bool.self, forKey: .compactMode) ?? false
        hiddenEmbedFields = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenEmbedFields) ?? []
    }
}

struct WikiParsingRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var pageType: String = "weapon"
    var templateName: String = "Weapon"
}

struct WikiSource: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String = "Wiki Source"
    var baseURL: String = "https://example.fandom.com"
    var apiPath: String = "/api.php"
    var searchScope: String = ""
    var enabled: Bool = true
    var isPrimary: Bool = false
    var commands: [WikiCommand] = []
    var formatting = WikiFormatting()
    var parsingRules: [WikiParsingRule] = []
    var lastLookupAt: Date?
    var lastStatus: String = "Never used"

    init(
        id: UUID = UUID(),
        name: String = "Wiki Source",
        baseURL: String = "https://example.fandom.com",
        apiPath: String = "/api.php",
        searchScope: String = "",
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
        self.searchScope = searchScope
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
            searchScope: "",
            enabled: true,
            isPrimary: true,
            commands: [
                WikiCommand(trigger: "/finals", endpoint: "search", description: "Search THE FINALS stats", enabled: true)
            ],
            formatting: WikiFormatting(
                includeStatBlocks: true,
                useEmbeds: true,
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
            name: "New Game Wiki",
            baseURL: "",
            apiPath: "/api.php",
            searchScope: "",
            enabled: true,
            isPrimary: false,
            commands: [],
            formatting: WikiFormatting(
                includeStatBlocks: true,
                useEmbeds: true,
                compactMode: false
            ),
            parsingRules: [
                WikiParsingRule(pageType: "weapon", templateName: "Weapon")
            ],
            lastLookupAt: nil,
            lastStatus: "Ready"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case apiPath
        case searchScope
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
        searchScope = try container.decodeIfPresent(String.self, forKey: .searchScope) ?? ""
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
        try container.encode(searchScope, forKey: .searchScope)
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
            updated.searchScope = source.searchScope.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.commands = source.commands.compactMap { command in
                var normalized = command
                normalized.trigger = Self.slashCommandTrigger(command.trigger)
                normalized.endpoint = command.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                normalized.description = command.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = Self.normalizedCommandTrigger(normalized.trigger)
                guard !["wiki", "weapon"].contains(key) else { return nil }
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
                let trigger = Self.defaultCommandTrigger(for: updated)
                updated.commands = [
                    WikiCommand(
                        trigger: trigger,
                        endpoint: "search",
                        description: "Search \(updated.name) stats",
                        enabled: true
                    )
                ]
            }
            if updated.baseURL.lowercased().contains("thefinals.wiki") {
                updated.formatting.includeStatBlocks = true
                updated.formatting.useEmbeds = true
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

    private static func normalizedCommandTrigger(_ trigger: String) -> String {
        var trimmed = trigger
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let first = trimmed.split(separator: " ").first {
            trimmed = String(first)
        }
        while let first = trimmed.first, first == "!" || first == "/" {
            trimmed.removeFirst()
        }
        return trimmed
    }

    private static func slashCommandTrigger(_ trigger: String) -> String {
        let normalized = normalizedCommandTrigger(trigger)
        return normalized.isEmpty ? "" : "/\(normalized)"
    }

    private static func defaultCommandTrigger(for source: WikiSource) -> String {
        let hostSlug: String? = URL(string: source.baseURL)?
            .host?
            .lowercased()
            .split(separator: ".")
            .map(String.init)
            .drop(while: { $0 == "www" })
            .first { !["fandom", "com", "wiki"].contains($0) }

        let base = source.baseURL.lowercased().contains("thefinals.wiki")
            ? "finals"
            : (hostSlug ?? source.name)
        let slug = base
            .replacingOccurrences(of: " Wiki", with: "")
            .replacingOccurrences(of: "THE ", with: "")
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "/\(slug.isEmpty ? "lookup" : String(slug.prefix(32)))"
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
                searchScope: "",
                enabled: legacy.isEnabled ?? true,
                isPrimary: false,
                commands: [],
                formatting: WikiFormatting(
                    includeStatBlocks: false,
                    useEmbeds: true,
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
            let key = normalizedCommandTrigger(command.trigger)
            if key == "finals" || key == "thefinals" {
                updated.enabled = allowFinalsCommand
            } else if key == "wiki" {
                updated.enabled = allowWikiAlias
            } else if key == "weapon" {
                updated.enabled = allowWeaponCommand
            }
            return updated
        }
        source.formatting.includeStatBlocks = includeWeaponStats
        source.formatting.useEmbeds = true
        return source
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
