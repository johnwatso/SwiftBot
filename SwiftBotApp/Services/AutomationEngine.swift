import Foundation
import OSLog

/// Matches and executes Automations.Rule against incoming VoiceRuleEvents.
///
/// Two responsibilities, kept in one actor since they share state:
///   1. `evaluate(event:in:)` — pure filter. Returns rules whose trigger matches.
///   2. `execute(rule:event:token:)` — runs the rule's ordered Steps.
actor AutomationEngine {

    // MARK: - Dependencies

    /// All Discord side-effects flow through this struct so the engine can be
    /// constructed in tests with stubs. Mirrors the surface of the old
    /// RuleExecutionService.Dependencies.
    struct Dependencies {
        let sendMessage: (_ channelId: String, _ content: String, _ token: String) async throws -> Void
        let sendPayloadMessage: (_ channelId: String, _ payload: [String: Any], _ token: String) async throws -> Void
        let sendDM: (_ userId: String, _ content: String) async throws -> Void
        let addReaction: (_ channelId: String, _ messageId: String, _ emoji: String, _ token: String) async throws -> Void
        let deleteMessage: (_ channelId: String, _ messageId: String, _ token: String) async throws -> Void
        let addRole: (_ guildId: String, _ userId: String, _ roleId: String, _ token: String) async throws -> Void
        let removeRole: (_ guildId: String, _ userId: String, _ roleId: String, _ token: String) async throws -> Void
        let timeoutMember: (_ guildId: String, _ userId: String, _ seconds: Int, _ token: String) async throws -> Void
        let kickMember: (_ guildId: String, _ userId: String, _ reason: String, _ token: String) async throws -> Void
        let moveMember: (_ guildId: String, _ userId: String, _ channelId: String, _ token: String) async throws -> Void
        let sendWebhook: (_ url: String, _ content: String) async throws -> Void
        let resolveChannelName: (_ guildId: String, _ channelId: String) async -> String
        let resolveGuildName: (_ guildId: String) async -> String?
        let log: (_ message: String) -> Void
    }

    private let aiService: DiscordAIService
    private let dependencies: Dependencies
    private var handledMessageIds: Set<String> = []
    private let logger = Logger(subsystem: "com.swiftbot", category: "automations")

    init(aiService: DiscordAIService, dependencies: Dependencies) {
        self.aiService = aiService
        self.dependencies = dependencies
    }

    // MARK: - Dedup

    func wasMessageHandledByRules(messageId: String) -> Bool {
        handledMessageIds.contains(messageId)
    }

    private func markHandled(_ messageId: String) {
        handledMessageIds.insert(messageId)
        if handledMessageIds.count > 1000 {
            handledMessageIds = Set(Array(handledMessageIds).suffix(1000))
        }
    }

    // MARK: - Matching

    /// Returns the enabled rules whose Trigger and Filter set match `event`.
    /// Pure — no side effects, no actor state read.
    nonisolated func evaluate(event: VoiceRuleEvent, in rules: [Automations.Rule]) -> [Automations.Rule] {
        rules.filter { rule in
            guard rule.enabled else { return false }
            guard Self.triggerMatches(rule.trigger, event: event) else { return false }
            return Self.filtersMatch(rule.filters, logic: rule.filterLogic, event: event)
        }
    }

    private nonisolated static func triggerMatches(_ trigger: Automations.Trigger, event: VoiceRuleEvent) -> Bool {
        switch (trigger.kind, event.kind) {
        case (.userJoinedVoice, .join),
             (.userLeftVoice, .leave),
             (.userMovedVoice, .move),
             (.messageCreated, .message),
             (.memberJoined, .memberJoin),
             (.memberLeft, .memberLeave),
             (.mediaAdded, .mediaAdded):
            return true
        case (.reactionAdded, _), (.slashCommand, _):
            // Not yet emitted by gateway plumbing; future-proofed.
            return false
        default:
            return false
        }
    }

    private nonisolated static func filtersMatch(
        _ filters: [Automations.Filter],
        logic: Automations.FilterLogic,
        event: VoiceRuleEvent
    ) -> Bool {
        guard !filters.isEmpty else { return true }
        switch logic {
        case .all: return filters.allSatisfy { filterMatches($0, event: event) }
        case .any: return filters.contains { filterMatches($0, event: event) }
        }
    }

    private nonisolated static func filterMatches(
        _ filter: Automations.Filter,
        event: VoiceRuleEvent
    ) -> Bool {
        switch filter.kind {
        case .inChannel:
            let pool = filter.channelIds ?? []
            return pool.isEmpty || pool.contains(event.channelId)

        case .directMessage:
            return (filter.boolValue ?? true) == event.isDirectMessage

        case .userIsOneOf:
            let pool = filter.userIds ?? []
            return pool.isEmpty || pool.contains(event.userId)

        case .userHasAnyRole, .userHasAllRoles, .userHasNoneOfRoles:
            // Member role state isn't plumbed through VoiceRuleEvent yet,
            // so role filters always pass. Surface this in the UI as
            // "currently informational" until we wire it up.
            return true

        case .messageContains:
            let needle = (filter.text ?? "").lowercased()
            let hay = (event.messageContent ?? "").lowercased()
            return !needle.isEmpty && hay.contains(needle)

        case .messageContainsAny:
            let needles = (filter.textValues ?? []).map { $0.lowercased() }
            let hay = (event.messageContent ?? "").lowercased()
            return needles.contains { !$0.isEmpty && hay.contains($0) }

        case .messageEquals:
            let target = (filter.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let actual = (event.messageContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return target == actual

        case .messageDoesNotContain:
            let needle = (filter.text ?? "").lowercased()
            let hay = (event.messageContent ?? "").lowercased()
            return needle.isEmpty || !hay.contains(needle)

        case .messageMatchesRegex:
            let pattern = filter.text ?? ""
            guard !pattern.isEmpty else { return false }
            let hay = event.messageContent ?? ""
            return (try? NSRegularExpression(pattern: pattern))?
                .firstMatch(in: hay, range: NSRange(hay.startIndex..., in: hay)) != nil

        case .messageIsReply:
            // VoiceRuleEvent doesn't carry reply state yet; treat as
            // unknown → pass when expected true, fail when expected false.
            // Will be accurate once parseMessageRuleEvent surfaces it.
            return filter.boolValue ?? true

        case .fromBot:
            return (filter.boolValue ?? false) == (event.authorIsBot ?? false)

        case .minVoiceDurationSeconds:
            let min = filter.intValue ?? 0
            return (event.durationSeconds ?? 0) >= min

        case .reactionEmoji:
            // Reaction event payload doesn't reach the engine yet.
            return true

        case .mediaSource:
            let target = filter.text ?? ""
            return target.isEmpty || event.mediaSourceName == target
        }
    }

    // MARK: - Execution

    /// Runs every Step in `rule.steps` in order against `event`.
    func execute(rule: Automations.Rule, event: VoiceRuleEvent, token: String?) async {
        guard let token else { return }
        var ctx = ExecutionContext(event: event)

        for step in rule.steps {
            await runStep(step, ctx: &ctx, token: token)
        }

        if ctx.eventHandled, let msgId = event.triggerMessageId {
            markHandled(msgId)
        }
    }

    private struct ExecutionContext {
        let event: VoiceRuleEvent
        var eventHandled: Bool = false
    }

    private func runStep(_ step: Automations.Step, ctx: inout ExecutionContext, token: String) async {
        switch step.kind {
        case .sendMessage:
            await runSendMessage(step, ctx: &ctx, token: token)
        case .modifyMember:
            await runModifyMember(step, ctx: &ctx, token: token)
        case .modifyMessage:
            await runModifyMessage(step, ctx: &ctx, token: token)
        case .log:
            await runLog(step, ctx: ctx)
        case .webhook:
            await runWebhook(step, ctx: ctx)
        case .delay:
            let s = max(0, step.delaySeconds ?? 0)
            if s > 0 { try? await Task.sleep(nanoseconds: UInt64(s) * 1_000_000_000) }
        }
    }

    // MARK: - Step: sendMessage

    private func runSendMessage(_ step: Automations.Step, ctx: inout ExecutionContext, token: String) async {
        let event = ctx.event

        // Resolve content: aiPrompt takes precedence if set.
        let rawContent: String
        if let prompt = step.aiPrompt, !prompt.isEmpty {
            let renderedPrompt = await render(prompt, event: event)
            let channelName = event.isDirectMessage
                ? "Direct Message"
                : await dependencies.resolveChannelName(event.triggerGuildId, event.triggerChannelId ?? event.channelId)
            let aiOutput = await aiService.generateRuleActionAIReply(
                prompt: renderedPrompt,
                event: event,
                serverName: await dependencies.resolveGuildName(event.triggerGuildId),
                channelName: channelName
            ) ?? "(AI did not return a response)"
            rawContent = aiOutput
        } else {
            rawContent = await render(step.content ?? "", event: event)
        }

        let target = step.sendTarget ?? defaultSendTarget(for: event)

        switch target {
        case .replyToTrigger:
            if let mid = event.triggerMessageId,
               let cid = event.triggerChannelId, !cid.isEmpty {
                let payload: [String: Any] = [
                    "content": rawContent,
                    "message_reference": [
                        "message_id": mid,
                        "channel_id": cid,
                        "fail_if_not_exists": false
                    ]
                ]
                _ = try? await dependencies.sendPayloadMessage(cid, payload, token)
                ctx.eventHandled = true
            } else {
                await sendToFirstAvailable(rawContent, event: event, fallback: step.channelId, token: token, ctx: &ctx)
            }

        case .sameChannel:
            let cid = event.triggerChannelId ?? event.channelId
            guard !cid.isEmpty else { return }
            try? await dependencies.sendMessage(cid, rawContent, token)
            ctx.eventHandled = true

        case .directMessage:
            guard !event.userId.isEmpty else { return }
            try? await dependencies.sendDM(event.userId, rawContent)
            ctx.eventHandled = true

        case .specificChannel:
            guard let cid = step.channelId, !cid.isEmpty else { return }
            try? await dependencies.sendMessage(cid, rawContent, token)
            ctx.eventHandled = true
        }
    }

    private func sendToFirstAvailable(
        _ content: String,
        event: VoiceRuleEvent,
        fallback: String?,
        token: String,
        ctx: inout ExecutionContext
    ) async {
        let cid = event.triggerChannelId ?? fallback ?? event.channelId
        guard !cid.isEmpty else { return }
        try? await dependencies.sendMessage(cid, content, token)
        ctx.eventHandled = true
    }

    private nonisolated func defaultSendTarget(for event: VoiceRuleEvent) -> Automations.SendTarget {
        switch event.kind {
        case .message: return .replyToTrigger
        case .memberJoin, .memberLeave: return .directMessage
        case .join, .leave, .move, .mediaAdded: return .sameChannel
        }
    }

    // MARK: - Step: modifyMember

    private func runModifyMember(_ step: Automations.Step, ctx: inout ExecutionContext, token: String) async {
        let event = ctx.event
        guard !event.userId.isEmpty, !event.guildId.isEmpty else { return }
        guard let op = step.memberOp else { return }

        switch op {
        case .addRole:
            guard let rid = step.roleId, !rid.isEmpty else { return }
            _ = try? await dependencies.addRole(event.guildId, event.userId, rid, token)
        case .removeRole:
            guard let rid = step.roleId, !rid.isEmpty else { return }
            _ = try? await dependencies.removeRole(event.guildId, event.userId, rid, token)
        case .timeout:
            let s = max(1, step.timeoutSeconds ?? 60)
            _ = try? await dependencies.timeoutMember(event.guildId, event.userId, s, token)
        case .kick:
            _ = try? await dependencies.kickMember(event.guildId, event.userId, step.kickReason ?? "", token)
        case .moveVoice:
            guard let cid = step.targetVoiceChannelId, !cid.isEmpty else { return }
            _ = try? await dependencies.moveMember(event.guildId, event.userId, cid, token)
        }
        ctx.eventHandled = true
    }

    // MARK: - Step: modifyMessage

    private func runModifyMessage(_ step: Automations.Step, ctx: inout ExecutionContext, token: String) async {
        let event = ctx.event
        guard let mid = event.triggerMessageId,
              let cid = event.triggerChannelId, !cid.isEmpty else { return }
        guard let op = step.messageOp else { return }

        switch op {
        case .delete:
            _ = try? await dependencies.deleteMessage(cid, mid, token)
        case .react:
            guard let emoji = step.reactEmoji, !emoji.isEmpty else { return }
            _ = try? await dependencies.addReaction(cid, mid, emoji, token)
        }
        ctx.eventHandled = true
    }

    // MARK: - Step: log

    private func runLog(_ step: Automations.Step, ctx: ExecutionContext) async {
        let text = await render(step.logText ?? "", event: ctx.event)
        guard !text.isEmpty else { return }
        dependencies.log(text)
    }

    // MARK: - Step: webhook

    private func runWebhook(_ step: Automations.Step, ctx: ExecutionContext) async {
        guard let url = step.webhookUrl, !url.isEmpty else { return }
        let body = await render(step.webhookContent ?? "", event: ctx.event)
        _ = try? await dependencies.sendWebhook(url, body)
    }

    // MARK: - Variable substitution

    private func render(_ template: String, event: VoiceRuleEvent) async -> String {
        guard !template.isEmpty else { return "" }

        let channelId = event.channelId
        let channelName = await dependencies.resolveChannelName(event.guildId, channelId)
        let guildName = await dependencies.resolveGuildName(event.guildId) ?? event.guildId

        var out = template
        out = out.replacingOccurrences(of: Automations.Variable.username.rawValue, with: event.username)
        out = out.replacingOccurrences(of: Automations.Variable.userId.rawValue, with: event.userId)
        out = out.replacingOccurrences(of: Automations.Variable.userMention.rawValue, with: "<@\(event.userId)>")
        out = out.replacingOccurrences(of: Automations.Variable.channelName.rawValue, with: channelName)
        out = out.replacingOccurrences(of: Automations.Variable.channelId.rawValue, with: channelId)
        out = out.replacingOccurrences(of: Automations.Variable.guildName.rawValue, with: guildName)
        out = out.replacingOccurrences(of: Automations.Variable.guildId.rawValue, with: event.guildId)
        out = out.replacingOccurrences(of: Automations.Variable.message.rawValue, with: event.messageContent ?? "")
        out = out.replacingOccurrences(of: Automations.Variable.messageId.rawValue, with: event.messageId ?? "")
        out = out.replacingOccurrences(of: Automations.Variable.duration.rawValue, with: formatDuration(event.durationSeconds))
        out = out.replacingOccurrences(of: Automations.Variable.mediaFile.rawValue, with: event.mediaFileName ?? "")
        out = out.replacingOccurrences(of: Automations.Variable.mediaSource.rawValue, with: event.mediaSourceName ?? "")
        return out
    }

    private nonisolated func formatDuration(_ seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "0s" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
}
