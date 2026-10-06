import Foundation

extension AppModel {

    /// Enabled Automations and Moderation rules, so every surface that
    /// reports "active automations" agrees.
    var enabledAutomationRuleCount: Int {
        automationStore.rules.filter(\.enabled).count
    }

    var totalAutomationRuleCount: Int {
        automationStore.rules.count
    }

    /// Evaluate the live rule set against `event` and execute each match,
    /// moderation first. Same dispatcher as live messages and voice changes.
    func fireAutomations(for event: SwiftBotEvent) async {
        guard shouldProcessPrimaryGatewayActions, await service.outputAllowed else { return }
        let tok = settings.token
        await automationService.dispatch(event: event, rules: automationStore.rules, token: tok.isEmpty ? nil : tok)
    }

    /// Context passed into the AI drafter so it can pick real channel/role IDs.
    /// Synchronous so SwiftUI views can call it during render. Channels and
    /// roles are sourced from the main-actor `availableVoiceChannelsByServer`
    /// / `availableTextChannelsByServer` caches; the actor-backed DiscordCache
    /// is intentionally NOT read here to keep this call sync.
    func automationServerContext() -> AutomationDrafter.ServerContext {
        let guildId = connectedServers.keys.first
        let guildName = guildId.flatMap { connectedServers[$0] }

        var textChannels: [(id: String, name: String)] = []
        var voiceChannels: [(id: String, name: String)] = []
        var roles: [(id: String, name: String)] = []

        if let gid = guildId {
            if let textChans = availableTextChannelsByServer[gid] {
                textChannels = textChans.map { ($0.id, $0.name) }
            }
            if let voiceChans = availableVoiceChannelsByServer[gid] {
                voiceChannels = voiceChans.map { ($0.id, $0.name) }
            }
            if let r = availableRolesByServer[gid] {
                roles = r.map { ($0.id, $0.name) }
            }
        }

        return AutomationDrafter.ServerContext(
            guildName: guildName,
            guildId: guildId,
            textChannels: textChannels,
            voiceChannels: voiceChannels,
            roles: roles
        )
    }

    /// Build the engine. Called once via the lazy property on AppModel.
    func buildAutomationService() -> AutomationService {
        let deps = AutomationService.Dependencies(
            canExecute: { [weak self] in
                guard let self else { return false }
                let owns = await self.cluster.hasActiveOwnership()
                let allows = await self.service.outputAllowed
                return owns && allows
            },
            scheduledRuleStillValid: { [weak self] rule in
                await MainActor.run {
                    guard let current = self?.automationStore.rules.first(where: { $0.id == rule.id }) else { return false }
                    return current.enabled && current.isExecutionEquivalent(to: rule)
                }
            },
            scheduledEventStillValid: { [weak self] trigger, occurrenceId, token in
                guard let self, let guild = trigger.guildId, let eventId = trigger.eventId,
                    let events = try? await self.service.fetchScheduledEvents(guildId: guild, token: token),
                    let event = events.first(where: { $0.id == eventId && $0.status != 4 })
                else { return false }
                let due =
                    trigger.eventCustomTime.flatMap(Automations.Schedule.parse)
                    ?? event.startDate?.addingTimeInterval(Double(trigger.eventOffsetSeconds ?? 0))
                guard let due else { return false }
                return occurrenceId == "schedule:" + String(Int(due.timeIntervalSince1970))
            },
            sendMessage: { [weak self] c, m, t in
                try await self?.service.sendMessage(channelId: c, content: m, token: t)
            },
            sendPayloadMessage: { [weak self] c, p, t in
                nonisolated(unsafe) let safeP = p
                _ = try await self?.service.sendMessage(channelId: c, payload: safeP, token: t)
            },
            sendDM: { [weak self] u, c in
                try await self?.service.sendDM(userId: u, content: c)
            },
            addReaction: { [weak self] c, m, e, t in
                try await self?.service.addReaction(channelId: c, messageId: m, emoji: e, token: t)
            },
            deleteMessage: { [weak self] c, m, t in
                try await self?.service.deleteMessage(channelId: c, messageId: m, token: t)
                self?.recordAudit(
                    source: .moderation,
                    actor: "Automation",
                    action: "Deleted message",
                    detail: "channel \(c) · msg \(m)",
                    level: .warning
                )
            },
            addRole: { [weak self] g, u, r, t in
                try await self?.service.addRole(guildId: g, userId: u, roleId: r, token: t)
            },
            removeRole: { [weak self] g, u, r, t in
                try await self?.service.removeRole(guildId: g, userId: u, roleId: r, token: t)
            },
            timeoutMember: { [weak self] g, u, s, t in
                try await self?.service.timeoutMember(guildId: g, userId: u, durationSeconds: s, token: t)
                self?.recordAudit(
                    source: .moderation,
                    actor: "Automation",
                    action: "Timed out member",
                    detail: "user \(u) · guild \(g) · \(s)s",
                    level: .warning
                )
            },
            kickMember: { [weak self] g, u, r, t in
                try await self?.service.kickMember(guildId: g, userId: u, reason: r, token: t)
                self?.recordAudit(
                    source: .moderation,
                    actor: "Automation",
                    action: "Kicked member",
                    detail: "user \(u) · guild \(g) · reason: \(r.isEmpty ? "—" : r)",
                    level: .warning
                )
            },
            banMember: { [weak self] g, u, reason, seconds, token in
                guard let self else { throw CancellationError() }
                try await self.service.banMember(guildId: g, userId: u, reason: reason, deleteMessageSeconds: seconds, token: token)
                self.recordAudit(source: .moderation, actor: "Automation", action: "Banned member",
                                 detail: "user \(u) · guild \(g) · reason: \(reason.isEmpty ? "—" : reason) · removed \(seconds)s of messages", level: .warning)
            },
            removeTimeout: { [weak self] g, u, token in
                guard let self else { throw CancellationError() }
                try await self.service.removeTimeout(guildId: g, userId: u, token: token)
                self.recordAudit(source: .moderation, actor: "Automation", action: "Removed member timeout",
                                 detail: "user \(u) · guild \(g)", level: .ok)
            },
            moveMember: { [weak self] g, u, c, t in
                try await self?.service.moveMember(guildId: g, userId: u, channelId: c, token: t)
            },
            sendWebhook: { [weak self] url, c in
                try await self?.service.sendWebhook(url: url, content: c)
            },
            resolveChannelName: { [weak self] g, c in
                guard let self else { return "Unknown" }
                let textByGuild = await self.discordCache.textChannelsByGuild()
                let voiceByGuild = await self.discordCache.voiceChannelsByGuild()
                if let text = textByGuild[g]?.first(where: { $0.id == c }) {
                    return text.name
                }
                if let voice = voiceByGuild[g]?.first(where: { $0.id == c }) {
                    return voice.name
                }
                return "Unknown"
            },
            resolveGuildName: { [weak self] g in
                guard let self else { return nil }
                return await self.discordCache.allGuildNames()[g]
            },
            log: { [weak self] msg in
                Task { @MainActor [weak self] in self?.logs.append(msg) }
            },
            recordAutomationRun: { [weak self] ruleId, ruleName, eventKind, triggerUser, stepsCount, status in
                if status.hasPrefix("Failed") {
                    Task { @MainActor [weak self] in
                        guard self?.automationStore.rules.first(where: { $0.id == ruleId })?.category == .moderation else { return }
                        self?.recordAudit(source: .moderation, actor: "Automation", action: "Moderation rule failed",
                                          detail: "\(ruleName) · \(triggerUser) · \(status)", level: .error)
                    }
                }
                self?.recordAutomationRun(
                    ruleId: ruleId,
                    ruleName: ruleName,
                    eventKind: eventKind,
                    triggerUser: triggerUser,
                    stepsCount: stepsCount,
                    status: status
                )
            }
        )
        return AutomationService(aiService: aiService, dependencies: deps, journalURL: SwiftBotStorage.folderURL().appendingPathComponent(AutomationExecutionJournal.fileName))
    }
}

extension AppModel {
    func startAutomationScheduler() {
        guard automationScheduleTask == nil else { return }
        automationScheduleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let model = self { await model.tickAutomationSchedules() } else { return }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
    func refreshScheduledEvents(force: Bool = false) async {
        guard !scheduledEventsRefreshing, !settings.token.isEmpty,
            force || scheduledEventsRefreshedAt == nil || Date().timeIntervalSince(scheduledEventsRefreshedAt!) >= 60
        else { return }
        scheduledEventsRefreshing = true
        defer { scheduledEventsRefreshing = false }
        let servers = connectedServers
        var events: [DiscordScheduledEvent] = []
        var errors: [String: String] = [:]
        for guild in servers.keys.sorted() {
            do { events += try await service.fetchScheduledEvents(guildId: guild, token: settings.token) } catch { errors[guild] = error.localizedDescription }
        }
        scheduledDiscordEvents = events.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
        scheduledEventErrors = errors
        scheduledEventsRefreshedAt = Date()
    }
    func tickAutomationSchedules() async {
        guard shouldProcessPrimaryGatewayActions, await service.outputAllowed, !settings.token.isEmpty else { return }
        let rules = automationStore.rules.filter { $0.enabled && ($0.trigger.kind == .schedule || $0.trigger.kind == .scheduledEvent) }
        if rules.contains(where: { $0.trigger.kind == .scheduledEvent }) { await refreshScheduledEvents() }
        // Never send from cached data if an event refresh failed: it may have been cancelled.
        await automationService.runScheduledRules(
            rules, events: scheduledDiscordEvents.filter { scheduledEventErrors[$0.guildId] == nil }, token: settings.token)
    }
}

// MARK: - Reaction and slash-command triggers

extension AppModel {
    /// Slash names that enabled automation rules own, in rule order. Built-in
    /// and Lookup commands keep their names; a colliding rule is not registered.
    func automationSlashCommandNames() -> [String] {
        var taken = Set(builtInSlashCommandDefinitions().compactMap { $0["name"] as? String })
        for source in orderedEnabledWikiSources() {
            for command in source.commands where command.enabled {
                taken.insert(discordSlashSafeWikiCommandName(command.trigger))
            }
        }
        var names: [String] = []
        for rule in automationStore.rules where rule.enabled && rule.trigger.kind == .slashCommand {
            let name = discordSlashSafeWikiCommandName(rule.trigger.commandName ?? "")
            guard !name.isEmpty, !taken.contains(name) else { continue }
            taken.insert(name)
            names.append(name)
        }
        return names
    }

    func automationSlashCommandDefinitions() -> [[String: Any]] {
        automationSlashCommandNames().map { name in
            let rule = automationStore.rules.first {
                $0.enabled && $0.trigger.kind == .slashCommand
                    && discordSlashSafeWikiCommandName($0.trigger.commandName ?? "") == name
            }
            let title = (rule?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                "name": name,
                "description": title.isEmpty ? "Run the /\(name) automation" : String(title.prefix(100)),
                "type": 1,
                "options": [["type": 3, "name": "text", "description": "Details to include", "required": false]]
            ]
        }
    }

    /// Re-register slash commands when a rule edit adds, removes or renames an
    /// automation command, rather than waiting for the five-minute refresh.
    func refreshAutomationSlashCommandsIfChanged() async {
        let names = automationSlashCommandNames()
        guard names != registeredAutomationSlashCommandNames else { return }
        lastSlashGuildRegistrationAt.removeAll()
        await registerSlashCommandsIfNeeded()
    }

    func handleAutomationReaction(_ raw: DiscordJSON?) async {
        guard let event = Self.automationReactionEvent(from: raw, botUserId: botUserId) else { return }
        await fireAutomations(for: event)
    }

    /// MESSAGE_REACTION_ADD as a `reactionAdded` event. The bot's own
    /// reactions are ignored so a react step cannot trigger itself.
    nonisolated static func automationReactionEvent(from raw: DiscordJSON?, botUserId: String?) -> SwiftBotEvent? {
        guard case let .object(map)? = raw,
              case let .string(userId)? = map["user_id"],
              case let .string(channelId)? = map["channel_id"],
              case let .string(messageId)? = map["message_id"],
              case let .object(emoji)? = map["emoji"],
              case let .string(emojiName)? = emoji["name"], !emojiName.isEmpty,
              userId != botUserId
        else { return nil }
        var guildId = ""
        if case let .string(id)? = map["guild_id"] { guildId = id }
        var username = userId
        var roleIds: [String]?
        var isBot = false
        if case let .object(member)? = map["member"] {
            if case let .array(roles)? = member["roles"] {
                roleIds = roles.compactMap { if case let .string(id) = $0 { return id }; return nil }
            }
            if case let .object(user)? = member["user"] {
                if case let .string(name)? = user["username"] { username = name }
                if case let .bool(bot)? = user["bot"] { isBot = bot }
            }
        }
        var payload = SwiftBotEvent.MessagePayload(
            guildId: guildId, userId: userId, username: username, roleIds: roleIds, channelId: channelId,
            messageId: messageId, content: emojiName, isDirectMessage: guildId.isEmpty, authorIsBot: isBot)
        payload.automationTrigger = .reactionAdded
        payload.occurrenceId = "reaction:\(messageId):\(userId):\(emojiName)"
        return .message(payload)
    }

    /// An automation slash command as a `slashCommand` event. Its content is
    /// `/name` plus the optional text, which `{message}` renders.
    nonisolated static func automationSlashEvent(from interaction: GatewayInteractionCreateEvent, name: String) -> SwiftBotEvent {
        let map = interaction.rawMap
        var guildId = ""
        if case let .string(id)? = map["guild_id"] { guildId = id }
        var channelId = ""
        if case let .string(id)? = map["channel_id"] { channelId = id }
        var userId = ""
        var username = "User"
        var roleIds: [String]?
        var user: [String: DiscordJSON]?
        if case let .object(member)? = map["member"] {
            if case let .array(roles)? = member["roles"] {
                roleIds = roles.compactMap { if case let .string(id) = $0 { return id }; return nil }
            }
            if case let .object(value)? = member["user"] { user = value }
        } else if case let .object(value)? = map["user"] {
            user = value
        }
        if case let .string(id)? = user?["id"] { userId = id }
        if case let .string(value)? = user?["username"] { username = value }
        var text = ""
        if case let .array(options)? = interaction.data["options"] {
            for case let .object(option) in options {
                if case let .string("text")? = option["name"], case let .string(value)? = option["value"] { text = value }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = SwiftBotEvent.MessagePayload(
            guildId: guildId, userId: userId, username: username, roleIds: roleIds, channelId: channelId,
            messageId: interaction.interactionID, content: trimmed.isEmpty ? "/\(name)" : "/\(name) \(trimmed)",
            isDirectMessage: guildId.isEmpty, authorIsBot: false)
        payload.automationTrigger = .slashCommand
        payload.occurrenceId = "interaction:\(interaction.interactionID)"
        return .message(payload)
    }

    /// Acknowledges privately within Discord's three-second window, runs the
    /// rules (whose messages post to the channel), then closes the reply.
    func handleAutomationSlash(event interaction: GatewayInteractionCreateEvent, name: String) async {
        do {
            try await service.respondToInteraction(
                interactionID: interaction.interactionID,
                interactionToken: interaction.interactionToken,
                payload: ["type": 5, "data": ["flags": 64]]
            )
        } catch {
            logs.append("❌ Failed ACK for /\(name) automation: \(error.localizedDescription)")
            return
        }
        await fireAutomations(for: Self.automationSlashEvent(from: interaction, name: name))
        stats.commandsRun += 1
        guard let applicationID = botUserId, !applicationID.isEmpty else { return }
        try? await service.editOriginalInteractionResponse(
            applicationID: applicationID, interactionToken: interaction.interactionToken, content: "Done.")
    }
}
