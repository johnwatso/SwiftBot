import Foundation

actor RuleExecutionService {
    struct Dependencies {
        let sendMessage: (_ channelId: String, _ content: String, _ token: String) async throws -> Void
        let sendPayloadMessage: (_ channelId: String, _ payload: [String: Any], _ token: String) async throws -> Void
        let sendDM: (_ userId: String, _ content: String) async throws -> Void
        let addReaction: (_ channelId: String, _ messageId: String, _ emoji: String, _ token: String) async throws -> Void
        let deleteMessage: (_ channelId: String, _ messageId: String, _ token: String) async throws -> Void
        let addRole: (_ guildId: String, _ userId: String, _ roleId: String, _ token: String) async throws -> Void
        let removeRole: (_ guildId: String, _ userId: String, _ roleId: String, _ token: String) async throws -> Void
        let timeoutMember: (_ guildId: String, _ userId: String, _ durationSeconds: Int, _ token: String) async throws -> Void
        let kickMember: (_ guildId: String, _ userId: String, _ reason: String, _ token: String) async throws -> Void
        let moveMember: (_ guildId: String, _ userId: String, _ channelId: String, _ token: String) async throws -> Void
        let createChannel: (_ guildId: String, _ name: String, _ token: String) async throws -> Void
        let sendWebhook: (_ url: String, _ content: String) async throws -> Void
        let updatePresence: (_ text: String) async -> Void
        let resolveChannelName: (_ guildId: String, _ channelId: String) async -> String
        let resolveGuildName: (_ guildId: String) async -> String?
        let debugLog: (_ message: String) -> Void
    }

    private let aiService: DiscordAIService
    private let dependencies: Dependencies
    private var ruleHandledMessageIds: Set<String> = []

    init(aiService: DiscordAIService, dependencies: Dependencies) {
        self.aiService = aiService
        self.dependencies = dependencies
    }

    func wasMessageHandledByRules(messageId: String) -> Bool {
        ruleHandledMessageIds.contains(messageId)
    }

    func markMessageHandledByRules(messageId: String) {
        ruleHandledMessageIds.insert(messageId)
        if ruleHandledMessageIds.count > 1000 {
            let sortedIds = Array(ruleHandledMessageIds)
            ruleHandledMessageIds = Set(sortedIds.suffix(1000))
        }
    }

    func executeRulePipeline(
        actions: [Action],
        for event: VoiceRuleEvent,
        isDirectMessage: Bool,
        token: String?
    ) async -> PipelineContext {
        var context = PipelineContext()
        context.isDirectMessage = isDirectMessage
        context.triggerGuildId = event.triggerGuildId
        context.triggerChannelId = event.triggerChannelId
        context.triggerMessageId = event.triggerMessageId

        dependencies.debugLog("Executing rule pipeline: \(actions.count) blocks. Initial context: \(context)")

        for (index, action) in actions.enumerated() {
            await execute(action: action, for: event, context: &context, token: token)
            dependencies.debugLog("  [\(index)] Executed \(action.type.rawValue). Updated context: \(context)")
        }

        if context.eventHandled, let messageId = event.triggerMessageId {
            markMessageHandledByRules(messageId: messageId)
            dependencies.debugLog("Message \(messageId) handled by rule actions - AI reply will be skipped")
        }

        dependencies.debugLog("Rule pipeline execution complete.")
        return context
    }

    func execute(
        action: Action,
        for event: VoiceRuleEvent,
        context: inout PipelineContext,
        token: String?
    ) async {
        guard let token else { return }

        switch action.type {
        case .mentionUser:
            context.prependUserMention = true
        case .mentionRole:
            context.mentionRole = action.roleId
        case .disableMention:
            context.mentionUser = false
        case .sendToChannel:
            context.targetChannelId = action.channelId
        case .sendToDM:
            context.sendToDM = true
        case .replyToTrigger:
            context.replyToTriggerMessage = true
            if let triggerChannelId = event.triggerChannelId {
                context.targetChannelId = triggerChannelId
            }
        case .generateAIResponse:
            let prompt = await renderMessage(template: action.message, event: event, context: context)
            if let aiReply = await generateRuleActionAIReply(prompt: prompt, event: event) {
                context.aiResponse = aiReply
            }
        case .summariseMessage:
            guard let content = event.messageContent, !content.isEmpty else { break }
            let prompt = "Summarize the following message concisely:\n\n\(content)"
            if let summary = await generateRuleActionAIReply(prompt: prompt, event: event) {
                context.aiSummary = summary
            }
        case .classifyMessage:
            guard let content = event.messageContent, !content.isEmpty else { break }
            let categories = action.categories.isEmpty ? "question, feedback, spam, other" : action.categories
            let prompt = "Classify the following message into one of these categories [\(categories)]:\n\n\(content)\n\nCategory:"
            if let classification = await generateRuleActionAIReply(prompt: prompt, event: event) {
                context.aiClassification = classification.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .extractEntities:
            guard let content = event.messageContent, !content.isEmpty else { break }
            let entityTypes = action.entityTypes.isEmpty ? "names, dates, locations, organizations" : action.entityTypes
            let prompt = "Extract \(entityTypes) from the following message as a comma-separated list:\n\n\(content)\n\nEntities:"
            if let entities = await generateRuleActionAIReply(prompt: prompt, event: event) {
                context.aiEntities = entities.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .rewriteMessage:
            guard let content = event.messageContent, !content.isEmpty else { break }
            let style = action.rewriteStyle.isEmpty ? "professional" : action.rewriteStyle
            let prompt = "Rewrite the following message in a \(style) style:\n\n\(content)\n\nRewritten:"
            if let rewrite = await generateRuleActionAIReply(prompt: prompt, event: event) {
                context.aiRewrite = rewrite
            }
        case .sendMessage:
            let messageContent: String
            switch action.contentSource {
            case .custom:
                messageContent = action.message
            case .aiResponse:
                messageContent = context.aiResponse ?? "{ai.response} not available"
            case .aiSummary:
                messageContent = context.aiSummary ?? "{ai.summary} not available"
            case .aiClassification:
                messageContent = context.aiClassification ?? "{ai.classification} not available"
            case .aiEntities:
                messageContent = context.aiEntities ?? "{ai.entities} not available"
            case .aiRewrite:
                messageContent = context.aiRewrite ?? "{ai.rewrite} not available"
            }

            let targetIsDM = context.sendToDM
            let rendered = await renderMessage(template: messageContent, event: event, context: context)

            if targetIsDM && !event.userId.isEmpty {
                _ = try? await dependencies.sendDM(event.userId, rendered)
                context.eventHandled = true
                return
            }

            let modifierTargetChannelId = context.targetChannelId
            let triggerMessageId = context.triggerMessageId ?? event.triggerMessageId
            let triggerChannelId = context.triggerChannelId ?? event.triggerChannelId

            if context.replyToTriggerMessage,
               let triggerMessageId,
               let triggerChannelId,
               !triggerChannelId.isEmpty {
                let payload: [String: Any] = [
                    "content": rendered,
                    "message_reference": [
                        "message_id": triggerMessageId,
                        "channel_id": triggerChannelId,
                        "fail_if_not_exists": false
                    ]
                ]
                _ = try? await dependencies.sendPayloadMessage(triggerChannelId, payload, token)
                context.eventHandled = true
                return
            }

            let destinationMode = action.destinationMode ?? MessageDestination.defaultMode(for: event, context: context)

            switch destinationMode {
            case .replyToTrigger:
                if let triggerMessageId,
                   let triggerChannelId,
                   !triggerChannelId.isEmpty {
                    let payload: [String: Any] = [
                        "content": rendered,
                        "message_reference": [
                            "message_id": triggerMessageId,
                            "channel_id": triggerChannelId,
                            "fail_if_not_exists": false
                        ]
                    ]
                    _ = try? await dependencies.sendPayloadMessage(triggerChannelId, payload, token)
                    context.eventHandled = true
                } else if let fallbackChannelId = modifierTargetChannelId ?? triggerChannelId, !fallbackChannelId.isEmpty {
                    try? await dependencies.sendMessage(fallbackChannelId, rendered, token)
                    context.eventHandled = true
                } else if !action.channelId.isEmpty {
                    try? await dependencies.sendMessage(action.channelId, rendered, token)
                    context.eventHandled = true
                }
            case .sameChannel:
                let targetChannelId = modifierTargetChannelId ?? triggerChannelId ?? event.channelId
                guard !targetChannelId.isEmpty else { return }
                try? await dependencies.sendMessage(targetChannelId, rendered, token)
                context.eventHandled = true
            case .specificChannel:
                let targetChannelId = modifierTargetChannelId ?? action.channelId
                guard !targetChannelId.isEmpty else { return }
                try? await dependencies.sendMessage(targetChannelId, rendered, token)
                context.eventHandled = true
            }
        case .addLogEntry:
            return
        case .setStatus:
            let statusText = await renderMessage(template: action.statusText, event: event, context: context)
            guard !statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await dependencies.updatePresence(statusText)
        case .sendDM:
            let rendered = await renderMessage(template: action.dmContent, event: event, context: context)
            _ = try? await dependencies.sendDM(event.userId, rendered)
            context.eventHandled = true
        case .addReaction:
            guard let triggerMessageId = event.triggerMessageId, let triggerChannelId = event.triggerChannelId else { return }
            _ = try? await dependencies.addReaction(triggerChannelId, triggerMessageId, action.emoji, token)
            context.eventHandled = true
        case .deleteMessage:
            guard let triggerMessageId = event.triggerMessageId, let triggerChannelId = event.triggerChannelId else { return }
            if action.deleteDelaySeconds > 0 {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(action.deleteDelaySeconds) * 1_000_000_000)
                    _ = try? await self.dependencies.deleteMessage(triggerChannelId, triggerMessageId, token)
                }
            } else {
                _ = try? await dependencies.deleteMessage(triggerChannelId, triggerMessageId, token)
            }
            context.eventHandled = true
        case .addRole:
            _ = try? await dependencies.addRole(event.guildId, event.userId, action.roleId, token)
            context.eventHandled = true
        case .removeRole:
            _ = try? await dependencies.removeRole(event.guildId, event.userId, action.roleId, token)
            context.eventHandled = true
        case .timeoutMember:
            _ = try? await dependencies.timeoutMember(event.guildId, event.userId, action.timeoutDuration, token)
            context.eventHandled = true
        case .kickMember:
            _ = try? await dependencies.kickMember(event.guildId, event.userId, action.kickReason, token)
            context.eventHandled = true
        case .moveMember:
            _ = try? await dependencies.moveMember(event.guildId, event.userId, action.targetVoiceChannelId, token)
            context.eventHandled = true
        case .createChannel:
            _ = try? await dependencies.createChannel(event.guildId, action.newChannelName, token)
            context.eventHandled = true
        case .webhook:
            _ = try? await dependencies.sendWebhook(action.webhookURL, action.webhookContent)
        case .delay:
            try? await Task.sleep(nanoseconds: UInt64(action.delaySeconds) * 1_000_000_000)
        case .setVariable, .randomChoice:
            dependencies.debugLog("Action \(action.type.rawValue) not yet fully implemented")
            return
        }
    }

    private func renderMessage(template: String, event: VoiceRuleEvent, context: PipelineContext) async -> String {
        let channelId = event.channelId
        let fromChannelId = event.fromChannelId ?? channelId
        let toChannelId = event.toChannelId ?? channelId

        let channelName = await dependencies.resolveChannelName(event.guildId, channelId)
        let fromChannelName = await dependencies.resolveChannelName(event.guildId, fromChannelId)
        let toChannelName = await dependencies.resolveChannelName(event.guildId, toChannelId)

        var output = template
            .replacingOccurrences(of: "<#{channelId}>", with: channelName)
            .replacingOccurrences(of: "<#{fromChannelId}>", with: fromChannelName)
            .replacingOccurrences(of: "<#{toChannelId}>", with: toChannelName)
            .replacingOccurrences(of: "{userId}", with: event.userId)
            .replacingOccurrences(of: "{username}", with: event.username)
            .replacingOccurrences(of: "{guildId}", with: event.guildId)
            .replacingOccurrences(of: "{guildName}", with: await dependencies.resolveGuildName(event.guildId) ?? event.guildId)
            .replacingOccurrences(of: "{channelId}", with: channelId)
            .replacingOccurrences(of: "{channelName}", with: channelName)
            .replacingOccurrences(of: "{fromChannelId}", with: fromChannelId)
            .replacingOccurrences(of: "{toChannelId}", with: toChannelId)
            .replacingOccurrences(of: "{duration}", with: formatDuration(seconds: event.durationSeconds))
            .replacingOccurrences(of: "{message}", with: event.messageContent ?? "")
            .replacingOccurrences(of: "{messageId}", with: event.messageId ?? "")
            .replacingOccurrences(of: "{media.file}", with: event.mediaFileName ?? "")
            .replacingOccurrences(of: "{media.path}", with: event.mediaRelativePath ?? "")
            .replacingOccurrences(of: "{media.source}", with: event.mediaSourceName ?? "")
            .replacingOccurrences(of: "{media.node}", with: event.mediaNodeName ?? "")
            .replacingOccurrences(of: "{ai.response}", with: context.aiResponse ?? "")

        if !context.mentionUser {
            output = output.replacingOccurrences(of: "<@\(event.userId)>", with: event.username)
        }

        if context.prependUserMention {
            output = "<@\(event.userId)> " + output
        }

        if let roleMention = context.mentionRole {
            output = "<@&\(roleMention)> " + output
        }

        return output
    }

    private func generateRuleActionAIReply(prompt: String, event: VoiceRuleEvent) async -> String? {
        let channelId = event.triggerChannelId ?? event.channelId
        let channelName = event.isDirectMessage
            ? "Direct Message"
            : await dependencies.resolveChannelName(event.triggerGuildId, channelId)
        return await aiService.generateRuleActionAIReply(
            prompt: prompt,
            event: event,
            serverName: await dependencies.resolveGuildName(event.triggerGuildId),
            channelName: channelName
        )
    }

    private func formatDuration(seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "0s" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
