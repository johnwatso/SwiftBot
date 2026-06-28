import Foundation

extension AppModel {

    /// Evaluate the live rule set against `event` and execute each match.
    func fireAutomations(for event: SwiftBotEvent) async {
        let snapshot = automationStore.rules
        let tok = settings.token
        let token: String? = tok.isEmpty ? nil : tok

        // 1. Separate moderation rules and automation rules
        let moderationRules = snapshot.filter { $0.category == .moderation }
        let automationRules = snapshot.filter { $0.category == .automation }

        // 2. Evaluate and execute moderation rules first
        let moderationMatches = automationService.evaluate(event: event, in: moderationRules)
        var messageWasModerated = false

        for rule in moderationMatches {
            await automationService.execute(rule: rule, event: event, token: token)
            
            // If the rule performs destructive action, mark it as moderated to cancel standard automations
            if rule.steps.contains(where: { step in
                (step.kind == .modifyMessage && step.messageOp == .delete) ||
                (step.kind == .modifyMember && (step.memberOp == .timeout || step.memberOp == .kick))
            }) {
                messageWasModerated = true
            }
        }

        // 3. Evaluate and execute standard automation rules only if not moderated
        if !messageWasModerated {
            let automationMatches = automationService.evaluate(event: event, in: automationRules)
            for rule in automationMatches {
                await automationService.execute(rule: rule, event: event, token: token)
            }
        }
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
        return AutomationService(aiService: aiService, dependencies: deps)
    }
}
