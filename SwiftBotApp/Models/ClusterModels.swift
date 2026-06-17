import Foundation

// MARK: - Patchy Settings

enum PatchyDefaults {
    static let steamAppID = "2073850"
}

enum PatchySourceKind: String, Codable, CaseIterable, Identifiable {
    case nvidia = "NVIDIA"
    case amd = "AMD"
    case intel = "Intel Arc"
    case apple = "Apple"
    case steam = "Steam"
    case github = "GitHub"
    case swiftMiner = "SwiftMiner"

    var id: String { rawValue }

    var brandAccentColor: PatchyAccentColor {
        switch self {
        case .nvidia:
            return PatchyAccentColor(name: "NVIDIA", hex: "#76B900")
        case .amd:
            return PatchyAccentColor(name: "AMD Radeon", hex: "#ED1C24")
        case .intel:
            return PatchyAccentColor(name: "Intel Arc", hex: "#0071C5")
        case .apple:
            return PatchyAccentColor(name: "Apple Silver", hex: "#A2AAAD")
        case .steam:
            return PatchyAccentColor(name: "Cobalt", hex: "#2563EB")
        case .github:
            return PatchyAccentColor(name: "Violet", hex: "#7C3AED")
        case .swiftMiner:
            return PatchyAccentColor(name: "SwiftMiner", hex: "#00A7D8")
        }
    }

    var supportsCustomAccentColor: Bool {
        switch self {
        case .github, .steam, .apple, .swiftMiner:
            return true
        case .nvidia, .amd, .intel:
            return false
        }
    }
}

enum PatchyAppleProduct: String, Codable, CaseIterable, Identifiable {
    case macOS = "macOS"
    case iOS = "iOS"
    case iPadOS = "iPadOS"
    case tvOS = "tvOS"
    case watchOS = "watchOS"
    case visionOS = "visionOS"
    case xcode = "Xcode"
    case safari = "Safari"

    var id: String { rawValue }

    /// Tokens used to match the product against the Apple releases RSS feed item title.
    var matchTokens: [String] {
        switch self {
        case .macOS: return ["macOS"]
        case .iOS: return ["iOS"]
        case .iPadOS: return ["iPadOS"]
        case .tvOS: return ["tvOS"]
        case .watchOS: return ["watchOS"]
        case .visionOS: return ["visionOS"]
        case .xcode: return ["Xcode"]
        case .safari: return ["Safari"]
        }
    }
}

enum PatchyGitHubBranchMode: String, Codable, CaseIterable, Identifiable {
    case main
    case specific
    case all

    var id: String { rawValue }
}

struct PatchyDeliveryTarget: Codable, Hashable, Identifiable {
    var id = UUID()
    var isEnabled: Bool = true
    var name: String = "Target"
    var serverId: String = ""
    var channelId: String = ""
    var roleIDs: [String] = []
}

struct PatchySourceTarget: Codable, Hashable, Identifiable {
    var id = UUID()
    var isEnabled: Bool = true
    var source: PatchySourceKind = .nvidia
    var steamAppID: String = PatchyDefaults.steamAppID
    var useSteamIcon: Bool = true
    var githubRepo: String = ""
    var githubBranch: String = ""
    var githubWatchAllCommits: Bool = false
    var githubBranchMode: PatchyGitHubBranchMode = .main
    var appleProduct: PatchyAppleProduct = .macOS
    var appleIncludeBetas: Bool = false
    var swiftMinerGameName: String = "The Finals"
    var pollingIntervalMinutes: Int = 60
    var embedColorHex: String = ""
    var summarizeWithAppleIntelligence: Bool = false
    var serverId: String = ""
    var channelId: String = ""
    var roleIDs: [String] = []
    var lastCheckedAt: Date?
    var lastRunAt: Date?
    var lastStatus: String = "Never checked"

    enum CodingKeys: String, CodingKey {
        case id, isEnabled, source, steamAppID, useSteamIcon
        case githubRepo, githubBranch, githubWatchAllCommits, githubBranchMode
        case appleProduct, appleIncludeBetas
        case swiftMinerGameName
        case pollingIntervalMinutes, embedColorHex, summarizeWithAppleIntelligence
        case summarizeFixesWithAppleIntelligence
        case serverId, channelId, roleIDs
        case lastCheckedAt, lastRunAt, lastStatus
    }

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        source: PatchySourceKind = .nvidia,
        steamAppID: String = PatchyDefaults.steamAppID,
        useSteamIcon: Bool = true,
        githubRepo: String = "",
        githubBranch: String = "",
        githubWatchAllCommits: Bool = false,
        githubBranchMode: PatchyGitHubBranchMode = .main,
        appleProduct: PatchyAppleProduct = .macOS,
        appleIncludeBetas: Bool = false,
        swiftMinerGameName: String = "The Finals",
        pollingIntervalMinutes: Int = 60,
        embedColorHex: String = "",
        summarizeWithAppleIntelligence: Bool = false,
        serverId: String = "",
        channelId: String = "",
        roleIDs: [String] = [],
        lastCheckedAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastStatus: String = "Never checked"
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.source = source
        self.steamAppID = steamAppID
        self.useSteamIcon = useSteamIcon
        self.githubRepo = githubRepo
        self.githubBranch = githubBranch
        self.githubWatchAllCommits = githubWatchAllCommits
        self.githubBranchMode = githubBranchMode
        self.appleProduct = appleProduct
        self.appleIncludeBetas = appleIncludeBetas
        self.swiftMinerGameName = swiftMinerGameName
        self.pollingIntervalMinutes = pollingIntervalMinutes
        self.embedColorHex = embedColorHex
        self.summarizeWithAppleIntelligence = summarizeWithAppleIntelligence
        self.serverId = serverId
        self.channelId = channelId
        self.roleIDs = roleIDs
        self.lastCheckedAt = lastCheckedAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        source = try c.decodeIfPresent(PatchySourceKind.self, forKey: .source) ?? .nvidia
        steamAppID = try c.decodeIfPresent(String.self, forKey: .steamAppID) ?? PatchyDefaults.steamAppID
        useSteamIcon = try c.decodeIfPresent(Bool.self, forKey: .useSteamIcon) ?? true
        githubRepo = try c.decodeIfPresent(String.self, forKey: .githubRepo) ?? ""
        githubBranch = try c.decodeIfPresent(String.self, forKey: .githubBranch) ?? ""
        githubWatchAllCommits = try c.decodeIfPresent(Bool.self, forKey: .githubWatchAllCommits) ?? false
        let legacyHasSpecificBranch = !githubBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        githubBranchMode = try c.decodeIfPresent(PatchyGitHubBranchMode.self, forKey: .githubBranchMode) ?? (legacyHasSpecificBranch ? .specific : .main)
        appleProduct = try c.decodeIfPresent(PatchyAppleProduct.self, forKey: .appleProduct) ?? .macOS
        appleIncludeBetas = try c.decodeIfPresent(Bool.self, forKey: .appleIncludeBetas) ?? false
        swiftMinerGameName = try c.decodeIfPresent(String.self, forKey: .swiftMinerGameName) ?? "The Finals"
        pollingIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .pollingIntervalMinutes) ?? PatchyEmbedAccent.defaultPollingIntervalMinutes(for: source)
        embedColorHex = try c.decodeIfPresent(String.self, forKey: .embedColorHex) ?? ""
        summarizeWithAppleIntelligence = try c.decodeIfPresent(Bool.self, forKey: .summarizeWithAppleIntelligence)
            ?? c.decodeIfPresent(Bool.self, forKey: .summarizeFixesWithAppleIntelligence)
            ?? false
        serverId = try c.decodeIfPresent(String.self, forKey: .serverId) ?? ""
        channelId = try c.decodeIfPresent(String.self, forKey: .channelId) ?? ""
        roleIDs = try c.decodeIfPresent([String].self, forKey: .roleIDs) ?? []
        lastCheckedAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus) ?? "Never checked"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(source, forKey: .source)
        try c.encode(steamAppID, forKey: .steamAppID)
        try c.encode(useSteamIcon, forKey: .useSteamIcon)
        try c.encode(githubRepo, forKey: .githubRepo)
        try c.encode(githubBranch, forKey: .githubBranch)
        try c.encode(githubWatchAllCommits, forKey: .githubWatchAllCommits)
        try c.encode(githubBranchMode, forKey: .githubBranchMode)
        try c.encode(appleProduct, forKey: .appleProduct)
        try c.encode(appleIncludeBetas, forKey: .appleIncludeBetas)
        try c.encode(swiftMinerGameName, forKey: .swiftMinerGameName)
        try c.encode(pollingIntervalMinutes, forKey: .pollingIntervalMinutes)
        try c.encode(embedColorHex, forKey: .embedColorHex)
        try c.encode(summarizeWithAppleIntelligence, forKey: .summarizeWithAppleIntelligence)
        try c.encode(serverId, forKey: .serverId)
        try c.encode(channelId, forKey: .channelId)
        try c.encode(roleIDs, forKey: .roleIDs)
        try c.encodeIfPresent(lastCheckedAt, forKey: .lastCheckedAt)
        try c.encodeIfPresent(lastRunAt, forKey: .lastRunAt)
        try c.encode(lastStatus, forKey: .lastStatus)
    }
}

struct PatchyAccentColor: Hashable, Identifiable {
    let name: String
    let hex: String

    var id: String { hex }

    var discordValue: Int {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return Int(raw, radix: 16) ?? 0x7C3AED
    }
}

enum PatchyEmbedAccent {
    static let customChoices: [PatchyAccentColor] = [
        PatchyAccentColor(name: "Emerald", hex: "#00A86B"),
        PatchyAccentColor(name: "Cobalt", hex: "#2563EB"),
        PatchyAccentColor(name: "Violet", hex: "#7C3AED"),
        PatchyAccentColor(name: "Hot Pink", hex: "#FF2D8D"),
        PatchyAccentColor(name: "Orange", hex: "#FF8A00"),
        PatchyAccentColor(name: "Cyan", hex: "#00A7D8"),
        PatchyAccentColor(name: "Ruby", hex: "#E11D48"),
        PatchyAccentColor(name: "Graphite", hex: "#3A3A3C")
    ]

    static func defaultHex(for source: PatchySourceKind) -> String {
        source.brandAccentColor.hex
    }

    static func defaultPollingIntervalMinutes(for source: PatchySourceKind) -> Int {
        switch source {
        case .github: return 5
        case .apple: return 120
        case .swiftMiner: return 60
        default: return 60
        }
    }

    static func resolvedHex(_ hex: String, for source: PatchySourceKind) -> String {
        guard source.supportsCustomAccentColor else {
            return source.brandAccentColor.hex
        }
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedHex(trimmed) ?? defaultHex(for: source)
    }

    static func discordColorInt(hex: String, source: PatchySourceKind) -> Int {
        let resolved = resolvedHex(hex, for: source)
        let raw = resolved.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return Int(raw, radix: 16) ?? source.brandAccentColor.discordValue
    }

    static func isCustomChoice(_ hex: String) -> Bool {
        let normalized = normalizedHex(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        return customChoices.contains { $0.hex == normalized }
    }

    private static func normalizedHex(_ value: String) -> String? {
        let raw = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard raw.count == 6, raw.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#\(raw.uppercased())"
    }
}

struct PatchySettings: Codable, Hashable {
    var monitoringEnabled: Bool = false
    var showDebug: Bool = false
    var sourceTargets: [PatchySourceTarget] = []
    var steamAppNames: [String: String] = [:]
    // appID -> Steam clienticon URL (.ico, up to 256x256). Cached when a Steam
    // target is added, used for the Patchy UI row art and the Discord thumbnail.
    var steamAppIcons: [String: String] = [:]

    // Legacy fields kept for migration compatibility.
    var source: PatchySourceKind = .nvidia
    var steamAppID: String = PatchyDefaults.steamAppID
    var saveAfterFetch: Bool = true
    var targets: [PatchyDeliveryTarget] = []

    mutating func syncMonitoringEnabledWithTargets() {
        monitoringEnabled = sourceTargets.contains(where: \.isEnabled)
    }
}

// MARK: - SwiftMesh Settings

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

/// A lightweight snapshot of all user-configurable settings, used to detect unsaved changes in the UI.
struct AppPreferencesSnapshot: Equatable {
    // General
    var token = ""
    var prefix = "/"
    var autoStart = false
    var presenceMode: AppPresenceMode = .dock

    // SwiftMesh
    var clusterMode: ClusterMode = .standalone
    var clusterNodeName = ""
    var clusterLeaderAddress = ""
    var clusterLeaderPort = 38787
    var clusterListenPort = 38787
    var clusterSharedSecret = ""
    var clusterWorkerOffloadEnabled = false
    var clusterOffloadAIReplies = false
    var clusterOffloadWikiLookups = false

    // Media Library
    var mediaSourcesJSON = ""

    // Admin Web UI
    var adminWebEnabled = false
    var adminWebHost = ""
    var adminWebPort = 38888
    var adminWebBaseURL = ""
    var adminWebHTTPSEnabled = false
    var adminWebCertificateMode: AdminWebUICertificateMode = .automatic
    var adminWebHostname = ""
    var adminWebCloudflareToken = ""
    var adminWebPublicAccessEnabled = false
    var adminWebImportedCertificateFile = ""
    var adminWebImportedPrivateKeyFile = ""
    var adminWebImportedCertificateChainFile = ""
    var adminLocalAuthEnabled = false
    var adminLocalAuthUsername = ""
    var adminLocalAuthPassword = ""
    var adminRestrictSpecificUsers = false
    var adminDiscordClientID = ""
    var adminDiscordClientSecret = ""
    var adminAllowedUserIDs = ""
    var adminRedirectPath = ""

    // AI Bots (Apple Intelligence only)
    var localAIDMReplyEnabled = false
    var useAIInGuildChannels = false
    var allowDMs = false
    var localAISystemPrompt = ""
}

struct MeshSyncedFilesPayload: Codable, Hashable {
    let generatedAt: Date
    let files: [MeshSyncedFile]
}

// MARK: - Cluster Mode

/// Transient runtime state, orthogonal to the configured `ClusterMode`.
/// Surfaces in-flight transitions so the dashboard can show "Promoting…",
/// "Demoting…", "Isolated", or "Recovering" instead of a stale role label
/// during the swap window. Always `.idle` once the node settles back into
/// its steady-state role.
enum ClusterRuntimeState: String, Codable, Sendable {
    case idle
    case promoting
    case demoting
    case isolated
    case recovering

    var displayName: String {
        switch self {
        case .idle:       return "Idle"
        case .promoting:  return "Promoting…"
        case .demoting:   return "Demoting…"
        case .isolated:   return "Isolated"
        case .recovering: return "Recovering"
        }
    }
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
        case .leader:     return "This node acts as the Primary node for the SwiftMesh cluster."
        case .worker:     return "Deprecated. This node performs offloaded compute tasks for the Primary node."
        case .standby:    return "This node will automatically promote to Primary node if the current Leader fails. (Fail Over node)"
        }
    }
}

// MARK: - Action Dispatcher

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

// MARK: - SwiftMesh Protocol Types

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

/// Live "what's happening on the bot right now" snapshot pushed from Leader
/// to Standby alongside the regular sync payload. The Standby renders these
/// fields directly into its dashboard so the Failover doesn't feel dead — bot
/// avatar/name, connected servers, and event counters all come from here when
/// the Standby is in passive mode.
///
/// All fields are optional so older nodes that don't populate them stay
/// compatible.
struct MeshLiveSnapshot: Codable, Sendable, Hashable {
    let botUserId: String?
    let botUsername: String?
    let botDiscriminator: String?
    let botAvatarHash: String?
    /// Guild ID → guild name. The Standby renders this verbatim in the
    /// "Connected Servers" surfaces.
    let connectedServers: [String: String]?
    let gatewayEventCount: Int?
    let voiceStateEventCount: Int?
    let readyEventCount: Int?
    let guildCreateEventCount: Int?
    let lastGatewayEventName: String?
    let lastVoiceStateAt: Date?
    let lastVoiceStateSummary: String?
    /// Raw `BotStatus` value on the Leader (e.g. "running").
    let botStatusRaw: String?
    /// When the bot last started on the Leader; Standby uses this to render a
    /// shared uptime so its dashboard agrees with the Primary.
    let uptimeStartedAt: Date?
    /// True when the Primary is currently running a Handover Test. The
    /// Failover surfaces this so it can show a "test in progress" banner
    /// even when the Primary can't reach it directly (residential NAT).
    let isHandoverTestActive: Bool?
    /// When the test is expected to end / auto-reclaim. Drives the same
    /// countdown UI the Primary shows.
    let handoverTestEndsAt: Date?
    /// When a Handover Test is queued to begin. Lets the Failover render a
    /// heads-up banner ahead of T0 via the regular pull-sync (so the test
    /// announcement doesn't depend on the Primary being able to reach the
    /// Failover inbound — which often fails over residential NAT).
    let scheduledHandoverTestAt: Date?
    /// Node name of the Failover chosen to promote at T0. The matching
    /// Standby fires its local promotion task; non-matching Standbys ignore.
    let scheduledHandoverTargetNodeName: String?
    /// Primary's publicly-reachable URL (typically the Cloudflare-tunneled
    /// admin hostname). Failover uses this as a secondary reachability probe
    /// (`<url>/live`) so it can detect "Primary has truly disappeared" even
    /// when the direct mesh socket is fine but the Primary's Discord side has
    /// failed — or vice versa. `nil` if Primary has no public URL configured.
    let primaryPublicURL: String?
    /// Transient runtime state on the Primary at snapshot time. Mirrored on
    /// the Standby so its dashboard can show "Primary is promoting…" / etc.
    let runtimeState: String?
}

/// Incremental conversation sync payload sent leader → standby.
/// Records are ordered by (timestamp ascending, id ascending) for deterministic replay.
struct MeshSyncPayload: Codable, Sendable {
    let conversations: [MemoryRecord]
    let imageUsage: [String: Int]?
    let commandLog: [CommandLogEntry]?
    let voiceLog: [VoiceEventLogEntry]?
    let activeVoice: [VoiceMemberPresence]?
    let configFilesChanged: Bool
    let configFiles: Data?
    let leaderTerm: Int
    /// ID of the last record in this batch — standby stores as its new cursor.
    let cursorRecordID: String?
    /// True if more records exist beyond this batch; standby should request resync for next page.
    let hasMore: Bool
    /// The cursor the leader assumed this node held when building this batch.
    /// Node compares against its own lastMergedRecordID to detect gaps.
    let fromCursorRecordID: String?
    /// Optional live dashboard snapshot — see `MeshLiveSnapshot`. Omitted by
    /// the resync endpoint and config-only pushes; included on the normal
    /// 60-second leader → standby tick.
    let liveSnapshot: MeshLiveSnapshot?

    init(
        conversations: [MemoryRecord],
        imageUsage: [String: Int]? = nil,
        commandLog: [CommandLogEntry]? = nil,
        voiceLog: [VoiceEventLogEntry]? = nil,
        activeVoice: [VoiceMemberPresence]? = nil,
        configFilesChanged: Bool = false,
        configFiles: Data? = nil,
        leaderTerm: Int,
        cursorRecordID: String? = nil,
        hasMore: Bool = false,
        fromCursorRecordID: String? = nil,
        liveSnapshot: MeshLiveSnapshot? = nil
    ) {
        self.conversations = conversations
        self.imageUsage = imageUsage
        self.commandLog = commandLog
        self.voiceLog = voiceLog
        self.activeVoice = activeVoice
        self.configFilesChanged = configFilesChanged
        self.configFiles = configFiles
        self.leaderTerm = leaderTerm
        self.cursorRecordID = cursorRecordID
        self.hasMore = hasMore
        self.fromCursorRecordID = fromCursorRecordID
        self.liveSnapshot = liveSnapshot
    }
}

/// Standby → leader: request a bounded checkpoint batch starting from a cursor.
struct MeshResyncRequest: Codable, Sendable {
    /// ID of the last successfully merged record (nil = start from beginning).
    let fromRecordID: String?
    let pageSize: Int
}

/// Per-node operational state surfaced to the primary so the GUI can show
/// what each follower is doing in real time (Phase 3 / bidirectional GUI sync).
/// Each node exposes its own summary at `GET /v1/mesh/follower-state`; the
/// primary polls registered workers and stores them in `ClusterSnapshot`.
struct FollowerStateSummary: Codable, Sendable, Hashable {
    let nodeName: String
    let baseURL: String
    let mode: String              // "leader" | "standby" | "worker" | "standalone"
    let leaderTerm: Int
    let gatewayConnected: Bool    // Discord gateway state on the node
    let outputAllowed: Bool       // Whether the node is currently allowed to send Discord messages
    let lastEventAt: Date?        // Most recent gateway event observed on this node
    let recentLogTail: [String]   // Last few log lines (bounded, redacted of tokens by caller)
    let activeVoiceMembers: Int   // Count of voice presences known to this node
    let collectedAt: Date         // When this snapshot was assembled
    /// Most recent Discord gateway heartbeat → ACK round-trip in ms.
    /// `nil` if the gateway hasn't received an ACK yet (or is disconnected).
    /// Used by the primary to compute the cross-instance Gateway Delta.
    let discordGatewayLatencyMs: Int?
}

/// Response body for `GET /v1/mesh/discord-token` — used by a Standby (or
/// freshly-registered Worker) to pull the bot's Discord token from the
/// Primary after a successful HMAC-authed handshake, so a Failover node
/// never needs to be onboarded with its own copy of the token. The endpoint
/// is gated by the same mesh shared-secret HMAC as every other /v1/mesh route.
struct MeshDiscordTokenResponse: Codable, Sendable {
    let token: String
    /// True when the Primary actually has a token configured. False means the
    /// Primary itself isn't onboarded; the caller should not overwrite a
    /// known-good local value.
    let available: Bool
}

/// Coordinated handover test payload. Sent by the current Primary to its
/// Failover to request a temporary takeover, then sent back from the
/// temporary-Primary at the end of the window so the original Primary can
/// reclaim. Carries the duration, the original Primary's node name, and its
/// base URL so the temporary Primary can signal reclaim directly.
struct MeshHandoverTestPayload: Codable, Sendable {
    let originPrimaryNodeName: String
    let originPrimaryBaseURL: String
    let durationSeconds: Int
    let currentLeaderTerm: Int?
}

/// Body returned with a 409 Conflict when a sender's leader term is stale.
/// Carries the receiver's current term so the (now-demoted) sender can detect
/// it is no longer authoritative and step down — preventing split-brain when
/// a partitioned former leader rejoins after a successful failover promotion.
struct StaleTermResponse: Codable, Sendable {
    let error: String
    let currentTerm: Int
    let currentLeaderAddress: String?
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

// MARK: - Cluster State Enums

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
    case standby

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

// MARK: - Cluster Node Status

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
    var isHandoverTestActive: Bool = false
    var handoverTestEndsAt: Date? = nil
    /// Transient transition state — see `ClusterRuntimeState`. Steady state
    /// is `.idle`; non-idle values flag in-flight transitions and are
    /// surfaced in the dashboard sidebar and on `/live`.
    var runtimeState: ClusterRuntimeState = .idle
    /// When set, a Handover Test is queued to begin at this timestamp. The
    /// Primary publishes this so the Failover can show a heads-up banner via
    /// the regular mesh-sync pull (works through NAT, unlike the inbound
    /// "begin" callback). Cleared once the test actually starts or is cancelled.
    var scheduledHandoverTestAt: Date? = nil
    /// Node name of the Failover chosen to promote during the next scheduled
    /// handover test. Each Standby compares this to its own `nodeName` to
    /// know whether IT should fire its local promotion task at T0. This is
    /// what makes the test work without the Primary→Standby callback: the
    /// chosen Standby acts on its local clock instead of waiting for an
    /// inbound HTTP signal.
    var scheduledHandoverTargetNodeName: String? = nil
    /// Phase 3: per-follower state polled by the primary. Keyed by node baseURL.
    /// Empty on followers and on standalone nodes.
    var followerStates: [String: FollowerStateSummary] = [:]
}
