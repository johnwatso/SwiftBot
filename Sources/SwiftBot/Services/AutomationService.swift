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
        var canExecute: @Sendable () async -> Bool = { true }
        var scheduledRuleStillValid: @Sendable (_ rule: Automations.Rule) async -> Bool = { _ in true }
        var scheduledEventStillValid: @Sendable (_ trigger: Automations.Trigger, _ occurrenceId: String, _ token: String) async -> Bool = { _, _, _ in true }
        let sendMessage: @Sendable (_ channelId: String, _ content: String, _ token: String) async throws -> Void
        let sendPayloadMessage: @Sendable (_ channelId: String, _ payload: [String: Any], _ token: String) async throws -> Void
        let sendDM: @Sendable (_ userId: String, _ content: String) async throws -> Void
        let addReaction: @Sendable (_ channelId: String, _ messageId: String, _ emoji: String, _ token: String) async throws -> Void
        let deleteMessage: @Sendable (_ channelId: String, _ messageId: String, _ token: String) async throws -> Void
        let addRole: @Sendable (_ guildId: String, _ userId: String, _ roleId: String, _ token: String) async throws -> Void
        let removeRole: @Sendable (_ guildId: String, _ userId: String, _ roleId: String, _ token: String) async throws -> Void
        let timeoutMember: @Sendable (_ guildId: String, _ userId: String, _ seconds: Int, _ token: String) async throws -> Void
        let kickMember: @Sendable (_ guildId: String, _ userId: String, _ reason: String, _ token: String) async throws -> Void
        var banMember: @Sendable (_ guildId: String, _ userId: String, _ reason: String, _ deleteMessageSeconds: Int, _ token: String) async throws -> Void = { _, _, _, _, _ in
            throw NSError(domain: "AutomationService", code: 503, userInfo: [NSLocalizedDescriptionKey: "Banning is unavailable"])
        }
        var removeTimeout: @Sendable (_ guildId: String, _ userId: String, _ token: String) async throws -> Void = { _, _, _ in
            throw NSError(domain: "AutomationService", code: 503, userInfo: [NSLocalizedDescriptionKey: "Removing timeouts is unavailable"])
        }
        let moveMember: @Sendable (_ guildId: String, _ userId: String, _ channelId: String, _ token: String) async throws -> Void
        let sendWebhook: @Sendable (_ url: String, _ content: String) async throws -> Void
        var resolveWebhookURL: @Sendable (_ credentialId: String) -> String? = { AutomationWebhookVault.url(for: $0) }
        let resolveChannelName: @Sendable (_ guildId: String, _ channelId: String) async -> String
        let resolveGuildName: @Sendable (_ guildId: String) async -> String?
        let log: @Sendable (_ message: String) -> Void
        let recordAutomationRun:
            @Sendable (_ ruleId: String, _ ruleName: String, _ eventKind: String, _ triggerUser: String, _ stepsCount: Int, _ status: String) -> Void
    }

    private let aiService: DiscordAIService
    private let dependencies: Dependencies
    private var handledMessageIds: Set<String> = []
    private var journal: AutomationExecutionJournal
    private var memory = AutomationMemory()
    private var memoryReadable = true
    private var memoryURL: URL? { journal.fileURL.map(AutomationMemory.url) }
    private var paused = false
    private var executionGeneration = 0
    private var activeExecutions: Set<String> = []
    private var activeEffects = 0
    private let logger = Logger(subsystem: "com.swiftbot", category: "automations")

    init(aiService: DiscordAIService, dependencies: Dependencies, journalURL: URL? = nil) {
        self.aiService = aiService
        self.dependencies = dependencies
        self.journal = AutomationExecutionJournal(fileURL: journalURL)
        if let url = journalURL.map(AutomationMemory.url), FileManager.default.fileExists(atPath: url.path) {
            do { self.memory = try JSONDecoder().decode(AutomationMemory.self, from: Data(contentsOf: url)) } catch { self.memoryReadable = false }
        }
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
    nonisolated func evaluate(event: SwiftBotEvent, in rules: [Automations.Rule], memory: AutomationMemory = AutomationMemory()) -> [Automations.Rule] {
        rules.filter { rule in
            guard rule.enabled else { return false }
            guard Self.triggerMatches(rule.trigger, event: event) else { return false }
            return Self.conditionsMatch(
                rule.filters, groups: rule.conditionGroups ?? [], logic: rule.filterLogic, event: event, memory: memory, ruleId: rule.id)
        }
    }

    private nonisolated static func triggerMatches(_ trigger: Automations.Trigger, event: SwiftBotEvent) -> Bool {
        if let guild = trigger.guildId, !guild.isEmpty, guild != event.guildId { return false }
        let synthetic: Automations.TriggerKind? = {
            if case .message(let payload) = event { return payload.automationTrigger }; return nil
        }()
        if trigger.kind == .schedule || trigger.kind == .scheduledEvent { return synthetic == trigger.kind }
        if let synthetic, synthetic != trigger.kind { return false }
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
            guard synthetic == nil else { return false }
            if let cid = trigger.channelId, !cid.isEmpty {
                guard event.channelId == cid else { return false }
            }
            return synthetic == nil
        case (.memberJoined, .memberJoin):
            return true
        case (.memberLeft, .memberLeave):
            return true
        case (.mediaAdded, .mediaAdded):
            if let cid = trigger.channelId, !cid.isEmpty {
                guard event.channelId == cid else { return false }
            }
            return true
        case (.reactionAdded, .message):
            guard synthetic == .reactionAdded else { return false }
            if let emoji = trigger.reactionEmoji, !emoji.isEmpty {
                return reactionEmojiMatches(emoji, event.messageContent ?? "")
            }
            return true
        case (.slashCommand, .message):
            guard synthetic == .slashCommand else { return false }
            let name = (trigger.commandName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
            guard !name.isEmpty else { return true }
            let content = (event.messageContent ?? "").lowercased()
            return content == "/" + name || content.hasPrefix("/" + name + " ")
        default:
            return false
        }
    }

    /// Discord reports a custom emoji by name and a Unicode one by character,
    /// sometimes without the variation selector a typed emoji carries.
    nonisolated static func reactionEmojiMatches(_ expected: String, _ actual: String) -> Bool {
        func key(_ value: String) -> String {
            var text = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FE0F}", with: "")
            // <:name:id> or <a:name:id>
            if text.hasPrefix("<"), text.hasSuffix(">") {
                let parts = text.dropFirst().dropLast().split(separator: ":")
                if parts.count >= 2 { text = String(parts[parts.count - 2]) }
            }
            return text.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        }
        return key(expected) == key(actual)
    }

    private nonisolated static func filtersMatch(
        _ filters: [Automations.Filter],
        logic: Automations.FilterLogic,
        event: SwiftBotEvent, memory: AutomationMemory = AutomationMemory(), ruleId: String = ""
    ) -> Bool {
        guard !filters.isEmpty else { return true }
        switch logic {
        case .all: return filters.allSatisfy { filterMatches($0, event: event, memory: memory, ruleId: ruleId) }
        case .any: return filters.contains { filterMatches($0, event: event, memory: memory, ruleId: ruleId) }
        case .none: return filters.allSatisfy { !filterMatches($0, event: event, memory: memory, ruleId: ruleId) }
        }
    }

    private nonisolated static func filterMatches(
        _ filter: Automations.Filter,
        event: SwiftBotEvent, memory: AutomationMemory = AutomationMemory(), ruleId: String = ""
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
            guard case .message(let payload) = event else { return false }
            return (payload.isReply ?? false) == (filter.boolValue ?? true)

        case .fromBot:
            return (filter.boolValue ?? false) == (event.authorIsBot ?? false)

        case .minVoiceDurationSeconds:
            let min = filter.intValue ?? 0
            return (event.durationSeconds ?? 0) >= min

        case .reactionEmoji:
            guard case .message(let payload) = event, payload.automationTrigger == .reactionAdded else { return false }
            return (filter.text ?? "").isEmpty || reactionEmojiMatches(filter.text ?? "", payload.content)

        case .mediaSource:
            let target = filter.text ?? ""
            return target.isEmpty || event.mediaSourceName == target

        case .counterAtLeast, .counterBelow:
            let count = memory.count(name: filter.counterName ?? "", scope: filter.counterScope ?? .user, ruleId: ruleId, event: event)
            return filter.kind == .counterAtLeast ? count >= (filter.intValue ?? 1) : count < (filter.intValue ?? 1)
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
    /// Returns only after already-started effects have settled. Delays and
    /// computation cannot pass their next step boundary once generation changes.
    func pauseAndDrain() async -> Bool {
        paused = true
        executionGeneration += 1
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while activeEffects > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return activeEffects == 0
    }

    func resume() {
        paused = false
        journal.reload()
        reloadMemory()
    }

    func resumePendingExecutions(token: String?, rules: [Automations.Rule]) {
        let enabled = Set(rules.filter(\.enabled).map(\.id))
        for record in journal.records.values where !record.completed {
            if record.needsReview {
                dependencies.recordAutomationRun(
                    record.rule.id, record.rule.name, record.event.kind.rawValue,
                    record.event.username, record.nextStep, "Needs review: an action was not acknowledged before recovery"
                )
            } else if enabled.contains(record.rule.id) {
                scheduleContinuation(id: record.id, token: token)
            }
        }
    }

    /// Runs live matches with moderation first. Once a matched moderation rule
    /// deletes the message or removes the member, ordinary automations for the
    /// same event are skipped. Each run returns at its first pending delay, so
    /// callers on the Gateway receive path are never held for the wait.
    func dispatch(event: SwiftBotEvent, rules: [Automations.Rule], token: String?) async {
        var moderated = false
        for rule in matchingRules(event: event, in: rules.filter { $0.category == .moderation }) {
            await execute(rule: rule, event: event, token: token)
            if rule.steps.contains(where: \.isDestructiveModeration) { moderated = true }
        }
        guard !moderated else { return }
        for rule in matchingRules(event: event, in: rules.filter { $0.category != .moderation }) {
            await execute(rule: rule, event: event, token: token)
        }
    }

    /// Runs `rule` until it finishes or reaches a pending delay. A delayed run
    /// is already journaled, and continues in its own task.
    func execute(rule: Automations.Rule, event: SwiftBotEvent, token: String?) async {
        let id = rule.id + ":" + (event.occurrenceId ?? event.triggerMessageId ?? UUID().uuidString)
        if let checkpoint = journal.records[id] { await executeCheckpoint(checkpoint, token: token); return }
        guard token != nil, !paused, memoryReadable, await dependencies.canExecute() else { return }
        if let checkpoint = journal.records[id] { await executeCheckpoint(checkpoint, token: token); return }
        let checkpoint = AutomationExecutionCheckpoint(id: id, rule: AutomationWebhookVault.seal(rule), event: event)
        await executeCheckpoint(checkpoint, token: token)
    }

    /// Continues a journaled run from its latest saved state once any run
    /// still holding the same ID has returned.
    private func scheduleContinuation(id: String, token: String?) {
        Task {
            while self.activeExecutions.contains(id) {
                guard !self.paused, !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let latest = self.journal.records[id] else { return }
            await self.executeCheckpoint(latest, token: token, waitsInline: true)
        }
    }

    /// A caller-facing run (`waitsInline == false`) hands a pending delay to a
    /// continuation instead of sleeping, so it returns promptly.
    private func executeCheckpoint(_ initial: AutomationExecutionCheckpoint, token: String?, waitsInline: Bool = false) async {
        guard let token, memoryReadable, !paused, !initial.completed, !initial.needsReview,
            !activeExecutions.contains(initial.id), await dependencies.canExecute()
        else { return }
        let generation = executionGeneration
        guard activeExecutions.insert(initial.id).inserted else { return }
        defer { activeExecutions.remove(initial.id) }
        var checkpoint = initial
        var ctx = ExecutionContext(event: checkpoint.event)
        ctx.eventHandled = checkpoint.eventHandled
        ctx.aiOutput = checkpoint.aiOutput
        ctx.errors = checkpoint.errors
        ctx.ruleId = checkpoint.rule.id
        var branches = checkpoint.branchStack ?? []
        do {
            try checkpoint.rule.validate()
            if checkpoint.admitted != true {
                let admissionId = "admission:" + initial.id
                if memory.appliedSteps[admissionId] == nil, let cooldown = checkpoint.rule.cooldown {
                    let key = AutomationMemory.scopeKey(name: checkpoint.rule.id, scope: cooldown.scope, ruleId: checkpoint.rule.id, event: checkpoint.event)
                    if (memory.cooldowns[key] ?? .distantPast) > Date() {
                        checkpoint.completed = true
                        checkpoint.errors = ["Skipped: cooldown"]
                        try journal.save(checkpoint)
                        dependencies.recordAutomationRun(
                            checkpoint.rule.id, checkpoint.rule.name, checkpoint.event.kind.rawValue, checkpoint.event.username, 0, "Skipped: cooldown")
                        return
                    }
                    var updated = memory
                    updated.cooldowns[key] = Date().addingTimeInterval(Double(cooldown.seconds))
                    updated.appliedSteps[admissionId] = Date()
                    try saveMemory(updated)
                }
                checkpoint.admitted = true
            }
            try journal.save(checkpoint)
            while checkpoint.nextStep < checkpoint.rule.steps.count {
                guard !paused, executionGeneration == generation, !Task.isCancelled,
                    await dependencies.canExecute()
                else { return }
                if let wake = checkpoint.wakeAt, wake > Date() {
                    guard waitsInline else {
                        deferWait(checkpoint, ctx: ctx, token: token)
                        return
                    }
                    try? await Task.sleep(for: .seconds(min(1, wake.timeIntervalSinceNow)))
                    continue
                }
                checkpoint.wakeAt = nil
                let index = checkpoint.nextStep
                let step = checkpoint.rule.steps[index]
                let active = branches.last?.active ?? true
                if [.branch, .otherwise, .endBranch].contains(step.kind) {
                    let detail = processBranch(step, event: ctx.event, ruleId: ctx.ruleId, branches: &branches)
                    checkpoint.branchStack = branches
                    checkpoint.traces = (checkpoint.traces ?? []) + [Automations.StepTrace(stepId: step.id, kind: step.kind, executed: true, detail: detail)]
                    checkpoint.nextStep += 1
                    try journal.save(checkpoint)
                    continue
                }
                if !active {
                    checkpoint.traces =
                        (checkpoint.traces ?? []) + [
                            Automations.StepTrace(stepId: step.id, kind: step.kind, executed: false, detail: "Skipped: other branch selected")
                        ]
                    checkpoint.nextStep += 1
                    try journal.save(checkpoint)
                    continue
                }
                if step.kind == .delay {
                    checkpoint.nextStep += 1
                    checkpoint.traces =
                        (checkpoint.traces ?? []) + [
                            Automations.StepTrace(stepId: step.id, kind: step.kind, executed: true, detail: "Wait \(step.delaySeconds ?? 0) seconds")
                        ]
                    checkpoint.wakeAt = Date().addingTimeInterval(Double(max(0, step.delaySeconds ?? 0)))
                    try journal.save(checkpoint)
                    continue
                }
                let isEffect = [.sendMessage, .modifyMember, .modifyMessage, .webhook].contains(step.kind)
                if isEffect, [.schedule, .scheduledEvent].contains(checkpoint.rule.trigger.kind) {
                    let ruleValid = await dependencies.scheduledRuleStillValid(checkpoint.rule)
                    guard !paused, generation == executionGeneration, await dependencies.canExecute() else { return }
                    if !ruleValid {
                        checkpoint.errors.append("Cancelled: scheduled rule was disabled, removed, or edited")
                        checkpoint.completed = true
                        try journal.save(checkpoint)
                        dependencies.recordAutomationRun(
                            checkpoint.rule.id, checkpoint.rule.name, checkpoint.event.kind.rawValue,
                            checkpoint.event.username, checkpoint.nextStep, "Cancelled: rule changed")
                        return
                    }
                }
                if isEffect, checkpoint.rule.trigger.kind == .scheduledEvent {
                    let eventValid = await dependencies.scheduledEventStillValid(checkpoint.rule.trigger, checkpoint.event.messageId ?? "", token)
                    guard !paused, generation == executionGeneration, await dependencies.canExecute() else { return }
                    guard eventValid else {
                        checkpoint.errors.append("Announcement stopped: event could not be verified, was removed, cancelled, or rescheduled")
                        checkpoint.completed = true
                        try journal.save(checkpoint)
                        dependencies.recordAutomationRun(
                            checkpoint.rule.id, checkpoint.rule.name, checkpoint.event.kind.rawValue, checkpoint.event.username, checkpoint.nextStep,
                            "Cancelled: event changed")
                        return
                    }
                }
                checkpoint.inFlightStep = isEffect ? index : nil
                try journal.save(checkpoint)
                if isEffect { activeEffects += 1 }
                let errorCount = ctx.errors.count
                if step.kind == .incrementCounter || step.kind == .resetCounter {
                    do { try applyCounter(step, event: ctx.event, ruleId: ctx.ruleId, executionId: initial.id) } catch {
                        ctx.errors.append("Counter could not be saved: " + error.localizedDescription)
                    }
                } else {
                    await runStep(step, ctx: &ctx, token: token)
                }
                let failed = ctx.errors.count > errorCount
                checkpoint.traces =
                    (checkpoint.traces ?? []) + [
                        Automations.StepTrace(
                            stepId: step.id, kind: step.kind, executed: !failed,
                            detail: failed ? ctx.errors.suffix(from: errorCount).joined(separator: " | ") : "Completed")
                    ]
                if isEffect { activeEffects -= 1 }
                // A superseded generation can finish its currently admitted
                // effect, but cannot begin another one or overwrite imported state.
                guard executionGeneration == generation || (paused && isEffect) else { return }
                checkpoint.nextStep += 1
                checkpoint.inFlightStep = nil
                checkpoint.eventHandled = ctx.eventHandled
                checkpoint.aiOutput = ctx.aiOutput
                checkpoint.errors = ctx.errors
                try journal.save(checkpoint)
                if failed && checkpoint.rule.failurePolicy == .stopOnError {
                    checkpoint.nextStep = checkpoint.rule.steps.count
                    checkpoint.completed = true
                    try journal.save(checkpoint)
                    break
                }
            }
            // The final delay still has a due time even when it is the last step.
            while let wake = checkpoint.wakeAt, wake > Date() {
                guard !paused, generation == executionGeneration, !Task.isCancelled else { return }
                guard waitsInline else {
                    deferWait(checkpoint, ctx: ctx, token: token)
                    return
                }
                try? await Task.sleep(for: .seconds(min(1, wake.timeIntervalSinceNow)))
            }
            checkpoint.completed = true
            checkpoint.wakeAt = nil
            try journal.save(checkpoint)
            if ctx.eventHandled, let id = checkpoint.event.triggerMessageId { markHandled(id) }
            dependencies.recordAutomationRun(
                checkpoint.rule.id, checkpoint.rule.name,
                checkpoint.event.kind.rawValue, checkpoint.event.username, checkpoint.rule.steps.count,
                ctx.errors.isEmpty ? "Success" : "Failed: " + ctx.errors.joined(separator: " | ")
            )
        } catch {
            dependencies.log("Automation paused: checkpoint could not be saved (" + error.localizedDescription + ")")
        }
    }

    /// The checkpoint is already saved with its `wakeAt`. Decide now whether
    /// the triggering message counts as handled, because the caller acts on
    /// that before the delay ends: it does if a step already answered it, or
    /// if a send step is still to come.
    private func deferWait(_ checkpoint: AutomationExecutionCheckpoint, ctx: ExecutionContext, token: String) {
        let repliesLater = checkpoint.rule.steps.dropFirst(checkpoint.nextStep).contains { $0.kind == .sendMessage }
        if ctx.eventHandled || repliesLater, let id = checkpoint.event.triggerMessageId { markHandled(id) }
        scheduleContinuation(id: checkpoint.id, token: token)
    }

    private struct ExecutionContext {
        let event: SwiftBotEvent
        var eventHandled: Bool = false
        var errors: [String] = []
        /// Result of the most recent `aiTransform` step. Read by `{ai_output}`
        /// token substitution in any later step. Nil until an aiTransform step
        /// runs; overwritten by any subsequent aiTransform step.
        var aiOutput: String?
        var ruleId: String = ""
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
        case .branch, .otherwise, .endBranch, .incrementCounter, .resetCounter: break
        }
    }

    // MARK: - Step: sendMessage

    private func runSendMessage(_ step: Automations.Step, ctx: inout ExecutionContext, token: String) async {
        let event = ctx.event

        // Resolve content: aiPrompt takes precedence if set.
        let rawContent: String
        if let prompt = step.aiPrompt, !prompt.isEmpty {
            let renderedPrompt = await render(prompt, event: event, aiOutput: ctx.aiOutput)
            let channelName =
                event.isDirectMessage
                ? "Direct Message"
                : await dependencies.resolveChannelName(event.triggerGuildId, event.triggerChannelId ?? event.channelId)
            let aiOutput =
                await aiService.generateStepAIReply(
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
        if let embed = step.embed {
            do {
                let payload = try await embedPayload(embed, content: rawContent, event: event, aiOutput: ctx.aiOutput)
                let channel = target == .specificChannel ? (step.channelId ?? "") : (event.triggerChannelId ?? event.channelId)
                guard !channel.isEmpty, target != .directMessage else { ctx.errors.append("Embeds need a destination channel"); return }
                nonisolated(unsafe) var message = payload
                if target == .replyToTrigger, event.hasReplyableMessage, let id = event.triggerMessageId {
                    message["message_reference"] = ["message_id": id, "fail_if_not_exists": false]
                }
                try await dependencies.sendPayloadMessage(channel, message, token)
                ctx.eventHandled = true
            } catch { ctx.errors.append("sendEmbed failed: " + error.localizedDescription) }
            return
        }

        switch target {
        case .replyToTrigger:
            if event.hasReplyableMessage, let mid = event.triggerMessageId,
                let cid = event.triggerChannelId, !cid.isEmpty {
                let payload: [String: Any] = [
                    "content": rawContent,
                    "message_reference": [
                        "message_id": mid,
                        "channel_id": cid,
                        "fail_if_not_exists": false,
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
            let s = step.timeoutSeconds ?? 60
            do {
                try step.validate()
                _ = try await dependencies.timeoutMember(event.guildId, event.userId, s, token)
            } catch {
                ctx.errors.append("timeoutMember failed: \(error.localizedDescription)")
            }
        case .kick:
            let reason = await render(step.kickReason ?? "", event: event, aiOutput: ctx.aiOutput)
            do {
                _ = try await dependencies.kickMember(event.guildId, event.userId, reason, token)
            } catch {
                ctx.errors.append("kickMember failed: \(error.localizedDescription)")
            }
        case .ban:
            let reason = await render(step.kickReason ?? "", event: event, aiOutput: ctx.aiOutput)
            do {
                try step.validate()
                try await dependencies.banMember(event.guildId, event.userId, reason, step.banDeleteMessageSeconds ?? 0, token)
            } catch {
                ctx.errors.append("banMember failed: \(error.localizedDescription)")
            }
        case .removeTimeout:
            do {
                try await dependencies.removeTimeout(event.guildId, event.userId, token)
            } catch {
                ctx.errors.append("removeTimeout failed: \(error.localizedDescription)")
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
        let inline = (step.webhookUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = inline.isEmpty ? step.webhookCredentialId.flatMap(dependencies.resolveWebhookURL) : inline, !url.isEmpty else {
            if !(step.webhookCredentialId ?? "").isEmpty {
                ctx.errors.append("sendWebhook failed: the saved webhook URL is missing on this Mac")
            }
            return
        }
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
        if case .message(let payload) = event {
            for (token, value) in [
                ("{eventName}", payload.eventName), ("{eventDescription}", payload.eventDescription), ("{eventURL}", payload.eventURL),
                ("{eventStart}", payload.eventStart),
            ] { out = out.replacingOccurrences(of: token, with: value ?? "") }
        }
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
            let matched = Self.filterMatches(filter, event: event, memory: memory, ruleId: rule.id)

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

        filtersMatched = Self.conditionsMatch(
            rule.filters, groups: rule.conditionGroups ?? [], logic: rule.filterLogic, event: event, memory: memory, ruleId: rule.id)
        // 3. Dry-run steps if overall trigger and filters passed
        var stepTraces: [Automations.StepTrace] = []
        var diagnostics: [String] = []
        for group in rule.conditionGroups ?? [] {
            let nested = (rule.conditionGroups ?? []).filter { candidate in
                var parent = candidate.parentId
                var depth = 0
                while let id = parent, depth < 32 {
                    if id == group.id { return true }
                    parent = rule.conditionGroups?.first { $0.id == id }?.parentId
                    depth += 1
                }
                return false
            }
            let result = Self.conditionsMatch(
                group.filters,
                groups: nested.map { value in
                    var copy = value
                    if copy.parentId == group.id { copy.parentId = nil }
                    return copy
                }, logic: group.logic, event: event, memory: memory, ruleId: rule.id)
            diagnostics.append("Group (" + group.logic.rawValue + "): " + (result ? "matched" : "did not match"))
        }
        var cooldownActive = false
        if let cooldown = rule.cooldown {
            let key = AutomationMemory.scopeKey(name: rule.id, scope: cooldown.scope, ruleId: rule.id, event: event)
            let remaining = (memory.cooldowns[key] ?? .distantPast).timeIntervalSinceNow
            cooldownActive = remaining > 0
            diagnostics.append(cooldownActive ? "Cooldown: \(Int(ceil(remaining))) seconds remaining" : "Cooldown: ready")
        }
        let shouldExecute = triggerMatched && filtersMatched && !cooldownActive

        if shouldExecute {
            let accumulator = SimTraceAccumulator()

            let dryRunDeps = AutomationService.Dependencies(
                sendMessage: { _, m, _ in
                    accumulator.appendStep(kind: .sendMessage, detail: "Would send message to channel/user: \"\(m)\"")
                },
                sendPayloadMessage: { _, _, _ in
                    accumulator.appendStep(kind: .sendMessage, detail: "Would send rich embed/payload message")
                },
                sendDM: { u, c in
                    accumulator.appendStep(kind: .sendMessage, detail: "Would send DM to user \(u): \"\(c)\"")
                },
                addReaction: { _, m, e, _ in
                    accumulator.appendStep(kind: .modifyMessage, detail: "Would add reaction \(e) to message \(m)")
                },
                deleteMessage: { _, m, _ in
                    accumulator.appendStep(kind: .modifyMessage, detail: "Would delete message \(m)")
                },
                addRole: { _, u, r, _ in
                    accumulator.appendStep(kind: .modifyMember, detail: "Would add role \(r) to user \(u)")
                },
                removeRole: { _, u, r, _ in
                    accumulator.appendStep(kind: .modifyMember, detail: "Would remove role \(r) from user \(u)")
                },
                timeoutMember: { _, u, s, _ in
                    accumulator.appendStep(kind: .modifyMember, detail: "Would timeout user \(u) for \(s) seconds")
                },
                kickMember: { _, u, reason, _ in
                    accumulator.appendStep(kind: .modifyMember, detail: "Would kick user \(u) (reason: \(reason))")
                },
                banMember: { _, u, reason, seconds, _ in
                    accumulator.appendStep(kind: .modifyMember, detail: "Would ban user \(u) (reason: \(reason)); delete \(seconds)s of recent messages")
                },
                removeTimeout: { _, u, _ in
                    accumulator.appendStep(kind: .modifyMember, detail: "Would remove timeout from user \(u)")
                },
                moveMember: { _, u, c, _ in
                    accumulator.appendStep(kind: .modifyMember, detail: "Would move user \(u) to voice channel \(c)")
                },
                sendWebhook: { url, _ in
                    // The URL usually holds the webhook's token; show only its host.
                    accumulator.appendStep(kind: .webhook, detail: "Would POST to webhook at \(URL(string: url)?.host() ?? "saved URL")")
                },
                resolveChannelName: { _, _ in "simulated-channel" },
                resolveGuildName: { _ in "simulated-guild" },
                log: { _ in },
                recordAutomationRun: { _, _, _, _, _, _ in }
            )

            // A separate in-memory service: no journal file, no real waits.
            let simService = AutomationService(aiService: self.aiService, dependencies: dryRunDeps)
            await simService.setSimulationMemory(memory)
            stepTraces = await simService.traceSteps(of: rule, event: event, recorder: accumulator)
        } else {
            for step in rule.steps {
                stepTraces.append(
                    Automations.StepTrace(stepId: step.id, kind: step.kind, executed: false, detail: "Step bypassed (filters/trigger did not match)"))
            }
        }

        return Automations.SimulationResult(
            triggerMatched: triggerMatched,
            filtersMatched: filtersMatched && !cooldownActive,
            filterTraces: filterTraces,
            stepTraces: stepTraces,
            diagnostics: diagnostics
        )
    }
}

extension AutomationService {
    /// Runs each step once against dry-run dependencies and reports what it
    /// would have done. Steps are traced one at a time, so a step that
    /// records nothing (log, delay, aiTransform, or a step with no target)
    /// can't shift later steps' details onto the wrong row. Delays are
    /// reported, not waited out.
    fileprivate func traceSteps(of rule: Automations.Rule, event: SwiftBotEvent, recorder: SimTraceAccumulator) async -> [Automations.StepTrace] {
        var ctx = ExecutionContext(event: event)
        ctx.ruleId = rule.id
        var branches: [AutomationBranchFrame] = []
        var stopped = false
        var traces: [Automations.StepTrace] = []
        for step in rule.steps {
            if stopped || (!(branches.last?.active ?? true) && ![.branch, .otherwise, .endBranch].contains(step.kind)) {
                traces.append(Automations.StepTrace(stepId: step.id, kind: step.kind, executed: false, detail: stopped ? "Skipped: previous step failed" : "Skipped: other branch selected"))
                continue
            }
            let actionsBefore = recorder.steps.count
            let errorsBefore = ctx.errors.count
            var executed = true
            var detail: String
            switch step.kind {
            case .branch, .otherwise, .endBranch:
                detail = processBranch(step, event: event, ruleId: rule.id, branches: &branches)
            case .incrementCounter, .resetCounter:
                do { try applyCounter(step, event: event, ruleId: rule.id, executionId: UUID().uuidString) } catch { ctx.errors.append(error.localizedDescription) }
                detail = "Would \(step.kind == .incrementCounter ? "increment" : "reset") counter \(step.counterName ?? "")"
            case .delay:
                detail = "Would wait \(formatDuration(max(0, step.delaySeconds ?? 0)))"
            case .log:
                let text = await render(step.logText ?? "", event: event, aiOutput: ctx.aiOutput)
                executed = !text.isEmpty
                detail = text.isEmpty ? "Nothing to log" : "Would log: \"\(text)\""
            default:
                await runStep(step, ctx: &ctx, token: "sim-token")
                let actions = recorder.steps.dropFirst(actionsBefore).map(\.detail)
                if step.kind == .aiTransform, let output = ctx.aiOutput {
                    detail = "AI output: \"\(output)\""
                } else if actions.isEmpty {
                    executed = false
                    detail = "Nothing to do. Check the step's target and content."
                } else {
                    detail = actions.joined(separator: "\n")
                }
            }
            let errors = ctx.errors.dropFirst(errorsBefore)
            if !errors.isEmpty {
                executed = false
                detail = errors.joined(separator: "\n")
                stopped = rule.failurePolicy == .stopOnError
            }
            traces.append(Automations.StepTrace(stepId: step.id, kind: step.kind, executed: executed, detail: detail))
        }
        return traces
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

// MARK: - Simulation input

extension Automations {
    /// The sample event a dry run is tested against. Shared by the native rule
    /// editor and the WebUI so both simulate the same thing.
    struct SimulationInput: Codable, Sendable, Hashable {
        var username: String
        var channelId: String
        var messageContent: String
        var voiceDurationSeconds: Int

        /// Values that should satisfy the rule's own trigger and filters.
        static func suggested(for rule: Rule) -> SimulationInput {
            var channelId = "chan-123"
            if let tc = rule.trigger.channelId, !tc.isEmpty {
                channelId = tc
            } else if let first = rule.filters.first(where: { $0.kind == .inChannel })?.channelIds?.first, !first.isEmpty {
                channelId = first
            }

            var duration = 300
            if let threshold = rule.trigger.voiceDurationThreshold {
                duration = threshold
            } else if let minSeconds = rule.filters.first(where: { $0.kind == .minVoiceDurationSeconds })?.intValue {
                duration = minSeconds
            }

            var content = "Hello world!"
            if rule.filters.contains(where: { $0.kind == .messageContainsSpamLink }) {
                content = "FREE-DISCORD-NITRO PHISHING LINK HERE: HTTPS://GIFT-NITRO.COM"
            } else if rule.filters.contains(where: { $0.kind == .messageCapsPercentage }) {
                content = "HELLO WORLD THIS IS A LOUD SHOUTING MESSAGE"
            } else if let mentions = rule.filters.first(where: { $0.kind == .messageMentionsCount }) {
                let count = mentions.intValue ?? 5
                content = (1...max(1, count + 1)).map { "<@user\($0)>" }.joined(separator: " ") + " wake up!"
            } else if let t = rule.filters.first(where: { $0.kind == .messageEquals })?.text, !t.isEmpty {
                content = t
            } else if let t = rule.filters.first(where: { $0.kind == .messageContains })?.text, !t.isEmpty {
                content = t
            } else if let t = rule.filters.first(where: { $0.kind == .messageContainsAny })?.textValues?.first, !t.isEmpty {
                content = t
            } else if let t = rule.filters.first(where: { $0.kind == .messageMatchesRegex })?.text, !t.isEmpty {
                content = "Sample matching string for regex: \(t)"
            }
            // Live events carry the command or the emoji as their content.
            if rule.trigger.kind == .slashCommand {
                content = "/" + (rule.trigger.commandName ?? "command").trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
            } else if rule.trigger.kind == .reactionAdded {
                content = rule.trigger.reactionEmoji.flatMap { $0.isEmpty ? nil : $0 } ?? "⭐"
            }

            return SimulationInput(username: "john_doe", channelId: channelId, messageContent: content, voiceDurationSeconds: duration)
        }

        /// The event this input describes for a trigger kind.
        func event(for trigger: TriggerKind, guildId: String? = nil) -> SwiftBotEvent {
            switch trigger {
            case .userJoinedVoice:
                return .join(guildId: "guild-123", userId: "user-123", username: username, channelId: channelId)
            case .userLeftVoice:
                return .leave(guildId: "guild-123", userId: "user-123", username: username, channelId: channelId, durationSeconds: voiceDurationSeconds)
            case .userMovedVoice:
                return .move(
                    guildId: "guild-123", userId: "user-123", username: username, channelId: channelId,
                    fromChannelId: "voice-old", toChannelId: channelId, durationSeconds: voiceDurationSeconds)
            case .memberJoined:
                return .memberJoin(guildId: "guild-123", userId: "user-123", username: username, joinedAt: Date())
            case .memberLeft:
                return .memberLeave(guildId: "guild-123", userId: "user-123", username: username)
            case .schedule, .scheduledEvent, .reactionAdded, .slashCommand:
                var payload = SwiftBotEvent.MessagePayload(
                    guildId: guildId ?? "guild-123", userId: "user-123", username: username, channelId: channelId, messageId: "sim-123",
                    content: messageContent, isDirectMessage: false, authorIsBot: false)
                payload.automationTrigger = trigger
                payload.eventName = "The Finals Season 12"
                payload.eventURL = "https://discord.com/events/guild-123/event-123"
                return .message(payload)
            case .mediaAdded:
                return .mediaAdded(
                    SwiftBotEvent.MediaPayload(
                        guildId: "guild-123", userId: "user-123", username: username, fileName: "audio.mp3",
                        relativePath: nil, sourceName: "Local", nodeName: "node-1"
                    ))
            default:
                return .message(
                    SwiftBotEvent.MessagePayload(
                        guildId: "guild-123", userId: "user-123", username: username, channelId: channelId,
                        messageId: "msg-123", content: messageContent, isDirectMessage: false, authorIsBot: false
                    ))
            }
        }
    }
}

extension AutomationService {
    func matchingRules(event: SwiftBotEvent, in rules: [Automations.Rule]) -> [Automations.Rule] {
        evaluate(event: event, in: rules, memory: memory)
    }
    private func reloadMemory() {
        guard let url = memoryURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { memory = AutomationMemory(); memoryReadable = true; return }
        do { memory = try JSONDecoder().decode(AutomationMemory.self, from: Data(contentsOf: url)); memoryReadable = true } catch { memoryReadable = false }
    }
    private func saveMemory(_ next: AutomationMemory) throws {
        guard memoryReadable else { throw CocoaError(.fileReadCorruptFile) }
        var copy = next
        copy.prune()
        guard copy.counters.count <= 10_000, copy.counters.values.reduce(0, { $0 + $1.count }) <= 100_000, copy.appliedSteps.count <= 100_000 else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        if let url = memoryURL {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(copy).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        memory = copy
    }
    private func applyCounter(_ step: Automations.Step, event: SwiftBotEvent, ruleId: String, executionId: String) throws {
        let operation = executionId + ":" + step.id
        guard memory.appliedSteps[operation] == nil else { return }
        var copy = memory
        let key = AutomationMemory.scopeKey(name: step.counterName ?? "", scope: step.counterScope ?? .user, ruleId: ruleId, event: event)
        if step.kind == .resetCounter {
            copy.counters.removeValue(forKey: key)
        } else {
            copy.counters[key, default: []].append(Date().addingTimeInterval(Double(step.counterLifetimeSeconds ?? 600)))
        }
        copy.appliedSteps[operation] = Date()
        try saveMemory(copy)
    }
    fileprivate func setSimulationMemory(_ copy: AutomationMemory) { memory = copy }
    private nonisolated static func combine(_ values: [Bool], logic: Automations.FilterLogic) -> Bool {
        if values.isEmpty { return true }
        switch logic {
        case .all: return values.allSatisfy { $0 }
        case .any: return values.contains(true)
        case .none: return !values.contains(true)
        }
    }
    private nonisolated static func conditionsMatch(
        _ filters: [Automations.Filter], groups: [Automations.ConditionGroup], logic: Automations.FilterLogic, event: SwiftBotEvent, memory: AutomationMemory,
        ruleId: String
    ) -> Bool {
        func matches(_ group: Automations.ConditionGroup, depth: Int) -> Bool {
            guard depth <= 32 else { return false }
            let leaves = group.filters.map { filterMatches($0, event: event, memory: memory, ruleId: ruleId) }
            let children = groups.filter { $0.parentId == group.id }.map { matches($0, depth: depth + 1) }
            return combine(leaves + children, logic: group.logic)
        }
        return combine(
            filters.map { filterMatches($0, event: event, memory: memory, ruleId: ruleId) }
                + groups.filter { $0.parentId == nil }.map { matches($0, depth: 0) }, logic: logic)
    }
    private func processBranch(_ step: Automations.Step, event: SwiftBotEvent, ruleId: String, branches: inout [AutomationBranchFrame]) -> String {
        switch step.kind {
        case .branch:
            let parent = branches.last?.active ?? true
            let matched =
                parent
                && Self.conditionsMatch(
                    step.conditions ?? [], groups: step.conditionGroups ?? [], logic: step.conditionLogic ?? .all, event: event, memory: memory, ruleId: ruleId)
            branches.append(AutomationBranchFrame(parentActive: parent, conditionMatched: matched))
            return parent ? (matched ? "If matched: taking this branch" : "If did not match: taking Otherwise") : "Skipped: parent branch inactive"
        case .otherwise:
            if !branches.isEmpty { branches[branches.count - 1].inOtherwise = true }
            return branches.last?.active == true ? "Taking Otherwise" : "Otherwise skipped"
        case .endBranch:
            if !branches.isEmpty { branches.removeLast() }
            return "End If"
        default: return ""
        }
    }
    private func embedPayload(_ embed: Automations.Embed, content: String, event: SwiftBotEvent, aiOutput: String?) async throws -> [String: Any] {
        var rendered = embed
        rendered.title = await render(embed.title ?? "", event: event, aiOutput: aiOutput)
        rendered.description = await render(embed.description ?? "", event: event, aiOutput: aiOutput)
        rendered.footer = await render(embed.footer ?? "", event: event, aiOutput: aiOutput)
        try rendered.validate()
        guard content.count <= 2000 else { throw ValidationError.invalidValue("Message exceeds 2000 characters") }
        var body: [String: Any] = [:]
        if let title = rendered.title, !title.isEmpty { body["title"] = title }
        if let description = rendered.description, !description.isEmpty { body["description"] = description }
        if let color = rendered.color { body["color"] = color }
        if let image = rendered.imageURL, !image.isEmpty { body["image"] = ["url": image] }
        if let image = rendered.thumbnailURL, !image.isEmpty { body["thumbnail"] = ["url": image] }
        if let footer = rendered.footer, !footer.isEmpty { body["footer"] = ["text": footer] }
        return ["content": content, "embeds": [body], "allowed_mentions": ["parse": []]]
    }
    func runDiagnostics() -> [AutomationRunDiagnostic] {
        journal.records.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(100).map {
            AutomationRunDiagnostic(
                id: $0.id, ruleId: $0.rule.id, ruleName: $0.rule.name, updatedAt: $0.updatedAt,
                status: $0.needsReview
                    ? "Needs review" : ($0.completed ? ($0.errors.isEmpty ? "Success" : ($0.errors.first == "Skipped: cooldown" ? "Skipped" : "Failed")) : ($0.wakeAt != nil ? "Waiting" : "Running")),
                traces: $0.traces ?? [], errors: $0.errors)
        }
    }
}

extension AutomationService {
    /// Catch up only the latest occurrence within five minutes. Older occurrences
    /// stay missed rather than publishing stale announcements after a long outage.
    func runScheduledRules(_ rules: [Automations.Rule], events: [DiscordScheduledEvent], token: String?, now: Date = Date()) async {
        guard !paused, memoryReadable, await dependencies.canExecute() else { return }
        for rule in rules where rule.enabled {
            // Discord event announcements are one-off. Moving the event after
            // admission must not create a second announcement for the same rule.
            if rule.trigger.kind == .scheduledEvent, memory.scheduleCursors[rule.id] != nil { continue }
            let occurrence: Date?
            var discordEvent: DiscordScheduledEvent?
            if rule.trigger.kind == .schedule {
                occurrence = rule.trigger.schedule?.latestOccurrence(at: now)
            } else {
                discordEvent = events.first { $0.id == rule.trigger.eventId && $0.guildId == rule.trigger.guildId && ($0.status == 1 || $0.status == 2 || $0.status == 3) }
                guard let selected = discordEvent else { continue }
                occurrence =
                    rule.trigger.eventCustomTime.flatMap(Automations.Schedule.parse)
                    ?? selected.startDate?.addingTimeInterval(Double(rule.trigger.eventOffsetSeconds ?? 0))
            }
            guard let due = occurrence, due <= now, now.timeIntervalSince(due) <= 300,
                due > (memory.scheduleCursors[rule.id] ?? .distantPast)
            else { continue }
            var payload = SwiftBotEvent.MessagePayload(
                guildId: rule.trigger.guildId ?? "", userId: "", username: "Schedule", channelId: rule.trigger.channelId ?? "",
                messageId: "schedule:" + String(Int(due.timeIntervalSince1970)), content: "", isDirectMessage: false, authorIsBot: false)
            payload.automationTrigger = rule.trigger.kind
            payload.eventName = discordEvent?.name
            payload.eventDescription = discordEvent?.description
            payload.eventURL = discordEvent?.url
            payload.eventStart = discordEvent?.startDate.map { "<t:\(Int($0.timeIntervalSince1970)):F>" }
            let event = SwiftBotEvent.message(payload)
            guard !evaluate(event: event, in: [rule], memory: memory).isEmpty else { continue }
            // Journal intent first. If a crash occurs before cursor persistence,
            // the deterministic execution ID still prevents repeating that run.
            let id = rule.id + ":" + payload.messageId
            do {
                if journal.records[id] == nil {
                    try journal.save(AutomationExecutionCheckpoint(id: id, rule: AutomationWebhookVault.seal(rule), event: event))
                }
                var updated = memory
                updated.scheduleCursors[rule.id] = due
                try saveMemory(updated)
            } catch { dependencies.log("Schedule paused: " + error.localizedDescription); continue }
            Task { await self.execute(rule: rule, event: event, token: token) }
        }
    }
}
