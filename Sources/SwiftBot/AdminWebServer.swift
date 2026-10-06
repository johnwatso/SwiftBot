import Foundation
import WebAuthn
import Security
import RecordingsKit
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
// Authentication is the browser session cookie (swiftbot_admin_session),
// issued by Discord OAuth, a passkey, or the local fallback password.

struct AdminWebStatusPayload: Codable {
    let botStatus: String
    let botUsername: String
    let botAvatarURL: String?
    let connectedServerCount: Int
    let gatewayEventCount: Int
    let uptimeText: String?
    let webUIEnabled: Bool
    let webUIBaseURL: String
    /// Configured SwiftMesh role on this node ("Standalone" / "Leader" /
    /// "Standby" / "Worker"). Optional so existing Codable consumers keep
    /// working; populated by `adminWebStatusSnapshot()`.
    let clusterMode: String?
    /// Transient runtime state ("idle" / "promoting" / "demoting" /
    /// "isolated" / "recovering"). Optional for back-compat.
    let runtimeState: String?
    /// A standby or worker node is controlled by the active Primary and must
    /// not accept direct browser configuration edits.
    let isFailoverManagedNode: Bool
}

struct AdminWebLivePayload: Codable {
    let status: String
    let discordConnected: Bool
    let clusterMode: String?
    let runtimeState: String?
    let botUsername: String
    let generatedAt: Date
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

/// GET /api/swiftmesh: everything the native SwiftMesh view shows.
struct AdminWebSwiftMeshPayload: Codable {
    struct Status: Codable {
        let state: String
        let text: String
    }
    struct Follower: Codable {
        let mode: String
        let gatewayConnected: Bool
        let outputAllowed: Bool
        let lastEventAt: Date?
        let activeVoiceMembers: Int
        let discordLatencyMs: Int?
        let collectedAt: Date
    }
    struct Node: Codable {
        let id: String
        let displayName: String
        let hostname: String
        let role: String
        let status: String
        let hardwareModel: String
        let cpuName: String
        let memoryBytes: UInt64
        let uptimeSeconds: Double
        let jobsActive: Int
        let latencyMs: Double?
        let isThisNode: Bool
        let follower: Follower?
        var operatorID: String?
        /// The SF Symbol chosen for this node, nil when auto-detected.
        var iconOverride: String?
    }
    struct IconOption: Codable {
        let symbol: String
        let label: String
    }
    struct Handover: Codable {
        let isActive: Bool
        let scheduledAt: Date?
        let endsAt: Date?
        let lastRunAt: Date?
        let lastRunOK: Bool
        let canRun: Bool
    }

    let configuredMode: String
    let runtimeMode: String
    let runtimeState: String
    let nodeName: String
    let leaderAddress: String
    let leaderPort: Int
    let listenPort: Int
    let leaderTerm: Int
    let workerOffloadEnabled: Bool
    let offloadAIReplies: Bool
    let offloadWikiLookups: Bool
    var automaticHandbackEnabled: Bool = true
    let autoReclaimAfterHours: Int
    let autoReclaimRemainingSeconds: Double?
    let server: Status
    let worker: Status
    let diagnostics: String
    let lastJobRoute: String
    let lastJobNode: String
    let lastJobSummary: String
    let registeredWorkers: Int
    let localGatewayLatencyMs: Int?
    let handover: Handover
    let nodes: [Node]
    var iconOptions: [IconOption] = []
    /// Ruru, the ownership witness: display state only. Its endpoint path,
    /// cluster ID and bearer token stay in this Mac's Keychain.
    struct Witness: Codable {
        let host: String
        /// "checking", "ready", "recovering" or "unreachable".
        let health: String
        /// This Mac holds an unexpired lease.
        let leaseHeld: Bool
        /// Ruru's Preferred Primary: "checking", "current", "unsupported" or
        /// "unavailable". Intent only; `currentOwner` is who runs the bot.
        var preferenceStatus: String = "checking"
        /// Display name of the preferred node; nil when none is set.
        var preferredPrimary: String?
        var preferredIsThisMac = false
        var currentOwner: String = ""
    }
    var witness: Witness?
}

/// GET /api/member/replay: a member's own Replay for one of their servers.
struct AdminWebMemberReplayPayload: Codable {
    let rewindEnabled: Bool
    let guilds: [AdminWebSimpleOption]
    let guildID: String?
    /// Years and months with archived messages, newest first.
    let periods: [String]
    let periodKey: String?
    let replay: PersonalReplay?
}

/// GET /api/operators: who runs each Mac and which alerts are on.
struct AdminWebOperatorsPayload: Codable {
    struct Node: Codable {
        let name: String
        let operatorID: String?
        let isThisNode: Bool
    }
    struct Alert: Codable {
        let id: String
        let title: String
        let enabled: Bool
    }
    let thisNode: String
    let nodes: [Node]
    let alerts: [Alert]
    let members: [AdminWebMemberOption]
}

/// POST /api/operators: set a node's operator, or switch an alert.
struct AdminWebOperatorsPatch: Codable {
    var node: String?
    var userID: String?
    var alert: String?
    var enabled: Bool?
}

/// POST /api/swiftmesh/action.
struct AdminWebSwiftMeshAction: Codable {
    /// "handoverTest", "cancelHandoverTest", "promote", "forget" or "setIcon".
    let action: String
    /// The node's display name, for "forget" and "setIcon".
    var node: String?
    /// An SF Symbol from `iconOptions` for "setIcon"; nil returns to auto-detect.
    var icon: String?
}

/// One-off things the Web UI asks the host to do right now: run the bot,
/// send a test, refresh a cache, handle an update. The runner returns nil
/// when done, or the reason it couldn't be.
enum AdminWebHostOperation: Sendable {
    case startBot
    case stopBot
    case restartBot
    case announcerTest
    case announcerReconnect
    case welcomeTest
    case refreshWelcomeInvites
    case sweepTestMVP(SweepPolicy)
    case checkForUpdates
    case installUpdate
    case setAutomaticUpdateChecks(Bool)
    case setUnattendedUpdates(Bool)
    case clearCachedData
    case clearActivity
    /// Leave the server so it can be re-invited with fresh permissions.
    case forceRejoin(guildID: String)
}

/// POST /api/bot/permissions/force-rejoin.
struct AdminWebForceRejoinRequest: Codable {
    let guildID: String
}

/// POST /api/automations/simulate. Missing input fields are filled from the
/// rule itself, the same way the native editor pre-fills its simulator.
struct AdminWebAutomationSimulationRequest: Codable {
    struct Input: Codable {
        var username: String?
        var channelId: String?
        var messageContent: String?
        var voiceDurationSeconds: Int?
    }
    let rule: Automations.Rule
    var input: Input?
}

struct AdminWebAutomationSimulationPayload: Codable {
    let input: Automations.SimulationInput
    let result: Automations.SimulationResult
}

struct AdminWebBotPermissionsPayload: Codable {
    struct Flag: Codable {
        let name: String
        let detail: String
    }

    struct Guild: Codable {
        let id: String
        let name: String
        let isOwner: Bool
        let hasAdministrator: Bool
        let missingEssential: [Flag]
        let missingRecommended: [Flag]
        let missingOptional: [Flag]
        /// Text and announcement channels the bot can see; nil when Discord
        /// wouldn't list them.
        let visibleTextChannels: Int?
        let reinviteURL: String?
        let adminReinviteURL: String?
    }

    let botUsername: String?
    let error: String?
    let guilds: [Guild]
    let checkedAt: Date
}

struct AdminWebUpdatesPayload: Codable {
    let configured: Bool
    let version: String
    let build: String
    let channel: String
    let automaticChecks: Bool
    let unattended: Bool
    let isChecking: Bool
    let lastCheckedAt: Date?
    let availableVersion: String?
    let availableBuild: String?
    let releaseNotesURL: String?
    /// An unattended download is waiting; installing restarts SwiftBot.
    let readyToInstall: Bool
    let lastError: String?
}

struct AdminWebUpdatesSettingsPatch: Codable {
    var automaticChecks: Bool?
    var unattended: Bool?
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
    var joinedAt: Date? = nil
    /// Server avatar when set, else their Discord avatar (cdn.discordapp.com).
    var avatarURL: String? = nil
}

struct AdminWebDiscordUser: Codable, Sendable {
    let discordId: String
    let displayName: String
    let username: String?
    let avatarURL: String?
    /// Stated rather than implied: `/v1/users` already leaves bots out, and
    /// saying so lets SwiftMiner drop one on its own should a future caller of
    /// this payload ever include them.
    var isBot: Bool = false

    enum CodingKeys: String, CodingKey {
        case discordId = "discord_id"
        case displayName = "display_name"
        case username
        case avatarURL = "avatar_url"
        case isBot = "bot"
    }

    init(discordId: String, displayName: String, username: String?, avatarURL: String?, isBot: Bool = false) {
        self.discordId = discordId
        self.displayName = displayName
        self.username = username
        self.avatarURL = avatarURL
        self.isBot = isBot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        discordId = try container.decode(String.self, forKey: .discordId)
        displayName = try container.decode(String.self, forKey: .displayName)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        isBot = try container.decodeIfPresent(Bool.self, forKey: .isBot) ?? false
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
    /// Mirrors the native Overview's Operational Status / Attention Required /
    /// Live Activity panels (both are built from OverviewHealthReport).
    var health: AdminWebOverviewHealthPayload?
}

struct AdminWebOverviewHealthPayload: Codable {
    struct Tile: Codable {
        let id: String
        let title: String
        let value: String
        let detail: String
        let icon: String      // lucide icon name
        let state: String     // healthy | warning | critical | neutral
    }

    struct Attention: Codable {
        let id: String
        let title: String
        let detail: String
        let severity: String  // critical | warning | info
        let label: String
    }

    struct Activity: Codable {
        let id: String
        let timestamp: Date
        let title: String
        let detail: String
        let icon: String      // lucide icon name
        let tone: String
    }

    let state: String
    let title: String
    let tiles: [Tile]
    let attention: [Attention]
    let activity: [Activity]
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
    var recentReports: [SweepRunReport]
    var suggestions: [SweepSuggestion]
    let isScanningSuggestions: Bool
    let lastSuggestionScanAt: Date?
    let scanProgressDone: Int
    let scanProgressTotal: Int
    let servers: [AdminWebSimpleOption]
    let textChannelsByServer: [String: [AdminWebSimpleOption]]
    /// Voice channels have their own text chat, where join/leave
    /// announcements land, so Sweep can tidy those too.
    var voiceChannelsByServer: [String: [AdminWebSimpleOption]] = [:]
}

struct AdminWebGameTrackerPlayerPayload: Codable {
    let id: String
    let game: String
    let gameDisplayName: String
    let provider: String
    let providerDisplayName: String
    let playerID: String
    let displayName: String
    let destinationChannelID: String
    let destinationChannelName: String
    let isEnabled: Bool
    let supportsRankedScore: Bool
    let season: String?
    let rankName: String?
    let score: Int?
    let baselineRecordedAt: Date?
    /// "Rank hidden" / "Unranked this season" when the profile has no score.
    var rankUnavailable: String?
    /// Editable fields the WebUI player editor round-trips.
    var discordUserID: String = ""
}

/// What the WebUI needs to offer the same choices as the native player
/// editor: games, the providers for each, and the stats each provider reports.
struct AdminWebGameTrackerCatalog: Codable {
    struct Game: Codable {
        let id: String
        let displayName: String
        /// SF Symbol name; the web UI maps it to a Lucide icon.
        let symbolName: String
    }

    struct Metric: Codable {
        let id: String
        let displayName: String
        /// Counters only ever climb, so they can't trigger announcements.
        let canTrigger: Bool
    }

    struct Provider: Codable {
        let id: String
        let displayName: String
        let supportedGames: [String]
        let metrics: [Metric]
        let isConfigured: Bool
        /// "API Token" or "API Key". The credential itself never leaves the
        /// Mac; the WebUI only learns whether one is set, its last four
        /// characters and when it changed.
        var credentialLabel: String = "API Key"
        var hasCredential: Bool = false
        var credentialHint: String?
        var credentialUpdatedAt: Date?
        /// Why the connection isn't usable yet, if it isn't.
        var issue: String?
    }

    let games: [Game]
    let providers: [Provider]
}

struct AdminWebGameTrackerPayload: Codable {
    let enabled: Bool
    let dailyCheckEnabled: Bool
    let sessionTrackingEnabled: Bool
    let statusText: String
    let statusTone: String
    let configurationIssue: String?
    let checkInProgress: Bool
    let scheduleDescription: String
    let lastCheckAt: Date?
    let nextCheckAt: Date?
    let enabledPlayerCount: Int
    let totalPlayerCount: Int
    let players: [AdminWebGameTrackerPlayerPayload]
    let history: [GameTrackingHistoryEntry]
    let isPollingRuntime: Bool
    var checkHour: Int = 9
    var timeZoneIdentifier: String = ""
    var linkedPlayerCount: Int = 0
    var sessionMinimumMinutes: Int = 5
    var sessionGraceMinutes: Int = 3
    var isFailoverManagedNode: Bool = false
    var catalog: AdminWebGameTrackerCatalog?
    var channels: [AdminWebSimpleOption] = []
    /// Server members for the "Discord member" picker; `name` is the
    /// display name and `username` the @handle when it differs.
    var members: [AdminWebMemberOption] = []
    /// How announcements look, and sample Discord payloads rendered with it
    /// by the same code that posts them.
    var announcementStyle: GameAnnouncementStyle = GameAnnouncementStyle()
    var stylePreview: AdminWebGameTrackerStylePreview?
}

/// Discord message JSON (`content`, `embeds`) for the style editor preview.
struct AdminWebGameTrackerStylePreview: Codable {
    let rankUpdate: String
    let session: String
}

struct AdminWebMemberOption: Codable {
    let id: String
    let name: String
    let username: String?
}

/// Sets or removes a Game Tracker provider credential from the WebUI. The
/// response never carries the credential back.
struct AdminWebGameProviderCredentialUpdate: Codable {
    let provider: String
    /// The new credential; nil with `remove` to delete it.
    var token: String?
    var remove: Bool?
}

/// One WebUI edit to Game Tracker. Mirrors what the native view can change.
struct AdminWebGameTrackerUpdate: Codable, Validatable {
    enum Action: String, Codable {
        case upsertPlayer
        case deletePlayer
        case setPlayerEnabled
        case updateSettings
        case updateStyle
        /// Posts sample announcements to a player's channel.
        case sendTest
    }

    struct PlayerInput: Codable {
        /// Nil for a new player.
        let id: String?
        let game: String
        let provider: String
        let playerID: String
        let displayName: String
        let destinationChannelID: String
        let isEnabled: Bool
        let discordUserID: String
    }

    let action: Action
    var player: PlayerInput?
    var playerID: String?
    var enabled: Bool?
    var dailyCheckEnabled: Bool?
    var sessionTrackingEnabled: Bool?
    var checkHour: Int?
    var style: GameAnnouncementStyle?

    func validate() throws {
        switch action {
        case .upsertPlayer:
            guard let player else { throw ValidationError.invalidValue("Player is required") }
            guard let game = GameID(rawValue: player.game),
                  let provider = GameProviderID(rawValue: player.provider),
                  provider.supportedGames.contains(game) else {
                throw ValidationError.invalidValue("Unsupported game or provider")
            }
            if player.playerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.invalidValue("Player ID is required")
            }
            if player.destinationChannelID.isEmpty {
                throw ValidationError.invalidValue("Choose a channel for announcements")
            }
        case .deletePlayer, .setPlayerEnabled:
            guard let playerID, UUID(uuidString: playerID) != nil else {
                throw ValidationError.invalidValue("Player is required")
            }
        case .updateSettings:
            if let checkHour, !(0...23).contains(checkHour) {
                throw ValidationError.outOfRange("checkHour", min: 0, max: 23)
            }
        case .updateStyle:
            guard let style else { throw ValidationError.invalidValue("Style is required") }
            if style.accent == .custom, style.customColorValue == nil {
                throw ValidationError.invalidValue("Custom colour must be a hex value like #D21F3C")
            }
            if style.effectiveAnnounceOn.isEmpty {
                throw ValidationError.invalidValue("Pick at least one change to post on")
            }
            let limit = GameAnnouncementStyle.maxTemplateLength
            if [style.rankTitleTemplate, style.sessionTitleTemplate, style.footerText].contains(where: { $0.count > limit }) {
                throw ValidationError.invalidValue("Titles and footer must be \(limit) characters or fewer")
            }
        case .sendTest:
            if let playerID, UUID(uuidString: playerID) == nil {
                throw ValidationError.invalidValue("Unknown player")
            }
        }
    }
}

struct AdminWebSweepRunReportPayload: Codable {
    let report: SweepRunReport
}

struct AdminWebRewindTermPayload: Codable {
    let label: String
    let count: Int
}

struct AdminWebRewindGuildPayload: Codable {
    let id: String
    let name: String
    let years: [Int]
    let year: Int
    let totalMessages: Int
    let totalWords: Int
    let activeDays: Int
    let busiestDay: String?
    let peakHour: String?
    let topUsers: [AdminWebRewindTermPayload]
    let topWords: [AdminWebRewindTermPayload]
    let topPhrases: [AdminWebRewindTermPayload]
    let topEmoji: [AdminWebRewindTermPayload]
}

/// Replay requests from the Rewind page. One typed handler rather than a
/// closure per route.
enum AdminWebRewindRequest: Sendable {
    case replay(guildID: String, period: ReplayPeriod)
    case member(guildID: String, userID: String, period: ReplayPeriod)
    case phrase(guildID: String, phrase: String)
    case recaps
    case updateRecap(AdminWebRewindRecapUpdate)
    case postRecap(guildID: String, period: ReplayPeriod)
    case recipients(guildID: String, period: ReplayPeriod)
    case sendDMs(guildID: String, period: ReplayPeriod)
}

enum AdminWebRewindResult: Sendable {
    case replay(ServerReplay)
    case member(PersonalReplay)
    case phrase(AdminWebRewindPhrasePayload)
    case recaps(AdminWebRewindRecapsPayload)
    case recipients(Int)
    case ok
    case failure(String)
}

struct AdminWebRewindPhrasePayload: Codable, Sendable {
    let phrase: String
    let total: Int
    let messages: Int
    let scanned: Int
    let firstSeen: Date?
    let lastSeen: Date?
    let byUser: [ServerReplay.Ranked]
    let byMonth: [ServerReplay.Ranked]
    let topChannel: String?
}

struct AdminWebRewindRecapsPayload: Codable, Sendable {
    struct Guild: Codable, Sendable {
        let id: String
        let name: String
        let channelID: String
        let monthly: Bool
        let yearly: Bool
        let lastMonthlyKey: String?
        let lastYearlyKey: String?
        let channels: [AdminWebSimpleOption]
        var personalDMs: Bool = false
        var onlyDMActiveMembers: Bool = true
    }
    let guilds: [Guild]
    /// Members who turned Replay DMs off.
    var dmOptOutCount: Int = 0
    var lastCatchUpAt: Date?
    /// Whether the archive keeps text, which the nightly catch-up needs.
    var catchUpAvailable: Bool = false
    var dmProgress: ReplayDMProgress?
    /// The months that have archived messages, newest first ("2026-09").
    let months: [String]
}

struct AdminWebRewindRecapUpdate: Codable, Sendable {
    let guildID: String
    let channelID: String
    let monthly: Bool
    let yearly: Bool
    var personalDMs: Bool?
    var onlyDMActiveMembers: Bool?
}

/// Read-only mirror of the native Rewind screen. Collection settings stay
/// native-only on purpose: switching on a message archive is not something the
/// web surface should be able to do remotely.
struct AdminWebRewindPayload: Codable {
    let generatedAt: Date
    let isEnabled: Bool
    let retainsContent: Bool
    let retentionDays: Int
    let messageCount: Int
    let diskBytes: Int
    let earliestDay: String?
    let latestDay: String?
    let guilds: [AdminWebRewindGuildPayload]

    static let empty = AdminWebRewindPayload(
        generatedAt: Date(),
        isEnabled: false,
        retainsContent: false,
        retentionDays: 0,
        messageCount: 0,
        diskBytes: 0,
        earliestDay: nil,
        latestDay: nil,
        guilds: []
    )
}

struct AdminWebAnalyticsPayload: Codable, Sendable {
    let generatedAt: Date
    let peakActivityLabel: String
    let metrics: [AdminWebAnalyticsMetricPayload]
    let dailyActivity: [AdminWebAnalyticsDayPayload]
    let hourlyActivity: [AdminWebAnalyticsHourPayload]
    let topUsers: [AdminWebAnalyticsTopUserPayload]
    let feed: [AdminWebAnalyticsFeedEntryPayload]
    let health: AdminWebAnalyticsHealthPayload
    let insights: [AdminWebAnalyticsInsightPayload]
    /// Who's around and what they use, from the command and voice logs.
    var community: AdminWebAnalyticsCommunityPayload = .init()
    /// The selected time window (`?period=7d|30d|365d`).
    var period: AdminWebAnalyticsPeriodPayload?

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

struct AdminWebAnalyticsCommunityPayload: Codable {
    struct Ranked: Codable {
        let title: String
        let count: Int
    }
    struct InVoice: Codable {
        let username: String
        let channelName: String
        let since: Date
    }
    var inVoice: [InVoice] = []
    var topCommands: [Ranked] = []
    var topCommandUsers: [Ranked] = []
    var topChannels: [Ranked] = []
    var topVoiceChannels: [Ranked] = []
}

struct AdminWebAnalyticsPeriodPayload: Codable {
    typealias Ranked = AdminWebAnalyticsCommunityPayload.Ranked
    struct Bucket: Codable {
        let label: String
        let start: Date
        let voiceSessions: Int
        let voiceMinutes: Int
        let commands: Int
        let messages: Int
        let joins: Int
        let leaves: Int
    }
    struct Totals: Codable {
        let voiceSessions: Int
        let voiceSeconds: Int
        let averageSessionSeconds: Int
        let commands: Int
        let failedCommands: Int
        let messages: Int
        let joins: Int
        let leaves: Int
        let previousVoiceSessions: Int
        let previousVoiceSeconds: Int
        let previousMessages: Int
    }
    struct VoiceUser: Codable {
        let name: String
        let seconds: Int
        let sessions: Int
        let inVoiceNow: Bool
    }
    struct Streak: Codable {
        let name: String
        let days: Int
    }
    struct RankPoint: Codable {
        let date: Date
        let score: Int
        let rankName: String?
    }
    struct RankSeries: Codable {
        let name: String
        let game: String
        let points: [RankPoint]
    }

    let period: String
    let label: String
    let buckets: [Bucket]
    let hourlyVoice: [Int]
    let hourlyMessages: [Int]
    let totals: Totals
    let topVoiceUsers: [VoiceUser]
    let voiceChannels: [Ranked]
    let topCommands: [Ranked]
    let topCommandUsers: [Ranked]
    let topPosters: [Ranked]
    let messageChannels: [Ranked]
    /// Admin sessions only: these are fragments of members' messages.
    let topWords: [Ranked]?
    let topEmoji: [Ranked]?
    let streak: Streak?
    let rankSeries: [RankSeries]
    let clipsByGame: [Ranked]
    /// Rewind is on and has archived something.
    let messagesAvailable: Bool
    let rewindEnabled: Bool
    /// Completed feature work in this period; absent on older servers.
    var featureUses: [String: Int]? = nil
}

struct AdminWebConfigPayload: Codable {
    struct Commands: Codable {
        let enabled: Bool
        let prefixEnabled: Bool
        let slashEnabled: Bool
        let prefix: String
    }

    struct AppleIntelligence: Codable {
        let localAIDMReplyEnabled: Bool
        let useAIInGuildChannels: Bool
        let allowDMs: Bool
        let localAISystemPrompt: String
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
        let leaderPort: Int
        let listenPort: Int
        let workerOffloadEnabled: Bool
        let offloadAIReplies: Bool
        let offloadWikiLookups: Bool
        let autoReclaimAfterHours: Int
    }

    struct General: Codable {
        let autoStart: Bool
        let webUIEnabled: Bool
        let webUIBaseURL: String
        /// Bot install link; nil until the bot's application ID is known.
        var inviteURL: String?
        /// Read-only facts about the Mac running SwiftBot.
        var appVersion: String = ""
        var appBuild: String = ""
        var hostName: String = ""
        var osVersion: String = ""
        /// "Mac mini (M1, 2020) · 16 GB memory".
        var macModel: String = ""
    }

    struct UserTimezones: Codable {
        let mappings: [String: String]
        /// Server members, so the editor can show names instead of IDs.
        var members: [AdminWebMemberOption] = []
    }

    struct SwiftMiner: Codable {
        let enabled: Bool
        let paired: Bool
    }

    let commands: Commands
    let appleIntelligence: AppleIntelligence
    let wikiBridge: WikiBridge
    let patchy: Patchy
    let swiftMesh: SwiftMesh
    let general: General
    let userTimezones: UserTimezones
    let swiftMiner: SwiftMiner
}

struct AdminWebConfigPatch: Codable {
    var commandsEnabled: Bool?
    var prefixCommandsEnabled: Bool?
    var slashCommandsEnabled: Bool?
    var prefix: String?
    var localAIDMReplyEnabled: Bool?
    var useAIInGuildChannels: Bool?
    var allowDMs: Bool?
    var localAISystemPrompt: String?
    var aiActivityAnswersEnabled: Bool?
    var wikiBridgeEnabled: Bool?
    var patchyMonitoringEnabled: Bool?
    var clusterMode: String?
    var clusterNodeName: String?
    var clusterLeaderAddress: String?
    var clusterLeaderPort: Int?
    var clusterListenPort: Int?
    var clusterWorkerOffloadEnabled: Bool?
    var clusterOffloadAIReplies: Bool?
    var clusterOffloadWikiLookups: Bool?
    var clusterAutomaticHandbackEnabled: Bool?
    var clusterAutoReclaimAfterHours: Int?
    var autoStart: Bool?
    var musicLinkWatchEnabled: Bool?
    var musicLinkWatchChannelIDs: [String]?
    var userTimezones: [String: String]?
    var swiftMinerEnabled: Bool?
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

struct AdminWebMusicLinkWatchPayload: Codable {
    let isEnabled: Bool
    let channelIDs: [String]
    let servers: [AdminWebSimpleOption]
    let textChannelsByServer: [String: [AdminWebSimpleOption]]
}

struct AdminWebCommandCatalogPayload: Codable {
    let commandsEnabled: Bool
    let prefixCommandsEnabled: Bool
    let slashCommandsEnabled: Bool
    let items: [AdminWebCommandCatalogItem]
    let musicLinkWatch: AdminWebMusicLinkWatchPayload
}

/// The unified activity feed, as the native Activity view shows it.
struct AdminWebActivityPayload: Codable {
    struct Entry: Codable {
        let id: String
        let time: Date
        /// command / system / mesh / audit
        let kind: String
        /// info / ok / warning / error
        let level: String
        /// ActivityCategory raw value, for the row icon and the Gateway chip.
        let category: String
        let title: String
        let detail: String?
    }
    let entries: [Entry]
    let totalCount: Int
}

/// Who may sign in to the WebUI with Discord.
struct AdminWebAccessPayload: Codable {
    let restrictToListedUsers: Bool
    let allowedUserIDs: [String]
    let members: [AdminWebMemberOption]
    /// Password fallback is configured in the macOS app; shown so admins know
    /// there's a way back in.
    let localFallbackEnabled: Bool
    /// Server members can sign in to their own Replay and clips.
    var memberAccessEnabled = false
}

/// POST /api/access/members.
struct AdminWebMemberAccessUpdate: Codable {
    let enabled: Bool
}

struct AdminWebAccessUpdate: Codable {
    let restrictToListedUsers: Bool
    let allowedUserIDs: [String]

    enum GuardFailure: String, Error {
        case emptyList = "empty_list"
        case selfLockout = "self_lockout"
        case invalidID = "invalid_id"
    }

    var normalizedIDs: [String] {
        var seen = Set<String>()
        return allowedUserIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The lock-out guards. `editorUserID` is the signed-in admin; local
    /// fallback sessions (`local:`) aren't subject to the list.
    func validate(editorUserID: String) throws {
        let ids = normalizedIDs
        guard ids.allSatisfy({ $0.count >= 15 && $0.count <= 22 && $0.allSatisfy(\.isNumber) }) else { throw GuardFailure.invalidID }
        guard restrictToListedUsers else { return }
        guard !ids.isEmpty else { throw GuardFailure.emptyList }
        if !editorUserID.hasPrefix("local:"), !ids.contains(editorUserID) { throw GuardFailure.selfLockout }
    }
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

// MARK: - AI Bots payloads

/// Returned by GET /api/aibots. Mirrors the native Apple Intelligence
/// surface so the WebUI can render the same status, personality presets,
/// reply rules, conversation memory and capability tiles.
struct AdminWebAIBotsPayload: Codable {
    struct Personality: Codable {
        let id: String
        let title: String
        let summary: String
        let description: String
        let preview: String
        let prompt: String
        let icon: String                              // lucide icon name
        let tint: String                              // getTintHex() key
        let isSelected: Bool
    }

    struct Capability: Codable {
        let id: String
        let title: String
        let description: String
        let icon: String
        let tint: String
        let status: String                            // "active" | "ready" | "off"
    }

    struct Conversation: Codable {
        let id: String
        let scopeID: String
        let scopeType: String                         // MemoryScopeType raw value
        let title: String
        let messageCount: Int
    }

    struct Memory: Codable {
        let totalMessages: Int
        let conversations: [Conversation]
    }

    let online: Bool
    /// "Private Cloud Compute" or "On-device · …"; nil when offline.
    var modelName: String?
    let replyScope: String
    let dmRepliesEnabled: Bool
    let guildMentionRepliesEnabled: Bool
    let allowDMs: Bool
    let systemPrompt: String
    let selectedPersonalityID: String
    /// The saved instructions aren't one of the presets.
    var isCustomPrompt = false
    /// SwiftBot's built-in instructions, for "Reset to default".
    var defaultPrompt = ""
    /// Replies can answer "when is sam usually on?" from activity records.
    var activityAnswersEnabled = false
    let isFailoverManagedNode: Bool
    let personalities: [Personality]
    let capabilities: [Capability]
    let memory: Memory
}

/// Clears one conversation's memory, or every conversation when both
/// fields are omitted.
/// POST /api/aibots/try: one reply using `prompt` as the instructions,
/// without saving them.
struct AdminWebAITryRequest: Codable {
    let message: String
    let prompt: String
    /// The signed-in admin's Discord ID, so "how much have I been in
    /// voice?" is about them. Set by the server, never by the page.
    var askerID: String?
}

struct AdminWebAIMemoryClearPatch: Codable {
    let scopeID: String?
    let scopeType: String?
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
    /// The server's invites as last read from Discord, for the invite-role picker.
    var invites: [AdminWebWelcomeInvite] = []
}

struct AdminWebWelcomeInvite: Codable {
    let code: String
    let channelName: String?
    let uses: Int
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
}

struct AdminWebPatchyStatePatch: Codable {
    let monitoringEnabled: Bool?
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
    var answersQuestions: Bool = true
    let sources: [WikiSource]
    /// Keyed by source ID; sources nobody has used yet are missing.
    var usage: [String: WikiLookupUsageSummary] = [:]
}

struct AdminWebWikiBridgeStatePatch: Codable {
    let enabled: Bool?
    var answersQuestions: Bool?
}

struct AdminWebWikiDetectRequest: Codable {
    let baseURL: String
    var apiPath: String?
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

/// Runs one lookup against an unsaved source draft, like the native
/// editor's Preview section, so the web editor can show the reply embed.
struct AdminWebWikiPreviewRequest: Codable {
    let source: WikiSource
    let query: String
}

/// Read-only mirror of the native Announcer tab's "Current State" panel.
///
/// `guildID` / `voiceChannelID` / `watchedTextChannelID` on the parent payload
/// are live session state that `activateAnnouncerConfig` rewrites on every
/// connect, so the web surfaces them here as status rather than as settings.
struct AdminWebAnnouncerLiveState: Codable {
    let isConnected: Bool
    let connectionLabel: String
    let phaseLabel: String
    let listening: String
    let monitoredFeeds: String
    let queueDepth: Int
    let queueLabel: String
    let manualHold: String?
    let recovery: String?
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
    /// Voices installed on this Mac (id = AVSpeechSynthesisVoice identifier),
    /// offered as a dropdown in the per-rule editor.
    let installedVoices: [AdminWebSimpleOption]
    let liveState: AdminWebAnnouncerLiveState
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
    /// "Recorded by": the member whose voice channel decides who's in its clips.
    var ownerID: String?
}

/// POST /api/media/game-match: Fix Match for a clip's game.
struct AdminWebMediaGameMatchPatch: Codable {
    /// One clip, by its library id; or, with `fromGame`, a whole game.
    var itemID: String?
    /// Every clip filed under this game, now and later.
    var fromGame: String?
    /// Empty returns the clip to the game its filename names.
    let gameName: String
    var steamAppID: String?
    /// Also every clip detected as the same game, now and later.
    var applyToDetected: Bool?
}

/// GET /api/media/game-search: titles to pick from in Fix Match.
struct AdminWebGameSearchResult: Codable {
    let name: String
    let steamAppID: String
}

/// POST /api/media/source-owner.
struct AdminWebMediaSourceOwnerPatch: Codable {
    let sourceID: String
    let userID: String
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
    /// Who was in voice with the recorder while it was recorded.
    var people: [AdminWebSimpleOption] = []
    /// The folder's "Recorded by" member, when one is set.
    var recordedByID: String?
    /// The game its filename names, before any Fix Match.
    var detectedGameName: String?
    /// An admin's Fix Match: "clip" for this clip alone, "detected" for
    /// every clip detected as its game; nil when the filename's game is used.
    var gameMatch: String?
}

struct AdminWebMediaLibraryPayload: Codable {
    let generatedAt: Date
    let sources: [AdminWebMediaSourcePayload]
    let items: [AdminWebMediaItemPayload]
    let games: [String]
    /// One entry per game for the poster view, honouring the source and
    /// date filters but not the game filter.
    var gameSummaries: [AdminWebMediaGameSummary] = []
    let selectedSourceID: String?
    let selectedDateRange: String
    let selectedGame: String?
    let page: Int
    let pageSize: Int
    let totalItems: Int
    let totalPages: Int
}

struct AdminWebMediaGameSummary: Codable {
    let name: String
    let clipCount: Int
    let latestAt: Date?
    let totalBytes: Int64
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

struct AdminWebSweepPolicyCreatePatch: Codable {
    let name: String
    let guildID: String
    let channelID: String
    let strategyKind: String
    let ageHours: Int
    let keepCount: Int
    let fromBotsOnly: Bool
    let scheduleMinutes: Int
    let maxMessagesPerRun: Int
    let minMessageAgeMinutes: Int
    let protectPinned: Bool
    let protectReacted: Bool
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
        /// Server members who aren't admins can sign in to a member-only view.
        var memberAccessEnabled: Bool = false
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
        /// A server member: their own Replay and clips, nothing else. Kept
        /// to the member routes by the gate at the top of `process`.
        case member
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
        // sent, in which case binding is not enforced.
        var userAgentHash: String? = nil
        var role: Role = .admin
        /// Members: the connected servers they belonged to at sign-in, which
        /// scopes what they can see.
        var guildIDs: [String]? = nil
        var signInMethod: String? = nil
        // Secrets remain in the Keychain-backed session store. Never exposed to clients.
        var discordRefreshToken: String? = nil
    }

    private struct PendingState {
        let value: String
        let expiresAt: Date
        let codeVerifier: String?
        /// When set, this OAuth flow authenticates a companion app's user
        /// (e.g. SwiftMiner's web dashboard): on success we redirect here with
        /// a short-lived signed identity assertion instead of creating an
        /// admin session.
        var companionReturnURL: String? = nil
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
    private var oauthURLSession = URLSession.shared
    private var persistAuthenticationState = true
    private var passkeyState = PasskeyState()
    private var passkeyChallenges: [String: PasskeyChallenge] = [:]
    private var passkeyUsersInFlight: Set<String> = []
    private var passkeyRequestBuckets: [String: [Date]] = [:]
    /// Analytics takes seconds to build (Rewind and media scans), so recent
    /// results are reused and concurrent requests share one build instead of
    /// piling up and starving /api/overview.
    private struct AnalyticsCacheKey: Hashable {
        let period: AnalyticsPeriod
        let includeMessageText: Bool
    }
    private static let analyticsCacheLifetime: TimeInterval = 30
    private var analyticsCache: [AnalyticsCacheKey: (payload: AdminWebAnalyticsPayload, builtAt: Date)] = [:]
    private var analyticsInFlight: [AnalyticsCacheKey: Task<AdminWebAnalyticsPayload, Never>] = [:]
    private var listener: NWListener?
    private var nioChannel: Channel?
    private var nioGroup: MultiThreadedEventLoopGroup?
    private var activePublicBaseURL = ""
    private var activeTransportUsesTLS = false
    private var statusProvider: (@Sendable () async -> AdminWebStatusPayload)?
    private var overviewProvider: (@Sendable () async -> AdminWebOverviewPayload)?
    private var analyticsProvider: (@Sendable (AnalyticsPeriod, Bool) async -> AdminWebAnalyticsPayload)?
    private var rewindProvider: (@Sendable () async -> AdminWebRewindPayload)?
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
    private var disconnectAnnouncer: (@Sendable () async -> Bool)?
    private var patchyProvider: (@Sendable () async -> AdminWebPatchyPayload)?
    private var updatePatchyState: (@Sendable (AdminWebPatchyStatePatch) async -> Bool)?
    private var createPatchyTarget: (@Sendable () async -> PatchySourceTarget?)?
    private var updatePatchyTarget: (@Sendable (PatchySourceTarget) async -> Bool)?
    private var setPatchyTargetEnabled: (@Sendable (UUID, Bool) async -> Bool)?
    private var deletePatchyTarget: (@Sendable (UUID) async -> Bool)?
    private var sendPatchyTestTarget: (@Sendable (UUID) async -> PatchyTestOutcome)?
    private var pullPatchyTarget: (@Sendable (UUID) async -> Bool)?
    private var runPatchyCheckNow: (@Sendable () async -> Bool)?
    private var aiBotsProvider: (@Sendable () async -> AdminWebAIBotsPayload)?
    private var clearAIMemory: (@Sendable (AdminWebAIMemoryClearPatch) async -> Bool)?
    private var tryAIReply: (@Sendable (AdminWebAITryRequest) async -> String?)?
    private var wikiBridgeProvider: (@Sendable () async -> AdminWebWikiBridgePayload)?
    private var updateWikiBridgeState: (@Sendable (AdminWebWikiBridgeStatePatch) async -> Bool)?
    private var createWikiSource: (@Sendable () async -> WikiSource?)?
    private var updateWikiSource: (@Sendable (WikiSource) async -> Bool)?
    private var setWikiSourceEnabled: (@Sendable (UUID, Bool) async -> Bool)?
    private var setWikiSourcePrimary: (@Sendable (UUID) async -> Bool)?
    private var testWikiSource: (@Sendable (UUID) async -> Bool)?
    /// Returns the preview JSON ({ embed, fields }), or nil when nothing matched.
    private var previewWikiSource: (@Sendable (AdminWebWikiPreviewRequest) async -> Data?)?
    private var detectWikiSite: (@Sendable (AdminWebWikiDetectRequest) async -> WikiSiteInfo?)?
    private var deleteWikiSource: (@Sendable (UUID) async -> Bool)?
    private var mediaLibraryProvider: (@Sendable ([String: String]) async -> AdminWebMediaLibraryPayload)?
    private var mediaStreamProvider: (@Sendable (String, String?, String?) async -> BinaryHTTPResponse?)?
    private var mediaHLSPlaylistProvider: (@Sendable (String, String?) async -> BinaryHTTPResponse?)?
    private var mediaHLSSegmentProvider: (@Sendable (String, String, String?) async -> BinaryHTTPResponse?)?
    private var mediaThumbnailProvider: (@Sendable (String) async -> BinaryHTTPResponse?)?
    private var mediaFrameProvider: (@Sendable (String, Double) async -> BinaryHTTPResponse?)?
    private var mediaExportStatusProvider: (@Sendable () async -> MediaExportStatus)?
    private var mediaExportJobsProvider: (@Sendable () async -> MediaExportJobsPayload)?
    private var mediaPlaybackRecorder: (@Sendable (AdminWebMediaPlaybackPatch) async -> Bool)?
    private var mediaClipExportStarter: (@Sendable (MediaExportClipRequest) async -> MediaExportJobResponse)?
    private var mediaMultiViewExportStarter: (@Sendable (MediaExportMultiViewRequest) async -> MediaExportJobResponse)?
    private var sweepProvider: (@Sendable () async -> AdminWebSweepPayload)?
    private var gameTrackerProvider: (@Sendable () async -> AdminWebGameTrackerPayload)?
    private var gameTrackerCheckRunner: (@Sendable () async -> Bool)?
    private var gameTrackerUpdater: (@Sendable (AdminWebGameTrackerUpdate) async -> Bool)?
    private var gameTrackerStylePreviewer: (@Sendable (GameAnnouncementStyle) async -> AdminWebGameTrackerStylePreview)?
    /// Saves (token) or removes (nil) a provider credential; returns a
    /// `GameProviderCredentialResult` raw value.
    private var gameProviderCredentialUpdater: (@Sendable (String, String?) async -> String)?
    private var hostOperationRunner: (@Sendable (AdminWebHostOperation) async -> String?)?
    private var automationSimulator: (@Sendable (AdminWebAutomationSimulationRequest) async -> AdminWebAutomationSimulationPayload?)?
    /// The same redacted diagnostic report as the native Activity › Export.
    private var activityReportProvider: (@Sendable () async -> String)?
    private var botPermissionsProvider: (@Sendable () async -> AdminWebBotPermissionsPayload)?
    private var updatesProvider: (@Sendable () async -> AdminWebUpdatesPayload?)?
    /// Credential changes need a sign-in this recent, since sessions last a day.
    private let credentialReauthWindow: TimeInterval = 15 * 60
    private var mediaGameArtworkProvider: (@Sendable (String) async -> BinaryHTTPResponse?)?
    private var accessProvider: (@Sendable () async -> AdminWebAccessPayload)?
    private var activityProvider: (@Sendable (Int) async -> AdminWebActivityPayload)?
    private var rewindHandler: (@Sendable (AdminWebRewindRequest) async -> AdminWebRewindResult)?
    private var accessUpdater: (@Sendable (AdminWebAccessUpdate) async -> Bool)?
    private var memberAccessUpdater: (@Sendable (Bool) async -> Bool)?
    private var setSweepGlobalPaused: (@Sendable (Bool) async -> Bool)?
    private var updateSweepPolicy: (@Sendable (SweepPolicy) async -> Bool)?
    private var createSweepPolicy: (@Sendable (AdminWebSweepPolicyCreatePatch) async -> SweepPolicy?)?
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
    private var swiftMeshProvider: (@Sendable () async -> AdminWebSwiftMeshPayload?)?
    /// (userID, servers a member may see or nil for an admin, guild, period).
    private var memberReplayProvider: (@Sendable (String, [String]?, String?, String?) async -> AdminWebMemberReplayPayload?)?
    /// The Discord message JSON SwiftBot would post for a shared music link.
    private var musicPreviewProvider: (@Sendable (String) async -> Data?)?
    private var musicPreviewCache: [String: (body: Data, builtAt: Date)] = [:]
    private var memberClipsProvider: (@Sendable (String, [String: String]) async -> AdminWebMediaLibraryPayload?)?
    private var memberMayPlay: (@Sendable (String, String) async -> Bool)?
    private var mediaPlaybackChoiceProvider: (@Sendable (String) async -> (quality: String, preparing: Bool)?)?
    private var operatorsProvider: (@Sendable () async -> AdminWebOperatorsPayload?)?
    private var updateOperators: (@Sendable (AdminWebOperatorsPatch) async -> Bool)?
    private var sendOperatorTest: (@Sendable () async -> String?)?
    private var setMediaSourceOwner: (@Sendable (String, String) async -> Bool)?
    private var fixMediaGameMatch: (@Sendable (AdminWebMediaGameMatchPatch) async -> Bool)?
    private var runSwiftMeshAction: (@Sendable (AdminWebSwiftMeshAction) async -> String?)?
    private var swiftMeshJoinCodeProvider: (@Sendable () async -> String?)?
    private var swiftMinerWebhookHandler: (@Sendable ([String: String], Data) async -> (status: String, body: Data))?
    /// Registers a companion-app hostname (e.g. SwiftMiner's dashboard) on the
    /// Cloudflare tunnel. HMAC-authenticated inside the handler; fail-closed.
    private var swiftMinerTunnelHostnameHandler: (@Sendable ([String: String], Data) async -> (status: String, body: Data))?
    /// Read-only tunnel info (domain, readiness) for companion apps. No auth:
    /// it reveals only the public domain, which the tunnel URL itself exposes.
    private var swiftMinerTunnelInfoProvider: (@Sendable () async -> (status: String, body: Data))?
    /// Companion SSO config: the hostnames registered on the tunnel (allowed
    /// `return_to` targets) and the shared pairing secret used to sign identity
    /// assertions. Empty secret disables the flow (fail-closed).
    private var companionSSOConfigProvider: (@Sendable () async -> (hostnames: [String], secret: String))?
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
        overviewProvider: @escaping @Sendable () async -> AdminWebOverviewPayload,
        analyticsProvider: @escaping @Sendable (AnalyticsPeriod, Bool) async -> AdminWebAnalyticsPayload,
        rewindProvider: @escaping @Sendable () async -> AdminWebRewindPayload,
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
        disconnectAnnouncer: @escaping @Sendable () async -> Bool,
        patchyProvider: @escaping @Sendable () async -> AdminWebPatchyPayload,
        updatePatchyState: @escaping @Sendable (AdminWebPatchyStatePatch) async -> Bool,
        createPatchyTarget: @escaping @Sendable () async -> PatchySourceTarget?,
        updatePatchyTarget: @escaping @Sendable (PatchySourceTarget) async -> Bool,
        setPatchyTargetEnabled: @escaping @Sendable (UUID, Bool) async -> Bool,
        deletePatchyTarget: @escaping @Sendable (UUID) async -> Bool,
        sendPatchyTestTarget: @escaping @Sendable (UUID) async -> PatchyTestOutcome,
        pullPatchyTarget: @escaping @Sendable (UUID) async -> Bool,
        runPatchyCheckNow: @escaping @Sendable () async -> Bool,
        aiBotsProvider: (@Sendable () async -> AdminWebAIBotsPayload)? = nil,
        clearAIMemory: (@Sendable (AdminWebAIMemoryClearPatch) async -> Bool)? = nil,
        tryAIReply: (@Sendable (AdminWebAITryRequest) async -> String?)? = nil,
        wikiBridgeProvider: @escaping @Sendable () async -> AdminWebWikiBridgePayload,
        updateWikiBridgeState: @escaping @Sendable (AdminWebWikiBridgeStatePatch) async -> Bool,
        createWikiSource: @escaping @Sendable () async -> WikiSource?,
        updateWikiSource: @escaping @Sendable (WikiSource) async -> Bool,
        setWikiSourceEnabled: @escaping @Sendable (UUID, Bool) async -> Bool,
        setWikiSourcePrimary: @escaping @Sendable (UUID) async -> Bool,
        testWikiSource: @escaping @Sendable (UUID) async -> Bool,
        previewWikiSource: (@Sendable (AdminWebWikiPreviewRequest) async -> Data?)? = nil,
        detectWikiSite: (@Sendable (AdminWebWikiDetectRequest) async -> WikiSiteInfo?)? = nil,
        deleteWikiSource: @escaping @Sendable (UUID) async -> Bool,
        mediaLibraryProvider: @escaping @Sendable ([String: String]) async -> AdminWebMediaLibraryPayload,
        mediaStreamProvider: @escaping @Sendable (String, String?, String?) async -> BinaryHTTPResponse?,
        mediaHLSPlaylistProvider: @escaping @Sendable (String, String?) async -> BinaryHTTPResponse?,
        mediaHLSSegmentProvider: @escaping @Sendable (String, String, String?) async -> BinaryHTTPResponse?,
        mediaThumbnailProvider: @escaping @Sendable (String) async -> BinaryHTTPResponse?,
        mediaFrameProvider: @escaping @Sendable (String, Double) async -> BinaryHTTPResponse?,
        mediaExportStatusProvider: @escaping @Sendable () async -> MediaExportStatus,
        mediaExportJobsProvider: @escaping @Sendable () async -> MediaExportJobsPayload,
        mediaPlaybackRecorder: @escaping @Sendable (AdminWebMediaPlaybackPatch) async -> Bool,
        mediaClipExportStarter: @escaping @Sendable (MediaExportClipRequest) async -> MediaExportJobResponse,
        mediaMultiViewExportStarter: @escaping @Sendable (MediaExportMultiViewRequest) async -> MediaExportJobResponse,
        gameTrackerProvider: @escaping @Sendable () async -> AdminWebGameTrackerPayload,
        gameTrackerCheckRunner: @escaping @Sendable () async -> Bool,
        gameTrackerUpdater: @escaping @Sendable (AdminWebGameTrackerUpdate) async -> Bool,
        gameTrackerStylePreviewer: (@Sendable (GameAnnouncementStyle) async -> AdminWebGameTrackerStylePreview)? = nil,
        mediaGameArtworkProvider: @escaping @Sendable (String) async -> BinaryHTTPResponse?,
        accessProvider: @escaping @Sendable () async -> AdminWebAccessPayload,
        activityProvider: @escaping @Sendable (Int) async -> AdminWebActivityPayload,
        rewindHandler: @escaping @Sendable (AdminWebRewindRequest) async -> AdminWebRewindResult,
        accessUpdater: @escaping @Sendable (AdminWebAccessUpdate) async -> Bool,
        memberAccessUpdater: (@Sendable (Bool) async -> Bool)? = nil,
        sweepProvider: @escaping @Sendable () async -> AdminWebSweepPayload,
        setSweepGlobalPaused: @escaping @Sendable (Bool) async -> Bool,
        updateSweepPolicy: @escaping @Sendable (SweepPolicy) async -> Bool,
        createSweepPolicy: @escaping @Sendable (AdminWebSweepPolicyCreatePatch) async -> SweepPolicy?,
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
        swiftMeshProvider: (@Sendable () async -> AdminWebSwiftMeshPayload?)? = nil,
        memberReplayProvider: (@Sendable (String, [String]?, String?, String?) async -> AdminWebMemberReplayPayload?)? = nil,
        musicPreviewProvider: (@Sendable (String) async -> Data?)? = nil,
        memberClipsProvider: (@Sendable (String, [String: String]) async -> AdminWebMediaLibraryPayload?)? = nil,
        memberMayPlay: (@Sendable (String, String) async -> Bool)? = nil,
        mediaPlaybackChoiceProvider: (@Sendable (String) async -> (quality: String, preparing: Bool)?)? = nil,
        operatorsProvider: (@Sendable () async -> AdminWebOperatorsPayload?)? = nil,
        updateOperators: (@Sendable (AdminWebOperatorsPatch) async -> Bool)? = nil,
        sendOperatorTest: (@Sendable () async -> String?)? = nil,
        setMediaSourceOwner: (@Sendable (String, String) async -> Bool)? = nil,
        fixMediaGameMatch: (@Sendable (AdminWebMediaGameMatchPatch) async -> Bool)? = nil,
        runSwiftMeshAction: (@Sendable (AdminWebSwiftMeshAction) async -> String?)? = nil,
        swiftMeshJoinCodeProvider: (@Sendable () async -> String?)? = nil,
        swiftMinerWebhookHandler: @escaping @Sendable ([String: String], Data) async -> (status: String, body: Data),
        swiftMinerTunnelHostnameHandler: (@Sendable ([String: String], Data) async -> (status: String, body: Data))? = nil,
        swiftMinerTunnelInfoProvider: (@Sendable () async -> (status: String, body: Data))? = nil,
        companionSSOConfigProvider: (@Sendable () async -> (hostnames: [String], secret: String))? = nil,
        discordUsersProvider: @escaping @Sendable () async -> [AdminWebDiscordUser],
        swiftMinerTestDMSender: @escaping @Sendable (SwiftMinerDMRequest, String) async -> Bool,
        swiftMinerPairedProvider: @escaping @Sendable () async -> Bool,
        log: @escaping @Sendable (String) async -> Void
    ) async -> RuntimeState {
        self.statusProvider = statusProvider
        self.overviewProvider = overviewProvider
        self.analyticsProvider = analyticsProvider
        self.rewindProvider = rewindProvider
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
        self.disconnectAnnouncer = disconnectAnnouncer
        self.patchyProvider = patchyProvider
        self.updatePatchyState = updatePatchyState
        self.createPatchyTarget = createPatchyTarget
        self.updatePatchyTarget = updatePatchyTarget
        self.setPatchyTargetEnabled = setPatchyTargetEnabled
        self.deletePatchyTarget = deletePatchyTarget
        self.sendPatchyTestTarget = sendPatchyTestTarget
        self.pullPatchyTarget = pullPatchyTarget
        self.runPatchyCheckNow = runPatchyCheckNow
        self.aiBotsProvider = aiBotsProvider
        self.clearAIMemory = clearAIMemory
        self.tryAIReply = tryAIReply
        self.wikiBridgeProvider = wikiBridgeProvider
        self.updateWikiBridgeState = updateWikiBridgeState
        self.createWikiSource = createWikiSource
        self.updateWikiSource = updateWikiSource
        self.setWikiSourceEnabled = setWikiSourceEnabled
        self.setWikiSourcePrimary = setWikiSourcePrimary
        self.testWikiSource = testWikiSource
        self.previewWikiSource = previewWikiSource
        self.detectWikiSite = detectWikiSite
        self.deleteWikiSource = deleteWikiSource
        self.mediaLibraryProvider = mediaLibraryProvider
        self.mediaStreamProvider = mediaStreamProvider
        self.mediaHLSPlaylistProvider = mediaHLSPlaylistProvider
        self.mediaHLSSegmentProvider = mediaHLSSegmentProvider
        self.mediaThumbnailProvider = mediaThumbnailProvider
        self.mediaFrameProvider = mediaFrameProvider
        self.mediaExportStatusProvider = mediaExportStatusProvider
        self.mediaExportJobsProvider = mediaExportJobsProvider
        self.mediaPlaybackRecorder = mediaPlaybackRecorder
        self.mediaClipExportStarter = mediaClipExportStarter
        self.mediaMultiViewExportStarter = mediaMultiViewExportStarter
        self.sweepProvider = sweepProvider
        self.gameTrackerProvider = gameTrackerProvider
        self.gameTrackerCheckRunner = gameTrackerCheckRunner
        self.gameTrackerUpdater = gameTrackerUpdater
        self.gameTrackerStylePreviewer = gameTrackerStylePreviewer
        self.mediaGameArtworkProvider = mediaGameArtworkProvider
        self.accessProvider = accessProvider
        self.activityProvider = activityProvider
        self.rewindHandler = rewindHandler
        self.accessUpdater = accessUpdater
        self.memberAccessUpdater = memberAccessUpdater
        self.setSweepGlobalPaused = setSweepGlobalPaused
        self.updateSweepPolicy = updateSweepPolicy
        self.createSweepPolicy = createSweepPolicy
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
        self.swiftMeshProvider = swiftMeshProvider
        self.memberReplayProvider = memberReplayProvider
        self.musicPreviewProvider = musicPreviewProvider
        self.memberClipsProvider = memberClipsProvider
        self.memberMayPlay = memberMayPlay
        self.mediaPlaybackChoiceProvider = mediaPlaybackChoiceProvider
        self.operatorsProvider = operatorsProvider
        self.updateOperators = updateOperators
        self.sendOperatorTest = sendOperatorTest
        self.setMediaSourceOwner = setMediaSourceOwner
        self.fixMediaGameMatch = fixMediaGameMatch
        self.runSwiftMeshAction = runSwiftMeshAction
        self.swiftMeshJoinCodeProvider = swiftMeshJoinCodeProvider
        self.swiftMinerWebhookHandler = swiftMinerWebhookHandler
        self.swiftMinerTunnelHostnameHandler = swiftMinerTunnelHostnameHandler
        self.swiftMinerTunnelInfoProvider = swiftMinerTunnelInfoProvider
        self.companionSSOConfigProvider = companionSSOConfigProvider
        self.discordUsersProvider = discordUsersProvider
        self.swiftMinerTestDMSender = swiftMinerTestDMSender
        self.swiftMinerPairedProvider = swiftMinerPairedProvider
        self.logger = log

        loadPersistedSessions()
        loadPasskeys()
        let previous = self.config
        self.config = config
        revokeSessionsOutsideAllowList(previous: previous.allowedUserIDs)
        if !config.memberAccessEnabled {
            let members = sessions.values.filter { $0.role == .member }
            if !members.isEmpty {
                members.forEach { sessions[$0.id] = nil }
                persistSessions()
            }
        }

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
            let requestData = try await withReadTimeout(connection: connection) {
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

    /// On timeout we cancel the connection *before* throwing: `NWConnection.receive`
    /// does not observe Swift task cancellation, so without the explicit cancel the
    /// read child task would stay suspended on its continuation and the task group
    /// could never finish tearing down (the caller's `defer` cancel can't run until
    /// this returns).
    private func withReadTimeout<T: Sendable>(
        connection: NWConnection,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { [requestReadTimeout] in
                try await Task.sleep(nanoseconds: UInt64(requestReadTimeout * 1_000_000_000))
                connection.cancel()
                throw NSError(domain: "AdminWebServer", code: 408, userInfo: [NSLocalizedDescriptionKey: "Request read timed out"])
            }
            defer { group.cancelAll() }
            return try await group.next()!
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

    private static let memberPlaybackPaths: Set<String> = [
        "/api/media/stream", "/api/media/hls", "/api/media/hls-segment",
        "/api/media/thumbnail", "/api/media/frame", "/api/media/game-art", "/api/media/game-details",
        "/api/media/playback"
    ]

    private static func isMemberRoute(method: String, path: String) -> Bool {
        if path.hasPrefix("/api/member/") { return true }
        if path.hasPrefix("/auth/") { return true }
        switch path {
        case "/api/me", "/api/auth/options":
            return true
        default:
            // The page and its static files; never another API.
            return method == "GET" && !path.hasPrefix("/api/") && !path.hasPrefix("/v1/") && !path.hasPrefix("/media")
        }
    }

    private func requireRole(_ role: Role, session: Session) -> Bool {
        if session.role == .admin { return true }
        return session.role == role
    }

    private var meshRequestHandler: (@Sendable (Data, String?) async -> Data)?

    func setMeshRequestHandler(_ handler: @escaping @Sendable (Data, String?) async -> Data) {
        meshRequestHandler = handler
    }

    private func process(_ requestData: Data, peerIP: String? = nil) async -> Data {
        guard var request = parseRequest(requestData) else {
            return httpResponse(status: "400 Bad Request", body: Data("Invalid request".utf8))
        }
        request.peerIP = peerIP
        if request.path.hasPrefix("/v1/mesh/") || ["/cluster/status", "/cluster/register", "/cluster/ping"].contains(request.path) {
            guard let handler = meshRequestHandler else {
                return httpResponse(status: "404 Not Found", body: Data())
            }
            return await handler(requestData, peerIP)
        }

        pruneExpiredState()
        pruneExpiredSessions()

        // Browser edits must never bypass SwiftMesh failover ownership. The
        // native app may explicitly forward selected edits to the Primary,
        // but the WebUI has no such acknowledgement flow, so it is strictly
        // read-only on standby and worker nodes. Keep this at the router
        // boundary so new mutation endpoints cannot accidentally omit it.
        if request.method != "GET",
           request.path.hasPrefix("/api/") {
            if let status = await statusProvider?(), status.isFailoverManagedNode {
                return jsonResponse(
                    ["error": "failover_managed", "message": "This node is managed by the active Primary and is read-only in WebUI."],
                    status: "409 Conflict"
                )
            }
        }

        if request.method == "GET" && request.path == config.redirectPath {
            return await handleDiscordCallback(request: request)
        }

        // Members only reach the page, sign-in and their own routes. One gate
        // here, rather than trusting every admin endpoint to check the role.
        if let session = authenticatedSession(for: request), session.role == .member,
           !Self.isMemberRoute(method: request.method, path: request.path) {
            // Playback is allowed only for clips this member is in.
            guard Self.memberPlaybackPaths.contains(request.path), ["GET", "HEAD"].contains(request.method) else {
                return jsonResponse(["error": "admins_only"], status: "403 Forbidden")
            }
            // Game art and Steam details aren't anyone's clips.
            if request.path != "/api/media/game-art" && request.path != "/api/media/game-details" {
                guard let token = request.query["id"], !token.isEmpty,
                      await memberMayPlay?(session.userID, token) == true else {
                    return jsonResponse(["error": "not_your_clip"], status: "403 Forbidden")
                }
            }
        }

        if request.path.hasPrefix("/auth/passkeys/") {
            return await handlePasskeys(request: request)
        }

        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return serveIndex()
        case ("HEAD", "/"), ("HEAD", "/index.html"):
            // Uptime monitors and link checkers probe with HEAD.
            return headersOnly(serveIndex())
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
        case ("GET", "/assets/hls.min.js"):
            return serveAsset(named: "hls.min", ext: "js")
        case ("GET", "/assets/tabler-icons.js"):
            return serveAsset(named: "tabler-icons", ext: "js")
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
        case ("GET", "/live"):
            // Public liveness probe — no auth. Reveals only whether the bot
            // is currently connected to Discord, which any user could infer
            // by watching the bot in a server.
            //
            // Three states:
            //   online  — node is serving Discord traffic (Primary/Standalone, status=running).
            //   passive — node is connected but in Failover mode; gateway is open in
            //             passive mode (output muted), takes over on promotion.
            //   offline — node is not connected (stopped/reconnecting/etc.).
            //
            // Content-negotiated: browsers (Accept: text/html) get a styled
            // status page; everything else (curl, UptimeRobot, BetterStack,
            // k8s probes) gets the plain-text state for trivial scraping.
            let liveStatus = await statusProvider?()
            let botStatus = liveStatus?.botStatus ?? "stopped"
            let isRunning = botStatus == "running"
            let isStandby = (liveStatus?.clusterMode ?? "") == "Standby"
            // Standby with a running gateway is "passive" — connected to
            // Discord but with output muted. Reporting "online" here would lie
            // to uptime monitors; reporting "offline" would lie too. The
            // distinct "passive" state lets each monitor decide whether to
            // alert on it.
            let isPassive = isRunning && isStandby
            let isOnline = isRunning && !isStandby
            let rawName = liveStatus?.botUsername.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let botName = rawName.isEmpty || rawName == "OnlineBot" ? "SwiftBot" : rawName

            let plainBody: String
            let pageTitle: String
            let pageMessage: String
            let pageDetail: String
            let pageVariant: AuthStatusVariant
            if isOnline {
                plainBody = "online"
                pageTitle = "\(botName) is online ✓"
                pageMessage = "Connected to Discord and responding to events."
                pageDetail = "If you're seeing this page you've reached the live SwiftBot node successfully."
                pageVariant = .liveOnline
            } else if isPassive {
                plainBody = "passive"
                pageTitle = "\(botName) is on standby"
                pageMessage = "Connected to Discord in passive Failover mode. The bot does not send messages until this node is promoted to Primary."
                pageDetail = "If the Primary disappears, this node will take over automatically."
                pageVariant = .mfaRequired // amber/gold palette — informational, not an error
            } else {
                plainBody = "offline"
                pageTitle = "\(botName) is offline"
                pageMessage = "The bot is not currently connected to Discord."
                pageDetail = "The node is reachable but the bot itself is stopped or reconnecting. Check the dashboard for details."
                pageVariant = .error
            }

            let acceptHeader = request.headers["accept"] ?? ""
            if acceptHeader.contains("application/json") {
                return codableResponse(AdminWebLivePayload(
                    status: plainBody,
                    discordConnected: isRunning,
                    clusterMode: liveStatus?.clusterMode,
                    runtimeState: liveStatus?.runtimeState,
                    botUsername: botName,
                    generatedAt: Date()
                ))
            }

            let wantsHTML = acceptHeader.contains("text/html")
            if wantsHTML {
                return authStatusPageResponse(
                    status: "200 OK",
                    title: pageTitle,
                    eyebrow: "Status",
                    message: pageMessage,
                    detail: pageDetail,
                    actionTitle: "Open dashboard",
                    actionURL: "/",
                    variant: pageVariant
                )
            }
            return httpResponse(status: "200 OK", body: Data(plainBody.utf8))
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
        case ("GET", "/v1/tunnel/info"):
            guard let provider = swiftMinerTunnelInfoProvider else {
                return jsonResponse(["error": "unavailable"], status: "503 Service Unavailable")
            }
            let result = await provider()
            return httpResponse(status: result.status, body: result.body, contentType: "application/json; charset=utf-8")
        case ("POST", "/v1/tunnel/hostnames"):
            // Companion-app (SwiftMiner) hostname registration. The handler
            // verifies the shared-secret HMAC itself and fails closed, since
            // this endpoint mutates Cloudflare configuration.
            guard let handler = swiftMinerTunnelHostnameHandler else {
                return jsonResponse(["error": "unavailable"], status: "503 Service Unavailable")
            }
            let result = await handler(request.headers, request.body)
            return httpResponse(status: result.status, body: result.body, contentType: "application/json; charset=utf-8")
        case ("GET", "/api/status"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            let payload = await statusProvider?() ?? AdminWebStatusPayload(
                botStatus: "stopped",
                botUsername: "SwiftBot",
                botAvatarURL: nil,
                connectedServerCount: 0,
                gatewayEventCount: 0,
                uptimeText: nil,
                webUIEnabled: false,
                webUIBaseURL: "",
                clusterMode: nil,
                runtimeState: nil,
                isFailoverManagedNode: false
            )
            return codableResponse(payload)
        case ("GET", "/api/overview"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
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
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            // Word and emoji counts are message fragments, so only admins get
            // them, matching /api/rewind.
            let payload = await cachedAnalytics(
                period: AnalyticsPeriod(query: request.query["period"]),
                includeMessageText: session.role == .admin
            )
            return codableResponse(payload)
        case ("GET", "/api/rewind/replay"), ("GET", "/api/rewind/member"), ("GET", "/api/rewind/phrase"), ("GET", "/api/rewind/recaps"), ("GET", "/api/rewind/recipients"):
            // Admin-only like /api/rewind: replays and phrase counts are built
            // from members' messages.
            guard let session = authenticatedSession(for: request) else { return unauthorizedResponse() }
            guard requireRole(.admin, session: session) else { return forbiddenResponse() }
            let guildID = request.query["guild"] ?? ""
            let period = ReplayPeriod(key: request.query["period"] ?? "") ?? .year(Calendar.current.component(.year, from: Date()))
            let rewindRequest: AdminWebRewindRequest
            switch request.path {
            case "/api/rewind/replay": rewindRequest = .replay(guildID: guildID, period: period)
            case "/api/rewind/member": rewindRequest = .member(guildID: guildID, userID: request.query["user"] ?? "", period: period)
            case "/api/rewind/phrase": rewindRequest = .phrase(guildID: guildID, phrase: request.query["q"] ?? "")
            case "/api/rewind/recipients": rewindRequest = .recipients(guildID: guildID, period: period)
            default: rewindRequest = .recaps
            }
            return rewindResponse(await rewindHandler?(rewindRequest) ?? .failure("rewind_unavailable"))
        case ("POST", "/api/rewind/recaps/update"), ("POST", "/api/rewind/recaps/post"), ("POST", "/api/rewind/recaps/dm"):
            guard let session = authenticatedSession(for: request) else { return unauthorizedResponse() }
            guard requireRole(.admin, session: session) else { return forbiddenResponse() }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            let result: AdminWebRewindResult
            if request.path == "/api/rewind/recaps/update" {
                guard let update = try? decoder.decode(AdminWebRewindRecapUpdate.self, from: request.body) else {
                    return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
                }
                result = await rewindHandler?(.updateRecap(update)) ?? .failure("rewind_unavailable")
                audit(source: "Web Config", actor: actorLabel(session), action: "Updated Replay recap drops",
                      detail: "monthly \(update.monthly ? "on" : "off") · yearly \(update.yearly ? "on" : "off")")
            } else {
                struct PostBody: Decodable { let guildID: String; let period: String }
                guard let body = try? decoder.decode(PostBody.self, from: request.body),
                      let period = ReplayPeriod(key: body.period) else {
                    return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
                }
                if request.path == "/api/rewind/recaps/dm" {
                    result = await rewindHandler?(.sendDMs(guildID: body.guildID, period: period)) ?? .failure("rewind_unavailable")
                    audit(source: "Web Config", actor: actorLabel(session), action: "Sent personal Replay DMs", detail: period.key)
                } else {
                    result = await rewindHandler?(.postRecap(guildID: body.guildID, period: period)) ?? .failure("rewind_unavailable")
                    audit(source: "Web Config", actor: actorLabel(session), action: "Posted a Replay recap", detail: period.key)
                }
            }
            return rewindResponse(result)
        case ("GET", "/api/rewind"):
            // Admin-only, unlike /api/analytics. Rewind's "top words" and "top
            // phrases" are verbatim fragments of members' messages, not
            // operational metrics — a viewer session should not read them, and
            // this endpoint is reachable over the public tunnel when that is on.
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            let payload = await rewindProvider?() ?? AdminWebRewindPayload.empty
            return codableResponse(payload)
        case ("GET", "/api/me"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            // Admins and members; a viewer session has no page to show.
            guard session.role == .admin || session.role == .member else {
                return forbiddenResponse()
            }
            return jsonResponse([
                "id": session.userID,
                "username": session.username,
                "globalName": session.globalName ?? "",
                "discriminator": session.discriminator ?? "",
                "avatar": session.avatar ?? "",
                "csrfToken": session.csrfToken,
                "role": session.role.rawValue,
                // For the Preferences page's account card.
                "signInMethod": session.signInMethod ?? (session.userID.hasPrefix("local:") ? "password" : "discord"),
                "sessionExpiresAt": ISO8601DateFormatter().string(from: session.expiresAt)
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
        case ("GET", "/api/activity"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            let limit = min(1_000, max(1, Int(request.query["limit"] ?? "") ?? 400))
            if let payload = await activityProvider?(limit) {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "activity_unavailable"], status: "503 Service Unavailable")
        case ("GET", "/api/activity/export"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard let report = await activityReportProvider?() else {
                return jsonResponse(["error": "activity_unavailable"], status: "503 Service Unavailable")
            }
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
            return httpResponse(
                status: "200 OK",
                body: Data(report.utf8),
                headers: ["Content-Disposition": "attachment; filename=\"SwiftBot-Diagnostics-\(stamp).txt\""]
            )
        case ("GET", "/api/access"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            if let payload = await accessProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "access_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/access/update"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let update = try? decoder.decode(AdminWebAccessUpdate.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            do {
                try update.validate(editorUserID: session.userID)
            } catch let failure as AdminWebAccessUpdate.GuardFailure {
                return jsonResponse(["error": failure.rawValue], status: "400 Bad Request")
            } catch {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await accessUpdater?(update) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            audit(source: "Web Config", actor: actorLabel(session), action: "Updated sign-in access",
                  detail: update.restrictToListedUsers ? "Only \(update.normalizedIDs.count) listed people" : "Server managers")
            return jsonResponse(["ok": true])
        case ("POST", "/api/access/members"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let update = try? decoder.decode(AdminWebMemberAccessUpdate.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await memberAccessUpdater?(update.enabled) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            audit(source: "Web Config", actor: actorLabel(session), action: update.enabled ? "Let server members sign in" : "Stopped member sign-in")
            return jsonResponse(["ok": true])
        case ("GET", "/api/music/preview"):
            // Runs the real lookup (oEmbed + Apple search), so admins only, and
            // cached so reopening the dialog doesn't search again.
            guard let session = authenticatedSession(for: request) else { return unauthorizedResponse() }
            guard requireRole(.admin, session: session) else { return forbiddenResponse() }
            let link = (request.query["url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.isEmpty, link.count <= 2048 else {
                return jsonResponse(["error": "missing_url", "message": "Paste a song link to preview."], status: "400 Bad Request")
            }
            musicPreviewCache = musicPreviewCache.filter { Date().timeIntervalSince($0.value.builtAt) < 600 }
            if let cached = musicPreviewCache[link] {
                return httpResponse(status: "200 OK", body: cached.body, contentType: "application/json; charset=utf-8")
            }
            guard let body = await musicPreviewProvider?(link) else {
                return jsonResponse(["error": "not_found", "message": "That isn’t a song link SwiftBot recognises, or it couldn’t be identified."], status: "404 Not Found")
            }
            if musicPreviewCache.count > 50 { musicPreviewCache.removeAll() }
            musicPreviewCache[link] = (body, Date())
            return httpResponse(status: "200 OK", body: body, contentType: "application/json; charset=utf-8")
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

        case ("POST", "/api/automations/simulate"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let body = try? decoder.decode(AdminWebAutomationSimulationRequest.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard let payload = await automationSimulator?(body) else {
                return jsonResponse(["error": "simulation_unavailable"], status: "503 Service Unavailable")
            }
            return codableResponse(payload)

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

        case ("POST", "/api/announcer/disconnect"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard await disconnectAnnouncer?() == true else {
                return jsonResponse(["error": "not_connected"], status: "400 Bad Request")
            }
            audit(source: "webui", actor: actorLabel(session), action: "announcer.disconnect", detail: "Disconnected the active announcer")
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
                let patch = try apiDecoder.decode(AdminWebPatchyTargetPatch.self, from: request.body)
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
            // Waits for the real send so the WebUI can say "sent" or show
            // Discord's or the source's actual error.
            guard let outcome = await sendPatchyTestTarget?(patch.targetID) else {
                return jsonResponse(["error": "test_failed", "message": "Patchy isn't available."], status: "503 Service Unavailable")
            }
            guard outcome.ok else {
                return jsonResponse(["error": "test_failed", "message": outcome.message], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true, "message": outcome.message])
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
        case ("GET", "/api/gametracker"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await gameTrackerProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "gametracker_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/gametracker/check"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard await gameTrackerCheckRunner?() == true else {
                return jsonResponse(["error": "check_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/gametracker/update"):
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
                let update = try apiDecoder.decode(AdminWebGameTrackerUpdate.self, from: request.body)
                try update.validate()
                guard await gameTrackerUpdater?(update) == true else {
                    return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
                }
                return jsonResponse(["ok": true])
            } catch {
                return jsonResponse(["error": "validation_failed", "message": error.localizedDescription], status: "400 Bad Request")
            }
        case ("POST", "/api/gametracker/preview"):
            // Renders an unsaved style so the editor preview follows the
            // draft. Read-only: nothing is stored or posted.
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard var style = try? apiDecoder.decode(GameAnnouncementStyle.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            style.normalize()
            if let preview = await gameTrackerStylePreviewer?(style) {
                return codableResponse(preview)
            }
            return jsonResponse(["error": "gametracker_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/gametracker/credential"):
            return await handleGameProviderCredential(request)
        case ("GET", "/api/bot/permissions"), ("GET", "/api/updates"):
            return await handleHostSnapshot(request)
        case ("POST", let path) where Self.hostOperationPaths.contains(path):
            return await handleHostOperation(request)
        case ("GET", "/api/sweep"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            if var payload = await sweepProvider?() {
                // Run previews quote members' messages, so only admins get
                // them, matching /api/analytics and /api/rewind.
                if session.role != .admin {
                    payload.recentReports = payload.recentReports.map(\.withoutMessageText)
                    payload.suggestions = payload.suggestions.map { suggestion in
                        var redacted = suggestion
                        redacted.projection = suggestion.projection?.withoutMessageText
                        return redacted
                    }
                }
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
        case ("POST", "/api/sweep/policy/create"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebSweepPolicyCreatePatch.self, from: request.body),
                  let policy = await createSweepPolicy?(patch) else {
                return jsonResponse(["error": "create_failed"], status: "400 Bad Request")
            }
            audit(source: "webui", actor: actorLabel(session), action: "sweep.policy.create", detail: policy.name)
            return codableResponse(policy)
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
                let patch = try apiDecoder.decode(SweepPolicy.self, from: request.body)
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
            guard let patch = try? apiDecoder.decode(SweepPolicy.self, from: request.body) else {
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
        case ("GET", "/api/aibots"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await aiBotsProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "aibots_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/aibots/memory/clear"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebAIMemoryClearPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await clearAIMemory?(patch) == true else {
                return jsonResponse(["error": "clear_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/aibots/try"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard var tryRequest = try? decoder.decode(AdminWebAITryRequest.self, from: request.body),
                  !tryRequest.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  tryRequest.message.count <= 1_000, tryRequest.prompt.count <= 4_000 else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            tryRequest.askerID = session.userID.hasPrefix("local:") ? nil : session.userID
            guard let reply = await tryAIReply?(tryRequest) else {
                return jsonResponse(["error": "no_reply"], status: "503 Service Unavailable")
            }
            return jsonResponse(["reply": reply])
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
        case ("GET", "/api/media/game-details"):
            guard mediaAccessAuthorized(request) else { return unauthorizedResponse() }
            guard let game = request.query["game"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !game.isEmpty, game.count <= 200 else {
                return jsonResponse(["error": "invalid_game"], status: "400 Bad Request")
            }
            guard let data = await RecordingSteamArtworkService.shared.gameDetailsData(for: game) else {
                return jsonResponse(["error": "details_unavailable"], status: "404 Not Found")
            }
            return httpResponse(status: "200 OK", body: data, contentType: "application/json")
        case ("GET", "/api/media/game-art"):
            // Portrait poster for a game: custom artwork when set, otherwise
            // Steam library art fetched and cached by the app, so the page
            // never loads images from Steam directly.
            guard mediaAccessAuthorized(request) else {
                return unauthorizedResponse()
            }
            guard let game = request.query["game"]?.trimmingCharacters(in: .whitespacesAndNewlines), !game.isEmpty else {
                return jsonResponse(["error": "missing_game"], status: "400 Bad Request")
            }
            guard let response = await mediaGameArtworkProvider?(game) else {
                return jsonResponse(["error": "artwork_unavailable"], status: "404 Not Found")
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
        case ("GET", "/api/media/playback"):
            guard mediaAccessAuthorized(request) else { return unauthorizedResponse() }
            guard let token = request.query["id"], !token.isEmpty,
                  let choice = await mediaPlaybackChoiceProvider?(token) else {
                return jsonResponse(["error": "unknown_item"], status: "404 Not Found")
            }
            return jsonResponse(["quality": choice.quality, "preparing": choice.preparing])
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
        case ("GET", "/api/media/hls"):
            guard mediaAccessAuthorized(request) else {
                return unauthorizedResponse()
            }
            guard let token = request.query["id"], !token.isEmpty else {
                return jsonResponse(["error": "missing_id"], status: "400 Bad Request")
            }
            let accessToken = request.query["token"]
            guard let response = await mediaHLSPlaylistProvider?(token, accessToken) else {
                return jsonResponse(["error": "hls_unavailable"], status: "404 Not Found")
            }
            return httpResponse(
                status: response.status,
                body: response.body,
                contentType: response.contentType,
                headers: response.headers
            )
        case ("GET", "/api/media/hls-segment"):
            guard mediaAccessAuthorized(request) else {
                return unauthorizedResponse()
            }
            guard let token = request.query["id"], !token.isEmpty,
                  let segment = request.query["seg"], !segment.isEmpty else {
                return jsonResponse(["error": "missing_id"], status: "400 Bad Request")
            }
            guard let response = await mediaHLSSegmentProvider?(token, segment, request.query["token"]) else {
                return jsonResponse(["error": "hls_segment_unavailable"], status: "404 Not Found")
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
                let patch = try apiDecoder.decode(AdminWebWikiSourcePatch.self, from: request.body)
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
        case ("POST", "/api/wikibridge/source/detect"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let detect = try? decoder.decode(AdminWebWikiDetectRequest.self, from: request.body),
                  detect.baseURL.count <= 300 else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard let site = await detectWikiSite?(detect) else {
                return jsonResponse(["error": "not_mediawiki"], status: "404 Not Found")
            }
            return jsonResponse(["siteName": site.siteName, "apiPath": site.apiPath])
        case ("POST", "/api/wikibridge/source/preview"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let preview = try? apiDecoder.decode(AdminWebWikiPreviewRequest.self, from: request.body),
                  !preview.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  preview.query.count <= 200 else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard let body = await previewWikiSource?(preview) else {
                return jsonResponse(["error": "no_result"], status: "404 Not Found")
            }
            return httpResponse(status: "200 OK", body: body, contentType: "application/json; charset=utf-8", headers: [:])
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
        case ("GET", "/api/member/replay"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            // Admins can open it too (to see their own); members only ever
            // get their own user ID and servers.
            let guildIDs = session.role == .member ? (session.guildIDs ?? []) : nil
            guard let payload = await memberReplayProvider?(session.userID, guildIDs, request.query["guild"], request.query["period"]) else {
                return jsonResponse(["error": "unavailable"], status: "503 Service Unavailable")
            }
            return codableResponse(payload)
        case ("GET", "/api/member/clips"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard let payload = await memberClipsProvider?(session.userID, request.query) else {
                return jsonResponse(["error": "unavailable"], status: "503 Service Unavailable")
            }
            return codableResponse(payload)
        case ("POST", "/api/media/source-owner"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebMediaSourceOwnerPatch.self, from: request.body),
                  await setMediaSourceOwner?(patch.sourceID, patch.userID) == true else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            audit(source: "Web Config", actor: actorLabel(session), action: "Set who records a folder", detail: patch.userID.isEmpty ? "Cleared" : patch.userID)
            return jsonResponse(["ok": true])
        case ("POST", "/api/media/game-match"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebMediaGameMatchPatch.self, from: request.body),
                  await fixMediaGameMatch?(patch) == true else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            let scope = patch.fromGame.map { "all \($0) clips" }
                ?? (patch.applyToDetected == true ? "all clips of its detected game" : "one clip")
            audit(source: "Web Config", actor: actorLabel(session), action: "Fixed a recording's game",
                  detail: patch.gameName.isEmpty ? "Reset \(scope)" : "\(patch.gameName) (\(scope))")
            return jsonResponse(["ok": true])
        case ("GET", "/api/media/game-search"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            let term = request.query["q"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !term.isEmpty, term.count <= 100 else {
                return codableResponse([AdminWebGameSearchResult]())
            }
            let results = await RecordingSteamArtworkService.shared.searchGames(term: term)
            return codableResponse(results.map { AdminWebGameSearchResult(name: $0.name, steamAppID: $0.id) })
        case ("GET", "/api/operators"):
            guard let session = authenticatedSession(for: request) else { return unauthorizedResponse() }
            guard requireRole(.admin, session: session) else { return forbiddenResponse() }
            guard let payload = await operatorsProvider?() else {
                return jsonResponse(["error": "unavailable"], status: "503 Service Unavailable")
            }
            return codableResponse(payload)
        case ("POST", "/api/operators"):
            guard let session = authenticatedSession(for: request) else { return unauthorizedResponse() }
            guard requireRole(.admin, session: session) else { return forbiddenResponse() }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebOperatorsPatch.self, from: request.body),
                  await updateOperators?(patch) == true else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            audit(source: "Web Config", actor: actorLabel(session), action: patch.node != nil ? "Set the operator for \(patch.node ?? "")" : "Changed operator alerts",
                  detail: patch.alert.map { "\($0): \(patch.enabled == true ? "on" : "off")" } ?? (patch.userID?.isEmpty == false ? patch.userID! : "Cleared"))
            return jsonResponse(["ok": true])
        case ("POST", "/api/operators/test"):
            guard let session = authenticatedSession(for: request) else { return unauthorizedResponse() }
            guard requireRole(.admin, session: session) else { return forbiddenResponse() }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            if let problem = await sendOperatorTest?() {
                return jsonResponse(["error": problem], status: "409 Conflict")
            }
            return jsonResponse(["ok": true])
        case ("GET", "/api/swiftmesh"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            guard let payload = await swiftMeshProvider?() else {
                return jsonResponse(["error": "unavailable"], status: "503 Service Unavailable")
            }
            return codableResponse(payload)
        case ("POST", "/api/swiftmesh/pair"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            // The link carries the mesh's shared secret, so only a Discord
            // admin (sign-in requires Discord 2FA) gets it. Local-password
            // sessions have no second factor.
            guard !session.userID.hasPrefix("local:") else {
                return jsonResponse([
                    "error": "discord_required",
                    "message": "Sign in with Discord to pair a Mac. The local admin sign-in has no two-factor authentication."
                ], status: "403 Forbidden")
            }
            if let refusal = sensitiveSecretRefusal(session: session, request: request, purpose: "pair a Mac") {
                return refusal
            }
            guard let joinURL = await swiftMeshJoinCodeProvider?() else {
                return jsonResponse(["error": "Pairing is available only on the active Primary."], status: "409 Conflict")
            }
            audit(source: "Web Config", actor: actorLabel(session), action: "SwiftMesh pairing link requested")
            return jsonResponse(["joinURL": joinURL])
        case ("POST", "/api/swiftmesh/action"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard requireRole(.admin, session: session) else {
                return forbiddenResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let action = try? decoder.decode(AdminWebSwiftMeshAction.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            // nil means done; a string is the reason it couldn't be.
            if let problem = await runSwiftMeshAction?(action) {
                return jsonResponse(["error": problem], status: "409 Conflict")
            }
            audit(source: "Web Config", actor: actorLabel(session), action: "SwiftMesh \(action.action)\(action.node.map { " \($0)" } ?? "")")
            return jsonResponse(["ok": true])

        // MARK: - OAuth Authentication
        //
        // The Discord OAuth routes sign people in to the WebUI:
        //
        // Browser → /auth/discord/login
        //         → Discord OAuth
        //         → /auth/discord/callback
        //         → session cookie set
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
        case ("GET", "/auth/companion/discord"):
            return await handleCompanionDiscordLogin(request: request)
        case ("POST", "/auth/local/login"):
            return handleLocalLogin(request: request)
        case ("POST", "/auth/logout"):
            return handleLogout(request: request)
        case ("GET", "/api/auth/options"):
            return await handleAuthOptions()
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
        // Browsers' URLSearchParams send a space as "+", which URLComponents
        // leaves alone; decode it as a form would ("Call+of+Duty" was being
        // looked up literally). A real "+" arrives as %2B and stays one.
        components?.percentEncodedQueryItems?.forEach { item in
            let name = item.name.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? item.name
            let value = item.value?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            query[name] = value
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

        let uri = redirectURI()

        // Discord returns to the configured public address. Started from
        // another address (the LAN or 127.0.0.1), the state cookie would sit
        // on that host and the callback would reject the sign-in, so start
        // over on the callback's own host first.
        if let callbackOrigin = Self.origin(of: uri),
           let requestHost = request.headers["host"]?.lowercased(),
           callbackOrigin.host != requestHost {
            return redirectResponse(to: callbackOrigin.url + "/auth/discord/login")
        }

        let state = randomToken()
        let codeVerifier = randomToken() // High-entropy random string
        let codeChallenge = base64URLEncode(sha256(codeVerifier))

        pendingStates[state] = PendingState(
            value: state,
            expiresAt: Date().addingTimeInterval(stateTTL),
            codeVerifier: codeVerifier
        )

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
        let stateCookie = cookieHeader(
            name: "swiftbot_oauth_state",
            value: state,
            maxAge: Int(stateTTL),
            secure: isHTTPSRequest(request)
        )
        return redirectResponse(to: url.absoluteString, headers: ["Set-Cookie": stateCookie])
    }

    /// Starts a Discord OAuth flow on behalf of a companion app (SwiftMiner's
    /// web dashboard). Identity-only: on success the callback redirects back to
    /// the companion with a short-lived HMAC-signed assertion of the Discord
    /// user id — no admin session, no allow-list or MFA requirements, because
    /// the companion only lets a user manage their own miner.
    private func handleCompanionDiscordLogin(request: HTTPRequest) async -> Data {
        let clientID = config.discordOAuth.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = config.discordOAuth.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            return oauthErrorPageResponse(
                status: "503 Service Unavailable",
                title: "Discord sign-in unavailable",
                message: "Discord OAuth hasn't been configured on this SwiftBot instance.",
                detail: "Ask the operator to add the Discord client ID and secret in SwiftBot's settings."
            )
        }

        guard let sso = await companionSSOConfigProvider?(),
              !sso.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return oauthErrorPageResponse(
                status: "503 Service Unavailable",
                title: "Companion sign-in unavailable",
                message: "SwiftBot isn't paired with a companion app.",
                detail: "Pair SwiftMiner with SwiftBot first."
            )
        }

        // `return_to` must be an https URL on a hostname this tunnel actually
        // carries for a companion — anything else is an open-redirect attempt.
        guard let returnRaw = request.query["return_to"],
              let returnURL = URL(string: returnRaw),
              returnURL.scheme?.lowercased() == "https",
              let returnHost = returnURL.host?.lowercased(),
              sso.hostnames.contains(where: { $0.lowercased() == returnHost }) else {
            await logger?("Companion SSO rejected: return_to not a registered companion hostname")
            return oauthErrorPageResponse(
                status: "400 Bad Request",
                title: "Sign-in request rejected",
                message: "The return address isn't a registered companion app.",
                detail: "Register the companion's hostname on SwiftBot's tunnel first."
            )
        }

        let state = randomToken()
        let codeVerifier = randomToken()
        let codeChallenge = base64URLEncode(sha256(codeVerifier))

        pendingStates[state] = PendingState(
            value: state,
            expiresAt: Date().addingTimeInterval(stateTTL),
            codeVerifier: codeVerifier,
            companionReturnURL: returnURL.absoluteString
        )

        var components = URLComponents(string: "https://discord.com/oauth2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI()),
            URLQueryItem(name: "scope", value: "identify guilds"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let url = components?.url else {
            return oauthErrorPageResponse(
                status: "500 Internal Server Error",
                title: "Something went wrong",
                message: "We couldn't build the Discord sign-in URL.",
                detail: "Try again in a moment."
            )
        }

        let stateCookie = cookieHeader(
            name: "swiftbot_oauth_state",
            value: state,
            maxAge: Int(stateTTL),
            secure: isHTTPSRequest(request)
        )
        return redirectResponse(to: url.absoluteString, headers: ["Set-Cookie": stateCookie])
    }

    private func handleLocalLogin(request: HTTPRequest) -> Data {
        // Mirrors what the sign-in page offers: a developer feature, and only
        // on this Mac or the local network, never through the public tunnel.
        guard config.localAuthEnabled, config.devFeaturesEnabled else {
            return jsonResponse(["error": "local_auth_disabled"], status: "403 Forbidden")
        }
        guard !isPublicTunnelRequest(request) else {
            audit(source: "Web Auth", actor: "local", action: "Login blocked", detail: "Password sign-in tried through the public address", level: "warning")
            return jsonResponse(["error": "local_auth_local_only"], status: "403 Forbidden")
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
            headers: ["Set-Cookie": sessionCookie(for: session.id, secure: isHTTPSRequest(request))]
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
        if !constantTimeEquals(stateCookieValue, state) {
            return oauthErrorPageResponse(
                status: "400 Bad Request",
                title: "Sign-in didn't complete",
                message: "The browser session that started this sign-in no longer matches.",
                detail: "Start over from the login screen in the same browser you started in."
            )
        }

        // Companion SSO: hand the verified Discord identity back to the
        // companion app as a short-lived signed assertion. Deliberately no
        // admin session, allow-list, or MFA gate — the companion only lets a
        // user manage their own miner, and authorization happens there.
        if let companionReturnURL = pendingState.companionReturnURL {
            return await completeCompanionSSO(
                code: code,
                codeVerifier: pendingState.codeVerifier,
                returnURL: companionReturnURL
            )
        }

        do {
            let token = try await exchangeDiscordCode(code: code, codeVerifier: pendingState.codeVerifier)
            let user = try await fetchDiscordUser(accessToken: token.accessToken)
            let guilds = try await fetchDiscordGuilds(accessToken: token.accessToken)
            let isAdmin = await isAuthorized(userID: user.id, guilds: guilds)
            let connectedGuildIDs = await connectedGuildIDsProvider?() ?? []
            let memberGuildIDs = guilds.map(\.id).filter { connectedGuildIDs.contains($0) }
            if !isAdmin, config.memberAccessEnabled, !memberGuildIDs.isEmpty {
                return await startMemberSession(user: user, guildIDs: memberGuildIDs, request: request, pendingState: pendingState)
            }
            guard isAdmin else {
                await logger?("Admin Web UI login denied for \(user.username) (\(user.id))")
                audit(source: "Web Auth", actor: "\(user.username) (\(user.id))", action: "Login denied", detail: "User not authorized for this bot", level: "warning")
                return authStatusPageResponse(
                    status: "403 Forbidden",
                    title: "Access not allowed",
                    eyebrow: "SwiftBot Web Admin",
                    message: "You're signed in to Discord as @\(user.username), but that account can't sign in here.",
                    detail: config.allowedUserIDs.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                        ? "Only people on SwiftBot's sign-in list can use this page. Ask a SwiftBot administrator to add you."
                        : "Sign in with an account that owns or can manage one of the connected servers, or ask a SwiftBot administrator to add you to the sign-in list.",
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
                role: .admin,
                discordRefreshToken: token.refreshToken
            )
            if let refreshToken = token.refreshToken,
               passkeyState.credentials.values.contains(where: { $0.userID == user.id }) {
                var state = passkeyState
                state.refreshTokens[user.id] = refreshToken
                try savePasskeys(state)
            }
            sessions[session.id] = session
            persistSessions()
            await logger?("Admin Web UI login for \(user.username) (\(user.id))")
            audit(source: "Web Auth", actor: "\(user.username) (\(user.id))", action: "Logged in", detail: "Discord OAuth", level: "ok")
            return redirectResponse(
                to: "/",
                headers: ["Set-Cookie": sessionCookie(for: session.id, secure: isHTTPSRequest(request))]
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

    /// Finishes a companion SSO flow: exchanges the code, fetches the Discord
    /// identity, and redirects to the companion with `sso` (base64url payload)
    /// + `sig` (hex HMAC-SHA256 over the payload, keyed by the pairing secret).
    /// The payload carries a 120s expiry and a single-use nonce; the companion
    /// enforces both.
    private func completeCompanionSSO(code: String, codeVerifier: String?, returnURL: String) async -> Data {
        guard let sso = await companionSSOConfigProvider?() else {
            return oauthErrorPageResponse(
                status: "503 Service Unavailable",
                title: "Companion sign-in unavailable",
                message: "SwiftBot isn't paired with a companion app.",
                detail: "Pair SwiftMiner with SwiftBot first."
            )
        }
        let secret = sso.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        // Re-validate the return host against the *current* registrations — the
        // pending state could outlive a removed companion.
        guard !secret.isEmpty,
              let returnComponentsURL = URL(string: returnURL),
              let returnHost = returnComponentsURL.host?.lowercased(),
              sso.hostnames.contains(where: { $0.lowercased() == returnHost }) else {
            return oauthErrorPageResponse(
                status: "400 Bad Request",
                title: "Sign-in request rejected",
                message: "The return address is no longer a registered companion app.",
                detail: "Register the companion's hostname on SwiftBot's tunnel first."
            )
        }

        do {
            let token = try await exchangeDiscordCode(code: code, codeVerifier: codeVerifier)
            let user = try await fetchDiscordUser(accessToken: token.accessToken)
            let guilds = try await fetchDiscordGuilds(accessToken: token.accessToken)
            let isGuildMember = await isMemberOfConnectedGuild(guilds: guilds)

            let payloadObject: [String: Any] = [
                "discordUserId": user.id,
                "username": user.username,
                "exp": Int(Date().timeIntervalSince1970) + 120,
                "nonce": randomToken(),
                "isGuildMember": isGuildMember
            ]
            let payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
            let payload = base64URLEncode(payloadData)
            let key = SymmetricKey(data: Data(secret.utf8))
            let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
            let signature = mac.map { String(format: "%02x", $0) }.joined()

            guard var components = URLComponents(string: returnURL) else {
                return oauthErrorPageResponse(
                    status: "500 Internal Server Error",
                    title: "Something went wrong",
                    message: "We couldn't build the return address.",
                    detail: "Try signing in again."
                )
            }
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "sso" || $0.name == "sig" }
            items.append(URLQueryItem(name: "sso", value: payload))
            items.append(URLQueryItem(name: "sig", value: signature))
            components.queryItems = items
            guard let destination = components.url?.absoluteString else {
                return oauthErrorPageResponse(
                    status: "500 Internal Server Error",
                    title: "Something went wrong",
                    message: "We couldn't build the return address.",
                    detail: "Try signing in again."
                )
            }

            await logger?("Companion SSO issued for \(user.username) (\(user.id)) → \(returnHost)")
            audit(source: "Web Auth", actor: "\(user.username) (\(user.id))", action: "Companion SSO issued", detail: returnHost, level: "ok")
            return redirectResponse(to: destination)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await logger?("Companion SSO failed: \(message)")
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
            headers: [
                "Set-Cookie": cookieHeader(
                    name: "swiftbot_admin_session",
                    value: "",
                    maxAge: 0,
                    secure: isHTTPSRequest(request)
                )
            ]
        )
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
            "passkeysEnabled": passkeyOrigin() != nil,
            "discordEnabled": discordConfigured,
            "localEnabled": localEnabled && devFeaturesEnabled,
            "devFeaturesEnabled": devFeaturesEnabled,
            "botName": botName,
            "botAvatarURL": botAvatarURL,
            // Just up or not: nothing about servers or members before sign-in.
            "botOnline": status?.botStatus == "running"
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

        return nil
    }

    /// Session was bound to a UA at login — reject if it changed. A session with
    /// no recorded UA (the browser sent none) isn't bound.
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

    /// Signs out Discord sessions the allow-list no longer covers, so removing
    /// someone takes effect immediately rather than when their session expires.
    /// Local fallback sessions (`local:`) never go through the list.
    private func revokeSessionsOutsideAllowList(previous: [String]) {
        let allowed = Set(config.allowedUserIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !allowed.isEmpty, allowed != Set(previous) else { return }
        let revoked = sessions.values.filter { $0.role != .member && !$0.userID.hasPrefix("local:") && !allowed.contains($0.userID) }
        guard !revoked.isEmpty else { return }
        for session in revoked {
            sessions[session.id] = nil
            audit(source: "Web Auth", actor: "\(session.username) (\(session.userID))", action: "Signed out", detail: "Removed from the access list", level: "warning")
        }
        persistSessions()
    }

    private func isAuthorized(userID: String, guilds: [DiscordGuildSummary]) async -> Bool {
        // A non-empty list is a strict allow-list: only the listed people get
        // in, server managers included. The list only reaches here when
        // "Only allow specific people" is on (see configureAdminWebServer).
        let allowed = config.allowedUserIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !allowed.isEmpty {
            return allowed.contains(userID)
        }

        let connectedGuildIDs = await connectedGuildIDsProvider?() ?? []
        guard Self.isMemberOfConnectedGuild(guilds: guilds, connectedGuildIDs: connectedGuildIDs) else { return false }
        return guilds.contains { guild in
            guard connectedGuildIDs.contains(guild.id) else { return false }
            if guild.owner == true { return true }
            guard let raw = guild.permissions, let permissions = UInt64(raw) else { return false }
            let administratorBit: UInt64 = 1 << 3
            let manageGuildBit: UInt64 = 1 << 5
            return (permissions & administratorBit) != 0 || (permissions & manageGuildBit) != 0
        }
    }

    /// Signs a server member in to the member view. No 2FA requirement:
    /// members only ever see their own Replay and clips.
    private func startMemberSession(user: DiscordUser, guildIDs: [String], request: HTTPRequest, pendingState: PendingState) async -> Data {
        var session = Session(
            id: randomToken(),
            userID: user.id,
            username: user.username,
            globalName: user.globalName,
            discriminator: user.discriminator,
            avatar: user.avatar,
            csrfToken: randomToken(),
            expiresAt: Date().addingTimeInterval(sessionTTL),
            userAgentHash: userAgentHash(for: request),
            role: .member
        )
        session.guildIDs = guildIDs
        sessions[session.id] = session
        persistSessions()
        await logger?("Web UI member sign-in for \(user.username) (\(user.id))")
        audit(source: "Web Auth", actor: "\(user.username) (\(user.id))", action: "Member signed in", detail: "\(guildIDs.count) server\(guildIDs.count == 1 ? "" : "s")", level: "ok")
        return redirectResponse(to: "/", headers: ["Set-Cookie": sessionCookie(for: session.id, secure: isHTTPSRequest(request))])
    }

    private func isMemberOfConnectedGuild(guilds: [DiscordGuildSummary]) async -> Bool {
        let connectedGuildIDs = await connectedGuildIDsProvider?() ?? []
        return Self.isMemberOfConnectedGuild(guilds: guilds, connectedGuildIDs: connectedGuildIDs)
    }

    private static func isMemberOfConnectedGuild(guilds: [DiscordGuildSummary], connectedGuildIDs: Set<String>) -> Bool {
        guard !connectedGuildIDs.isEmpty else { return false }
        return guilds.contains { connectedGuildIDs.contains($0.id) }
    }

    private struct DiscordToken {
        let accessToken: String
        let refreshToken: String?
    }

    private func exchangeDiscordCode(code: String, codeVerifier: String?) async throws -> DiscordToken {
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

        let (data, response) = try await oauthURLSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.tokenExchangeFailed((response as? HTTPURLResponse)?.statusCode ?? -1, "Discord rejected the token exchange.")
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = object["access_token"] as? String,
            !accessToken.isEmpty
        else {
            throw OAuthError.tokenExchangeFailed(http.statusCode, "Discord returned an invalid token response.")
        }

        return DiscordToken(accessToken: accessToken, refreshToken: object["refresh_token"] as? String)
    }

    private func fetchDiscordUser(accessToken: String) async throws -> DiscordUser {
        guard let url = URL(string: "https://discord.com/api/users/@me") else {
            throw OAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await oauthURLSession.data(for: request)
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

        let (data, response) = try await oauthURLSession.data(for: request)
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

    /// Scheme, host and port of a URL: `url` for building links, `host` as a
    /// browser sends it in the Host header (port included unless default).
    static func origin(of rawURL: String) -> (url: String, host: String)? {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let isDefaultPort = components.port == nil
            || (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        let hostHeader = isDefaultPort ? host : "\(host):\(components.port!)"
        return ("\(scheme)://\(hostHeader)", hostHeader)
    }

    /// Whether a request arrived through the public Cloudflare tunnel rather
    /// than from this Mac or the local network. Cloudflare adds these headers
    /// to every tunnelled request and visitors can't remove them; someone on
    /// the LAN adding them only locks themselves out.
    private func isPublicTunnelRequest(_ request: HTTPRequest) -> Bool {
        if request.headers["cf-connecting-ip"] != nil || request.headers["cf-ray"] != nil { return true }
        guard let publicHost = passkeyOrigin().flatMap({ Self.origin(of: $0)?.host }),
              let requestHost = request.headers["host"]?.lowercased() else { return false }
        return requestHost == publicHost
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

    func setHostOperations(
        run: @escaping @Sendable (AdminWebHostOperation) async -> String?,
        permissions: @escaping @Sendable () async -> AdminWebBotPermissionsPayload,
        updates: @escaping @Sendable () async -> AdminWebUpdatesPayload?
    ) {
        hostOperationRunner = run
        botPermissionsProvider = permissions
        updatesProvider = updates
    }

    static let hostOperationPaths: Set<String> = [
        "/api/bot/start", "/api/bot/stop", "/api/bot/restart",
        "/api/announcer/test", "/api/announcer/reconnect",
        "/api/welcome-flow/test", "/api/welcome-flow/invites/refresh",
        "/api/sweep/draft/test-mvp",
        "/api/updates/check", "/api/updates/install", "/api/updates/settings",
        "/api/cache/clear", "/api/activity/clear", "/api/bot/permissions/force-rejoin"
    ]

    /// `GET /api/bot/permissions` and `GET /api/updates`.
    private func handleHostSnapshot(_ request: HTTPRequest) async -> Data {
        guard let session = authenticatedSession(for: request) else { return unauthorizedResponse() }
        guard requireRole(.admin, session: session) else { return forbiddenResponse() }
        if request.path == "/api/bot/permissions" {
            guard let provider = botPermissionsProvider else {
                return jsonResponse(["error": "unavailable"], status: "503 Service Unavailable")
            }
            return codableResponse(await provider())
        }
        guard let payload = await updatesProvider?() else {
            return jsonResponse(["error": "unavailable", "message": "Software updates aren’t available yet. Open SwiftBot on the Mac once."], status: "503 Service Unavailable")
        }
        return codableResponse(payload)
    }

    private func handleHostOperation(_ request: HTTPRequest) async -> Data {
        guard let session = authenticatedSession(for: request) else { return unauthorizedResponse() }
        guard requireRole(.admin, session: session) else { return forbiddenResponse() }
        guard validateCSRF(session: session, request: request) else {
            return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
        }

        let operation: AdminWebHostOperation
        let auditAction: String?
        switch request.path {
        case "/api/bot/start": (operation, auditAction) = (.startBot, "Started the bot")
        case "/api/bot/stop": (operation, auditAction) = (.stopBot, "Stopped the bot")
        case "/api/bot/restart": (operation, auditAction) = (.restartBot, "Restarted the bot")
        case "/api/announcer/test": (operation, auditAction) = (.announcerTest, nil)
        case "/api/announcer/reconnect": (operation, auditAction) = (.announcerReconnect, "Reconnected the announcer")
        case "/api/welcome-flow/test": (operation, auditAction) = (.welcomeTest, "Sent a test welcome")
        case "/api/welcome-flow/invites/refresh": (operation, auditAction) = (.refreshWelcomeInvites, nil)
        case "/api/sweep/draft/test-mvp":
            guard let policy = try? apiDecoder.decode(SweepPolicy.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            (operation, auditAction) = (.sweepTestMVP(policy), "Sent a test weekly MVP")
        case "/api/updates/check": (operation, auditAction) = (.checkForUpdates, nil)
        case "/api/updates/install": (operation, auditAction) = (.installUpdate, "Installed a software update")
        case "/api/updates/settings":
            guard let patch = try? apiDecoder.decode(AdminWebUpdatesSettingsPatch.self, from: request.body),
                  patch.automaticChecks != nil || patch.unattended != nil else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            if let automatic = patch.automaticChecks {
                (operation, auditAction) = (.setAutomaticUpdateChecks(automatic), "\(automatic ? "Turned on" : "Turned off") automatic update checks")
            } else {
                let unattended = patch.unattended ?? false
                (operation, auditAction) = (.setUnattendedUpdates(unattended), "\(unattended ? "Turned on" : "Turned off") unattended updates")
            }
        case "/api/cache/clear": (operation, auditAction) = (.clearCachedData, "Cleared cached server data")
        case "/api/activity/clear": (operation, auditAction) = (.clearActivity, "Cleared activity")
        case "/api/bot/permissions/force-rejoin":
            guard let body = try? apiDecoder.decode(AdminWebForceRejoinRequest.self, from: request.body),
                  !body.guildID.isEmpty, body.guildID.allSatisfy(\.isNumber) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            (operation, auditAction) = (.forceRejoin(guildID: body.guildID), "Removed SwiftBot from server \(body.guildID) to re-invite it")
        default:
            return jsonResponse(["error": "not_found"], status: "404 Not Found")
        }

        guard let runner = hostOperationRunner else {
            return jsonResponse(["error": "unavailable"], status: "503 Service Unavailable")
        }
        if let problem = await runner(operation) {
            return jsonResponse(["error": "failed", "message": problem], status: "409 Conflict")
        }
        if let auditAction {
            audit(source: "Web Config", actor: actorLabel(session), action: auditAction, level: "ok")
        }
        return jsonResponse(["ok": true])
    }

    /// Installs (or replaces) the structured audit-log sink. Hooks AppModel's
    /// `recordAudit(...)` to the web server's auth/config events.
    func setAutomationSimulator(_ simulator: @escaping @Sendable (AdminWebAutomationSimulationRequest) async -> AdminWebAutomationSimulationPayload?) {
        automationSimulator = simulator
    }

    func setActivityReportProvider(_ provider: @escaping @Sendable () async -> String) {
        activityReportProvider = provider
    }

    func setGameProviderCredentialUpdater(_ updater: @escaping @Sendable (String, String?) async -> String) {
        self.gameProviderCredentialUpdater = updater
    }

    /// Extra checks for routes that write or hand out a secret: an encrypted
    /// connection (or a loopback peer) and a sign-in within the last 15
    /// minutes. Returns the refusal, or nil when the request may proceed.
    private func sensitiveSecretRefusal(session: Session, request: HTTPRequest, purpose: String) -> Data? {
        guard activeTransportUsesTLS || Self.isLoopbackPeer(request.peerIP) else {
            return jsonResponse([
                "error": "insecure_transport",
                "message": "Open the WebUI over https to \(purpose). Over plain http the secret could be read by anyone on the network."
            ], status: "400 Bad Request")
        }
        let signedInAt = session.expiresAt.addingTimeInterval(-sessionTTL)
        guard Date().timeIntervalSince(signedInAt) <= credentialReauthWindow else {
            return jsonResponse([
                "error": "reauth_required",
                "message": "For security, sign out and back in to \(purpose). You signed in more than 15 minutes ago."
            ], status: "401 Unauthorized")
        }
        return nil
    }

    /// `POST /api/gametracker/credential`. Write-only: a stolen session can
    /// replace or remove a key but never read one. On top of the usual admin
    /// and CSRF checks it needs a recent sign-in and an encrypted connection.
    private func handleGameProviderCredential(_ request: HTTPRequest) async -> Data {
        guard let session = authenticatedSession(for: request) else {
            return unauthorizedResponse()
        }
        guard requireRole(.admin, session: session) else {
            return forbiddenResponse()
        }
        guard validateCSRF(session: session, request: request) else {
            return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
        }
        if let refusal = sensitiveSecretRefusal(session: session, request: request, purpose: "change API keys") {
            return refusal
        }
        guard let update = try? apiDecoder.decode(AdminWebGameProviderCredentialUpdate.self, from: request.body),
              let providerID = GameProviderID(rawValue: update.provider) else {
            return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
        }
        let removing = update.remove == true
        guard removing || !(update.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return jsonResponse(["error": "invalid_payload", "message": "Paste a key, or remove the current one."], status: "400 Bad Request")
        }
        guard let updater = gameProviderCredentialUpdater else {
            return jsonResponse(["error": "unavailable"], status: "503 Service Unavailable")
        }

        let result = await updater(providerID.rawValue, removing ? nil : update.token)
        let label = "\(providerID.displayName) \(GameProviderCatalog.descriptor(for: providerID)?.auth.credentialLabel ?? "credential")"
        switch result {
        case GameProviderCredentialResult.saved.rawValue:
            audit(source: "Web Config", actor: actorLabel(session), action: removing ? "Removed \(label)" : "Replaced \(label)", level: "ok")
            return jsonResponse(["ok": true])
        case GameProviderCredentialResult.rejected.rawValue:
            audit(source: "Web Config", actor: actorLabel(session), action: "Tried a \(label) that was rejected", level: "warning")
            return jsonResponse(["error": "rejected", "message": "\(providerID.displayName) didn’t accept that key. Nothing was changed."], status: "400 Bad Request")
        case GameProviderCredentialResult.unreachable.rawValue:
            return jsonResponse(["error": "unreachable", "message": "Couldn’t reach \(providerID.displayName) to check the key, so it wasn’t saved. Try again in a minute."], status: "502 Bad Gateway")
        case GameProviderCredentialResult.misconfigured.rawValue:
            return jsonResponse(["error": "misconfigured", "message": "\(providerID.displayName)’s API address is set up wrong. Fix it under Integrations in the SwiftBot app on the Mac."], status: "400 Bad Request")
        default:
            return jsonResponse(["error": "invalid_payload", "message": "That doesn’t look like a valid key."], status: "400 Bad Request")
        }
    }

    /// Loopback peers: a local browser, or a tunnel (cloudflared) on the same
    /// Mac that has already terminated TLS.
    nonisolated static func isLoopbackPeer(_ peerIP: String?) -> Bool {
        guard var address = peerIP?.lowercased() else { return false }
        if let scope = address.firstIndex(of: "%") { address = String(address[..<scope]) }
        return address == "127.0.0.1" || address == "::1" || address == "::ffff:127.0.0.1" || address.hasPrefix("127.")
    }

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
        var diff = UInt(a.count ^ b.count)
        for i in 0..<Swift.max(a.count, b.count) {
            let lb = i < a.count ? a[i] : 0
            let rb = i < b.count ? b[i] : 0
            diff |= UInt(lb ^ rb)
        }
        return diff == 0
    }

    /// Nonisolated copy of the check `AppModel` exposes on the main actor, so it
    /// can be read from this actor's own executor. `Persistence` keeps one for the
    /// same reason.
    private static let isRunningUnderXCTest: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil

    private func serverSigningKey() -> SymmetricKey {
        if let cached = cachedSigningKey { return cached }
        // Under XCTest, stay off the Keychain entirely: the real one is slow to
        // reach from an ad-hoc-signed test host and writing to it would leave
        // per-run junk in the developer's login keychain. An ephemeral key is
        // sufficient — nothing in a test run needs a token to survive the
        // process. `Persistence` redirects its storage the same way.
        if Self.isRunningUnderXCTest {
            let key = SymmetricKey(size: .bits256)
            cachedSigningKey = key
            return key
        }
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

    private func sessionCookie(for sessionID: String, secure: Bool) -> String {
        cookieHeader(
            name: "swiftbot_admin_session",
            value: sessionID,
            maxAge: Int(sessionTTL),
            secure: secure
        )
    }

    private func cookieHeader(name: String, value: String, maxAge: Int, secure: Bool) -> String {
        "\(name)=\(value); Path=/; Max-Age=\(maxAge); HttpOnly\(secure ? "; Secure" : ""); SameSite=Lax"
    }

    /// Whether the browser reached us over HTTPS: TLS terminated here, or by
    /// a tunnel on this Mac (cloudflared) that says so. Only a loopback peer
    /// is trusted to set X-Forwarded-Proto. Plain-HTTP LAN visits get cookies
    /// without Secure, which browsers would otherwise refuse to store.
    private func isHTTPSRequest(_ request: HTTPRequest) -> Bool {
        if activeTransportUsesTLS { return true }
        guard Self.isLoopbackPeer(request.peerIP) else { return false }
        return request.headers["x-forwarded-proto"]?.lowercased() == "https"
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
        guard persistAuthenticationState else { return }
        if sessions.isEmpty {
            KeychainHelper.delete(account: sessionsKeychainAccount)
            return
        }
        guard let data = try? encoder.encode(sessions),
              let serialized = String(data: data, encoding: .utf8) else { return }
        KeychainHelper.save(serialized, account: sessionsKeychainAccount)
    }

    private func rewindResponse(_ result: AdminWebRewindResult) -> Data {
        switch result {
        case .replay(let value): return codableResponse(value)
        case .member(let value): return codableResponse(value)
        case .phrase(let value): return codableResponse(value)
        case .recaps(let value): return codableResponse(value)
        case .recipients(let count): return jsonResponse(["count": count])
        case .ok: return jsonResponse(["ok": true])
        case .failure(let code): return jsonResponse(["error": code], status: "400 Bad Request")
        }
    }

    private func codableResponse<T: Encodable>(_ value: T) -> Data {
        let body = (try? apiEncoder.encode(value)) ?? Data("{}".utf8)
        return httpResponse(status: "200 OK", body: body, contentType: "application/json; charset=utf-8")
    }

    private func jsonResponse(_ object: [String: Any], status: String = "200 OK", headers: [String: String] = [:]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return httpResponse(status: status, body: data, contentType: "application/json; charset=utf-8", headers: headers)
    }

    private func cachedAnalytics(period: AnalyticsPeriod, includeMessageText: Bool) async -> AdminWebAnalyticsPayload {
        let key = AnalyticsCacheKey(period: period, includeMessageText: includeMessageText)
        if let cached = analyticsCache[key], Date().timeIntervalSince(cached.builtAt) < Self.analyticsCacheLifetime {
            return cached.payload
        }
        if let pending = analyticsInFlight[key] {
            return await pending.value
        }
        guard let provider = analyticsProvider else { return .empty }
        let build = Task { await provider(period, includeMessageText) }
        analyticsInFlight[key] = build
        let payload = await build.value
        analyticsInFlight[key] = nil
        analyticsCache[key] = (payload, Date())
        return payload
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
        case liveOnline
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
        let isLiveOnline = (variant == .liveOnline)
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
        } else if isLiveOnline {
            // Approval / good / online glyphs for the public /live page.
            icons = [
                // Check in circle
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><polyline points="9 12 11 14 15 10"/></svg>"#,
                // Bare checkmark
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>"#,
                // Shield with check (approved)
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 4 6v6c0 5 3.5 8.5 8 10 4.5-1.5 8-5 8-10V6l-8-3z"/><polyline points="9 12 11 14 15 10"/></svg>"#,
                // Badge / award
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="9" r="6"/><polyline points="8.21 13.89 7 22 12 19 17 22 15.79 13.88"/></svg>"#,
                // Thumbs up
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M7 10v12"/><path d="M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H7V10l4.7-7.4a1.5 1.5 0 0 1 2.6 1.4l-.3 1.88z"/></svg>"#,
                // Heart (alive / healthy)
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>"#,
                // Sparkles
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v4M12 17v4M3 12h4M17 12h4M5.6 5.6l2.8 2.8M15.6 15.6l2.8 2.8M5.6 18.4l2.8-2.8M15.6 8.4l2.8-2.8"/></svg>"#,
                // Signal/wifi waves
                #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.55a11 11 0 0 1 14 0"/><path d="M2 8.82a15 15 0 0 1 20 0"/><path d="M8.5 16.43a6 6 0 0 1 7 0"/><circle cx="12" cy="20" r="1"/></svg>"#
            ]
            // Green / mint palette — universally "good".
            palette = ["#22c55e", "#16a34a", "#4ade80", "#34d399", "#10b981", "#86efac", "#15803d"]
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

    /// A HEAD reply: the GET response's status and headers (Content-Length
    /// included) without its body.
    private func headersOnly(_ response: Data) -> Data {
        guard let end = response.range(of: Data("\r\n\r\n".utf8)) else { return response }
        return response.subdata(in: response.startIndex..<end.upperBound)
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
        // Behind a TLS-terminating tunnel (cloudflared) this server speaks
        // plain HTTP, but the public address is HTTPS. Browsers ignore HSTS
        // received over plain HTTP, so LAN access is unaffected.
        let servedOverHTTPS = activeTransportUsesTLS || activePublicBaseURL.lowercased().hasPrefix("https://")
        if servedOverHTTPS, normalizedHeaders["strict-transport-security"] == nil {
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

    private struct SendableContext: @unchecked Sendable {
        let value: ChannelHandlerContext
    }

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

        let contextBox = SendableContext(value: context)
        let eventLoop = context.eventLoop
        let processor = processor
        processorTask = Task { [weak self] in
            let response = await processor(requestData)
            let serverRequestedClose = Self.responseRequestsClose(response)
            eventLoop.execute { [weak self] in
                guard let handler = self else { return }
                handler.writeResponse(
                    response,
                    context: contextBox.value,
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

#if DEBUG
// MARK: - Test Seam
//
// The auth surface (sessions, CSRF, user-agent binding, role gating, media
// access tokens, login lockout) is reachable only through `process`, and every
// piece of state it reads is `private`. These hooks live in this file because
// Swift scopes `private` to the enclosing file — an extension anywhere else
// could not see them. They deliberately expose behaviour rather than internals:
// tests drive real HTTP bytes through the real router and assert on real
// responses, so they keep holding after a refactor of anything behind them.
extension AdminWebServer {
    func testSetSwiftMeshJoinCodeProvider(_ provider: @escaping @Sendable () async -> String?) {
        swiftMeshJoinCodeProvider = provider
    }

    /// Inserts a ready-made admin session and returns the values a client would
    /// need to use it. `userAgent` nil leaves the session unbound, matching a
    /// client that sent no UA header.
    func testSeedSession(
        userAgent: String? = nil,
        expiresIn: TimeInterval = 3_600,
        viewerRole: Bool = false,
        memberRole: Bool = false,
        userID: String = "1234567890"
    ) -> (id: String, csrf: String) {
        let session = Session(
            id: randomToken(),
            userID: userID,
            username: "audit-fixture",
            globalName: "Audit Fixture",
            discriminator: nil,
            avatar: nil,
            csrfToken: randomToken(),
            expiresAt: Date().addingTimeInterval(expiresIn),
            userAgentHash: userAgent.map { sha256Hex($0) },
            role: memberRole ? .member : viewerRole ? .viewer : .admin
        )
        sessions[session.id] = session
        return (session.id, session.csrfToken)
    }

    /// Feeds raw request bytes through the same entry point the NIO and Network
    /// listeners use, and hands back the raw response bytes.
    func testProcessRequest(_ raw: Data, peerIP: String? = nil) async -> Data {
        await process(raw, peerIP: peerIP)
    }

    /// Mints a media access token exactly as `GET /api/media/access-token` does.
    func testMintMediaAccessToken(sessionID: String) -> String {
        mintMediaAccessToken(sessionID: sessionID).token
    }

    /// Drops a session from the store without waiting for its TTL, standing in
    /// for logout or eviction.
    func testRevokeSession(_ sessionID: String) {
        sessions.removeValue(forKey: sessionID)
    }

    /// Records `count` failed local logins for one IP/username pair and reports
    /// whether the bucket ended up locked.
    func testRegisterFailedLogins(count: Int, peerIP: String, username: String) -> Bool {
        let attemptKey = "\(peerIP)|\(username.lowercased())"
        var bucket = localLoginAttempts[attemptKey] ?? RateLimitBucket()
        for _ in 0..<count {
            registerFailedAttempt(&bucket, threshold: loginFailureThreshold)
        }
        localLoginAttempts[attemptKey] = bucket
        return isBucketLocked(bucket)
    }
}
#endif

// MARK: - Optional Discord-linked WebAuthn passkeys

extension AdminWebServer {
    private struct PasskeyRecord: Codable {
        let id: String
        let userID: String
        let userHandle: [UInt8]
        let origin: String
        let publicKey: [UInt8]
        var signCount: UInt32
        let name: String
        let createdAt: Date
    }

    private struct PasskeyState: Codable {
        var credentials: [String: PasskeyRecord] = [:]
        var refreshTokens: [String: String] = [:]
    }

    private struct PasskeyChallenge {
        let bytes: [UInt8]
        let origin: String
        let expiresAt: Date
        let sessionID: String?
        let browserHash: String
        let name: String
    }

    private struct PasskeyFinish<T: Decodable>: Decodable {
        let ceremony: String
        let credential: T
    }

    private enum PasskeyError: Error, Equatable { case invalid, storage, authorization }
    private var passkeyKeychainAccount: String { "swiftbot.admin.web.passkeys" }

    /// Use only the explicitly configured HTTPS origin; never trust Host or
    /// forwarded headers to choose a relying party. Credentials are node-local.
    private func passkeyOrigin() -> String? {
        guard let url = URLComponents(string: config.publicBaseURL),
            url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
            !host.isEmpty, !host.contains(":"), url.user == nil, url.password == nil,
            host != "localhost", host != "127.0.0.1", !host.hasSuffix(".local"),
            host.contains(where: { $0.isLetter }),
            url.query == nil, url.fragment == nil
        else { return nil }
        return "https://\(host)" + (url.port.map { $0 == 443 ? "" : ":\($0)" } ?? "")
    }

    private func passkeyManager(origin: String) -> WebAuthnManager {
        WebAuthnManager(
            configuration: .init(
                relyingPartyID: URL(string: origin)!.host!,
                relyingPartyName: "SwiftBot",
                relyingPartyOrigin: origin
            ))
    }

    private func loadPasskeys() {
        guard let stored = KeychainHelper.load(account: passkeyKeychainAccount),
            let data = stored.data(using: .utf8),
            let state = try? decoder.decode(PasskeyState.self, from: data)
        else { return }
        passkeyState = state
    }

    /// Persist before reporting success, so a Keychain failure cannot silently
    /// lose a newly enrolled credential or a rotated Discord refresh token.
    private func savePasskeys(_ state: PasskeyState) throws {
        guard persistAuthenticationState else {
            passkeyState = state
            return
        }
        let data = try encoder.encode(state)
        // Update in place: delete-then-add would lose every passkey if the
        // replacement failed while the Keychain was locked or unavailable.
        guard KeychainHelper.update(data, account: passkeyKeychainAccount) else { throw PasskeyError.storage }
        passkeyState = state
    }

    private func passkeyBrowserHash(_ request: HTTPRequest) -> String {
        sha256Hex(request.headers["user-agent"] ?? "")
    }

    private func takePasskeyChallenge(_ id: String, request: HTTPRequest, origin: String, sessionID: String?) throws -> PasskeyChallenge {
        guard let challenge = passkeyChallenges.removeValue(forKey: id),
            challenge.expiresAt > Date(), challenge.origin == origin,
            challenge.sessionID == sessionID,
            challenge.browserHash == passkeyBrowserHash(request),
            constantTimeEquals(cookie(named: "swiftbot_passkey_ceremony", request: request) ?? "", id)
        else {
            throw PasskeyError.invalid
        }
        return challenge
    }

    private func passkeyOptions<T: Encodable>(_ options: T, bytes: [UInt8], request: HTTPRequest, origin: String, session: Session?, name: String = "Passkey") throws -> Data {
        let id = randomToken()
        passkeyChallenges[id] = PasskeyChallenge(
            bytes: bytes, origin: origin,
            expiresAt: Date().addingTimeInterval(120), sessionID: session?.id,
            browserHash: passkeyBrowserHash(request), name: name)
        let object = try JSONSerialization.jsonObject(with: encoder.encode(options))
        return jsonResponse(
            ["ceremony": id, "publicKey": object],
            headers: [
                "Set-Cookie": "swiftbot_passkey_ceremony=\(id); Path=/auth/passkeys/; Max-Age=120; HttpOnly; Secure; SameSite=Strict",
                "Cache-Control": "no-store",
            ])
    }

    /// The verifier checks challenge/type/origin. Explicitly reject framed
    /// ceremonies as the library currently does not validate crossOrigin.
    private func validatePasskeyClientData(_ bytes: [UInt8]) throws {
        guard let data = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
            data["crossOrigin"] == nil || (data["crossOrigin"] as? Bool) == false,
            data["topOrigin"] == nil
        else { throw PasskeyError.invalid }
    }

    private func handlePasskeys(request: HTTPRequest) async -> Data {
        guard let origin = passkeyOrigin() else {
            return jsonResponse(["error": "passkeys_unavailable", "message": "Open SwiftBot at its configured HTTPS address to use passkeys."], status: "400 Bad Request")
        }
        if let status = await statusProvider?(), status.isFailoverManagedNode {
            return jsonResponse(["error": "passkeys_unavailable", "message": "Use the Primary node to manage and use passkeys."], status: "409 Conflict")
        }
        guard request.method == "GET" || (request.headers["origin"] == origin && (activeTransportUsesTLS || Self.isLoopbackPeer(request.peerIP))) else {
            return forbiddenResponse()
        }
        let session = authenticatedSession(for: request)
        let managing = !request.path.hasPrefix("/auth/passkeys/login/")
        if managing {
            guard let session, session.role == .admin, !session.userID.hasPrefix("local:") else { return forbiddenResponse() }
            if request.method != "GET", !validateCSRF(session: session, request: request) { return forbiddenResponse() }
        }
        passkeyChallenges = passkeyChallenges.filter { $0.value.expiresAt > Date() }
        // Bound anonymous challenge allocation and expensive verification work.
        passkeyRequestBuckets = passkeyRequestBuckets.mapValues { $0.filter { Date().timeIntervalSince($0) < 60 } }.filter { !$0.value.isEmpty }
        if request.method != "GET" {
            let bucket = request.peerIP ?? "unknown"
            guard (passkeyRequestBuckets[bucket]?.count ?? 0) < 20,
                passkeyChallenges.count < 500, passkeyRequestBuckets.count < 1000
            else {
                return jsonResponse(["error": "rate_limited"], status: "429 Too Many Requests")
            }
            passkeyRequestBuckets[bucket, default: []].append(Date())
        }
        let manager = passkeyManager(origin: origin)
        do {
            switch (request.method, request.path) {
            case ("GET", "/auth/passkeys/list"):
                let records = passkeyState.credentials.values.filter { $0.userID == session!.userID && $0.origin == origin }
                return jsonResponse(
                    [
                        "credentials": records.sorted { $0.createdAt < $1.createdAt }.map {
                            ["id": $0.id, "name": $0.name, "createdAt": ISO8601DateFormatter().string(from: $0.createdAt)]
                        }
                    ], headers: ["Cache-Control": "no-store"])
            case ("POST", "/auth/passkeys/register/options"):
                let session = session!
                guard session.signInMethod != "passkey", session.discordRefreshToken != nil,
                    Date().timeIntervalSince(session.expiresAt.addingTimeInterval(-sessionTTL)) <= 300
                else {
                    return jsonResponse(["error": "reauth_required", "message": "Sign in with Discord again before adding a passkey."], status: "401 Unauthorized")
                }
                guard passkeyState.credentials.values.filter({ $0.userID == session.userID }).count < 10 else { throw PasskeyError.invalid }
                let input = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
                let name = String((input?["name"] as? String ?? "Passkey").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                let options = manager.beginRegistration(
                    user: .init(id: Array(session.userID.utf8), name: session.username, displayName: session.globalName ?? session.username),
                    timeout: .seconds(120), authenticatorSelection: .init(residentKey: .required, userVerification: .required))
                return try passkeyOptions(options, bytes: options.challenge, request: request, origin: origin, session: session, name: name.isEmpty ? "Passkey" : name)
            case ("POST", "/auth/passkeys/register/finish"):
                let session = session!
                guard session.signInMethod != "passkey", let refreshToken = session.discordRefreshToken,
                    Date().timeIntervalSince(session.expiresAt.addingTimeInterval(-sessionTTL)) <= 300
                else { throw PasskeyError.authorization }
                let input = try decoder.decode(PasskeyFinish<RegistrationCredential>.self, from: request.body)
                let challenge = try takePasskeyChallenge(input.ceremony, request: request, origin: origin, sessionID: session.id)
                try validatePasskeyClientData(input.credential.attestationResponse.clientDataJSON)
                guard input.credential.id.asString() == base64URLEncode(Data(input.credential.rawID)) else { throw PasskeyError.invalid }
                let credential = try await manager.finishRegistration(
                    challenge: challenge.bytes, credentialCreationData: input.credential,
                    requireUserVerification: true, confirmCredentialIDNotRegisteredYet: { _ in true })
                // Recheck after the verifier's suspension point, including revocation.
                guard authenticatedSession(for: request)?.id == session.id, passkeyOrigin() == origin,
                    passkeyState.credentials[input.credential.id.asString()] == nil,
                    passkeyState.credentials.values.filter({ $0.userID == session.userID }).count < 10
                else { throw PasskeyError.invalid }
                var state = passkeyState
                let id = base64URLEncode(Data(input.credential.rawID))
                state.credentials[id] = PasskeyRecord(
                    id: id, userID: session.userID, userHandle: Array(session.userID.utf8), origin: origin,
                    publicKey: credential.publicKey, signCount: credential.signCount, name: challenge.name, createdAt: Date())
                state.refreshTokens[session.userID] = state.refreshTokens[session.userID] ?? refreshToken
                try savePasskeys(state)
                audit(source: "Web Auth", actor: actorLabel(session), action: "Passkey added", detail: challenge.name, level: "ok")
                return jsonResponse(["ok": true])
            case ("POST", "/auth/passkeys/remove"):
                guard let input = try JSONSerialization.jsonObject(with: request.body) as? [String: String],
                    let id = input["id"], let record = passkeyState.credentials[id], record.userID == session!.userID
                else { throw PasskeyError.invalid }
                var state = passkeyState
                state.credentials[id] = nil
                if !state.credentials.values.contains(where: { $0.userID == record.userID }) { state.refreshTokens[record.userID] = nil }
                try savePasskeys(state)
                // Revocation also ends existing passkey sessions for this account.
                sessions = sessions.filter { $0.value.userID != record.userID || $0.value.signInMethod != "passkey" }
                persistSessions()
                audit(source: "Web Auth", actor: actorLabel(session!), action: "Passkey removed", detail: record.name, level: "ok")
                return jsonResponse(["ok": true])
            case ("POST", "/auth/passkeys/login/options"):
                let options = manager.beginAuthentication(timeout: .seconds(120), userVerification: .required)
                return try passkeyOptions(options, bytes: options.challenge, request: request, origin: origin, session: nil)
            case ("POST", "/auth/passkeys/login/finish"):
                let input = try decoder.decode(PasskeyFinish<AuthenticationCredential>.self, from: request.body)
                let challenge = try takePasskeyChallenge(input.ceremony, request: request, origin: origin, sessionID: nil)
                let id = base64URLEncode(Data(input.credential.rawID))
                guard input.credential.id.asString() == id, let record = passkeyState.credentials[id], record.origin == origin,
                    input.credential.response.userHandle == record.userHandle,
                    let refreshToken = passkeyState.refreshTokens[record.userID],
                    passkeyUsersInFlight.insert(record.userID).inserted
                else { throw PasskeyError.invalid }
                defer { passkeyUsersInFlight.remove(record.userID) }
                try validatePasskeyClientData(input.credential.response.clientDataJSON)
                let verified = try manager.finishAuthentication(
                    credential: input.credential, expectedChallenge: challenge.bytes,
                    credentialPublicKey: record.publicKey, credentialCurrentSignCount: record.signCount, requireUserVerification: true)
                let token = try await refreshPasskeyDiscordToken(refreshToken)
                // Persist rotation even if subsequent authorization fails.
                guard passkeyState.credentials[id]?.publicKey == record.publicKey else { throw PasskeyError.invalid }
                var state = passkeyState
                state.refreshTokens[record.userID] = token.refreshToken ?? refreshToken
                state.credentials[id]?.signCount = verified.newSignCount
                try savePasskeys(state)
                let user = try await fetchDiscordUser(accessToken: token.accessToken)
                let guilds = try await fetchDiscordGuilds(accessToken: token.accessToken)
                guard user.id == record.userID, user.mfaEnabled,
                    await isAuthorized(userID: user.id, guilds: guilds),
                    passkeyState.credentials[id]?.publicKey == record.publicKey,
                    passkeyOrigin() == origin
                else { throw PasskeyError.authorization }
                let session = Session(
                    id: randomToken(), userID: user.id, username: user.username, globalName: user.globalName,
                    discriminator: user.discriminator, avatar: user.avatar, csrfToken: randomToken(),
                    expiresAt: Date().addingTimeInterval(sessionTTL), userAgentHash: userAgentHash(for: request), role: .admin, signInMethod: "passkey")
                sessions[session.id] = session
                persistSessions()
                audit(source: "Web Auth", actor: actorLabel(session), action: "Logged in", detail: "Passkey", level: "ok")
                return jsonResponse(["ok": true], headers: ["Set-Cookie": sessionCookie(for: session.id, secure: true)])
            default:
                return httpResponse(status: "404 Not Found", body: Data())
            }
        } catch {
            audit(source: "Web Auth", actor: session.map { actorLabel($0) } ?? "Passkey sign-in", action: "Passkey request rejected", level: "warning")
            let storage = (error as? PasskeyError) == .storage
            let message =
                storage
                ? "Keychain storage is unavailable. Try again after unlocking your Mac."
                : "Couldn’t complete the passkey request. Try again or sign in with Discord."
            return jsonResponse(
                ["error": storage ? "storage_unavailable" : "passkey_failed", "message": message],
                status: storage ? "503 Service Unavailable" : "400 Bad Request")
        }
    }

    private func refreshPasskeyDiscordToken(_ refreshToken: String) async throws -> DiscordToken {
        var request = URLRequest(url: URL(string: "https://discord.com/api/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": config.discordOAuth.clientID, "client_secret": config.discordOAuth.clientSecret,
            "grant_type": "refresh_token", "refresh_token": refreshToken,
        ]
        request.httpBody = form.map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }.sorted().joined(separator: "&").data(using: .utf8)
        let (data, response) = try await oauthURLSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = object["access_token"] as? String, !accessToken.isEmpty
        else { throw PasskeyError.authorization }
        return DiscordToken(accessToken: accessToken, refreshToken: object["refresh_token"] as? String)
    }
}

extension AdminWebServer {
    /// Isolated HTTP fixtures exercise the real verifier without touching the
    /// user's Keychain or contacting Discord.
    func testConfigurePasskeys(origin: String, oauthSession: URLSession) -> (id: String, csrf: String) {
        config.publicBaseURL = origin
        config.allowedUserIDs = ["1234567890"]
        oauthURLSession = oauthSession
        persistAuthenticationState = false
        let session = Session(
            id: randomToken(), userID: "1234567890", username: "passkey-fixture", globalName: nil,
            discriminator: nil, avatar: nil, csrfToken: randomToken(), expiresAt: Date().addingTimeInterval(sessionTTL),
            discordRefreshToken: "fixture-refresh-token")
        sessions[session.id] = session
        return (session.id, session.csrfToken)
    }

    func testExpirePasskeyChallenges() {
        passkeyChallenges = passkeyChallenges.mapValues {
            PasskeyChallenge(bytes: $0.bytes, origin: $0.origin, expiresAt: .distantPast,
                             sessionID: $0.sessionID, browserHash: $0.browserHash, name: $0.name)
        }
    }
}

extension AdminWebServer {
    func testSetPasskeyAllowList(_ ids: [String]) {
        config.allowedUserIDs = ids
    }
}

extension AdminWebServer {
    /// Sign-in settings for tests, kept out of the Keychain.
    func testConfigureSignIn(
        publicBaseURL: String = "",
        discordClient: Bool = false,
        localPassword: String? = nil,
        devFeatures: Bool = false
    ) {
        persistAuthenticationState = false
        config.publicBaseURL = publicBaseURL
        if discordClient {
            config.discordOAuth = OAuthProviderSettings(enabled: true, clientID: "123", clientSecret: "fixture-secret")
        }
        if let localPassword {
            config.localAuthEnabled = true
            config.localAuthUsername = "admin"
            config.localAuthPassword = localPassword
        }
        config.devFeaturesEnabled = devFeatures
    }
}
