import Foundation
import SwiftUI
import UpdateEngine
import Darwin

struct BugAutoFixPendingApproval {
    let bugMessageID: String
    let channelID: String
    let guildID: String
    let sourceRepoPath: String
    let isolatedRepoPath: String
    let branch: String
    let updateChannelID: String
    let version: String
    let build: String
}

struct BugAutoFixPendingStart {
    let bugMessageID: String
    let channelID: String
    let guildID: String
    let sourceRepoPath: String
    let isolatedRepoPath: String
    let branch: String
    let updateChannelID: String
    let version: String
    let build: String
    let requestedByUserID: String
}

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
    @Published var appleIntelligenceOnline = false
    @Published var ollamaOnline = false
    @Published var openAIOnline = false
    @Published var ollamaDetectedModel: String?
    @Published var patchyDebugLogs: [String] = []
    @Published var patchyIsCycleRunning = false
    @Published var patchyLastCycleAt: Date?
    @Published var bugAutoFixStatusText: String = "Idle"
    @Published var bugAutoFixConsoleText: String = ""
    @Published var workerModeMigrated = false
    // MARK: - P0.4 Diagnostics state

    @Published var connectionDiagnostics = ConnectionDiagnostics()
    /// Date after which another Test Connection is allowed (10s UI rate limit).
    @Published var testConnectionCooldownUntil: Date? = nil

    /// `true` once a valid token has been confirmed — gates the main dashboard.
    @Published var isOnboardingComplete: Bool = false
    /// OAuth2 client ID resolved from a validated token; used to build the invite URL.
    @Published var resolvedClientID: String? = nil
    /// Result from the most recent rich token validation; exposed for onboarding UI error display.
    @Published var lastTokenValidationResult: DiscordService.TokenValidationResult? = nil
    let isBetaBuild: Bool = (Bundle.main.object(forInfoDictionaryKey: "ShipHookIsBetaBuild") as? Bool) ?? false

    var logs = LogStore()
    let ruleStore = RuleStore()

    let store = ConfigStore()
    let discordCacheStore = DiscordCacheStore()
    let meshCursorStore = MeshCursorStore()
    let discordCache = DiscordCache()
    let service = DiscordService()
    let cluster = ClusterCoordinator()
    let adminWebServer = AdminWebServer()
    let clusterStatusService = ClusterStatusPollingService()
    let ruleEngine: RuleEngine
    let wikiContextCache = WikiContextCache()
    var serviceCallbacksConfigured = false
    var uptimeTask: Task<Void, Never>?
    var joinTimes: [String: Date] = [:]
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
    var botUserId: String?
    let launchedAt = Date()
    var clusterNodesRefreshTask: Task<Void, Never>?
    // P1b: off-peak background mesh refresh
    var backgroundRefreshScheduler: NSBackgroundActivityScheduler?
    @Published var botUsername: String = "OnlineBot"
    @Published var botDiscriminator: String?
    @Published var botAvatarHash: String?
    @Published var userAvatarHashById: [String: String] = [:]
    @Published var guildAvatarHashByMemberKey: [String: String] = [:]
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

    init() {
        self.ruleEngine = RuleEngine(store: ruleStore)
        self.pluginManager = PluginManager(bus: eventBus)
        if let store = try? JSONVersionStore(fileURL: PatchyRuntime.checkerStoreURL()) {
            self.patchyChecker = UpdateChecker(store: store)
        } else {
            self.patchyChecker = nil
        }

        Task {
            await startRateLimitCleanupTask()

            var loadedSettings = await store.load()
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
            // Worker mode is temporarily disabled pending UX redesign — migrate to Standalone.
            if loadedSettings.clusterMode == .worker {
                loadedSettings.clusterMode = .standalone
                workerModeMigrated = true
                migrated = true
            }

            settings = loadedSettings
            isOnboardingComplete = !loadedSettings.token.isEmpty
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
                    return await self.service.generateSmartDMReply(
                        messages: messages,
                        serverName: serverName,
                        channelName: channelName,
                        wikiContext: wikiContext
                    )
                },
                wikiHandler: { [weak self] query, source in
                    guard let self else { return nil }
                    return await self.service.lookupWiki(query: query, source: source)
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
                conversationFetcher: { [weak self] fromRecordID, limit in
                    guard let self else { return ([], false) }
                    return await self.conversationStore.recordsSince(fromRecordID: fromRecordID, limit: limit)
                },
                onPromotion: { [weak self] in
                    guard let self else { return }
                    // When promoted to leader, start connecting to Discord.
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        logs.append("🚀 Promoted to Primary. Connecting to Discord...")
                        Task { await self.connectDiscordAfterPromotion() }
                    }
                }
            )
            await service.configureLocalAIDMReplies(
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
                listenPort: settings.clusterListenPort,
                sharedSecret: settings.clusterSharedSecret,
                leaderTerm: settings.clusterLeaderTerm
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
        settings.adminWebUI.bindHost = settings.adminWebUI.bindHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "127.0.0.1"
            : settings.adminWebUI.bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAdminPort = min(max(settings.adminWebUI.port, 1), 65535)
        if normalizedAdminPort != settings.adminWebUI.port {
            logs.append("⚠️ Admin Web UI port was out of range. Clamped to \(normalizedAdminPort).")
            settings.adminWebUI.port = normalizedAdminPort
        }
        settings.adminWebUI.redirectPath = normalizedAdminRedirectPath(settings.adminWebUI.redirectPath)
        settings.adminWebUI.discordClientID = settings.adminWebUI.discordClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.discordClientSecret = settings.adminWebUI.discordClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.publicBaseURL = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.allowedUserIDs = settings.adminWebUI.normalizedAllowedUserIDs

        Task {
            await service.configureLocalAIDMReplies(
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
                listenPort: settings.clusterListenPort,
                sharedSecret: settings.clusterSharedSecret
            )
            await configureAdminWebServer()
            configurePatchyMonitoring()

            do {
                try await store.save(settings)
                logs.append("✅ Settings saved")
                await refreshAIStatus()
            } catch {
                stats.errors += 1
                logs.append("❌ Failed saving settings: \(error.localizedDescription)")
            }
        }
    }

    func saveMeshCursors(_ cursors: [String: ReplicationCursor]) async {
        do {
            try await meshCursorStore.save(cursors)
        } catch {
            logs.append("⚠️ Failed to save mesh cursors: \(error.localizedDescription)")
        }
    }

    func detectOllamaModel() {
        let base = normalizedOllamaBaseURL(from: settings.ollamaBaseURL)
        Task {
            guard let model = await service.detectOllamaModel(baseURL: base) else {
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
        let status = await service.currentAIStatus(
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

    func addPatchyTarget(_ target: PatchySourceTarget) {
        settings.patchy.sourceTargets.append(target)
        saveSettings()
        resolveSteamNameIfNeeded(for: target)
    }

    func addWikiBridgeSourceTarget(_ target: WikiSource) {
        settings.wikiBot.sources.append(target)
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func updateWikiBridgeSourceTarget(_ target: WikiSource) {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == target.id }) else { return }
        settings.wikiBot.sources[idx] = target
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func deleteWikiBridgeSourceTarget(_ targetID: UUID) {
        settings.wikiBot.sources.removeAll { $0.id == targetID }
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func toggleWikiBridgeSourceTargetEnabled(_ targetID: UUID) {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == targetID }) else { return }
        settings.wikiBot.sources[idx].enabled.toggle()
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func setWikiBridgePrimarySource(_ targetID: UUID) {
        settings.wikiBot.setPrimarySource(targetID)
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func testWikiBridgeSource(targetID: UUID) {
        Task {
            guard let target = settings.wikiBot.sources.first(where: { $0.id == targetID }) else { return }
            let usesWeaponCommand = target.commands.contains { normalizedWikiCommandTrigger($0.trigger) == "weapon" }
            let testQuery = usesWeaponCommand ? "AKM" : "Main Page"
            let result = await service.lookupWiki(query: testQuery, source: target)
            updateWikiBridgeSourceRuntimeState(id: targetID) { entry in
                entry.lastLookupAt = Date()
                if let result {
                    entry.lastStatus = "Resolved: \(result.title)"
                } else {
                    entry.lastStatus = "No result for \"\(testQuery)\""
                }
            }
            persistSettingsQuietly()
        }
    }

    func runWikiBridgeSourceTestQuery(source: WikiSource, query: String) async -> FinalsWikiLookupResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await service.lookupWiki(query: trimmed, source: source)
    }

    func updatePatchyTarget(_ target: PatchySourceTarget) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == target.id }) else { return }
        settings.patchy.sourceTargets[idx] = target
        saveSettings()
        resolveSteamNameIfNeeded(for: target)
    }

    func deletePatchyTarget(_ targetID: UUID) {
        settings.patchy.sourceTargets.removeAll { $0.id == targetID }
        saveSettings()
    }

    func togglePatchyTargetEnabled(_ targetID: UUID) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == targetID }) else { return }
        settings.patchy.sourceTargets[idx].isEnabled.toggle()
        saveSettings()
    }

    func setPatchyTargetEnabled(_ targetID: UUID, enabled: Bool) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == targetID }) else { return }
        settings.patchy.sourceTargets[idx].isEnabled = enabled
        saveSettings()
    }

    func runPatchyManualCheck() {
        Task {
            await runPatchyMonitoringCycle(trigger: "Manual")
        }
    }

    func sendPatchyTest(targetID: UUID) {
        Task {
            guard let target = settings.patchy.sourceTargets.first(where: { $0.id == targetID }) else { return }
            guard !target.channelId.isEmpty else {
                appendPatchyLog("Test send skipped: target channel is empty.")
                return
            }

            do {
                resolveSteamNameIfNeeded(for: target)
                let source = try PatchyRuntime.makeSource(from: target)
                let item = try await source.fetchLatest()
                let mapped = PatchyRuntime.map(item: item, change: .unchanged(identifier: item.identifier))
                let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                let delivery = await sendPatchyNotificationDetailed(
                    channelId: target.channelId,
                    message: fallback,
                    embedJSON: mapped.embedJSON,
                    roleIDs: target.roleIDs
                )

                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastRunAt = Date()
                    entry.lastStatus = delivery.detail
                }
                persistSettingsQuietly()
                appendPatchyLog("Test send [\(target.source.rawValue)] -> \(delivery.detail)")
            } catch {
                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastStatus = "Patchy test failed: \(error.localizedDescription)"
                }
                persistSettingsQuietly()
                appendPatchyLog("Patchy test failed: \(error.localizedDescription)")
            }
        }
    }

    func configurePatchyMonitoring() {
        patchyMonitorTask?.cancel()
        patchyMonitorTask = nil

        guard settings.patchy.monitoringEnabled else {
            appendPatchyLog("Patchy monitoring paused.")
            return
        }

        patchyMonitorTask = Task { [weak self] in
            guard let self else { return }
            await self.runPatchyMonitoringCycle(trigger: "Startup")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                if Task.isCancelled { break }
                await self.runPatchyMonitoringCycle(trigger: "Scheduled")
            }
        }
        appendPatchyLog("Patchy monitoring started (hourly).")
    }

    struct PatchySourceGroupKey: Hashable {
        let source: PatchySourceKind
        let steamAppID: String
    }

    func runPatchyMonitoringCycle(trigger: String) async {
        guard !patchyIsCycleRunning else { return }
        guard let patchyChecker else {
            appendPatchyLog("Patchy checker unavailable. Cycle skipped.")
            return
        }

        let enabledTargets = settings.patchy.sourceTargets.filter { $0.isEnabled && !$0.channelId.isEmpty }
        guard !enabledTargets.isEmpty else {
            appendPatchyLog("Patchy cycle (\(trigger)) skipped: no enabled targets.")
            patchyLastCycleAt = Date()
            return
        }

        patchyIsCycleRunning = true
        defer {
            patchyIsCycleRunning = false
            patchyLastCycleAt = Date()
        }

        let grouped = Dictionary(grouping: enabledTargets) { target in
            PatchySourceGroupKey(
                source: target.source,
                steamAppID: target.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        for (_, targets) in grouped {
            guard let referenceTarget = targets.first else { continue }

            do {
                resolveSteamNameIfNeeded(for: referenceTarget)
                let source = try PatchyRuntime.makeSource(from: referenceTarget)
                let item = try await source.fetchLatest()
                let mapped: PatchyFetchResult
                if let driverItem = item as? DriverUpdateItem {
                    let newestVersion = driverItem.version.trimmingCharacters(in: .whitespacesAndNewlines)
                    let versionKey = PatchyRuntime.lastPostedDriverVersionKey(for: item.sourceKey)
                    let versionCheck = try await patchyChecker.check(identifier: newestVersion, for: versionKey)
                    mapped = PatchyRuntime.map(item: item, change: versionCheck)
                    for target in targets {
                        updatePatchyTargetRuntimeState(id: target.id) { entry in
                            entry.lastCheckedAt = Date()
                            entry.lastStatus = mapped.statusSummary
                        }
                    }

                    switch versionCheck {
                    case .firstSeen:
                        try await patchyChecker.save(identifier: newestVersion, for: versionKey)
                        appendPatchyLog("Patchy driver baseline initialized [\(referenceTarget.source.rawValue)] version=\(newestVersion)")
                    case .unchanged:
                        break
                    case .changed(let oldVersion, _):
                        guard let comparison = PatchyRuntime.compareDriverVersions(newestVersion, oldVersion) else {
                            try await patchyChecker.save(identifier: newestVersion, for: versionKey)
                            appendPatchyLog("Patchy migrated legacy driver baseline [\(referenceTarget.source.rawValue)] old=\(oldVersion) new=\(newestVersion)")
                            break
                        }

                        guard comparison > 0 else {
                            appendPatchyLog("Patchy ignored non-newer driver [\(referenceTarget.source.rawValue)] latest=\(newestVersion) lastPosted=\(oldVersion)")
                            break
                        }

                        let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                        for target in targets {
                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: mapped.embedJSON,
                                roleIDs: target.roleIDs
                            )
                            updatePatchyTargetRuntimeState(id: target.id) { entry in
                                entry.lastRunAt = Date()
                                entry.lastStatus = delivery.detail
                            }
                            if delivery.ok {
                                try await patchyChecker.save(identifier: newestVersion, for: versionKey)
                            }
                        }
                    }
                } else if let steamItem = item as? SteamUpdateItem {
                    let newestStamp = PatchyRuntime.makeSteamOrderingStamp(item: steamItem)
                    let steamKey = PatchyRuntime.lastPostedSteamIdentifierKey(for: item.sourceKey)
                    let steamCheck = try await patchyChecker.check(identifier: newestStamp, for: steamKey)
                    mapped = PatchyRuntime.map(item: item, change: steamCheck)

                    for target in targets {
                        updatePatchyTargetRuntimeState(id: target.id) { entry in
                            entry.lastCheckedAt = Date()
                            entry.lastStatus = mapped.statusSummary
                        }
                    }

                    switch steamCheck {
                    case .firstSeen:
                        try await patchyChecker.save(identifier: newestStamp, for: steamKey)
                        appendPatchyLog("Patchy Steam baseline initialized [\(referenceTarget.steamAppID)] stamp=\(newestStamp)")
                    case .unchanged:
                        break
                    case .changed(let oldStamp, _):
                        guard let comparison = PatchyRuntime.compareSteamOrderingStamp(newestStamp, oldStamp) else {
                            try await patchyChecker.save(identifier: newestStamp, for: steamKey)
                            appendPatchyLog("Patchy migrated legacy Steam baseline [\(referenceTarget.steamAppID)] old=\(oldStamp) new=\(newestStamp)")
                            break
                        }

                        guard comparison > 0 else {
                            appendPatchyLog("Patchy ignored non-newer Steam item [\(referenceTarget.steamAppID)] latest=\(newestStamp) lastPosted=\(oldStamp)")
                            break
                        }

                        let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                        for target in targets {
                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: mapped.embedJSON,
                                roleIDs: target.roleIDs
                            )
                            updatePatchyTargetRuntimeState(id: target.id) { entry in
                                entry.lastRunAt = Date()
                                entry.lastStatus = delivery.detail
                            }
                            if delivery.ok {
                                try await patchyChecker.save(identifier: newestStamp, for: steamKey)
                            }
                        }
                    }
                } else {
                    let change = try await patchyChecker.check(item: item)
                    try await patchyChecker.save(item: item)
                    mapped = PatchyRuntime.map(item: item, change: change)

                    for target in targets {
                        updatePatchyTargetRuntimeState(id: target.id) { entry in
                            entry.lastCheckedAt = Date()
                            entry.lastStatus = mapped.statusSummary
                        }
                    }

                    if change.isNewItem {
                        let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                        for target in targets {
                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: mapped.embedJSON,
                                roleIDs: target.roleIDs
                            )
                            updatePatchyTargetRuntimeState(id: target.id) { entry in
                                entry.lastRunAt = Date()
                                entry.lastStatus = delivery.detail
                            }
                        }
                    }
                }
            } catch {
                for target in targets {
                    updatePatchyTargetRuntimeState(id: target.id) { entry in
                        entry.lastCheckedAt = Date()
                        entry.lastStatus = "Patchy check failed: \(error.localizedDescription)"
                    }
                }
                appendPatchyLog("Patchy cycle \(referenceTarget.source.rawValue) failed: \(error.localizedDescription)")
            }
        }

        persistSettingsQuietly()
    }

    func updatePatchyTargetRuntimeState(id: UUID, apply: (inout PatchySourceTarget) -> Void) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == id }) else { return }
        var target = settings.patchy.sourceTargets[idx]
        apply(&target)
        settings.patchy.sourceTargets[idx] = target
    }

    func updateWikiBridgeSourceRuntimeState(id: UUID, apply: (inout WikiSource) -> Void) {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == id }) else { return }
        var target = settings.wikiBot.sources[idx]
        apply(&target)
        settings.wikiBot.sources[idx] = target
    }

    func appendPatchyLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let final = "[\(stamp)] \(line)"
        patchyDebugLogs.insert(final, at: 0)
        if patchyDebugLogs.count > 200 {
            patchyDebugLogs.removeLast(patchyDebugLogs.count - 200)
        }
        logs.append("Patchy: \(line)")
    }

    func persistSettingsQuietly() {
        let snapshot = settings
        Task {
            do {
                try await store.save(snapshot)
            } catch {
                await MainActor.run {
                    self.logs.append("❌ Failed saving settings: \(error.localizedDescription)")
                }
            }
        }
    }

    func migrateLegacyPatchySettingsIfNeeded(_ loaded: inout BotSettings) -> Bool {
        guard loaded.patchy.sourceTargets.isEmpty, !loaded.patchy.targets.isEmpty else {
            return false
        }

        let migratedTargets = loaded.patchy.targets.map { legacy in
            PatchySourceTarget(
                isEnabled: legacy.isEnabled,
                source: loaded.patchy.source,
                steamAppID: loaded.patchy.steamAppID,
                serverId: legacy.serverId,
                channelId: legacy.channelId,
                roleIDs: legacy.roleIDs
            )
        }

        loaded.patchy.sourceTargets = migratedTargets
        return true
    }

    func migrateLegacyWikiBridgeSettingsIfNeeded(_ loaded: inout BotSettings) -> Bool {
        let previousTargets = loaded.wikiBot.sources.count
        let previousPrimary = loaded.wikiBot.sources.first(where: { $0.isPrimary })?.id
        loaded.wikiBot.normalizeSources()
        let currentPrimary = loaded.wikiBot.sources.first(where: { $0.isPrimary })?.id
        return previousTargets != loaded.wikiBot.sources.count || previousPrimary != currentPrimary
    }

    func startBot() async {
        // Worker mode is temporarily disabled pending UX redesign.
        // The underlying code is preserved; re-enable by removing this guard when ready.
        if settings.clusterMode == .worker {
            await MainActor.run {
                logs.append("⚠️ Worker mode is temporarily unavailable. Select Standalone, Primary, or Fail Over in Settings.")
            }
            return
        }

        await cluster.applySettings(
            mode: settings.clusterMode,
            nodeName: settings.clusterNodeName,
            leaderAddress: settings.clusterLeaderAddress,
            listenPort: settings.clusterListenPort,
            sharedSecret: settings.clusterSharedSecret,
            leaderTerm: settings.clusterLeaderTerm
        )

        let runtimeMode = await cluster.currentSnapshot().mode
        if runtimeMode == .standby {
            status = .stopped
            logs.append("Fail Over mode active. Monitoring Primary; Discord connection deferred until promotion.")
            return
        }

        let normalizedToken = normalizedDiscordToken(from: settings.token)
        if settings.token != normalizedToken {
            settings.token = normalizedToken
        }

        guard !normalizedToken.isEmpty else {
            logs.append("⚠️ Token is empty; cannot start bot")
            return
        }

        await connectDiscordInternal()
    }

    func connectDiscordAfterPromotion() async {
        let normalizedToken = normalizedDiscordToken(from: settings.token)
        if settings.token != normalizedToken {
            settings.token = normalizedToken
        }
        guard !normalizedToken.isEmpty else { return }
        await connectDiscordInternal()
    }

    func connectDiscordInternal() async {
        if !serviceCallbacksConfigured {
            await configureServiceCallbacks()
        }

        let token = normalizedDiscordToken(from: settings.token)
        if settings.token != token {
            settings.token = token
        }
        guard !token.isEmpty else {
            logs.append("⚠️ Token is empty; cannot connect")
            status = .stopped
            return
        }

        let tokenValidation = await service.validateBotTokenRich(token)
        lastTokenValidationResult = tokenValidation
        guard tokenValidation.isValid else {
            status = .stopped
            logs.append("❌ Token validation failed: \(tokenValidation.errorMessage)")
            return
        }

        status = .connecting
        uptime = UptimeInfo(startedAt: Date())
        activeVoice.removeAll()
        joinTimes.removeAll()
        userAvatarHashById.removeAll()
        guildAvatarHashByMemberKey.removeAll()
        gatewayEventCount = 0
        voiceStateEventCount = 0
        readyEventCount = 0
        guildCreateEventCount = 0
        lastGatewayEventName = "-"
        lastVoiceStateAt = nil
        lastVoiceStateSummary = "-"
        startUptimeTicker()

        let weekly = WeeklySummaryPlugin()
        self.weeklyPlugin = weekly
        Task { await pluginManager.add(weekly) }

        await service.connect(token: token)
        logs.append("Connecting to Discord Gateway")
    }

    // MARK: - Onboarding integration

    /// Validates the current token, resolves the OAuth2 client ID, and stores results for
    /// the onboarding UI. Returns `true` on success. Does NOT flip `isOnboardingComplete` —
    /// call `completeOnboarding()` after the user gives explicit confirmation.
    @discardableResult
    func validateAndOnboard() async -> Bool {
        let token = normalizedDiscordToken(from: settings.token)
        guard !token.isEmpty else { return false }
        let result = await service.validateBotTokenRich(token)
        lastTokenValidationResult = result
        guard result.isValid else { return false }
        let cid = await service.resolveClientID(token: token, fallbackUserID: result.userId)
        resolvedClientID = cid
        return true
    }

    /// Flips the onboarding gate after the user has explicitly confirmed they want to proceed.
    /// Persists settings through the Keychain path, then flips `isOnboardingComplete`.
    /// Must only be called after a successful `validateAndOnboard()`.
    func completeOnboarding() {
        saveSettings()
        isOnboardingComplete = true
    }

    /// Performs a safe API key reset with deterministic ordering:
    /// 1. Awaits gateway disconnect (cancels reconnect task, sets userInitiatedDisconnect).
    /// 2. Clears all bot runtime state.
    /// 3. Clears the token and persists via the Keychain-backed path (disk settings.json stays redacted).
    /// 4. Clears invite/token validation cache so setup can be run again on demand.
    func clearAPIKey() async {
        // Step 1: deterministic gateway disconnect — awaited before any state mutation.
        await service.disconnect()
        // Step 2: clear runtime state (mirrors stopBot without fire-and-forget disconnect).
        uptimeTask?.cancel()
        uptime = nil
        activeVoice.removeAll()
        joinTimes.removeAll()
        userAvatarHashById.removeAll()
        guildAvatarHashByMemberKey.removeAll()
        lastGatewayEventName = "-"
        lastVoiceStateAt = nil
        lastVoiceStateSummary = "-"
        botUserId = nil
        botUsername = "OnlineBot"
        botDiscriminator = nil
        botAvatarHash = nil
        Task { await pluginManager.removeAll() }
        Task { await cluster.stopAll() }
        status = .stopped
        // Step 3: secure token erase — empty token triggers KeychainHelper.deleteToken() in ConfigStore.
        settings.token = ""
        saveSettings()
        // Step 4: clear onboarding caches; caller decides whether to reopen setup flow.
        resolvedClientID = nil
        lastTokenValidationResult = nil
        logs.append("API key cleared. Please enter a new token to reconnect.")
    }

    /// Returns the app to the initial onboarding/setup screen.
    func runInitialSetup() {
        resolvedClientID = nil
        lastTokenValidationResult = nil
        isOnboardingComplete = false
    }

    /// Generates a Discord invite URL for the bot, resolving/storing client ID on demand.
    func generateInviteURL(includeSlashCommands: Bool? = nil) async -> String? {
        let cid: String
        if let existing = resolvedClientID {
            cid = existing
        } else {
            let token = normalizedDiscordToken(from: settings.token)
            guard !token.isEmpty else { return nil }
            let resolved = await service.resolveClientID(token: token, fallbackUserID: nil)
            if let resolved {
                resolvedClientID = resolved
                cid = resolved
            } else {
                let validation = await service.validateBotTokenRich(token)
                guard validation.isValid else {
                    lastTokenValidationResult = validation
                    return nil
                }
                lastTokenValidationResult = validation
                guard let fallback = await service.resolveClientID(token: token, fallbackUserID: validation.userId) else {
                    return nil
                }
                resolvedClientID = fallback
                cid = fallback
            }
        }
        let includeSlash = includeSlashCommands ?? (settings.commandsEnabled && settings.slashCommandsEnabled)
        return await service.generateInviteURL(clientId: cid, includeSlashCommands: includeSlash)
    }

    // MARK: - Diagnostics

    /// Whether the 10-second Test Connection UI cooldown has elapsed.
    var canRunTestConnection: Bool {
        guard let until = testConnectionCooldownUntil else { return true }
        return Date() >= until
    }

    /// Derived: gateway intents were accepted when Discord sent READY.
    var intentsAccepted: Bool? {
        switch status {
        case .running where readyEventCount > 0: return true
        case .stopped: return nil
        default: return nil
        }
    }

    /// Runs an on-demand REST health probe and updates `connectionDiagnostics`.
    /// Enforces a 10-second UI rate limit — callers must check `canRunTestConnection` first.
    func runTestConnection() async {
        guard canRunTestConnection else { return }
        testConnectionCooldownUntil = Date().addingTimeInterval(10)
        let token = normalizedDiscordToken(from: settings.token)
        guard !token.isEmpty else {
            connectionDiagnostics.lastTestAt = Date()
            connectionDiagnostics.lastTestMessage = "No token configured."
            connectionDiagnostics.restHealth = .error(0, "No token")
            return
        }
        let (isOK, httpStatus, remaining) = await service.restHealthProbe(token: token)
        let now = Date()
        connectionDiagnostics.lastTestAt = now
        connectionDiagnostics.rateLimitRemaining = remaining
        if isOK {
            connectionDiagnostics.restHealth = .ok
            connectionDiagnostics.lastTestMessage = "REST probe OK."
        } else {
            let code = httpStatus ?? 0
            let message = diagnosticsRemediationMessage(httpStatus: code)
            connectionDiagnostics.restHealth = .error(code, message)
            connectionDiagnostics.lastTestMessage = message
        }
    }

    func diagnosticsRemediationMessage(httpStatus: Int) -> String {
        switch httpStatus {
        case 401: return "401 Unauthorized — Token is invalid or revoked. Use Clear API Key to reset."
        case 403: return "403 Forbidden — Bot lacks required permissions. Re-invite with correct permissions."
        case 429: return "429 Rate Limited — Reduce request frequency. Discord will reset the limit automatically."
        case 0:   return "Network failure — Check your internet connection."
        default:  return "HTTP \(httpStatus) — Unexpected error from Discord REST API."
        }
    }

    func gatewayCloseRemediationMessage(code: Int) -> String {
        switch code {
        case 4004: return "Close 4004 — Authentication failed. Token is invalid. Use Clear API Key to reset."
        case 4014: return "Close 4014 — Privileged intent not enabled. Enable SERVER MEMBERS INTENT and MESSAGE CONTENT INTENT in the Discord Developer Portal → Bot tab."
        case 4013: return "Close 4013 — Invalid intents specified. Check the gateway intents bitmask (required: 37507)."
        case 4009: return "Close 4009 — Session timed out. The bot will reconnect automatically."
        case 4000: return "Close 4000 — Unknown gateway error. The bot will attempt to reconnect."
        default:   return "Close \(code) — Gateway closed with error. The bot will attempt to reconnect."
        }
    }

    func normalizedDiscordToken(from raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bot ") {
            token = String(token.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return token
    }

    func normalizedAdminRedirectPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/auth/discord/callback" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    func adminWebStatusSnapshot() -> AdminWebStatusPayload {
        AdminWebStatusPayload(
            botStatus: status.rawValue,
            botUsername: botUsername,
            connectedServerCount: connectedServers.count,
            gatewayEventCount: gatewayEventCount,
            uptimeText: uptime?.text,
            webUIEnabled: settings.adminWebUI.enabled,
            webUIBaseURL: adminWebBaseURL()
        )
    }

    func adminWebOverviewSnapshot() -> AdminWebOverviewPayload {
        let enabledWikiSourceCount = settings.wikiBot.sources.filter(\.enabled).count
        let patchyTargetCount = settings.patchy.sourceTargets.count
        let patchyEnabledTargetCount = settings.patchy.sourceTargets.filter(\.isEnabled).count
        let actionRuleCount = ruleStore.rules.count
        let enabledActionRuleCount = ruleStore.rules.filter(\.isEnabled).count
        let aiProviderSummary = settings.preferredAIProvider.rawValue
        let clusterLeader = clusterNodes.first(where: { $0.role == .leader })?.hostname
            ?? clusterNodes.first?.hostname
            ?? "Unavailable"
        let connectedNodes = clusterNodes.filter { $0.status != .disconnected }.count

        let metrics: [AdminWebMetricPayload] = [
            AdminWebMetricPayload(
                title: "Bot Status",
                value: status.rawValue.capitalized,
                subtitle: uptime?.text ?? "--"
            ),
            AdminWebMetricPayload(
                title: "Servers Connected",
                value: "\(connectedServers.count)",
                subtitle: settings.clusterMode == .standalone ? "Standalone" : settings.clusterMode.displayName
            ),
            AdminWebMetricPayload(
                title: "Users In Voice",
                value: "\(activeVoice.count)",
                subtitle: "users right now"
            ),
            AdminWebMetricPayload(
                title: "Commands Run",
                value: "\(stats.commandsRun)",
                subtitle: "this session"
            ),
            AdminWebMetricPayload(
                title: "WikiBridge Status",
                value: settings.wikiBot.isEnabled ? "Enabled" : "Disabled",
                subtitle: "\(enabledWikiSourceCount) sources"
            ),
            AdminWebMetricPayload(
                title: "Patchy Monitoring",
                value: settings.patchy.monitoringEnabled ? "Monitoring On" : "Monitoring Off",
                subtitle: "\(patchyEnabledTargetCount)/\(patchyTargetCount) targets"
            ),
            AdminWebMetricPayload(
                title: "Active Actions",
                value: "\(enabledActionRuleCount)",
                subtitle: "\(actionRuleCount) total rules"
            ),
            AdminWebMetricPayload(
                title: "AI Bots",
                value: aiProviderSummary,
                subtitle: settings.localAIDMReplyEnabled ? "DM replies enabled" : "DM replies disabled"
            )
        ]

        let recentVoice = Array(voiceLog.prefix(5)).map {
            AdminWebRecentVoicePayload(
                description: $0.description,
                timeText: $0.time.formatted(date: .omitted, time: .standard)
            )
        }

        let recentCommands = Array(commandLog.prefix(5)).map {
            AdminWebRecentCommandPayload(
                title: "\($0.user) @ \($0.server) • \($0.command)",
                timeText: $0.time.formatted(date: .omitted, time: .standard),
                ok: $0.ok
            )
        }

        let activeVoiceUsers = activeVoice
            .sorted { lhs, rhs in
                if lhs.guildId != rhs.guildId { return lhs.guildId < rhs.guildId }
                if lhs.channelName != rhs.channelName { return lhs.channelName.localizedCaseInsensitiveCompare(rhs.channelName) == .orderedAscending }
                return lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
            }
            .map { member in
                AdminWebActiveVoicePayload(
                    userId: member.userId,
                    username: member.username,
                    channelName: member.channelName,
                    serverName: connectedServers[member.guildId] ?? member.guildId,
                    joinedText: "Joined \(member.joinedAt.formatted(date: .omitted, time: .shortened))"
                )
            }

        return AdminWebOverviewPayload(
            metrics: metrics,
            cluster: AdminWebClusterPayload(
                connectedNodes: connectedNodes,
                leader: clusterLeader,
                mode: clusterSnapshot.mode.rawValue
            ),
            activeVoice: activeVoiceUsers,
            recentVoice: recentVoice,
            recentCommands: recentCommands,
            botInfo: AdminWebBotInfoPayload(
                uptime: uptime?.text ?? "--",
                errors: stats.errors,
                state: status.rawValue.capitalized,
                cluster: settings.clusterMode != .standalone ? clusterSnapshot.mode.rawValue : nil
            )
        )
    }

    func adminWebBaseURL() -> String {
        let explicit = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return explicit
        }
        return "http://\(settings.adminWebUI.bindHost):\(settings.adminWebUI.port)"
    }

    func adminWebConfigSnapshot() -> AdminWebConfigPayload {
        AdminWebConfigPayload(
            commands: .init(
                enabled: settings.commandsEnabled,
                prefixEnabled: settings.prefixCommandsEnabled,
                slashEnabled: settings.slashCommandsEnabled,
                bugTrackingEnabled: settings.bugTrackingEnabled,
                prefix: settings.prefix
            ),
            aiBots: .init(
                localAIDMReplyEnabled: settings.localAIDMReplyEnabled,
                preferredProvider: settings.preferredAIProvider.rawValue,
                openAIEnabled: settings.openAIEnabled,
                openAIModel: settings.openAIModel,
                openAIImageGenerationEnabled: settings.openAIImageGenerationEnabled,
                openAIImageMonthlyLimitPerUser: settings.openAIImageMonthlyLimitPerUser
            ),
            wikiBridge: .init(
                enabled: settings.wikiBot.isEnabled,
                enabledSources: settings.wikiBot.sources.filter(\.enabled).count,
                totalSources: settings.wikiBot.sources.count
            ),
            patchy: .init(
                monitoringEnabled: settings.patchy.monitoringEnabled,
                enabledTargets: settings.patchy.sourceTargets.filter(\.isEnabled).count,
                totalTargets: settings.patchy.sourceTargets.count
            ),
            swiftMesh: .init(
                mode: settings.clusterMode.rawValue,
                nodeName: settings.clusterNodeName,
                leaderAddress: settings.clusterLeaderAddress,
                listenPort: settings.clusterListenPort
            ),
            general: .init(
                autoStart: settings.autoStart,
                webUIEnabled: settings.adminWebUI.enabled,
                webUIBaseURL: adminWebBaseURL()
            )
        )
    }

    func applyAdminWebConfigPatch(_ patch: AdminWebConfigPatch) -> Bool {
        if let value = patch.commandsEnabled { settings.commandsEnabled = value }
        if let value = patch.prefixCommandsEnabled { settings.prefixCommandsEnabled = value }
        if let value = patch.slashCommandsEnabled { settings.slashCommandsEnabled = value }
        if let value = patch.bugTrackingEnabled { settings.bugTrackingEnabled = value }
        if let value = patch.prefix { settings.prefix = value }
        if let value = patch.localAIDMReplyEnabled { settings.localAIDMReplyEnabled = value }
        if let value = patch.preferredAIProvider,
           let provider = AIProviderPreference(rawValue: value) {
            settings.preferredAIProvider = provider
        }
        if let value = patch.openAIEnabled { settings.openAIEnabled = value }
        if let value = patch.openAIModel { settings.openAIModel = value }
        if let value = patch.openAIImageGenerationEnabled { settings.openAIImageGenerationEnabled = value }
        if let value = patch.openAIImageMonthlyLimitPerUser { settings.openAIImageMonthlyLimitPerUser = max(0, value) }
        if let value = patch.wikiBridgeEnabled { settings.wikiBot.isEnabled = value }
        if let value = patch.patchyMonitoringEnabled { settings.patchy.monitoringEnabled = value }
        if let value = patch.clusterMode,
           let mode = ClusterMode(rawValue: value) {
            settings.clusterMode = mode
        }
        if let value = patch.clusterNodeName { settings.clusterNodeName = value }
        if let value = patch.clusterLeaderAddress { settings.clusterLeaderAddress = value }
        if let value = patch.clusterListenPort { settings.clusterListenPort = max(1, value) }
        if let value = patch.autoStart { settings.autoStart = value }
        saveSettings()
        return true
    }

    func adminWebCommandCatalogSnapshot() -> AdminWebCommandCatalogPayload {
        struct VisualCommand {
            let id: String
            let name: String
            let usage: String
            let description: String
            let category: String
            let surface: String
            let aliases: [String]
            let adminOnly: Bool
        }

        let prefixCatalog = buildFullHelpCatalog(prefix: effectivePrefix())
        let prefixCommands = prefixCatalog.entries.map { entry in
            VisualCommand(
                id: "prefix-\(entry.name)",
                name: entry.name,
                usage: entry.usage,
                description: entry.description,
                category: entry.category.rawValue,
                surface: "prefix",
                aliases: entry.aliases,
                adminOnly: entry.isAdminOnly
            )
        }
        let slashCommands = allSlashCommandDefinitions().compactMap { raw -> VisualCommand? in
            guard let name = raw["name"] as? String else { return nil }
            let description = (raw["description"] as? String) ?? "No description"
            let options = (raw["options"] as? [[String: Any]]) ?? []
            let usageSuffix = options.compactMap { option in
                guard let optionName = option["name"] as? String else { return nil }
                let required = (option["required"] as? Bool) ?? false
                return required ? " \(optionName):<value>" : " [\(optionName):<value>]"
            }.joined()
            return VisualCommand(
                id: "slash-\(name)",
                name: name,
                usage: "/\(name)\(usageSuffix)",
                description: description,
                category: "Slash",
                surface: "slash",
                aliases: [],
                adminOnly: name == "debug"
            )
        }

        var commands = prefixCommands + slashCommands
        commands.append(
            VisualCommand(
                id: "mention-bug",
                name: "bug",
                usage: "@swiftbot bug (reply to a message)",
                description: "Creates a tracked bug report in #swiftbot-dev and manages status via reactions.",
                category: "Server",
                surface: "mention",
                aliases: [],
                adminOnly: true
            )
        )

        let items = commands.sorted { lhs, rhs in
            if lhs.surface != rhs.surface {
                return lhs.surface < rhs.surface
            }
            if lhs.category != rhs.category {
                return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        .map { command in
            AdminWebCommandCatalogItem(
                id: command.id,
                name: command.name,
                usage: command.usage,
                description: command.description,
                category: command.category,
                surface: command.surface.capitalized,
                aliases: command.aliases,
                adminOnly: command.adminOnly,
                enabled: isCommandEnabled(name: command.name, surface: command.surface)
            )
        }

        return AdminWebCommandCatalogPayload(
            commandsEnabled: settings.commandsEnabled,
            prefixCommandsEnabled: settings.prefixCommandsEnabled,
            slashCommandsEnabled: settings.slashCommandsEnabled,
            items: items
        )
    }

    func updateAdminWebCommandEnabled(name: String, surface: String, enabled: Bool) -> Bool {
        setCommandEnabled(name: name, surface: surface, enabled: enabled)
        saveSettings()
        if surface.lowercased() == "slash" {
            Task { await registerSlashCommandsIfNeeded() }
        }
        return true
    }

    func adminWebActionsSnapshot() -> AdminWebActionsPayload {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let servers = serverIDs.map { AdminWebSimpleOption(id: $0, name: connectedServers[$0] ?? $0) }

        let textChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableTextChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })
        let voiceChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableVoiceChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })

        return AdminWebActionsPayload(
            rules: ruleStore.rules,
            servers: servers,
            textChannelsByServer: textChannelsByServer,
            voiceChannelsByServer: voiceChannelsByServer,
            conditionTypes: ConditionType.allCases.map(\.rawValue),
            actionTypes: ActionType.allCases.map(\.rawValue)
        )
    }

    func adminWebPatchySnapshot() -> AdminWebPatchyPayload {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let servers = serverIDs.map { AdminWebSimpleOption(id: $0, name: connectedServers[$0] ?? $0) }
        let textChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableTextChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })
        let rolesByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let roles = (availableRolesByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, roles)
        })

        return AdminWebPatchyPayload(
            monitoringEnabled: settings.patchy.monitoringEnabled,
            showDebug: settings.patchy.showDebug,
            isCycleRunning: patchyIsCycleRunning,
            lastCycleAt: patchyLastCycleAt,
            debugLogs: Array(patchyDebugLogs.prefix(80)),
            sourceKinds: PatchySourceKind.allCases.map(\.rawValue),
            targets: settings.patchy.sourceTargets,
            servers: servers,
            textChannelsByServer: textChannelsByServer,
            rolesByServer: rolesByServer,
            steamAppNames: settings.patchy.steamAppNames
        )
    }

    func adminWebWikiBridgeSnapshot() -> AdminWebWikiBridgePayload {
        AdminWebWikiBridgePayload(
            enabled: settings.wikiBot.isEnabled,
            sources: settings.wikiBot.sources.sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary && !rhs.isPrimary }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        )
    }

    func updateAdminWebWikiBridgeState(_ patch: AdminWebWikiBridgeStatePatch) -> Bool {
        if let enabled = patch.enabled {
            settings.wikiBot.isEnabled = enabled
        }
        settings.wikiBot.normalizeSources()
        saveSettings()
        return true
    }

    func createAdminWebWikiSource() -> WikiSource? {
        let source = WikiSource.genericTemplate()
        addWikiBridgeSourceTarget(source)
        return source
    }

    func upsertAdminWebWikiSource(_ source: WikiSource) -> Bool {
        if settings.wikiBot.sources.contains(where: { $0.id == source.id }) {
            updateWikiBridgeSourceTarget(source)
        } else {
            addWikiBridgeSourceTarget(source)
        }
        return true
    }

    func setAdminWebWikiSourceEnabled(_ sourceID: UUID, enabled: Bool) -> Bool {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == sourceID }) else { return false }
        settings.wikiBot.sources[idx].enabled = enabled
        settings.wikiBot.normalizeSources()
        saveSettings()
        return true
    }

    func setAdminWebWikiSourcePrimary(_ sourceID: UUID) -> Bool {
        guard settings.wikiBot.sources.contains(where: { $0.id == sourceID }) else { return false }
        setWikiBridgePrimarySource(sourceID)
        return true
    }

    func testAdminWebWikiSource(_ sourceID: UUID) -> Bool {
        testWikiBridgeSource(targetID: sourceID)
        return true
    }

    func deleteAdminWebWikiSource(_ sourceID: UUID) -> Bool {
        deleteWikiBridgeSourceTarget(sourceID)
        return true
    }

    func updateAdminWebPatchyState(_ patch: AdminWebPatchyStatePatch) -> Bool {
        if let value = patch.monitoringEnabled {
            settings.patchy.monitoringEnabled = value
        }
        if let value = patch.showDebug {
            settings.patchy.showDebug = value
        }
        saveSettings()
        return true
    }

    func createAdminWebPatchyTarget() -> PatchySourceTarget? {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let serverID = serverIDs.first ?? ""
        let textChannelID = availableTextChannelsByServer[serverID]?.first?.id ?? ""
        let target = PatchySourceTarget(
            id: UUID(),
            isEnabled: true,
            source: .nvidia,
            steamAppID: "570",
            serverId: serverID,
            channelId: textChannelID,
            roleIDs: [],
            lastCheckedAt: nil,
            lastRunAt: nil,
            lastStatus: "Never checked"
        )
        addPatchyTarget(target)
        return target
    }

    func upsertAdminWebPatchyTarget(_ target: PatchySourceTarget) -> Bool {
        if settings.patchy.sourceTargets.contains(where: { $0.id == target.id }) {
            updatePatchyTarget(target)
        } else {
            addPatchyTarget(target)
        }
        return true
    }

    func deleteAdminWebPatchyTarget(_ targetID: UUID) -> Bool {
        deletePatchyTarget(targetID)
        return true
    }

    func setAdminWebPatchyTargetEnabled(_ targetID: UUID, enabled: Bool) -> Bool {
        setPatchyTargetEnabled(targetID, enabled: enabled)
        return true
    }

    func sendAdminWebPatchyTest(_ targetID: UUID) -> Bool {
        sendPatchyTest(targetID: targetID)
        return true
    }

    func runAdminWebPatchyCheckNow() -> Bool {
        runPatchyManualCheck()
        return true
    }

    func createAdminWebActionRule() -> Rule? {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let serverID = serverIDs.first ?? ""
        let textChannelID = availableTextChannelsByServer[serverID]?.first?.id ?? ""
        ruleStore.addNewRule(serverId: serverID, channelId: textChannelID)
        return ruleStore.rules.last
    }

    func upsertAdminWebActionRule(_ rule: Rule) -> Bool {
        if let index = ruleStore.rules.firstIndex(where: { $0.id == rule.id }) {
            ruleStore.rules[index] = rule
        } else {
            ruleStore.rules.append(rule)
        }
        ruleStore.scheduleAutoSave()
        return true
    }

    func deleteAdminWebActionRule(_ ruleID: UUID) -> Bool {
        let before = ruleStore.rules.count
        ruleStore.rules.removeAll { $0.id == ruleID }
        if before == ruleStore.rules.count {
            return false
        }
        if ruleStore.selectedRuleID == ruleID {
            ruleStore.selectedRuleID = ruleStore.rules.first?.id
        }
        ruleStore.scheduleAutoSave()
        return true
    }

    func updatePrefixFromAdmin(_ prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        settings.prefix = trimmed
        saveSettings()
        return true
    }

    func configureAdminWebServer() async {
        let config = AdminWebServer.Configuration(
            enabled: settings.adminWebUI.enabled,
            bindHost: settings.adminWebUI.bindHost,
            port: settings.adminWebUI.port,
            publicBaseURL: adminWebBaseURL(),
            discordClientID: settings.adminWebUI.discordClientID,
            discordClientSecret: settings.adminWebUI.discordClientSecret,
            redirectPath: settings.adminWebUI.redirectPath,
            allowedUserIDs: settings.adminWebUI.normalizedAllowedUserIDs
        )

        await adminWebServer.configure(
            config: config,
            statusProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebStatusPayload(
                        botStatus: "stopped",
                        botUsername: "SwiftBot",
                        connectedServerCount: 0,
                        gatewayEventCount: 0,
                        uptimeText: nil,
                        webUIEnabled: false,
                        webUIBaseURL: ""
                    )
                }
                return await MainActor.run { model.adminWebStatusSnapshot() }
            },
            overviewProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebOverviewPayload(
                        metrics: [],
                        cluster: AdminWebClusterPayload(connectedNodes: 0, leader: "Unavailable", mode: "standalone"),
                        activeVoice: [],
                        recentVoice: [],
                        recentCommands: [],
                        botInfo: AdminWebBotInfoPayload(uptime: "--", errors: 0, state: "Stopped", cluster: nil)
                    )
                }
                return await MainActor.run { model.adminWebOverviewSnapshot() }
            },
            connectedGuildIDsProvider: { [weak self] in
                guard let model = self else { return [] }
                return await MainActor.run { Set(model.connectedServers.keys) }
            },
            currentPrefixProvider: { [weak self] in
                guard let model = self else { return "/" }
                return await MainActor.run { model.settings.prefix }
            },
            updatePrefix: { [weak self] prefix in
                guard let model = self else { return false }
                return await MainActor.run { model.updatePrefixFromAdmin(prefix) }
            },
            configProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebConfigPayload(
                        commands: .init(enabled: true, prefixEnabled: true, slashEnabled: true, bugTrackingEnabled: true, prefix: "/"),
                        aiBots: .init(localAIDMReplyEnabled: false, preferredProvider: AIProviderPreference.apple.rawValue, openAIEnabled: false, openAIModel: "", openAIImageGenerationEnabled: false, openAIImageMonthlyLimitPerUser: 0),
                        wikiBridge: .init(enabled: false, enabledSources: 0, totalSources: 0),
                        patchy: .init(monitoringEnabled: false, enabledTargets: 0, totalTargets: 0),
                        swiftMesh: .init(mode: ClusterMode.standalone.rawValue, nodeName: "SwiftBot", leaderAddress: "", listenPort: 38787),
                        general: .init(autoStart: false, webUIEnabled: false, webUIBaseURL: "")
                    )
                }
                return await MainActor.run { model.adminWebConfigSnapshot() }
            },
            updateConfig: { [weak self] patch in
                guard let model = self else { return false }
                return await MainActor.run { model.applyAdminWebConfigPatch(patch) }
            },
            commandCatalogProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebCommandCatalogPayload(
                        commandsEnabled: true,
                        prefixCommandsEnabled: true,
                        slashCommandsEnabled: true,
                        items: []
                    )
                }
                return await MainActor.run { model.adminWebCommandCatalogSnapshot() }
            },
            updateCommandEnabled: { [weak self] name, surface, enabled in
                guard let model = self else { return false }
                return await MainActor.run { model.updateAdminWebCommandEnabled(name: name, surface: surface, enabled: enabled) }
            },
            actionsProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebActionsPayload(
                        rules: [],
                        servers: [],
                        textChannelsByServer: [:],
                        voiceChannelsByServer: [:],
                        conditionTypes: ConditionType.allCases.map(\.rawValue),
                        actionTypes: ActionType.allCases.map(\.rawValue)
                    )
                }
                return await MainActor.run { model.adminWebActionsSnapshot() }
            },
            createActionRule: { [weak self] in
                guard let model = self else { return nil }
                return await MainActor.run { model.createAdminWebActionRule() }
            },
            updateActionRule: { [weak self] rule in
                guard let model = self else { return false }
                return await MainActor.run { model.upsertAdminWebActionRule(rule) }
            },
            deleteActionRule: { [weak self] ruleID in
                guard let model = self else { return false }
                return await MainActor.run { model.deleteAdminWebActionRule(ruleID) }
            },
            patchyProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebPatchyPayload(
                        monitoringEnabled: false,
                        showDebug: false,
                        isCycleRunning: false,
                        lastCycleAt: nil,
                        debugLogs: [],
                        sourceKinds: PatchySourceKind.allCases.map(\.rawValue),
                        targets: [],
                        servers: [],
                        textChannelsByServer: [:],
                        rolesByServer: [:],
                        steamAppNames: [:]
                    )
                }
                return await MainActor.run { model.adminWebPatchySnapshot() }
            },
            updatePatchyState: { [weak self] patch in
                guard let model = self else { return false }
                return await MainActor.run { model.updateAdminWebPatchyState(patch) }
            },
            createPatchyTarget: { [weak self] in
                guard let model = self else { return nil }
                return await MainActor.run { model.createAdminWebPatchyTarget() }
            },
            updatePatchyTarget: { [weak self] target in
                guard let model = self else { return false }
                return await MainActor.run { model.upsertAdminWebPatchyTarget(target) }
            },
            setPatchyTargetEnabled: { [weak self] targetID, enabled in
                guard let model = self else { return false }
                return await MainActor.run { model.setAdminWebPatchyTargetEnabled(targetID, enabled: enabled) }
            },
            deletePatchyTarget: { [weak self] targetID in
                guard let model = self else { return false }
                return await MainActor.run { model.deleteAdminWebPatchyTarget(targetID) }
            },
            sendPatchyTestTarget: { [weak self] targetID in
                guard let model = self else { return false }
                return await MainActor.run { model.sendAdminWebPatchyTest(targetID) }
            },
            runPatchyCheckNow: { [weak self] in
                guard let model = self else { return false }
                return await MainActor.run { model.runAdminWebPatchyCheckNow() }
            },
            wikiBridgeProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebWikiBridgePayload(enabled: false, sources: [])
                }
                return await MainActor.run { model.adminWebWikiBridgeSnapshot() }
            },
            updateWikiBridgeState: { [weak self] patch in
                guard let model = self else { return false }
                return await MainActor.run { model.updateAdminWebWikiBridgeState(patch) }
            },
            createWikiSource: { [weak self] in
                guard let model = self else { return nil }
                return await MainActor.run { model.createAdminWebWikiSource() }
            },
            updateWikiSource: { [weak self] source in
                guard let model = self else { return false }
                return await MainActor.run { model.upsertAdminWebWikiSource(source) }
            },
            setWikiSourceEnabled: { [weak self] sourceID, enabled in
                guard let model = self else { return false }
                return await MainActor.run { model.setAdminWebWikiSourceEnabled(sourceID, enabled: enabled) }
            },
            setWikiSourcePrimary: { [weak self] sourceID in
                guard let model = self else { return false }
                return await MainActor.run { model.setAdminWebWikiSourcePrimary(sourceID) }
            },
            testWikiSource: { [weak self] sourceID in
                guard let model = self else { return false }
                return await MainActor.run { model.testAdminWebWikiSource(sourceID) }
            },
            deleteWikiSource: { [weak self] sourceID in
                guard let model = self else { return false }
                return await MainActor.run { model.deleteAdminWebWikiSource(sourceID) }
            },
            startBot: { [weak self] in
                guard let model = self else { return false }
                await model.startBot()
                return true
            },
            stopBot: { [weak self] in
                guard let model = self else { return false }
                await MainActor.run { model.stopBot() }
                return true
            },
            refreshSwiftMesh: { [weak self] in
                guard let model = self else { return false }
                _ = await MainActor.run { model.refreshClusterStatus() }
                return true
            },
            log: { [weak self] message in
                guard let model = self else { return }
                await MainActor.run { model.logs.append(message) }
            }
        )
    }

    func stopBot() {
        Task { await service.disconnect() }
        uptimeTask?.cancel()
        uptime = nil
        activeVoice.removeAll()
        joinTimes.removeAll()
        userAvatarHashById.removeAll()
        guildAvatarHashByMemberKey.removeAll()
        lastGatewayEventName = "-"
        lastVoiceStateAt = nil
        lastVoiceStateSummary = "-"
        botUserId = nil
        botUsername = "OnlineBot"
        botDiscriminator = nil
        botAvatarHash = nil
        Task { await pluginManager.removeAll() }
        status = .stopped
        // SwiftMesh intentionally keeps running — cluster topology is independent of Discord connection.
        logs.append("Bot stopped")
    }

    func refreshClusterStatus() {
        Task {
            await pollClusterStatus()
            let snapshot = await cluster.currentSnapshot()
            await MainActor.run {
                self.clusterSnapshot = snapshot
                self.logSwiftMeshStatus(snapshot, context: "Refresh")
            }
        }
    }

    func testWorkerLeaderConnection() {
        Task {
            await MainActor.run {
                self.workerConnectionTestInProgress = true
                self.workerConnectionTestIsSuccess = false
                self.workerConnectionTestStatus = "Testing connection..."
            }

            let outcome = await performWorkerConnectionTest(leaderAddress: settings.clusterLeaderAddress)

            await MainActor.run {
                self.workerConnectionTestInProgress = false
                self.workerConnectionTestIsSuccess = outcome.isSuccess
                self.workerConnectionTestStatus = outcome.message
                self.logs.append("SwiftMesh worker connection test: \(outcome.message)")
            }
        }
    }

    func refreshClusterStatusNow() async -> ClusterSnapshot {
        await pollClusterStatus()
        let snapshot = await cluster.currentSnapshot()
        self.clusterSnapshot = snapshot
        logSwiftMeshStatus(snapshot, context: "Refresh")
        return snapshot
    }

    func scheduleClusterNodesRefresh() {
        clusterNodesRefreshTask?.cancel()
        clusterNodesRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            await self.pollClusterStatus()
        }
    }

    func configureMeshSync() {
        meshSyncTask?.cancel()
        meshSyncTask = nil

        guard settings.clusterMode == .leader || settings.clusterMode == .standby else { return }

        meshSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                // Leader pushes, Standby pulls
                // Sync every 60 seconds
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }

                guard let self else { break }

                if self.settings.clusterMode == .leader {
                    // 1. Push worker registry to all nodes
                    await self.cluster.pushWorkerRegistryToStandbys()
                    // 2. Push incremental conversation batches per node
                    await self.pushIncrementalConversationsToAllNodes()
                } else if self.settings.clusterMode == .standby {
                    // 3. Standby: Pull Wiki Cache from Leader
                    await self.pullWikiCacheFromLeader()
                }
            }
        }
    }

    // MARK: - P1b: Off-peak background mesh refresh

    /// Schedules a low-priority background activity (15 min / 5 min tolerance) that fires
    /// existing standby/worker sync paths when the system is idle (NSBackgroundActivityScheduler).
    func setupBackgroundRefreshScheduler() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.swiftbot.meshBackgroundRefresh")
        scheduler.repeats = true
        scheduler.interval = 15 * 60        // 15 minutes
        scheduler.tolerance = 5 * 60        // 5-minute tolerance window
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completion in
            guard let self else { completion(.finished); return }
            Task {
                await self.runBackgroundMeshRefresh()
                completion(.finished)
            }
        }
        backgroundRefreshScheduler = scheduler
    }

    func runBackgroundMeshRefresh() async {
        guard settings.clusterMode == .standby || settings.clusterMode == .worker else { return }
        await requestResyncFromLeader(fromRecordID: localLastMergedRecordID)
    }

    /// Leader: push incremental conversation batches to each registered node using per-node cursors.
    func pushIncrementalConversationsToAllNodes() async {
        let nodes = await cluster.registeredNodeInfo()
        guard !nodes.isEmpty else { return }
        let currentTerm = await cluster.currentLeaderTerm()
        for (nodeName, baseURL) in nodes {
            let cursor = await cluster.currentReplicationCursor(for: nodeName)
            let fromID = cursor?.lastSentRecordID
            let (records, hasMore) = await conversationStore.recordsSince(fromRecordID: fromID, limit: 500)
            guard !records.isEmpty else { continue }
            let lastID = records.last?.id
            let payload = MeshSyncPayload(
                conversations: records,
                leaderTerm: currentTerm,
                cursorRecordID: lastID,
                hasMore: hasMore,
                fromCursorRecordID: fromID
            )
            let ok = await cluster.pushConversationsToSingleNode(baseURL, payload)
            if ok {
                await cluster.updateReplicationCursor(for: nodeName, lastSentRecordID: lastID, term: currentTerm)
            }
        }
    }

    func pullWikiCacheFromLeader() async {
        guard let data = await cluster.fetchWikiCache() else { return }
        if let entries = try? JSONDecoder().decode([WikiContextEntry].self, from: data) {
            for entry in entries {
                await wikiContextCache.upsertEntry(entry)
            }
            logs.append("SwiftMesh: pulled \(entries.count) wiki entry(s) from Primary")
        }
    }

    func applyClusterSettingsRuntime(mode: ClusterMode, nodeName: String, leaderAddress: String, listenPort: Int, sharedSecret: String) async {
        await cluster.applySettings(
            mode: mode,
            nodeName: nodeName,
            leaderAddress: leaderAddress,
            listenPort: listenPort,
            sharedSecret: sharedSecret,
            leaderTerm: settings.clusterLeaderTerm
        )
        configureMeshSync()
        await pollClusterStatus()
    }

    func pollClusterStatus() async {
        guard settings.clusterMode != .standalone else {
            clusterNodes = []
            return
        }

        let authHeaders = await meshStatusAuthHeaders(path: "/cluster/status", method: "GET", body: Data())
        guard let localURL = URL(string: "http://127.0.0.1:\(settings.clusterListenPort)/cluster/status"),
              let response = await clusterStatusService.fetchStatus(from: localURL, headers: authHeaders) else {
            clusterNodes = fallbackClusterNodes()
            return
        }

        clusterNodes = response.nodes.isEmpty ? fallbackClusterNodes() : response.nodes
    }

    private func meshStatusAuthHeaders(path: String, method: String, body: Data) async -> [String: String] {
        let secret = settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return [:] }

        let nonce = UUID().uuidString
        let timestamp = Int(Date().timeIntervalSince1970)
        let signature = await cluster.meshSignature(
            method: method,
            nonce: nonce,
            timestamp: timestamp,
            path: path,
            body: body
        )
        return [
            "X-Mesh-Nonce": nonce,
            "X-Mesh-Timestamp": String(timestamp),
            "X-Mesh-Signature": signature
        ]
    }

    func fallbackClusterNodes() -> [ClusterNodeStatus] {
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = ProcessInfo.processInfo.hostName
        let role: ClusterNodeRole = settings.clusterMode == .worker ? .worker : .leader
        let uptime = max(0, Date().timeIntervalSince(launchedAt))
        let hardwareInfo = HardwareInfo.current()
        var nodes: [ClusterNodeStatus] = [
            ClusterNodeStatus(
                id: "\(role.rawValue)-\(hostname.lowercased())-\(settings.clusterListenPort)",
                hostname: hostname,
                displayName: localNodeName,
                role: role,
                hardwareModel: hardwareInfo.modelIdentifier,
                cpu: 0,
                mem: 0,
                cpuName: hardwareInfo.cpuName,
                physicalMemoryBytes: hardwareInfo.physicalMemoryBytes,
                uptime: uptime,
                latencyMs: nil,
                status: clusterSnapshot.serverState.nodeHealthStatus,
                jobsActive: 0
            )
        ]

        if settings.clusterMode == .worker, !settings.clusterLeaderAddress.isEmpty {
            let host = URL(string: settings.clusterLeaderAddress)?.host ?? "Primary"
            nodes.append(
                ClusterNodeStatus(
                    id: "leader-\(host.lowercased())",
                    hostname: host,
                    displayName: host,
                    role: .leader,
                    hardwareModel: "Unknown",
                    cpu: 0,
                    mem: 0,
                    cpuName: "Unknown CPU",
                    physicalMemoryBytes: 0,
                    uptime: 0,
                    latencyMs: nil,
                    status: .disconnected,
                    jobsActive: 0
                )
            )
        }

        return nodes
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
        settings.clusterMode == .worker
            ? (isWorkerServiceRunning ? "Worker Online" : "Worker Offline")
            : (status == .running ? "Online" : "Offline")
    }

    var primaryServiceIsOnline: Bool {
        settings.clusterMode == .worker ? isWorkerServiceRunning : status == .running
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
        uptimeTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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

    func handleMemberJoin(_ raw: DiscordJSON?) async {
        // Legacy settings path still active for backward compatibility.
        // New config: use a "Member Joined" trigger rule in Actions instead.
        let legacyEnabled = settings.behavior.memberJoinWelcomeEnabled &&
            !settings.behavior.memberJoinWelcomeChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasRules = ruleStore.rules.contains { $0.isEnabled && $0.trigger == .memberJoined }
        guard legacyEnabled || hasRules else { return }

        guard case let .object(map)? = raw,
              case let .object(user)? = map["user"],
              case let .string(userId)? = user["id"]
        else { return }

        let guildId: String
        if case let .string(gid)? = map["guild_id"] { guildId = gid } else { return }

        let now = Date()

        // Increment member count for this guild (best-effort; sourced from GUILD_CREATE).
        let memberCount = (guildMemberCounts[guildId] ?? 0) + 1
        guildMemberCounts[guildId] = memberCount

        // Burst-guard: track join timestamps per guild; cap array to 50 entries.
        var timestamps = guildJoinTimestamps[guildId] ?? []
        timestamps = timestamps.filter { now.timeIntervalSince($0) < 5 }
        timestamps.append(now)
        if timestamps.count > 50 { timestamps = Array(timestamps.suffix(50)) }
        guildJoinTimestamps[guildId] = timestamps

        let burstThreshold = 10
        if timestamps.count > burstThreshold {
            // Raid-safe: summarize instead of individual welcome.
            if timestamps.count == burstThreshold + 1 {
                // Post once at the threshold crossing, not on every subsequent join.
                let channelId = settings.behavior.memberJoinWelcomeChannelId
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let serverName = connectedServers[guildId] ?? "the server"
                _ = await send(channelId, "👥 Multiple members joined \(serverName) — welcome everyone!")
                logs.append("Member join burst detected in \(guildId); switched to summary mode.")
            }
            return
        }

        // Dedupe: skip if same user joined this guild within 10 seconds.
        let dedupeKey = "\(guildId):\(userId)"
        if let last = recentMemberJoins[dedupeKey], now.timeIntervalSince(last) < 10 { return }
        recentMemberJoins[dedupeKey] = now
        // Bounded cleanup: cap at 500 entries, remove entries older than 60s.
        if recentMemberJoins.count > 500 {
            let pruned = recentMemberJoins.filter { now.timeIntervalSince($0.value) < 60 }
            recentMemberJoins = Dictionary(uniqueKeysWithValues: Array(pruned.prefix(500)))
        }

        let rawUsername: String
        if case let .string(name)? = user["global_name"] ?? user["username"] {
            rawUsername = name
        } else {
            rawUsername = "Unknown"
        }

        // Template sanitization: neutralize @everyone and @here to prevent mass-ping abuse.
        let safeUsername = rawUsername
            .replacingOccurrences(of: "@everyone", with: "@​everyone")
            .replacingOccurrences(of: "@here", with: "@​here")

        let serverName = connectedServers[guildId] ?? "the server"
        let message = settings.behavior.memberJoinWelcomeTemplate
            .replacingOccurrences(of: "{username}", with: safeUsername)
            .replacingOccurrences(of: "{server}", with: serverName)
            .replacingOccurrences(of: "{memberCount}", with: "\(memberCount)")

        if legacyEnabled {
            let channelId = settings.behavior.memberJoinWelcomeChannelId
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = await send(channelId, message)
        }

        // Rule-based execution: evaluate any enabled "Member Joined" trigger rules.
        let ruleEvent = VoiceRuleEvent(
            kind: .memberJoin,
            guildId: guildId,
            userId: userId,
            username: safeUsername,
            channelId: "",
            fromChannelId: nil,
            toChannelId: nil,
            durationSeconds: nil,
            messageContent: nil,
            messageId: nil,
            triggerMessageId: nil,
            triggerChannelId: nil,
            triggerGuildId: guildId,
            triggerUserId: userId,
            isDirectMessage: false
        )
        let matchedActions = ruleEngine.evaluate(event: ruleEvent)
        for action in matchedActions where action.type == .sendMessage {
            let ruleMessage = action.message
                .replacingOccurrences(of: "{username}", with: safeUsername)
                .replacingOccurrences(of: "{server}", with: serverName)
                .replacingOccurrences(of: "{memberCount}", with: "\(memberCount)")
                .replacingOccurrences(of: "{userId}", with: userId)
            let targetChannel = action.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetChannel.isEmpty else { continue }
            _ = await send(targetChannel, ruleMessage)
        }

        // Log username only — no internal IDs or metadata.
        addEvent(ActivityEvent(timestamp: now, kind: .info, message: "👋 \(safeUsername) joined \(serverName)"))
        logs.append("Member join welcome sent for \(safeUsername) in \(serverName)")
    }

    func handleGuildCreate(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw,
              case let .string(guildId)? = map["id"]
        else { return }

        if case let .int(count)? = map["member_count"] {
            guildMemberCounts[guildId] = count
        }

        let guildName: String?
        if case let .string(name)? = map["name"] {
            guildName = name
        } else {
            guildName = nil
        }

        await discordCache.upsertGuild(id: guildId, name: guildName)
        await discordCache.setGuildVoiceChannels(guildID: guildId, channels: parseVoiceChannels(from: map))
        await discordCache.setGuildTextChannels(guildID: guildId, channels: parseTextChannels(from: map))
        await discordCache.setGuildRoles(guildID: guildId, roles: parseRoles(from: map))
        await discordCache.mergeChannelTypes(parseChannelTypes(from: map))
        await cacheGuildMembers(from: map)
        await syncPublishedDiscordCacheFromService()
        await syncVoicePresenceFromGuildSnapshot(guildId: guildId, guildMap: map)
        scheduleDiscordCacheSave()
        await registerSlashCommandsIfNeeded()
    }

    func handleChannelCreate(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw,
              case let .string(channelId)? = map["id"],
              case let .int(type)? = map["type"]
        else { return }

        let guildId: String? = {
            if case let .string(id)? = map["guild_id"] { return id }
            return nil
        }()
        await discordCache.setChannelType(channelID: channelId, type: type)
        let name: String = {
            if case let .string(value)? = map["name"] { return value }
            return type == 1 ? "Direct Message" : (type == 3 ? "Group DM" : "Channel")
        }()
        await discordCache.upsertChannel(
            guildID: guildId,
            channelID: channelId,
            name: name,
            type: type
        )
        await syncPublishedDiscordCacheFromService()
        scheduleDiscordCacheSave()
    }

    func handleGuildDelete(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw,
              case let .string(guildId)? = map["id"]
        else { return }

        await discordCache.removeGuild(id: guildId)
        await syncPublishedDiscordCacheFromService()
        activeVoice.removeAll { $0.guildId == guildId }
        joinTimes = joinTimes.filter { !$0.key.hasPrefix("\(guildId)-") }
        scheduleDiscordCacheSave()
    }

    func patchyErrorDiagnostic(from error: Error) -> String {
        let ns = error as NSError
        let statusCode = ns.userInfo["statusCode"] as? Int ?? ns.code
        let body = (ns.userInfo["responseBody"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedBody: String
        if body.count > 220 {
            trimmedBody = String(body.prefix(220)) + "..."
        } else {
            trimmedBody = body
        }
        let bodySnippet = trimmedBody.isEmpty ? "-" : trimmedBody
        return "status=\(statusCode), error=\(error.localizedDescription), response=\(bodySnippet)"
    }

    func syncVoicePresenceFromGuildSnapshot(guildId: String, guildMap: [String: DiscordJSON]) async {
        guard case let .array(voiceStates)? = guildMap["voice_states"] else { return }

        activeVoice.removeAll { $0.guildId == guildId }
        joinTimes = joinTimes.filter { !$0.key.hasPrefix("\(guildId)-") }

        let now = Date()
        for state in voiceStates {
            guard case let .object(stateMap) = state,
                  case let .string(userId)? = stateMap["user_id"],
                  case let .string(channelId)? = stateMap["channel_id"]
            else { continue }

            if case let .object(member)? = stateMap["member"],
               case let .object(user)? = member["user"],
               case let .string(avatarHash)? = user["avatar"],
               !avatarHash.isEmpty {
                userAvatarHashById[userId] = avatarHash
                if case let .string(guildAvatarHash)? = member["avatar"], !guildAvatarHash.isEmpty {
                    guildAvatarHashByMemberKey["\(guildId)-\(userId)"] = guildAvatarHash
                }
            } else if case let .object(user)? = stateMap["user"],
                      case let .string(avatarHash)? = user["avatar"],
                      !avatarHash.isEmpty {
                userAvatarHashById[userId] = avatarHash
            }

            let username = await voiceDisplayName(from: stateMap, userId: userId)
            let key = "\(guildId)-\(userId)"
            let joinedAt = now
            joinTimes[key] = joinedAt

            activeVoice.append(
                VoiceMemberPresence(
                    id: key,
                    userId: userId,
                    username: username,
                    guildId: guildId,
                    channelId: channelId,
                    channelName: channelDisplayName(guildId: guildId, channelId: channelId),
                    joinedAt: joinedAt
                )
            )
        }
    }

    func cacheGuildMembers(from guildMap: [String: DiscordJSON]) async {
        guard case let .array(members)? = guildMap["members"] else { return }

        for member in members {
            guard case let .object(memberMap) = member else { continue }
            if case let .string(nick)? = memberMap["nick"], !nick.isEmpty,
               case let .object(user)? = memberMap["user"],
               case let .string(userId)? = user["id"] {
                await discordCache.upsertUser(id: userId, preferredName: nick)
                continue
            }

            guard case let .object(user)? = memberMap["user"],
                  case let .string(userId)? = user["id"] else { continue }

            if case let .string(avatarHash)? = user["avatar"], !avatarHash.isEmpty {
                userAvatarHashById[userId] = avatarHash
            }

            if case let .string(globalName)? = user["global_name"], !globalName.isEmpty {
                await discordCache.upsertUser(id: userId, preferredName: globalName)
            } else if case let .string(username)? = user["username"], !username.isEmpty {
                await discordCache.upsertUser(id: userId, preferredName: username)
            }
        }
    }

    func syncPublishedDiscordCacheFromService() async {
        let snapshot = await discordCache.currentSnapshot()
        connectedServers = snapshot.connectedServers
        availableVoiceChannelsByServer = snapshot.availableVoiceChannelsByServer
        availableTextChannelsByServer = snapshot.availableTextChannelsByServer
        availableRolesByServer = snapshot.availableRolesByServer
        knownUsersById = snapshot.usernamesById
    }

    func scheduleDiscordCacheSave() {
        discordCacheSaveTask?.cancel()
        discordCacheSaveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            do {
                let snapshot = await self.discordCache.currentSnapshot()
                try await discordCacheStore.save(snapshot)
            } catch {
                await MainActor.run {
                    self.logs.append("❌ Failed saving Discord cache: \(error.localizedDescription)")
                }
            }
        }
    }

    func resolveSteamNameIfNeeded(for target: PatchySourceTarget) {
        guard target.source == .steam else { return }
        let appID = target.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty else { return }
        if let existing = settings.patchy.steamAppNames[appID], !existing.isEmpty {
            return
        }

        Task {
            if let name = await fetchSteamAppName(appID: appID) {
                await MainActor.run {
                    self.settings.patchy.steamAppNames[appID] = name
                    self.persistSettingsQuietly()
                }
            }
        }
    }

    func fetchSteamAppName(appID: String) async -> String? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=english") else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let appNode = root[appID] as? [String: Any],
                let success = appNode["success"] as? Bool, success,
                let dataNode = appNode["data"] as? [String: Any],
                let name = dataNode["name"] as? String
            else {
                return nil
            }

            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }

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
}
