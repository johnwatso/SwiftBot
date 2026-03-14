import Foundation
import SwiftUI

extension AppModel {

    // MARK: - Discord Event Handlers

    func handleMemberJoin(_ event: GatewayMemberJoinEvent) async {
        // Legacy settings path still active for backward compatibility.
        // New config: use a "Member Joined" trigger rule in Actions instead.
        let legacyEnabled = settings.behavior.memberJoinWelcomeEnabled &&
            !settings.behavior.memberJoinWelcomeChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasRules = ruleStore.rules.contains { $0.isEnabled && $0.trigger == .memberJoined }
        guard legacyEnabled || hasRules else { return }

        let now = Date()
        let guildId = event.guildID
        let userId = event.userID

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

        // Template sanitization: neutralize @everyone and @here to prevent mass-ping abuse.
        let safeUsername = event.rawUsername
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
            joinedAt: event.joinedAt
        )
        let matchedRules = ruleEngine.evaluateRules(event: ruleEvent)
        for rule in matchedRules {
            _ = PipelineContext()
            for action in rule.processedActions where action.type == .sendMessage {
                let ruleMessage = action.message
                    .replacingOccurrences(of: "{username}", with: safeUsername)
                    .replacingOccurrences(of: "{server}", with: serverName)
                    .replacingOccurrences(of: "{memberCount}", with: "\(memberCount)")
                    .replacingOccurrences(of: "{userId}", with: userId)
                let targetChannel = action.channelId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard !targetChannel.isEmpty else { continue }
                _ = await send(targetChannel, ruleMessage)
            }
        }

        // Log username only — no internal IDs or metadata.
        addEvent(ActivityEvent(timestamp: now, kind: .info, message: "👋 \(safeUsername) joined \(serverName)"))
        logs.append("Member join welcome sent for \(safeUsername) in \(serverName)")
    }

    func handleMemberLeave(_ event: GatewayMemberLeaveEvent) async {
        let now = Date()
        let guildId = event.guildID
        let userId = event.userID
        
        // Best-effort member count decrement
        if let count = guildMemberCounts[guildId] {
            guildMemberCounts[guildId] = max(0, count - 1)
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

        let matchedRules = ruleEngine.evaluateRules(event: ruleEvent)
        for rule in matchedRules {
            _ = await service.executeRulePipeline(actions: rule.processedActions, for: ruleEvent, isDirectMessage: ruleEvent.isDirectMessage)
        }

        addEvent(ActivityEvent(timestamp: now, kind: .info, message: "🚪 \(username) left the server"))
        logs.append("Member leave handled for \(username)")
    }

    func handleGuildCreate(_ event: GatewayGuildCreateEvent) async {
        guildCreateEventCount += 1
        if let memberCount = event.memberCount {
            guildMemberCounts[event.guildID] = memberCount
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
            let joinedAt = now

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
                cacheUserAvatar(avatarHash, for: userId)
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

}
