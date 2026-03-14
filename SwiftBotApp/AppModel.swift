import AppKit
import AVFoundation
import CryptoKit
import Foundation
import SwiftUI
import Darwin

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = BotSettings()
    @Published var status: BotStatus = .stopped
    @Published var stats = StatCounter()
    @Published var events: [ActivityEvent] = []
    @Published var commandLog: [CommandLogEntry] = []
    @Published var voiceLog: [VoiceEventLogEntry] = []
    @Published var activeVoice: [VoiceMemberPresence] = []
    @Published var uptime: UptimeInfo?
    @Published var connectedServers: [String: String] = [:]
    @Published var availableVoiceChannelsByServer: [String: [GuildVoiceChannel]] = [:]
    @Published var availableTextChannelsByServer: [String: [GuildTextChannel]] = [:]
    @Published var availableRolesByServer: [String: [GuildRole]] = [:]
    @Published var knownUsersById: [String: String] = [:]
    @Published var gatewayEventCount = 0
    @Published var voiceStateEventCount = 0
    @Published var readyEventCount = 0
    @Published var guildCreateEventCount = 0
    @Published var lastGatewayEventName: String = "-"
    @Published var lastVoiceStateAt: Date?
    @Published var lastVoiceStateSummary: String = "-"
    @Published var clusterSnapshot = ClusterSnapshot()
    @Published var clusterNodes: [ClusterNodeStatus] = []
    @Published var workerConnectionTestStatus: String = "Not tested"
    @Published var workerConnectionTestIsSuccess = false
    @Published var workerConnectionTestInProgress = false
    @Published var workerConnectionTestOutcome: WorkerConnectionTestOutcome? = nil
    @Published var lastClusterStatusRefreshAt: Date? = nil
    @Published var appleIntelligenceOnline = false
    @Published var ollamaOnline = false
    @Published var openAIOnline = false
    @Published var recentMediaCount24h = 0
    @Published var ollamaDetectedModel: String?
    @Published var patchyDebugLogs: [String] = []
    @Published var patchyIsCycleRunning = false
    @Published var patchyLastCycleAt: Date?
    var patchyTargetValidationCache: [String: (isValid: Bool, detail: String, validatedAt: Date)] = [:]
    @Published var bugAutoFixStatusText: String = "Idle"
    @Published var bugAutoFixConsoleText: String = ""
    @Published var adminWebResolvedBaseURL: String = ""
    @Published var adminWebPublicAccessStatus = AdminWebPublicAccessRuntimeStatus()
    @Published var workerModeMigrated = false
    // MARK: - P0.4 Diagnostics state

    @Published var connectionDiagnostics = ConnectionDiagnostics()
    /// Date after which another Test Connection is allowed (10s UI rate limit).
    @Published var testConnectionCooldownUntil: Date? = nil

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
    @Published var resolvedClientID: String? = nil
    /// Result from the most recent rich token validation; exposed for onboarding UI error display.
    @Published var lastTokenValidationResult: DiscordService.TokenValidationResult? = nil
    let isBetaBuild: Bool = (Bundle.main.object(forInfoDictionaryKey: "ShipHookIsBetaBuild") as? Bool) ?? false

    var logs = LogStore()
    let ruleStore = RuleStore()

    let store = ConfigStore()
    let swiftMeshConfigStore = SwiftMeshConfigStore()
    let mediaLibraryConfigStore = MediaLibraryConfigStore()
    let discordCacheStore = DiscordCacheStore()
    let meshCursorStore = MeshCursorStore()
    let mediaLibraryIndexer = MediaLibraryIndexer()
    let mediaThumbnailCache = MediaThumbnailCache()
    let mediaExportCoordinator = MediaExportCoordinator()
    let discordCache = DiscordCache()
    
    /// Shared session for general Discord REST API calls (gateway, guild, message operations).
    /// Uses default configuration for connection pooling and reuse.
    let discordRESTSession = URLSession(configuration: .default)
    
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
    let ruleEngine: RuleEngine
    let wikiContextCache = WikiContextCache()
    var guildOwnerIdByGuild: [String: String] = [:]
    var serviceCallbacksConfigured = false
    lazy var gatewayEventDispatcher = makeGatewayEventDispatcher()
    lazy var commandProcessor = makeCommandProcessor()
    let voicePresenceStore = VoicePresenceStore()
    var uptimeTask: Task<Void, Never>?
    var discordCacheSaveTask: Task<Void, Never>?
    var meshSyncTask: Task<Void, Never>?
    let conversationStore = ConversationStore()
    /// Tracks the last MemoryRecord ID the standby successfully merged from the leader.
    var localLastMergedRecordID: String?
    var lastCommandTimeByUserId: [String: Date] = [:]
    /// Dedupe cache for GUILD_MEMBER_ADD: keyed by "guildId:userId", 10s window. Capped at 500 entries.
    var recentMemberJoins: [String: Date] = [:]
    /// Approximate member count per guild, seeded from GUILD_CREATE and incremented on GUILD_MEMBER_ADD.
    var guildMemberCounts: [String: Int] = [:]
    /// Burst-guard: recent join timestamps per guild (keyed by guildId). Used to detect member raids.
    var guildJoinTimestamps: [String: [Date]] = [:]
    let commandCooldown: TimeInterval = 3.0
    let maxMediaClipDurationSeconds: Double = 15 * 60
    let aiMemoryStopwords: Set<String> = [
        "a","an","and","are","as","at","be","but","by","for","from","hey","how",
        "i","if","in","into","is","it","its","me","my","of","on","or","our","so",
        "that","the","their","them","then","there","these","they","this","to","up",
        "use","was","we","what","when","where","which","who","why","with","you","your"
    ]
    lazy var memoryViewModel = MemoryViewModel(store: conversationStore, discordCache: discordCache)
    let eventBus = EventBus()
    let pluginManager: PluginManager
    var weeklyPlugin: WeeklySummaryPlugin?
    let patchyChecker: UpdateChecker?
    var patchyMonitorTask: Task<Void, Never>?
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
    // P1b: off-peak background mesh refresh
    var backgroundRefreshScheduler: NSBackgroundActivityScheduler?
    @Published var botUsername: String = "OnlineBot"
    @Published var botDiscriminator: String?
    @Published var botAvatarHash: String?
    @Published var userAvatarHashById: [String: String] = [:]
    @Published var guildAvatarHashByMemberKey: [String: String] = [:]
    // Max cache entries to prevent unbounded memory growth during extended operation
    private let maxAvatarCacheCount = 1000

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
    var lastSlashRegistrationAt: Date?
    var lastSlashGuildRegistrationAt: [String: Date] = [:]
    var clearedGlobalSlashCommands = false
    var lastSlashCommandsEnabledState: Bool?
    var bugEntriesByMessageID: [String: BugEntry] = [:]
    var activeBugAutoFixMessageIDs: Set<String> = []
    var pendingBugAutoFixStarts: [String: BugAutoFixPendingStart] = [:]
    var pendingBugAutoFixApprovals: [String: BugAutoFixPendingApproval] = [:]

    var botAvatarURL: URL? {
        guard let userId = botUserId, let hash = botAvatarHash else { return nil }
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
        case .standaloneBot, .swiftMeshClusterNode:
            return !settings.token.isEmpty
        }
    }

    init() {
        self.ruleEngine = RuleEngine(store: ruleStore)
        self.pluginManager = PluginManager(bus: eventBus)
        if let store = try? JSONVersionStore(fileURL: PatchyRuntime.checkerStoreURL()) {
            self.patchyChecker = UpdateChecker(store: store)
        } else {
            self.patchyChecker = nil
        }
        self.ruleStore.onPersisted = { [weak self] in
            await self?.handleRuleStorePersisted()
        }
        Task { [weak self] in
            await self?.mediaExportCoordinator.setOnJobFinished { [weak self] (_: MediaExportJob) in
                await self?.mediaLibraryIndexer.invalidate()
            }
        }

        Task {
            await startRateLimitCleanupTask()

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

            if loadedSettings.localAIEndpoint.contains("mac-studio.local") {
                loadedSettings.localAIEndpoint = "http://127.0.0.1:1234/v1/chat/completions"
                migrated = true
            }
            if loadedSettings.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadedSettings.ollamaBaseURL = "http://localhost:11434"
                migrated = true
            }
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
            if loadedSettings.remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadedSettings.remoteAccessToken = generatedRemoteAccessToken()
                migrated = true
            }

            settings = loadedSettings
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
            if settings.localAIProvider == .ollama {
                detectOllamaModel()
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

            await service.setRuleEngine(ruleEngine)
            await service.setHistoryProvider { [weak self] scope in
                guard let self else { return [] }
                let (messages, _) = await self.aiMessagesForScope(
                    scope: scope,
                    currentUserID: "",
                    currentContent: ""
                )
                return messages
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
                onSnapshot: { [weak self] snapshot in
                    let model = self
                    await MainActor.run {
                        model?.clusterSnapshot = snapshot
                        model?.scheduleClusterNodesRefresh()
                    }
                },
                onJobLog: { [weak self] entry in
                    let model = self
                    await MainActor.run {
                        model?.commandLog.insert(entry, at: 0)
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
                    // Promoted to Primary — enable Discord output. If already connected
                    // in passive standby mode, no reconnect is needed; output gate flips instantly.
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        logs.append("🚀 Promoted to Primary.")
                        Task { await self.connectDiscordAfterPromotion() }
                    }
                }
            )
            await aiService.configureLocalAIDMReplies(
                enabled: settings.localAIDMReplyEnabled,
                provider: settings.localAIProvider,
                preferredProvider: settings.preferredAIProvider,
                endpoint: localAIEndpointForService(),
                model: settings.localAIModel,
                openAIAPIKey: effectiveOpenAIAPIKey(),
                openAIModel: settings.openAIModel,
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
        let normalizedToken = normalizedDiscordToken(from: settings.token)
        if normalizedToken != settings.token {
            settings.token = normalizedToken
            logs.append("⚠️ Token format normalized (removed surrounding whitespace or Bot prefix)")
        }

        let trimmedPrefix = settings.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrefix.isEmpty {
            settings.prefix = "/"
            logs.append("⚠️ Prefix cannot be empty. Reset to default.")
        } else if trimmedPrefix == "!" {
            settings.prefix = "/"
            logs.append("ℹ️ Legacy command prefix migrated to '/'.")
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
        settings.adminWebUI.hostname = settings.adminWebUI.normalizedHostname
        settings.adminWebUI.publicAccessTunnelToken = settings.adminWebUI.publicAccessTunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.importedCertificateFile = settings.adminWebUI.normalizedImportedCertificateFile
        settings.adminWebUI.importedPrivateKeyFile = settings.adminWebUI.normalizedImportedPrivateKeyFile
        settings.adminWebUI.importedCertificateChainFile = settings.adminWebUI.normalizedImportedCertificateChainFile
        settings.adminWebUI.publicBaseURL = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.allowedUserIDs = settings.adminWebUI.normalizedAllowedUserIDs
        settings.remoteMode.normalize()
        settings.remoteAccessToken = settings.remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.remoteAccessToken.isEmpty {
            settings.remoteAccessToken = generatedRemoteAccessToken()
        }
        isOnboardingComplete = onboardingCompleted(for: settings)

        Task {
            do {
                try await store.save(settings)
                try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
                try await mediaLibraryConfigStore.save(mediaLibrarySettings)
                await mediaLibraryIndexer.invalidate()
                logs.append("✅ Settings saved")
                await refreshAIStatus()
            } catch {
                stats.errors += 1
                logs.append("❌ Failed saving settings: \(error.localizedDescription)")
                return
            }

            if self.usesLocalRuntime {
                await aiService.configureLocalAIDMReplies(
                    enabled: settings.localAIDMReplyEnabled,
                    provider: settings.localAIProvider,
                    preferredProvider: settings.preferredAIProvider,
                    endpoint: localAIEndpointForService(),
                    model: settings.localAIModel,
                    openAIAPIKey: effectiveOpenAIAPIKey(),
                    openAIModel: settings.openAIModel,
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
        let payload = MeshSyncPayload(
            conversations: [],
            configFilesChanged: true,
            leaderTerm: currentTerm
        )
        await cluster.pushSyncPayloadToNodes(payload)
    }


    // MARK: - Media (see AppModel+Media.swift)

    func detectOllamaModel() {
        let base = normalizedOllamaBaseURL(from: settings.ollamaBaseURL)
        Task {
            guard let model = await aiService.detectOllamaModel(baseURL: base) else {
                await MainActor.run {
                    self.logs.append("⚠️ Ollama model auto-detect failed.")
                }
                await refreshAIStatus()
                return
            }

            await MainActor.run {
                if self.settings.localAIModel != model {
                    self.settings.localAIModel = model
                    self.saveSettings()
                }
                self.logs.append("✅ Ollama model detected: \(model)")
            }
            await refreshAIStatus()
        }
    }

    func refreshAIStatus() async {
        let status = await aiService.currentAIStatus(
            ollamaBaseURL: normalizedOllamaBaseURL(from: settings.ollamaBaseURL),
            ollamaModelHint: settings.localAIModel,
            openAIAPIKey: effectiveOpenAIAPIKey()
        )
        appleIntelligenceOnline = status.appleOnline
        ollamaOnline = status.ollamaOnline
        ollamaDetectedModel = status.ollamaModel
        openAIOnline = status.openAIOnline
    }

    func normalizedOllamaBaseURL(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "http://localhost:11434" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "http://\(trimmed)"
    }

    func localAIEndpointForService() -> String {
        if settings.localAIProvider == .ollama {
            return normalizedOllamaBaseURL(from: settings.ollamaBaseURL)
        }
        return settings.localAIEndpoint
    }

    func effectiveOpenAIAPIKey() -> String {
        guard settings.openAIEnabled else { return "" }
        return settings.openAIAPIKey
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
        uptimeTask?.cancel()
        uptime = nil
        await clearVoicePresence()
        userAvatarHashById.removeAll()
        guildAvatarHashByMemberKey.removeAll()
        lastGatewayEventName = "-"
        lastVoiceStateAt = nil
        lastVoiceStateSummary = "-"
        botUserId = nil
        botUsername = "OnlineBot"
        botDiscriminator = nil
        botAvatarHash = nil
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
        settings.clusterMode == .worker
            ? (isWorkerServiceRunning ? "Worker Online" : "Worker Offline")
            : (status == .running ? "Online" : "Offline")
    }

    var primaryServiceIsOnline: Bool {
        settings.clusterMode == .worker ? isWorkerServiceRunning : status == .running
    }

    var isFailoverManagedNode: Bool {
        settings.clusterMode == .worker || settings.clusterMode == .standby
    }

    var shouldProcessPrimaryGatewayActions: Bool {
        settings.clusterMode == .standalone || settings.clusterMode == .leader
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
                self?.connectionDiagnostics.heartbeatLatencyMs = latencyMs
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

    func addEvent(_ event: ActivityEvent) {
        events.insert(event, at: 0)
        if events.count > 20 { events.removeLast(events.count - 20) }
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
    var latencyMs: Double? = nil
    var nodeName: String? = nil
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
