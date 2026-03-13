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
            onMessageCreate: { [weak self] raw in
                await self?.handleMessageCreate(raw)
            },
            onMessageReactionAdd: { [weak self] raw in
                await self?.handleMessageReactionAdd(raw)
            },
            onInteractionCreate: { [weak self] raw in
                await self?.handleInteractionCreate(raw)
            },
            onVoiceStateUpdate: { [weak self] raw in
                await self?.handleVoiceStateUpdateDispatch(raw)
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
            onMemberJoin: { [weak self] raw in
                await self?.handleMemberJoin(raw)
            },
            onMemberLeave: { [weak self] raw in
                await self?.handleMemberLeave(raw)
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

    private func handleVoiceStateUpdateDispatch(_ raw: DiscordJSON?) async {
        voiceStateEventCount += 1
        await handleVoiceStateUpdate(raw)
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
            activeVoice = remoteActiveVoice
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

    func handleMessageCreate(_ raw: DiscordJSON?) async {
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
        if case let .string(avatarHash)? = author["avatar"], !avatarHash.isEmpty {
            userAvatarHashById[userId] = avatarHash
        }
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

    func handleInteractionCreate(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw else { return }
        guard case let .string(interactionID)? = map["id"],
              case let .string(interactionToken)? = map["token"] else { return }
        guard case let .int(kind)? = map["type"], kind == 2 else { return } // 2 = application command
        guard case let .object(data)? = map["data"],
              case let .string(commandName)? = data["name"] else { return }

        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "respondToInteraction", log: { logs.append($0) }) else { return }
        let context = interactionContext(from: map)
        do {
            try await service.respondToInteraction(
                interactionID: interactionID,
                interactionToken: interactionToken,
                payload: ["type": 5]
            )
        } catch {
            logs.append("❌ Failed ACK for slash command: \(error.localizedDescription)")
            return
        }

        let response: SlashResponsePayload
        if settings.commandsEnabled && settings.slashCommandsEnabled {
            response = await executeSlashCommand(
                command: commandName.lowercased(),
                data: data,
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
        let slashCommandForLog = formatSlashCommandForLog(name: commandName, data: data)
        let slashOk = response.embeds != nil || (response.content?.isEmpty == false)
        let slashExecutionDetails = await commandExecutionDetails(for: commandName.lowercased())
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
                interactionToken: interactionToken,
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

    typealias SlashContext = (channelId: String, username: String, rawLikeMessage: [String: DiscordJSON])
    typealias SlashResponsePayload = (content: String?, embeds: [[String: Any]]?)

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

        return (channelId: channelId, username: username, rawLikeMessage: rawLike)
    }

    func executeSlashCommand(
        command: String,
        data: [String: DiscordJSON],
        context: SlashContext
    ) async -> SlashResponsePayload {
        func embed(title: String, description: String, color: Int = 5_793_266) -> SlashResponsePayload {
            (
                content: nil,
                embeds: [[
                    "title": title,
                    "description": description,
                    "color": color
                ]]
            )
        }

        func statusEmbed(title: String, ok: Bool) -> SlashResponsePayload {
            embed(title: title, description: ok ? "✅ Completed." : "❌ Failed.", color: ok ? 3_062_954 : 15_790_767)
        }

        guard settings.commandsEnabled else {
            return embed(title: "Commands Disabled", description: "Commands are turned off in SwiftBot settings.", color: 15_790_767)
        }

        guard settings.slashCommandsEnabled else {
            return embed(title: "Slash Commands Disabled", description: "Slash commands are turned off in SwiftBot settings.", color: 15_790_767)
        }

        guard isCommandEnabled(name: command, surface: "slash") else {
            return embed(title: "Slash Command Disabled", description: "`/\(command)` is disabled in command settings.", color: 15_790_767)
        }

        switch command {
        case "help":
            let cmd = slashOptionString(named: "command", in: data)
            if let cmd, !cmd.isEmpty {
                _ = await executeCommand(
                    "help \(cmd)",
                    username: context.username,
                    channelId: context.channelId,
                    raw: context.rawLikeMessage,
                    bypassSystemToggles: true
                )
            } else {
                _ = await executeCommand(
                    "help",
                    username: context.username,
                    channelId: context.channelId,
                    raw: context.rawLikeMessage,
                    bypassSystemToggles: true
                )
            }
            return embed(title: "Help", description: "📘 Posted help details in this channel.")
        case "ping":
            return embed(title: "Ping", description: "🏓 Pong!")
        case "roll":
            let notation = slashOptionString(named: "notation", in: data) ?? "1d6"
            if let result = rollDice(notation) {
                return embed(title: "Dice Roll", description: result)
            }
            return embed(title: "Dice Roll", description: "Invalid roll notation. Try `2d6`.", color: 15_790_767)
        case "8ball":
            let responses = ["Yes.", "No.", "It is certain.", "Ask again later.", "Very doubtful."]
            return embed(title: "Magic 8-Ball", description: "🎱 \(responses.randomElement() ?? "Ask again later.")")
        case "poll":
            let question = slashOptionString(named: "question", in: data) ?? "New poll"
            return embed(title: "Poll", description: "📊 \(question)")
        case "userinfo":
            return embed(title: "User Info", description: "👤 \(context.username)")
        case "cluster":
            let action = slashOptionString(named: "action", in: data) ?? "status"
            let ok = await clusterCommand(action: action, channelId: context.channelId)
            return statusEmbed(title: "Cluster", ok: ok)
        case "weekly":
            return embed(title: "Weekly Summary", description: weeklyPlugin?.snapshotSummary() ?? "No data yet.")
        case "bugreport":
            return embed(title: "Bug Report", description: bugReportText(for: context.rawLikeMessage))
        case "logabug":
            let errorText = slashOptionString(named: "error", in: data)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !errorText.isEmpty else {
                return embed(title: "Log a Bug", description: "Usage: `/logabug error:<what happened>`", color: 15_790_767)
            }
            let result = await handleLogABugSlash(
                raw: context.rawLikeMessage,
                username: context.username,
                channelId: context.channelId,
                errorText: errorText
            )
            return embed(
                title: "Log a Bug",
                description: result.message,
                color: result.ok ? 3_062_954 : 15_790_767
            )
        case "featurerequest":
            let featureText = slashOptionString(named: "feature", in: data)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reasonText = slashOptionString(named: "reason", in: data)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !featureText.isEmpty else {
                return embed(title: "Feature Request", description: "Usage: `/featurerequest feature:<feature> [reason:<why>]`", color: 15_790_767)
            }
            let result = await handleFeatureRequestSlash(
                raw: context.rawLikeMessage,
                username: context.username,
                channelId: context.channelId,
                featureText: featureText,
                reasonText: reasonText
            )
            return embed(
                title: "Feature Request",
                description: result.message,
                color: result.ok ? 3_062_954 : 15_790_767
            )
        case "debug":
            guard await canRunDebugCommand(raw: context.rawLikeMessage) else {
                return embed(title: "Debug", description: "⛔ Restricted to server owners or admins.", color: 15_790_767)
            }
            return (content: nil, embeds: [debugSummaryEmbed()])
        case "setchannel":
            if await setNotificationChannel(for: context.rawLikeMessage, currentChannelId: context.channelId) {
                return embed(title: "Notifications", description: "✅ Notification channel set.")
            }
            return embed(title: "Notifications", description: "❌ Failed setting notification channel.", color: 15_790_767)
        case "ignorechannel":
            let action = slashOptionString(named: "action", in: data) ?? "list"
            if action == "list" {
                let ok = await updateIgnoredChannels(tokens: ["ignorechannel", "list"], raw: context.rawLikeMessage, responseChannelId: context.channelId)
                return statusEmbed(title: "Ignored Channels", ok: ok)
            }
            let channelID = slashOptionChannelID(named: "channel", in: data) ?? ""
            if channelID.isEmpty {
                return embed(title: "Ignored Channels", description: "Provide a channel for add/remove.", color: 15_790_767)
            }
            let token = action == "remove" ? "remove" : "add"
            let ok = await updateIgnoredChannels(tokens: ["ignorechannel", token, channelID], raw: context.rawLikeMessage, responseChannelId: context.channelId)
            return statusEmbed(title: "Ignored Channels", ok: ok)
        case "notifystatus":
            let ok = await notifyStatus(raw: context.rawLikeMessage, responseChannelId: context.channelId)
            return statusEmbed(title: "Notification Status", ok: ok)
        case "image":
            let prompt = slashOptionString(named: "prompt", in: data) ?? ""
            let userId = authorId(from: context.rawLikeMessage) ?? "unknown-user"
            let ok = await generateImageCommand(prompt: prompt, userId: userId, username: context.username, channelId: context.channelId)
            return statusEmbed(title: "Image Generation", ok: ok)
        case "wiki":
            let query = slashOptionString(named: "query", in: data) ?? ""
            guard settings.wikiBot.isEnabled else {
                return embed(title: "WikiBridge", description: "WikiBridge is disabled.", color: 15_790_767)
            }
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return embed(title: "WikiBridge", description: "Usage: `/wiki query:<text>`", color: 15_790_767)
            }
            let resolved = resolveWikiCommand(named: "wiki") ?? {
                for source in orderedEnabledWikiSources() {
                    if let first = source.commands.first(where: \.enabled) {
                        return ResolvedWikiCommand(source: source, command: first)
                    }
                }
                return nil
            }()
            guard let resolved else {
                return embed(title: "WikiBridge", description: "No enabled wiki source/command found.", color: 15_790_767)
            }
            let ok = await performWikiLookup(
                command: resolved.command,
                source: resolved.source,
                query: query,
                channelId: context.channelId
            )
            return statusEmbed(title: "WikiBridge Lookup", ok: ok)
        case "compare":
            let left = slashOptionString(named: "weapon_a", in: data)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let right = slashOptionString(named: "weapon_b", in: data)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !left.isEmpty, !right.isEmpty else {
                return embed(title: "Weapon Compare", description: "Usage: `/compare weapon_a:<weapon> weapon_b:<weapon>`", color: 15_790_767)
            }

            guard let leftResult = await service.lookupFinalsWiki(query: left),
                  let leftStats = leftResult.weaponStats else {
                return embed(title: "Weapon Compare", description: "Couldn’t find weapon stats for `\(left)`.", color: 15_790_767)
            }
            guard let rightResult = await service.lookupFinalsWiki(query: right),
                  let rightStats = rightResult.weaponStats else {
                return embed(title: "Weapon Compare", description: "Couldn’t find weapon stats for `\(right)`.", color: 15_790_767)
            }

            func value(_ stat: String?) -> String {
                let trimmed = stat?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? "N/A" : trimmed
            }

            let fields: [[String: Any]] = [
                [
                    "name": leftResult.title,
                    "value": """
                    Type: \(value(leftStats.type))
                    Body: \(value(leftStats.bodyDamage))
                    Head: \(value(leftStats.headshotDamage))
                    RPM: \(value(leftStats.fireRate))
                    Magazine: \(value(leftStats.magazineSize))
                    Reload: \(value(leftStats.shortReload)) / \(value(leftStats.longReload))
                    """,
                    "inline": true
                ],
                [
                    "name": rightResult.title,
                    "value": """
                    Type: \(value(rightStats.type))
                    Body: \(value(rightStats.bodyDamage))
                    Head: \(value(rightStats.headshotDamage))
                    RPM: \(value(rightStats.fireRate))
                    Magazine: \(value(rightStats.magazineSize))
                    Reload: \(value(rightStats.shortReload)) / \(value(rightStats.longReload))
                    """,
                    "inline": true
                ]
            ]
            return (
                content: nil,
                embeds: [[
                    "title": "THE FINALS Weapon Compare",
                    "description": "\(leftResult.title) vs \(rightResult.title)",
                    "color": 5_793_266,
                    "fields": fields
                ]]
            )
        case "meta":
            if let result = await service.fetchFinalsMetaFromSkycoach() {
                return embed(title: "THE FINALS Meta", description: result)
            }
            return embed(
                title: "THE FINALS Meta",
                description: "Couldn't fetch meta data right now.\nSource: https://skycoach.gg/blog/the-finals/articles/the-finals-best-builds",
                color: 15_790_767
            )
        default:
            return embed(title: "Slash Command", description: "Unknown slash command.", color: 15_790_767)
        }
    }

    func handleVoiceStateUpdate(_ raw: DiscordJSON?) async {
        guard case let .object(map)? = raw,
              case let .string(userId)? = map["user_id"],
              case let .string(guildId)? = map["guild_id"]
        else { return }

        let allowPrimarySideEffects = shouldProcessPrimaryGatewayActions

        let key = "\(guildId)-\(userId)"
        let now = Date()
        let previous = activeVoice.first(where: { $0.userId == userId && $0.guildId == guildId })
        if let avatarHash = avatarHashFromVoicePayload(map), !avatarHash.isEmpty {
            userAvatarHashById[userId] = avatarHash
        }
        if let guildAvatarHash = guildAvatarHashFromVoicePayload(map), !guildAvatarHash.isEmpty {
            guildAvatarHashByMemberKey[key] = guildAvatarHash
        }
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

                    if allowPrimarySideEffects,
                       (shouldNotifyVoiceEvent(guildId: guildId, channelId: previous.channelId) || shouldNotifyVoiceEvent(guildId: guildId, channelId: newChannel)) {
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

                if allowPrimarySideEffects,
                   shouldNotifyVoiceEvent(guildId: guildId, channelId: newChannel) {
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
                if allowPrimarySideEffects {
                    await eventBus.publish(VoiceJoined(guildId: guildId, userId: userId, username: displayName, channelId: newChannel))
                }
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
            let elapsedSec = Int(now.timeIntervalSince(joinTimes[key] ?? previous.joinedAt))
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
