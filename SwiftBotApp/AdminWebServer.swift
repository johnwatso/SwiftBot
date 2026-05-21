import Foundation
import Network
import Darwin
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
// - Bearer token: Authorization: Bearer <session-id> (for remote clients)

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

    struct AIBots: Codable {
        let localAIDMReplyEnabled: Bool
        let preferredProvider: String
        let openAIEnabled: Bool
        let openAIModel: String
        let openAIImageGenerationEnabled: Bool
        let openAIImageMonthlyLimitPerUser: Int
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
    let aiBots: AIBots
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
    var preferredAIProvider: String?
    var openAIEnabled: Bool?
    var openAIModel: String?
    var openAIImageGenerationEnabled: Bool?
    var openAIImageMonthlyLimitPerUser: Int?
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

struct AdminWebAutomationRulePatch: Codable {
    let rule: Automations.Rule
}

struct AdminWebAutomationRuleIDPatch: Codable {
    let id: String
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

struct AdminWebPatchyTargetPatch: Codable {
    let target: PatchySourceTarget
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

struct AdminWebWikiSourcePatch: Codable {
    let source: WikiSource
}

struct AdminWebWikiSourceIDPatch: Codable {
    let sourceID: UUID
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
        var discordOAuth: OAuthProviderSettings
        var localAuthEnabled: Bool
        var localAuthUsername: String
        var localAuthPassword: String
        var redirectPath: String
        var allowedUserIDs: [String]
        var remoteAccessToken: String
        var devFeaturesEnabled: Bool
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
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
    }

    private struct PendingState {
        let value: String
        let expiresAt: Date
        let appRedirectURL: String?
    }

    private struct DiscordUser {
        let id: String
        let username: String
        let globalName: String?
        let discriminator: String?
        let avatar: String?
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
        remoteAccessToken: "",
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
    private var swiftMinerWebhookHandler: (@Sendable ([String: String], Data) async -> (status: String, body: Data))?
    private var discordUsersProvider: (@Sendable () async -> [String: String])?
    private var swiftMinerTestDMSender: (@Sendable (SwiftMinerDMRequest, String) async -> Bool)?
    private var swiftMinerPairedProvider: (@Sendable () async -> Bool)?
    private var logger: (@Sendable (String) async -> Void)?
    private var sessions: [String: Session] = [:]
    private var pendingStates: [String: PendingState] = [:]
    private let stateTTL: TimeInterval = 600
    private let sessionTTL: TimeInterval = 30 * 24 * 60 * 60
    private let sessionsDefaultsKey = "swiftbot.admin.web.sessions"
    private let maxHTTPRequestSize = 1_024 * 1_024

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
        swiftMinerWebhookHandler: @escaping @Sendable ([String: String], Data) async -> (status: String, body: Data),
        discordUsersProvider: @escaping @Sendable () async -> [String: String],
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
                await logger?("Admin Web UI TLS failed: \(error.localizedDescription). Falling back to HTTP.")
            }
        }

        await startPlainHTTPServer()
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
                        let tlsHandler = NIOSSLServerHandler(context: sslContext)
                        let httpHandler = AdminWebNIOHTTPHandler(
                            maxHTTPRequestSize: self.maxHTTPRequestSize,
                            processor: { requestData in
                                return await self.process(requestData)
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
        }

        do {
            let requestData = try await receiveHTTPRequest(from: connection)
            let response = await process(requestData)
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

    private func process(_ requestData: Data) async -> Data {
        guard let request = parseRequest(requestData) else {
            return httpResponse(status: "400 Bad Request", body: Data("Invalid request".utf8))
        }

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
            let usernamesById = await discordUsersProvider?() ?? [:]
            let users = usernamesById
                .map { ["discord_id": $0.key, "display_name": $0.value] }
                .sorted { ($0["display_name"] ?? "") < ($1["display_name"] ?? "") }
            return jsonResponse(["users": users])
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
            return jsonResponse([
                "id": session.userID,
                "username": session.username,
                "globalName": session.globalName ?? "",
                "discriminator": session.discriminator ?? "",
                "avatar": session.avatar ?? "",
                "csrfToken": session.csrfToken
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
            return jsonResponse(["ok": true])
        case ("POST", "/api/config"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
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
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebAutomationRulePatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await upsertAutomation?(patch.rule) == true else {
                return jsonResponse(["error": "upsert_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])

        case ("POST", "/api/automations/delete"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
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
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyTargetPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updatePatchyTarget?(patch.target) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/patchy/target/toggle"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
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
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(SweepPolicy.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateSweepPolicy?(patch) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/sweep/policy/delete"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
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
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebWikiSourcePatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateWikiSource?(patch.source) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/wikibridge/source/toggle"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
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
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            _ = await startBot?()
            await logger?("Admin Web UI requested bot start")
            return jsonResponse(["ok": true])
        case ("POST", "/api/bot/stop"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            _ = await stopBot?()
            await logger?("Admin Web UI requested bot stop")
            return jsonResponse(["ok": true])
        case ("POST", "/api/swiftmesh/refresh"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            _ = await refreshSwiftMesh?()
            await logger?("Admin Web UI requested SwiftMesh refresh")
            return jsonResponse(["ok": true])

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
            return httpResponse(status: "404 Not Found", body: Data("Not Found".utf8))
        }
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
                return httpResponse(status: "200 OK", body: data, contentType: "text/html; charset=utf-8")
            }
        }

        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let data = try? Data(contentsOf: url) {
            return httpResponse(status: "200 OK", body: data, contentType: "text/html; charset=utf-8")
        }

        let fallback = "<html><body><h1>SwiftBot Admin UI</h1><p>Missing bundled resource.</p></body></html>"
        return httpResponse(status: "200 OK", body: Data(fallback.utf8), contentType: "text/html; charset=utf-8")
    }

    private func serveAsset(named name: String, ext: String, subdirectories: [String] = []) -> Data {
        let baseDirectories = ["Resources", "admin", "Resources/admin"]
        let candidates: [(Bundle, String)] = (subdirectories + baseDirectories).map { (.main, $0) }

        for (bundle, subdirectory) in candidates {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory),
               let data = try? Data(contentsOf: url) {
                return httpResponse(status: "200 OK", body: data, contentType: "image/png")
            }
        }

        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let data = try? Data(contentsOf: url) {
            return httpResponse(status: "200 OK", body: data, contentType: "image/png")
        }

        return httpResponse(status: "404 Not Found", body: Data("Not Found".utf8))
    }

    private func handleDiscordLogin(request: HTTPRequest) async -> Data {
        let clientID = config.discordOAuth.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = config.discordOAuth.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            return httpResponse(status: "503 Service Unavailable", body: Data("Discord OAuth is not configured.".utf8))
        }

        let state = randomToken()
        let appRedirectURL = validatedAppRedirectURL(from: request.query["return_to"])
        pendingStates[state] = PendingState(
            value: state,
            expiresAt: Date().addingTimeInterval(stateTTL),
            appRedirectURL: appRedirectURL?.absoluteString
        )

        let uri = redirectURI()

        var components = URLComponents(string: "https://discord.com/oauth2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: uri),
            URLQueryItem(name: "scope", value: "identify guilds"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let url = components?.url else {
            return httpResponse(status: "500 Internal Server Error", body: Data("Failed to build OAuth URL.".utf8))
        }

        return redirectResponse(to: url.absoluteString)
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

        let expectedUsername = config.localAuthUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedPassword = config.localAuthPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !expectedUsername.isEmpty,
            !expectedPassword.isEmpty,
            username == expectedUsername,
            password == expectedPassword
        else {
            return jsonResponse(["error": "invalid_credentials"], status: "401 Unauthorized")
        }

        let session = makeSession(
            userID: "local:\(expectedUsername)",
            username: expectedUsername,
            globalName: "Local Admin",
            discriminator: nil,
            avatar: nil
        )
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
            let body = """
            <!doctype html><html><head><meta charset="utf-8"><title>Bot permissions updated</title>\
            <style>body{font-family:-apple-system,system-ui,sans-serif;max-width:560px;margin:10vh auto;padding:0 1.5rem;color:#222}\
            h1{font-size:1.4rem}p{line-height:1.5}</style></head><body>\
            <h1>Bot permissions updated</h1>\
            <p>SwiftBot's permissions have been refreshed for guild <code>\(guildID)</code>.</p>\
            <p>You can close this tab and return to the app.</p></body></html>
            """
            return httpResponse(
                status: "200 OK",
                body: Data(body.utf8),
                contentType: "text/html; charset=utf-8"
            )
        }
        guard let code = request.query["code"], let state = request.query["state"] else {
            return httpResponse(status: "400 Bad Request", body: Data("Missing code or state.".utf8))
        }
        guard let pendingState = pendingStates.removeValue(forKey: state) else {
            return httpResponse(status: "400 Bad Request", body: Data("State expired or invalid.".utf8))
        }

        do {
            let token = try await exchangeDiscordCode(code: code)
            let user = try await fetchDiscordUser(accessToken: token)
            let guilds = try await fetchDiscordGuilds(accessToken: token)
            guard await isAuthorized(userID: user.id, guilds: guilds) else {
                return httpResponse(status: "403 Forbidden", body: Data("This Discord account is not allowed.".utf8))
            }

            let session = Session(
                id: randomToken(),
                userID: user.id,
                username: user.username,
                globalName: user.globalName,
                discriminator: user.discriminator,
                avatar: user.avatar,
                csrfToken: randomToken(),
                expiresAt: Date().addingTimeInterval(sessionTTL)
            )
            sessions[session.id] = session
            persistSessions()
            await logger?("Admin Web UI login for \(user.username) (\(user.id))")
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
            return httpResponse(status: "502 Bad Gateway", body: Data("Discord OAuth failed: \(message)".utf8))
        }
    }

    private func handleLogout(request: HTTPRequest) -> Data {
        if let sessionID = cookie(named: "swiftbot_admin_session", request: request) {
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
            "permissions": ["admin"],
            "sessionToken": session.id,
            "expiresAt": ISO8601DateFormatter().string(from: session.expiresAt)
        ])
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

    /// Reads `?category=automation|moderation` from a request path, defaulting
    /// to `.automation` when absent or unrecognised.
    private func categoryParam(from request: HTTPRequest) -> Automations.Category {
        let raw = request.path
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst().first.map(String.init) ?? ""
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == "category" {
                if let kind = Automations.Category(rawValue: parts[1]) {
                    return kind
                }
            }
        }
        return .automation
    }

    private func authenticatedSession(for request: HTTPRequest) -> Session? {
        // First try cookie-based session (WebUI)
        if let sessionID = cookie(named: "swiftbot_admin_session", request: request),
           let session = sessions[sessionID],
           session.expiresAt > Date() {
            return session
        }

        // Then try Bearer token (Remote client)
        if let authorization = request.headers["authorization"],
           authorization.hasPrefix("Bearer ") {
            let sessionID = String(authorization.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
            if let session = sessions[sessionID],
               session.expiresAt > Date() {
                return session
            }
        }

        return nil
    }

    private func mediaAccessAuthorized(_ request: HTTPRequest) -> Bool {
        if authenticatedSession(for: request) != nil { return true }
        guard let access = request.query["access"], !access.isEmpty else { return false }
        let now = Date()
        return sessions.values.contains { $0.csrfToken == access && $0.expiresAt > now }
    }

    private func isRemoteRequestAuthorized(_ request: HTTPRequest) -> Bool {
        if authenticatedSession(for: request) != nil {
            return true
        }

        let expectedToken = config.remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedToken.isEmpty,
              let authorization = request.headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              authorization.hasPrefix("Bearer ") else {
            return false
        }

        let providedToken = String(authorization.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return !providedToken.isEmpty && providedToken == expectedToken
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
        request.headers["x-admin-csrf"] == session.csrfToken
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

    private func exchangeDiscordCode(code: String) async throws -> String {
        guard let url = URL(string: "https://discord.com/api/oauth2/token") else {
            throw OAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": config.discordOAuth.clientID,
            "client_secret": config.discordOAuth.clientSecret,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI()
        ]
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
            avatar: object["avatar"] as? String
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
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeSession(
        userID: String,
        username: String,
        globalName: String?,
        discriminator: String?,
        avatar: String?
    ) -> Session {
        Session(
            id: randomToken(),
            userID: userID,
            username: username,
            globalName: globalName,
            discriminator: discriminator,
            avatar: avatar,
            csrfToken: randomToken(),
            expiresAt: Date().addingTimeInterval(sessionTTL)
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
        guard let data = UserDefaults.standard.data(forKey: sessionsDefaultsKey),
              let decoded = try? decoder.decode([String: Session].self, from: data) else {
            sessions = [:]
            return
        }
        let now = Date()
        sessions = decoded.filter { $0.value.expiresAt > now }
    }

    private func persistSessions() {
        if sessions.isEmpty {
            UserDefaults.standard.removeObject(forKey: sessionsDefaultsKey)
            return
        }
        guard let data = try? encoder.encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: sessionsDefaultsKey)
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

        context.eventLoop.execute {
            var buffer = context.channel.allocator.buffer(capacity: response.count)
            buffer.writeBytes(response)
            context.writeAndFlush(self.wrapOutboundOut(buffer)).whenComplete { _ in
                if closeAfterWrite {
                    context.close(promise: nil)
                    return
                }
                self.hasWrittenResponse = false
                self.isProcessing = false
                self.processorTask = nil
                self.tryProcessNextRequest(context: context)
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
