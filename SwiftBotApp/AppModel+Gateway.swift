import Foundation

extension AppModel {
    func handlePayload(_ payload: GatewayPayload) async {
        await gatewayEventDispatcher.dispatch(
            payload,
            shouldProcessPrimaryGatewayActions: shouldProcessPrimaryGatewayActions
        )
    }

    func makeGatewayEventDispatcher() -> GatewayEventDispatcher {
        GatewayEventDispatcher(
            onEventReceived: { [weak self] eventName in
                guard let self else { return }
                self.recordGatewayEvent(named: eventName)
            },
            onMessageCreate: { [weak self] event in
                await self?.handleMessageCreate(event)
            },
            onMessageReactionAdd: { [weak self] raw in
                await self?.handleMessageReactionAdd(raw)
            },
            onInteractionCreate: { [weak self] event in
                await self?.handleInteractionCreate(event)
            },
            onVoiceStateUpdate: { [weak self] event in
                await self?.handleVoiceStateUpdateDispatch(event)
            },
            onReady: { [weak self] event, shouldRegisterSlashCommands in
                await self?.handleReadyDispatch(event, shouldRegisterSlashCommands: shouldRegisterSlashCommands)
            },
            onGuildCreate: { [weak self] event in
                await self?.handleGuildCreate(event)
            },
            onChannelCreate: { [weak self] event in
                await self?.handleChannelCreate(event)
            },
            onMemberJoin: { [weak self] event in
                await self?.handleMemberJoin(event)
            },
            onMemberLeave: { [weak self] event in
                await self?.handleMemberLeave(event)
            },
            onGuildDelete: { [weak self] event in
                await self?.handleGuildDelete(event)
            }
        )
    }

    private func recordGatewayEvent(named eventName: String) {
        gatewayEventCount += 1
        lastGatewayEventName = eventName
    }

    private func handleVoiceStateUpdateDispatch(_ event: GatewayVoiceStateUpdateEvent) async {
        voiceStateEventCount += 1
        await handleVoiceStateUpdate(event)
    }

    private func handleReadyDispatch(_ event: GatewayReadyEvent, shouldRegisterSlashCommands: Bool) async {
        readyEventCount += 1
        connectionDiagnostics.lastGatewayCloseCode = nil
        updateBotIdentity(event.identity)
        await handleReady(event)
        logs.append("READY received")
        if shouldRegisterSlashCommands {
            await registerSlashCommandsIfNeeded()
        }
    }

    private func updateBotIdentity(_ identity: GatewayBotIdentity?) {
        botUserId = identity?.id
        if let username = identity?.username {
            botUsername = username
        }
        botDiscriminator = identity?.discriminator
        botAvatarHash = identity?.avatarHash
    }

    func handleMeshSync(_ payload: MeshSyncPayload) async {
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

        // Merge image usage counts
        if let remoteUsage = payload.imageUsage {
            for (key, count) in remoteUsage {
                let current = settings.openAIImageUsageByUserMonth[key] ?? 0
                if count > current {
                    settings.openAIImageUsageByUserMonth[key] = count
                }
            }
        }

        if let lastID = payload.conversations.last?.id {
            localLastMergedRecordID = lastID
        }
        if let remoteCommandLog = payload.commandLog {
            commandLog = Array(remoteCommandLog.prefix(200))
        }
        if let remoteVoiceLog = payload.voiceLog {
            voiceLog = Array(remoteVoiceLog.prefix(200))
        }
        if let remoteActiveVoice = payload.activeVoice {
            await replaceVoicePresence(remoteActiveVoice)
        }
        if payload.configFilesChanged, settings.clusterMode == .standby {
            await pullConfigFilesFromLeader()
        }
        if !payload.conversations.isEmpty {
            logs.append("SwiftMesh: merged \(payload.conversations.count) record(s) (term \(payload.leaderTerm))")
        } else if payload.configFilesChanged {
            logs.append("SwiftMesh: config updated on Primary — pulled latest config files")
        }
        // Fetch next page immediately if more records exist.
        if payload.hasMore {
            await requestResyncFromLeader(fromRecordID: localLastMergedRecordID)
        }
    }

    /// Standby requests a bounded page of records from the leader starting after `fromRecordID`.
    func requestResyncFromLeader(fromRecordID: String?) async {
        guard let payload = await cluster.fetchResyncPage(fromRecordID: fromRecordID, pageSize: 500) else { return }
        await handleMeshSync(payload)
    }

    /// Leader: push current image usage map to all nodes.
    func pushImageUsageToAllNodes() async {
        guard settings.clusterMode == .leader else { return }
        let nodes = await cluster.registeredNodeInfo()
        guard !nodes.isEmpty else { return }
        let currentTerm = await cluster.currentLeaderTerm()
        
        let payload = MeshSyncPayload(
            conversations: [],
            imageUsage: settings.openAIImageUsageByUserMonth,
            leaderTerm: currentTerm
        )
        
        for (_, baseURL) in nodes {
            _ = await cluster.pushConversationsToSingleNode(baseURL, payload)
        }
    }

    func handleMeshRequest(type: String) async -> Data? {
        switch type {
        case "wiki-cache":
            let all = await wikiContextCache.allEntries()
            return try? JSONEncoder().encode(all)
        case "image-usage":
            return try? JSONEncoder().encode(settings.openAIImageUsageByUserMonth)
        case "config-files":
            return await store.exportMeshSyncedFiles(
                excludingFileNames: Set([
                    SwiftBotStorage.swiftMeshConfigFileName,
                    SwiftBotStorage.clusterStateFileName
                ])
            )
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
    func checkRateLimit(userId: String, username: String, channelId: String, isDM: Bool) async -> Bool {
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

    func startRateLimitCleanupTask() async {
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

    func cleanupRateLimitCache() {
        let now = Date()
        let expired = lastCommandTimeByUserId.filter { now.timeIntervalSince($1) > 60.0 }.map { $0.key }
        for key in expired {
            lastCommandTimeByUserId.removeValue(forKey: key)
        }
        if !expired.isEmpty {
            logs.append("🧹 Cleaned up \(expired.count) rate limit cache entries")
        }
    }

    func handleMessageCreate(_ event: GatewayMessageCreateEvent) async {
        let map = event.rawMap
        let content = event.content
        let username = event.username
        let channelId = event.channelID
        let userId = event.userID
        if let avatarHash = event.avatarHash, !avatarHash.isEmpty {
            userAvatarHashById[userId] = avatarHash
        }
        let messageId = event.messageID
        let isBot = event.isBot
        let channelType = await resolvedChannelType(from: map, channelID: channelId)
        let isDMChannel = (channelType == 1 || channelType == 3)
        let isGuildTextChannel = (channelType == 0)
        let guildID = event.guildID
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
            if let memoryText = extractAIMemoryInstruction(from: content) {
                _ = await rememberAIMemory(
                    text: memoryText,
                    userId: userId,
                    username: username,
                    channelId: channelId
                )
                return
            }

            if settings.localAIDMReplyEnabled {
                guard await checkRateLimit(userId: userId, username: username, channelId: channelId, isDM: true) else { return }

                // Skip AI reply if message was already handled by rule actions
                if await service.wasMessageHandledByRules(messageId: messageId) {
                    logs.append("AI DM reply skipped: message \(messageId) was handled by rule actions")
                    return
                }

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

        if isGuildTextChannel, isMentioningBot(map) {
            let mentionText = contentWithoutBotMention(content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if mentionText == "bug" {
                if settings.bugTrackingEnabled {
                    await handleBugTrackCommand(raw: map, username: username, responseChannelId: channelId)
                }
                return
            }
        }

        if isGuildTextChannel,
           settings.localAIDMReplyEnabled,
           settings.behavior.useAIInGuildChannels,
           isMentioningBot(map),
           !content.hasPrefix(prefix) {
            let prompt = contentWithoutBotMention(content)
            if !prompt.isEmpty {
                if let memoryText = extractAIMemoryInstruction(from: prompt) {
                    _ = await rememberAIMemory(
                        text: memoryText,
                        userId: userId,
                        username: username,
                        channelId: channelId
                    )
                    return
                }

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

    func handleMessageReactionAdd(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw else { return }
        await handleBugReactionAdd(raw: map)
    }

    func handleInteractionCreate(_ event: GatewayInteractionCreateEvent) async {
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "respondToInteraction", log: { logs.append($0) }) else { return }
        let context = interactionContext(from: event.rawMap)
        do {
            try await service.respondToInteraction(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                payload: ["type": 5]
            )
        } catch {
            logs.append("❌ Failed ACK for slash command: \(error.localizedDescription)")
            return
        }

        let response: SlashResponsePayload
        if settings.commandsEnabled && settings.slashCommandsEnabled {
            response = await executeSlashCommand(
                command: event.commandName.lowercased(),
                data: event.data,
                context: context
            )
        } else {
            response = (
                content: nil,
                embeds: [[
                    "title": "Slash Commands Disabled",
                    "description": "Slash commands are turned off in SwiftBot settings.",
                    "color": 15_790_767
                ]]
            )
        }
        stats.commandsRun += 1
        let slashCommandForLog = formatSlashCommandForLog(name: event.commandName, data: event.data)
        let slashOk = response.embeds != nil || (response.content?.isEmpty == false)
        let slashExecutionDetails = await commandExecutionDetails(for: event.commandName.lowercased())
        commandLog.insert(CommandLogEntry(
            time: Date(),
            user: context.username,
            server: commandServerName(from: context.rawLikeMessage),
            command: slashCommandForLog,
            channel: context.channelId,
            executionRoute: slashExecutionDetails.route,
            executionNode: slashExecutionDetails.node,
            ok: slashOk
        ), at: 0)

        guard let applicationID = botUserId, !applicationID.isEmpty else { return }
        do {
            var payload: [String: Any] = [:]
            if let content = response.content {
                payload["content"] = String(content.prefix(1900))
            }
            if let embeds = response.embeds, !embeds.isEmpty {
                payload["embeds"] = Array(embeds.prefix(10))
            }
            if payload.isEmpty {
                payload["content"] = "Done."
            }
            try await service.editOriginalInteractionResponse(
                applicationID: applicationID,
                interactionToken: event.interactionToken,
                payload: payload
            )
        } catch {
            logs.append("❌ Failed editing slash response: \(error.localizedDescription)")
        }
    }

    private func formatSlashCommandForLog(name: String, data: [String: DiscordJSON]) -> String {
        guard case let .array(options)? = data["options"], !options.isEmpty else {
            return "/\(name)"
        }
        let rendered: [String] = options.compactMap { option in
            guard case let .object(map) = option,
                  case let .string(optionName)? = map["name"] else { return nil }
            switch map["value"] {
            case let .string(value)?:
                return "\(optionName):\(value)"
            case let .int(value)?:
                return "\(optionName):\(value)"
            case let .double(value)?:
                return "\(optionName):\(value)"
            case let .bool(value)?:
                return "\(optionName):\(value)"
            default:
                return optionName
            }
        }
        if rendered.isEmpty { return "/\(name)" }
        return "/\(name) " + rendered.joined(separator: " ")
    }

    func registerSlashCommandsIfNeeded() async {
        guard let appID = botUserId, !appID.isEmpty else { return }
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        let slashEnabled = settings.commandsEnabled && settings.slashCommandsEnabled
        if lastSlashCommandsEnabledState != slashEnabled {
            lastSlashRegistrationAt = nil
            lastSlashGuildRegistrationAt.removeAll()
            clearedGlobalSlashCommands = false
            lastSlashCommandsEnabledState = slashEnabled
        }
        let commands = buildSlashCommandDefinitions()
        let now = Date()
        let guildIds = connectedServers.keys.sorted()

        if !guildIds.isEmpty, !clearedGlobalSlashCommands {
            do {
                try await service.registerGlobalApplicationCommands(
                    applicationID: appID,
                    commands: [],
                    token: token
                )
                clearedGlobalSlashCommands = true
                lastSlashRegistrationAt = now
                logs.append("✅ Cleared global slash commands to avoid duplicates")
            } catch {
                logs.append("⚠️ Failed clearing global slash commands: \(error.localizedDescription)")
            }
        }

        var guildRegisteredCount = 0
        for guildId in guildIds {
            if let last = lastSlashGuildRegistrationAt[guildId], now.timeIntervalSince(last) < 300 {
                continue
            }
            do {
                try await service.registerGuildApplicationCommands(
                    applicationID: appID,
                    guildID: guildId,
                    commands: commands,
                    token: token
                )
                lastSlashGuildRegistrationAt[guildId] = now
                guildRegisteredCount += 1
            } catch {
                logs.append("⚠️ Guild slash command registration failed (\(guildId)): \(error.localizedDescription)")
            }
        }
        if guildRegisteredCount > 0 {
            if slashEnabled {
                logs.append("✅ Slash commands registered for \(guildRegisteredCount) guild(s)")
            } else {
                logs.append("✅ Slash commands disabled and cleared for \(guildRegisteredCount) guild(s)")
            }
        } else if guildIds.isEmpty,
                  (lastSlashRegistrationAt == nil || now.timeIntervalSince(lastSlashRegistrationAt!) >= 300) {
            do {
                try await service.registerGlobalApplicationCommands(
                    applicationID: appID,
                    commands: commands,
                    token: token
                )
                lastSlashRegistrationAt = now
                if slashEnabled {
                    logs.append("✅ Slash commands registered globally (no guilds known yet)")
                } else {
                    logs.append("✅ Slash commands disabled and cleared globally")
                }
            } catch {
                logs.append("❌ Global slash command registration failed: \(error.localizedDescription)")
            }
        }
    }

    typealias SlashContext = CommandProcessor.SlashContext
    typealias SlashResponsePayload = CommandProcessor.SlashResponsePayload

    func interactionContext(from map: [String: DiscordJSON]) -> SlashContext {
        let channelId: String = {
            if case let .string(id)? = map["channel_id"] { return id }
            return ""
        }()

        var username = "User"
        var userId = "unknown-user"
        if case let .object(member)? = map["member"],
           case let .object(user)? = member["user"] {
            if case let .string(id)? = user["id"] { userId = id }
            if case let .string(name)? = user["username"] { username = name }
        } else if case let .object(user)? = map["user"] {
            if case let .string(id)? = user["id"] { userId = id }
            if case let .string(name)? = user["username"] { username = name }
        }

        var rawLike: [String: DiscordJSON] = [
            "channel_id": .string(channelId),
            "author": .object(["id": .string(userId), "username": .string(username)])
        ]
        if let guildId = guildId(from: map) {
            rawLike["guild_id"] = .string(guildId)
        }
        if case let .object(member)? = map["member"] {
            rawLike["member"] = .object(member)
        }

        return .init(channelId: channelId, username: username, rawLikeMessage: rawLike)
    }

    func executeSlashCommand(
        command: String,
        data: [String: DiscordJSON],
        context: SlashContext
    ) async -> SlashResponsePayload {
        await commandProcessor.executeSlashCommand(command: command, data: data, context: context)
    }

    func handleVoiceStateUpdate(_ event: GatewayVoiceStateUpdateEvent) async {
        let allowPrimarySideEffects = shouldProcessPrimaryGatewayActions
        let map = event.rawMap
        let userId = event.userID
        let guildId = event.guildID

        let now = Date()
        if let avatarHash = avatarHashFromVoicePayload(map), !avatarHash.isEmpty {
            userAvatarHashById[userId] = avatarHash
        }
        let memberKey = "\(guildId)-\(userId)"
        if let guildAvatarHash = guildAvatarHashFromVoicePayload(map), !guildAvatarHash.isEmpty {
            guildAvatarHashByMemberKey[memberKey] = guildAvatarHash
        }
        let displayName = await voiceDisplayName(from: map, userId: userId)

        lastVoiceStateAt = now

        let channelId = event.channelID
        let channelName = channelId.map { channelDisplayName(guildId: guildId, channelId: $0) } ?? ""
        let transition = await voicePresenceStore.applyVoiceStateUpdate(
            guildID: guildId,
            userID: userId,
            displayName: displayName,
            channelID: channelId,
            channelName: channelName,
            now: now
        )
        activeVoice = await voicePresenceStore.snapshot()

        switch transition {
        case .ignored:
            break
        case .unchanged:
            return
        case .joined(let next):
            stats.voiceJoins += 1
            lastVoiceStateSummary = "JOIN \(displayName) -> \(next.channelName)"
            addEvent(ActivityEvent(timestamp: now, kind: .voiceJoin, message: "🟢 @\(displayName) joined \(next.channelName)"))
            voiceLog.insert(VoiceEventLogEntry(time: now, description: "JOIN \(displayName) \(next.channelName)"), at: 0)

            if allowPrimarySideEffects,
               shouldNotifyVoiceEvent(guildId: guildId, channelId: next.channelId) {
                let message = renderNotificationTemplate(
                    settings.guildSettings[guildId]?.joinNotificationTemplate ?? GuildSettings().joinNotificationTemplate,
                    username: displayName,
                    guildId: guildId,
                    channelId: next.channelId,
                    fromChannelId: nil,
                    toChannelId: next.channelId
                )
                _ = await sendVoiceNotification(guildId: guildId, message: message, event: .join,
                    displayName: displayName, channelName: next.channelName)
            }
            if allowPrimarySideEffects {
                await eventBus.publish(VoiceJoined(guildId: guildId, userId: userId, username: displayName, channelId: next.channelId))
            }
        case .moved(let previous, let next, let startedAt):
            let elapsed = formatDuration(from: startedAt, to: now)
            stats.voiceLeaves += 1
            lastVoiceStateSummary = "MOVE \(displayName): \(previous.channelName) -> \(next.channelName)"
            addEvent(ActivityEvent(timestamp: now, kind: .voiceMove, message: "🔀 @\(displayName) moved from \(previous.channelName) — Time in chat: \(elapsed) → \(next.channelName)"))
            voiceLog.insert(VoiceEventLogEntry(time: now, description: "MOVE \(displayName) \(previous.channelName) -> \(next.channelName)"), at: 0)

            if allowPrimarySideEffects,
               (shouldNotifyVoiceEvent(guildId: guildId, channelId: previous.channelId) || shouldNotifyVoiceEvent(guildId: guildId, channelId: next.channelId)) {
                let message = renderNotificationTemplate(
                    settings.guildSettings[guildId]?.moveNotificationTemplate ?? GuildSettings().moveNotificationTemplate,
                    username: displayName,
                    guildId: guildId,
                    channelId: next.channelId,
                    fromChannelId: previous.channelId,
                    toChannelId: next.channelId
                )
                _ = await sendVoiceNotification(guildId: guildId, message: message, event: .move,
                    displayName: displayName, channelName: next.channelName,
                    fromChannelName: previous.channelName)
            }
        case .left(let previous, let startedAt):
            let elapsed = formatDuration(from: startedAt, to: now)
            stats.voiceLeaves += 1
            lastVoiceStateSummary = "LEAVE \(previous.username) <- \(previous.channelName)"
            addEvent(ActivityEvent(timestamp: now, kind: .voiceLeave, message: "🔴 @\(previous.username) left \(previous.channelName) — Time in chat: \(elapsed)"))
            voiceLog.insert(VoiceEventLogEntry(time: now, description: "LEAVE \(previous.username) \(previous.channelName) duration=\(elapsed)"), at: 0)

            if allowPrimarySideEffects,
               shouldNotifyVoiceEvent(guildId: guildId, channelId: previous.channelId) {
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
            let elapsedSec = Int(now.timeIntervalSince(startedAt))
            if allowPrimarySideEffects {
                await eventBus.publish(VoiceLeft(guildId: guildId, userId: userId, username: displayName, channelId: previous.channelId, durationSeconds: elapsedSec))
            }
        }

        if voiceLog.count > 200 { voiceLog.removeLast(voiceLog.count - 200) }
    }

    enum VoiceNotifyEvent {
        case join
        case leave
        case move
    }

    func voiceDisplayName(from map: [String: DiscordJSON], userId: String) async -> String {
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

    private func avatarHashFromVoicePayload(_ map: [String: DiscordJSON]) -> String? {
        if case let .object(member)? = map["member"],
           case let .object(user)? = member["user"],
           case let .string(avatarHash)? = user["avatar"] {
            return avatarHash
        }
        if case let .object(user)? = map["user"],
           case let .string(avatarHash)? = user["avatar"] {
            return avatarHash
        }
        return nil
    }

    private func guildAvatarHashFromVoicePayload(_ map: [String: DiscordJSON]) -> String? {
        if case let .object(member)? = map["member"],
           case let .string(avatarHash)? = member["avatar"] {
            return avatarHash
        }
        return nil
    }

    func channelDisplayName(guildId: String, channelId: String) -> String {
        if let channel = availableVoiceChannelsByServer[guildId]?.first(where: { $0.id == channelId }) {
            return channel.name
        }
        return "#\(channelId.suffix(5))"
    }

    func shouldNotifyVoiceEvent(guildId: String, channelId: String) -> Bool {
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
    func sendVoiceNotification(
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

    func renderNotificationTemplate(
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

    func handleReady(_ event: GatewayReadyEvent) async {
        for guild in event.guilds {
            await discordCache.upsertGuild(id: guild.id, name: guild.name)
        }
        await syncPublishedDiscordCacheFromService()
        scheduleDiscordCacheSave()
        // GUILD_MEMBER_ADD is now handled via handleMemberJoin (P0.5).
    }


}
