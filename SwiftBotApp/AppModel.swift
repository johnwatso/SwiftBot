import AppKit
import AVFoundation
import CryptoKit
import Foundation
import OSLog
import SwiftUI
import Darwin

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = BotSettings()
    @Published var status: BotStatus = .stopped {
        didSet {
            if status != oldValue {
                configurePatchyMonitoring()
            }
        }
    }
    @Published var stats = StatCounter()
    @Published var events: [ActivityEvent] = []
    @Published var commandLog: [CommandLogEntry] = []
    @Published var auditLog: [AuditLogEntry] = []
    private let auditLogCap = 500

    @Published var automationLog: [AutomationLogEntry] = []
    private let automationLogCap = 500

    /// Append an audit event. Capped at `auditLogCap` (oldest dropped). Safe to
    /// call from any actor; hops to the main actor for the publish.
    nonisolated func recordAudit(
        source: AuditLogEntry.Source,
        actor: String,
        action: String,
        detail: String? = nil,
        level: AuditLogEntry.Level = .info
    ) {
        let entry = AuditLogEntry(
            source: source,
            actor: actor,
            action: action,
            detail: detail,
            level: level
        )
        Task { @MainActor in
            self.auditLog.append(entry)
            if self.auditLog.count > self.auditLogCap {
                self.auditLog.removeFirst(self.auditLog.count - self.auditLogCap)
            }
            self.persistAnalyticsRuntime()
        }
    }

    nonisolated func recordAutomationRun(
        ruleId: String,
        ruleName: String,
        eventKind: String,
        triggerUser: String,
        stepsCount: Int,
        status: String
    ) {
        let entry = AutomationLogEntry(
            ruleId: ruleId,
            ruleName: ruleName,
            eventKind: eventKind,
            triggerUser: triggerUser,
            stepsCount: stepsCount,
            status: status
        )
        Task { @MainActor in
            self.automationLog.insert(entry, at: 0)
            if self.automationLog.count > self.automationLogCap {
                self.automationLog.removeLast(self.automationLog.count - self.automationLogCap)
            }
            self.persistAnalyticsRuntime()
        }
    }
    @Published var voiceLog: [VoiceEventLogEntry] = []
    @Published var messagesSpokenToday: Int = 0
    var lastSpokenDate: Date = Date()
    var autoDisconnectTask: Task<Void, Never>?
    @Published var activeVoice: [VoiceMemberPresence] = []
    @Published var uptime: UptimeInfo?
    @Published var connectedServers: [String: String] = [:]
    @Published var availableVoiceChannelsByServer: [String: [GuildVoiceChannel]] = [:]
    @Published var availableTextChannelsByServer: [String: [GuildTextChannel]] = [:]
    @Published var availableRolesByServer: [String: [GuildRole]] = [:]
    @Published var welcomeFlowInvitesByServer: [String: [WelcomeFlowService.InviteSnapshot]] = [:]
    @Published var knownUsersById: [String: String] = [:]
    @Published var knownBotUserIds: Set<String> = []
    @Published var knownGuildMemberIds: Set<String> = []
    @Published var gatewayEventCount = 0
    @Published var voiceStateEventCount = 0
    @Published var readyEventCount = 0
    @Published var guildCreateEventCount = 0
    @Published var lastGatewayEventName: String = "-"
    @Published var lastVoiceStateAt: Date?
    @Published var lastVoiceStateSummary: String = "-"
    @Published var clusterSnapshot = ClusterSnapshot()
    private var lastPublishedRole: ClusterMode?
    @Published var clusterNodes: [ClusterNodeStatus] = []
    /// Phase 4: seconds remaining until this node auto-reclaims Primary, or
    /// `nil` if auto-reclaim is disabled / not eligible. Refreshed by
    /// `pollClusterStatus()` on the regular mesh polling tick.
    @Published var autoReclaimRemainingSeconds: TimeInterval?
    @Published var workerConnectionTestStatus: String = "Not tested"
    @Published var workerConnectionTestIsSuccess = false
    @Published var workerConnectionTestInProgress = false
    @Published var workerConnectionTestOutcome: WorkerConnectionTestOutcome?
    @Published var lastClusterStatusRefreshAt: Date?
    @Published var appleIntelligenceOnline = false
    @Published var recentMediaCount24h = 0
    @Published var patchyDebugLogs: [String] = []
    @Published var patchyIsCycleRunning = false
    @Published var patchyLastCycleAt: Date?
    var patchyTargetValidationCache: [String: (isValid: Bool, detail: String, validatedAt: Date)] = [:]
    @Published var adminWebResolvedBaseURL: String = ""
    @Published var adminWebPublicAccessStatus = AdminWebPublicAccessRuntimeStatus()
    @Published var workerModeMigrated = false
    // MARK: - P0.4 Diagnostics state

    @Published var connectionDiagnostics = ConnectionDiagnostics()
    /// Date after which another Test Connection is allowed (10s UI rate limit).
    @Published var testConnectionCooldownUntil: Date?

    /// `true` once a valid token has been confirmed — gates the main dashboard.
    @Published var isOnboardingComplete: Bool = false

    // MARK: - View Mode

    /// The current view mode (local or remote dashboard). Persisted across launches.
    @AppStorage("swiftbot.viewMode")
    private var viewModeRaw: String = ViewMode.local.rawValue

    var viewMode: ViewMode {
        get { ViewMode(rawValue: viewModeRaw) ?? .local }
        set {
            viewModeRaw = newValue.rawValue
            updateProvider()
        }
    }

    // MARK: - Bot Data Provider

    /// The current data provider (local or remote). Views should use this instead of accessing AppModel directly.
    @Published var provider: AnyBotDataProvider?

    private var localProvider: LocalBotProvider?
    private var localProviderBox: AnyBotDataProvider?

    private func updateProvider() {
        if localProvider == nil {
            let localProvider = LocalBotProvider(app: self)
            self.localProvider = localProvider
            self.localProviderBox = AnyBotDataProvider(localProvider)
        }
        provider = localProviderBox
    }

    /// OAuth2 client ID resolved from a validated token; used to build the invite URL.
    @Published var resolvedClientID: String?
    /// Result from the most recent rich token validation; exposed for onboarding UI error display.
    @Published var lastTokenValidationResult: DiscordService.TokenValidationResult?
    let isBetaBuild: Bool = (Bundle.main.object(forInfoDictionaryKey: "ShipHookIsBetaBuild") as? Bool) ?? false

    var logs = LogStore()
    let automationStore = AutomationStore()
    let automationDrafter = AutomationDrafter()
    /// Legacy rule store — empty no-op shim. Retained so the web admin
    /// rule editor, analytics rule panels, and bot data provider compile.
    /// All real rule logic now lives in `automationStore`.
    let ruleStore = RuleStore()

    let store = ConfigStore()
    let analyticsRuntimeStore = AnalyticsRuntimeStore()
    let welcomeFlowService = WelcomeFlowService()
    let swiftMeshConfigStore = SwiftMeshConfigStore()
    let mediaLibraryConfigStore = MediaLibraryConfigStore()
    let discordCacheStore = DiscordCacheStore()
    let meshCursorStore = MeshCursorStore()
    let mediaLibraryIndexer = MediaLibraryIndexer()
    let mediaThumbnailCache = MediaThumbnailCache()
    let mediaExportCoordinator = MediaExportCoordinator()
    let mediaTranscodeCache: MediaTranscodeCache = {
        let baseCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = baseCaches.appendingPathComponent("SwiftBot/MediaTranscodes", isDirectory: true)
        return MediaTranscodeCache(cacheRoot: root)
    }()
    let discordCache = DiscordCache()

    /// Shared session for general Discord REST API calls (gateway, guild, message operations).
    /// Uses default configuration for connection pooling and reuse.
    var discordRESTSession = URLSession(configuration: .default)

    /// Dedicated session for Discord identity/token validation calls.
    /// Uses ephemeral configuration: no disk cache, no credential storage, short timeout.
    /// This ensures token validation responses are never cached and credentials aren't persisted.
    private static let identitySessionConfig: URLSessionConfiguration = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCache = nil
        return c
    }()
    let identitySession = URLSession(configuration: AppModel.identitySessionConfig)

    lazy var aiService = DiscordAIService(session: discordRESTSession)
    lazy var identityRESTClient = DiscordIdentityRESTClient(
        session: discordRESTSession,
        identitySession: identitySession
    )
    lazy var guildRESTClient = DiscordGuildRESTClient(session: discordRESTSession)
    lazy var messageRESTClient = DiscordMessageRESTClient(session: discordRESTSession)
    lazy var wikiLookupService = WikiLookupService(session: discordRESTSession)
    lazy var musicLookupService = MusicLookupService(session: discordRESTSession)
    lazy var playlistImportService = PlaylistImportService(session: discordRESTSession)
    lazy var service = DiscordService(
        session: discordRESTSession,
        identitySession: identitySession,
        aiService: aiService,
        wikiLookupService: wikiLookupService
    )
    let cluster = ClusterCoordinator()
    let adminWebServer = AdminWebServer()
    let certificateManager = CertificateManager()
    let tunnelProvider: any TunnelProvider = TunnelManager.shared
    let clusterStatusService = ClusterStatusPollingService()
    lazy var automationService: AutomationService = buildAutomationService()
    let wikiContextCache = WikiContextCache()
    var guildOwnerIdByGuild: [String: String] = [:]
    var serviceCallbacksConfigured = false
    lazy var gatewayEventDispatcher = makeGatewayEventDispatcher()
    lazy var commandProcessor = makeCommandProcessor()
    let voicePresenceStore = VoicePresenceStore()
    let voiceSessionStore = VoiceSessionStore()

    // Voice playback / announcement pipeline (see AppModel+Voice.swift).
    var voicePlaybackServiceStorage: VoicePlaybackService?
    var voiceAnnouncementServiceStorage: VoiceAnnouncementService?
    var textChannelAnnouncerStorage: TextChannelAnnouncer?
    var voicePendingGuildID: String?
    var voicePendingChannelID: String?
    var voicePendingSessionID: String?
    var voicePendingServerToken: String?
    var voicePendingServerEndpoint: String?
    @Published var voiceConnectionStatus: VoiceConnectionStatus = .idle
    /// Retained AVSpeechSynthesizer for in-app preview playback (used while
    /// the Discord voice path is blocked by DAVE).
    let localSpeechPreviewSynthesizer = AVSpeechSynthesizer()
    var uptimeTask: Task<Void, Never>?
    var connectionHealthTask: Task<Void, Never>?
    var discordCacheSaveTask: Task<Void, Never>?
    var meshSyncTask: Task<Void, Never>?
    let conversationStore = ConversationStore()
    /// Tracks the last MemoryRecord ID the standby successfully merged from the leader.
    var localLastMergedRecordID: String?
    var lastCommandTimeByUserId: [String: Date] = [:]
    let commandCooldown: TimeInterval = 3.0
    let maxMediaClipDurationSeconds: Double = 15 * 60
    let aiMemoryStopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "hey", "how",
        "i", "if", "in", "into", "is", "it", "its", "me", "my", "of", "on", "or", "our", "so",
        "that", "the", "their", "them", "then", "there", "these", "they", "this", "to", "up",
        "use", "was", "we", "what", "when", "where", "which", "who", "why", "with", "you", "your"
    ]
    lazy var memoryViewModel = MemoryViewModel(store: conversationStore, discordCache: discordCache)
    let eventBus = EventBus()
    let swiftMinerLogger = Logger(subsystem: "com.swiftbot", category: "swiftminer")
    let pluginManager: PluginManager
    var weeklyPlugin: WeeklySummaryPlugin?
    let patchyChecker: UpdateChecker?
    let sweepService = SweepService()
    var patchyMonitorTask: Task<Void, Never>?
    var lastPatchyMonitoringSnapshot: PatchyMonitoringSnapshot?
    var adminWebCertificateRenewalTask: Task<Void, Never>?
    var adminWebCertificateRenewalConfiguration: AdminWebCertificateRenewalConfiguration?
    var mediaMonitorTask: Task<Void, Never>?
    var lastSeenMediaItemIDs: Set<String> = []
    var botUserId: String?
    let launchedAt = Date()
    var clusterNodesRefreshTask: Task<Void, Never>?
    var lastClusterStatusSuccessAt: Date?
    var lastGoodClusterNodes: [ClusterNodeStatus] = []
    var registeredWorkersDebugCount: Int = 0
    var registeredWorkersDebugSummary: String = "none"
    private var lastSettingsSaveAt: Date = .distantPast
    // P1b: off-peak background mesh refresh
    var backgroundRefreshScheduler: NSBackgroundActivityScheduler?
    @Published var botUsername: String = "OnlineBot"
    @Published var botDiscriminator: String?
    @Published var botAvatarHash: String?
    @Published var userAvatarHashById: [String: String] = [:]
    @Published var guildAvatarHashByMemberKey: [String: String] = [:]
    // Max cache entries to prevent unbounded memory growth during extended operation
    private let maxAvatarCacheCount = 1000

    var resolvedBotUsername: String {
        let live = botUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty, live != "OnlineBot" {
            return live
        }
        let cached = settings.cachedBotIdentity.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return cached.isEmpty ? "SwiftBot" : cached
    }

    func cacheUserAvatar(_ hash: String, for userId: String) {
        userAvatarHashById[userId] = hash
        if userAvatarHashById.count > maxAvatarCacheCount {
            userAvatarHashById.keys.prefix(200).forEach { userAvatarHashById.removeValue(forKey: $0) }
        }
    }

    func cacheGuildAvatar(_ hash: String, for key: String) {
        guildAvatarHashByMemberKey[key] = hash
        if guildAvatarHashByMemberKey.count > maxAvatarCacheCount {
            guildAvatarHashByMemberKey.keys.prefix(200).forEach { guildAvatarHashByMemberKey.removeValue(forKey: $0) }
        }
    }

    @Published var mediaLibrarySettings = MediaLibrarySettings()
    @Published var mediaExportJobs: [MediaExportJob] = []
    @Published var mediaPlaybackStarts = 0
    @Published var mediaPlaybackCompletedViews = 0
    @Published var mediaPlaybackTotalSeconds = 0
    @Published var mediaPlaybackUniqueItemCount = 0
    var lastSlashRegistrationAt: Date?
    var lastSlashGuildRegistrationAt: [String: Date] = [:]
    var clearedGlobalSlashCommands = false
    var lastSlashCommandsEnabledState: Bool?
    var pendingMusicSelectionsByUserID: [String: PendingMusicSelection] = [:]
    var musicInteractionSessionsByID: [String: MusicInteractionSession] = [:]
    var playlistTrackCardsByKey: [String: PlaylistTrackCardState] = [:]
    var mediaPlaybackStartedSessionIDs: Set<String> = []
    var mediaPlaybackCompletedSessionIDs: Set<String> = []
    var mediaPlaybackLastSecondsBySession: [String: Int] = [:]
    var mediaPlaybackViewedItemIDs: Set<String> = []

    var botAvatarURL: URL? {
        let cachedUserId = settings.cachedBotIdentity.userId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cachedAvatarHash = settings.cachedBotIdentity.avatarHash.trimmingCharacters(in: .whitespacesAndNewlines)
        let userId = botUserId ?? (cachedUserId.isEmpty ? nil : cachedUserId)
        let hash = botAvatarHash ?? (cachedAvatarHash.isEmpty ? nil : cachedAvatarHash)
        guard let userId, let hash else { return nil }
        let ext = hash.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/avatars/\(userId)/\(hash).\(ext)?size=128")
    }

    func avatarURL(forUserId userId: String, guildId: String? = nil) -> URL? {
        if let guildId,
           let guildHash = guildAvatarHashByMemberKey["\(guildId)-\(userId)"],
           !guildHash.isEmpty {
            let ext = guildHash.hasPrefix("a_") ? "gif" : "png"
            return URL(string: "https://cdn.discordapp.com/guilds/\(guildId)/users/\(userId)/avatars/\(guildHash).\(ext)?size=96")
        }
        guard let hash = userAvatarHashById[userId], !hash.isEmpty else { return nil }
        let ext = hash.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/avatars/\(userId)/\(hash).\(ext)?size=96")
    }

    func fallbackAvatarURL(forUserId userId: String) -> URL? {
        guard let numericID = UInt64(userId) else {
            return URL(string: "https://cdn.discordapp.com/embed/avatars/0.png")
        }
        let index = Int(numericID % 6)
        return URL(string: "https://cdn.discordapp.com/embed/avatars/\(index).png")
    }

    var isRemoteLaunchMode: Bool {
        settings.launchMode == .remoteControl
    }

    var remoteControlFeatureEnabled: Bool {
        isBetaBuild && settings.devFeaturesEnabled
    }

    var canSwitchDashboardViewMode: Bool {
        !isRemoteLaunchMode && !isFailoverManagedNode
    }

    var canOpenRemoteDashboardFromLocalApp: Bool {
        remoteControlFeatureEnabled && canSwitchDashboardViewMode
    }

    var usesLocalRuntime: Bool {
        settings.launchMode != .remoteControl
    }

    private func onboardingCompleted(for settings: BotSettings) -> Bool {
        switch settings.launchMode {
        case .remoteControl:
            return settings.remoteMode.isConfigured
        case .standaloneBot:
            return !settings.token.isEmpty
        case .swiftMeshClusterNode:
            // Failover / Worker nodes don't always carry their own Discord
            // token — they relay via the Primary. Treat them as onboarded
            // once the cluster is configured (host + shared secret), so that
            // a term update → saveSettings → recompute doesn't kick a
            // tokenless Standby back to the welcome screen mid-failover.
            switch settings.clusterMode {
            case .standby, .worker:
                let host = settings.clusterLeaderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                let secret = settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                return !host.isEmpty && !secret.isEmpty
            case .leader, .standalone:
                return !settings.token.isEmpty
            }
        }
    }

    init(discordRESTSession: URLSession? = nil) {
        if let customSession = discordRESTSession {
            self.discordRESTSession = customSession
        }
        self.pluginManager = PluginManager(bus: eventBus)
        if let store = try? JSONVersionStore(fileURL: PatchyRuntime.checkerStoreURL()) {
            self.patchyChecker = UpdateChecker(store: store)
        } else {
            self.patchyChecker = nil
        }
        self.automationStore.onPersisted = { [weak self] in
            Task { [weak self] in await self?.handleRuleStorePersisted() }
        }

        // Wire Sweep to the real Discord runtime. The dispatcher self-gates via
        // canExecute() so it stays a no-op on non-Primary nodes.
        let discord = self.service
        self.sweepService.setDispatcher(
            LiveSweepDispatcher(
                discord: discord,
                isPrimary: { [weak self] in
                    guard let self else { return false }
                    let mode = await MainActor.run { self.clusterSnapshot.mode }
                    return mode == .standalone || mode == .leader
                }
            )
        )
        // On-device digest via Apple Intelligence.
        let aiService = self.aiService
        self.sweepService.setSummariser { channelName, lines in
            await aiService.summarizeSweepDigest(channelName: channelName, lines: lines)
        }
        // Forward Sweep run reports into the shared Activity log so the user
        // can see them alongside Patchy / voice activity.
        self.sweepService.setActivityLogger { [weak self] report in
            guard let self else { return }
            let channel = self.sweepChannelName(for: report)
            let prefix: String
            let body: String
            let level: String
            if let err = report.error {
                prefix = "[ERR]"
                level = "error"
                body = "Sweep failed · \(report.policyName) · #\(channel): \(err)"
            } else if report.executed == 0 && report.matched == 0 {
                prefix = "[INFO]"
                level = "info"
                body = "Sweep ran · \(report.policyName) · #\(channel): nothing to tidy (\(report.scanned) scanned)"
            } else if report.dryRun {
                prefix = "[INFO]"
                level = "info"
                body = "Sweep dry-run · \(report.policyName) · #\(channel): would tidy \(report.matched), \(report.suppressed) protected"
            } else {
                prefix = "[INFO]"
                level = "info"
                body = "Sweep tidied \(report.executed) in #\(channel) · \(report.policyName) (\(report.suppressed) protected)"
            }
            // Activity log (the Activity tab reads from logs.lines)
            self.logs.append("\(prefix) \(body)")
            // Also push into the structured event list for analytics consumers.
            let eventKind: ActivityEvent.Kind = level == "error" ? .error : .info
            self.addEvent(.init(timestamp: Date(), kind: eventKind, message: body))

            // Emit a moderation audit only when a non-dry-run deleted something —
            // dry-runs and idle scans are noise.
            if !report.dryRun && report.executed > 0 && report.error == nil {
                self.recordAudit(
                    source: .moderation,
                    actor: "Sweep · \(report.policyName)",
                    action: "Deleted \(report.executed) message\(report.executed == 1 ? "" : "s")",
                    detail: "#\(channel) · matched \(report.matched), suppressed \(report.suppressed)",
                    level: .warning
                )
            }
        }
        StreamDebug.inAppSink = { [weak self] line in
            Task { @MainActor [weak self] in
                self?.logs.append(line)
            }
        }
        Task { [weak self] in
            await self?.mediaExportCoordinator.setOnJobFinished { [weak self] (_: MediaExportJob) in
                await self?.mediaLibraryIndexer.invalidate()
            }
        }

        Task {
            await startRateLimitCleanupTask()

            await voiceSessionStore.load()
            let analyticsRuntimeSnapshot = await analyticsRuntimeStore.load()
            restoreAnalyticsRuntime(analyticsRuntimeSnapshot)
            var loadedSettings = await store.load()
            let loadedMeshSettings = await swiftMeshConfigStore.load()
            let loadedMediaSettings = await mediaLibraryConfigStore.load()
            if let loadedMeshSettings {
                loadedSettings.swiftMeshSettings = loadedMeshSettings
            } else {
                // Seed dedicated mesh config once so later synced settings imports can't drift mesh identity.
                try? await swiftMeshConfigStore.save(loadedSettings.swiftMeshSettings)
            }
            mediaLibrarySettings = loadedMediaSettings
            var migrated = false

            if migrateLegacyPatchySettingsIfNeeded(&loadedSettings) {
                migrated = true
            }
            if migrateLegacyWikiBridgeSettingsIfNeeded(&loadedSettings) {
                migrated = true
            }
            // Worker mode is deprecated in UI — migrate to Fail Over for existing users.
            if loadedSettings.clusterMode == .worker {
                loadedSettings.clusterMode = .standby
                workerModeMigrated = true
                migrated = true
            }
            loadedSettings.remoteMode.normalize()
            if loadedSettings.swiftMiner.enabled && !loadedSettings.adminWebUI.enabled {
                loadedSettings.adminWebUI.enabled = true
                migrated = true
            }

            settings = loadedSettings
            restoreCachedBotIdentity()
            isOnboardingComplete = onboardingCompleted(for: loadedSettings)

            // Initialize the appropriate data provider
            await MainActor.run {
                self.updateProvider()
            }
            if let cachedDiscord = await discordCacheStore.load() {
                await discordCache.replace(with: cachedDiscord)
                await syncPublishedDiscordCacheFromService()
                logs.append("Loaded cached Discord metadata (\(cachedDiscord.connectedServers.count) servers)")
            }
            await refreshAIStatus()
            for target in settings.patchy.sourceTargets where target.source == .steam {
                resolveSteamNameIfNeeded(for: target)
            }

            if migrated {
                try? await store.save(loadedSettings)
                try? await swiftMeshConfigStore.save(loadedSettings.swiftMeshSettings)
            }

            guard loadedSettings.launchMode != .remoteControl else {
                await cluster.stopAll()
                await adminWebServer.stop()
                await service.setOutputAllowed(false)
                return
            }

            await service.setAutomationService(automationService, store: automationStore)
            await MainActor.run { automationStore.load() }
            await service.setHistoryProvider { [weak self] scope in
                guard let self else { return [] }
                let (messages, _) = await self.aiMessagesForScope(
                    scope: scope,
                    currentUserID: "",
                    currentContent: ""
                )
                return messages
            }
            await service.setActiveVoiceJoinDateProvider { [weak self] guildId, userId in
                guard let self else { return nil }
                return await self.voiceSessionStore.persistedJoinDate(guildId: guildId, userId: userId)
            }
            await cluster.configureHandlers(
                aiHandler: { [weak self] messages, serverName, channelName, wikiContext in
                    guard let self else { return nil }
                    return await self.aiService.generateSmartDMReply(
                        messages: messages,
                        serverName: serverName,
                        channelName: channelName,
                        wikiContext: wikiContext
                    )
                },
                wikiHandler: { [weak self] query, source in
                    guard let self else { return nil }
                    return await self.wikiLookupService.lookupWiki(query: query, source: source)
                },
                playlistImportHandler: { [weak self] playlistURL, limit in
                    guard let self else { return nil }
                    return await self.playlistImportService.importPlaylist(from: playlistURL, limit: limit)
                },
                onSnapshot: { [weak self] snapshot in
                    let model = self
                    await MainActor.run {
                        model?.clusterSnapshot = snapshot
                        model?.lastPublishedRole = snapshot.mode
                        model?.scheduleClusterNodesRefresh()
                    }
                },
                onJobLog: { [weak self] entry in
                    let model = self
                    await MainActor.run {
                        model?.addCommandLogEntry(entry)
                    }
                },
                onSync: { [weak self] payload in
                    guard let self else { return }
                    await self.handleMeshSync(payload)
                },
                meshHandler: { [weak self] type in
                    guard let self else { return nil }
                    return await self.handleMeshRequest(type: type)
                },
                mediaLibraryProvider: { [weak self] in
                    guard let self else { return MediaLibraryPayload(nodeName: "SwiftBot", configFilePath: "", sources: [], items: [], generatedAt: Date()) }
                    return await self.localMediaLibrarySnapshot()
                },
                mediaStreamHandler: { [weak self] itemID, rangeHeader in
                    guard let self else { return nil }
                    return await self.localMediaStreamResponse(itemID: itemID, rangeHeader: rangeHeader)
                },
                mediaThumbnailHandler: { [weak self] itemID, _ in
                    guard let self else { return nil }
                    return await self.localMediaThumbnailResponse(itemID: itemID)
                },
                mediaClipHandler: { [weak self] request in
                    guard let self else { return nil }
                    return await self.localMediaClipExport(request: request)
                },
            mediaMultiViewHandler: { [weak self] request in
                guard let self else { return nil }
                return await self.localMediaMultiViewExport(request: request)
            },
            mediaFrameHandler: { [weak self] itemID, seconds in
                guard let self else { return nil }
                return await self.localMediaFrameResponse(itemID: itemID, atSeconds: seconds)
            },
                conversationFetcher: { [weak self] fromRecordID, limit in
                    guard let self, let fromRecordID else { return ([], false) }
                    return await self.conversationStore.recordsSince(fromRecordID: fromRecordID, limit: limit)
                },
                onPromotion: { [weak self] in
                    guard let self else { return }
                    // Promoted to Primary — enable Discord output.
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.lastPublishedRole = .leader
                        logs.append("[OK] SwiftMesh promoted to Primary.")
                        Task {
                            await self.handleClusterRoleChange()
                            await self.connectDiscordAfterPromotion()
                        }
                    }
                }
            )
            await aiService.configureLocalAIDMReplies(
                enabled: settings.localAIDMReplyEnabled,
                systemPrompt: settings.localAISystemPrompt
            )
            await cluster.applySettings(
                mode: settings.clusterMode,
                nodeName: settings.clusterNodeName,
                leaderAddress: settings.clusterLeaderAddress,
                leaderPort: settings.clusterLeaderPort,
                listenPort: settings.clusterListenPort,
                sharedSecret: settings.clusterSharedSecret,
                leaderTerm: settings.clusterLeaderTerm
            )
            await cluster.setOffloadPolicy(
                workerOffloadEnabled: settings.clusterWorkerOffloadEnabled,
                aiReplies: settings.clusterOffloadAIReplies,
                wikiLookups: settings.clusterOffloadWikiLookups
            )
            await cluster.setTermChangedHandler { [weak self] newTerm in
                guard let self else { return }
                await MainActor.run { [weak self] in
                    self?.settings.clusterLeaderTerm = newTerm
                    self?.saveSettings()
                }
            }
            await cluster.setCursorsChangedHandler { [weak self] cursors in
                Task { [weak self] in
                    await self?.saveMeshCursors(cursors)
                }
            }
            // Primary-side: serve the Discord token to mesh-authenticated
            // peers so a Failover can pull it after onboarding.
            await cluster.setDiscordTokenProvider { [weak self] in
                guard let self else { return nil }
                return await MainActor.run {
                    let trimmed = self.settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            }
            // Standby/Worker-side: receive a pulled token from the Primary
            // and persist via the existing Keychain-backed save path. Only
            // applies when the local node has no token yet — the guard here
            // prevents a stale Primary from overwriting a known-good local.
            await cluster.setDiscordTokenFetchedHandler { [weak self] pulled in
                guard let self else { return }
                let trimmed = pulled.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                await MainActor.run {
                    let existing = self.settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard existing.isEmpty else { return }
                    self.settings.token = trimmed
                    self.logs.append("[INFO] SwiftMesh pulled Discord token from Primary (via mesh handshake).")
                    self.saveSettings()
                }
            }
            await cluster.setLeaderRegistrationSyncHandler { [weak self] _ in
                guard let self else { return }
                await MainActor.run {
                    self.logs.append("[INFO] SwiftMesh registered with Primary — pulling immediate failover sync.")
                }
                await self.pullConfigFilesFromLeader()
                await self.pullWikiCacheFromLeader()
                await self.requestResyncFromLeader(fromRecordID: await MainActor.run { self.localLastMergedRecordID })
            }
            await cluster.setHandoverTestPassedHandler { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.settings.clusterLastHandoverTestAt = Date()
                    self.settings.clusterLastHandoverTestOK = true
                    self.logs.append("[OK] SwiftMesh handover test completed end-to-end.")
                    self.saveSettings()
                }
            }
            // Per-step trace of the handover drill. Each event lands in the
            // Activity Log under the SwiftMesh filter (any line containing
            // "SwiftMesh" / "Primary" / "Standby" auto-categorises as mesh —
            // see ActivityCategory.infer).
            await cluster.setHandoverTestStepHandler { [weak self] step in
                guard let self else { return }
                await MainActor.run {
                    self.logs.append("[INFO] SwiftMesh handover test: \(step)")
                }
            }
            await cluster.setDemotionHandler { [weak self] in
                guard let self else { return }
                // Higher-term peer detected — mute Discord and revert to passive standby.
                await self.service.setOutputAllowed(false)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.lastPublishedRole = .standby
                    self.logs.append("[WARN] SwiftMesh demoted to Standby — another Primary holds a higher term. Output muted.")
                    Task {
                        await self.handleClusterRoleChange()
                    }
                }
            }
            // Phase 3: provide this node's follower-state summary on demand.
            // Called by the local /v1/mesh/follower-state endpoint when the
            // primary polls. Read on MainActor since most of the source fields
            // are @Published; bridge into a Sendable struct before returning.
            await cluster.setFollowerStateProvider { [weak self] in
                guard let self else {
                    return FollowerStateSummary(
                        nodeName: Host.current().localizedName ?? "SwiftBot Node",
                        baseURL: "",
                        mode: "unknown",
                        leaderTerm: 0,
                        gatewayConnected: false,
                        outputAllowed: false,
                        lastEventAt: nil,
                        recentLogTail: [],
                        activeVoiceMembers: 0,
                        collectedAt: Date(),
                        discordGatewayLatencyMs: nil
                    )
                }
                let outputAllowed = await self.service.outputAllowed
                return await MainActor.run { [weak self] in
                    guard let self else {
                        return FollowerStateSummary(
                            nodeName: Host.current().localizedName ?? "SwiftBot Node",
                            baseURL: "",
                            mode: "unknown",
                            leaderTerm: 0,
                            gatewayConnected: false,
                            outputAllowed: false,
                            lastEventAt: nil,
                            recentLogTail: [],
                            activeVoiceMembers: 0,
                            collectedAt: Date(),
                            discordGatewayLatencyMs: nil
                        )
                    }
                    let tail = Array(self.logs.lines.suffix(8))
                    return FollowerStateSummary(
                        nodeName: self.settings.clusterNodeName.isEmpty
                            ? (Host.current().localizedName ?? "SwiftBot Node")
                            : self.settings.clusterNodeName,
                        baseURL: "http://127.0.0.1:\(self.settings.clusterListenPort)",
                        mode: self.settings.clusterMode.rawValue,
                        leaderTerm: self.settings.clusterLeaderTerm,
                        gatewayConnected: self.status == .running,
                        outputAllowed: outputAllowed,
                        lastEventAt: self.lastVoiceStateAt,
                        recentLogTail: tail,
                        activeVoiceMembers: self.voiceStateEventCount,
                        collectedAt: Date(),
                        discordGatewayLatencyMs: self.connectionDiagnostics.heartbeatLatencyMs
                    )
                }
            }
            let restoredCursors = await meshCursorStore.load()
            await cluster.applyRestoredCursors(restoredCursors)
            await configureAdminWebServer()
            configureMeshSync()
            setupBackgroundRefreshScheduler()
            await pollClusterStatus()
            await configureServiceCallbacks()
            configurePatchyMonitoring()
            if settings.autoStart, !settings.token.isEmpty {
                await startBot()
            }
        }
    }

    func saveSettings() {
        let now = Date()
        let throttleInterval: TimeInterval = 3
        if now.timeIntervalSince(lastSettingsSaveAt) < throttleInterval {
            // Too soon — skip the save to prevent cascading config-change storms.
            return
        }
        lastSettingsSaveAt = now

        let normalizedToken = normalizedDiscordToken(from: settings.token)
        if normalizedToken != settings.token {
            settings.token = normalizedToken
            logs.append("[WARN] Token format normalized (removed surrounding whitespace or Bot prefix)")
        }

        let trimmedPrefix = settings.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrefix.isEmpty {
            settings.prefix = "/"
            logs.append("[WARN] Prefix cannot be empty. Reset to default.")
        } else if trimmedPrefix == "!" {
            settings.prefix = "/"
            logs.append("[INFO] Legacy command prefix migrated to '/'.")
        } else {
            settings.prefix = trimmedPrefix
        }
        settings.wikiBot.normalizeSources()
        settings.adminWebUI.redirectPath = normalizedAdminRedirectPath(settings.adminWebUI.redirectPath)
        settings.adminWebUI.discordOAuth.clientID = settings.adminWebUI.discordOAuth.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.discordOAuth.clientSecret = settings.adminWebUI.discordOAuth.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.localAuthUsername = settings.adminWebUI.localAuthUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.adminWebUI.localAuthUsername.isEmpty {
            settings.adminWebUI.localAuthUsername = "admin"
        }
        settings.adminWebUI.localAuthPassword = settings.adminWebUI.localAuthPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.hostname = settings.adminWebUI.normalizedHostname
        settings.adminWebUI.cloudflareAPIToken = settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.publicAccessTunnelToken = settings.adminWebUI.publicAccessTunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.importedCertificateFile = settings.adminWebUI.normalizedImportedCertificateFile
        settings.adminWebUI.importedPrivateKeyFile = settings.adminWebUI.normalizedImportedPrivateKeyFile
        settings.adminWebUI.importedCertificateChainFile = settings.adminWebUI.normalizedImportedCertificateChainFile
        settings.adminWebUI.publicBaseURL = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.allowedUserIDs = settings.adminWebUI.normalizedAllowedUserIDs
        settings.remoteMode.normalize()
        isOnboardingComplete = onboardingCompleted(for: settings)

        Task {
            do {
                try await store.save(settings)
                try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
                try await mediaLibraryConfigStore.save(mediaLibrarySettings)
                await mediaLibraryIndexer.invalidate()
                logs.append("[OK] Settings saved")
                await refreshAIStatus()
            } catch {
                stats.errors += 1
                logs.append("[ERR] Failed saving settings: \(error.localizedDescription)")
                return
            }

            if self.usesLocalRuntime {
                await aiService.configureLocalAIDMReplies(
                    enabled: settings.localAIDMReplyEnabled,
                    systemPrompt: settings.localAISystemPrompt
                )
                await applyClusterSettingsRuntime(
                    mode: settings.clusterMode,
                    nodeName: settings.clusterNodeName,
                    leaderAddress: settings.clusterLeaderAddress,
                    leaderPort: settings.clusterLeaderPort,
                    listenPort: settings.clusterListenPort,
                    sharedSecret: settings.clusterSharedSecret
                )
                await configureAdminWebServer()
                configurePatchyMonitoring()
            } else {
                patchyMonitorTask?.cancel()
                patchyMonitorTask = nil
                await cluster.stopAll()
                await adminWebServer.stop()
                await service.setOutputAllowed(false)
                adminWebResolvedBaseURL = ""
                adminWebPublicAccessStatus = AdminWebPublicAccessRuntimeStatus()
            }

            await notifyConfigFilesChangedIfLeader()
        }
    }

    func handleRuleStorePersisted() async {
        await notifyConfigFilesChangedIfLeader()
    }

    func notifyConfigFilesChangedIfLeader() async {
        guard settings.clusterMode == .leader else { return }
        let currentTerm = await cluster.currentLeaderTerm()
        let configFiles = await store.exportMeshSyncedFiles(
            excludingFileNames: Set([
                SwiftBotStorage.swiftMeshConfigFileName,
                SwiftBotStorage.clusterStateFileName
            ])
        )
        let payload = MeshSyncPayload(
            conversations: [],
            configFilesChanged: true,
            configFiles: configFiles,
            leaderTerm: currentTerm
        )
        await cluster.pushSyncPayloadToNodes(payload)
    }

    // MARK: - Media (see AppModel+Media.swift)

    func refreshAIStatus() async {
        appleIntelligenceOnline = await aiService.currentAIStatus()
    }

    // MARK: - Patchy (see AppModel+Patchy.swift)

    // MARK: - WikiBridge (see AppModel+WikiBridge.swift)

    // MARK: - Bot Lifecycle (see AppModel+BotLifecycle.swift)

    // MARK: - Admin Web Server (see AppModel+AdminWeb.swift)

    func stopBot() async {
        stopMediaMonitor()
        await service.disconnect()
        await cluster.stopAll()
        meshSyncTask?.cancel()
        meshSyncTask = nil
        clusterNodesRefreshTask?.cancel()
        clusterNodesRefreshTask = nil
        patchyMonitorTask?.cancel()
        patchyMonitorTask = nil
        connectionHealthTask?.cancel()
        connectionHealthTask = nil
        uptimeTask?.cancel()
        uptime = nil
        await clearVoicePresence()
        userAvatarHashById.removeAll()
        guildAvatarHashByMemberKey.removeAll()
        lastGatewayEventName = "-"
        lastVoiceStateAt = nil
        lastVoiceStateSummary = "-"
        restoreCachedBotIdentity()
        clusterNodes = []
        lastGoodClusterNodes = []
        lastClusterStatusSuccessAt = nil
        clusterSnapshot = await cluster.currentSnapshot()
        await pluginManager.removeAll()
        status = .stopped
        logs.append("Bot stopped (SwiftMesh listener stopped)")
    }

    // MARK: - Cluster (see AppModel+Cluster.swift)

    // MARK: - P1b: Off-peak background mesh refresh

    /// Schedules a low-priority background activity (15 min / 5 min tolerance) that fires
    /// existing standby/worker sync paths when the system is idle (NSBackgroundActivityScheduler).

    /// Leader: push incremental conversation batches to each registered node using per-node cursors.

    var runtimeClusterMode: ClusterMode {
        lastPublishedRole ?? clusterSnapshot.mode
    }

    var isWorkerServiceRunning: Bool {
        guard settings.clusterMode == .worker else { return false }
        switch clusterSnapshot.serverState {
        case .starting, .listening, .connected:
            return true
        default:
            return false
        }
    }

    var primaryServiceStatusText: String {
        runtimeClusterMode == .worker
            ? (isWorkerServiceRunning ? "Worker Online" : "Worker Offline")
            : (status == .running ? "Online" : "Offline")
    }

    var primaryServiceIsOnline: Bool {
        runtimeClusterMode == .worker ? isWorkerServiceRunning : status == .running
    }

    var isFailoverManagedNode: Bool {
        runtimeClusterMode == .worker || runtimeClusterMode == .standby
    }

    var shouldProcessPrimaryGatewayActions: Bool {
        runtimeClusterMode == .standalone || runtimeClusterMode == .leader
    }

    func configureServiceCallbacks() async {
        if serviceCallbacksConfigured { return }

        await service.setOnConnectionState { [weak self] state in
            await MainActor.run {
                self?.status = state
                self?.logs.append("Connection state: \(state.rawValue)")
            }
        }

        await service.setOnPayload { [weak self] payload in
            await self?.handlePayload(payload)
        }

        await service.setOnHeartbeatLatency { [weak self] latencyMs in
            await MainActor.run {
                self?.connectionDiagnostics.recordHeartbeatLatency(latencyMs)
            }
        }

        await service.setOnGatewayClose { [weak self] code in
            await MainActor.run {
                self?.connectionDiagnostics.lastGatewayCloseCode = code
            }
        }

        serviceCallbacksConfigured = true
    }

    func startUptimeTicker() {
        uptimeTask?.cancel()
        uptimeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self else { return }
                await MainActor.run {
                    if let startedAt = self.uptime?.startedAt {
                        self.uptime = UptimeInfo(startedAt: startedAt)
                    }
                }
            }
        }
    }

    /// Periodic connection-health probe. Fires once immediately and then every
    /// 10 minutes for as long as the bot is running. Replaces the manual
    /// "Test Connection" button that used to live in the Connection Health
    /// card on the Overview.
    func startConnectionHealthMonitor() {
        connectionHealthTask?.cancel()
        connectionHealthTask = Task { [weak self] in
            // Initial probe — small delay so token/identity loading settles.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.runTestConnection()
                // 10 minutes between probes.
                try? await Task.sleep(nanoseconds: 600_000_000_000)
            }
        }
    }

    /// Resolves the channel display name for a Sweep run report by looking up
    /// the policy that ran. Falls back to the policy name if the policy isn't
    /// found (e.g. it was deleted between run and log).
    func sweepChannelName(for report: SweepRunReport) -> String {
        if let policy = sweepService.policies.first(where: { $0.id == report.policyID }),
           !policy.channelName.isEmpty {
            return policy.channelName
        }
        return report.policyName
    }

    func addEvent(_ event: ActivityEvent) {
        events.insert(event, at: 0)
        if events.count > 20 { events.removeLast(events.count - 20) }
        persistAnalyticsRuntime()
    }

    func addCommandLogEntry(_ entry: CommandLogEntry) {
        commandLog.insert(entry, at: 0)
        persistAnalyticsRuntime()
    }

    func addVoiceLogEntry(_ entry: VoiceEventLogEntry) {
        voiceLog.insert(entry, at: 0)
        if voiceLog.count > 200 { voiceLog.removeLast(voiceLog.count - 200) }
        persistAnalyticsRuntime()
    }

    func setPatchyLastCycleAt(_ date: Date?) {
        patchyLastCycleAt = date
        persistAnalyticsRuntime()
    }

    private func restoreAnalyticsRuntime(_ snapshot: AnalyticsRuntimeSnapshot) {
        events = snapshot.events
        commandLog = snapshot.commandLog
        voiceLog = snapshot.voiceLog
        auditLog = snapshot.auditLog
        patchyLastCycleAt = snapshot.patchyLastCycleAt
        automationLog = snapshot.automationLog ?? []
    }

    func persistAnalyticsRuntime() {
        let snapshot = AnalyticsRuntimeSnapshot(
            events: events,
            commandLog: commandLog,
            voiceLog: voiceLog,
            auditLog: auditLog,
            patchyLastCycleAt: patchyLastCycleAt,
            automationLog: automationLog
        )
        Task {
            await analyticsRuntimeStore.save(snapshot)
        }
    }

    // MARK: - P0.5: Member join welcome

    // MARK: - Discord Events (see AppModel+DiscordEvents.swift)

    func commandServerName(from map: [String: DiscordJSON]) -> String {
        guard case let .string(guildId)? = map["guild_id"] else {
            return "Direct Message"
        }
        return connectedServers[guildId] ?? "Server \(guildId.suffix(4))"
    }

    func effectivePrefix() -> String {
        let trimmed = settings.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/" : trimmed
    }

    func formatDuration(from: Date, to: Date) -> String {
        let interval = Int(to.timeIntervalSince(from))
        let m = interval / 60
        let s = interval % 60
        return "\(m)m \(s)s"
    }

    func restoreCachedBotIdentity() {
        let cached = settings.cachedBotIdentity
        let cachedUserId = cached.userId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cachedUserId.isEmpty {
            botUserId = cachedUserId
        }
        let cachedUsername = cached.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cachedUsername.isEmpty {
            botUsername = cachedUsername
        }
        let cachedDiscriminator = cached.discriminator.trimmingCharacters(in: .whitespacesAndNewlines)
        botDiscriminator = cachedDiscriminator.isEmpty ? nil : cachedDiscriminator
        let cachedAvatarHash = cached.avatarHash.trimmingCharacters(in: .whitespacesAndNewlines)
        botAvatarHash = cachedAvatarHash.isEmpty ? nil : cachedAvatarHash
    }

    func persistCachedBotIdentityIfNeeded() {
        var cached = settings.cachedBotIdentity
        let nextUserId = botUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? cached.userId
        let nextUsername = botUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextDiscriminator = botDiscriminator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? cached.discriminator
        let nextAvatarHash = botAvatarHash?.trimmingCharacters(in: .whitespacesAndNewlines) ?? cached.avatarHash

        guard !nextUsername.isEmpty, nextUsername != "OnlineBot" else { return }

        cached.userId = nextUserId
        cached.username = nextUsername
        cached.discriminator = nextDiscriminator == "0" ? "" : nextDiscriminator
        cached.avatarHash = nextAvatarHash

        guard cached != settings.cachedBotIdentity else { return }
        settings.cachedBotIdentity = cached
        saveSettings()
    }
}

@MainActor
final class MemoryViewModel: ObservableObject {
    @Published private(set) var summaries: [MemorySummary] = []
    @Published private(set) var scopeDisplayNames: [MemoryScope: String] = [:]

    let store: ConversationStore
    let discordCache: DiscordCache
    var storeUpdatesTask: Task<Void, Never>?
    var cacheUpdatesTask: Task<Void, Never>?

    init(store: ConversationStore, discordCache: DiscordCache) {
        self.store = store
        self.discordCache = discordCache

        storeUpdatesTask = Task { [weak self] in
            guard let self else { return }
            await self.reloadSummaries()
            let updates = await store.updates
            for await _ in updates {
                if Task.isCancelled { break }
                await self.reloadSummaries()
            }
        }

        cacheUpdatesTask = Task { [weak self] in
            guard let self else { return }
            let updates = await discordCache.updates
            for await _ in updates {
                if Task.isCancelled { break }
                await self.refreshDisplayNames()
            }
        }
    }

    deinit {
        storeUpdatesTask?.cancel()
        cacheUpdatesTask?.cancel()
    }

    var totalMessages: Int {
        summaries.reduce(0) { $0 + $1.messageCount }
    }

    func clearAll() {
        Task { await store.clearAll() }
    }

    func clear(scope: MemoryScope) {
        Task { await store.clear(scope: scope) }
    }

    func clear(channelID: String) {
        clear(scope: .guildTextChannel(channelID))
    }

    func displayName(for summary: MemorySummary) -> String {
        if let cached = scopeDisplayNames[summary.scope], !cached.isEmpty {
            return cached
        }
        return fallbackTitle(for: summary.scope)
    }

    func reloadSummaries() async {
        summaries = await store.summaries()
        await refreshDisplayNames()
    }

    func refreshDisplayNames() async {
        let current = summaries
        var updated: [MemoryScope: String] = [:]
        for summary in current {
            updated[summary.scope] = await resolvedTitle(for: summary.scope)
        }
        scopeDisplayNames = updated
    }

    func resolvedTitle(for scope: MemoryScope) async -> String {
        switch scope.type {
        case .guildTextChannel:
            if let channelName = await discordCache.channelName(for: scope.id),
               !channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "#\(channelName)"
            }
            return fallbackTitle(for: scope)
        case .directMessageUser:
            if let userName = await discordCache.userName(for: scope.id),
               !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "DM: \(userName)"
            }
            return fallbackTitle(for: scope)
        }
    }

    func fallbackTitle(for scope: MemoryScope) -> String {
        switch scope.type {
        case .guildTextChannel:
            return "Channel \(scope.id)"
        case .directMessageUser:
            return "DM User \(scope.id.suffix(4))"
        }
    }
}

struct WorkerConnectionTestOutcome {
    let message: String
    let isSuccess: Bool
    var latencyMs: Double?
    var nodeName: String?
}

enum WorkerReachabilityResult {
    case reachable
    case hostUnreachable(reason: String)
}

struct SwiftMeshPingResponse: Decodable {
    let status: String
    let role: String
    let node: String
}

actor ClusterStatusPollingService {
    let decoder = JSONDecoder()

    func fetchStatus(from endpoint: URL, headers: [String: String] = [:]) async -> ClusterStatusResponse? {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 3
            for (header, value) in headers {
                request.setValue(value, forHTTPHeaderField: header)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try decoder.decode(ClusterStatusResponse.self, from: data)
        } catch {
            return nil
        }
    }

    func fetchPing(from endpoint: URL, headers: [String: String] = [:]) async -> (response: SwiftMeshPingResponse, latencyMs: Double)? {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 3
            for (header, value) in headers {
                request.setValue(value, forHTTPHeaderField: header)
            }

            let startedAt = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let latencyMs = max(0, Date().timeIntervalSince(startedAt) * 1000)

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }

            let payload = try decoder.decode(SwiftMeshPingResponse.self, from: data)
            return (payload, latencyMs)
        } catch {
            return nil
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a remote authentication session token is received via deep link.
    static let remoteAuthSessionReceived = Notification.Name("remoteAuthSessionReceived")
}
