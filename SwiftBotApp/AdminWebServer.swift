import Foundation
import Network
import Darwin
import CryptoKit
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL

// MARK: - Architecture Note
//
// AdminWebServer intentionally exposes only stateless HTTP endpoints.
// No WebSocket endpoints exist for the admin UI.
// Real-time events are handled internally via the Discord gateway WebSocket
// inside DiscordService.swift (outbound connection to Discord only).
//
// Authentication supports both:
// - Cookie-based: swiftbot_admin_session (for browser WebUI)
// - Bearer token: Authorization: Bearer <session-id> (issued via Discord OAuth
//   to the desktop Remote client; not a long-lived shared secret)

struct AdminWebStatusPayload: Codable {
    let botStatus: String
    let botUsername: String
    let botAvatarURL: String?
    let connectedServerCount: Int
    let gatewayEventCount: Int
    let uptimeText: String?
    let webUIEnabled: Bool
    let webUIBaseURL: String
}

struct AdminWebMetricPayload: Codable {
    let title: String
    let value: String
    let subtitle: String
}

struct AdminWebClusterPayload: Codable {
    let connectedNodes: Int
    let leader: String
    let mode: String
}

struct AdminWebClusterNodePayload: Codable {
    let id: String
    let displayName: String
    let role: String
    let status: String
    let hostname: String
    let hardwareModel: String
    let jobsActive: Int
    let latencyMs: Double?
}

struct AdminWebRecentVoicePayload: Codable {
    let description: String
    let timeText: String
}

struct AdminWebRecentCommandPayload: Codable {
    let title: String
    let timeText: String
    let ok: Bool
}

struct AdminWebActiveVoicePayload: Codable {
    let userId: String
    let username: String
    let channelName: String
    let serverName: String
    let joinedText: String
}

struct AdminWebDiscordUser: Codable, Sendable {
    let discordId: String
    let displayName: String
    let username: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case discordId = "discord_id"
        case displayName = "display_name"
        case username
        case avatarURL = "avatar_url"
    }
}

private struct AdminWebDiscordUsersResponse: Codable {
    let users: [AdminWebDiscordUser]
}

struct AdminWebBotInfoPayload: Codable {
    let uptime: String
    let errors: Int
    let state: String
    let cluster: String?
}

struct AdminWebOverviewPayload: Codable {
    let metrics: [AdminWebMetricPayload]
    let cluster: AdminWebClusterPayload
    let clusterNodes: [AdminWebClusterNodePayload]
    let activeVoice: [AdminWebActiveVoicePayload]
    let recentVoice: [AdminWebRecentVoicePayload]
    let recentCommands: [AdminWebRecentCommandPayload]
    let botInfo: AdminWebBotInfoPayload
}

struct AdminWebAnalyticsMetricPayload: Codable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let trend: String
    let tone: String
}

struct AdminWebAnalyticsDayPayload: Codable {
    let date: Date
    let label: String
    let count: Int
}

struct AdminWebAnalyticsHourPayload: Codable {
    let hour: Int
    let label: String
    let count: Int
}

struct AdminWebAnalyticsTopUserPayload: Codable {
    let id: String
    let username: String
    let initials: String
    let totalTime: String
    let activityShare: Int
    let isActive: Bool
}

struct AdminWebAnalyticsFeedEntryPayload: Codable {
    let id: String
    let timestamp: Date
    let title: String
    let detail: String
    let category: String
    let tone: String
}

struct AdminWebAnalyticsHealthPayload: Codable {
    let state: String
    let detail: String
    let websocketLatencyMs: Int?
    let reconnectCount: Int
    let activeTasks: Int
    let eventQueueDepth: Int
    let eventQueueLoad: Double
    let memoryText: String
}

struct AdminWebAnalyticsInsightPayload: Codable {
    let title: String
    let body: String
    let tone: String
}

struct AdminWebSweepPayload: Codable {
    let globalPaused: Bool
    let state: String
    let stateTone: String
    let nextRunDescription: String
    let enabledPolicyCount: Int
    let totalPolicyCount: Int
    let messagesTodayCount: Int
    let suppressedTodayCount: Int
    let summariesThisWeekCount: Int
    let policies: [SweepPolicy]
    let recentReports: [SweepRunReport]
    let suggestions: [SweepSuggestion]
    let isScanningSuggestions: Bool
    let lastSuggestionScanAt: Date?
    let scanProgressDone: Int
    let scanProgressTotal: Int
}

struct AdminWebSweepRunReportPayload: Codable {
    let report: SweepRunReport
}

struct AdminWebAnalyticsPayload: Codable {
    let generatedAt: Date
    let peakActivityLabel: String
    let metrics: [AdminWebAnalyticsMetricPayload]
    let dailyActivity: [AdminWebAnalyticsDayPayload]
    let hourlyActivity: [AdminWebAnalyticsHourPayload]
    let topUsers: [AdminWebAnalyticsTopUserPayload]
    let feed: [AdminWebAnalyticsFeedEntryPayload]
    let health: AdminWebAnalyticsHealthPayload
    let insights: [AdminWebAnalyticsInsightPayload]

    static let empty = AdminWebAnalyticsPayload(
        generatedAt: Date(),
        peakActivityLabel: "Waiting for activity",
        metrics: [],
        dailyActivity: [],
        hourlyActivity: [],
        topUsers: [],
        feed: [],
        health: AdminWebAnalyticsHealthPayload(
            state: "healthy",
            detail: "Runtime analytics are waiting for the app state.",
            websocketLatencyMs: nil,
            reconnectCount: 0,
            activeTasks: 0,
            eventQueueDepth: 0,
            eventQueueLoad: 0,
            memoryText: "-"
        ),
        insights: []
    )
}

struct AdminWebConfigPayload: Codable {
    struct Commands: Codable {
        let enabled: Bool
        let prefixEnabled: Bool
        let slashEnabled: Bool
        let bugTrackingEnabled: Bool
        let prefix: String
    }

    struct AppleIntelligence: Codable {
        let localAIDMReplyEnabled: Bool
    }

    struct WikiBridge: Codable {
        let enabled: Bool
        let enabledSources: Int
        let totalSources: Int
    }

    struct Patchy: Codable {
        let monitoringEnabled: Bool
        let enabledTargets: Int
        let totalTargets: Int
    }

    struct SwiftMesh: Codable {
        let mode: String
        let nodeName: String
        let leaderAddress: String
        let listenPort: Int
        let offloadAIReplies: Bool
        let offloadWikiLookups: Bool
    }

    struct General: Codable {
        let autoStart: Bool
        let webUIEnabled: Bool
        let webUIBaseURL: String
    }

    let commands: Commands
    let appleIntelligence: AppleIntelligence
    let wikiBridge: WikiBridge
    let patchy: Patchy
    let swiftMesh: SwiftMesh
    let general: General
}

struct AdminWebConfigPatch: Codable {
    var commandsEnabled: Bool?
    var prefixCommandsEnabled: Bool?
    var slashCommandsEnabled: Bool?
    var bugTrackingEnabled: Bool?
    var prefix: String?
    var localAIDMReplyEnabled: Bool?
    var wikiBridgeEnabled: Bool?
    var patchyMonitoringEnabled: Bool?
    var clusterMode: String?
    var clusterNodeName: String?
    var clusterLeaderAddress: String?
    var clusterListenPort: Int?
    var clusterOffloadAIReplies: Bool?
    var clusterOffloadWikiLookups: Bool?
    var autoStart: Bool?
}

struct AdminWebCommandCatalogItem: Codable {
    let id: String
    let name: String
    let usage: String
    let description: String
    let category: String
    let surface: String
    let aliases: [String]
    let adminOnly: Bool
    let enabled: Bool
}

struct AdminWebCommandCatalogPayload: Codable {
    let commandsEnabled: Bool
    let prefixCommandsEnabled: Bool
    let slashCommandsEnabled: Bool
    let items: [AdminWebCommandCatalogItem]
}

struct AdminWebCommandTogglePatch: Codable {
    let name: String
    let surface: String
    let enabled: Bool
}

struct AdminWebSimpleOption: Codable {
    let id: String
    let name: String
}

// MARK: - Automations / Moderation payloads

/// Returned by GET /api/automations?category=... — everything the
/// frontend needs to render one tab's worth of UI.
struct AdminWebAutomationsPayload: Codable {
    let category: String                              // "automation" or "moderation"
    let rules: [Automations.Rule]
    let templates: [AdminWebAutomationTemplate]
    let serverContext: AdminWebAutomationServerContext
    let metrics: AdminWebAutomationMetrics
}

struct AdminWebAutomationTemplate: Codable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let tint: String                                  // "blue" | "green" | "purple" | "orange" | "red" | "indigo"
    let rule: Automations.Rule
}

struct AdminWebAutomationServerContext: Codable {
    let guildName: String?
    let guildId: String?
    let textChannels: [AdminWebSimpleOption]
    let voiceChannels: [AdminWebSimpleOption]
    let roles: [AdminWebSimpleOption]
}

struct AdminWebAutomationMetrics: Codable {
    let total: Int
    let enabled: Int
    let triggerKinds: Int
}

struct AdminWebAutomationRulePatch: Codable, Validatable {
    let rule: Automations.Rule

    func validate() throws {
        try rule.validate()
    }
}

struct AdminWebAutomationRuleIDPatch: Codable {
    let id: String
}

struct AdminWebAutomationDraftPatch: Codable {
    let prompt: String
    let category: Automations.Category
}

struct AdminWebAutomationDraftPayload: Codable {
    let rule: Automations.Rule?
    let error: String?
    let unavailableReason: String?
}

struct AdminWebWelcomeFlowPayload: Codable {
    let settings: WelcomeFlowSettings
    let serverContext: AdminWebAutomationServerContext
    let metrics: AdminWebWelcomeFlowMetrics
}

struct AdminWebWelcomeFlowMetrics: Codable {
    let activeRules: Int
    let inviteRules: Int
    let safetyEnabled: Bool
}

struct AdminWebWelcomeFlowPatch: Codable, Validatable {
    let settings: WelcomeFlowSettings

    func validate() throws {
        // WelcomeFlowSettings validation
    }
}

struct AdminWebPatchyPayload: Codable {
    let monitoringEnabled: Bool
    let showDebug: Bool
    let isCycleRunning: Bool
    let lastCycleAt: Date?
    let sourceKinds: [String]
    let targets: [PatchySourceTarget]
    let servers: [AdminWebSimpleOption]
    let textChannelsByServer: [String: [AdminWebSimpleOption]]
    let rolesByServer: [String: [AdminWebSimpleOption]]
    let steamAppNames: [String: String]
    let isFailoverManagedNode: Bool
    let botStatus: String
    let debugLogs: [String]
}

struct AdminWebPatchyStatePatch: Codable {
    let monitoringEnabled: Bool?
    let showDebug: Bool?
}

struct AdminWebPatchyTargetPatch: Codable, Validatable {
    let target: PatchySourceTarget

    func validate() throws {
        // PatchySourceTarget validation
    }
}

struct AdminWebPatchyTargetEnabledPatch: Codable {
    let targetID: UUID
    let enabled: Bool
}

struct AdminWebPatchyTargetIDPatch: Codable {
    let targetID: UUID
}

struct AdminWebWikiBridgePayload: Codable {
    let enabled: Bool
    let sources: [WikiSource]
}

struct AdminWebWikiBridgeStatePatch: Codable {
    let enabled: Bool?
}

struct AdminWebWikiSourcePatch: Codable, Validatable {
    let source: WikiSource

    func validate() throws {
        // WikiSource validation (mostly URL or key patterns)
    }
}

struct AdminWebWikiSourceIDPatch: Codable {
    let sourceID: UUID
}

struct AdminWebAnnouncerPayload: Codable {
    let configs: [AnnouncerVoiceChannelConfig]
    let servers: [AdminWebSimpleOption]
    let textChannelsByServer: [String: [AdminWebSimpleOption]]
    let voiceChannelsByServer: [String: [AdminWebSimpleOption]]
    let guildID: String
    let voiceChannelID: String
    let watchedTextChannelID: String
    let preferredVoiceIdentifier: String
    let textChannelSourceEnabled: Bool
    let autoConnect: Bool
}

struct AdminWebAnnouncerConfigUpsertPatch: Codable {
    let config: AnnouncerVoiceChannelConfig
}

struct AdminWebAnnouncerConfigTogglePatch: Codable {
    let id: String
    let enabled: Bool
}

struct AdminWebAnnouncerConfigDeletePatch: Codable {
    let id: String
}

struct AdminWebAnnouncerSettingsPatch: Codable {
    var guildID: String?
    var voiceChannelID: String?
    var watchedTextChannelID: String?
    var preferredVoiceIdentifier: String?
    var textChannelSourceEnabled: Bool?
    var autoConnect: Bool?
}


struct AdminWebMediaSourcePayload: Codable {
    let id: String
    let nodeName: String
    let sourceName: String
    let itemCount: Int
}

struct AdminWebMediaItemPayload: Codable {
    let id: String
    let nodeName: String
    let sourceName: String
    let gameName: String
    let fileName: String
    let relativePath: String
    let fileExtension: String
    let sizeBytes: Int64
    let modifiedAt: Date
    let thumbnailURL: String
    let streamURL: String
}

struct AdminWebMediaLibraryPayload: Codable {
    let generatedAt: Date
    let sources: [AdminWebMediaSourcePayload]
    let items: [AdminWebMediaItemPayload]
    let games: [String]
    let selectedSourceID: String?
    let selectedDateRange: String
    let selectedGame: String?
    let page: Int
    let pageSize: Int
    let totalItems: Int
    let totalPages: Int
}

struct AdminWebMediaPlaybackPatch: Codable {
    let sessionID: String
    let itemID: String
    let event: String
    let watchedSeconds: Int?
}

struct AdminWebSweepGlobalPausedPatch: Codable {
    let paused: Bool
}

struct AdminWebSweepPolicyEnabledPatch: Codable {
    let policyID: UUID
    let enabled: Bool
}

struct AdminWebSweepPolicyIDPatch: Codable {
    let policyID: UUID
}

struct AdminWebSweepSuggestionIDPatch: Codable {
    let suggestionID: UUID
}

actor AdminWebServer {
    struct RuntimeState: Equatable {
        var isEnabled: Bool
        var isListening: Bool
        var usesTLS: Bool
        var publicBaseURL: String
    }

    private enum OAuthError: LocalizedError {
        case invalidURL
        case tokenExchangeFailed(Int, String)
        case userFetchFailed(Int, String)
        case guildFetchFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid Discord OAuth URL."
            case .tokenExchangeFailed(let status, let body):
                return "Token exchange failed (\(status)): \(body)"
            case .userFetchFailed(let status, let body):
                return "User fetch failed (\(status)): \(body)"
            case .guildFetchFailed(let status, let body):
                return "Guild fetch failed (\(status)): \(body)"
            }
        }
    }

    struct Configuration: Equatable {
        struct HTTPSConfiguration: Equatable {
            var certificatePath: String
            var privateKeyPath: String
            var hostOverride: String?
            var reloadToken: String
        }

        var enabled: Bool
        var bindHost: String
        var port: Int
        var publicBaseURL: String
        var https: HTTPSConfiguration?
        /// When true, the server refuses to start if `https` is nil. Prevents
        /// the admin panel from accidentally serving over plain HTTP.
        var requireHTTPS: Bool = false
        var discordOAuth: OAuthProviderSettings
        var localAuthEnabled: Bool
        var localAuthUsername: String
        var localAuthPassword: String
        var redirectPath: String
        var allowedUserIDs: [String]
        var devFeaturesEnabled: Bool
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
        var peerIP: String? = nil
    }

    private enum Role: String, Codable {
        case admin
        case viewer
    }

    private struct Session: Codable {
        let id: String
        let userID: String
        let username: String
        let globalName: String?
        let discriminator: String?
        let avatar: String?
        let csrfToken: String
        let expiresAt: Date
        // Hex SHA256 of the User-Agent header captured at login. Empty if no UA was
        // sent (e.g. native Remote clients) — in that case binding is not enforced.
        var userAgentHash: String? = nil
        var role: Role = .admin
    }

    private struct PendingState {
        let value: String
        let expiresAt: Date
        let appRedirectURL: String?
        let codeVerifier: String?
    }

    private struct DiscordUser {
        let id: String
        let username: String
        let globalName: String?
        let discriminator: String?
        let avatar: String?
        let mfaEnabled: Bool
    }

    private struct DiscordGuildSummary {
        let id: String
        let owner: Bool?
        let permissions: String?
    }

    private let encoder = JSONEncoder()
    private let apiEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder = JSONDecoder()
    private let apiDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var config = Configuration(
        enabled: false,
        bindHost: "127.0.0.1",
        port: 38888,
        publicBaseURL: "",
        https: nil,
        discordOAuth: OAuthProviderSettings(),
        localAuthEnabled: false,
        localAuthUsername: "admin",
        localAuthPassword: "",
        redirectPath: "/auth/discord/callback",
        allowedUserIDs: [],
        devFeaturesEnabled: false
    )
    private var listener: NWListener?
    private var nioChannel: Channel?
    private var nioGroup: MultiThreadedEventLoopGroup?
    private var activePublicBaseURL = ""
    private var activeTransportUsesTLS = false
    private var statusProvider: (@Sendable () async -> AdminWebStatusPayload)?
    private var overviewProvider: (@Sendable () async -> AdminWebOverviewPayload)?
    private var analyticsProvider: (@Sendable () async -> AdminWebAnalyticsPayload)?
    private var remoteStatusProvider: (@Sendable () async -> RemoteStatusPayload)?
    private var remoteRulesProvider: (@Sendable () async -> RemoteRulesPayload)?
    private var updateRemoteRule: (@Sendable (Rule) async -> Bool)?
    private var remoteEventsProvider: (@Sendable () async -> RemoteEventsPayload)?
    private var remoteSettingsProvider: (@Sendable () async -> AdminWebConfigPayload)?
    private var updateRemoteSettings: (@Sendable (AdminWebConfigPatch) async -> Bool)?
    private var connectedGuildIDsProvider: (@Sendable () async -> Set<String>)?
    private var currentPrefixProvider: (@Sendable () async -> String)?
    private var updatePrefix: (@Sendable (String) async -> Bool)?
    private var configProvider: (@Sendable () async -> AdminWebConfigPayload)?
    private var updateConfig: (@Sendable (AdminWebConfigPatch) async -> Bool)?
    private var commandCatalogProvider: (@Sendable () async -> AdminWebCommandCatalogPayload)?
    private var updateCommandEnabled: (@Sendable (String, String, Bool) async -> Bool)?
    private var automationsProvider: (@Sendable (Automations.Category) async -> AdminWebAutomationsPayload)?
    private var upsertAutomation: (@Sendable (Automations.Rule) async -> Bool)?
    private var deleteAutomation: (@Sendable (String) async -> Bool)?
    private var toggleAutomation: (@Sendable (String) async -> Bool)?
    private var draftAutomation: (@Sendable (String, Automations.Category) async -> AdminWebAutomationDraftPayload)?
    private var welcomeFlowProvider: (@Sendable () async -> AdminWebWelcomeFlowPayload)?
    private var updateWelcomeFlow: (@Sendable (WelcomeFlowSettings) async -> Bool)?
    private var announcerProvider: (@Sendable () async -> AdminWebAnnouncerPayload)?
    private var upsertAnnouncerConfig: (@Sendable (AnnouncerVoiceChannelConfig) async -> Bool)?
    private var deleteAnnouncerConfig: (@Sendable (String) async -> Bool)?
    private var toggleAnnouncerConfig: (@Sendable (String, Bool) async -> Bool)?
    private var updateAnnouncerSettings: (@Sendable (AdminWebAnnouncerSettingsPatch) async -> Bool)?
    private var patchyProvider: (@Sendable () async -> AdminWebPatchyPayload)?
    private var updatePatchyState: (@Sendable (AdminWebPatchyStatePatch) async -> Bool)?
    private var createPatchyTarget: (@Sendable () async -> PatchySourceTarget?)?
    private var updatePatchyTarget: (@Sendable (PatchySourceTarget) async -> Bool)?
    private var setPatchyTargetEnabled: (@Sendable (UUID, Bool) async -> Bool)?
    private var deletePatchyTarget: (@Sendable (UUID) async -> Bool)?
    private var sendPatchyTestTarget: (@Sendable (UUID) async -> Bool)?
    private var pullPatchyTarget: (@Sendable (UUID) async -> Bool)?
    private var runPatchyCheckNow: (@Sendable () async -> Bool)?
    private var wikiBridgeProvider: (@Sendable () async -> AdminWebWikiBridgePayload)?
    private var updateWikiBridgeState: (@Sendable (AdminWebWikiBridgeStatePatch) async -> Bool)?
    private var createWikiSource: (@Sendable () async -> WikiSource?)?
    private var updateWikiSource: (@Sendable (WikiSource) async -> Bool)?
    private var setWikiSourceEnabled: (@Sendable (UUID, Bool) async -> Bool)?
    private var setWikiSourcePrimary: (@Sendable (UUID) async -> Bool)?
    private var testWikiSource: (@Sendable (UUID) async -> Bool)?
    private var deleteWikiSource: (@Sendable (UUID) async -> Bool)?
    private var mediaLibraryProvider: (@Sendable ([String: String]) async -> AdminWebMediaLibraryPayload)?
    private var mediaStreamProvider: (@Sendable (String, String?, String?) async -> BinaryHTTPResponse?)?
    private var mediaThumbnailProvider: (@Sendable (String) async -> BinaryHTTPResponse?)?
    private var mediaFrameProvider: (@Sendable (String, Double) async -> BinaryHTTPResponse?)?
    private var mediaExportStatusProvider: (@Sendable () async -> MediaExportStatus)?
    private var mediaExportJobsProvider: (@Sendable () async -> MediaExportJobsPayload)?
    private var mediaPlaybackRecorder: (@Sendable (AdminWebMediaPlaybackPatch) async -> Bool)?
    private var mediaClipExportStarter: (@Sendable (MediaExportClipRequest) async -> MediaExportJobResponse)?
    private var mediaMultiViewExportStarter: (@Sendable (MediaExportMultiViewRequest) async -> MediaExportJobResponse)?
    private var sweepProvider: (@Sendable () async -> AdminWebSweepPayload)?
    private var setSweepGlobalPaused: (@Sendable (Bool) async -> Bool)?
    private var updateSweepPolicy: (@Sendable (SweepPolicy) async -> Bool)?
    private var deleteSweepPolicy: (@Sendable (UUID) async -> Bool)?
    private var setSweepPolicyEnabled: (@Sendable (UUID, Bool) async -> Bool)?
    private var runSweepPolicy: (@Sendable (UUID) async -> Bool)?
    private var previewSweepPolicy: (@Sendable (UUID) async -> AdminWebSweepRunReportPayload?)?
    private var previewSweepDraft: (@Sendable (SweepPolicy) async -> AdminWebSweepRunReportPayload?)?
    private var scanSweepSuggestions: (@Sendable () async -> Bool)?
    private var applySweepSuggestion: (@Sendable (UUID) async -> Bool)?
    private var dismissSweepSuggestion: (@Sendable (UUID) async -> Bool)?
    private var startBot: (@Sendable () async -> Bool)?
    private var stopBot: (@Sendable () async -> Bool)?
    private var refreshSwiftMesh: (@Sendable () async -> Bool)?
    private var generateSwiftMeshJoinCode: (@Sendable () async -> String?)?
    private var swiftMinerWebhookHandler: (@Sendable ([String: String], Data) async -> (status: String, body: Data))?
    private var discordUsersProvider: (@Sendable () async -> [AdminWebDiscordUser])?
    private var swiftMinerTestDMSender: (@Sendable (SwiftMinerDMRequest, String) async -> Bool)?
    private var swiftMinerPairedProvider: (@Sendable () async -> Bool)?
    private var logger: (@Sendable (String) async -> Void)?
    /// Emits a structured audit event. (source, actor, action, detail, level).
    /// Hooked up by AppModel to feed the unified Activity Log.
    private var auditLogger: (@Sendable (String, String, String, String?, String) -> Void)?
    private var sessions: [String: Session] = [:]
    private var pendingStates: [String: PendingState] = [:]
    private let stateTTL: TimeInterval = 600
    private let sessionTTL: TimeInterval = 24 * 60 * 60
    private let sessionsDefaultsKey = "swiftbot.admin.web.sessions"
    private let sessionsKeychainAccount = "swiftbot.admin.web.sessions"
    private let signingKeyKeychainAccount = "swiftbot.admin.web.signing-key"
    private let maxHTTPRequestSize = 1_024 * 1_024
    private let mediaAccessTokenTTL: TimeInterval = 5 * 60
    private let maxConcurrentConnections = 128
    private let requestReadTimeout: TimeInterval = 15
    private var activeConnectionCount = 0
    private var cachedSigningKey: SymmetricKey?

    private struct RateLimitBucket {
        var failures: [Date] = []
        var lockedUntil: Date?
    }
    /// Failed-login buckets keyed by `<peerIP>|<lowercased-username>` so that an
    /// attacker rotating usernames from a single IP still hits the cap. When the
    /// peer IP is unknown (rare) we fall back to keying on the username alone.
    private var localLoginAttempts: [String: RateLimitBucket] = [:]
    private let loginFailureWindow: TimeInterval = 5 * 60
    private let loginFailureThreshold = 5
    private let loginLockoutDuration: TimeInterval = 15 * 60

    func configure(
        config: Configuration,
        statusProvider: @escaping @Sendable () async -> AdminWebStatusPayload,
        remoteStatusProvider: @escaping @Sendable () async -> RemoteStatusPayload,
        remoteRulesProvider: @escaping @Sendable () async -> RemoteRulesPayload,
        updateRemoteRule: @escaping @Sendable (Rule) async -> Bool,
        remoteEventsProvider: @escaping @Sendable () async -> RemoteEventsPayload,
        remoteSettingsProvider: @escaping @Sendable () async -> AdminWebConfigPayload,
        updateRemoteSettings: @escaping @Sendable (AdminWebConfigPatch) async -> Bool,
        overviewProvider: @escaping @Sendable () async -> AdminWebOverviewPayload,
        analyticsProvider: @escaping @Sendable () async -> AdminWebAnalyticsPayload,
        connectedGuildIDsProvider: @escaping @Sendable () async -> Set<String>,
        currentPrefixProvider: @escaping @Sendable () async -> String,
        updatePrefix: @escaping @Sendable (String) async -> Bool,
        configProvider: @escaping @Sendable () async -> AdminWebConfigPayload,
        updateConfig: @escaping @Sendable (AdminWebConfigPatch) async -> Bool,
        commandCatalogProvider: @escaping @Sendable () async -> AdminWebCommandCatalogPayload,
        updateCommandEnabled: @escaping @Sendable (String, String, Bool) async -> Bool,
        automationsProvider: @escaping @Sendable (Automations.Category) async -> AdminWebAutomationsPayload,
        upsertAutomation: @escaping @Sendable (Automations.Rule) async -> Bool,
        deleteAutomation: @escaping @Sendable (String) async -> Bool,
        toggleAutomation: @escaping @Sendable (String) async -> Bool,
        draftAutomation: @escaping @Sendable (String, Automations.Category) async -> AdminWebAutomationDraftPayload,
        welcomeFlowProvider: @escaping @Sendable () async -> AdminWebWelcomeFlowPayload,
        updateWelcomeFlow: @escaping @Sendable (WelcomeFlowSettings) async -> Bool,
        announcerProvider: @escaping @Sendable () async -> AdminWebAnnouncerPayload,
        upsertAnnouncerConfig: @escaping @Sendable (AnnouncerVoiceChannelConfig) async -> Bool,
        deleteAnnouncerConfig: @escaping @Sendable (String) async -> Bool,
        toggleAnnouncerConfig: @escaping @Sendable (String, Bool) async -> Bool,
        updateAnnouncerSettings: @escaping @Sendable (AdminWebAnnouncerSettingsPatch) async -> Bool,
        patchyProvider: @escaping @Sendable () async -> AdminWebPatchyPayload,
        updatePatchyState: @escaping @Sendable (AdminWebPatchyStatePatch) async -> Bool,
        createPatchyTarget: @escaping @Sendable () async -> PatchySourceTarget?,
        updatePatchyTarget: @escaping @Sendable (PatchySourceTarget) async -> Bool,
        setPatchyTargetEnabled: @escaping @Sendable (UUID, Bool) async -> Bool,
        deletePatchyTarget: @escaping @Sendable (UUID) async -> Bool,
        sendPatchyTestTarget: @escaping @Sendable (UUID) async -> Bool,
        pullPatchyTarget: @escaping @Sendable (UUID) async -> Bool,
        runPatchyCheckNow: @escaping @Sendable () async -> Bool,
        wikiBridgeProvider: @escaping @Sendable () async -> AdminWebWikiBridgePayload,
        updateWikiBridgeState: @escaping @Sendable (AdminWebWikiBridgeStatePatch) async -> Bool,
        createWikiSource: @escaping @Sendable () async -> WikiSource?,
        updateWikiSource: @escaping @Sendable (WikiSource) async -> Bool,
        setWikiSourceEnabled: @escaping @Sendable (UUID, Bool) async -> Bool,
        setWikiSourcePrimary: @escaping @Sendable (UUID) async -> Bool,
        testWikiSource: @escaping @Sendable (UUID) async -> Bool,
        deleteWikiSource: @escaping @Sendable (UUID) async -> Bool,
        mediaLibraryProvider: @escaping @Sendable ([String: String]) async -> AdminWebMediaLibraryPayload,
        mediaStreamProvider: @escaping @Sendable (String, String?, String?) async -> BinaryHTTPResponse?,
        mediaThumbnailProvider: @escaping @Sendable (String) async -> BinaryHTTPResponse?,
        mediaFrameProvider: @escaping @Sendable (String, Double) async -> BinaryHTTPResponse?,
        mediaExportStatusProvider: @escaping @Sendable () async -> MediaExportStatus,
        mediaExportJobsProvider: @escaping @Sendable () async -> MediaExportJobsPayload,
        mediaPlaybackRecorder: @escaping @Sendable (AdminWebMediaPlaybackPatch) async -> Bool,
        mediaClipExportStarter: @escaping @Sendable (MediaExportClipRequest) async -> MediaExportJobResponse,
        mediaMultiViewExportStarter: @escaping @Sendable (MediaExportMultiViewRequest) async -> MediaExportJobResponse,
        sweepProvider: @escaping @Sendable () async -> AdminWebSweepPayload,
        setSweepGlobalPaused: @escaping @Sendable (Bool) async -> Bool,
        updateSweepPolicy: @escaping @Sendable (SweepPolicy) async -> Bool,
        deleteSweepPolicy: @escaping @Sendable (UUID) async -> Bool,
        setSweepPolicyEnabled: @escaping @Sendable (UUID, Bool) async -> Bool,
        runSweepPolicy: @escaping @Sendable (UUID) async -> Bool,
        previewSweepPolicy: @escaping @Sendable (UUID) async -> AdminWebSweepRunReportPayload?,
        previewSweepDraft: @escaping @Sendable (SweepPolicy) async -> AdminWebSweepRunReportPayload?,
        scanSweepSuggestions: @escaping @Sendable () async -> Bool,
        applySweepSuggestion: @escaping @Sendable (UUID) async -> Bool,
        dismissSweepSuggestion: @escaping @Sendable (UUID) async -> Bool,
        startBot: @escaping @Sendable () async -> Bool,
        stopBot: @escaping @Sendable () async -> Bool,
        refreshSwiftMesh: @escaping @Sendable () async -> Bool,
        generateSwiftMeshJoinCode: @escaping @Sendable () async -> String?,
        swiftMinerWebhookHandler: @escaping @Sendable ([String: String], Data) async -> (status: String, body: Data),
        discordUsersProvider: @escaping @Sendable () async -> [AdminWebDiscordUser],
        swiftMinerTestDMSender: @escaping @Sendable (SwiftMinerDMRequest, String) async -> Bool,
        swiftMinerPairedProvider: @escaping @Sendable () async -> Bool,
        log: @escaping @Sendable (String) async -> Void
    ) async -> RuntimeState {
        self.statusProvider = statusProvider
        self.remoteStatusProvider = remoteStatusProvider
        self.remoteRulesProvider = remoteRulesProvider
        self.updateRemoteRule = updateRemoteRule
        self.remoteEventsProvider = remoteEventsProvider
        self.remoteSettingsProvider = remoteSettingsProvider
        self.updateRemoteSettings = updateRemoteSettings
        self.overviewProvider = overviewProvider
        self.analyticsProvider = analyticsProvider
        self.connectedGuildIDsProvider = connectedGuildIDsProvider
        self.currentPrefixProvider = currentPrefixProvider
        self.updatePrefix = updatePrefix
        self.configProvider = configProvider
        self.updateConfig = updateConfig
        self.commandCatalogProvider = commandCatalogProvider
        self.updateCommandEnabled = updateCommandEnabled
        self.automationsProvider = automationsProvider
        self.upsertAutomation = upsertAutomation
        self.deleteAutomation = deleteAutomation
        self.toggleAutomation = toggleAutomation
        self.draftAutomation = draftAutomation
        self.welcomeFlowProvider = welcomeFlowProvider
        self.updateWelcomeFlow = updateWelcomeFlow
        self.announcerProvider = announcerProvider
        self.upsertAnnouncerConfig = upsertAnnouncerConfig
        self.deleteAnnouncerConfig = deleteAnnouncerConfig
        self.toggleAnnouncerConfig = toggleAnnouncerConfig
        self.updateAnnouncerSettings = updateAnnouncerSettings
        self.patchyProvider = patchyProvider
        self.updatePatchyState = updatePatchyState
        self.createPatchyTarget = createPatchyTarget
        self.updatePatchyTarget = updatePatchyTarget
        self.setPatchyTargetEnabled = setPatchyTargetEnabled
        self.deletePatchyTarget = deletePatchyTarget
        self.sendPatchyTestTarget = sendPatchyTestTarget
        self.pullPatchyTarget = pullPatchyTarget
        self.runPatchyCheckNow = runPatchyCheckNow
        self.wikiBridgeProvider = wikiBridgeProvider
        self.updateWikiBridgeState = updateWikiBridgeState
        self.createWikiSource = createWikiSource
        self.updateWikiSource = updateWikiSource
        self.setWikiSourceEnabled = setWikiSourceEnabled
        self.setWikiSourcePrimary = setWikiSourcePrimary
        self.testWikiSource = testWikiSource
        self.deleteWikiSource = deleteWikiSource
        self.mediaLibraryProvider = mediaLibraryProvider
        self.mediaStreamProvider = mediaStreamProvider
        self.mediaThumbnailProvider = mediaThumbnailProvider
        self.mediaFrameProvider = mediaFrameProvider
        self.mediaExportStatusProvider = mediaExportStatusProvider
        self.mediaExportJobsProvider = mediaExportJobsProvider
        self.mediaPlaybackRecorder = mediaPlaybackRecorder
        self.mediaClipExportStarter = mediaClipExportStarter
        self.mediaMultiViewExportStarter = mediaMultiViewExportStarter
        self.sweepProvider = sweepProvider
        self.setSweepGlobalPaused = setSweepGlobalPaused
        self.updateSweepPolicy = updateSweepPolicy
        self.deleteSweepPolicy = deleteSweepPolicy
        self.setSweepPolicyEnabled = setSweepPolicyEnabled
        self.runSweepPolicy = runSweepPolicy
        self.previewSweepPolicy = previewSweepPolicy
        self.previewSweepDraft = previewSweepDraft
        self.scanSweepSuggestions = scanSweepSuggestions
        self.applySweepSuggestion = applySweepSuggestion
        self.dismissSweepSuggestion = dismissSweepSuggestion
        self.startBot = startBot
        self.stopBot = stopBot
        self.refreshSwiftMesh = refreshSwiftMesh
        self.generateSwiftMeshJoinCode = generateSwiftMeshJoinCode
        self.swiftMinerWebhookHandler = swiftMinerWebhookHandler
        self.discordUsersProvider = discordUsersProvider
        self.swiftMinerTestDMSender = swiftMinerTestDMSender
        self.swiftMinerPairedProvider = swiftMinerPairedProvider
        self.logger = log

        loadPersistedSessions()
        let previous = self.config
        self.config = config

        // Refresh the active public base URL so OAuth redirect URIs pick up config changes immediately.
        self.activePublicBaseURL = resolvedPublicBaseURL(usingTLS: activeTransportUsesTLS)

        if !config.enabled {
            await stop()
            return runtimeState()
        }

        let hasActiveListener = listener != nil || nioChannel != nil
        let needsRestart = !hasActiveListener
            || previous.bindHost != config.bindHost
            || previous.port != config.port
            || previous.https != config.https

        if needsRestart {
            await restart()
        } else {
            activePublicBaseURL = resolvedPublicBaseURL(usingTLS: activeTransportUsesTLS)
        }
        return runtimeState()
    }

    func stop() async {
        // Only log if something was actually running. Otherwise reconfigure /
        // settings-save flows that call `stop()` defensively spam the log with
        // "Admin Web UI stopped" lines even when the server was never up.
        let wasRunning = (listener != nil) || (nioChannel != nil)
        listener?.cancel()
        listener = nil
        await stopNIOServer()
        activeTransportUsesTLS = false
        activePublicBaseURL = resolvedPublicBaseURL(usingTLS: false)
        pendingStates.removeAll()
        if wasRunning {
            await logger?("Admin Web UI stopped")
        }
    }

    func restartListener() async -> RuntimeState {
        guard config.enabled else {
            await stop()
            return runtimeState()
        }
        await restart()
        return runtimeState()
    }

    private func restart() async {
        listener?.cancel()
        listener = nil
        await stopNIOServer()

        if let httpsConfiguration = config.https {
            do {
                try await startTLSServer(httpsConfiguration)
                return
            } catch {
                // HTTPS was explicitly configured but the cert/key couldn't be loaded.
                // Falling back to HTTP would silently leak the admin cookie + credentials
                // on what the operator thought was a TLS-protected endpoint, so refuse.
                await logger?("Admin Web UI TLS failed: \(error.localizedDescription). Refusing to fall back to HTTP — fix the certificate paths and restart.")
                return
            }
        }

        // No HTTPS configured. Two gates before we'll serve cleartext:
        // 1. If the operator explicitly opted into HTTPS-only via the desktop GUI
        //    (`requireHTTPS`), refuse to start. This is not exposed in the Web UI,
        //    so the admin panel can't disable its own protection.
        if config.requireHTTPS {
            await logger?("Admin Web UI refusing to start: HTTPS is required (per desktop preferences) but no TLS configuration is present. Configure HTTPS or disable 'Require HTTPS' in the SwiftBot desktop app.")
            return
        }
        // 2. Allow cleartext only on loopback interfaces — never serve admin
        //    credentials/cookies in the clear on a routable address.
        guard isLoopbackBindHost(config.bindHost) else {
            await logger?("Admin Web UI refusing to start: bindHost \(config.bindHost) is not loopback and HTTPS is not configured. Configure HTTPS or change the bind host to 127.0.0.1.")
            return
        }

        await startPlainHTTPServer()
    }

    /// True if `host` is a loopback identifier where cleartext HTTP is acceptable
    /// (only this machine can reach it). Routable / wildcard hosts must use TLS.
    private func isLoopbackBindHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "localhost"
            || normalized == "[::1]"
    }

    private func startPlainHTTPServer() async {
        do {
            let port = NWEndpoint.Port(rawValue: UInt16(config.port)) ?? NWEndpoint.Port(integerLiteral: 38888)
            let listener = try NWListener(using: .tcp, on: port)
            markListenerReady(usingTLS: false)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: DispatchQueue.global(qos: .utility))
                Task {
                    await self.handleConnection(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task {
                    switch state {
                    case .ready:
                        await self.markListenerReady(usingTLS: false)
                        await self.logger?("Admin Web UI listening on http://\(self.config.bindHost):\(self.config.port)")
                    case .failed(let error):
                        await self.logger?("Admin Web UI failed: \(error.localizedDescription)")
                    default:
                        break
                    }
                }
            }
            listener.start(queue: DispatchQueue.global(qos: .utility))
            self.listener = listener
        } catch {
            await logger?("Admin Web UI failed to start: \(error.localizedDescription)")
        }
    }

    private func startTLSServer(_ httpsConfiguration: Configuration.HTTPSConfiguration) async throws {
        let certificateChain = try NIOSSLCertificate
            .fromPEMFile(httpsConfiguration.certificatePath)
            .map { NIOSSLCertificateSource.certificate($0) }
        let privateKey = try NIOSSLPrivateKey(file: httpsConfiguration.privateKeyPath, format: .pem)
        let tlsConfiguration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificateChain,
            privateKey: .privateKey(privateKey)
        )
        let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
                .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
                .childChannelInitializer { channel in
                    do {
                        let peerIP = channel.remoteAddress?.ipAddress
                        let tlsHandler = NIOSSLServerHandler(context: sslContext)
                        let httpHandler = AdminWebNIOHTTPHandler(
                            maxHTTPRequestSize: self.maxHTTPRequestSize,
                            processor: { requestData in
                                return await self.process(requestData, peerIP: peerIP)
                            }
                        )
                        try channel.pipeline.syncOperations.addHandlers(tlsHandler, httpHandler)
                        return channel.eventLoop.makeSucceededFuture(())
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

            let channel = try await bootstrap.bind(host: config.bindHost, port: config.port).get()
            self.nioGroup = group
            self.nioChannel = channel
            markListenerReady(usingTLS: true)
            await logger?("Admin Web UI listening on https://\(config.bindHost):\(config.port)")
        } catch {
            try? await shutdownEventLoopGroup(group)
            throw error
        }
    }

    private func stopNIOServer() async {
        if let channel = nioChannel {
            nioChannel = nil
            try? await channel.close().get()
        }

        if let group = nioGroup {
            nioGroup = nil
            try? await shutdownEventLoopGroup(group)
        }
    }

    private func shutdownEventLoopGroup(_ group: EventLoopGroup) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func markListenerReady(usingTLS: Bool) {
        activeTransportUsesTLS = usingTLS
        activePublicBaseURL = resolvedPublicBaseURL(usingTLS: usingTLS)
    }

    private func runtimeState() -> RuntimeState {
        RuntimeState(
            isEnabled: config.enabled,
            isListening: listener != nil || nioChannel != nil,
            usesTLS: activeTransportUsesTLS && (listener != nil || nioChannel != nil),
            publicBaseURL: activePublicBaseURL.isEmpty
                ? resolvedPublicBaseURL(usingTLS: config.https != nil)
                : activePublicBaseURL
        )
    }

    private func resolvedPublicBaseURL(usingTLS: Bool) -> String {
        let explicit = config.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return explicit
        }

        let scheme = usingTLS ? "https" : "http"
        let host = usingTLS ? (config.https?.hostOverride ?? config.bindHost) : config.bindHost
        let isDefaultPort = (usingTLS && config.port == 443) || (!usingTLS && config.port == 80)
        if isDefaultPort {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(config.port)"
    }

    private func handleConnection(_ connection: NWConnection) async {
        defer {
            connection.cancel()
            Task { self.releaseConnectionSlot() }
        }

        guard await acquireConnectionSlot() else {
            let response = httpResponse(
                status: "503 Service Unavailable",
                body: Data("{\"error\":\"server_busy\"}".utf8),
                contentType: "application/json; charset=utf-8",
                headers: ["Retry-After": "5"]
            )
            try? await send(response, over: connection)
            return
        }

        let peerIP = Self.peerIP(of: connection)
        do {
            let requestData = try await withReadTimeout {
                try await self.receiveHTTPRequest(from: connection)
            }
            let response = await process(requestData, peerIP: peerIP)
            try await send(response, over: connection)
        } catch {
            let response = httpResponse(
                status: "400 Bad Request",
                body: Data("{\"error\":\"bad_request\"}".utf8),
                contentType: "application/json; charset=utf-8"
            )
            try? await send(response, over: connection)
        }
    }

    /// Extract the remote peer's IP string from an accepted NWConnection, if any.
    nonisolated private static func peerIP(of connection: NWConnection) -> String? {
        switch connection.endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                return addr.debugDescription
            case .ipv6(let addr):
                return addr.debugDescription
            case .name(let name, _):
                return name
            @unknown default:
                return nil
            }
        default:
            return nil
        }
    }

    private func acquireConnectionSlot() async -> Bool {
        if activeConnectionCount >= maxConcurrentConnections { return false }
        activeConnectionCount += 1
        return true
    }

    private func releaseConnectionSlot() {
        if activeConnectionCount > 0 { activeConnectionCount -= 1 }
    }

    private func withReadTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { [requestReadTimeout] in
                try await Task.sleep(nanoseconds: UInt64(requestReadTimeout * 1_000_000_000))
                throw NSError(domain: "AdminWebServer", code: 408, userInfo: [NSLocalizedDescriptionKey: "Request read timed out"])
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func receiveHTTPRequest(from connection: NWConnection) async throws -> Data {
        var buffer = Data()

        while true {
            let chunk = try await receiveChunk(from: connection)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            if buffer.count > maxHTTPRequestSize {
                throw NSError(domain: "AdminWebServer", code: 1)
            }

            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[..<headerRange.upperBound]
                let contentLength = parseContentLength(headerData)
                let bodyLength = buffer.count - headerRange.upperBound
                if bodyLength >= contentLength {
                    return buffer
                }
            }
        }

        return buffer
    }

    private func receiveChunk(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func parseContentLength(_ headerData: Data.SubSequence) -> Int {
        guard let text = String(data: Data(headerData), encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:"),
               let value = lower.split(separator: ":").last,
               let count = Int(value.trimmingCharacters(in: .whitespaces)) {
                return count
            }
        }
        return 0
    }

    private func requireRole(_ role: Role, session: Session) -> Bool {
        if session.role == .admin { return true }
        return session.role == role
    }

    private func process(_ requestData: Data, peerIP: String? = nil) async -> Data {
        guard var request = parseRequest(requestData) else {
            return httpResponse(status: "400 Bad Request", body: Data("Invalid request".utf8))
        }
        request.peerIP = peerIP

        pruneExpiredState()
        pruneExpiredSessions()

        if request.method == "GET" && request.path == config.redirectPath {
            return await handleDiscordCallback(request: request)
        }

        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return serveIndex()
        case ("GET", "/favicon.ico"), ("GET", "/favicon.png"):
            return serveAsset(named: "favicon", ext: "png")
        case ("GET", "/assets/AppIcon.png"):
            return serveAsset(named: "AppIcon", ext: "png")
        case ("GET", "/assets/SwiftBird.png"):
            return serveAsset(named: "SwiftBird", ext: "png")
        case ("GET", "/assets/SwiftBird3.png"):
            return serveAsset(named: "SwiftBird3", ext: "png")
        case ("GET", "/assets/lucide.min.js"):
            return serveAsset(named: "lucide.min", ext: "js")
        case ("GET", let path) where path.hasPrefix("/assets/games/"):
            let filename = path.replacingOccurrences(of: "/assets/games/", with: "")
            let parts = filename.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                return httpResponse(status: "404 Not Found", body: Data("Not Found".utf8))
            }
            return serveAsset(named: parts[0], ext: parts[1], subdirectories: ["admin/games", "Resources/admin/games"])
        case ("GET", "/health"):
            let paired = await swiftMinerPairedProvider?() ?? false
            return jsonResponse(["status": "ok", "paired": paired])
        case ("GET", "/v1/users"):
            let users = (await discordUsersProvider?() ?? [])
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            return codableResponse(AdminWebDiscordUsersResponse(users: users))
        case ("POST", let path) where path.hasPrefix("/v1/users/") && path.hasSuffix("/dm/test"):
            let segments = path.split(separator: "/").map(String.init)
            // Expected: ["v1", "users", "<discordUserId>", "dm", "test"]
            guard segments.count == 5 else {
                return jsonResponse(["error": "invalid_path"], status: "400 Bad Request")
            }
            let discordUserId = segments[2]
            let dmRequest: SwiftMinerDMRequest
            if !request.body.isEmpty {
                do {
                    dmRequest = try JSONDecoder().decode(SwiftMinerDMRequest.self, from: request.body)
                } catch {
                    return jsonResponse(["error": "invalid_payload", "detail": error.localizedDescription], status: "400 Bad Request")
                }
            } else {
                dmRequest = SwiftMinerDMRequest(messageType: .linked)
            }
            await logger?("[SwiftMiner] DM request type=\(dmRequest.messageType.rawValue) debug=\(dmRequest.debug) for \(discordUserId)")
            let sent = await swiftMinerTestDMSender?(dmRequest, discordUserId) ?? false
            return jsonResponse(["ok": sent], status: sent ? "200 OK" : "502 Bad Gateway")
        case ("POST", "/webhooks/swiftminer/events"):
            guard let handler = swiftMinerWebhookHandler else {
                return jsonResponse(["error": "swiftminer_unavailable"], status: "503 Service Unavailable")
            }
            let result = await handler(request.headers, request.body)
            return httpResponse(status: result.status, body: result.body, contentType: "application/json; charset=utf-8")
        case ("GET", "/api/remote/status"):
            guard isRemoteRequestAuthorized(request) else {
                return unauthorizedResponse()
            }
            if let payload = await remoteStatusProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "status_unavailable"], status: "503 Service Unavailable")
        case ("GET", "/api/remote/rules"):
            guard isRemoteRequestAuthorized(request) else {
                return unauthorizedResponse()
            }
            if let payload = await remoteRulesProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "rules_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/remote/rules/update"):
            guard isRemoteRequestAuthorized(request) else {
                return unauthorizedResponse()
            }
            guard let patch = try? decoder.decode(RemoteRuleUpsertRequest.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateRemoteRule?(patch.rule) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            await logger?("Remote API updated rule \(patch.rule.name)")
            return jsonResponse(["ok": true])
        case ("GET", "/api/remote/events"):
            guard isRemoteRequestAuthorized(request) else {
                return unauthorizedResponse()
            }
            if let payload = await remoteEventsProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "events_unavailable"], status: "503 Service Unavailable")
        case ("GET", "/api/remote/settings"):
            guard isRemoteRequestAuthorized(request) else {
                return unauthorizedResponse()
            }
            if let payload = await remoteSettingsProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "settings_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/remote/settings/update"):
            guard isRemoteRequestAuthorized(request) else {
                return unauthorizedResponse()
            }
            guard let patch = try? decoder.decode(AdminWebConfigPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateRemoteSettings?(patch) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            await logger?("Remote API updated settings")
            return jsonResponse(["ok": true])
        case ("GET", "/api/status"):
            let payload = await statusProvider?() ?? AdminWebStatusPayload(
                botStatus: "stopped",
                botUsername: "SwiftBot",
                botAvatarURL: nil,
                connectedServerCount: 0,
                gatewayEventCount: 0,
                uptimeText: nil,
                webUIEnabled: false,
                webUIBaseURL: ""
            )
            return codableResponse(payload)
        case ("GET", "/api/overview"):
            let payload = await overviewProvider?() ?? AdminWebOverviewPayload(
                metrics: [],
                cluster: AdminWebClusterPayload(connectedNodes: 0, leader: "Unavailable", mode: "standalone"),
                clusterNodes: [],
                activeVoice: [],
                recentVoice: [],
                recentCommands: [],
                botInfo: AdminWebBotInfoPayload(uptime: "--", errors: 0, state: "Stopped", cluster: nil)
            )
            return codableResponse(payload)
        case ("GET", "/api/analytics"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            let payload = await analyticsProvider?() ?? AdminWebAnalyticsPayload.empty
            return codableResponse(payload)
        case ("GET", "/api/me"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            return jsonResponse([
                "id": session.userID,
                "username": session.username,
                "globalName": session.globalName ?? "",
                "discriminator": session.discriminator ?? "",
                "avatar": session.avatar ?? "",
                "csrfToken": session.csrfToken
            ])
        case ("GET", "/api/media/access-token"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            let minted = mintMediaAccessToken(sessionID: session.id)
            return jsonResponse([
                "token": minted.token,
                "expiresAt": ISO8601DateFormatter().string(from: minted.expiresAt)
            ])
        case ("GET", "/api/settings"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            let prefix = await currentPrefixProvider?() ?? "/"
            return jsonResponse(["prefix": prefix])
        case ("GET", "/api/config"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await configProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "config_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/settings/prefix"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard
                let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                let prefix = body["prefix"] as? String,
                await updatePrefix?(prefix) == true
            else {
                return jsonResponse(["error": "invalid_prefix"], status: "400 Bad Request")
            }
            await logger?("Admin Web UI updated command prefix")
            audit(source: "Web Config", actor: actorLabel(session), action: "Updated command prefix", detail: prefix)
            return jsonResponse(["ok": true])
        case ("POST", "/api/config"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebConfigPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateConfig?(patch) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            await logger?("Admin Web UI updated configuration")
            audit(source: "Web Config", actor: actorLabel(session), action: "Updated configuration")
            return jsonResponse(["ok": true])
        case ("GET", "/api/commands"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await commandCatalogProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "commands_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/commands/toggle"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebCommandTogglePatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateCommandEnabled?(patch.name, patch.surface, patch.enabled) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            await logger?("Admin Web UI toggled command \(patch.surface):\(patch.name) -> \(patch.enabled)")
            audit(source: "Web Config", actor: actorLabel(session), action: patch.enabled ? "Enabled command" : "Disabled command", detail: "\(patch.surface):\(patch.name)")
            return jsonResponse(["ok": true])
        // /api/actions/* (legacy block-builder rule endpoints) retired; the
        // current automations + moderation surfaces live under /api/automations.
        case ("GET", "/api/automations"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            let category = categoryParam(from: request)
            if let provider = automationsProvider {
                let payload = await provider(category)
                return codableResponse(payload)
            }
            return jsonResponse(["error": "automations_unavailable"], status: "503 Service Unavailable")

        case ("POST", "/api/automations/upsert"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            do {
                let patch = try decoder.decode(AdminWebAutomationRulePatch.self, from: request.body)
                try patch.validate()
                guard await upsertAutomation?(patch.rule) == true else {
                    return jsonResponse(["error": "upsert_failed"], status: "400 Bad Request")
                }
                return jsonResponse(["ok": true])
            } catch {
                return jsonResponse(["error": "validation_failed", "message": error.localizedDescription], status: "400 Bad Request")
            }

        case ("POST", "/api/automations/validate"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            do {
                let patch = try decoder.decode(AdminWebAutomationRulePatch.self, from: request.body)
                try patch.validate()
                return jsonResponse(["ok": true])
            } catch {
                return jsonResponse(["error": "validation_failed", "message": error.localizedDescription], status: "400 Bad Request")
            }

        case ("POST", "/api/automations/delete"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebAutomationRuleIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await deleteAutomation?(patch.id) == true else {
                return jsonResponse(["error": "delete_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])

        case ("POST", "/api/automations/toggle"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebAutomationRuleIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await toggleAutomation?(patch.id) == true else {
                return jsonResponse(["error": "toggle_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])

        case ("POST", "/api/automations/draft"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebAutomationDraftPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            let payload = await draftAutomation?(patch.prompt, patch.category)
                ?? AdminWebAutomationDraftPayload(rule: nil, error: "Automations drafting is unavailable.", unavailableReason: nil)
            return codableResponse(payload)

        case ("GET", "/api/announcer"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await announcerProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "announcer_unavailable"], status: "503 Service Unavailable")

        case ("POST", "/api/announcer/config/upsert"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebAnnouncerConfigUpsertPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await upsertAnnouncerConfig?(patch.config) == true else {
                return jsonResponse(["error": "upsert_failed"], status: "400 Bad Request")
            }
            audit(source: "webui", actor: actorLabel(session), action: "announcer.config.upsert", detail: "Upserted announcer configuration for channel \(patch.config.voiceChannelName)")
            return jsonResponse(["ok": true])

        case ("POST", "/api/announcer/config/toggle"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebAnnouncerConfigTogglePatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await toggleAnnouncerConfig?(patch.id, patch.enabled) == true else {
                return jsonResponse(["error": "toggle_failed"], status: "400 Bad Request")
            }
            audit(source: "webui", actor: actorLabel(session), action: "announcer.config.toggle", detail: "\(patch.enabled ? "Enabled" : "Disabled") announcer config ID \(patch.id)")
            return jsonResponse(["ok": true])

        case ("POST", "/api/announcer/config/delete"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebAnnouncerConfigDeletePatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await deleteAnnouncerConfig?(patch.id) == true else {
                return jsonResponse(["error": "delete_failed"], status: "400 Bad Request")
            }
            audit(source: "webui", actor: actorLabel(session), action: "announcer.config.delete", detail: "Deleted announcer config ID \(patch.id)")
            return jsonResponse(["ok": true])

        case ("POST", "/api/announcer/settings"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebAnnouncerSettingsPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateAnnouncerSettings?(patch) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            audit(source: "webui", actor: actorLabel(session), action: "announcer.settings.update", detail: "Updated global announcer settings")
            return jsonResponse(["ok": true])

        case ("GET", "/api/welcome-flow"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let provider = welcomeFlowProvider {
                let payload = await provider()
                return codableResponse(payload)
            }
            return jsonResponse(["error": "welcome_flow_unavailable"], status: "503 Service Unavailable")

        case ("POST", "/api/welcome-flow"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            do {
                let patch = try apiDecoder.decode(AdminWebWelcomeFlowPatch.self, from: request.body)
                try patch.validate()
                guard await updateWelcomeFlow?(patch.settings) == true else {
                    return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
                }
                return jsonResponse(["ok": true])
            } catch {
                return jsonResponse(["error": "validation_failed", "message": error.localizedDescription], status: "400 Bad Request")
            }

        case ("GET", "/api/patchy"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await patchyProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "patchy_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/patchy/state"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyStatePatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updatePatchyState?(patch) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/patchy/check"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard await runPatchyCheckNow?() == true else {
                return jsonResponse(["error": "run_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/patchy/target/new"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let target = await createPatchyTarget?() else {
                return jsonResponse(["error": "create_failed"], status: "400 Bad Request")
            }
            return codableResponse(target)
        case ("POST", "/api/patchy/target/upsert"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            do {
                let patch = try decoder.decode(AdminWebPatchyTargetPatch.self, from: request.body)
                try patch.validate()
                guard await updatePatchyTarget?(patch.target) == true else {
                    return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
                }
                return jsonResponse(["ok": true])
            } catch {
                return jsonResponse(["error": "validation_failed", "message": error.localizedDescription], status: "400 Bad Request")
            }
        case ("POST", "/api/patchy/target/toggle"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyTargetEnabledPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await setPatchyTargetEnabled?(patch.targetID, patch.enabled) == true else {
                return jsonResponse(["error": "toggle_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/patchy/target/delete"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyTargetIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await deletePatchyTarget?(patch.targetID) == true else {
                return jsonResponse(["error": "delete_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/patchy/target/test"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyTargetIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await sendPatchyTestTarget?(patch.targetID) == true else {
                return jsonResponse(["error": "test_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/patchy/target/pull"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyTargetIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await pullPatchyTarget?(patch.targetID) == true else {
                return jsonResponse(["error": "pull_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("GET", "/api/sweep"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await sweepProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "sweep_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/sweep/pause"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebSweepGlobalPausedPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await setSweepGlobalPaused?(patch.paused) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/sweep/policy/update"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            do {
                let patch = try decoder.decode(SweepPolicy.self, from: request.body)
                try patch.validate()
                guard await updateSweepPolicy?(patch) == true else {
                    return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
                }
                return jsonResponse(["ok": true])
            } catch {
                return jsonResponse(["error": "validation_failed", "message": error.localizedDescription], status: "400 Bad Request")
            }
        case ("POST", "/api/sweep/policy/delete"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebSweepPolicyIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await deleteSweepPolicy?(patch.policyID) == true else {
                return jsonResponse(["error": "delete_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/sweep/policy/toggle"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebSweepPolicyEnabledPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await setSweepPolicyEnabled?(patch.policyID, patch.enabled) == true else {
                return jsonResponse(["error": "toggle_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/sweep/policy/run"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebSweepPolicyIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await runSweepPolicy?(patch.policyID) == true else {
                return jsonResponse(["error": "run_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/sweep/policy/preview"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebSweepPolicyIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            if let report = await previewSweepPolicy?(patch.policyID) {
                return codableResponse(report)
            }
            return jsonResponse(["error": "preview_failed"], status: "400 Bad Request")
        case ("POST", "/api/sweep/draft/preview"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(SweepPolicy.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            if let report = await previewSweepDraft?(patch) {
                return codableResponse(report)
            }
            return jsonResponse(["error": "preview_failed"], status: "400 Bad Request")
        case ("POST", "/api/sweep/suggestions/scan"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard await scanSweepSuggestions?() == true else {
                return jsonResponse(["error": "scan_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/sweep/suggestions/apply"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebSweepSuggestionIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await applySweepSuggestion?(patch.suggestionID) == true else {
                return jsonResponse(["error": "apply_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/sweep/suggestions/dismiss"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebSweepSuggestionIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await dismissSweepSuggestion?(patch.suggestionID) == true else {
                return jsonResponse(["error": "dismiss_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("GET", "/api/wikibridge"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await wikiBridgeProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "wikibridge_unavailable"], status: "503 Service Unavailable")
        case ("GET", "/api/media"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await mediaLibraryProvider?(request.query) {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "media_unavailable"], status: "503 Service Unavailable")
        case ("GET", "/api/media/ffmpeg"), ("GET", "/api/media/export-status"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await mediaExportStatusProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "export_unavailable"], status: "503 Service Unavailable")
        case ("GET", "/api/media/exports"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await mediaExportJobsProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "exports_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/media/playback"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let body = try? decoder.decode(AdminWebMediaPlaybackPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await mediaPlaybackRecorder?(body) == true else {
                return jsonResponse(["error": "record_failed"], status: "500 Internal Server Error")
            }
            return jsonResponse(["ok": true])
        case ("GET", "/api/media/thumbnail"):
            guard mediaAccessAuthorized(request) else {
                return unauthorizedResponse()
            }
            guard let token = request.query["id"], !token.isEmpty else {
                return jsonResponse(["error": "missing_id"], status: "400 Bad Request")
            }
            guard let response = await mediaThumbnailProvider?(token) else {
                return jsonResponse(["error": "thumbnail_unavailable"], status: "404 Not Found")
            }
            return httpResponse(
                status: response.status,
                body: response.body,
                contentType: response.contentType,
                headers: response.headers
            )
        case ("GET", "/api/media/frame"):
            guard mediaAccessAuthorized(request) else {
                return unauthorizedResponse()
            }
            guard let token = request.query["id"], !token.isEmpty else {
                return jsonResponse(["error": "missing_id"], status: "400 Bad Request")
            }
            let seconds = Double(request.query["t"] ?? "0") ?? 0
            guard let response = await mediaFrameProvider?(token, seconds) else {
                return jsonResponse(["error": "thumbnail_unavailable"], status: "404 Not Found")
            }
            return httpResponse(
                status: response.status,
                body: response.body,
                contentType: response.contentType,
                headers: response.headers
            )
        case ("GET", "/api/media/stream"):
            guard mediaAccessAuthorized(request) else {
                return unauthorizedResponse()
            }
            guard let token = request.query["id"], !token.isEmpty else {
                return jsonResponse(["error": "missing_id"], status: "400 Bad Request")
            }
            let rangeHeader = request.headers["range"]
            let quality = request.query["quality"]
            guard let response = await mediaStreamProvider?(token, rangeHeader, quality) else {
                return jsonResponse(["error": "stream_unavailable"], status: "404 Not Found")
            }
            return httpResponse(
                status: response.status,
                body: response.body,
                contentType: response.contentType,
                headers: response.headers
            )
        case ("HEAD", "/api/media/stream"):
            guard mediaAccessAuthorized(request) else {
                return unauthorizedResponse()
            }
            guard let token = request.query["id"], !token.isEmpty else {
                return jsonResponse(["error": "missing_id"], status: "400 Bad Request")
            }
            let rangeHeader = request.headers["range"] ?? "bytes=0-0"
            let quality = request.query["quality"]
            guard let response = await mediaStreamProvider?(token, rangeHeader, quality) else {
                return jsonResponse(["error": "stream_unavailable"], status: "404 Not Found")
            }
            return httpResponse(
                status: response.status,
                body: response.body,
                contentType: response.contentType,
                headers: response.headers
            )
        case ("POST", "/api/media/export/clip"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let body = try? decoder.decode(MediaExportClipRequest.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            if let response = await mediaClipExportStarter?(body) {
                return codableResponse(response)
            }
            return jsonResponse(["error": "export_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/media/export/multiview"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let body = try? decoder.decode(MediaExportMultiViewRequest.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            if let response = await mediaMultiViewExportStarter?(body) {
                return codableResponse(response)
            }
            return jsonResponse(["error": "export_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/wikibridge/state"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebWikiBridgeStatePatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateWikiBridgeState?(patch) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/wikibridge/source/new"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let source = await createWikiSource?() else {
                return jsonResponse(["error": "create_failed"], status: "400 Bad Request")
            }
            return codableResponse(source)
        case ("POST", "/api/wikibridge/source/upsert"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            do {
                let patch = try decoder.decode(AdminWebWikiSourcePatch.self, from: request.body)
                try patch.validate()
                guard await updateWikiSource?(patch.source) == true else {
                    return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
                }
                return jsonResponse(["ok": true])
            } catch {
                return jsonResponse(["error": "validation_failed", "message": error.localizedDescription], status: "400 Bad Request")
            }
        case ("POST", "/api/wikibridge/source/toggle"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyTargetEnabledPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await setWikiSourceEnabled?(patch.targetID, patch.enabled) == true else {
                return jsonResponse(["error": "toggle_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/wikibridge/source/primary"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebWikiSourceIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await setWikiSourcePrimary?(patch.sourceID) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/wikibridge/source/test"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebWikiSourceIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await testWikiSource?(patch.sourceID) == true else {
                return jsonResponse(["error": "test_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/wikibridge/source/delete"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebWikiSourceIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await deleteWikiSource?(patch.sourceID) == true else {
                return jsonResponse(["error": "delete_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/bot/start"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            _ = await startBot?()
            await logger?("Admin Web UI requested bot start")
            audit(source: "Web Config", actor: actorLabel(session), action: "Started bot", level: "ok")
            return jsonResponse(["ok": true])
        case ("POST", "/api/bot/stop"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            _ = await stopBot?()
            await logger?("Admin Web UI requested bot stop")
            audit(source: "Web Config", actor: actorLabel(session), action: "Stopped bot", level: "warning")
            return jsonResponse(["ok": true])
        case ("POST", "/api/swiftmesh/refresh"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            _ = await refreshSwiftMesh?()
            await logger?("Admin Web UI requested SwiftMesh refresh")
            return jsonResponse(["ok": true])
        case ("GET", "/api/swiftmesh/join-code"):
            // The Join Code embeds the leader's shared secret, so treat it as
            // a bearer credential: admin-only, generated on demand (never cached),
            // and audit-logged so a leak can be traced.
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard let code = await generateSwiftMeshJoinCode?(), !code.isEmpty else {
                return jsonResponse(
                    ["error": "unavailable", "message": "Join Code is only available on Primary nodes."],
                    status: "409 Conflict"
                )
            }
            audit(source: "Web Config", actor: actorLabel(session), action: "Viewed SwiftMesh Join Code")
            return jsonResponse(["code": code])

        // MARK: - OAuth Authentication
        //
        // The Discord OAuth routes are currently used for SwiftBot Remote
        // and WebUI authentication.
        //
        // Flow:
        //
        // Remote Client → /auth/discord/login
        //               → Discord OAuth
        //               → /auth/discord/callback
        //               → session created
        //               → /api/auth/session returns token
        //
        // Remote clients then authenticate API requests using:
        //
        // Authorization: Bearer <session-id>
        //
        // NOTE FOR FUTURE SWIFTMESH WORK:
        //
        // SwiftMesh nodes currently authenticate using mesh tokens.
        // However, this OAuth identity system may later be reused for:
        //
        // • administrative access to cluster nodes
        // • remote mesh management
        // • node approval flows
        //
        // SwiftMesh authentication should remain separate from user OAuth
        // unless explicitly designed to share the same identity layer.
        //
        case ("GET", "/auth/discord/login"):
            return await handleDiscordLogin(request: request)
        case ("POST", "/auth/local/login"):
            return handleLocalLogin(request: request)
        case ("POST", "/auth/logout"):
            return handleLogout(request: request)
        case ("GET", "/api/auth/options"):
            return await handleAuthOptions()
        case ("GET", "/api/auth/session"):
            return handleSessionInfo(request: request)
        case ("GET", "/api/server/info"):
            return await handleServerInfo(request: request)
        default:
            // GET requests to unknown non-API paths get the styled 404 page so
            // a misclicked link in the browser lands somewhere friendly. API
            // and non-GET routes keep the plain text response.
            if request.method == "GET" && !request.path.hasPrefix("/api/") {
                return notFoundPageResponse(path: request.path)
            }
            return httpResponse(status: "404 Not Found", body: Data("Not Found".utf8))
        }
    }

    private func oauthErrorPageResponse(
        status: String,
        title: String,
        message: String,
        detail: String
    ) -> Data {
        return authStatusPageResponse(
            status: status,
            title: title,
            eyebrow: "SwiftBot Web Admin",
            message: message,
            detail: detail,
            actionTitle: "Back to sign in",
            actionURL: "/",
            variant: .error
        )
    }

    private func notFoundPageResponse(path: String) -> Data {
        return authStatusPageResponse(
            status: "404 Not Found",
            title: "Page not found",
            eyebrow: "SwiftBot Web Admin",
            message: "We couldn't find the page you were looking for.",
            detail: "The link may be broken or the page may have moved. Head back to the dashboard to keep going.",
            actionTitle: "Back to dashboard",
            actionURL: "/",
            variant: .notFound
        )
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<marker.lowerBound], encoding: .utf8) else {
            return nil
        }

        let body = Data(data[marker.upperBound...])
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let rawTarget = String(parts[1])
        let components = URLComponents(string: "http://localhost\(rawTarget)")
        let path = components?.path.isEmpty == false ? components?.path ?? "/" : "/"
        var query: [String: String] = [:]
        components?.queryItems?.forEach { item in
            query[item.name] = item.value ?? ""
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        return HTTPRequest(method: String(parts[0]), path: path, query: query, headers: headers, body: body)
    }

    private func serveIndex() -> Data {
        var candidates: [(Bundle, String)] = [
            (.main, "admin"),
            (.main, "Resources/admin")
        ]

#if SWIFT_PACKAGE
        candidates.append((.module, "admin"))
#endif

        for (bundle, subdirectory) in candidates {
            if let url = bundle.url(forResource: "index", withExtension: "html", subdirectory: subdirectory),
               let data = try? Data(contentsOf: url) {
                return serveIndexHTML(data)
            }
        }

        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let data = try? Data(contentsOf: url) {
            return serveIndexHTML(data)
        }

        let fallback = "<html><body><h1>SwiftBot Admin UI</h1><p>Missing bundled resource.</p></body></html>"
        return httpResponse(status: "200 OK", body: Data(fallback.utf8), contentType: "text/html; charset=utf-8")
    }

    /// Adds a per-response CSP nonce to inline `<script>` blocks in the served
    /// index page and returns the response with the matching `Content-Security-Policy`
    /// header. Injected `<script>` blocks without the nonce are blocked by the browser.
    private func serveIndexHTML(_ data: Data) -> Data {
        let nonce = base64URLEncode(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        var body = data
        if let html = String(data: data, encoding: .utf8) {
            // Regex to find `<script>` tags that do NOT have a `src` attribute.
            // Matches `<script>` or `<script type="...">` but skips `<script src="...">`.
            let regex = try? NSRegularExpression(
                pattern: "<script(?![^>]*\\bsrc=)([^>]*)>",
                options: [.caseInsensitive]
            )
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let rewritten = regex?.stringByReplacingMatches(
                in: html,
                options: [],
                range: range,
                withTemplate: "<script nonce=\"\(nonce)\"$1>"
            ) ?? html

            body = Data(rewritten.utf8)
        }
        return httpResponse(
            status: "200 OK",
            body: body,
            contentType: "text/html; charset=utf-8",
            headers: ["Content-Security-Policy": contentSecurityPolicy(scriptNonce: nonce)]
        )
    }

    /// CSP for HTML responses. With a nonce set, injected `<script>` blocks
    /// (the dominant XSS pivot) cannot execute. Inline event-handler attributes
    /// are forbidden — the admin UI uses a centralized data-action dispatcher.
    /// Inline styles are allowed (style XSS cannot execute JS in modern browsers).
    private func contentSecurityPolicy(scriptNonce: String?) -> String {
        var scriptSrc = "'self'"
        if let scriptNonce {
            scriptSrc += " 'nonce-\(scriptNonce)'"
        }
        let parts = [
            "default-src 'self'",
            "script-src \(scriptSrc)",
            "script-src-attr 'none'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data: blob: https://cdn.discordapp.com https://media.discordapp.net",
            "media-src 'self' blob:",
            "connect-src 'self'",
            "font-src 'self' data:",
            "frame-ancestors 'none'",
            "base-uri 'none'",
            "form-action 'self'",
            "object-src 'none'"
        ]
        return parts.joined(separator: "; ")
    }

    private func serveAsset(named name: String, ext: String, subdirectories: [String] = []) -> Data {
        let baseDirectories = ["Resources", "admin", "admin/assets", "Resources/admin", "Resources/admin/assets"]
        let candidates: [(Bundle, String)] = (subdirectories + baseDirectories).map { (.main, $0) }

        let contentType: String = {
            switch ext.lowercased() {
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "gif": return "image/gif"
            case "js": return "application/javascript"
            case "css": return "text/css"
            case "html": return "text/html"
            default: return "application/octet-stream"
            }
        }()

        for (bundle, subdirectory) in candidates {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory),
               let data = try? Data(contentsOf: url) {
                return httpResponse(status: "200 OK", body: data, contentType: contentType)
            }
        }

        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let data = try? Data(contentsOf: url) {
            return httpResponse(status: "200 OK", body: data, contentType: contentType)
        }

        return httpResponse(status: "404 Not Found", body: Data("Not Found".utf8))
    }

    private func handleDiscordLogin(request: HTTPRequest) async -> Data {
        let clientID = config.discordOAuth.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = config.discordOAuth.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            return oauthErrorPageResponse(
                status: "503 Service Unavailable",
                title: "Discord sign-in unavailable",
                message: "Discord OAuth hasn't been configured on this SwiftBot instance.",
                detail: "Ask an administrator to add the Discord client ID and secret in the bot's settings."
            )
        }

        let state = randomToken()
        let codeVerifier = randomToken() // High-entropy random string
        let codeChallenge = base64URLEncode(sha256(codeVerifier))

        let appRedirectURL = validatedAppRedirectURL(from: request.query["return_to"])
        pendingStates[state] = PendingState(
            value: state,
            expiresAt: Date().addingTimeInterval(stateTTL),
            appRedirectURL: appRedirectURL?.absoluteString,
            codeVerifier: codeVerifier
        )

        let uri = redirectURI()

        var components = URLComponents(string: "https://discord.com/oauth2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: uri),
            URLQueryItem(name: "scope", value: "identify guilds"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let url = components?.url else {
            return oauthErrorPageResponse(
                status: "500 Internal Server Error",
                title: "Something went wrong",
                message: "We couldn't build the Discord sign-in URL.",
                detail: "This is usually transient. Try again in a moment, or contact an administrator if it keeps happening."
            )
        }

        // Bind the OAuth state to the originating browser so a leaked `state`
        // query value can't be redeemed from a different client.
        let stateCookie = "swiftbot_oauth_state=\(state); Path=/; Max-Age=\(Int(stateTTL)); HttpOnly; Secure; SameSite=Lax"
        return redirectResponse(to: url.absoluteString, headers: ["Set-Cookie": stateCookie])
    }

    private func handleLocalLogin(request: HTTPRequest) -> Data {
        guard config.localAuthEnabled else {
            return jsonResponse(["error": "local_auth_disabled"], status: "403 Forbidden")
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
            let username = (object["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            let password = (object["password"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
        }

        let peerKey = request.peerIP ?? "unknown"
        let attemptKey = "\(peerKey)|\(username.lowercased())"
        if isBucketLocked(localLoginAttempts[attemptKey] ?? RateLimitBucket()) {
            audit(source: "Web Auth", actor: "local:\(username)", action: "Login blocked", detail: "Rate limit lockout · \(peerKey)", level: "warning")
            return jsonResponse(["error": "rate_limited"], status: "429 Too Many Requests")
        }

        let expectedUsername = config.localAuthUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedPassword = config.localAuthPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentialsValid =
            !expectedUsername.isEmpty &&
            !expectedPassword.isEmpty &&
            constantTimeEquals(username, expectedUsername) &&
            constantTimeEquals(password, expectedPassword)

        guard credentialsValid else {
            var bucket = localLoginAttempts[attemptKey] ?? RateLimitBucket()
            registerFailedAttempt(&bucket, threshold: loginFailureThreshold)
            localLoginAttempts[attemptKey] = bucket
            audit(source: "Web Auth", actor: "local:\(username)", action: "Login failed", detail: "Invalid credentials · \(peerKey)", level: "warning")
            return jsonResponse(["error": "invalid_credentials"], status: "401 Unauthorized")
        }

        localLoginAttempts[attemptKey] = nil

        let session = makeSession(
            userID: "local:\(expectedUsername)",
            username: expectedUsername,
            globalName: "Local Admin",
            discriminator: nil,
            avatar: nil,
            userAgentHash: userAgentHash(for: request)
        )
        audit(source: "Web Auth", actor: "local:\(expectedUsername)", action: "Logged in", detail: "Local fallback auth", level: "ok")
        sessions[session.id] = session
        persistSessions()
        return jsonResponse(
            [
                "ok": true,
                "user": expectedUsername
            ],
            headers: ["Set-Cookie": sessionCookie(for: session.id)]
        )
    }

    private func handleDiscordCallback(request: HTTPRequest) async -> Data {
        // The bot re-invite flow reuses this redirect URI (Discord requires a
        // pre-registered one) but returns `guild_id`/`permissions` and no
        // `state` — the bot is already added by Discord on Authorize, so just
        // acknowledge it instead of running the user-login path.
        if let guildID = request.query["guild_id"] {
            await logger?("Bot re-invite callback for guild \(guildID)")
            return authStatusPageResponse(
                status: "200 OK",
                title: "Bot permissions updated",
                eyebrow: "Discord authorization",
                message: "SwiftBot's permissions have been refreshed.",
                detail: "Guild \(guildID). You can close this tab and return to the app.",
                actionTitle: "Open Web UI",
                actionURL: "/"
            )
        }
        guard let code = request.query["code"], let state = request.query["state"] else {
            return oauthErrorPageResponse(
                status: "400 Bad Request",
                title: "Sign-in didn't complete",
                message: "Discord didn't send back the information we needed to finish signing you in.",
                detail: "Head back to the sign-in screen and try again."
            )
        }
        guard let pendingState = pendingStates.removeValue(forKey: state) else {
            return oauthErrorPageResponse(
                status: "400 Bad Request",
                title: "Sign-in link expired",
                message: "This Discord sign-in link is no longer valid.",
                detail: "Sign-in links expire after a short time. Start over from the login screen to get a fresh link."
            )
        }

        // Verify the state cookie set at /auth/discord/login matches the `state`
        // query parameter. This binds the OAuth flow to the originating browser
        // and prevents login-CSRF via a leaked `state` value.
        let stateCookieValue = cookie(named: "swiftbot_oauth_state", request: request) ?? ""
        let isAppRedirect = pendingState.appRedirectURL != nil
        if !isAppRedirect && !constantTimeEquals(stateCookieValue, state) {
            return oauthErrorPageResponse(
                status: "400 Bad Request",
                title: "Sign-in didn't complete",
                message: "The browser session that started this sign-in no longer matches.",
                detail: "Start over from the login screen in the same browser you started in."
            )
        }

        do {
            let token = try await exchangeDiscordCode(code: code, codeVerifier: pendingState.codeVerifier)
            let user = try await fetchDiscordUser(accessToken: token)
            let guilds = try await fetchDiscordGuilds(accessToken: token)
            guard await isAuthorized(userID: user.id, guilds: guilds) else {
                await logger?("Admin Web UI login denied for \(user.username) (\(user.id))")
                audit(source: "Web Auth", actor: "\(user.username) (\(user.id))", action: "Login denied", detail: "User not authorized for this bot", level: "warning")
                return authStatusPageResponse(
                    status: "403 Forbidden",
                    title: "Access not allowed",
                    eyebrow: "SwiftBot Web Admin",
                    message: "This Discord account does not have permission to sign in.",
                    detail: "Ask a SwiftBot administrator to add your Discord user ID, or sign in with an account that can manage one of the connected servers.",
                    actionTitle: "Try another Discord account",
                    actionURL: "/auth/discord/login",
                    variant: .denied
                )
            }
            guard user.mfaEnabled else {
                await logger?("Admin Web UI MFA denied for \(user.username) (\(user.id))")
                audit(source: "Web Auth", actor: "\(user.username) (\(user.id))", action: "Login denied", detail: "Discord 2FA not enabled", level: "warning")
                return authStatusPageResponse(
                    status: "403 Forbidden",
                    title: "Two-factor authentication required",
                    eyebrow: "SwiftBot Web Admin",
                    message: "Your Discord account must have two-factor authentication enabled to sign in.",
                    detail: "Open Discord → User Settings → My Account → Enable Two-Factor Auth, then try again.",
                    actionTitle: "Try again",
                    actionURL: "/auth/discord/login",
                    variant: .mfaRequired
                )
            }

            let session = Session(
                id: randomToken(),
                userID: user.id,
                username: user.username,
                globalName: user.globalName,
                discriminator: user.discriminator,
                avatar: user.avatar,
                csrfToken: randomToken(),
                expiresAt: Date().addingTimeInterval(sessionTTL),
                userAgentHash: userAgentHash(for: request),
                role: .admin
            )
            sessions[session.id] = session
            persistSessions()
            await logger?("Admin Web UI login for \(user.username) (\(user.id))")
            audit(source: "Web Auth", actor: "\(user.username) (\(user.id))", action: "Logged in", detail: "Discord OAuth", level: "ok")
            let redirectTarget = remoteAuthRedirectURL(
                from: pendingState.appRedirectURL,
                sessionID: session.id
            ) ?? "/"
            return redirectResponse(
                to: redirectTarget,
                headers: ["Set-Cookie": sessionCookie(for: session.id)]
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await logger?("Admin Web UI OAuth failed: \(message)")
            return oauthErrorPageResponse(
                status: "502 Bad Gateway",
                title: "Discord sign-in failed",
                message: "We couldn't complete the Discord sign-in.",
                detail: message
            )
        }
    }

    private func handleLogout(request: HTTPRequest) -> Data {
        if let sessionID = cookie(named: "swiftbot_admin_session", request: request) {
            if let session = sessions[sessionID] {
                audit(source: "Web Auth", actor: "\(session.username) (\(session.userID))", action: "Logged out", level: "info")
            }
            sessions.removeValue(forKey: sessionID)
            persistSessions()
        }
        return jsonResponse(
            ["ok": true],
            headers: ["Set-Cookie": "swiftbot_admin_session=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax"]
        )
    }

    private func handleSessionInfo(request: HTTPRequest) -> Data {
        guard let session = authenticatedSession(for: request) else {
            return unauthorizedResponse()
        }

        return jsonResponse([
            "user": session.username,
            "discordUserID": session.userID,
            "globalName": session.globalName ?? "",
            "discriminator": session.discriminator ?? "",
            "avatar": session.avatar ?? "",
            "permissions": [session.role.rawValue],
            "sessionToken": session.id,
            "expiresAt": ISO8601DateFormatter().string(from: session.expiresAt)
        ])
    }

    private func forbiddenResponse() -> Data {
        jsonResponse(["error": "forbidden", "message": "You do not have permission to perform this action."], status: "403 Forbidden")
    }

    private func handleAuthOptions() async -> Data {
        let discordConfigured =
            !config.discordOAuth.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !config.discordOAuth.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let localEnabled =
            config.localAuthEnabled &&
            !config.localAuthUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !config.localAuthPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let devFeaturesEnabled = config.devFeaturesEnabled

        // Expose the running bot's identity on the unauthenticated login screen
        // so it can greet the operator personally instead of generic "SwiftBot".
        let status = await statusProvider?()
        let botName = status?.botUsername ?? "SwiftBot"
        let botAvatarURL = status?.botAvatarURL ?? ""

        return jsonResponse([
            "discordEnabled": discordConfigured,
            "localEnabled": localEnabled && devFeaturesEnabled,
            "devFeaturesEnabled": devFeaturesEnabled,
            "botName": botName,
            "botAvatarURL": botAvatarURL
        ])
    }

    private func handleServerInfo(request: HTTPRequest) async -> Data {
        guard authenticatedSession(for: request) != nil else {
            return unauthorizedResponse()
        }

        // Get status info for Discord connection state
        let status = await statusProvider?()
        let discordConnected = status?.botStatus == "online" || status?.botStatus == "connected"

        // Get config info for cluster details
        let config = await configProvider?()
        let clusterMode = config?.swiftMesh.mode ?? "standalone"
        let nodeName = config?.swiftMesh.nodeName ?? "SwiftBot"
        let meshEnabled = config?.general.webUIEnabled ?? false

        return jsonResponse([
            "nodeName": nodeName,
            "version": "1.0",
            "clusterMode": clusterMode,
            "meshEnabled": meshEnabled,
            "discordConnected": discordConnected
        ])
    }

    /// Reads `?category=automation|moderation`, defaulting to `.automation`
    /// when absent or unrecognised.
    private func categoryParam(from request: HTTPRequest) -> Automations.Category {
        if let raw = request.query["category"],
           let kind = Automations.Category(rawValue: raw) {
            return kind
        }
        return .automation
    }

    private func authenticatedSession(for request: HTTPRequest) -> Session? {
        // First try cookie-based session (WebUI)
        if let sessionID = cookie(named: "swiftbot_admin_session", request: request),
           let session = sessions[sessionID],
           session.expiresAt > Date(),
           sessionUserAgentMatches(session, request: request) {
            return session
        }

        // Then try Bearer token (Remote client)
        if let authorization = request.headers["authorization"],
           authorization.hasPrefix("Bearer ") {
            let sessionID = String(authorization.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
            if let session = sessions[sessionID],
               session.expiresAt > Date(),
               sessionUserAgentMatches(session, request: request) {
                return session
            }
        }

        return nil
    }

    /// Session was bound to a UA at login — reject if it changed. If the session has
    /// no recorded UA (legacy or native client that sent none), binding is not
    /// enforced so we don't break existing Remote app installs.
    private func sessionUserAgentMatches(_ session: Session, request: HTTPRequest) -> Bool {
        guard let bound = session.userAgentHash, !bound.isEmpty else { return true }
        return constantTimeEquals(bound, userAgentHash(for: request))
    }

    private func mediaAccessAuthorized(_ request: HTTPRequest) -> Bool {
        if authenticatedSession(for: request) != nil { return true }
        guard let token = request.query["token"], !token.isEmpty,
              let boundSessionID = validateMediaAccessToken(token),
              let session = sessions[boundSessionID],
              session.expiresAt > Date() else {
            return false
        }
        return true
    }

    private func isRemoteRequestAuthorized(_ request: HTTPRequest) -> Bool {
        authenticatedSession(for: request) != nil
    }

    private func validatedAppRedirectURL(from rawValue: String?) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "swiftbot",
              url.host?.lowercased() == "auth" else {
            return nil
        }
        return url
    }

    private func remoteAuthRedirectURL(from rawValue: String?, sessionID: String) -> String? {
        guard let rawValue,
              let url = URL(string: rawValue),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "session" }
        queryItems.append(URLQueryItem(name: "session", value: sessionID))
        components.queryItems = queryItems
        return components.url?.absoluteString
    }

    private func validateCSRF(session: Session, request: HTTPRequest) -> Bool {
        guard let provided = request.headers["x-admin-csrf"] else { return false }
        return constantTimeEquals(provided, session.csrfToken)
    }

    private func cookie(named name: String, request: HTTPRequest) -> String? {
        guard let cookieHeader = request.headers["cookie"] else { return nil }
        let cookies = cookieHeader.split(separator: ";")
        for cookie in cookies {
            let parts = cookie.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if key == name {
                return String(parts[1])
            }
        }
        return nil
    }

    private func isAuthorized(userID: String, guilds: [DiscordGuildSummary]) async -> Bool {
        let allowed = config.allowedUserIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if allowed.contains(userID) {
            return true
        }

        let connectedGuildIDs = await connectedGuildIDsProvider?() ?? []
        guard !connectedGuildIDs.isEmpty else { return false }

        return guilds.contains { guild in
            guard connectedGuildIDs.contains(guild.id) else { return false }
            if guild.owner == true { return true }
            guard let raw = guild.permissions, let permissions = UInt64(raw) else { return false }
            let administratorBit: UInt64 = 1 << 3
            let manageGuildBit: UInt64 = 1 << 5
            return (permissions & administratorBit) != 0 || (permissions & manageGuildBit) != 0
        }
    }

    private func exchangeDiscordCode(code: String, codeVerifier: String?) async throws -> String {
        guard let url = URL(string: "https://discord.com/api/oauth2/token") else {
            throw OAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = [
            "client_id": config.discordOAuth.clientID,
            "client_secret": config.discordOAuth.clientSecret,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI()
        ]
        if let codeVerifier {
            form["code_verifier"] = codeVerifier
        }
        request.httpBody = form
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = object["access_token"] as? String,
            !accessToken.isEmpty
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed(http.statusCode, "Unexpected token payload: \(body)")
        }

        return accessToken
    }

    private func fetchDiscordUser(accessToken: String) async throws -> DiscordUser {
        guard let url = URL(string: "https://discord.com/api/users/@me") else {
            throw OAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.userFetchFailed((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String,
            let username = object["username"] as? String
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.userFetchFailed(http.statusCode, "Unexpected user payload: \(body)")
        }

        return DiscordUser(
            id: id,
            username: username,
            globalName: object["global_name"] as? String,
            discriminator: object["discriminator"] as? String,
            avatar: object["avatar"] as? String,
            mfaEnabled: (object["mfa_enabled"] as? Bool) ?? false
        )
    }

    private func fetchDiscordGuilds(accessToken: String) async throws -> [DiscordGuildSummary] {
        guard let url = URL(string: "https://discord.com/api/users/@me/guilds") else {
            throw OAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.guildFetchFailed((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }

        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.guildFetchFailed(http.statusCode, "Unexpected guild payload: \(body)")
        }

        return array.compactMap { item in
            guard let id = item["id"] as? String else { return nil }

            let owner: Bool?
            if let value = item["owner"] as? Bool {
                owner = value
            } else {
                owner = nil
            }

            let permissions = (item["permissions"] as? String)
                ?? (item["permissions_new"] as? String)
                ?? (item["permissions"] as? NSNumber)?.stringValue
                ?? (item["permissions_new"] as? NSNumber)?.stringValue

            return DiscordGuildSummary(id: id, owner: owner, permissions: permissions)
        }
    }

    private func redirectURI() -> String {
        let resolvedBase = activePublicBaseURL.isEmpty
            ? resolvedPublicBaseURL(usingTLS: config.https != nil)
            : activePublicBaseURL

        Task {
            await logger?("[OAuth] Constructing redirectURI from base='\(resolvedBase)' and path='\(config.redirectPath)'")
        }

        let result = adminWebOAuthRedirectURL(baseURL: resolvedBase, redirectPath: config.redirectPath)

        Task {
            await logger?("[OAuth] Resulting redirectURI: \(result)")
        }

        return result
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func randomToken() -> String {
        // Use 48 bytes to ensure we get a 64-character string after base64 encoding.
        // RFC 7636 (PKCE) requires code_verifier to be between 43 and 128 characters.
        let bytes = (0..<48).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Installs (or replaces) the structured audit-log sink. Hooks AppModel's
    /// `recordAudit(...)` to the web server's auth/config events.
    func setAuditLogger(_ sink: @escaping @Sendable (String, String, String, String?, String) -> Void) {
        self.auditLogger = sink
    }

    /// Internal helper to emit a structured audit event.
    private func audit(
        source: String,
        actor: String,
        action: String,
        detail: String? = nil,
        level: String = "info"
    ) {
        auditLogger?(source, actor, action, detail, level)
    }

    /// Human-readable identifier for audit-log "actor" field given a session.
    private func actorLabel(_ session: Session) -> String {
        if session.userID.hasPrefix("local:") {
            return "local:\(session.username)"
        }
        return "\(session.username) (\(session.userID))"
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var diff = UInt8(a.count ^ b.count)
        for i in 0..<Swift.max(a.count, b.count) {
            let lb = i < a.count ? a[i] : 0
            let rb = i < b.count ? b[i] : 0
            diff |= lb ^ rb
        }
        return diff == 0
    }

    private func serverSigningKey() -> SymmetricKey {
        if let cached = cachedSigningKey { return cached }
        if let stored = KeychainHelper.load(account: signingKeyKeychainAccount),
           let data = Data(base64Encoded: stored) {
            let key = SymmetricKey(data: data)
            cachedSigningKey = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        let encoded = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        KeychainHelper.save(encoded, account: signingKeyKeychainAccount)
        cachedSigningKey = key
        return key
    }

    private func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func userAgentHash(for request: HTTPRequest) -> String {
        let ua = request.headers["user-agent"] ?? ""
        if ua.isEmpty { return "" }
        return sha256Hex(ua)
    }

    /// Mints a short-lived signed token granting media access for the given session.
    /// Format: base64url(payload) "." base64url(hmac) where payload is "<sessionID>:<expiryEpoch>".
    private func mintMediaAccessToken(sessionID: String) -> (token: String, expiresAt: Date) {
        let expiresAt = Date().addingTimeInterval(mediaAccessTokenTTL)
        let payload = "\(sessionID):\(Int(expiresAt.timeIntervalSince1970))"
        let payloadData = Data(payload.utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: payloadData, using: serverSigningKey())
        let signatureData = Data(signature)
        let token = "\(base64URLEncode(payloadData)).\(base64URLEncode(signatureData))"
        return (token, expiresAt)
    }

    /// Validates a media access token; returns the bound session ID on success.
    private func validateMediaAccessToken(_ token: String) -> String? {
        let parts = token.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let payloadData = base64URLDecode(parts[0]),
              let signatureData = base64URLDecode(parts[1]),
              let payload = String(data: payloadData, encoding: .utf8) else {
            return nil
        }
        let expected = HMAC<SHA256>.authenticationCode(for: payloadData, using: serverSigningKey())
        guard Data(expected).count == signatureData.count else { return nil }
        var diff: UInt8 = 0
        let expectedBytes = Data(expected)
        for i in 0..<expectedBytes.count {
            diff |= expectedBytes[i] ^ signatureData[i]
        }
        guard diff == 0 else { return nil }
        let segments = payload.split(separator: ":", maxSplits: 1).map(String.init)
        guard segments.count == 2,
              let expiry = TimeInterval(segments[1]),
              Date(timeIntervalSince1970: expiry) > Date() else {
            return nil
        }
        return segments[0]
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func sha256(_ string: String) -> Data {
        Data(CryptoKit.SHA256.hash(data: Data(string.utf8)))
    }

    private func base64URLDecode(_ input: String) -> Data? {
        var s = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    private func registerFailedAttempt(_ bucket: inout RateLimitBucket, threshold: Int, now: Date = Date()) {
        bucket.failures.removeAll { now.timeIntervalSince($0) > loginFailureWindow }
        bucket.failures.append(now)
        if bucket.failures.count >= threshold {
            bucket.lockedUntil = now.addingTimeInterval(loginLockoutDuration)
            bucket.failures.removeAll()
        }
    }

    private func isBucketLocked(_ bucket: RateLimitBucket, now: Date = Date()) -> Bool {
        if let until = bucket.lockedUntil, until > now { return true }
        return false
    }

    private func makeSession(
        userID: String,
        username: String,
        globalName: String?,
        discriminator: String?,
        avatar: String?,
        role: Role = .admin,
        userAgentHash: String? = nil
    ) -> Session {
        Session(
            id: randomToken(),
            userID: userID,
            username: username,
            globalName: globalName,
            discriminator: discriminator,
            avatar: avatar,
            csrfToken: randomToken(),
            expiresAt: Date().addingTimeInterval(sessionTTL),
            userAgentHash: userAgentHash,
            role: role
        )
    }

    private func sessionCookie(for sessionID: String) -> String {
        "swiftbot_admin_session=\(sessionID); Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=\(Int(sessionTTL))"
    }

    private func pruneExpiredState() {
        let now = Date()
        pendingStates = pendingStates.filter { $0.value.expiresAt > now }
    }

    private func pruneExpiredSessions() {
        let now = Date()
        let beforeCount = sessions.count
        sessions = sessions.filter { $0.value.expiresAt > now }
        if sessions.count != beforeCount {
            persistSessions()
        }
    }

    private func loadPersistedSessions() {
        // One-time migration: drain any sessions stashed in UserDefaults by previous
        // builds into the Keychain, then clear the plist entry so it's not readable
        // by other processes running as this user.
        if let legacy = UserDefaults.standard.data(forKey: sessionsDefaultsKey) {
            if let legacyString = String(data: legacy, encoding: .utf8) {
                KeychainHelper.save(legacyString, account: sessionsKeychainAccount)
            }
            UserDefaults.standard.removeObject(forKey: sessionsDefaultsKey)
        }

        guard let stored = KeychainHelper.load(account: sessionsKeychainAccount),
              let data = stored.data(using: .utf8),
              let decoded = try? decoder.decode([String: Session].self, from: data) else {
            sessions = [:]
            return
        }
        let now = Date()
        sessions = decoded.filter { $0.value.expiresAt > now }
    }

    private func persistSessions() {
        if sessions.isEmpty {
            KeychainHelper.delete(account: sessionsKeychainAccount)
            return
        }
        guard let data = try? encoder.encode(sessions),
              let serialized = String(data: data, encoding: .utf8) else { return }
        KeychainHelper.save(serialized, account: sessionsKeychainAccount)
    }

    private func codableResponse<T: Encodable>(_ value: T) -> Data {
        let body = (try? apiEncoder.encode(value)) ?? Data("{}".utf8)
        return httpResponse(status: "200 OK", body: body, contentType: "application/json; charset=utf-8")
    }

    private func jsonResponse(_ object: [String: Any], status: String = "200 OK", headers: [String: String] = [:]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return httpResponse(status: status, body: data, contentType: "application/json; charset=utf-8", headers: headers)
    }

    private func unauthorizedResponse() -> Data {
        jsonResponse(["error": "unauthorized"], status: "401 Unauthorized")
    }

    enum AuthStatusVariant {
        case success
        case denied
        case notFound
        case error
        case mfaRequired
    }

    private func authStatusPageResponse(
        status: String,
        title: String,
        eyebrow: String,
        message: String,
        detail: String,
        actionTitle: String,
        actionURL: String,
        variant: AuthStatusVariant = .success
    ) -> Data {
        let safeTitle = escapedHTML(title)
        let safeEyebrow = escapedHTML(eyebrow)
        let safeMessage = escapedHTML(message)
        let safeDetail = escapedHTML(detail)
        let safeActionTitle = escapedHTML(actionTitle)
        let safeActionURL = escapedHTML(actionURL)
        let isDenied = (variant == .denied)
        let isNotFound = (variant == .notFound)
        let isError = (variant == .error)
        let isMFARequired = (variant == .mfaRequired)
        let heroHTML: String
        let extraStyles: String
        let bgStreamHTML: String
        heroHTML = "<img src=\"/assets/SwiftBird3.png\" alt=\"SwiftBot Logo\">"

        extraStyles = """
        .bg-symbols {
          position: fixed;
          inset: 0;
          overflow: hidden;
          pointer-events: none;
          z-index: 0;
        }
        .bg-symbols span {
          position: absolute;
          bottom: -10vh;
          display: inline-flex;
          opacity: 0;
          will-change: transform, opacity;
          animation-name: status-float-up;
          animation-timing-function: linear;
          animation-iteration-count: infinite;
        }
        .bg-symbols svg {
          width: 100%;
          height: 100%;
          stroke-width: 1.6;
        }
        @keyframes status-float-up {
          0%   { transform: translateY(0) rotate(0deg); opacity: 0; }
          15%  { opacity: 0.55; }
          85%  { opacity: 0.55; }
          100% { transform: translateY(-120vh) rotate(360deg); opacity: 0; }
        }
        """

        let icons: [String]
        let palette: [String]
        if isDenied {
            icons = [
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>"#,
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 4 6v6c0 5 3.5 8.5 8 10 4.5-1.5 8-5 8-10V6l-8-3z"/><path d="M9 9l6 6M15 9l-6 6"/></svg>"#,
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M5.6 5.6l12.8 12.8"/></svg>"#,
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 2 20h20L12 3z"/><path d="M12 10v5M12 18h.01"/></svg>"#,
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="15" r="3"/><path d="M10 13l8-8M14 7l3 3M3 21 21 3"/></svg>"#
            ]
            palette = ["#ff8a3d", "#ff4d4d", "#ff6b35", "#e0392b", "#ffa066", "#c2410c", "#f97316"]
        } else if isNotFound {
            icons = ["?"]
            palette = ["#5b8def", "#7c5cff", "#3aa0ff", "#8aa6ff", "#a78bfa", "#60a5fa", "#818cf8"]
        } else if isError {
            icons = [
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 2 20h20L12 3z"/><path d="M12 10v5M12 18h.01"/></svg>"#,
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a4 4 0 0 0 5 5L21 12.6 12.6 21a2 2 0 0 1-2.8-2.8L18.2 9.7a4 4 0 0 0-5-5L11.4 3 3 11.4a2 2 0 0 0 2.8 2.8z"/></svg>"#,
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M9 2v6M15 2v6M6 8h12v4a6 6 0 0 1-12 0z"/><path d="M12 18v4"/></svg>"#,
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 0 1 15-6.7L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-15 6.7L3 16"/><path d="M3 21v-5h5"/></svg>"#
            ]
            palette = ["#f59e0b", "#fbbf24", "#facc15", "#eab308", "#d97706", "#fb923c", "#f97316"]
        } else if isMFARequired {
            // 2FA-themed glyphs: padlock, key, shield with check, authenticator
            // phone with shield, fingerprint, KeyRound, and a TOTP-style hexagon.
            icons = [
                // Padlock (closed)
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>"#,
                // Key
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><circle cx="7.5" cy="15.5" r="3.5"/><path d="M10 13 21 2"/><path d="M16 7l3 3"/><path d="M18 5l3 3"/></svg>"#,
                // Shield with checkmark
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 4 6v6c0 5 3.5 8.5 8 10 4.5-1.5 8-5 8-10V6l-8-3z"/><path d="M9 12l2 2 4-4"/></svg>"#,
                // Phone with shield (authenticator app)
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="2" width="12" height="20" rx="2"/><path d="M12 18h.01"/><path d="M9 7l3-1 3 1v2.5c0 1.7-1.3 3-3 3.5-1.7-.5-3-1.8-3-3.5V7z"/></svg>"#,
                // Fingerprint
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 11v2a9 9 0 0 1-.6 3"/><path d="M9 13a3 3 0 1 1 6 0 9 9 0 0 1-.4 2.5"/><path d="M6 13a6 6 0 0 1 12 0v.5"/><path d="M3.5 12a8.5 8.5 0 0 1 17 0"/><path d="M7 18.8q.5-1 .8-2.3"/><path d="M16.5 19a17 17 0 0 0 1-3.5"/></svg>"#,
                // Lock with rounded keyhole (KeyRound style)
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="15" r="4"/><path d="M10.85 12.15 19 4"/><path d="M18 5l3 3"/><path d="M15 8l3 3"/></svg>"#,
                // TOTP hexagon
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 21 7 21 17 12 22 3 17 3 7 12 2"/><circle cx="12" cy="12" r="3"/></svg>"#
            ]
            // Warm amber/gold palette — security warning without the harshness of red.
            palette = ["#f59e0b", "#fbbf24", "#fcd34d", "#facc15", "#eab308", "#d97706", "#f97316"]
        } else {
            // Success/Generic
            icons = [
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>"#,
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg>"#,
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg>"#
            ]
            palette = ["#5865f2", "#4752c4", "#3b82f6", "#6366f1", "#818cf8"]
        }

        let count = 90
        var iconsHTML = ""
        var seed: UInt32 = 0x9E3779B1
        func next() -> Double {
            seed &+= 0x6D2B79F5
            var t = seed
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return Double((t ^ (t >> 14)) & 0xFFFFFF) / Double(0xFFFFFF)
        }
        for _ in 0..<count {
            let leftPct = next() * 100.0
            let duration = 30.0 + next() * 40.0
            let delay = next() * duration
            let svg = icons[Int(next() * Double(icons.count)) % icons.count]
            let color = palette[Int(next() * Double(palette.count)) % palette.count]
            let size: String = (icons.count == 1 && icons[0] == "?") ? "font-size:\(18 + Int(next() * 40))px" : "width:\(14 + Int(next() * 22))px;height:\(14 + Int(next() * 22))px"
            iconsHTML += "<span style=\"left:\(String(format: "%.2f", leftPct))%;\(size);color:\(color);animation-duration:\(String(format: "%.2f", duration))s;animation-delay:-\(String(format: "%.2f", delay))s\">\(svg)</span>"
        }
        bgStreamHTML = "<div class=\"bg-symbols\" aria-hidden=\"true\">\(iconsHTML)</div>"
        let body = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(safeTitle) - SwiftBot</title>
          <link rel="icon" type="image/png" href="/favicon.png">
          <style>
            :root {
              color-scheme: light dark;
              --page-bg: #080b11;
              --text: rgba(255, 255, 255, 0.94);
              --muted: rgba(255, 255, 255, 0.62);
              --soft: rgba(255, 255, 255, 0.42);
              --card: rgba(10, 10, 15, 0.45);
              --stroke: rgba(255, 255, 255, 0.15);
              --button: linear-gradient(135deg, #5865f2 0%, #4c57d6 100%);
            }
            @media (prefers-color-scheme: light) {
              :root {
                --page-bg: #f4f5f7;
                --text: #1d1d1f;
                --muted: rgba(0, 0, 0, 0.66);
                --soft: rgba(0, 0, 0, 0.50);
                --card: rgba(255, 255, 255, 0.45);
                --stroke: rgba(255, 255, 255, 0.45);
              }
            }
            * { box-sizing: border-box; }
            body {
              min-height: 100vh;
              margin: 0;
              display: grid;
              place-items: center;
              padding: 24px 20px;
              overflow: hidden;
              background: var(--page-bg);
              color: var(--text);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", system-ui, sans-serif;
            }
            body::before {
              content: "";
              position: fixed;
              width: 40rem;
              height: 40rem;
              top: -10rem;
              left: 50%;
              transform: translateX(-50%);
              border-radius: 999px;
              background: radial-gradient(circle, rgba(32, 140, 255, 0.34), transparent 70%);
              filter: blur(80px);
              pointer-events: none;
            }
            body::after {
              content: "";
              position: fixed;
              inset: 0;
              opacity: 0.03;
              background-image: radial-gradient(circle at center, currentColor 1px, transparent 1px);
              background-size: 32px 32px;
              pointer-events: none;
            }
            main {
              position: relative;
              z-index: 1;
              width: min(440px, 100%);
              padding: 28px 22px 22px;
              border: 1px solid var(--stroke);
              border-radius: 24px;
              background: var(--card);
              box-shadow: 0 20px 50px rgba(0, 0, 0, 0.24);
              backdrop-filter: blur(12px) saturate(1.8);
              -webkit-backdrop-filter: blur(12px) saturate(1.8);
              text-align: center;
            }
            img {
              width: 88px;
              height: 88px;
              object-fit: contain;
              border-radius: 999px;
              filter: drop-shadow(0 0 20px rgba(255, 255, 255, 0.15));
            }
            .eyebrow {
              margin: 18px 0 8px;
              color: var(--soft);
              font-size: 11px;
              font-weight: 700;
              letter-spacing: 0.12em;
              text-transform: uppercase;
            }
            h1 {
              margin: 0;
              font-size: 32px;
              line-height: 1.05;
              letter-spacing: -0.03em;
            }
            p {
              margin: 10px auto 0;
              max-width: 336px;
              color: var(--muted);
              font-size: 14px;
              line-height: 1.48;
            }
            .detail {
              color: var(--soft);
              font-size: 13px;
            }
            a {
              width: 100%;
              height: 56px;
              margin-top: 24px;
              border-radius: 14px;
              display: inline-flex;
              align-items: center;
              justify-content: center;
              color: #fff;
              background: var(--button);
              font-size: 16px;
              font-weight: 650;
              text-decoration: none;
              box-shadow: 0 4px 15px rgba(88, 101, 242, 0.25);
            }
            a:hover { transform: translateY(-1px); }
            \(extraStyles)
          </style>
        </head>
        <body>
          \(bgStreamHTML)
          <main>
            \(heroHTML)
            <div class="eyebrow">\(safeEyebrow)</div>
            <h1>\(safeTitle)</h1>
            <p>\(safeMessage)</p>
            <p class="detail">\(safeDetail)</p>
            <a href="\(safeActionURL)">\(safeActionTitle)</a>
          </main>
        </body>
        </html>
        """
        return httpResponse(
            status: status,
            body: Data(body.utf8),
            contentType: "text/html; charset=utf-8",
            headers: ["Content-Security-Policy": contentSecurityPolicy(scriptNonce: nil)]
        )
        }

    private func escapedHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func redirectResponse(to location: String, headers: [String: String] = [:]) -> Data {
        var finalHeaders = headers
        finalHeaders["Location"] = location
        return httpResponse(status: "302 Found", body: Data(), headers: finalHeaders)
    }

    private func httpResponse(
        status: String,
        body: Data,
        contentType: String = "text/plain; charset=utf-8",
        headers: [String: String] = [:]
    ) -> Data {
        let normalizedHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        var response = "HTTP/1.1 \(status)\r\n"
        if normalizedHeaders["content-length"] == nil {
            response += "Content-Length: \(body.count)\r\n"
        }
        if normalizedHeaders["content-type"] == nil {
            response += "Content-Type: \(contentType)\r\n"
        }
        if normalizedHeaders["cache-control"] == nil {
            response += "Cache-Control: no-store\r\n"
        }
        if normalizedHeaders["x-content-type-options"] == nil {
            response += "X-Content-Type-Options: nosniff\r\n"
        }
        if normalizedHeaders["x-frame-options"] == nil {
            response += "X-Frame-Options: DENY\r\n"
        }
        if normalizedHeaders["referrer-policy"] == nil {
            response += "Referrer-Policy: no-referrer\r\n"
        }
        if normalizedHeaders["permissions-policy"] == nil {
            response += "Permissions-Policy: geolocation=(), microphone=(), camera=(), payment=()\r\n"
        }
        if normalizedHeaders["cross-origin-opener-policy"] == nil {
            response += "Cross-Origin-Opener-Policy: same-origin\r\n"
        }
        if normalizedHeaders["cross-origin-resource-policy"] == nil {
            response += "Cross-Origin-Resource-Policy: same-origin\r\n"
        }
        if activeTransportUsesTLS, normalizedHeaders["strict-transport-security"] == nil {
            response += "Strict-Transport-Security: max-age=31536000; includeSubDomains\r\n"
        }
        // For HTML responses without an explicit CSP (e.g. auth status pages), apply
        // a nonce-less default that blocks all inline + external scripts. The index
        // page sets its own header with a nonce.
        if contentType.hasPrefix("text/html"), normalizedHeaders["content-security-policy"] == nil {
            response += "Content-Security-Policy: \(contentSecurityPolicy(scriptNonce: nil))\r\n"
        }
        headers.forEach { key, value in
            response += "\(key): \(value)\r\n"
        }
        if normalizedHeaders["connection"] == nil {
            response += "Connection: keep-alive\r\n"
        }
        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)
        return data
    }
}

private final class AdminWebNIOHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let badRequestResponse = Data(
        "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nBad Request".utf8
    )

    private let maxHTTPRequestSize: Int
    private let processor: @Sendable (Data) async -> Data
    private var buffer = Data()
    private var isProcessing = false
    private var hasWrittenResponse = false
    private var processorTask: Task<Void, Never>?

    init(maxHTTPRequestSize: Int, processor: @escaping @Sendable (Data) async -> Data) {
        self.maxHTTPRequestSize = maxHTTPRequestSize
        self.processor = processor
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var chunk = unwrapInboundIn(data)
        if let bytes = chunk.readBytes(length: chunk.readableBytes) {
            buffer.append(contentsOf: bytes)
        }

        guard buffer.count <= maxHTTPRequestSize else {
            writeResponse(Self.badRequestResponse, context: context, closeAfterWrite: true)
            return
        }

        tryProcessNextRequest(context: context)
    }

    private func tryProcessNextRequest(context: ChannelHandlerContext) {
        guard !isProcessing,
              !hasWrittenResponse,
              let frame = Self.extractNextHTTPRequest(buffer) else {
            return
        }

        isProcessing = true
        let requestData = frame.request
        buffer = frame.remainder
        let clientRequestedClose = frame.connectionClose

        nonisolated(unsafe) let unsafeContext = context
        let eventLoop = context.eventLoop
        processorTask = Task { [weak self] in
            guard let self else { return }
            let response = await self.processor(requestData)
            let serverRequestedClose = Self.responseRequestsClose(response)
            eventLoop.execute {
                self.writeResponse(
                    response,
                    context: unsafeContext,
                    closeAfterWrite: clientRequestedClose || serverRequestedClose
                )
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        processorTask?.cancel()
        processorTask = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !hasWrittenResponse else {
            context.close(promise: nil)
            return
        }

        writeResponse(Self.badRequestResponse, context: context, closeAfterWrite: true)
    }

    private func writeResponse(_ response: Data, context: ChannelHandlerContext, closeAfterWrite: Bool) {
        guard !hasWrittenResponse else { return }
        hasWrittenResponse = true

        nonisolated(unsafe) let unsafeContext = context
        context.eventLoop.execute {
            var buffer = unsafeContext.channel.allocator.buffer(capacity: response.count)
            buffer.writeBytes(response)
            unsafeContext.writeAndFlush(self.wrapOutboundOut(buffer)).whenComplete { _ in
                if closeAfterWrite {
                    unsafeContext.close(promise: nil)
                    return
                }
                self.hasWrittenResponse = false
                self.isProcessing = false
                self.processorTask = nil
                self.tryProcessNextRequest(context: unsafeContext)
            }
        }
    }

    private struct HTTPFrame {
        let request: Data
        let remainder: Data
        let connectionClose: Bool
    }

    private static func extractNextHTTPRequest(_ buffer: Data) -> HTTPFrame? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = buffer[..<headerRange.upperBound]
        let contentLength = parseContentLength(headerData)
        let bodyEnd = headerRange.upperBound + contentLength
        guard buffer.count >= bodyEnd else { return nil }
        let request = buffer.subdata(in: 0..<bodyEnd)
        let remainder = buffer.subdata(in: bodyEnd..<buffer.count)
        let close = clientRequestedClose(headerData)
        return HTTPFrame(request: request, remainder: remainder, connectionClose: close)
    }

    private static func clientRequestedClose(_ headerData: Data.SubSequence) -> Bool {
        guard let text = String(data: Data(headerData), encoding: .utf8) else { return false }
        for line in text.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("connection:") {
                return lower.contains("close")
            }
        }
        // HTTP/1.0 defaults to close, HTTP/1.1 defaults to keep-alive.
        return text.contains(" HTTP/1.0")
    }

    private static func responseRequestsClose(_ response: Data) -> Bool {
        guard let headerEnd = response.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let headerData = response[..<headerEnd.upperBound]
        guard let text = String(data: Data(headerData), encoding: .utf8) else { return false }
        for line in text.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("connection:") {
                return lower.contains("close")
            }
        }
        return false
    }

    private static func isCompleteHTTPRequest(_ buffer: Data) -> Bool {
        extractNextHTTPRequest(buffer) != nil
    }

    private static func parseContentLength(_ headerData: Data.SubSequence) -> Int {
        guard let text = String(data: Data(headerData), encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:"),
               let value = lower.split(separator: ":").last,
               let count = Int(value.trimmingCharacters(in: .whitespaces)) {
                return count
            }
        }
        return 0
    }
}
