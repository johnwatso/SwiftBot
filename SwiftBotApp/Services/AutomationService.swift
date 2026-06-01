import Foundation
import OSLog

/// Matches and executes Automations.Rule against incoming SwiftBotEvents.
///
/// Two responsibilities, kept in one actor since they share state:
///   1. `evaluate(event:in:)` — pure filter. Returns rules whose trigger matches.
///   2. `execute(rule:event:token:)` — runs the rule's ordered Steps.
actor AutomationService {

    // MARK: - Dependencies

    /// All Discord side-effects flow through this struct so the engine can be
    /// constructed in tests with stubs. Mirrors the surface of the old
    /// RuleExecutionService.Dependencies.
    struct Dependencies: Sendable {
        let sendMessage: @Sendable (_ channelId: String, _ content: String, _ token: String) async throws -> Void
        let sendPayloadMessage: @Sendable (_ channelId: String, _ payload: [String: Any], _ token: String) async throws -> Void
        let sendDM: @Sendable (_ userId: String, _ content: String) async throws -> Void
        let addReaction: @Sendable (_ channelId: String, _ messageId: String, _ emoji: String, _ token: String) async throws -> Void
        let deleteMessage: @Sendable (_ channelId: String, _ messageId: String, _ token: String) async throws -> Void
        let addRole: @Sendable (_ guildId: String, _ userId: String, _ roleId: String, _ token: String) async throws -> Void
        let removeRole: @Sendable (_ guildId: String, _ userId: String, _ roleId: String, _ token: String) async throws -> Void
        let timeoutMember: @Sendable (_ guildId: String, _ userId: String, _ seconds: Int, _ token: String) async throws -> Void
        let kickMember: @Sendable (_ guildId: String, _ userId: String, _ reason: String, _ token: String) async throws -> Void
        let moveMember: @Sendable (_ guildId: String, _ userId: String, _ channelId: String, _ token: String) async throws -> Void
        let sendWebhook: @Sendable (_ url: String, _ content: String) async throws -> Void
        let resolveChannelName: @Sendable (_ guildId: String, _ channelId: String) async -> String
        let resolveGuildName: @Sendable (_ guildId: String) async -> String?
        let log: @Sendable (_ message: String) -> Void
        let recordAutomationRun: @Sendable (_ ruleId: String, _ ruleName: String, _ eventKind: String, _ triggerUser: String, _ stepsCount: Int, _ status: String) -> Void
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

    #if DEBUG
    func markMessageHandledForTesting(_ messageId: String) {
        markHandled(messageId)
    }
    #endif

    private func markHandled(_ messageId: String) {
        handledMessageIds.insert(messageId)
        if handledMessageIds.count > 1000 {
            handledMessageIds = Set(Array(handledMessageIds).suffix(1000))
        }
    }

    // MARK: - Matching

    /// Returns the enabled rules whose Trigger and Filter set match `event`.
    /// Pure — no side effects, no actor state read.
    nonisolated func evaluate(event: SwiftBotEvent, in rules: [Automations.Rule]) -> [Automations.Rule] {
        rules.filter { rule in
            guard rule.enabled else { return false }
            guard Self.triggerMatches(rule.trigger, event: event) else { return false }
            return Self.filtersMatch(rule.filters, logic: rule.filterLogic, event: event)
        }
    }

    private nonisolated static func triggerMatches(_ trigger: Automations.Trigger, event: SwiftBotEvent) -> Bool {
        switch (trigger.kind, event.kind) {
        case (.userJoinedVoice, .join):
            if let cid = trigger.channelId, !cid.isEmpty {
                guard event.channelId == cid else { return false }
            }
            return true
        case (.userLeftVoice, .leave):
            if let cid = trigger.channelId, !cid.isEmpty {
                guard event.channelId == cid else { return false }
            }
            if let threshold = trigger.voiceDurationThreshold {
                guard (event.durationSeconds ?? 0) >= threshold else { return false }
            }
            return true
        case (.userMovedVoice, .move):
            if let cid = trigger.channelId, !cid.isEmpty {
                guard event.channelId == cid else { return false }
            }
            return true
        case (.messageCreated, .message):
            if let cid = trigger.channelId, !cid.isEmpty {
                guard event.channelId == cid else { return false }
            }
            return true
        case (.memberJoined, .memberJoin):
            return true
        case (.memberLeft, .memberLeave):
            return true
        case (.mediaAdded, .mediaAdded):
            if let cid = trigger.channelId, !cid.isEmpty {
                guard event.channelId == cid else { return false }
            }
            return true
        case (.reactionAdded, _):
            if let emoji = trigger.reactionEmoji, !emoji.isEmpty {
                return (event.messageContent ?? "") == emoji
            }
            return true
        case (.slashCommand, _):
            if let name = trigger.commandName, !name.isEmpty {
                return (event.messageContent ?? "").hasPrefix("/\(name)")
            }
            return true
        default:
            return false
        }
    }

    private nonisolated static func filtersMatch(
        _ filters: [Automations.Filter],
        logic: Automations.FilterLogic,
        event: SwiftBotEvent
    ) -> Bool {
        guard !filters.isEmpty else { return true }
        switch logic {
        case .all: return filters.allSatisfy { filterMatches($0, event: event) }
        case .any: return filters.contains { filterMatches($0, event: event) }
        }
    }

    private nonisolated static func filterMatches(
        _ filter: Automations.Filter,
        event: SwiftBotEvent
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

        case .userHasAnyRole:
            guard let eventRoleIds = event.memberRoleIds else { return false }
            let required = Set(filter.roleIds ?? [])
            guard !required.isEmpty else { return false }
            return !Set(eventRoleIds).isDisjoint(with: required)

        case .userHasAllRoles:
            guard let eventRoleIds = event.memberRoleIds else { return false }
            let required = Set(filter.roleIds ?? [])
            guard !required.isEmpty else { return false }
            return required.isSubset(of: Set(eventRoleIds))

        case .userHasNoneOfRoles:
            guard let eventRoleIds = event.memberRoleIds else { return false }
            let excluded = Set(filter.roleIds ?? [])
            guard !excluded.isEmpty else { return false }
            return Set(eventRoleIds).isDisjoint(with: excluded)

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
            // SwiftBotEvent doesn't carry reply state yet; treat as
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

        case .messageContainsSpamLink:
            let content = (event.messageContent ?? "").lowercased()
            let spamKeywords = ["free-discord-nitro", "discord.gift", "gift-nitro", "steam-promo", "crypto-drop", "free-nitro"]
            let containsSpamKeyword = spamKeywords.contains { content.contains($0) }
            let hasUrl = content.contains("http://") || content.contains("https://") || content.contains("www.")
            return hasUrl && containsSpamKeyword

        case .messageCapsPercentage:
            let content = event.messageContent ?? ""
            let letters = content.filter { $0.isLetter }
            guard !letters.isEmpty else { return false }
            let caps = letters.filter { $0.isUppercase }
            let percentage = (caps.count * 100) / letters.count
            let threshold = filter.intValue ?? 70
            return percentage >= threshold

        case .messageMentionsCount:
            let content = event.messageContent ?? ""
            let pings = content.components(separatedBy: "<@").count - 1
            let threshold = filter.intValue ?? 5
            return pings >= threshold
        }
    }

    // MARK: - Execution

    /// Runs every Step in `rule.steps` in order against `event`.
    func execute(rule: Automations.Rule, event: SwiftBotEvent, token: String?) async {
        guard let token else { return }
        var ctx = ExecutionContext(event: event)

        for step in rule.steps {
            await runStep(step, ctx: &ctx, token: token)
        }

        if ctx.eventHandled, let msgId = event.triggerMessageId {
            markHandled(msgId)
        }

        let statusString: String = {
            if ctx.errors.isEmpty {
                return "Success"
            } else {
                return "Failed: " + ctx.errors.joined(separator: " | ")
            }
        }()

        dependencies.recordAutomationRun(
            rule.id,
            rule.name,
            event.kind.rawValue,
            event.username,
            rule.steps.count,
            statusString
        )
    }

    private struct ExecutionContext {
        let event: SwiftBotEvent
        var eventHandled: Bool = false
        var errors: [String] = []
        /// Result of the most recent `aiTransform` step. Read by `{ai_output}`
        /// token substitution in any later step. Nil until an aiTransform step
        /// runs; overwritten by any subsequent aiTransform step.
        var aiOutput: String?
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
            await runLog(step, ctx: &ctx)
        case .webhook:
            await runWebhook(step, ctx: &ctx)
        case .delay:
            let s = max(0, step.delaySeconds ?? 0)
            if s > 0 { try? await Task.sleep(nanoseconds: UInt64(s) * 1_000_000_000) }
        case .aiTransform:
            await runAITransform(step, ctx: &ctx)
        }
    }

    // MARK: - Step: sendMessage

    private func runSendMessage(_ step: Automations.Step, ctx: inout ExecutionContext, token: String) async {
        let event = ctx.event

        // Resolve content: aiPrompt takes precedence if set.
        let rawContent: String
        if let prompt = step.aiPrompt, !prompt.isEmpty {
            let renderedPrompt = await render(prompt, event: event, aiOutput: ctx.aiOutput)
            let channelName = event.isDirectMessage
                ? "Direct Message"
                : await dependencies.resolveChannelName(event.triggerGuildId, event.triggerChannelId ?? event.channelId)
            let aiOutput = await aiService.generateStepAIReply(
                prompt: renderedPrompt,
                event: event,
                serverName: await dependencies.resolveGuildName(event.triggerGuildId),
                channelName: channelName
            ) ?? "(AI did not return a response)"
            rawContent = aiOutput
        } else {
            rawContent = await render(step.content ?? "", event: event, aiOutput: ctx.aiOutput)
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
                do {
                    _ = try await dependencies.sendPayloadMessage(cid, payload, token)
                    ctx.eventHandled = true
                } catch {
                    ctx.errors.append("sendPayloadMessage failed: \(error.localizedDescription)")
                }
            } else {
                await sendToFirstAvailable(rawContent, event: event, fallback: step.channelId, token: token, ctx: &ctx)
            }

        case .sameChannel:
            let cid = event.triggerChannelId ?? event.channelId
            guard !cid.isEmpty else { return }
            do {
                try await dependencies.sendMessage(cid, rawContent, token)
                ctx.eventHandled = true
            } catch {
                ctx.errors.append("sendMessage failed: \(error.localizedDescription)")
            }

        case .directMessage:
            guard !event.userId.isEmpty else { return }
            do {
                try await dependencies.sendDM(event.userId, rawContent)
                ctx.eventHandled = true
            } catch {
                ctx.errors.append("sendDM failed: \(error.localizedDescription)")
            }

        case .specificChannel:
            guard let cid = step.channelId, !cid.isEmpty else { return }
            do {
                try await dependencies.sendMessage(cid, rawContent, token)
                ctx.eventHandled = true
            } catch {
                ctx.errors.append("sendMessage failed: \(error.localizedDescription)")
            }
        }
    }

    private func sendToFirstAvailable(
        _ content: String,
        event: SwiftBotEvent,
        fallback: String?,
        token: String,
        ctx: inout ExecutionContext
    ) async {
        let cid = event.triggerChannelId ?? fallback ?? event.channelId
        guard !cid.isEmpty else { return }
        do {
            try await dependencies.sendMessage(cid, content, token)
            ctx.eventHandled = true
        } catch {
            ctx.errors.append("sendMessage failed: \(error.localizedDescription)")
        }
    }

    private nonisolated func defaultSendTarget(for event: SwiftBotEvent) -> Automations.SendTarget {
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
            do {
                _ = try await dependencies.addRole(event.guildId, event.userId, rid, token)
            } catch {
                ctx.errors.append("addRole failed: \(error.localizedDescription)")
            }
        case .removeRole:
            guard let rid = step.roleId, !rid.isEmpty else { return }
            do {
                _ = try await dependencies.removeRole(event.guildId, event.userId, rid, token)
            } catch {
                ctx.errors.append("removeRole failed: \(error.localizedDescription)")
            }
        case .timeout:
            let s = max(1, step.timeoutSeconds ?? 60)
            do {
                _ = try await dependencies.timeoutMember(event.guildId, event.userId, s, token)
            } catch {
                ctx.errors.append("timeoutMember failed: \(error.localizedDescription)")
            }
        case .kick:
            do {
                _ = try await dependencies.kickMember(event.guildId, event.userId, step.kickReason ?? "", token)
            } catch {
                ctx.errors.append("kickMember failed: \(error.localizedDescription)")
            }
        case .moveVoice:
            guard let cid = step.targetVoiceChannelId, !cid.isEmpty else { return }
            do {
                _ = try await dependencies.moveMember(event.guildId, event.userId, cid, token)
            } catch {
                ctx.errors.append("moveMember failed: \(error.localizedDescription)")
            }
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
            do {
                _ = try await dependencies.deleteMessage(cid, mid, token)
            } catch {
                ctx.errors.append("deleteMessage failed: \(error.localizedDescription)")
            }
        case .react:
            guard let emoji = step.reactEmoji, !emoji.isEmpty else { return }
            do {
                _ = try await dependencies.addReaction(cid, mid, emoji, token)
            } catch {
                ctx.errors.append("addReaction failed: \(error.localizedDescription)")
            }
        }
        ctx.eventHandled = true
    }

    // MARK: - Step: log

    private func runLog(_ step: Automations.Step, ctx: inout ExecutionContext) async {
        let text = await render(step.logText ?? "", event: ctx.event, aiOutput: ctx.aiOutput)
        guard !text.isEmpty else { return }
        dependencies.log(text)
    }

    // MARK: - Step: webhook

    private func runWebhook(_ step: Automations.Step, ctx: inout ExecutionContext) async {
        guard let url = step.webhookUrl, !url.isEmpty else { return }
        let body = await render(step.webhookContent ?? "", event: ctx.event, aiOutput: ctx.aiOutput)
        do {
            _ = try await dependencies.sendWebhook(url, body)
        } catch {
            ctx.errors.append("sendWebhook failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Step: aiTransform

    private func runAITransform(_ step: Automations.Step, ctx: inout ExecutionContext) async {
        let prompt = (step.aiPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            ctx.errors.append("aiTransform: prompt was empty; step skipped")
            return
        }

        let event = ctx.event
        let renderedPrompt = await render(prompt, event: event, aiOutput: ctx.aiOutput)
        let channelName = event.isDirectMessage
            ? "Direct Message"
            : await dependencies.resolveChannelName(event.triggerGuildId, event.triggerChannelId ?? event.channelId)
        let reply = await aiService.generateStepAIReply(
            prompt: renderedPrompt,
            event: event,
            serverName: await dependencies.resolveGuildName(event.triggerGuildId),
            channelName: channelName
        )
        // Store regardless of success: a nil reply collapses {ai_output} to
        // "" downstream, matching the convention used by missing event tokens.
        ctx.aiOutput = reply
        if reply == nil {
            ctx.errors.append("aiTransform: Apple Intelligence returned no response")
        }
    }

    // MARK: - Variable substitution

    private func render(_ template: String, event: SwiftBotEvent, aiOutput: String? = nil) async -> String {
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
        out = out.replacingOccurrences(of: Automations.Variable.aiOutput.rawValue, with: aiOutput ?? "")
        return out
    }

    private nonisolated func formatDuration(_ seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "0s" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    /// Safely dry-runs and traces rule matching and step execution entirely in-memory.
    func simulate(rule: Automations.Rule, event: SwiftBotEvent) async -> Automations.SimulationResult {
        // 1. Check trigger
        let triggerMatched = Self.triggerMatches(rule.trigger, event: event)
        
        // 2. Evaluate filters and record traces
        var filterTraces: [Automations.FilterTrace] = []
        var filtersMatched = true
        
        for filter in rule.filters {
            let matched = Self.filterMatches(filter, event: event)
            
            // Generate detailed trace info
            let detail: String = {
                switch filter.kind {
                case .messageCapsPercentage:
                    let content = event.messageContent ?? ""
                    let letters = content.filter { $0.isLetter }
                    if letters.isEmpty {
                        return "0% caps (no letters in message)"
                    } else {
                        let caps = letters.filter { $0.isUppercase }
                        let pct = (caps.count * 100) / letters.count
                        return "\(pct)% caps (threshold \(filter.intValue ?? 70)%)"
                    }
                case .messageMentionsCount:
                    let content = event.messageContent ?? ""
                    let pings = content.components(separatedBy: "<@").count - 1
                    return "\(pings) ping(s) (threshold \(filter.intValue ?? 5))"
                case .messageContainsSpamLink:
                    let content = event.messageContent ?? ""
                    let spamKeywords = ["free-discord-nitro", "discord.gift", "gift-nitro", "steam-promo", "crypto-drop", "free-nitro"]
                    let hasKeyword = spamKeywords.contains { content.lowercased().contains($0) }
                    let hasUrl = content.contains("http://") || content.contains("https://") || content.contains("www.")
                    return "Link: \(hasUrl ? "yes" : "no"), Spam Keyword: \(hasKeyword ? "yes" : "no")"
                default:
                    return matched ? "Filter matched criteria" : "Filter did not match criteria"
                }
            }()
            
            filterTraces.append(Automations.FilterTrace(filterId: filter.id, kind: filter.kind, matched: matched, detail: detail))
            
            if !matched && rule.filterLogic == .all {
                filtersMatched = false
            }
        }
        
        if rule.filterLogic == .any && !rule.filters.isEmpty {
            filtersMatched = filterTraces.contains { $0.matched }
        }
        
        // 3. Dry-run steps if overall trigger and filters passed
        var stepTraces: [Automations.StepTrace] = []
        let shouldExecute = triggerMatched && (rule.filters.isEmpty || filtersMatched)
        
        if shouldExecute {
            let accumulator = SimTraceAccumulator()
            
            let dryRunDeps = AutomationService.Dependencies(
                sendMessage: { c, m, t in
                    accumulator.appendStep(kind: .sendMessage, detail: "Would send message to channel/user: \"\(m)\"")
                },
                sendPayloadMessage: { c, p, t in
                    accumulator.appendStep(kind: .sendMessage, detail: "Would send rich embed/payload message")
                },
                sendDM: { u, c in
                    accumulator.appendStep(kind: .sendMessage, detail: "Would send DM to user \(u): \"\(c)\"")
                },
                addReaction: { c, m, e, t in
                    accumulator.appendStep(kind: .modifyMessage, detail: "Would add reaction \(e) to message \(m)")
                },
                deleteMessage: { c, m, t in
                    accumulator.appendStep(kind: .modifyMessage, detail: "Would delete message \(m)")
                },
                addRole: { g, u, r, t in
                    accumulator.appendStep(kind: .modifyMember, detail: "Would add role \(r) to user \(u)")
                },
                removeRole: { g, u, r, t in
                    accumulator.appendStep(kind: .modifyMember, detail: "Would remove role \(r) from user \(u)")
                },
                timeoutMember: { g, u, s, t in
                    accumulator.appendStep(kind: .modifyMember, detail: "Would timeout user \(u) for \(s) seconds")
                },
                kickMember: { g, u, reason, t in
                    accumulator.appendStep(kind: .modifyMember, detail: "Would kick user \(u) (reason: \(reason))")
                },
                moveMember: { g, u, c, t in
                    accumulator.appendStep(kind: .modifyMember, detail: "Would move user \(u) to voice channel \(c)")
                },
                sendWebhook: { url, c in
                    accumulator.appendStep(kind: .webhook, detail: "Would POST to webhook: \(url)")
                },
                resolveChannelName: { _, _ in "simulated-channel" },
                resolveGuildName: { _ in "simulated-guild" },
                log: { _ in },
                recordAutomationRun: { _, _, _, _, _, _ in }
            )
            
            let simService = AutomationService(aiService: self.aiService, dependencies: dryRunDeps)
            await simService.execute(rule: rule, event: event, token: "sim-token")
            
            let ranSteps = accumulator.steps
            for (index, step) in rule.steps.enumerated() {
                let detail = index < ranSteps.count ? ranSteps[index].detail : "Step skipped or failed"
                stepTraces.append(Automations.StepTrace(stepId: step.id, kind: step.kind, executed: index < ranSteps.count, detail: detail))
            }
        } else {
            for step in rule.steps {
                stepTraces.append(Automations.StepTrace(stepId: step.id, kind: step.kind, executed: false, detail: "Step bypassed (filters/trigger did not match)"))
            }
        }
        
        return Automations.SimulationResult(
            triggerMatched: triggerMatched,
            filtersMatched: filtersMatched || rule.filters.isEmpty,
            filterTraces: filterTraces,
            stepTraces: stepTraces
        )
    }
}

private final class SimTraceAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [Automations.StepTrace] = []
    
    var steps: [Automations.StepTrace] {
        lock.lock()
        defer { lock.unlock() }
        return _steps
    }
    
    func appendStep(kind: Automations.StepKind, detail: String) {
        lock.lock()
        defer { lock.unlock() }
        _steps.append(Automations.StepTrace(stepId: UUID().uuidString, kind: kind, executed: true, detail: detail))
    }
}
