import Foundation
import SwiftUI

extension AppModel {

    // MARK: - Discord Event Handlers

    /// Shared sender that knows how to serialize a WelcomeFlowService.PublicMessage
    /// (plain text OR an embed with optional thumbnail/author) into a Discord payload.
    private func sendWelcomeFlowMessage(
        channelId: String,
        message: WelcomeFlowService.PublicMessage,
        action: String
    ) async -> Bool {
        if let embed = message.embed {
            var embedDict: [String: Any] = [
                "title": embed.title,
                "description": embed.description,
                "color": embed.color,
                "footer": ["text": embed.footer]
            ]
            if let thumb = embed.thumbnailURL, !thumb.isEmpty {
                embedDict["thumbnail"] = ["url": thumb]
            }
            if let authorName = embed.authorName, !authorName.isEmpty {
                var author: [String: Any] = ["name": authorName]
                if let icon = embed.authorIconURL, !icon.isEmpty {
                    author["icon_url"] = icon
                }
                embedDict["author"] = author
            }
            var payload: [String: Any] = ["embeds": [embedDict]]
            if let content = message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                payload["content"] = content
            }
            return await sendPayload(channelId: channelId, payload: payload, action: action)
        }
        guard let content = message.content else { return false }
        return await send(channelId, content)
    }

    func handleMemberJoin(_ event: GatewayMemberJoinEvent) async {
        let hasRules = automationStore.rules.contains {
            $0.enabled && $0.trigger.kind == .memberJoined
        }
        guard settings.welcomeFlow.handlesMemberJoin || hasRules else { return }

        let result = await welcomeFlowService.handleMemberJoin(
            event,
            settings: settings.welcomeFlow,
            serverName: connectedServers[event.guildID] ?? "the server",
            sendPublicMessage: { [weak self] channelId, message in
                guard let self else { return false }
                return await self.sendWelcomeFlowMessage(
                    channelId: channelId,
                    message: message,
                    action: "sendWelcomeEmbed"
                )
            },
            sendDirectMessage: { [weak self] userId, content in
                guard let self else { return }
                try await self.service.sendDM(userId: userId, content: content)
            },
            grantRole: { [weak self] guildId, userId, roleId in
                guard let self else { return }
                let token = self.settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else {
                    throw NSError(
                        domain: "SwiftBot.WelcomeFlow",
                        code: 401,
                        userInfo: [NSLocalizedDescriptionKey: "Discord token is not available."]
                    )
                }
                try await self.service.addRole(guildId: guildId, userId: userId, roleId: roleId, token: token)
            },
            fetchInvites: { [weak self] guildId in
                guard let self else { return nil }
                let token = self.settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { return nil }
                do {
                    return try await self.service.fetchGuildInvites(guildId: guildId, token: token)
                } catch {
                    self.logs.append("Welcome Flow: invite lookup unavailable for \(guildId): \(error.localizedDescription)")
                    return nil
                }
            },
            log: { [weak self] message in
                self?.logs.append(message)
            }
        )

        guard !result.isDuplicate, !result.isBurstSuppressed else { return }

        // Rule-based execution: evaluate any enabled "Member Joined" trigger rules.
        let ruleEvent = VoiceRuleEvent(
            kind: .memberJoin,
            guildId: event.guildID,
            userId: event.userID,
            username: result.safeUsername,
            channelId: "",
            fromChannelId: nil,
            toChannelId: nil,
            durationSeconds: nil,
            messageContent: nil,
            messageId: nil,
            mediaFileName: nil,
            mediaRelativePath: nil,
            mediaSourceName: nil,
            mediaNodeName: nil,
            triggerMessageId: nil,
            triggerChannelId: nil,
            triggerGuildId: event.guildID,
            triggerUserId: event.userID,
            isDirectMessage: false,
            authorIsBot: nil,
            joinedAt: event.joinedAt
        )
        await fireAutomations(for: ruleEvent)

        // Log username only — no internal IDs or metadata.
        addEvent(ActivityEvent(
            timestamp: result.handledAt,
            kind: .info,
            message: "👋 \(result.safeUsername) joined \(result.serverName)"
        ))
        logs.append("Member join handled for \(result.safeUsername) in \(result.serverName)")
    }

    func handleMemberLeave(_ event: GatewayMemberLeaveEvent) async {
        let now = Date()
        let guildId = event.guildID
        let userId = event.userID

        welcomeFlowService.decrementMemberCount(guildID: guildId)

        // Goodbye message (best-effort, fires before automation rules so the post precedes any rule reactions).
        if settings.welcomeFlow.hasGoodbyeMessage {
            await welcomeFlowService.handleGoodbye(
                event,
                settings: settings.welcomeFlow,
                serverName: connectedServers[guildId] ?? "the server",
                sendPublicMessage: { [weak self] channelId, message in
                    guard let self else { return false }
                    return await self.sendWelcomeFlowMessage(
                        channelId: channelId,
                        message: message,
                        action: "sendGoodbyeEmbed"
                    )
                },
                log: { [weak self] message in
                    self?.logs.append(message)
                }
            )
        }

        let username = event.username

        let ruleEvent = VoiceRuleEvent(
            kind: .memberLeave,
            guildId: guildId,
            userId: userId,
            username: username,
            channelId: "",
            fromChannelId: nil,
            toChannelId: nil,
            durationSeconds: nil,
            messageContent: nil,
            messageId: nil,
            mediaFileName: nil,
            mediaRelativePath: nil,
            mediaSourceName: nil,
            mediaNodeName: nil,
            triggerMessageId: nil,
            triggerChannelId: nil,
            triggerGuildId: guildId,
            triggerUserId: userId,
            isDirectMessage: false,
            authorIsBot: nil,
            joinedAt: nil
        )

        await fireAutomations(for: ruleEvent)

        addEvent(ActivityEvent(timestamp: now, kind: .info, message: "🚪 \(username) left the server"))
        logs.append("Member leave handled for \(username)")
    }

    func handleGuildCreate(_ event: GatewayGuildCreateEvent) async {
        guildCreateEventCount += 1
        if let memberCount = event.memberCount {
            welcomeFlowService.seedMemberCount(guildID: event.guildID, count: memberCount)
        }
        if !settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let invites = try await service.fetchGuildInvites(guildId: event.guildID, token: settings.token)
                welcomeFlowService.seedInvites(guildID: event.guildID, invites: invites)
                welcomeFlowInvitesByServer[event.guildID] = invites.sortedForWelcomeFlowDisplay()
            } catch {
                let guildName = event.guildName ?? event.guildID
                logs.append("Welcome Flow: invite tracking unavailable for \(guildName): \(error.localizedDescription)")
            }
        }

        await discordCache.upsertGuild(id: event.guildID, name: event.guildName)
        await discordCache.setGuildVoiceChannels(guildID: event.guildID, channels: parseVoiceChannels(from: event.rawMap))
        await discordCache.setGuildTextChannels(guildID: event.guildID, channels: parseTextChannels(from: event.rawMap))
        await discordCache.setGuildRoles(guildID: event.guildID, roles: parseRoles(from: event.rawMap))
        await discordCache.mergeChannelTypes(parseChannelTypes(from: event.rawMap))
        await cacheGuildMembers(from: event.rawMap)
        await syncPublishedDiscordCacheFromService()
        await syncVoicePresenceFromGuildSnapshot(guildId: event.guildID, guildMap: event.rawMap)
        scheduleDiscordCacheSave()
        await registerSlashCommandsIfNeeded()
    }

    func handleChannelCreate(_ event: GatewayChannelCreateEvent) async {
        await discordCache.setChannelType(channelID: event.channelID, type: event.type)
        await discordCache.upsertChannel(
            guildID: event.guildID,
            channelID: event.channelID,
            name: event.name,
            type: event.type
        )
        await syncPublishedDiscordCacheFromService()
        scheduleDiscordCacheSave()
    }

    func handleGuildDelete(_ event: GatewayGuildDeleteEvent) async {
        await discordCache.removeGuild(id: event.guildID)
        await syncPublishedDiscordCacheFromService()
        await clearVoicePresence(guildID: event.guildID)
        scheduleDiscordCacheSave()
    }

    func syncVoicePresenceFromGuildSnapshot(guildId: String, guildMap: [String: DiscordJSON]) async {
        // Ensure voice session store is loaded before looking up persisted join times
        await voiceSessionStore.waitForLoad()
        
        guard case let .array(voiceStates)? = guildMap["voice_states"] else { return }

        let now = Date()
        var snapshot: [VoiceMemberPresence] = []
        for state in voiceStates {
            guard case let .object(stateMap) = state,
                  case let .string(userId)? = stateMap["user_id"],
                  case let .string(channelId)? = stateMap["channel_id"]
            else { continue }

            if case let .object(member)? = stateMap["member"],
               case let .object(user)? = member["user"],
               case let .string(avatarHash)? = user["avatar"],
               !avatarHash.isEmpty {
                cacheUserAvatar(avatarHash, for: userId)
                if case let .string(guildAvatarHash)? = member["avatar"], !guildAvatarHash.isEmpty {
                    cacheGuildAvatar(guildAvatarHash, for: "\(guildId)-\(userId)")
                }
            } else if case let .object(user)? = stateMap["user"],
                      case let .string(avatarHash)? = user["avatar"],
                      !avatarHash.isEmpty {
                cacheUserAvatar(avatarHash, for: userId)
            }

            let username = await voiceDisplayName(from: stateMap, userId: userId)
            let key = "\(guildId)-\(userId)"
            // Use persisted join time if available so durations survive restarts
            let joinedAt = await voiceSessionStore.persistedJoinDate(guildId: guildId, userId: userId) ?? now

            snapshot.append(
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

        activeVoice = await voicePresenceStore.syncGuildSnapshot(guildId, members: snapshot)
        await voiceSessionStore.reconcileOnStartup(currentVoiceMembers: snapshot, now: now)
    }

    func cacheGuildMembers(from guildMap: [String: DiscordJSON]) async {
        guard case let .array(members)? = guildMap["members"] else { return }

        for member in members {
            guard case let .object(memberMap) = member else { continue }
            if case let .string(nick)? = memberMap["nick"], !nick.isEmpty,
               case let .object(user)? = memberMap["user"],
               case let .string(userId)? = user["id"] {
                await discordCache.upsertUser(id: userId, preferredName: nick)
                if user["bot"] == .bool(true) {
                    await discordCache.markBot(id: userId)
                } else {
                    await discordCache.markGuildMember(id: userId)
                }
                continue
            }

            guard case let .object(user)? = memberMap["user"],
                  case let .string(userId)? = user["id"] else { continue }

            if case let .string(avatarHash)? = user["avatar"], !avatarHash.isEmpty {
                cacheUserAvatar(avatarHash, for: userId)
            }

            if case let .string(globalName)? = user["global_name"], !globalName.isEmpty {
                await discordCache.upsertUser(id: userId, preferredName: globalName)
            } else if case let .string(username)? = user["username"], !username.isEmpty {
                await discordCache.upsertUser(id: userId, preferredName: username)
            }

            if user["bot"] == .bool(true) {
                await discordCache.markBot(id: userId)
            } else {
                await discordCache.markGuildMember(id: userId)
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
        knownBotUserIds = snapshot.botUserIds
        knownGuildMemberIds = snapshot.guildMemberIds
        maybeStartFirstSweepScan()
    }

    @discardableResult
    func refreshWelcomeFlowInvites(guildID: String) async -> Bool {
        let trimmedGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuildID.isEmpty, !token.isEmpty else { return false }

        do {
            let invites = try await service.fetchGuildInvites(guildId: trimmedGuildID, token: token)
            welcomeFlowService.seedInvites(guildID: trimmedGuildID, invites: invites)
            welcomeFlowInvitesByServer[trimmedGuildID] = invites.sortedForWelcomeFlowDisplay()
            let guildName = connectedServers[trimmedGuildID] ?? trimmedGuildID
            logs.append("Welcome Flow: refreshed \(invites.count) invite\(invites.count == 1 ? "" : "s") for \(guildName).")
            return true
        } catch {
            let guildName = connectedServers[trimmedGuildID] ?? trimmedGuildID
            logs.append("Welcome Flow: invite refresh unavailable for \(guildName): \(error.localizedDescription)")
            return false
        }
    }

    /// Kick off a one-time retroactive Sweep suggestion scan the first time
    /// channels are available. Subsequent scans are user-initiated.
    private func maybeStartFirstSweepScan() {
        guard sweepService.lastSuggestionScanAt == nil else { return }
        guard !availableTextChannelsByServer.isEmpty else { return }

        var targets: [SweepService.SweepScanTarget] = []
        for (guildID, channels) in availableTextChannelsByServer {
            let guildName = connectedServers[guildID] ?? "Server"
            for channel in channels {
                targets.append(.init(guildID: guildID, guildName: guildName, channel: channel))
            }
        }
        guard !targets.isEmpty else { return }

        Task { [weak self] in
            // Small delay so the gateway/cache settles before we hit the REST API.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self?.sweepService.scanForSuggestions(targets: targets)
        }
    }

    func scheduleDiscordCacheSave() {
        discordCacheSaveTask?.cancel()
        discordCacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self = self else { return }
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

    // MARK: - Welcome Flow test send

    /// Posts a synthetic welcome message to the configured channel using the current settings.
    /// Returns whether the send succeeded. Used by the UI "Send Test" button.
    @discardableResult
    func sendWelcomeFlowTestMessage() async -> Bool {
        let testServer: String
        if !settings.welcomeFlow.publicChannelId.isEmpty,
           let guildId = availableTextChannelsByServer
               .first(where: { $0.value.contains(where: { $0.id == settings.welcomeFlow.publicChannelId }) })?
               .key {
            testServer = connectedServers[guildId] ?? "your server"
        } else {
            testServer = connectedServers.values.first ?? "your server"
        }
        let identityID = botUserId ?? "0"
        let identityName = botUsername.isEmpty ? "SwiftBot" : botUsername
        return await welcomeFlowService.sendTestWelcome(
            settings: settings.welcomeFlow,
            serverName: testServer,
            testUserID: identityID,
            testUsername: identityName,
            sendPublicMessage: { [weak self] channelId, message in
                guard let self else { return false }
                return await self.sendWelcomeFlowMessage(
                    channelId: channelId,
                    message: message,
                    action: "sendWelcomeTest"
                )
            },
            log: { [weak self] message in
                self?.logs.append(message)
            }
        )
    }
}

private extension Array where Element == WelcomeFlowService.InviteSnapshot {
    func sortedForWelcomeFlowDisplay() -> [WelcomeFlowService.InviteSnapshot] {
        sorted { lhs, rhs in
            let lhsChannel = lhs.channelName ?? ""
            let rhsChannel = rhs.channelName ?? ""
            let channelOrder = lhsChannel.localizedCaseInsensitiveCompare(rhsChannel)
            if channelOrder != .orderedSame {
                return channelOrder == .orderedAscending
            }
            return lhs.code.localizedCaseInsensitiveCompare(rhs.code) == .orderedAscending
        }
    }
}
