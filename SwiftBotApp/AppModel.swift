import Foundation
import SwiftUI
import UpdateEngine
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
    @Published var appleIntelligenceOnline = false
    @Published var ollamaOnline = false
    @Published var ollamaDetectedModel: String?
    @Published var patchyDebugLogs: [String] = []
    @Published var patchyIsCycleRunning = false
    @Published var patchyLastCycleAt: Date?
    @Published var workerModeMigrated = false
    // MARK: - P0.4 Diagnostics state

    struct ConnectionDiagnostics {
        enum RESTHealth { case unknown, ok, error(Int, String) }
        var heartbeatLatencyMs: Int? = nil
        var restHealth: RESTHealth = .unknown
        var rateLimitRemaining: Int? = nil
        var lastTestAt: Date? = nil
        var lastTestMessage: String = ""
        /// Last non-normal WebSocket close code from Discord (e.g. 4004, 4014). Nil = no abnormal close.
        var lastGatewayCloseCode: Int? = nil
    }

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

    private let store = ConfigStore()
    private let discordCacheStore = DiscordCacheStore()
    private let meshCursorStore = MeshCursorStore()
    private let discordCache = DiscordCache()
    private let service = DiscordService()
    private let cluster = ClusterCoordinator()
    private let clusterStatusService = ClusterStatusPollingService()
    private let ruleEngine: RuleEngine
    private let wikiContextCache = WikiContextCache()
    private var serviceCallbacksConfigured = false
    private var uptimeTask: Task<Void, Never>?
    private var joinTimes: [String: Date] = [:]
    private var discordCacheSaveTask: Task<Void, Never>?
    private var meshSyncTask: Task<Void, Never>?
    private let conversationStore = ConversationStore()
    /// Tracks the last MemoryRecord ID the standby successfully merged from the leader.
    private var localLastMergedRecordID: String?
    private var lastCommandTimeByUserId: [String: Date] = [:]
    /// Dedupe cache for GUILD_MEMBER_ADD: keyed by "guildId:userId", 10s window. Capped at 500 entries.
    private var recentMemberJoins: [String: Date] = [:]
    /// Approximate member count per guild, seeded from GUILD_CREATE and incremented on GUILD_MEMBER_ADD.
    private var guildMemberCounts: [String: Int] = [:]
    /// Burst-guard: recent join timestamps per guild (keyed by guildId). Used to detect member raids.
    private var guildJoinTimestamps: [String: [Date]] = [:]
    private let commandCooldown: TimeInterval = 3.0
    lazy var memoryViewModel = MemoryViewModel(store: conversationStore, discordCache: discordCache)
    let eventBus = EventBus()
    private let pluginManager: PluginManager
    private var weeklyPlugin: WeeklySummaryPlugin?
    private let patchyChecker: UpdateChecker?
    private var patchyMonitorTask: Task<Void, Never>?
    private var botUserId: String?
    private let launchedAt = Date()
    private var clusterNodesRefreshTask: Task<Void, Never>?
    // P1b: off-peak background mesh refresh
    private var backgroundRefreshScheduler: NSBackgroundActivityScheduler?
    @Published var botUsername: String = "OnlineBot"
    @Published var botDiscriminator: String?
    @Published var botAvatarHash: String?
    
    var botAvatarURL: URL? {
        guard let userId = botUserId, let hash = botAvatarHash else { return nil }
        let ext = hash.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/avatars/\(userId)/\(hash).\(ext)?size=128")
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
            settings.prefix = "!"
            logs.append("⚠️ Prefix cannot be empty. Reset to !")
        } else {
            settings.prefix = trimmedPrefix
        }
        settings.wikiBot.normalizeSources()

        Task {
            await service.configureLocalAIDMReplies(
                enabled: settings.localAIDMReplyEnabled,
                provider: settings.localAIProvider,
                preferredProvider: settings.preferredAIProvider,
                endpoint: localAIEndpointForService(),
                model: settings.localAIModel,
                systemPrompt: settings.localAISystemPrompt
            )
            await applyClusterSettingsRuntime(
                mode: settings.clusterMode,
                nodeName: settings.clusterNodeName,
                leaderAddress: settings.clusterLeaderAddress,
                listenPort: settings.clusterListenPort,
                sharedSecret: settings.clusterSharedSecret
            )
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

    private func saveMeshCursors(_ cursors: [String: ReplicationCursor]) async {
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
            ollamaModelHint: settings.localAIModel
        )
        appleIntelligenceOnline = status.appleOnline
        ollamaOnline = status.ollamaOnline
        ollamaDetectedModel = status.ollamaModel
    }

    private func normalizedOllamaBaseURL(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "http://localhost:11434" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "http://\(trimmed)"
    }

    private func localAIEndpointForService() -> String {
        if settings.localAIProvider == .ollama {
            return normalizedOllamaBaseURL(from: settings.ollamaBaseURL)
        }
        return settings.localAIEndpoint
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

    private func configurePatchyMonitoring() {
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

    private struct PatchySourceGroupKey: Hashable {
        let source: PatchySourceKind
        let steamAppID: String
    }

    private func runPatchyMonitoringCycle(trigger: String) async {
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
                let change = try await patchyChecker.check(item: item)
                try await patchyChecker.save(item: item)
                let mapped = PatchyRuntime.map(item: item, change: change)

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

    private func updatePatchyTargetRuntimeState(id: UUID, apply: (inout PatchySourceTarget) -> Void) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == id }) else { return }
        var target = settings.patchy.sourceTargets[idx]
        apply(&target)
        settings.patchy.sourceTargets[idx] = target
    }

    private func updateWikiBridgeSourceRuntimeState(id: UUID, apply: (inout WikiSource) -> Void) {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == id }) else { return }
        var target = settings.wikiBot.sources[idx]
        apply(&target)
        settings.wikiBot.sources[idx] = target
    }

    private func appendPatchyLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let final = "[\(stamp)] \(line)"
        patchyDebugLogs.insert(final, at: 0)
        if patchyDebugLogs.count > 200 {
            patchyDebugLogs.removeLast(patchyDebugLogs.count - 200)
        }
        logs.append("Patchy: \(line)")
    }

    private func persistSettingsQuietly() {
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

    private func migrateLegacyPatchySettingsIfNeeded(_ loaded: inout BotSettings) -> Bool {
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

    private func migrateLegacyWikiBridgeSettingsIfNeeded(_ loaded: inout BotSettings) -> Bool {
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

        if settings.clusterMode == .standby {
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

    private func connectDiscordAfterPromotion() async {
        let normalizedToken = normalizedDiscordToken(from: settings.token)
        if settings.token != normalizedToken {
            settings.token = normalizedToken
        }
        guard !normalizedToken.isEmpty else { return }
        await connectDiscordInternal()
    }

    private func connectDiscordInternal() async {
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
    /// 4. Resets all onboarding and session state so the user returns to the onboarding gate.
    func clearAPIKey() async {
        // Step 1: deterministic gateway disconnect — awaited before any state mutation.
        await service.disconnect()
        // Step 2: clear runtime state (mirrors stopBot without fire-and-forget disconnect).
        uptimeTask?.cancel()
        uptime = nil
        activeVoice.removeAll()
        joinTimes.removeAll()
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
        // Step 4: onboarding/session state purge → gate returns to onboarding splash.
        resolvedClientID = nil
        lastTokenValidationResult = nil
        isOnboardingComplete = false
        logs.append("API key cleared. Please enter a new token to reconnect.")
    }

    /// Generates a Discord invite URL for the bot using the resolved OAuth2 client ID.
    /// Returns `nil` if `resolvedClientID` has not yet been set.
    func generateInviteURL(includeSlashCommands: Bool = false) async -> String? {
        guard let cid = resolvedClientID else { return nil }
        return await service.generateInviteURL(clientId: cid, includeSlashCommands: includeSlashCommands)
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

    private func diagnosticsRemediationMessage(httpStatus: Int) -> String {
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

    private func normalizedDiscordToken(from raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bot ") {
            token = String(token.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return token
    }

    func stopBot() {
        Task { await service.disconnect() }
        uptimeTask?.cancel()
        uptime = nil
        activeVoice.removeAll()
        joinTimes.removeAll()
        lastGatewayEventName = "-"
        lastVoiceStateAt = nil
        lastVoiceStateSummary = "-"
        botUserId = nil
        botUsername = "OnlineBot"
        botDiscriminator = nil
        botAvatarHash = nil
        Task { await pluginManager.removeAll() }
        status = .stopped
        Task { await cluster.stopAll() }
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

    private func scheduleClusterNodesRefresh() {
        clusterNodesRefreshTask?.cancel()
        clusterNodesRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            await self.pollClusterStatus()
        }
    }

    private func configureMeshSync() {
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
    private func setupBackgroundRefreshScheduler() {
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

    private func runBackgroundMeshRefresh() async {
        guard settings.clusterMode == .standby || settings.clusterMode == .worker else { return }
        await requestResyncFromLeader(fromRecordID: localLastMergedRecordID)
    }

    /// Leader: push incremental conversation batches to each registered node using per-node cursors.
    private func pushIncrementalConversationsToAllNodes() async {
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

    private func pullWikiCacheFromLeader() async {
        guard let normalizedLeader = await cluster.normalizedLeaderBaseURL(settings.clusterLeaderAddress),
              let leaderURL = URL(string: normalizedLeader + "/v1/mesh/sync/wiki-cache") else { return }
        
        do {
            var request = URLRequest(url: leaderURL)
            request.httpMethod = "GET"
            if !settings.clusterSharedSecret.isEmpty {
                request.setValue(settings.clusterSharedSecret, forHTTPHeaderField: "X-Cluster-Secret")
            }
            request.timeoutInterval = 15
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            
            if let entries = try? JSONDecoder().decode([WikiContextEntry].self, from: data) {
                for entry in entries {
                    await wikiContextCache.upsertEntry(entry)
                }
                logs.append("SwiftMesh: pulled \(entries.count) wiki entry(s) from Primary")
            }
        } catch {
            // best effort
        }
    }

    private func applyClusterSettingsRuntime(mode: ClusterMode, nodeName: String, leaderAddress: String, listenPort: Int, sharedSecret: String) async {
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

        guard let localURL = URL(string: "http://127.0.0.1:\(settings.clusterListenPort)/cluster/status"),
              let response = await clusterStatusService.fetchStatus(from: localURL) else {
            clusterNodes = fallbackClusterNodes()
            return
        }

        clusterNodes = response.nodes.isEmpty ? fallbackClusterNodes() : response.nodes
    }

    private func fallbackClusterNodes() -> [ClusterNodeStatus] {
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

    private func configureServiceCallbacks() async {
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

    private func startUptimeTicker() {
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

    private func addEvent(_ event: ActivityEvent) {
        events.insert(event, at: 0)
        if events.count > 20 { events.removeLast(events.count - 20) }
    }

    func handlePayload(_ payload: GatewayPayload) async {
        guard payload.op == 0, let eventName = payload.t else { return }

        gatewayEventCount += 1
        lastGatewayEventName = eventName

        switch eventName {
        case "MESSAGE_CREATE":
            await handleMessageCreate(payload.d)
        case "VOICE_STATE_UPDATE":
            voiceStateEventCount += 1
            await handleVoiceStateUpdate(payload.d)
        case "READY":
            readyEventCount += 1
            // Clear any stale close-code state — a new READY means the gateway is healthy.
            connectionDiagnostics.lastGatewayCloseCode = nil
            await handleReady(payload.d)
            logs.append("READY received")
            if case let .object(map)? = payload.d,
               case let .object(user)? = map["user"] {
                if case let .string(id)? = user["id"] {
                    botUserId = id
                }
                if case let .string(username)? = user["username"] {
                    botUsername = username
                }
                if case let .string(discriminator)? = user["discriminator"] {
                    botDiscriminator = discriminator != "0" ? discriminator : nil
                }
                if case let .string(avatarHash)? = user["avatar"] {
                    botAvatarHash = avatarHash
                }
            }
        case "GUILD_CREATE":
            guildCreateEventCount += 1
            await handleGuildCreate(payload.d)
        case "CHANNEL_CREATE":
            await handleChannelCreate(payload.d)
        case "GUILD_MEMBER_ADD":
            await handleMemberJoin(payload.d)
        case "GUILD_DELETE":
            await handleGuildDelete(payload.d)
        default:
            break
        }
    }

    private func handleMeshSync(_ payload: MeshSyncPayload) async {
        // Gap detection: if leader assumed we held cursor X but we actually hold Y, resync from Y.
        if let expectedFrom = payload.fromCursorRecordID,
           expectedFrom != localLastMergedRecordID {
            logs.append("SwiftMesh: gap detected — requesting resync from \(localLastMergedRecordID ?? "start")")
            await requestResyncFromLeader(fromRecordID: localLastMergedRecordID)
            return
        }

        // Idempotent merge.
        for record in payload.conversations {
            await conversationStore.appendIfNotExists(
                scope: record.scope,
                messageID: record.id,
                userID: record.userID,
                content: record.content,
                role: record.role,
                timestamp: record.timestamp
            )
        }
        if let lastID = payload.conversations.last?.id {
            localLastMergedRecordID = lastID
        }
        if !payload.conversations.isEmpty {
            logs.append("SwiftMesh: merged \(payload.conversations.count) record(s) (term \(payload.leaderTerm))")
        }
        // Fetch next page immediately if more records exist.
        if payload.hasMore {
            await requestResyncFromLeader(fromRecordID: localLastMergedRecordID)
        }
    }

    /// Standby requests a bounded page of records from the leader starting after `fromRecordID`.
    private func requestResyncFromLeader(fromRecordID: String?) async {
        guard let normalizedLeader = await cluster.normalizedLeaderBaseURL(settings.clusterLeaderAddress),
              let url = URL(string: normalizedLeader + "/v1/mesh/sync/conversations/resync") else { return }
        let req = MeshResyncRequest(fromRecordID: fromRecordID, pageSize: 500)
        guard let body = try? JSONEncoder().encode(req) else { return }
        do {
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !settings.clusterSharedSecret.isEmpty {
                urlRequest.setValue(settings.clusterSharedSecret, forHTTPHeaderField: "X-Cluster-Secret")
            }
            urlRequest.timeoutInterval = 15
            urlRequest.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let payload = try? JSONDecoder().decode(MeshSyncPayload.self, from: data) else { return }
            await handleMeshSync(payload)
        } catch {
            // best effort
        }
    }

    private func handleMeshRequest(type: String) async -> Data? {
        switch type {
        case "wiki-cache":
            let all = await wikiContextCache.allEntries()
            return try? JSONEncoder().encode(all)
        default:
            return nil
        }
    }

    /// Checks if a user is rate limited.
    /// - Parameters:
    ///   - userId: The Discord user ID.
    ///   - username: The Discord username (for logging).
    ///   - channelId: The channel ID to send feedback to if DM.
    ///   - isDM: Whether the message is a DM.
    /// - Returns: True if the command is allowed, false if rate limited.
    /// Note: Throttled commands in guild channels are silently dropped.
    /// DMs receive a "Cooldown active" feedback message.
    private func checkRateLimit(userId: String, username: String, channelId: String, isDM: Bool) async -> Bool {
        if let lastTime = lastCommandTimeByUserId[userId] {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < commandCooldown {
                logs.append("⚠️ Throttling \(username) (elapsed: \(String(format: "%.1fs", elapsed)))")
                if isDM {
                    _ = await send(channelId, "Cooldown active. Please wait a few seconds.")
                }
                return false
            }
        }
        lastCommandTimeByUserId[userId] = Date()
        return true
    }

    private func startRateLimitCleanupTask() async {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                if Task.isCancelled { break }
                await MainActor.run {
                    self.cleanupRateLimitCache()
                }
            }
        }
    }

    private func cleanupRateLimitCache() {
        let now = Date()
        let expired = lastCommandTimeByUserId.filter { now.timeIntervalSince($1) > 60.0 }.map { $0.key }
        for key in expired {
            lastCommandTimeByUserId.removeValue(forKey: key)
        }
        if !expired.isEmpty {
            logs.append("🧹 Cleaned up \(expired.count) rate limit cache entries")
        }
    }

    private func handleMessageCreate(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw,
              case let .string(content)? = map["content"],
              case let .object(author)? = map["author"],
              case let .string(username)? = author["username"],
              case let .string(channelId)? = map["channel_id"]
        else { return }

        let userId: String = {
            if case let .string(id)? = author["id"] { return id }
            return "unknown-user"
        }()
        let messageId: String = {
            if case let .string(id)? = map["id"] { return id }
            return UUID().uuidString
        }()
        let isBot = (author["bot"] == .bool(true))
        let channelType = await resolvedChannelType(from: map, channelID: channelId)
        let isDMChannel = (channelType == 1 || channelType == 3)
        let isGuildTextChannel = (channelType == 0)

        let guildID: String? = {
            if case let .string(id)? = map["guild_id"] { return id }
            return nil
        }()
        await upsertDiscordCacheFromMessage(
            map: map,
            guildID: guildID,
            channelID: channelId,
            channelType: channelType,
            userID: userId,
            fallbackUsername: username
        )

        // Ignore messages from bots (including this bot) to prevent reply loops.
        if isBot {
            return
        }

        let prefix = effectivePrefix()
        if isDMChannel, !settings.behavior.allowDMs {
            _ = await send(channelId, "DM support is disabled. If you need help, use \(prefix)help in a server channel.")
            return
        }

        if isDMChannel, !content.hasPrefix(prefix) {
            if settings.localAIDMReplyEnabled {
                guard await checkRateLimit(userId: userId, username: username, channelId: channelId, isDM: true) else { return }

                let scope = MemoryScope.directMessageUser(userId)
                let (messages, wikiContext) = await aiMessagesForScope(
                    scope: scope,
                    currentUserID: userId,
                    currentContent: content
                )
                
                var serverName: String? = nil
                if let gid = guildID {
                    serverName = await discordCache.guildName(for: gid)
                }
                let channelName = await discordCache.channelName(for: channelId)

                let outcome = await generateAIReplyWithTimeout(
                    channelId: channelId,
                    messages: messages,
                    serverName: serverName,
                    channelName: channelName,
                    wikiContext: wikiContext
                )
                switch outcome {
                case .reply(let aiReply):
                    await conversationStore.append(
                        scope: scope,
                        messageID: messageId,
                        userID: userId,
                        content: content,
                        role: .user
                    )
                    let sent = await send(channelId, aiReply)
                    if sent { await appendAssistantMessage(scope: scope, content: aiReply) }
                    return
                case .handledFallback:
                    // Timeout fallback already sent — do not emit a second message.
                    return
                case .noReply:
                    break
                }
            }

            _ = await send(channelId, "If you need help, type \(prefix)help.")
            return
        }

        await eventBus.publish(MessageReceived(
            guildId: guildID,
            channelId: channelId,
            userId: userId,
            username: username,
            content: content,
            isDirectMessage: isDMChannel
        ))

        if isGuildTextChannel,
           settings.localAIDMReplyEnabled,
           settings.behavior.useAIInGuildChannels,
           isMentioningBot(map),
           !content.hasPrefix(prefix) {
            let prompt = contentWithoutBotMention(content)
            if !prompt.isEmpty {
                guard await checkRateLimit(userId: userId, username: username, channelId: channelId, isDM: false) else { return }

                let scope = MemoryScope.guildTextChannel(channelId)
                let (messages, wikiContext) = await aiMessagesForScope(
                    scope: scope,
                    currentUserID: userId,
                    currentContent: prompt
                )
                var serverName: String? = nil
                if let gid = guildID {
                    serverName = await discordCache.guildName(for: gid)
                }
                let channelName = await discordCache.channelName(for: channelId)

                if case .reply(let aiReply) = await generateAIReplyWithTimeout(
                    channelId: channelId,
                    messages: messages,
                    serverName: serverName,
                    channelName: channelName,
                    wikiContext: wikiContext
                ) {
                    await conversationStore.append(
                        scope: scope,
                        messageID: messageId,
                        userID: userId,
                        content: prompt,
                        role: .user
                    )
                    let sent = await send(channelId, aiReply)
                    if sent { await appendAssistantMessage(scope: scope, content: aiReply) }
                    return
                }
            }
        }

        guard content.hasPrefix(prefix) else { return }

        guard await checkRateLimit(userId: userId, username: username, channelId: channelId, isDM: isDMChannel) else { return }

        stats.commandsRun += 1
        let commandText = String(content.dropFirst(prefix.count))
        let commandName = commandText.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        let result = await executeCommand(commandText, username: username, channelId: channelId, raw: map)
        let serverName = commandServerName(from: map)
        let executionDetails = await commandExecutionDetails(for: commandName)
        addEvent(ActivityEvent(timestamp: Date(), kind: .command, message: "\(username): \(content)"))
        commandLog.insert(CommandLogEntry(
            time: Date(),
            user: username,
            server: serverName,
            command: content,
            channel: channelId,
            executionRoute: executionDetails.route,
            executionNode: executionDetails.node,
            ok: result
        ), at: 0)
        logs.append(result ? "✅ Command success: \(content)" : "❌ Command failed: \(content)")
        if !result { stats.errors += 1 }
    }

    private func executeCommand(_ commandText: String, username: String, channelId: String, raw: [String: DiscordJSON]) async -> Bool {
        let tokens = commandText.split(separator: " ").map(String.init)
        guard let command = tokens.first?.lowercased() else { return false }

        let prefix = effectivePrefix()

        switch command {
        case "help":
            let catalog = buildHelpCatalog(prefix: prefix)
            let renderer = HelpRenderer(prefix: prefix, helpSettings: settings.help)
            let targetCommand = tokens.dropFirst().first?.lowercased()

            // `!help <command>` — send detailed text reply (with examples).
            if let target = targetCommand {
                if let entry = catalog.entry(for: target) {
                    return await send(channelId, renderer.detail(for: entry))
                } else {
                    return await send(channelId, "❓ Unknown command `\(prefix)\(target)`. Type `\(prefix)help` for a full list.")
                }
            }

            // `!help` — send embed overview.
            // Smart/Hybrid: attempt AI-generated intro for embed description; embed fields are always catalog-sourced.
            var aiIntro: String? = nil
            if settings.help.mode != .classic {
                let msg = Message(
                    channelID: channelId,
                    userID: "help-request",
                    username: "user",
                    content: "Write a short intro for a SwiftBot help embed.",
                    role: .user
                )
                aiIntro = await service.generateHelpReply(messages: [msg], systemPrompt: renderer.aiIntroPrompt(catalog: catalog))
            }

            let embed = renderer.embedOverview(catalog: catalog, aiDescription: aiIntro)
            return await sendEmbed(channelId, embed: embed)
        case "ping":
            return await send(channelId, "🏓 Pong! Gateway latency is currently live via heartbeat ACK.")
        case "roll":
            guard tokens.count >= 2, let output = rollDice(tokens[1]) else { return await unknown(channelId) }
            return await send(channelId, output)
        case "8ball":
            let responses = ["Yes.", "No.", "It is certain.", "Ask again later.", "Very doubtful."]
            return await send(channelId, "🎱 \(responses.randomElement()!)")
        case "poll":
            return await send(channelId, "📊 Poll created! Add reactions to vote.")
        case "userinfo":
            return await send(channelId, "👤 User: \(username)")
        case "cluster", "worker":
            let action = tokens.dropFirst().first?.lowercased() ?? "status"
            return await clusterCommand(action: action, channelId: channelId)
        case "setchannel":
            return await setNotificationChannel(for: raw, currentChannelId: channelId)
        case "ignorechannel":
            return await updateIgnoredChannels(tokens: tokens, raw: raw, responseChannelId: channelId)
        case "notifystatus":
            return await notifyStatus(raw: raw, responseChannelId: channelId)
        case "weekly":
            let report = weeklyPlugin?.snapshotSummary() ?? "No data yet."
            return await send(channelId, report)
        default:
            if let resolvedWikiCommand = resolveWikiCommand(named: command) {
                guard settings.wikiBot.isEnabled else {
                    return await send(channelId, "📘 WikiBridge is disabled. Enable it from the WikiBridge page.")
                }
                let query = tokens.dropFirst().joined(separator: " ")
                return await performWikiLookup(
                    command: resolvedWikiCommand.command,
                    source: resolvedWikiCommand.source,
                    query: query,
                    channelId: channelId
                )
            }
            _ = await unknown(channelId)
            return false
        }
    }

    private func unknown(_ channelId: String) async -> Bool {
        await send(channelId, "❓ I don't know that command! Type \(effectivePrefix())help to see all available commands.")
    }

    private struct ResolvedWikiCommand {
        let source: WikiSource
        let command: WikiCommand
    }

    private func resolveWikiCommand(named commandName: String) -> ResolvedWikiCommand? {
        let normalizedName = normalizedWikiCommandTrigger(commandName)
        guard !normalizedName.isEmpty else { return nil }

        for source in orderedEnabledWikiSources() {
            for command in source.commands where command.enabled {
                if normalizedWikiCommandTrigger(command.trigger) == normalizedName {
                    return ResolvedWikiCommand(source: source, command: command)
                }
            }
        }

        return nil
    }

    private func wikiCommandHelpList(prefix: String) -> String {
        var seen: Set<String> = []
        var display: [String] = []

        for source in orderedEnabledWikiSources() {
            for command in source.commands where command.enabled {
                let normalized = normalizedWikiCommandTrigger(command.trigger)
                guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
                display.append("\(prefix)\(normalized)")
            }
        }

        return display.joined(separator: ", ")
    }

    /// Builds the full CommandCatalog including all enabled WikiBridge commands.
    private func buildHelpCatalog(prefix: String) -> CommandCatalog {
        var wikiCmds: [WikiCommandInfo] = []
        for source in orderedEnabledWikiSources() {
            for command in source.commands where command.enabled {
                let key = normalizedWikiCommandTrigger(command.trigger)
                guard !key.isEmpty else { continue }
                wikiCmds.append(WikiCommandInfo(trigger: key, sourceName: source.name, description: command.description))
            }
        }
        return CommandCatalog.build(prefix: prefix, wikiCommands: wikiCmds)
    }

    /// Ensures custom intro/footer are always applied to AI help output.
    /// Deterministic help rendering already includes this shell.

    private func orderedEnabledWikiSources() -> [WikiSource] {
        let enabledSources = settings.wikiBot.sources.filter(\.enabled)
        return enabledSources.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary {
                return lhs.isPrimary && !rhs.isPrimary
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func normalizedWikiCommandTrigger(_ trigger: String) -> String {
        var trimmed = trigger
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if trimmed.isEmpty { return "" }

        if let first = trimmed.split(separator: " ").first {
            trimmed = String(first)
        }

        let prefix = effectivePrefix().lowercased()
        if !prefix.isEmpty, trimmed.hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count))
        }
        while let first = trimmed.first, first == "!" || first == "/" {
            trimmed.removeFirst()
        }
        return trimmed
    }

    private func setNotificationChannel(for raw: [String: DiscordJSON], currentChannelId: String) async -> Bool {
        guard let guildId = guildId(from: raw) else {
            return await send(currentChannelId, "⚠️ This command only works in a server channel.")
        }

        var guildSettings = settings.guildSettings[guildId] ?? GuildSettings()
        guildSettings.notificationChannelId = currentChannelId
        settings.guildSettings[guildId] = guildSettings

        let saved = await persistSettings()
        let message = saved ? "✅ Voice notifications will be posted in this channel." : "❌ Failed to save notification channel settings."
        return await send(currentChannelId, message)
    }

    private func updateIgnoredChannels(tokens: [String], raw: [String: DiscordJSON], responseChannelId: String) async -> Bool {
        guard let guildId = guildId(from: raw) else {
            return await send(responseChannelId, "⚠️ This command only works in a server channel.")
        }

        var guildSettings = settings.guildSettings[guildId] ?? GuildSettings()

        guard tokens.count >= 2 else {
            return await send(responseChannelId, "Usage: \(effectivePrefix())ignorechannel #channel | \(effectivePrefix())ignorechannel list | \(effectivePrefix())ignorechannel remove #channel")
        }

        let action = tokens[1].lowercased()
        if action == "list" {
            let list = guildSettings.ignoredVoiceChannelIds.sorted().map { "<#\($0)>" }.joined(separator: ", ")
            let message = list.isEmpty ? "ℹ️ No ignored voice channels configured." : "ℹ️ Ignored voice channels: \(list)"
            return await send(responseChannelId, message)
        }

        guard tokens.count >= 3, let targetChannelId = parseChannelId(tokens[2]) else {
            return await send(responseChannelId, "⚠️ Provide a channel mention like #general.")
        }

        if action == "remove" {
            guildSettings.ignoredVoiceChannelIds.remove(targetChannelId)
            settings.guildSettings[guildId] = guildSettings
            let saved = await persistSettings()
            let message = saved ? "✅ Removed <#\(targetChannelId)> from ignored voice channels." : "❌ Failed to save ignore list."
            return await send(responseChannelId, message)
        }

        guildSettings.ignoredVoiceChannelIds.insert(targetChannelId)
        settings.guildSettings[guildId] = guildSettings
        let saved = await persistSettings()
        let message = saved ? "✅ Added <#\(targetChannelId)> to ignored voice channels." : "❌ Failed to save ignore list."
        return await send(responseChannelId, message)
    }

    private func notifyStatus(raw: [String: DiscordJSON], responseChannelId: String) async -> Bool {
        guard let guildId = guildId(from: raw) else {
            return await send(responseChannelId, "⚠️ This command only works in a server channel.")
        }

        let guildSettings = settings.guildSettings[guildId] ?? GuildSettings()
        let notification = guildSettings.notificationChannelId.map { "<#\($0)>" } ?? "Not set"
        let monitored = guildSettings.monitoredVoiceChannelIds.sorted().map { "<#\($0)>" }.joined(separator: ", ")
        let monitoredText = monitored.isEmpty ? "All" : monitored
        let ignored = guildSettings.ignoredVoiceChannelIds.sorted().map { "<#\($0)>" }.joined(separator: ", ")
        let ignoredText = ignored.isEmpty ? "None" : ignored

        return await send(
            responseChannelId,
            "ℹ️ Notification channel: \(notification)\nMonitored voice channels: \(monitoredText)\nIgnored voice channels: \(ignoredText)\nJoin: \(guildSettings.notifyOnJoin ? "on" : "off"), Leave: \(guildSettings.notifyOnLeave ? "on" : "off"), Move: \(guildSettings.notifyOnMove ? "on" : "off")"
        )
    }

    private func persistSettings() async -> Bool {
        do {
            try await store.save(settings)
            return true
        } catch {
            stats.errors += 1
            logs.append("❌ Failed saving settings: \(error.localizedDescription)")
            return false
        }
    }

    private func guildId(from raw: [String: DiscordJSON]) -> String? {
        guard case let .string(guildId)? = raw["guild_id"] else { return nil }
        return guildId
    }

    private func parseChannelId(_ token: String) -> String? {
        if token.hasPrefix("<#") && token.hasSuffix(">") {
            return String(token.dropFirst(2).dropLast())
        }
        return token.allSatisfy(\.isNumber) ? token : nil
    }

    private func isMentioningBot(_ raw: [String: DiscordJSON]) -> Bool {
        guard let botUserId else { return false }
        guard case let .array(mentions)? = raw["mentions"] else { return false }

        for mention in mentions {
            guard case let .object(user) = mention,
                  case let .string(id)? = user["id"] else { continue }
            if id == botUserId {
                return true
            }
        }

        return false
    }

    private func contentWithoutBotMention(_ content: String) -> String {
        guard let botUserId else {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let patterns = [
            "<@\(botUserId)>",
            "<@!\(botUserId)>"
        ]

        let stripped = patterns.reduce(content) { partial, pattern in
            partial.replacingOccurrences(of: pattern, with: " ")
        }

        return stripped
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedChannelType(from map: [String: DiscordJSON], channelID: String) async -> Int? {
        if case let .int(type)? = map["channel_type"] {
            return type
        }
        return await discordCache.channelType(for: channelID)
    }

    private func upsertDiscordCacheFromMessage(
        map: [String: DiscordJSON],
        guildID: String?,
        channelID: String,
        channelType: Int?,
        userID: String,
        fallbackUsername: String
    ) async {
        if let guildID {
            let guildName: String?
            if case let .string(name)? = map["guild_name"] {
                guildName = name
            } else {
                guildName = nil
            }
            await discordCache.upsertGuild(id: guildID, name: guildName)
        }

        if let channelType {
            await discordCache.setChannelType(channelID: channelID, type: channelType)
        }

        if let guildID,
           case let .string(name)? = map["channel_name"] {
            let resolvedType = channelType ?? 0
            await discordCache.upsertChannel(
                guildID: guildID,
                channelID: channelID,
                name: name,
                type: resolvedType
            )
        }

        let preferredName: String = {
            if case let .object(member)? = map["member"],
               case let .string(nick)? = member["nick"],
               !nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nick
            }
            if case let .object(author)? = map["author"] {
                if case let .string(globalName)? = author["global_name"],
                   !globalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return globalName
                }
                if case let .string(username)? = author["username"],
                   !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return username
                }
            }
            return fallbackUsername
        }()

        await discordCache.upsertUser(id: userID, preferredName: preferredName)
        await syncPublishedDiscordCacheFromService()
        scheduleDiscordCacheSave()
    }

    private func displayNameForUserID(_ userID: String) async -> String {
        if let name = await discordCache.userName(for: userID), !name.isEmpty {
            return name
        }
        if userID == "system" {
            return "System"
        }
        return "User \(userID.suffix(4))"
    }

    private func aiMessagesForScope(
        scope: MemoryScope,
        currentUserID: String,
        currentContent: String
    ) async -> (messages: [Message], wikiContext: String) {
        let maxHistory = 8
        var recent = await conversationStore.recentMessages(for: scope, limit: maxHistory)
        
        if !currentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recent.append(
                MemoryRecord(
                    id: UUID().uuidString,
                    scope: scope,
                    userID: currentUserID,
                    content: currentContent,
                    timestamp: Date(),
                    role: .user
                )
            )
        }

        var conversationalMessages: [Message] = []
        conversationalMessages.reserveCapacity(recent.count)
        for record in recent {
            let resolvedUsername = await displayNameForUserID(record.userID)
            conversationalMessages.append(
                Message(
                    id: record.id,
                    channelID: record.scope.id,
                    userID: record.userID,
                    username: resolvedUsername,
                    content: record.content,
                    timestamp: record.timestamp,
                    role: record.role
                )
            )
        }

        let wikiContextEntries = await wikiContextCache.contextEntries(for: currentContent, limit: 3)
        let wikiContext = renderWikiContext(entries: wikiContextEntries)
        
        return (conversationalMessages, wikiContext)
    }

    private func renderWikiContext(entries: [WikiContextEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        var lines: [String] = ["Known Wiki Context (cached):"]
        for entry in entries {
            let summary = summarizedWikiExtract(entry.extract, limit: 220)
            if summary.isEmpty {
                lines.append("- [\(entry.sourceName)] \(entry.title): \(entry.url)")
            } else {
                lines.append("- [\(entry.sourceName)] \(entry.title): \(summary) (\(entry.url))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func appendAssistantMessage(scope: MemoryScope, content: String) async {
        let assistantID = botUserId ?? "swiftbot"
        await discordCache.upsertUser(id: assistantID, preferredName: botUsername)
        await conversationStore.append(
            scope: scope,
            userID: assistantID,
            content: content,
            role: .assistant
        )
    }

    // MARK: - AI typing indicator + timeout

#if DEBUG
    /// Exposes the cluster coordinator for test instrumentation.
    var testCluster: ClusterCoordinator { cluster }
    /// Override soft-notice delay for tests (default: 10 000 000 000 ns = 10s).
    var _testSoftNoticeDelayNs: UInt64 = 10_000_000_000
    /// Override hard-timeout for tests (default: 30 000 000 000 ns = 30s).
    var _testHardTimeoutNs: UInt64 = 30_000_000_000
    /// Override typing refresh interval for tests (default: 9 000 000 000 ns = 9s).
    var _testTypingRefreshNs: UInt64 = 9_000_000_000
#endif

    /// Outcome of `generateAIReplyWithTimeout`. Callers must inspect this to avoid
    /// emitting a second fallback message when the hard timeout has already fired.
    enum AIReplyOutcome {
        case reply(String)       // Generation succeeded — reply text to send.
        case handledFallback     // Hard timeout fired; fallback message already sent.
        case noReply             // Engine returned nil — caller may use its own fallback.
    }

    private func sendTypingIndicator(_ channelId: String) async {
        await service.triggerTyping(channelId: channelId, token: settings.token)
    }

    /// Runs AI generation with a typing indicator, a 10s soft notice, and a 30s hard timeout.
    func generateAIReplyWithTimeout(
        channelId: String,
        messages: [Message],
        serverName: String?,
        channelName: String?,
        wikiContext: String?
    ) async -> AIReplyOutcome {
        await sendTypingIndicator(channelId)

#if DEBUG
        let softNoticeNs = _testSoftNoticeDelayNs
        let hardTimeoutNs = _testHardTimeoutNs
        let typingRefreshNs = _testTypingRefreshNs
#else
        let softNoticeNs: UInt64 = 10_000_000_000
        let hardTimeoutNs: UInt64 = 30_000_000_000
        let typingRefreshNs: UInt64 = 9_000_000_000
#endif

        let typingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: typingRefreshNs)
                guard !Task.isCancelled else { return }
                await sendTypingIndicator(channelId)
            }
        }
        defer { typingTask.cancel() }

        var softNoticeSent = false

        return await withTaskGroup(of: String?.self) { group in
            // Main generation task
            group.addTask {
                await self.cluster.generateAIReply(
                    messages: messages,
                    serverName: serverName,
                    channelName: channelName,
                    wikiContext: wikiContext
                )
            }

            // Soft notice
            group.addTask {
                try? await Task.sleep(nanoseconds: softNoticeNs)
                return "__soft_notice__"
            }

            // Hard timeout
            group.addTask {
                try? await Task.sleep(nanoseconds: hardTimeoutNs)
                return "__hard_timeout__"
            }

            for await value in group {
                switch value {
                case "__soft_notice__":
                    if !softNoticeSent {
                        softNoticeSent = true
                        _ = await send(channelId, "One moment — I'm still working on that.")
                    }
                case "__hard_timeout__":
                    group.cancelAll()
                    _ = await send(channelId, "Whoops — that one's a bit beyond my current limits. Try a shorter or more specific prompt.")
                    return .handledFallback
                case let text?:
                    group.cancelAll()
                    return .reply(text)
                default:
                    // Engine returned nil. If the soft notice was already sent the user is
                    // waiting for a terminal reply — send the hard-timeout fallback so they
                    // are not left hanging. Without a soft notice, return .noReply so callers
                    // can decide whether to send their own fallback.
                    group.cancelAll()
                    if softNoticeSent {
                        _ = await send(channelId, "Whoops — that one's a bit beyond my current limits. Try a shorter or more specific prompt.")
                        return .handledFallback
                    }
                    return .noReply
                }
            }
            return .noReply
        }
    }

    private func send(_ channelId: String, _ message: String) async -> Bool {
        do {
            try await service.sendMessage(channelId: channelId, content: message, token: settings.token)
            return true
        } catch {
            return false
        }
    }

    private func sendEmbed(_ channelId: String, embed: [String: Any]) async -> Bool {
        do {
            _ = try await service.sendMessage(
                channelId: channelId,
                payload: ["embeds": [embed]],
                token: settings.token
            )
            return true
        } catch {
            return false
        }
    }

    func sendPatchyNotificationDetailed(
        channelId: String,
        message: String,
        embedJSON: String?,
        roleIDs: [String]
    ) async -> (ok: Bool, detail: String) {
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            let detail = "Patchy send failed. status=- token missing."
            logs.append("❌ \(detail)")
            return (false, detail)
        }

        let cleanedRoleIDs = roleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        let roleMentionText = cleanedRoleIDs.map { "<@&\($0)>" }.joined(separator: " ")
        let allowedMentions: [String: Any]? = cleanedRoleIDs.isEmpty ? nil : [
            "parse": [],
            "roles": cleanedRoleIDs
        ]

        var payload: [String: Any] = [:]
        var usingEmbedPayload = false
        if let rawEmbedJSON = embedJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawEmbedJSON.isEmpty,
           let data = rawEmbedJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let embeds = object["embeds"] as? [Any],
           !embeds.isEmpty {
            payload["embeds"] = embeds
            if !roleMentionText.isEmpty {
                payload["content"] = roleMentionText
            }
            if let allowedMentions {
                payload["allowed_mentions"] = allowedMentions
            }
            usingEmbedPayload = true
        } else {
            let fallbackBody = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = [roleMentionText, fallbackBody].filter { !$0.isEmpty }.joined(separator: " ")
            payload["content"] = content.isEmpty ? "Patchy update available." : content
            if let allowedMentions {
                payload["allowed_mentions"] = allowedMentions
            }
        }

        do {
            let response = try await service.sendMessage(channelId: channelId, payload: payload, token: token)
            let mode = usingEmbedPayload ? "embed" : "fallback"
            let detail = "Patchy send succeeded (\(mode), status=\(response.statusCode))."
            logs.append("✅ \(detail)")
            return (true, detail)
        } catch {
            let diagnostic = patchyErrorDiagnostic(from: error)
            let detail = "Patchy send failed (\(usingEmbedPayload ? "embed" : "fallback")). \(diagnostic)"
            logs.append("❌ \(detail)")
            return (false, detail)
        }
    }

    private func performWikiLookup(
        command: WikiCommand,
        source: WikiSource,
        query: String,
        channelId: String
    ) async -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trigger = normalizedWikiCommandTrigger(command.trigger)
        let usageTrigger = trigger.isEmpty ? command.trigger : "\(effectivePrefix())\(trigger)"
        guard !trimmedQuery.isEmpty else {
            return await send(
                channelId,
                "📘 Usage: \(usageTrigger) <query> (optional source selector: <wiki-command> <source>::<query>)"
            )
        }

        guard let resolved = resolveWikiSourceAndQuery(defaultSource: source, query: trimmedQuery) else {
            return await send(channelId, "⚠️ No WikiBridge sources are enabled. Add or enable a source in WikiBridge settings.")
        }

        let resolvedSource = resolved.source
        let sourceQuery = resolved.query
        guard !sourceQuery.isEmpty else {
            return await send(channelId, "📘 Provide a query after the source selector. Example: \(usageTrigger) \(resolvedSource.name)::AKM")
        }

        guard let result = await cluster.lookupWiki(query: sourceQuery, source: resolvedSource) else {
            updateWikiBridgeSourceRuntimeState(id: resolvedSource.id) { entry in
                entry.lastLookupAt = Date()
                entry.lastStatus = "No match for \"\(sourceQuery)\""
            }
            persistSettingsQuietly()
            return await send(channelId, "❌ I couldn't find a relevant page on \(resolvedSource.name) for \"\(sourceQuery)\".")
        }

        updateWikiBridgeSourceRuntimeState(id: resolvedSource.id) { entry in
            entry.lastLookupAt = Date()
            entry.lastStatus = "Resolved: \(result.title)"
        }
        persistSettingsQuietly()
        await wikiContextCache.store(sourceName: resolvedSource.name, query: sourceQuery, result: result)

        let body = formattedWikiResponse(source: resolvedSource, result: result)
        if resolvedSource.formatting.useEmbeds {
            let embedSent = await sendWikiEmbed(channelId: channelId, source: resolvedSource, result: result)
            if embedSent {
                return true
            }
        }

        return await send(channelId, body)
    }

    private func resolveWikiSourceAndQuery(defaultSource: WikiSource, query: String) -> (source: WikiSource, query: String)? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabledSources = settings.wikiBot.sources.filter(\.enabled)
        guard !enabledSources.isEmpty else { return nil }

        if let explicit = parseExplicitWikiSource(in: trimmedQuery, from: enabledSources) {
            return explicit
        }

        if enabledSources.contains(where: { $0.id == defaultSource.id }) {
            return (defaultSource, trimmedQuery)
        }

        if let primarySource = enabledSources.first(where: { $0.isPrimary }) {
            return (primarySource, trimmedQuery)
        }

        return (enabledSources[0], trimmedQuery)
    }

    private func parseExplicitWikiSource(
        in query: String,
        from enabledSources: [WikiSource]
    ) -> (source: WikiSource, query: String)? {
        guard let marker = query.range(of: "::") else { return nil }
        let rawSource = query[..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let remainingQuery = query[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawSource.isEmpty else { return nil }

        let lookupKey = normalizedWikiSourceKey(rawSource)
        guard !lookupKey.isEmpty else { return nil }

        for source in enabledSources {
            let nameKey = normalizedWikiSourceKey(source.name)
            if lookupKey == nameKey || nameKey.hasPrefix(lookupKey) {
                return (source, remainingQuery)
            }

            if let host = URL(string: source.baseURL)?.host {
                let hostKey = normalizedWikiSourceKey(host)
                if lookupKey == hostKey || hostKey.hasPrefix(lookupKey) {
                    return (source, remainingQuery)
                }
            }
        }

        return nil
    }

    private func normalizedWikiSourceKey(_ raw: String) -> String {
        raw
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func formattedWikiResponse(source: WikiSource, result: FinalsWikiLookupResult) -> String {
        let formatting = source.formatting
        if formatting.includeStatBlocks, let weaponStats = result.weaponStats {
            return formattedWeaponStats(
                result: result,
                sourceName: source.name,
                stats: weaponStats,
                compact: formatting.compactMode
            )
        }

        let summary = summarizedWikiExtract(
            result.extract,
            limit: formatting.compactMode ? 220 : 420
        )
        if summary.isEmpty {
            return "📘 **\(result.title)**\nSource: \(source.name)\n\(result.url)"
        }
        if formatting.compactMode {
            return "📘 **\(result.title)** • \(source.name)\n\(summary)\n\(result.url)"
        }
        return "📘 **\(result.title)**\nSource: \(source.name)\n\(summary)\n\(result.url)"
    }

    private func sendWikiEmbed(channelId: String, source: WikiSource, result: FinalsWikiLookupResult) async -> Bool {
        let summary = summarizedWikiExtract(
            result.extract,
            limit: source.formatting.compactMode ? 220 : 420
        )

        var embed: [String: Any] = [
            "title": result.title,
            "url": result.url,
            "footer": ["text": source.name]
        ]
        if !summary.isEmpty {
            embed["description"] = summary
        }

        if source.formatting.includeStatBlocks, let stats = result.weaponStats {
            var fields: [[String: Any]] = []
            func appendField(_ name: String, _ value: String?) {
                guard let value, !value.isEmpty else { return }
                fields.append([
                    "name": name,
                    "value": value,
                    "inline": true
                ])
            }
            appendField("Type", stats.type)
            appendField("Body Damage", stats.bodyDamage)
            appendField("Head Damage", stats.headshotDamage)
            appendField("Fire Rate", stats.fireRate)
            appendField("Dropoff Start", stats.dropoffStart)
            appendField("Dropoff End", stats.dropoffEnd)
            appendField("Minimum Damage", stats.minimumDamage)
            appendField("Magazine", stats.magazineSize)
            appendField("Short Reload", stats.shortReload)
            appendField("Long Reload", stats.longReload)
            if !fields.isEmpty {
                embed["fields"] = Array(fields.prefix(25))
            }
        }

        let payload: [String: Any] = [
            "embeds": [embed]
        ]
        do {
            _ = try await service.sendMessage(channelId: channelId, payload: payload, token: settings.token)
            return true
        } catch {
            return false
        }
    }

    private func formattedWeaponStats(
        result: FinalsWikiLookupResult,
        sourceName: String,
        stats: FinalsWeaponStats,
        compact: Bool
    ) -> String {
        var lines: [String] = []

        if let type = stats.type, !type.isEmpty {
            lines.append("📘 **\(result.title)** • \(type)")
        } else {
            lines.append("📘 **\(result.title)**")
        }
        if compact {
            lines[0] += " • \(sourceName)"
        } else {
            lines.append("Source: \(sourceName)")
        }

        let damageLine = [
            stats.bodyDamage.map { "Body \($0)" },
            stats.headshotDamage.map { "Head \($0)" }
        ].compactMap { $0 }.joined(separator: " • ")
        if !damageLine.isEmpty {
            lines.append(compact ? "DMG \(damageLine)" : "Damage: \(damageLine)")
        }

        if let fireRate = stats.fireRate, !fireRate.isEmpty {
            lines.append(compact ? "RPM \(fireRate)" : "Fire Rate: \(fireRate)")
        }

        let falloffLine = [
            stats.dropoffStart.map { "Start \($0)" },
            stats.dropoffEnd.map { "End \($0)" },
            stats.minimumDamage.map { "Min \($0)" }
        ].compactMap { $0 }.joined(separator: " • ")
        if !falloffLine.isEmpty {
            lines.append(compact ? "Falloff \(falloffLine)" : "Falloff: \(falloffLine)")
        }

        if let magazineSize = stats.magazineSize, !magazineSize.isEmpty {
            lines.append(compact ? "Mag \(magazineSize)" : "Magazine: \(magazineSize)")
        }

        let reloadLine = [
            stats.shortReload.map { "Short \($0)" },
            stats.longReload.map { "Long \($0)" }
        ].compactMap { $0 }.joined(separator: " • ")
        if !reloadLine.isEmpty {
            lines.append(compact ? "Reload \(reloadLine)" : "Reload: \(reloadLine)")
        }

        lines.append(result.url)
        return lines.joined(separator: "\n")
    }

    private func summarizedWikiExtract(_ extract: String, limit: Int = 420) -> String {
        let cleaned = extract
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count > limit else { return cleaned }

        let cutoffIndex = cleaned.index(cleaned.startIndex, offsetBy: limit)
        let prefix = String(cleaned[..<cutoffIndex])
        if let sentenceEnd = prefix.lastIndex(where: { ".!?".contains($0) }) {
            return String(prefix[...sentenceEnd])
        }

        return prefix + "..."
    }

    private func logSwiftMeshStatus(_ snapshot: ClusterSnapshot, context: String) {
        let leader = snapshot.leaderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaderValue = leader.isEmpty ? "-" : leader
        logs.append(
            "SwiftMesh [\(context)] mode=\(snapshot.mode.rawValue) server=\(snapshot.serverStatusText) worker=\(snapshot.workerStatusText) leader=\(leaderValue)"
        )
    }

    private func performWorkerConnectionTest(leaderAddress rawValue: String) async -> WorkerConnectionTestOutcome {
        guard let baseURL = normalizedSwiftMeshBaseURL(from: rawValue),
              let host = baseURL.host else {
            return WorkerConnectionTestOutcome(message: "Invalid URL", isSuccess: false)
        }

        let port = baseURL.port ?? (baseURL.scheme?.lowercased() == "https" ? 443 : 80)
        switch testReachability(host: host, port: port) {
        case .hostUnreachable:
            return WorkerConnectionTestOutcome(message: "Host unreachable", isSuccess: false)
        case .reachable:
            break
        }

        guard let pingURL = URL(string: baseURL.absoluteString + "/cluster/ping") else {
            return WorkerConnectionTestOutcome(message: "Invalid URL", isSuccess: false)
        }

        var request = URLRequest(url: pingURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        let startedAt = Date()

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let payload = try? JSONDecoder().decode(SwiftMeshPingResponse.self, from: data),
                  payload.status.caseInsensitiveCompare("ok") == .orderedSame,
                  payload.role.caseInsensitiveCompare("leader") == .orderedSame else {
                return WorkerConnectionTestOutcome(message: "Server reachable but not SwiftBot", isSuccess: false)
            }

            let latencyMs = max(1, Int((Date().timeIntervalSince(startedAt) * 1000).rounded()))
            return WorkerConnectionTestOutcome(
                message: "Successful connection with latency: \(latencyMs) ms",
                isSuccess: true
            )
        } catch let error as URLError {
            switch error.code {
            case .badURL, .unsupportedURL:
                return WorkerConnectionTestOutcome(message: "Invalid URL", isSuccess: false)
            case .cannotFindHost, .dnsLookupFailed, .timedOut, .notConnectedToInternet:
                return WorkerConnectionTestOutcome(message: "Host unreachable", isSuccess: false)
            case .cannotConnectToHost:
                let portLabel = baseURL.port ?? (baseURL.scheme?.lowercased() == "https" ? 443 : 80)
                return WorkerConnectionTestOutcome(
                    message: "Connection refused on port \(portLabel) (Primary may be offline or settings not saved)",
                    isSuccess: false
                )
            default:
                return WorkerConnectionTestOutcome(message: "Host unreachable", isSuccess: false)
            }
        } catch {
            return WorkerConnectionTestOutcome(message: "Host unreachable", isSuccess: false)
        }
    }

    private func normalizedSwiftMeshBaseURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            candidate = trimmed
        } else {
            candidate = "http://\(trimmed)"
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme,
              let host = url.host,
              !scheme.isEmpty,
              !host.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = ""
        return components.url
    }

    private func testReachability(host: String, port: Int) -> WorkerReachabilityResult {
        guard (1...Int(UInt16.max)).contains(port) else {
            return .hostUnreachable
        }

        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = String(port).withCString { portCString in
            host.withCString { hostCString in
                getaddrinfo(hostCString, portCString, &hints, &resultPointer)
            }
        }

        if let resultPointer {
            freeaddrinfo(resultPointer)
        }

        return status == 0 ? .reachable : .hostUnreachable
    }

    private func clusterCommand(action: String, channelId: String) async -> Bool {
        let normalized = ["test", "refresh", "check", "remote", "probe"].contains(action) ? action : "status"
        let snapshot = await clusterSnapshotForCommand(action: normalized)
        let leaderAddress = snapshot.leaderAddress.isEmpty ? "-" : snapshot.leaderAddress

        let message = """
        🧭 **Cluster \(normalized.capitalized)**
        Mode: \(snapshot.mode.rawValue)
        Node: \(snapshot.nodeName)
        Server: \(snapshot.serverStatusText)
        Worker: \(snapshot.workerStatusText)
        Leader Address: \(leaderAddress)
        Last Job: \(snapshot.lastJobSummary) [\(snapshot.lastJobRoute.rawValue)]
        Last Job Node: \(snapshot.lastJobNode)
        Diagnostics: \(snapshot.diagnostics)
        """

        return await send(channelId, message)
    }

    private func clusterSnapshotForCommand(action: String) async -> ClusterSnapshot {
        switch action {
        case "test", "refresh", "check":
            return await refreshClusterStatusNow()
        case "remote", "probe":
            _ = await cluster.probeWorker()
            let snapshot = await cluster.currentSnapshot()
            clusterSnapshot = snapshot
            return snapshot
        default:
            return clusterSnapshot
        }
    }

    private func commandExecutionDetails(for commandName: String) async -> (route: String, node: String) {
        let leaderNode = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines)

        let normalized = normalizedWikiCommandTrigger(commandName)
        let isWikiCommand = resolveWikiCommand(named: normalized) != nil

        if commandName == "cluster" || commandName == "worker" || isWikiCommand {
            let snapshot = await cluster.currentSnapshot()
            return (snapshot.lastJobRoute.rawValue.capitalized, snapshot.lastJobNode)
        }

        return ("Primary", leaderNode)
    }

    private func rollDice(_ descriptor: String) -> String? {
        let parts = descriptor.lowercased().split(separator: "d")
        guard parts.count == 2,
              let n = Int(parts[0]),
              let sides = Int(parts[1]),
              (1...30).contains(n), (2...1000).contains(sides) else { return nil }

        var rolls: [Int] = []
        for _ in 0..<n { rolls.append(Int.random(in: 1...sides)) }
        return "🎲 Rolled \(descriptor): [\(rolls.map(String.init).joined(separator: ", "))] total=\(rolls.reduce(0, +))"
    }

    private func handleVoiceStateUpdate(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw,
              case let .string(userId)? = map["user_id"],
              case let .string(guildId)? = map["guild_id"]
        else { return }

        let key = "\(guildId)-\(userId)"
        let now = Date()
        let previous = activeVoice.first(where: { $0.userId == userId && $0.guildId == guildId })
        let displayName = await voiceDisplayName(from: map, userId: userId)

        lastVoiceStateAt = now

        let channelId: String?
        if case let .string(cid)? = map["channel_id"] { channelId = cid } else { channelId = nil }

        if let newChannel = channelId {
            // Idempotency: ignore mute/deaf-only updates (channel unchanged). Only fire on channel transitions.
            if let previous, previous.channelId == newChannel { return }

            let next = VoiceMemberPresence(
                id: key,
                userId: userId,
                username: displayName,
                guildId: guildId,
                channelId: newChannel,
                channelName: channelDisplayName(guildId: guildId, channelId: newChannel),
                joinedAt: joinTimes[key] ?? now
            )

            if let previous {
                if previous.channelId != newChannel {
                    let elapsed = formatDuration(from: joinTimes[key] ?? previous.joinedAt, to: now)
                    stats.voiceLeaves += 1
                    lastVoiceStateSummary = "MOVE \(displayName): \(previous.channelName) -> \(next.channelName)"
                    addEvent(ActivityEvent(timestamp: now, kind: .voiceMove, message: "🔀 @\(displayName) moved from \(previous.channelName) — Time in chat: \(elapsed) → \(next.channelName)"))
                    voiceLog.insert(VoiceEventLogEntry(time: now, description: "MOVE \(displayName) \(previous.channelName) -> \(next.channelName)"), at: 0)

                    if shouldNotifyVoiceEvent(guildId: guildId, channelId: previous.channelId) || shouldNotifyVoiceEvent(guildId: guildId, channelId: newChannel) {
                        let message = renderNotificationTemplate(
                            settings.guildSettings[guildId]?.moveNotificationTemplate ?? GuildSettings().moveNotificationTemplate,
                            username: displayName,
                            guildId: guildId,
                            channelId: newChannel,
                            fromChannelId: previous.channelId,
                            toChannelId: newChannel
                        )
                        _ = await sendVoiceNotification(guildId: guildId, message: message, event: .move,
                            displayName: displayName, channelName: next.channelName,
                            fromChannelName: previous.channelName)
                    }
                }
                activeVoice.removeAll { $0.id == previous.id }
            } else {
                joinTimes[key] = now
                stats.voiceJoins += 1
                lastVoiceStateSummary = "JOIN \(displayName) -> \(next.channelName)"
                addEvent(ActivityEvent(timestamp: now, kind: .voiceJoin, message: "🟢 @\(displayName) joined \(next.channelName)"))
                voiceLog.insert(VoiceEventLogEntry(time: now, description: "JOIN \(displayName) \(next.channelName)"), at: 0)

                if shouldNotifyVoiceEvent(guildId: guildId, channelId: newChannel) {
                    let message = renderNotificationTemplate(
                        settings.guildSettings[guildId]?.joinNotificationTemplate ?? GuildSettings().joinNotificationTemplate,
                        username: displayName,
                        guildId: guildId,
                        channelId: newChannel,
                        fromChannelId: nil,
                        toChannelId: newChannel
                    )
                    _ = await sendVoiceNotification(guildId: guildId, message: message, event: .join,
                        displayName: displayName, channelName: next.channelName)
                }
                await eventBus.publish(VoiceJoined(guildId: guildId, userId: userId, username: displayName, channelId: newChannel))
            }

            activeVoice.append(next)
        } else if let previous {
            let start = joinTimes[key] ?? previous.joinedAt
            let elapsed = formatDuration(from: start, to: now)
            stats.voiceLeaves += 1
            activeVoice.removeAll { $0.id == previous.id }
            joinTimes[key] = nil
            lastVoiceStateSummary = "LEAVE \(previous.username) <- \(previous.channelName)"
            addEvent(ActivityEvent(timestamp: now, kind: .voiceLeave, message: "🔴 @\(previous.username) left \(previous.channelName) — Time in chat: \(elapsed)"))
            voiceLog.insert(VoiceEventLogEntry(time: now, description: "LEAVE \(previous.username) \(previous.channelName) duration=\(elapsed)"), at: 0)

            if shouldNotifyVoiceEvent(guildId: guildId, channelId: previous.channelId) {
                let message = renderNotificationTemplate(
                    settings.guildSettings[guildId]?.leaveNotificationTemplate ?? GuildSettings().leaveNotificationTemplate,
                    username: displayName,
                    guildId: guildId,
                    channelId: previous.channelId,
                    fromChannelId: previous.channelId,
                    toChannelId: nil
                )
                _ = await sendVoiceNotification(guildId: guildId, message: message, event: .leave,
                    displayName: previous.username, channelName: previous.channelName, duration: elapsed)
            }
            let elapsedSec = Int(now.timeIntervalSince(joinTimes[key] ?? previous.joinedAt))
            await eventBus.publish(VoiceLeft(guildId: guildId, userId: userId, username: displayName, channelId: previous.channelId, durationSeconds: elapsedSec))
        }

        if voiceLog.count > 200 { voiceLog.removeLast(voiceLog.count - 200) }
    }

    private enum VoiceNotifyEvent {
        case join
        case leave
        case move
    }

    private func voiceDisplayName(from map: [String: DiscordJSON], userId: String) async -> String {
        if case let .object(member)? = map["member"] {
            if case let .string(nick)? = member["nick"], !nick.isEmpty {
                await discordCache.upsertUser(id: userId, preferredName: nick)
                return nick
            }

            if case let .object(user)? = member["user"] {
                if case let .string(globalName)? = user["global_name"], !globalName.isEmpty {
                    await discordCache.upsertUser(id: userId, preferredName: globalName)
                    return globalName
                }
                if case let .string(username)? = user["username"], !username.isEmpty {
                    await discordCache.upsertUser(id: userId, preferredName: username)
                    return username
                }
            }
        }

        if case let .object(user)? = map["user"] {
            if case let .string(globalName)? = user["global_name"], !globalName.isEmpty {
                await discordCache.upsertUser(id: userId, preferredName: globalName)
                return globalName
            }
            if case let .string(username)? = user["username"], !username.isEmpty {
                await discordCache.upsertUser(id: userId, preferredName: username)
                return username
            }
        }

        if let cached = await discordCache.userName(for: userId), !cached.isEmpty {
            return cached
        }

        return "User \(userId.suffix(4))"
    }

    private func channelDisplayName(guildId: String, channelId: String) -> String {
        if let channel = availableVoiceChannelsByServer[guildId]?.first(where: { $0.id == channelId }) {
            return channel.name
        }
        return "#\(channelId.suffix(5))"
    }

    private func shouldNotifyVoiceEvent(guildId: String, channelId: String) -> Bool {
        guard let guildSettings = settings.guildSettings[guildId],
              guildSettings.notificationChannelId != nil
        else { return false }

        if guildSettings.ignoredVoiceChannelIds.contains(channelId) {
            return false
        }

        if !guildSettings.monitoredVoiceChannelIds.isEmpty,
           !guildSettings.monitoredVoiceChannelIds.contains(channelId) {
            return false
        }

        return true
    }

    /// Sends a voice activity notification. When using the global voice log channel (no per-guild channel
    /// configured), a privacy-safe display-name-only message is used instead of the per-guild template
    /// (which may contain Discord ID mentions). `displayName`, `channelName`, `fromChannelName`, and
    /// `duration` are used only for the global path.
    private func sendVoiceNotification(
        guildId: String,
        message: String,
        event: VoiceNotifyEvent,
        displayName: String = "",
        channelName: String = "",
        fromChannelName: String = "",
        duration: String = ""
    ) async -> Bool {
        let perGuildChannelId = settings.guildSettings[guildId]?.notificationChannelId
        let globalChannelId: String? = (settings.behavior.voiceActivityLogEnabled
            && !settings.behavior.voiceActivityLogChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ? settings.behavior.voiceActivityLogChannelId.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        if let gs = settings.guildSettings[guildId] {
            switch event {
            case .join where !gs.notifyOnJoin: return false
            case .leave where !gs.notifyOnLeave: return false
            case .move where !gs.notifyOnMove: return false
            default: break
            }
        }

        var sent = false
        // Per-guild channel: use the caller-rendered message (may contain Discord mention syntax).
        if let channelId = perGuildChannelId {
            sent = await send(channelId, message)
        }
        // Global voice log channel: use display-name-only message (no raw IDs).
        if let channelId = globalChannelId, channelId != perGuildChannelId {
            let privacyMessage: String
            switch event {
            case .join:
                privacyMessage = "🔊 \(displayName) joined \(channelName)"
            case .leave:
                let dur = duration.isEmpty ? "" : " (duration: \(duration))"
                privacyMessage = "🔌 \(displayName) left \(channelName)\(dur)"
            case .move:
                privacyMessage = "🔁 \(displayName) moved: \(fromChannelName) → \(channelName)"
            }
            sent = await send(channelId, privacyMessage) || sent
        }
        return sent
    }

    private func renderNotificationTemplate(
        _ template: String,
        username: String,
        guildId: String,
        channelId: String,
        fromChannelId: String?,
        toChannelId: String?
    ) -> String {
        let guildName = connectedServers[guildId] ?? "Server \(guildId.suffix(4))"
        let resolvedFromChannelId = fromChannelId ?? channelId
        let resolvedToChannelId = toChannelId ?? channelId

        // Only display-name tokens are substituted — raw IDs ({userId}, {guildId}, {channelId},
        // {fromChannelId}, {toChannelId}) are intentionally NOT substituted so they can never
        // leak Discord snowflake IDs into sent voice-notification messages.
        return template
            .replacingOccurrences(of: "{username}", with: username)
            .replacingOccurrences(of: "{guildName}", with: guildName)
            .replacingOccurrences(of: "{channelName}", with: channelDisplayName(guildId: guildId, channelId: channelId))
            .replacingOccurrences(of: "{fromChannelName}", with: channelDisplayName(guildId: guildId, channelId: resolvedFromChannelId))
            .replacingOccurrences(of: "{toChannelName}", with: channelDisplayName(guildId: guildId, channelId: resolvedToChannelId))
    }

    private func parseVoiceChannels(from guildMap: [String: DiscordJSON]) -> [GuildVoiceChannel] {
        guard case let .array(channels)? = guildMap["channels"] else { return [] }

        var result: [GuildVoiceChannel] = []
        for channel in channels {
            guard case let .object(channelMap) = channel,
                  case let .string(channelId)? = channelMap["id"],
                  case let .string(channelName)? = channelMap["name"],
                  case let .int(type)? = channelMap["type"]
            else { continue }

            if type == 2 || type == 13 {
                result.append(GuildVoiceChannel(id: channelId, name: channelName))
            }
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func parseTextChannels(from guildMap: [String: DiscordJSON]) -> [GuildTextChannel] {
        guard case let .array(channels)? = guildMap["channels"] else { return [] }

        var result: [GuildTextChannel] = []
        for channel in channels {
            guard case let .object(channelMap) = channel,
                  case let .string(channelId)? = channelMap["id"],
                  case let .string(channelName)? = channelMap["name"],
                  case let .int(type)? = channelMap["type"]
            else { continue }

            if type == 0 || type == 5 {
                result.append(GuildTextChannel(id: channelId, name: channelName))
            }
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func parseRoles(from guildMap: [String: DiscordJSON]) -> [GuildRole] {
        guard case let .array(roles)? = guildMap["roles"] else { return [] }

        var result: [GuildRole] = []
        for role in roles {
            guard case let .object(roleMap) = role,
                  case let .string(roleId)? = roleMap["id"],
                  case let .string(roleName)? = roleMap["name"]
            else { continue }

            if roleName == "@everyone" { continue }
            result.append(GuildRole(id: roleId, name: roleName))
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func parseChannelTypes(from guildMap: [String: DiscordJSON]) -> [String: Int] {
        guard case let .array(channels)? = guildMap["channels"] else { return [:] }

        var result: [String: Int] = [:]
        for channel in channels {
            guard case let .object(channelMap) = channel,
                  case let .string(channelId)? = channelMap["id"],
                  case let .int(type)? = channelMap["type"]
            else { continue }
            result[channelId] = type
        }
        return result
    }

    private func handleReady(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw else { return }
        guard case let .array(guilds)? = map["guilds"] else { return }

        for guild in guilds {
            guard case let .object(guildMap) = guild,
                  case let .string(guildId)? = guildMap["id"]
            else { continue }

            let guildName: String?
            if case let .string(name)? = guildMap["name"] {
                guildName = name
            } else {
                guildName = nil
            }
            await discordCache.upsertGuild(id: guildId, name: guildName)
        }
        await syncPublishedDiscordCacheFromService()
        scheduleDiscordCacheSave()
        // GUILD_MEMBER_ADD is now handled via handleMemberJoin (P0.5).
    }

    // MARK: - P0.5: Member join welcome

    private func handleMemberJoin(_ raw: DiscordJSON?) async {
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

    private func handleGuildCreate(_ raw: DiscordJSON?) async {
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
    }

    private func handleChannelCreate(_ raw: DiscordJSON?) async {
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

    private func handleGuildDelete(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw,
              case let .string(guildId)? = map["id"]
        else { return }

        await discordCache.removeGuild(id: guildId)
        await syncPublishedDiscordCacheFromService()
        activeVoice.removeAll { $0.guildId == guildId }
        joinTimes = joinTimes.filter { !$0.key.hasPrefix("\(guildId)-") }
        scheduleDiscordCacheSave()
    }

    private func patchyErrorDiagnostic(from error: Error) -> String {
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

    private func syncVoicePresenceFromGuildSnapshot(guildId: String, guildMap: [String: DiscordJSON]) async {
        guard case let .array(voiceStates)? = guildMap["voice_states"] else { return }

        activeVoice.removeAll { $0.guildId == guildId }
        joinTimes = joinTimes.filter { !$0.key.hasPrefix("\(guildId)-") }

        let now = Date()
        for state in voiceStates {
            guard case let .object(stateMap) = state,
                  case let .string(userId)? = stateMap["user_id"],
                  case let .string(channelId)? = stateMap["channel_id"]
            else { continue }

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

    private func cacheGuildMembers(from guildMap: [String: DiscordJSON]) async {
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

            if case let .string(globalName)? = user["global_name"], !globalName.isEmpty {
                await discordCache.upsertUser(id: userId, preferredName: globalName)
            } else if case let .string(username)? = user["username"], !username.isEmpty {
                await discordCache.upsertUser(id: userId, preferredName: username)
            }
        }
    }

    private func syncPublishedDiscordCacheFromService() async {
        let snapshot = await discordCache.currentSnapshot()
        connectedServers = snapshot.connectedServers
        availableVoiceChannelsByServer = snapshot.availableVoiceChannelsByServer
        availableTextChannelsByServer = snapshot.availableTextChannelsByServer
        availableRolesByServer = snapshot.availableRolesByServer
        knownUsersById = snapshot.usernamesById
    }

    private func scheduleDiscordCacheSave() {
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

    private func resolveSteamNameIfNeeded(for target: PatchySourceTarget) {
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

    private func fetchSteamAppName(appID: String) async -> String? {
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

    private func commandServerName(from map: [String: DiscordJSON]) -> String {
        guard case let .string(guildId)? = map["guild_id"] else {
            return "Direct Message"
        }
        return connectedServers[guildId] ?? "Server \(guildId.suffix(4))"
    }

    private func effectivePrefix() -> String {
        let trimmed = settings.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "!" : trimmed
    }

    private func formatDuration(from: Date, to: Date) -> String {
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

    private let store: ConversationStore
    private let discordCache: DiscordCache
    private var storeUpdatesTask: Task<Void, Never>?
    private var cacheUpdatesTask: Task<Void, Never>?

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

    private func reloadSummaries() async {
        summaries = await store.summaries()
        await refreshDisplayNames()
    }

    private func refreshDisplayNames() async {
        let current = summaries
        var updated: [MemoryScope: String] = [:]
        for summary in current {
            updated[summary.scope] = await resolvedTitle(for: summary.scope)
        }
        scopeDisplayNames = updated
    }

    private func resolvedTitle(for scope: MemoryScope) async -> String {
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

    private func fallbackTitle(for scope: MemoryScope) -> String {
        switch scope.type {
        case .guildTextChannel:
            return "Channel \(scope.id)"
        case .directMessageUser:
            return "DM User \(scope.id.suffix(4))"
        }
    }
}

private struct WorkerConnectionTestOutcome {
    let message: String
    let isSuccess: Bool
}

private enum WorkerReachabilityResult {
    case reachable
    case hostUnreachable
}

private struct SwiftMeshPingResponse: Decodable {
    let status: String
    let role: String
    let node: String
}

actor ClusterStatusPollingService {
    private let decoder = JSONDecoder()

    func fetchStatus(from endpoint: URL) async -> ClusterStatusResponse? {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 3
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
