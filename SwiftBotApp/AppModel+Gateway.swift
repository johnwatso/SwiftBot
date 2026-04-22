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
            let message = Message(
                id: record.id,
                channelID: record.scope.id,
                userID: record.userID,
                username: "",
                content: record.content,
                timestamp: record.timestamp,
                role: record.role
            )
            await conversationStore.appendIfNotExists(message)
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
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                if Task.isCancelled { break }
                guard let self = self else { return }
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

                var serverName: String?
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
                var serverName: String?
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
        switch event.interactionType {
        case 2:
            let slashName = (event.commandName ?? "").lowercased()
            if slashName == "music" {
                await handleInteractiveMusicSlash(event: event, context: context)
                return
            }
            if slashName == "playlist" {
                await handlePlaylistImportSlash(event: event, context: context)
                return
            }

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
                    command: slashName,
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
            let slashCommandForLog = formatSlashCommandForLog(name: event.commandName ?? "unknown", data: event.data)
            let slashOk = response.embeds != nil || (response.content?.isEmpty == false)
            let slashExecutionDetails = await commandExecutionDetails(for: slashName)
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
            guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "editOriginalInteractionResponse", log: { logs.append($0) }) else { return }
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
        case 3:
            let customID = slashCustomID(in: event.data)
            if customID.hasPrefix("music:") {
                await handleMusicComponentInteraction(event: event, context: context)
                return
            }
            if customID.hasPrefix("playlist:") {
                await handlePlaylistComponentInteraction(event: event, context: context)
                return
            }
        default:
            return
        }
    }

    private func handleInteractiveMusicSlash(event: GatewayInteractionCreateEvent, context: SlashContext) async {
        let usageText = "Usage: `/music query:<text>` or `/music title:<title> artist:<artist>`"
        guard settings.commandsEnabled, settings.slashCommandsEnabled else {
            do {
                try await service.respondToInteraction(
                    interactionID: event.interactionID,
                    interactionToken: event.interactionToken,
                    payload: [
                        "type": 4,
                        "data": [
                            "flags": 64,
                            "content": "Slash commands are disabled. \(usageText)"
                        ]
                    ]
                )
            } catch {
                logs.append("❌ Failed /music disabled response: \(error.localizedDescription)")
            }
            return
        }

        let userID = authorId(from: context.rawLikeMessage) ?? "unknown-user"
        let helpRequested = slashOptionBool(named: "help", in: event.data) ?? false
        let query = slashOptionString(named: "query", in: event.data)
        let title = slashOptionString(named: "title", in: event.data)
        let artist = slashOptionString(named: "artist", in: event.data)

        let effectiveQuery = [query, title, artist]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let normalizedQuery = effectiveQuery.lowercased()
        if helpRequested || ["help", "-h", "--help"].contains(normalizedQuery) {
            do {
                try await service.respondToInteraction(
                    interactionID: event.interactionID,
                    interactionToken: event.interactionToken,
                    payload: [
                        "type": 4,
                        "data": [
                            "flags": 64,
                            "content": HelpRenderer.detailedMusicGuide(prefix: effectivePrefix())
                        ]
                    ]
                )
            } catch {
                logs.append("❌ Failed /music help response: \(error.localizedDescription)")
            }
            return
        }

        guard !effectiveQuery.isEmpty else {
            do {
                try await service.respondToInteraction(
                    interactionID: event.interactionID,
                    interactionToken: event.interactionToken,
                    payload: [
                        "type": 4,
                        "data": [
                            "flags": 64,
                            "content": usageText
                        ]
                    ]
                )
            } catch {
                logs.append("❌ Failed /music usage response: \(error.localizedDescription)")
            }
            return
        }

        do {
            try await service.respondToInteraction(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                payload: [
                    "type": 5,
                    "data": ["flags": 64]
                ]
            )
        } catch {
            logs.append("❌ Failed ACK for /music: \(error.localizedDescription)")
            return
        }

        let results = await musicLookupService.searchTracks(query: effectiveQuery, limit: 5)
        stats.commandsRun += 1
        let commandName = event.commandName ?? "music"
        let slashCommandForLog = formatSlashCommandForLog(name: commandName, data: event.data)
        let slashExecutionDetails = await commandExecutionDetails(for: "music")
        commandLog.insert(CommandLogEntry(
            time: Date(),
            user: context.username,
            server: commandServerName(from: context.rawLikeMessage),
            command: slashCommandForLog,
            channel: context.channelId,
            executionRoute: slashExecutionDetails.route,
            executionNode: slashExecutionDetails.node,
            ok: !results.isEmpty
        ), at: 0)

        guard let applicationID = botUserId, !applicationID.isEmpty else { return }
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "editOriginalInteractionResponse", log: { logs.append($0) }) else { return }

        do {
            if results.isEmpty {
                try await service.editOriginalInteractionResponse(
                    applicationID: applicationID,
                    interactionToken: event.interactionToken,
                    payload: [
                        "content": "🎵 No matches for `\(effectiveQuery)`.\nTry refining title and artist.",
                        "embeds": [],
                        "components": []
                    ]
                )
                return
            }

            pruneExpiredMusicSelections()
            let sessionID = UUID().uuidString
            musicInteractionSessionsByID[sessionID] = MusicInteractionSession(
                id: sessionID,
                query: effectiveQuery,
                userID: userID,
                channelID: context.channelId,
                createdAt: Date(),
                results: results
            )

            let components = musicPickerComponents(sessionID: sessionID, results: results)
            let content = "🎵 Matches for `\(effectiveQuery)`\nChoose a track below. Only you can see this."
            try await service.editOriginalInteractionResponse(
                applicationID: applicationID,
                interactionToken: event.interactionToken,
                payload: [
                    "content": String(content.prefix(1900)),
                    "embeds": [musicSearchSummaryEmbed(query: effectiveQuery, results: results)],
                    "components": components
                ]
            )
        } catch {
            logs.append("❌ Failed interactive /music response: \(error.localizedDescription)")
        }
    }

    private func handleMusicComponentInteraction(event: GatewayInteractionCreateEvent, context: SlashContext) async {
        let customID = slashCustomID(in: event.data)
        guard customID.hasPrefix("music:") else { return }

        let userID = authorId(from: context.rawLikeMessage) ?? "unknown-user"
        pruneExpiredMusicSelections()

        if customID.hasPrefix("music:pick:") {
            let parts = customID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { return }
            let sessionID = parts[2]
            guard let session = musicInteractionSessionsByID[sessionID], session.userID == userID else {
                await respondToMusicComponentError(event: event, message: "This picker is no longer valid for you.")
                return
            }

            guard let selectedValue = slashComponentValues(in: event.data).first,
                  let selectedIndex = Int(selectedValue),
                  session.results.indices.contains(selectedIndex) else {
                await respondToMusicComponentError(event: event, message: "Invalid selection.")
                return
            }

            let track = session.results[selectedIndex]
            let trackEmbed = interactiveMusicTrackEmbed(for: track)
            let components = musicPostComponents(
                sessionID: sessionID,
                selectedIndex: selectedIndex,
                results: session.results
            )
            await updateMusicComponent(
                event: event,
                content: "Preview selected. Click **Post To Channel** to publish it.",
                embed: trackEmbed,
                components: components
            )
            return
        }

        if customID.hasPrefix("music:post:") {
            let parts = customID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return }
            let sessionID = parts[2]
            guard let selectedIndex = Int(parts[3]),
                  let session = musicInteractionSessionsByID[sessionID],
                  session.userID == userID,
                  session.results.indices.contains(selectedIndex) else {
                await respondToMusicComponentError(event: event, message: "This post action is no longer valid.")
                return
            }

            let track = session.results[selectedIndex]
            let payload: [String: Any] = [
                "content": "🎧 \(track.title) — \(track.artist)",
                "embeds": [interactiveMusicTrackEmbed(for: track)]
            ]
            let sent = await sendPayload(channelId: session.channelID, payload: payload, action: "sendMessage")
            let statusPrefix = sent ? "✅ Posted to channel." : "❌ Failed to post to channel."
            await updateMusicComponent(
                event: event,
                content: statusPrefix,
                embed: interactiveMusicTrackEmbed(for: track),
                components: musicPostComponents(sessionID: sessionID, selectedIndex: selectedIndex, results: session.results)
            )
        }
    }

    private func respondToMusicComponentError(event: GatewayInteractionCreateEvent, message: String) async {
        do {
            try await service.respondToInteraction(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                payload: [
                    "type": 4,
                    "data": [
                        "flags": 64,
                        "content": message
                    ]
                ]
            )
        } catch {
            logs.append("❌ Failed music component error response: \(error.localizedDescription)")
        }
    }

    private func updateMusicComponent(
        event: GatewayInteractionCreateEvent,
        content: String,
        embed: [String: Any]? = nil,
        components: [[String: Any]]
    ) async {
        do {
            var data: [String: Any] = [
                "content": String(content.prefix(1900)),
                "components": components
            ]
            if let embed {
                data["embeds"] = [embed]
            } else {
                data["embeds"] = []
            }
            try await service.respondToInteraction(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                payload: [
                    "type": 7,
                    "data": data
                ]
            )
        } catch {
            logs.append("❌ Failed music component update: \(error.localizedDescription)")
        }
    }

    private func musicPickerComponents(sessionID: String, results: [MusicSearchResult]) -> [[String: Any]] {
        let options: [[String: Any]] = results.enumerated().map { index, track in
            [
                "label": String("\(index + 1). \(track.title)".prefix(100)),
                "description": String(track.artist.prefix(100)),
                "value": "\(index)"
            ]
        }

        return [[
            "type": 1,
            "components": [[
                "type": 3,
                "custom_id": "music:pick:\(sessionID)",
                "placeholder": "Pick a song match",
                "min_values": 1,
                "max_values": 1,
                "options": options
            ]]
        ]]
    }

    private func musicPostComponents(sessionID: String, selectedIndex: Int, results: [MusicSearchResult]) -> [[String: Any]] {
        let picker = musicPickerComponents(sessionID: sessionID, results: results)
        let postButtonRow: [String: Any] = [
            "type": 1,
            "components": [[
                "type": 2,
                "style": 1,
                "custom_id": "music:post:\(sessionID):\(selectedIndex)",
                "label": "Post To Channel"
            ]]
        ]
        return [postButtonRow] + picker
    }

    private func interactiveMusicTrackEmbed(for track: MusicSearchResult) -> [String: Any] {
        let combinedSearch = "\(track.title) \(track.artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        let appleLink = track.appleMusicURL?.absoluteString ?? buildITunesSearchURL(query: combinedSearch)
        let spotifyLink = track.spotifyURL?.absoluteString ?? buildSpotifySearchURL(query: combinedSearch)
        let youtubeMusicLink = track.youtubeMusicURL?.absoluteString ?? buildYouTubeMusicSearchURL(query: combinedSearch)
        let youtubeLink = track.youtubeURL?.absoluteString ?? buildYouTubeSearchURL(query: combinedSearch)

        var embed: [String: Any] = [
            "title": "\(track.title) — \(track.artist)",
            "description": """
            [Apple Music](\(appleLink))
            [Spotify](\(spotifyLink))
            [YouTube Music](\(youtubeMusicLink))
            [YouTube](\(youtubeLink))
            """,
            "color": 5_793_266
        ]
        if let album = track.album, !album.isEmpty {
            embed["footer"] = ["text": album]
        }
        if let artworkURL = track.artworkURL?.absoluteString, !artworkURL.isEmpty {
            embed["thumbnail"] = ["url": artworkURL]
        }
        return embed
    }

    private func musicSearchSummaryEmbed(query: String, results: [MusicSearchResult]) -> [String: Any] {
        let lines = results.enumerated().map { index, track in
            "\(index + 1). **\(track.title)** — \(track.artist)"
        }.joined(separator: "\n")
        return [
            "title": "Music Search",
            "description": "Query: `\(query)`\n\n\(lines)",
            "color": 5_793_266
        ]
    }

    private func handlePlaylistImportSlash(event: GatewayInteractionCreateEvent, context: SlashContext) async {
        guard settings.commandsEnabled, settings.slashCommandsEnabled else {
            await respondEphemeralText(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                text: "Slash commands are disabled in settings."
            )
            return
        }

        let urlText = slashOptionString(named: "url", in: event.data)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let threadName = slashOptionString(named: "name", in: event.data)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(1, min(100, slashOptionInt(named: "limit", in: event.data) ?? 25))

        guard let playlistURL = URL(string: urlText), !urlText.isEmpty else {
            await respondEphemeralText(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                text: "Usage: `/playlist url:<playlist-url> [name:<thread-name>] [limit:<n>]`"
            )
            return
        }

        let host = playlistURL.host?.lowercased() ?? ""
        let path = playlistURL.path.lowercased()
        if host.contains("open.spotify.com"), !path.contains("/playlist/") {
            await respondEphemeralText(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                text: "That looks like a Spotify search/browse URL, not a playlist URL.\nUse a link like `https://open.spotify.com/playlist/<id>`."
            )
            return
        }

        do {
            try await service.respondToInteraction(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                payload: [
                    "type": 5,
                    "data": ["flags": 64]
                ]
            )
        } catch {
            logs.append("❌ Failed ACK for /playlist: \(error.localizedDescription)")
            return
        }

        let importResult: PlaylistImportResult
        if settings.clusterMode == .leader, settings.clusterWorkerOffloadEnabled {
            if let remoteResult = await cluster.importPlaylist(from: playlistURL, limit: limit) {
                importResult = remoteResult
            } else {
                importResult = await playlistImportService.importPlaylist(from: playlistURL, limit: limit)
            }
        } else {
            importResult = await playlistImportService.importPlaylist(from: playlistURL, limit: limit)
        }
        let tracks = importResult.tracks
        guard let applicationID = botUserId, !applicationID.isEmpty else { return }

        if tracks.isEmpty {
            do {
                try await service.editOriginalInteractionResponse(
                    applicationID: applicationID,
                    interactionToken: event.interactionToken,
                    payload: [
                        "content": "❌ I couldn't parse track entries from that playlist URL.\nSupported best-effort sources: Spotify, Apple Music, YouTube playlists.",
                        "embeds": [],
                        "components": []
                    ]
                )
            } catch {
                logs.append("❌ Failed /playlist empty response: \(error.localizedDescription)")
            }
            return
        }

        let sourceHost = playlistURL.host ?? "playlist"
        let anchorMessage = """
        🎶 Playlist import requested by @\(context.username)
        Source: <\(playlistURL.absoluteString)>
        Tracks detected: \(tracks.count)
        """

        guard let anchorMessageID = await sendMessageReturningID(channelId: context.channelId, content: anchorMessage) else {
            do {
                try await service.editOriginalInteractionResponse(
                    applicationID: applicationID,
                    interactionToken: event.interactionToken,
                    payload: [
                        "content": "❌ Failed to post the playlist anchor message in this channel."
                    ]
                )
            } catch {
                logs.append("❌ Failed /playlist anchor error response: \(error.localizedDescription)")
            }
            return
        }

        let desiredThreadName = {
            let parsedTitle = importResult.playlistTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallback = parsedTitle.isEmpty ? "Playlist • \(sourceHost)" : "Playlist • \(parsedTitle)"
            let proposed = (threadName?.isEmpty == false ? threadName! : fallback)
            return String(proposed.prefix(90))
        }()

        guard let threadID = await createThreadFromMessageReturningID(
            channelId: context.channelId,
            messageId: anchorMessageID,
            name: desiredThreadName
        ) else {
            do {
                try await service.editOriginalInteractionResponse(
                    applicationID: applicationID,
                    interactionToken: event.interactionToken,
                    payload: [
                        "content": "❌ Failed creating playlist thread. Check bot permissions for thread creation."
                    ]
                )
            } catch {
                logs.append("❌ Failed /playlist thread error response: \(error.localizedDescription)")
            }
            return
        }

        var posted = 0
        let isYouTubeSource = sourceHost.lowercased().contains("youtube")
        for seed in tracks {
            let query = [seed.title, seed.artist].compactMap { $0 }.joined(separator: " ")
            var candidates = await musicLookupService.searchTracks(query: query, limit: 5)
            if candidates.isEmpty {
                candidates = [
                    MusicSearchResult(
                        title: seed.title,
                        artist: seed.artist ?? "Unknown Artist",
                        album: nil,
                        artworkURL: nil,
                        appleMusicURL: nil,
                        spotifyURL: nil,
                        youtubeMusicURL: nil,
                        youtubeURL: nil
                    )
                ]
            }
            candidates = rankPlaylistCandidates(candidates, sourceTitle: seed.title, sourceArtist: seed.artist)

            let lowConfidenceMatch = {
                guard let best = candidates.first else { return true }
                let score = playlistMatchScore(
                    sourceTitle: seed.title,
                    sourceArtist: seed.artist,
                    candidate: best
                )
                return score < 0.55
            }()

            if lowConfidenceMatch {
                let sourceArtist = seed.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
                let sourceFallback = MusicSearchResult(
                    title: seed.title,
                    artist: (sourceArtist?.isEmpty == false ? sourceArtist! : "Unknown Artist"),
                    album: nil,
                    artworkURL: nil,
                    appleMusicURL: nil,
                    spotifyURL: nil,
                    youtubeMusicURL: nil,
                    youtubeURL: nil
                )
                let duplicateExists = candidates.contains(where: {
                    normalizeForMusicMatch($0.title) == normalizeForMusicMatch(sourceFallback.title) &&
                    normalizeForMusicMatch($0.artist) == normalizeForMusicMatch(sourceFallback.artist)
                })
                if !duplicateExists {
                    candidates.insert(sourceFallback, at: 0)
                }
            }

            let key = UUID().uuidString
            let tempState = PlaylistTrackCardState(
                key: key,
                threadID: threadID,
                messageID: "",
                sourceTitle: seed.title,
                sourceArtist: seed.artist,
                candidates: candidates,
                selectedIndex: 0,
                useSourceQueryForApple: false,
                useSourceQueryForSpotify: false,
                useSourceQueryForYouTubeMusic: isYouTubeSource && lowConfidenceMatch
            )
            let payload = playlistTrackMessagePayload(state: tempState)
            if let messageID = await sendPayloadReturningMessageID(
                channelId: threadID,
                payload: payload,
                action: "sendMessage"
            ) {
                var finalized = tempState
                finalized.messageID = messageID
                playlistTrackCardsByKey[key] = finalized
                posted += 1
            }
        }

        do {
            try await service.editOriginalInteractionResponse(
                applicationID: applicationID,
                interactionToken: event.interactionToken,
                payload: [
                    "content": "✅ Imported \(posted)/\(tracks.count) tracks into thread <#\(threadID)>."
                ]
            )
        } catch {
            logs.append("❌ Failed /playlist success response: \(error.localizedDescription)")
        }
    }

    private func handlePlaylistComponentInteraction(event: GatewayInteractionCreateEvent, context: SlashContext) async {
        let customID = slashCustomID(in: event.data)
        let parts = customID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return }
        let action = parts[1]

        func ackDeferredUpdate() async {
            do {
                try await service.respondToInteraction(
                    interactionID: event.interactionID,
                    interactionToken: event.interactionToken,
                    payload: ["type": 6]
                )
            } catch {
                logs.append("❌ Failed playlist component ACK: \(error.localizedDescription)")
            }
        }

        if action == "next", parts.count >= 3 {
            let key = parts[2]
            guard var state = playlistTrackCardsByKey[key], !state.candidates.isEmpty else { return }
            state.selectedIndex = (state.selectedIndex + 1) % state.candidates.count
            playlistTrackCardsByKey[key] = state
            await ackDeferredUpdate()
            _ = await editMessagePayload(
                channelId: state.threadID,
                messageId: state.messageID,
                payload: playlistTrackMessagePayload(state: state)
            )
            return
        }

        if action == "toggle", parts.count >= 4 {
            let service = parts[2]
            let key = parts[3]
            guard var state = playlistTrackCardsByKey[key] else { return }
            switch service {
            case "apple":
                state.useSourceQueryForApple.toggle()
            case "spotify":
                state.useSourceQueryForSpotify.toggle()
            case "ytm":
                state.useSourceQueryForYouTubeMusic.toggle()
            default:
                return
            }
            playlistTrackCardsByKey[key] = state
            await ackDeferredUpdate()
            _ = await editMessagePayload(
                channelId: state.threadID,
                messageId: state.messageID,
                payload: playlistTrackMessagePayload(state: state)
            )
            return
        }

        _ = context
    }

    private func playlistTrackMessagePayload(state: PlaylistTrackCardState) -> [String: Any] {
        let selected = state.candidates[min(max(0, state.selectedIndex), max(0, state.candidates.count - 1))]
        let sourceQuery = [state.sourceTitle, state.sourceArtist].compactMap { $0 }.joined(separator: " ")
        let selectedQuery = "\(selected.title) \(selected.artist)"

        let apple = state.useSourceQueryForApple
            ? buildITunesSearchURL(query: sourceQuery)
            : (selected.appleMusicURL?.absoluteString ?? buildITunesSearchURL(query: selectedQuery))
        let spotify = state.useSourceQueryForSpotify
            ? buildSpotifySearchURL(query: sourceQuery)
            : (selected.spotifyURL?.absoluteString ?? buildSpotifySearchURL(query: selectedQuery))
        let ytm = state.useSourceQueryForYouTubeMusic
            ? buildYouTubeMusicSearchURL(query: sourceQuery)
            : (selected.youtubeMusicURL?.absoluteString ?? buildYouTubeMusicSearchURL(query: selectedQuery))
        let yt = selected.youtubeURL?.absoluteString ?? buildYouTubeSearchURL(query: selectedQuery)

        var embed: [String: Any] = [
            "title": "\(selected.title) — \(selected.artist)",
            "description": """
            [Apple Music](\(apple))
            [Spotify](\(spotify))
            [YouTube Music](\(ytm))
            [YouTube](\(yt))
            """,
            "color": 5_793_266,
            "footer": ["text": "Match \(state.selectedIndex + 1)/\(max(1, state.candidates.count)) • Source: \(sourceQuery)"]
        ]
        if let art = selected.artworkURL?.absoluteString, !art.isEmpty {
            embed["thumbnail"] = ["url": art]
        }

        let components: [[String: Any]] = [
            [
                "type": 1,
                "components": [[
                    "type": 2,
                    "style": 1,
                    "custom_id": "playlist:next:\(state.key)",
                    "label": "Next Match"
                ]]
            ],
            [
                "type": 1,
                "components": [
                    [
                        "type": 2,
                        "style": state.useSourceQueryForApple ? 3 : 2,
                        "custom_id": "playlist:toggle:apple:\(state.key)",
                        "label": state.useSourceQueryForApple ? "Apple: Source Query" : "Apple: Matched"
                    ],
                    [
                        "type": 2,
                        "style": state.useSourceQueryForSpotify ? 3 : 2,
                        "custom_id": "playlist:toggle:spotify:\(state.key)",
                        "label": state.useSourceQueryForSpotify ? "Spotify: Source Query" : "Spotify: Matched"
                    ],
                    [
                        "type": 2,
                        "style": state.useSourceQueryForYouTubeMusic ? 3 : 2,
                        "custom_id": "playlist:toggle:ytm:\(state.key)",
                        "label": state.useSourceQueryForYouTubeMusic ? "YTM: Source Query" : "YTM: Matched"
                    ]
                ]
            ]
        ]
        return [
            "content": "🎵 Playlist Track",
            "embeds": [embed],
            "components": components
        ]
    }

    private func rankPlaylistCandidates(
        _ candidates: [MusicSearchResult],
        sourceTitle: String,
        sourceArtist: String?
    ) -> [MusicSearchResult] {
        candidates.sorted { lhs, rhs in
            let left = playlistMatchScore(sourceTitle: sourceTitle, sourceArtist: sourceArtist, candidate: lhs)
            let right = playlistMatchScore(sourceTitle: sourceTitle, sourceArtist: sourceArtist, candidate: rhs)
            if left == right {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return left > right
        }
    }

    private func playlistMatchScore(
        sourceTitle: String,
        sourceArtist: String?,
        candidate: MusicSearchResult
    ) -> Double {
        let sourceTitleNorm = normalizeForMusicMatch(sourceTitle)
        let candidateTitleNorm = normalizeForMusicMatch(candidate.title)
        let sourceArtistNorm = normalizeForMusicMatch(sourceArtist ?? "")
        let candidateArtistNorm = normalizeForMusicMatch(candidate.artist)

        let titleSimilarity = tokenOverlapScore(sourceTitleNorm, candidateTitleNorm)
        let artistSimilarity = sourceArtistNorm.isEmpty ? 0.0 : tokenOverlapScore(sourceArtistNorm, candidateArtistNorm)
        let exactTitleBoost = sourceTitleNorm == candidateTitleNorm ? 0.35 : 0.0
        let containsBoost = (sourceTitleNorm.contains(candidateTitleNorm) || candidateTitleNorm.contains(sourceTitleNorm)) ? 0.15 : 0.0

        return (titleSimilarity * 0.75) + (artistSimilarity * 0.25) + exactTitleBoost + containsBoost
    }

    private func normalizeForMusicMatch(_ text: String) -> String {
        let lowered = text.lowercased()
        let cleaned = lowered.replacingOccurrences(
            of: #"[^a-z0-9\s]"#,
            with: " ",
            options: .regularExpression
        )
        return cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenOverlapScore(_ a: String, _ b: String) -> Double {
        let left = Set(a.split(separator: " ").map(String.init).filter { !$0.isEmpty })
        let right = Set(b.split(separator: " ").map(String.init).filter { !$0.isEmpty })
        guard !left.isEmpty, !right.isEmpty else { return 0.0 }

        let intersection = left.intersection(right).count
        let denom = max(left.count, right.count)
        guard denom > 0 else { return 0.0 }
        return Double(intersection) / Double(denom)
    }

    private func respondEphemeralText(interactionID: String, interactionToken: String, text: String) async {
        do {
            try await service.respondToInteraction(
                interactionID: interactionID,
                interactionToken: interactionToken,
                payload: [
                    "type": 4,
                    "data": [
                        "flags": 64,
                        "content": text
                    ]
                ]
            )
        } catch {
            logs.append("❌ Failed ephemeral response: \(error.localizedDescription)")
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

    private func slashOptionString(named name: String, in data: [String: DiscordJSON]) -> String? {
        guard case let .array(options)? = data["options"] else { return nil }
        for option in options {
            guard case let .object(map) = option,
                  case let .string(optionName)? = map["name"],
                  optionName == name else { continue }
            if case let .string(value)? = map["value"] {
                return value
            }
        }
        return nil
    }

    private func slashOptionInt(named name: String, in data: [String: DiscordJSON]) -> Int? {
        guard case let .array(options)? = data["options"] else { return nil }
        for option in options {
            guard case let .object(map) = option,
                  case let .string(optionName)? = map["name"],
                  optionName == name else { continue }
            if case let .int(value)? = map["value"] {
                return value
            }
            if case let .string(value)? = map["value"], let parsed = Int(value) {
                return parsed
            }
        }
        return nil
    }

    private func slashOptionBool(named name: String, in data: [String: DiscordJSON]) -> Bool? {
        guard case let .array(options)? = data["options"] else { return nil }
        for option in options {
            guard case let .object(map) = option,
                  case let .string(optionName)? = map["name"],
                  optionName == name else { continue }
            if case let .bool(value)? = map["value"] {
                return value
            }
            if case let .string(value)? = map["value"] {
                return ["true", "1", "yes", "y", "on"].contains(value.lowercased())
            }
        }
        return nil
    }

    private func slashCustomID(in data: [String: DiscordJSON]) -> String {
        if case let .string(value)? = data["custom_id"] {
            return value
        }
        return ""
    }

    private func slashComponentValues(in data: [String: DiscordJSON]) -> [String] {
        guard case let .array(values)? = data["values"] else { return [] }
        return values.compactMap { item in
            if case let .string(value) = item {
                return value
            }
            return nil
        }
    }

    func registerSlashCommandsIfNeeded() async {
        guard let appID = botUserId, !appID.isEmpty else { return }
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "registerSlashCommands", log: { logs.append($0) }) else { return }

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
                  lastSlashRegistrationAt == nil || now.timeIntervalSince(lastSlashRegistrationAt!) >= 300 {
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
            await voiceSessionStore.recordJoin(userId: userId, username: displayName, guildId: guildId, channelId: next.channelId, channelName: next.channelName, at: now)

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
            await voiceSessionStore.recordChannelSwitch(userId: userId, username: displayName, guildId: guildId, newChannelId: next.channelId, newChannelName: next.channelName, at: now)

            if allowPrimarySideEffects,
               shouldNotifyVoiceEvent(guildId: guildId, channelId: previous.channelId) || shouldNotifyVoiceEvent(guildId: guildId, channelId: next.channelId) {
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
            await voiceSessionStore.recordLeave(userId: userId, guildId: guildId, at: now)

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
