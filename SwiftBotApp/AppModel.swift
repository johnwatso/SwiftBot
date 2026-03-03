import Foundation
import SwiftUI
import UpdateEngine

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
    @Published var patchyDebugLogs: [String] = []
    @Published var patchyIsCycleRunning = false
    @Published var patchyLastCycleAt: Date?

    var logs = LogStore()
    let ruleStore = RuleStore()

    private let store = ConfigStore()
    private let discordCacheStore = DiscordCacheStore()
    private let service = DiscordService()
    private let cluster = ClusterCoordinator()
    private let ruleEngine: RuleEngine
    private var serviceCallbacksConfigured = false
    private var uptimeTask: Task<Void, Never>?
    private var joinTimes: [String: Date] = [:]
    private var usernamesById: [String: String] = [:]
    private var discordCacheSaveTask: Task<Void, Never>?
    private var dmUsersSeen: Set<String> = []
    let eventBus = EventBus()
    private let pluginManager: PluginManager
    private var weeklyPlugin: WeeklySummaryPlugin?
    private let patchyChecker: UpdateChecker?
    private var patchyMonitorTask: Task<Void, Never>?
    private var botUserId: String?
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
            if migrateLegacyPatchySettingsIfNeeded(&loadedSettings) {
                migrated = true
            }

            settings = loadedSettings
            if let cachedDiscord = await discordCacheStore.load() {
                applyDiscordCacheSnapshot(cachedDiscord)
                logs.append("Loaded cached Discord metadata (\(cachedDiscord.connectedServers.count) servers)")
            }
            for target in settings.patchy.sourceTargets where target.source == .steam {
                resolveSteamNameIfNeeded(for: target)
            }

            if migrated {
                try? await store.save(loadedSettings)
            }

            await service.setRuleEngine(ruleEngine)
            await cluster.configureHandlers(
                aiHandler: { [weak self] message, username in
                    guard let self else { return nil }
                    return await self.service.generateSmartDMReply(message: message, username: username)
                },
                wikiHandler: { [weak self] query in
                    guard let self else { return nil }
                    return await self.service.lookupFinalsWiki(query: query)
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
                endpoint: settings.localAIEndpoint,
                model: settings.localAIModel,
                systemPrompt: settings.localAISystemPrompt
            )
            await cluster.applySettings(
                mode: settings.clusterMode,
                nodeName: settings.clusterNodeName,
                workerBaseURL: settings.clusterWorkerBaseURL,
                listenPort: settings.clusterListenPort
            )
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

        Task {
            await service.configureLocalAIDMReplies(
                enabled: settings.localAIDMReplyEnabled,
                endpoint: settings.localAIEndpoint,
                model: settings.localAIModel,
                systemPrompt: settings.localAISystemPrompt
            )
            await cluster.applySettings(
                mode: settings.clusterMode,
                nodeName: settings.clusterNodeName,
                workerBaseURL: settings.clusterWorkerBaseURL,
                listenPort: settings.clusterListenPort
            )
            configurePatchyMonitoring()

            do {
                try await store.save(settings)
                logs.append("✅ Settings saved")
            } catch {
                stats.errors += 1
                logs.append("❌ Failed saving settings: \(error.localizedDescription)")
            }
        }
    }

    func addPatchyTarget(_ target: PatchySourceTarget) {
        settings.patchy.sourceTargets.append(target)
        saveSettings()
        resolveSteamNameIfNeeded(for: target)
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
        dmUsersSeen.removeAll()
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
        dmUsersSeen.removeAll()
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
        return snapshot
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
            handleReady(payload.d)
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
            handleGuildCreate(payload.d)
        case "GUILD_DELETE":
            handleGuildDelete(payload.d)
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

        if case let .string(userId)? = author["id"] {
            cacheUsername(userId: userId, username: username)
        }

        // Ignore messages from bots (including this bot) to prevent reply loops.
        if case let .bool(isBot)? = author["bot"], isBot {
            return
        }

        let prefix = effectivePrefix()
        let isDM = map["guild_id"] == nil || map["guild_id"] == .null
        if isDM, !content.hasPrefix(prefix) {
            let dmUserKey: String
            if case let .string(userId)? = author["id"] {
                dmUserKey = userId
            } else {
                dmUserKey = username
            }

            if !dmUsersSeen.contains(dmUserKey) {
                dmUsersSeen.insert(dmUserKey)
                try? await service.sendMessage(channelId: channelId, content: "👋 Hey there! If you need help, type \(prefix)help to see what I can do!", token: settings.token)
                return
            }

            if settings.localAIDMReplyEnabled,
               let aiReply = await cluster.generateAIReply(message: content, username: username) {
                try? await service.sendMessage(channelId: channelId, content: aiReply, token: settings.token)
                return
            }

            try? await service.sendMessage(channelId: channelId, content: "If you need help, type \(prefix)help.", token: settings.token)
            return
        }

        await eventBus.publish(MessageReceived(
            guildId: (map["guild_id"] != nil && map["guild_id"] != .null) ? ( ( { () -> String in if case let .string(gid)? = map["guild_id"] { return gid } else { return "" } }() ) ) : nil,
            channelId: channelId,
            userId: ( { () -> String in if case let .string(uid)? = author["id"] { return uid } else { return "" } }() ),
            username: username,
            content: content,
            isDirectMessage: isDM
        ))

        if !isDM,
           settings.localAIDMReplyEnabled,
           isMentioningBot(map),
           !content.hasPrefix(prefix) {
            let prompt = contentWithoutBotMention(content)
            if !prompt.isEmpty,
               let aiReply = await cluster.generateAIReply(message: prompt, username: username) {
                try? await service.sendMessage(channelId: channelId, content: aiReply, token: settings.token)
                return
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
            return await send(channelId, "Commands: \(prefix)help, \(prefix)ping, \(prefix)roll NdS, \(prefix)8ball <question>, \(prefix)poll \"Question\" \"Option 1\" \"Option 2\", \(prefix)userinfo [@user], \(prefix)finals <question>, \(prefix)weapon <name>, \(prefix)cluster [status|test|probe], \(prefix)setchannel, \(prefix)ignorechannel #channel|list|remove #channel, \(prefix)notifystatus")
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
        case "finals", "wiki", "weapon":
            let query = tokens.dropFirst().joined(separator: " ")
            return await finalsWikiLookup(query: query, channelId: channelId)
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
            _ = await unknown(channelId)
            return false
        }
    }

    private func unknown(_ channelId: String) async -> Bool {
        await send(channelId, "❓ I don't know that command! Type \(effectivePrefix())help to see all available commands.")
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

    private func finalsWikiLookup(query: String, channelId: String) async -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return await send(channelId, "📘 Usage: \(effectivePrefix())finals <weapon, gadget, map, mode, patch, or topic>")
        }

        guard let result = await cluster.lookupFinalsWiki(query: trimmedQuery) else {
            return await send(channelId, "❌ I couldn't find a relevant THE FINALS Wiki page for \"\(trimmedQuery)\".")
        }

        let body: String
        if let weaponStats = result.weaponStats {
            body = formattedWeaponStats(result: result, stats: weaponStats)
        } else {
            let summary = summarizedWikiExtract(result.extract)
            body = summary.isEmpty
                ? "📘 **\(result.title)**\n\(result.url)"
                : "📘 **\(result.title)**\n\(summary)\n\(result.url)"
        }

        return await send(channelId, body)
    }

    private func formattedWeaponStats(result: FinalsWikiLookupResult, stats: FinalsWeaponStats) -> String {
        var lines: [String] = []

        if let type = stats.type, !type.isEmpty {
            lines.append("📘 **\(result.title)** • \(type)")
        } else {
            lines.append("📘 **\(result.title)**")
        }

        let damageLine = [
            stats.bodyDamage.map { "Body \($0)" },
            stats.headshotDamage.map { "Head \($0)" }
        ].compactMap { $0 }.joined(separator: " • ")
        if !damageLine.isEmpty {
            lines.append("Damage: \(damageLine)")
        }

        if let fireRate = stats.fireRate, !fireRate.isEmpty {
            lines.append("Fire Rate: \(fireRate)")
        }

        let falloffLine = [
            stats.dropoffStart.map { "Start \($0)" },
            stats.dropoffEnd.map { "End \($0)" },
            stats.minimumDamage.map { "Min \($0)" }
        ].compactMap { $0 }.joined(separator: " • ")
        if !falloffLine.isEmpty {
            lines.append("Falloff: \(falloffLine)")
        }

        if let magazineSize = stats.magazineSize, !magazineSize.isEmpty {
            lines.append("Magazine: \(magazineSize)")
        }

        let reloadLine = [
            stats.shortReload.map { "Short \($0)" },
            stats.longReload.map { "Long \($0)" }
        ].compactMap { $0 }.joined(separator: " • ")
        if !reloadLine.isEmpty {
            lines.append("Reload: \(reloadLine)")
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

        switch commandName {
        case "finals", "wiki", "cluster", "worker":
            let snapshot = await cluster.currentSnapshot()
            return (snapshot.lastJobRoute.rawValue.capitalized, snapshot.lastJobNode)
        default:
            return ("Leader", leaderNode)
        }
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
        let displayName = voiceDisplayName(from: map, userId: userId)

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

    private func voiceDisplayName(from map: [String: DiscordJSON], userId: String) -> String {
        if case let .object(member)? = map["member"] {
            if case let .string(nick)? = member["nick"], !nick.isEmpty {
                cacheUsername(userId: userId, username: nick)
                return nick
            }

            if case let .object(user)? = member["user"] {
                if case let .string(globalName)? = user["global_name"], !globalName.isEmpty {
                    cacheUsername(userId: userId, username: globalName)
                    return globalName
                }
                if case let .string(username)? = user["username"], !username.isEmpty {
                    cacheUsername(userId: userId, username: username)
                    return username
                }
            }
        }

        if case let .object(user)? = map["user"] {
            if case let .string(globalName)? = user["global_name"], !globalName.isEmpty {
                cacheUsername(userId: userId, username: globalName)
                return globalName
            }
            if case let .string(username)? = user["username"], !username.isEmpty {
                cacheUsername(userId: userId, username: username)
                return username
            }
        }

        if let cached = usernamesById[userId], !cached.isEmpty {
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

    private func handleReady(_ raw: DiscordJSON?) {
        guard case let .object(map)? = raw else { return }
        guard case let .array(guilds)? = map["guilds"] else { return }

        for guild in guilds {
            guard case let .object(guildMap) = guild,
                  case let .string(guildId)? = guildMap["id"]
            else { continue }

            let guildName: String
            if case let .string(name)? = guildMap["name"] {
                guildName = name
            } else {
                guildName = "Server \(guildId.suffix(4))"
            }

            connectedServers[guildId] = guildName
        }
        scheduleDiscordCacheSave()
        // TODO: Emit UserJoinedServer events when GUILD_MEMBER_ADD events are handled (future implementation)
    }

    private func handleGuildCreate(_ raw: DiscordJSON?) {
        guard case let .object(map)? = raw,
              case let .string(guildId)? = map["id"]
        else { return }

        let guildName: String
        if case let .string(name)? = map["name"] {
            guildName = name
        } else {
            guildName = "Server \(guildId.suffix(4))"
        }

        connectedServers[guildId] = guildName
        availableVoiceChannelsByServer[guildId] = parseVoiceChannels(from: map)
        availableTextChannelsByServer[guildId] = parseTextChannels(from: map)
        availableRolesByServer[guildId] = parseRoles(from: map)
        cacheGuildMembers(from: map)
        syncVoicePresenceFromGuildSnapshot(guildId: guildId, guildMap: map)
        scheduleDiscordCacheSave()
    }

    private func handleGuildDelete(_ raw: DiscordJSON?) {
        guard case let .object(map)? = raw,
              case let .string(guildId)? = map["id"]
        else { return }

        connectedServers[guildId] = nil
        availableVoiceChannelsByServer[guildId] = nil
        availableTextChannelsByServer[guildId] = nil
        availableRolesByServer[guildId] = nil
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

    private func syncVoicePresenceFromGuildSnapshot(guildId: String, guildMap: [String: DiscordJSON]) {
        guard case let .array(voiceStates)? = guildMap["voice_states"] else { return }

        activeVoice.removeAll { $0.guildId == guildId }
        joinTimes = joinTimes.filter { !$0.key.hasPrefix("\(guildId)-") }

        let now = Date()
        for state in voiceStates {
            guard case let .object(stateMap) = state,
                  case let .string(userId)? = stateMap["user_id"],
                  case let .string(channelId)? = stateMap["channel_id"]
            else { continue }

            let username = voiceDisplayName(from: stateMap, userId: userId)
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

    private func cacheGuildMembers(from guildMap: [String: DiscordJSON]) {
        guard case let .array(members)? = guildMap["members"] else { return }

        for member in members {
            guard case let .object(memberMap) = member else { continue }
            if case let .string(nick)? = memberMap["nick"], !nick.isEmpty,
               case let .object(user)? = memberMap["user"],
               case let .string(userId)? = user["id"] {
                cacheUsername(userId: userId, username: nick)
                continue
            }

            guard case let .object(user)? = memberMap["user"],
                  case let .string(userId)? = user["id"] else { continue }

            if case let .string(globalName)? = user["global_name"], !globalName.isEmpty {
                cacheUsername(userId: userId, username: globalName)
            } else if case let .string(username)? = user["username"], !username.isEmpty {
                cacheUsername(userId: userId, username: username)
            }
        }
    }

    private func cacheUsername(userId: String, username: String) {
        let cleaned = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if usernamesById[userId] == cleaned { return }
        usernamesById[userId] = cleaned
        knownUsersById = usernamesById
        scheduleDiscordCacheSave()
    }

    private func applyDiscordCacheSnapshot(_ snapshot: DiscordCacheSnapshot) {
        connectedServers = snapshot.connectedServers
        availableVoiceChannelsByServer = snapshot.availableVoiceChannelsByServer
        availableTextChannelsByServer = snapshot.availableTextChannelsByServer
        availableRolesByServer = snapshot.availableRolesByServer
        usernamesById = snapshot.usernamesById
        knownUsersById = snapshot.usernamesById
    }

    private func buildDiscordCacheSnapshot() -> DiscordCacheSnapshot {
        DiscordCacheSnapshot(
            updatedAt: Date(),
            connectedServers: connectedServers,
            availableVoiceChannelsByServer: availableVoiceChannelsByServer,
            availableTextChannelsByServer: availableTextChannelsByServer,
            availableRolesByServer: availableRolesByServer,
            usernamesById: usernamesById
        )
    }

    private func scheduleDiscordCacheSave() {
        let snapshot = buildDiscordCacheSnapshot()
        discordCacheSaveTask?.cancel()
        discordCacheSaveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            do {
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
