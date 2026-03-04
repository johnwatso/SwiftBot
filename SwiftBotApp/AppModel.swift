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
    @Published var appleIntelligenceOnline = false
    @Published var ollamaOnline = false
    @Published var ollamaDetectedModel: String?
    @Published var patchyDebugLogs: [String] = []
    @Published var patchyIsCycleRunning = false
    @Published var patchyLastCycleAt: Date?

    var logs = LogStore()
    let ruleStore = RuleStore()

    private let store = ConfigStore()
    private let discordCacheStore = DiscordCacheStore()
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
    private let conversationStore = ConversationStore()
    lazy var memoryViewModel = MemoryViewModel(store: conversationStore, discordCache: discordCache)
    let eventBus = EventBus()
    private let pluginManager: PluginManager
    private var weeklyPlugin: WeeklySummaryPlugin?
    private let patchyChecker: UpdateChecker?
    private var patchyMonitorTask: Task<Void, Never>?
    private var botUserId: String?
    private let launchedAt = Date()
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

            settings = loadedSettings
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
            await cluster.configureHandlers(
                aiHandler: { [weak self] messages in
                    guard let self else { return nil }
                    return await self.service.generateSmartDMReply(messages: messages)
                },
                wikiHandler: { [weak self] query, source in
                    guard let self else { return nil }
                    return await self.service.lookupWiki(query: query, source: source)
                },
                onSnapshot: { [weak self] snapshot in
                    let model = self
                    await MainActor.run {
                        model?.clusterSnapshot = snapshot
                    }
                },
                onJobLog: { [weak self] entry in
                    let model = self
                    await MainActor.run {
                        model?.commandLog.insert(entry, at: 0)
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
                workerBaseURL: settings.clusterWorkerBaseURL,
                listenPort: settings.clusterListenPort
            )
            await pollClusterStatus()
            await configureServiceCallbacks()
            configurePatchyMonitoring()
            if settings.autoStart, !settings.token.isEmpty {
                await startBot()
            }
        }
    }

    func saveSettings() {
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
            await cluster.applySettings(
                mode: settings.clusterMode,
                nodeName: settings.clusterNodeName,
                workerBaseURL: settings.clusterWorkerBaseURL,
                listenPort: settings.clusterListenPort
            )
            await pollClusterStatus()
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
        await cluster.applySettings(
            mode: settings.clusterMode,
            nodeName: settings.clusterNodeName,
            workerBaseURL: settings.clusterWorkerBaseURL,
            listenPort: settings.clusterListenPort
        )

        if settings.clusterMode == .worker {
            status = .stopped
            logs.append("Worker mode active. Discord connection is disabled on this node.")
            return
        }

        guard !settings.token.isEmpty else {
            logs.append("⚠️ Token is empty; cannot start bot")
            return
        }

        if !serviceCallbacksConfigured {
            await configureServiceCallbacks()
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

        await service.connect(token: settings.token)
        logs.append("Connecting to Discord Gateway")
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
            await cluster.applySettings(
                mode: settings.clusterMode,
                nodeName: settings.clusterNodeName,
                workerBaseURL: settings.clusterWorkerBaseURL,
                listenPort: settings.clusterListenPort
            )
            await cluster.refreshWorkerHealth()
            let snapshot = await cluster.currentSnapshot()
            await MainActor.run {
                self.clusterSnapshot = snapshot
            }
            await pollClusterStatus()
        }
    }

    func refreshClusterStatusNow() async -> ClusterSnapshot {
        await cluster.applySettings(
            mode: settings.clusterMode,
            nodeName: settings.clusterNodeName,
            workerBaseURL: settings.clusterWorkerBaseURL,
            listenPort: settings.clusterListenPort
        )
        await cluster.refreshWorkerHealth()
        let snapshot = await cluster.currentSnapshot()
        self.clusterSnapshot = snapshot
        await pollClusterStatus()
        return snapshot
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
        var nodes: [ClusterNodeStatus] = [
            ClusterNodeStatus(
                id: "\(role.rawValue)-\(hostname.lowercased())-\(settings.clusterListenPort)",
                hostname: hostname,
                displayName: localNodeName,
                role: role,
                hardwareModel: localHardwareModelIdentifier(),
                cpu: 0,
                mem: 0,
                uptime: uptime,
                latencyMs: nil,
                status: clusterSnapshot.serverState.nodeHealthStatus,
                jobsActive: 0
            )
        ]

        if settings.clusterMode == .leader, !settings.clusterWorkerBaseURL.isEmpty {
            let host = URL(string: settings.clusterWorkerBaseURL)?.host ?? "Worker"
            nodes.append(
                ClusterNodeStatus(
                    id: "worker-\(host.lowercased())",
                    hostname: host,
                    displayName: host,
                    role: .worker,
                    hardwareModel: "Unknown",
                    cpu: 0,
                    mem: 0,
                    uptime: 0,
                    latencyMs: nil,
                    status: .disconnected,
                    jobsActive: 0
                )
            )
        }

        return nodes
    }

    private func localHardwareModelIdentifier() -> String {
        var length = 0
        // Use `hw.model` so identifiers resolve to Mac family names (for example MacBookAir10,1).
        guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 0 else {
            return "Mac"
        }
        var value = [CChar](repeating: 0, count: length)
        guard sysctlbyname("hw.model", &value, &length, nil, 0) == 0 else {
            return "Mac"
        }
        return String(cString: value)
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
        case "GUILD_DELETE":
            await handleGuildDelete(payload.d)
        default:
            break
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
                let scope = MemoryScope.directMessageUser(userId)
                let messages = await aiMessagesForScope(
                    scope: scope,
                    currentUserID: userId,
                    currentContent: content
                )
                if let aiReply = await cluster.generateAIReply(messages: messages) {
                    await conversationStore.append(
                        scope: scope,
                        messageID: messageId,
                        userID: userId,
                        content: content,
                        role: .user
                    )
                    let sent = await send(channelId, aiReply)
                    if sent {
                        await appendAssistantMessage(scope: scope, content: aiReply)
                    }
                    return
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
                let scope = MemoryScope.guildTextChannel(channelId)
                let messages = await aiMessagesForScope(
                    scope: scope,
                    currentUserID: userId,
                    currentContent: prompt
                )
                if let aiReply = await cluster.generateAIReply(messages: messages) {
                    await conversationStore.append(
                        scope: scope,
                        messageID: messageId,
                        userID: userId,
                        content: prompt,
                        role: .user
                    )
                    let sent = await send(channelId, aiReply)
                    if sent {
                        await appendAssistantMessage(scope: scope, content: aiReply)
                    }
                    return
                }
            }
        }

        guard content.hasPrefix(prefix) else { return }

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
            let dynamicWiki = wikiCommandHelpList(prefix: prefix)
            let wikiHelpSuffix = dynamicWiki.isEmpty
                ? ""
                : ", \(dynamicWiki)"
            return await send(
                channelId,
                "Commands: \(prefix)help, \(prefix)ping, \(prefix)roll NdS, \(prefix)8ball <question>, \(prefix)poll \"Question\" \"Option 1\" \"Option 2\", \(prefix)userinfo [@user]\(wikiHelpSuffix), \(prefix)cluster [status|test|probe], \(prefix)setchannel, \(prefix)ignorechannel #channel|list|remove #channel, \(prefix)notifystatus. Use <wiki-command> <source>::<query> to target a specific WikiBridge source."
            )
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
    ) async -> [Message] {
        var recent = await conversationStore.recentMessages(for: scope, limit: 20)
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

        let systemPrompt = settings.localAISystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "You are a friendly Discord assistant. Reply briefly and naturally."
            : settings.localAISystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let wikiContextEntries = await wikiContextCache.contextEntries(for: currentContent, limit: 3)
        let wikiContext = renderWikiContext(entries: wikiContextEntries)
        let combinedPrompt = wikiContext.isEmpty ? systemPrompt : "\(systemPrompt)\n\n\(wikiContext)"
        let systemMessage = Message(
            channelID: scope.id,
            userID: "system",
            username: "System",
            content: combinedPrompt,
            role: .system
        )
        return [systemMessage] + conversationalMessages
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

    private func send(_ channelId: String, _ message: String) async -> Bool {
        do {
            try await service.sendMessage(channelId: channelId, content: message, token: settings.token)
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

    private func clusterCommand(action: String, channelId: String) async -> Bool {
        let normalized = ["test", "refresh", "check", "remote", "probe"].contains(action) ? action : "status"
        let snapshot = await clusterSnapshotForCommand(action: normalized)
        let workerURL = snapshot.workerBaseURL.isEmpty ? "-" : snapshot.workerBaseURL

        let message = """
        🧭 **Cluster \(normalized.capitalized)**
        Mode: \(snapshot.mode.rawValue)
        Node: \(snapshot.nodeName)
        Server: \(snapshot.serverStatusText)
        Worker: \(snapshot.workerStatusText)
        Worker URL: \(workerURL)
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

        return ("Leader", leaderNode)
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
                            userId: userId,
                            username: displayName,
                            guildId: guildId,
                            channelId: newChannel,
                            fromChannelId: previous.channelId,
                            toChannelId: newChannel
                        )
                        _ = await sendVoiceNotification(guildId: guildId, message: message, event: .move)
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
                        userId: userId,
                        username: displayName,
                        guildId: guildId,
                        channelId: newChannel,
                        fromChannelId: nil,
                        toChannelId: newChannel
                    )
                    _ = await sendVoiceNotification(guildId: guildId, message: message, event: .join)
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
                    userId: userId,
                    username: displayName,
                    guildId: guildId,
                    channelId: previous.channelId,
                    fromChannelId: previous.channelId,
                    toChannelId: nil
                )
                _ = await sendVoiceNotification(guildId: guildId, message: message, event: .leave)
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

    private func sendVoiceNotification(guildId: String, message: String, event: VoiceNotifyEvent) async -> Bool {
        guard let guildSettings = settings.guildSettings[guildId],
              let channelId = guildSettings.notificationChannelId else { return false }

        switch event {
        case .join where !guildSettings.notifyOnJoin:
            return false
        case .leave where !guildSettings.notifyOnLeave:
            return false
        case .move where !guildSettings.notifyOnMove:
            return false
        default:
            break
        }

        return await send(channelId, message)
    }

    private func renderNotificationTemplate(
        _ template: String,
        userId: String,
        username: String,
        guildId: String,
        channelId: String,
        fromChannelId: String?,
        toChannelId: String?
    ) -> String {
        let guildName = connectedServers[guildId] ?? "Server \(guildId.suffix(4))"
        let resolvedFromChannelId = fromChannelId ?? channelId
        let resolvedToChannelId = toChannelId ?? channelId

        return template
            .replacingOccurrences(of: "{userId}", with: userId)
            .replacingOccurrences(of: "{username}", with: username)
            .replacingOccurrences(of: "{guildId}", with: guildId)
            .replacingOccurrences(of: "{guildName}", with: guildName)
            .replacingOccurrences(of: "{channelId}", with: channelId)
            .replacingOccurrences(of: "{channelName}", with: channelDisplayName(guildId: guildId, channelId: channelId))
            .replacingOccurrences(of: "{fromChannelId}", with: resolvedFromChannelId)
            .replacingOccurrences(of: "{toChannelId}", with: resolvedToChannelId)
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
        // TODO: Emit UserJoinedServer events when GUILD_MEMBER_ADD events are handled (future implementation)
    }

    private func handleGuildCreate(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw,
              case let .string(guildId)? = map["id"]
        else { return }

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
