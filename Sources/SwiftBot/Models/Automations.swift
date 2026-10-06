import Foundation
import FoundationModels

/// IFTTT-style automation rules.
///
/// Design:
///   - A `Rule` has one `Trigger` (an event kind), zero or more `Filter`s
///     joined by `.all` (AND) or `.any` (OR), and an ordered list of `Step`s.
///   - Every type is `@Generable` so Apple Intelligence can draft a rule
///     directly from natural-language input.
///   - Filters are flat structs with a `kind` discriminator and optional
///     params. The engine only consults the params relevant to `kind`.
///     This shape is friendlier to FoundationModels than associated-value
///     enums and easier to render in SwiftUI.
enum Automations {

    // MARK: - Rule

    @Generable
    struct Rule: Codable, Identifiable, Hashable, Sendable, Validatable {
        @Guide(description: "Stable unique identifier (UUID).")
        var id: String

        @Guide(description: "Short human-readable name, e.g. 'Welcome new members'.")
        var name: String

        @Guide(description: "Whether the rule is currently active.")
        var enabled: Bool

        @Guide(description: "Which tab this rule belongs to: automation (general 'do cool stuff' rules) or moderation (block/timeout/delete rules).")
        var category: Category

        @Guide(description: "The event that fires this rule.")
        var trigger: Trigger

        @Guide(description: "How filters combine: .all means every filter must match (AND), .any means at least one (OR).")
        var filterLogic: FilterLogic

        @Guide(description: "Conditions that gate the rule. Empty means always-fires for the trigger.")
        var filters: [Filter]

        @Guide(description: "Ordered steps to run when the trigger fires and filters pass. Usually 1, max 3.")
        var steps: [Step]
        var conditionGroups: [ConditionGroup]?
        var cooldown: Cooldown?
        var failurePolicy: FailurePolicy?

        init(
            id: String = UUID().uuidString,
            name: String,
            enabled: Bool = true,
            category: Category = .automation,
            trigger: Trigger,
            filterLogic: FilterLogic = .all,
            filters: [Filter] = [],
            steps: [Step],
            conditionGroups: [ConditionGroup]? = nil,
            cooldown: Cooldown? = nil,
            failurePolicy: FailurePolicy? = nil
        ) {
            self.id = id
            self.name = name
            self.enabled = enabled
            self.category = category
            self.trigger = trigger
            self.filterLogic = filterLogic
            self.filters = filters
            self.steps = steps
            self.conditionGroups = conditionGroups
            self.cooldown = cooldown
            self.failurePolicy = failurePolicy
        }

        func validate() throws {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.invalidValue("Rule name cannot be empty")
            }
            guard !steps.isEmpty, steps.count <= 100 else {
                throw ValidationError.invalidValue("Add between 1 and 100 steps")
            }
            guard Set(steps.map(\.id)).count == steps.count else { throw ValidationError.invalidValue("Each step must have a unique ID") }
            try trigger.validate()
            try Self.validateGroups(conditionGroups ?? [])
            try cooldown?.validate()
            var branches: [Bool] = []
            for step in steps {
                switch step.kind {
                case .branch: branches.append(false)
                case .otherwise:
                    guard let used = branches.last, !used else { throw ValidationError.invalidValue("Otherwise must follow an If and can appear only once") }
                    branches[branches.count - 1] = true
                case .endBranch:
                    guard !branches.isEmpty else { throw ValidationError.invalidValue("End If has no matching If") }
                    branches.removeLast()
                default: break
                }
            }
            guard branches.isEmpty else { throw ValidationError.invalidValue("Every If needs an End If") }
            if category == .events && trigger.kind != .scheduledEvent {
                throw ValidationError.invalidValue("Event announcements require a Discord event trigger")
            }
            for filter in filters {
                try filter.validate()
            }
            for step in steps {
                if enabled, step.kind == .sendMessage, step.sendTarget == .specificChannel, (step.channelId ?? "").isEmpty {
                    throw ValidationError.invalidValue("Choose a destination channel")
                }
                if trigger.kind == .schedule || trigger.kind == .scheduledEvent {
                    if step.kind == .modifyMember || step.kind == .modifyMessage {
                        throw ValidationError.invalidValue("Scheduled workflows do not have a triggering member or message")
                    }
                    if step.kind == .sendMessage, step.sendTarget != .specificChannel {
                        throw ValidationError.invalidValue("Scheduled messages need a specific destination channel")
                    }
                }
                try step.validate()
            }
        }
    }

    @Generable
    enum Category: String, Codable, Hashable, Sendable, CaseIterable {
        case automation
        case moderation
        case events
    }

    @Generable
    enum FilterLogic: String, Codable, Hashable, Sendable, CaseIterable {
        case all  // AND
        case any  // OR
        case none  // NOT: every condition must be false
    }

    // MARK: - Trigger

    @Generable
    enum TriggerKind: String, Codable, Hashable, Sendable, CaseIterable {
        case userJoinedVoice
        case userLeftVoice
        case userMovedVoice
        case messageCreated
        case memberJoined
        case memberLeft
        case reactionAdded
        case slashCommand
        case mediaAdded
        case schedule
        case scheduledEvent

        static func visibleCases(for category: Category) -> [TriggerKind] {
            switch category {
            case .automation:
                return allCases
            case .events: return [.scheduledEvent]
            case .moderation:
                return [
                    .messageCreated,
                    .memberJoined,
                    .memberLeft,
                    .userJoinedVoice,
                    .userLeftVoice,
                    .userMovedVoice,
                    .reactionAdded,
                    .slashCommand,
                ]
            }
        }
    }

    /// Lean trigger — only the params that *define* the trigger itself (a
    /// slash command without a name is meaningless). Everything else
    /// (channel, role, message content, etc.) is expressed as a Filter.
    @Generable
    struct Trigger: Codable, Hashable, Sendable, Validatable {
        @Guide(description: "Which Discord event fires this rule.")
        var kind: TriggerKind

        @Guide(description: "For slashCommand: command name without the leading slash. Required when kind is slashCommand.")
        var commandName: String?

        @Guide(description: "Specific channel ID to restrict this trigger. Optional.")
        var channelId: String?

        @Guide(description: "For reactionAdded: Restrict to specific emoji string. Optional.")
        var reactionEmoji: String?

        @Guide(description: "For userLeftVoice: Restrict to voice duration threshold (seconds). Optional.")
        var voiceDurationThreshold: Int?
        var guildId: String?
        var schedule: Schedule?
        var eventId: String?
        var eventOffsetSeconds: Int?
        var eventCustomTime: String?

        func validate() throws {
            if kind == .schedule {
                try schedule?.validate()
                guard schedule != nil, !(guildId ?? "").isEmpty else { throw ValidationError.invalidValue("Choose a server and schedule") }
            }
            if kind == .scheduledEvent {
                guard !(guildId ?? "").isEmpty, !(eventId ?? "").isEmpty else { throw ValidationError.invalidValue("Choose a server and Discord event") }
                if let time = eventCustomTime, Schedule.parse(time) == nil { throw ValidationError.invalidValue("Invalid custom announcement time") }
                if let offset = eventOffsetSeconds, offset < -2_592_000 || offset > 2_592_000 { throw ValidationError.invalidValue("Event offset must be within 30 days") }
            }
            if kind == .slashCommand {
                guard let name = commandName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    throw ValidationError.invalidValue("Command name is required for slashCommand triggers")
                }
            }
            if let threshold = voiceDurationThreshold {
                guard threshold >= 0 && threshold <= 86400 else {
                    throw ValidationError.outOfRange("voiceDurationThreshold", min: 0, max: 86400)
                }
            }
        }
    }

    // MARK: - Filter

    @Generable
    enum FilterKind: String, Codable, Hashable, Sendable, CaseIterable {
        // Scope
        case inChannel  // channelIds: at least one matches event.channelId
        case directMessage  // boolValue: true = DMs only, false = guild only
        // User
        case userIsOneOf  // userIds
        case userHasAnyRole  // roleIds
        case userHasAllRoles  // roleIds
        case userHasNoneOfRoles  // roleIds
        // Message content
        case messageContains  // text (case-insensitive substring)
        case messageContainsAny  // textValues (any substring matches)
        case messageEquals  // text (exact, trimmed)
        case messageDoesNotContain  // text
        case messageMatchesRegex  // text
        case messageIsReply  // boolValue: true = is reply, false = is not
        // Author
        case fromBot  // boolValue
        // Voice
        case minVoiceDurationSeconds  // intValue
        // Reaction
        case reactionEmoji  // text
        // Media
        case mediaSource  // text
        // Moderation
        case messageContainsSpamLink
        case messageCapsPercentage
        case messageMentionsCount
        case counterAtLeast
        case counterBelow
    }

    @Generable
    struct Filter: Codable, Hashable, Sendable, Identifiable, Validatable {
        @Guide(description: "Stable unique identifier for this filter.")
        var id: String

        @Guide(description: "What this filter checks.")
        var kind: FilterKind

        // Polymorphic param fields — the engine reads only the field(s)
        // relevant to `kind`.

        @Guide(description: "For inChannel: list of channel IDs. Filter passes if event's channel is in the list.")
        var channelIds: [String]?

        @Guide(description: "For role filters: list of role IDs.")
        var roleIds: [String]?

        @Guide(description: "For userIsOneOf: list of user IDs the rule should fire for.")
        var userIds: [String]?

        @Guide(description: "Single text value (for contains / equals / regex / reactionEmoji / mediaSource).")
        var text: String?

        @Guide(description: "For messageContainsAny: list of substrings. Filter passes if any one substring is found.")
        var textValues: [String]?

        @Guide(description: "For directMessage / messageIsReply / fromBot: true or false.")
        var boolValue: Bool?

        @Guide(description: "For minVoiceDurationSeconds: integer seconds threshold.")
        var intValue: Int?
        var counterName: String?
        var counterScope: MemoryScope?

        init(
            id: String = UUID().uuidString,
            kind: FilterKind,
            channelIds: [String]? = nil,
            roleIds: [String]? = nil,
            userIds: [String]? = nil,
            text: String? = nil,
            textValues: [String]? = nil,
            boolValue: Bool? = nil,
            intValue: Int? = nil, counterName: String? = nil, counterScope: MemoryScope? = nil
        ) {
            self.id = id
            self.kind = kind
            self.channelIds = channelIds
            self.roleIds = roleIds
            self.userIds = userIds
            self.text = text
            self.textValues = textValues
            self.boolValue = boolValue
            self.intValue = intValue
            self.counterName = counterName
            self.counterScope = counterScope
        }

        func validate() throws {
            switch kind {
            case .counterAtLeast, .counterBelow:
                guard !(counterName ?? "").trimmingCharacters(in: .whitespaces).isEmpty, let value = intValue, value >= 0 else {
                    throw ValidationError.invalidValue("A counter condition needs a name and non-negative threshold")
                }
            case .messageMatchesRegex:
                if let pattern = text {
                    do {
                        _ = try NSRegularExpression(pattern: pattern)
                    } catch {
                        throw ValidationError.invalidValue("Invalid regex pattern: \(error.localizedDescription)")
                    }
                }
            case .minVoiceDurationSeconds:
                if let value = intValue {
                    if value < 0 || value > 86400 {
                        throw ValidationError.outOfRange("minVoiceDurationSeconds", min: 0, max: 86400)
                    }
                }
            case .messageCapsPercentage:
                if let val = intValue {
                    guard val >= 0 && val <= 100 else {
                        throw ValidationError.outOfRange("Caps Percentage", min: 0, max: 100)
                    }
                }
            case .messageMentionsCount:
                if let val = intValue {
                    guard val >= 0 else {
                        throw ValidationError.invalidValue("Mentions Count threshold must be non-negative")
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: - Step

    @Generable
    enum StepKind: String, Codable, Hashable, Sendable, CaseIterable {
        case sendMessage
        case modifyMember
        case modifyMessage
        case log
        case webhook
        case delay
        /// Runs Apple Intelligence with `aiPrompt`. Result is stored in the
        /// execution context's `aiOutput` and exposed to subsequent steps as
        /// the `{ai_output}` template token. Only the most-recent
        /// `aiTransform` step in a rule's pipeline contributes — running a
        /// second `aiTransform` overwrites the first.
        case aiTransform
        case branch
        case otherwise
        case endBranch
        case incrementCounter
        case resetCounter
    }

    @Generable
    enum SendTarget: String, Codable, Hashable, Sendable, CaseIterable {
        case replyToTrigger
        case sameChannel
        case directMessage
        case specificChannel
    }

    @Generable
    enum MemberOp: String, Codable, Hashable, Sendable, CaseIterable {
        case addRole
        case removeRole
        case timeout
        case removeTimeout
        case kick
        case ban
        case moveVoice
    }

    @Generable
    enum MessageOp: String, Codable, Hashable, Sendable, CaseIterable {
        case delete
        case react
    }

    @Generable
    struct Step: Codable, Hashable, Sendable, Identifiable, Validatable {
        @Guide(description: "Stable unique identifier for this step.")
        var id: String

        @Guide(description: "Which kind of action to perform.")
        var kind: StepKind

        @Guide(
            description:
                "For sendMessage: where to send. Default replyToTrigger for message triggers, sameChannel for voice triggers, directMessage for member triggers."
        )
        var sendTarget: SendTarget?

        @Guide(description: "For sendMessage with sendTarget=specificChannel: the channel ID.")
        var channelId: String?

        @Guide(description: "For sendMessage: literal text to send. May contain variables like {username}, {channelName}. Omit if aiPrompt is set.")
        var content: String?

        @Guide(description: "For sendMessage: if set, generate the message content with Apple Intelligence using this prompt.")
        var aiPrompt: String?

        @Guide(description: "For modifyMember: which member operation.")
        var memberOp: MemberOp?

        @Guide(description: "For addRole/removeRole: the role ID.")
        var roleId: String?

        @Guide(description: "For timeout: duration in seconds.")
        var timeoutSeconds: Int?

        @Guide(description: "For kick or ban: reason string, with optional template variables.")
        var kickReason: String?

        @Guide(description: "For ban: seconds of the user's recent messages to delete, from 0 to 604800 (7 days). Default 0 preserves message history.")
        var banDeleteMessageSeconds: Int?

        @Guide(description: "For moveVoice: destination voice channel ID.")
        var targetVoiceChannelId: String?

        @Guide(description: "For modifyMessage: which message operation.")
        var messageOp: MessageOp?

        @Guide(description: "For react: emoji (unicode or :name:).")
        var reactEmoji: String?

        @Guide(description: "For log: text to write to the bot log. May contain variables.")
        var logText: String?

        @Guide(description: "For webhook: full HTTPS URL.")
        var webhookUrl: String?

        /// Keychain reference for a saved webhook URL. Stored rules keep only
        /// this reference; see `AutomationWebhookVault`.
        var webhookCredentialId: String?

        @Guide(description: "For webhook: body content.")
        var webhookContent: String?

        @Guide(description: "For delay: seconds to wait before the next step.")
        var delaySeconds: Int?
        var conditions: [Filter]?
        var conditionGroups: [ConditionGroup]?
        var conditionLogic: FilterLogic?
        var counterName: String?
        var counterScope: MemoryScope?
        var counterLifetimeSeconds: Int?
        var embed: Embed?

        init(
            id: String = UUID().uuidString,
            kind: StepKind,
            sendTarget: SendTarget? = nil,
            channelId: String? = nil,
            content: String? = nil,
            aiPrompt: String? = nil,
            memberOp: MemberOp? = nil,
            roleId: String? = nil,
            timeoutSeconds: Int? = nil,
            kickReason: String? = nil,
            banDeleteMessageSeconds: Int? = nil,
            targetVoiceChannelId: String? = nil,
            messageOp: MessageOp? = nil,
            reactEmoji: String? = nil,
            logText: String? = nil,
            webhookUrl: String? = nil,
            webhookContent: String? = nil,
            webhookCredentialId: String? = nil,
            delaySeconds: Int? = nil,
            conditions: [Filter]? = nil, conditionGroups: [ConditionGroup]? = nil,
            conditionLogic: FilterLogic? = nil, counterName: String? = nil,
            counterScope: MemoryScope? = nil, counterLifetimeSeconds: Int? = nil,
            embed: Embed? = nil
        ) {
            self.id = id
            self.kind = kind
            self.sendTarget = sendTarget
            self.channelId = channelId
            self.content = content
            self.aiPrompt = aiPrompt
            self.memberOp = memberOp
            self.roleId = roleId
            self.timeoutSeconds = timeoutSeconds
            self.kickReason = kickReason
            self.banDeleteMessageSeconds = banDeleteMessageSeconds
            self.targetVoiceChannelId = targetVoiceChannelId
            self.messageOp = messageOp
            self.reactEmoji = reactEmoji
            self.logText = logText
            self.webhookUrl = webhookUrl
            self.webhookContent = webhookContent
            self.webhookCredentialId = webhookCredentialId
            self.delaySeconds = delaySeconds
            self.conditions = conditions
            self.conditionGroups = conditionGroups
            self.conditionLogic = conditionLogic
            self.counterName = counterName
            self.counterScope = counterScope
            self.counterLifetimeSeconds = counterLifetimeSeconds
            self.embed = embed
        }

        func validate() throws {
            switch kind {
            case .branch:
                guard !(conditions ?? []).isEmpty || !(conditionGroups ?? []).isEmpty else { throw ValidationError.invalidValue("If needs a condition") }
                for filter in conditions ?? [] { try filter.validate() }
                try Rule.validateGroups(conditionGroups ?? [])
            case .incrementCounter, .resetCounter:
                guard !(counterName ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError.invalidValue("Choose a counter name") }
                if kind == .incrementCounter, !(1...2_592_000).contains(counterLifetimeSeconds ?? 600) {
                    throw ValidationError.invalidValue("Counter lifetime must be 1 second to 30 days")
                }
            case .sendMessage:
                try embed?.validate()
            case .webhook:
                // A saved step keeps its URL in the Keychain; an edit that leaves
                // the URL blank keeps that saved URL.
                if (webhookUrl ?? "").isEmpty, !(webhookCredentialId ?? "").isEmpty { break }
                try validateSecureURL(webhookUrl)
            case .delay:
                if let val = delaySeconds {
                    if val < 0 || val > 3600 {
                        throw ValidationError.outOfRange("delaySeconds", min: 0, max: 3600)
                    }
                }
            case .modifyMember:
                if memberOp == .timeout, let val = timeoutSeconds {
                    if val < 1 || val > 2_419_200 {  // 28 days
                        throw ValidationError.outOfRange("timeoutSeconds", min: 1, max: 2_419_200)
                    }
                }
                if memberOp == .ban, let val = banDeleteMessageSeconds, !(0...604800).contains(val) {
                    throw ValidationError.outOfRange("banDeleteMessageSeconds", min: 0, max: 604800)
                }
            case .aiTransform:
                let trimmed = (aiPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    throw ValidationError.invalidValue("AI Transform requires a prompt")
                }
            default:
                break
            }
        }
    }

    // MARK: - Template variables

    enum Variable: String, CaseIterable {
        case username = "{username}"
        case userId = "{userId}"
        case userMention = "{userMention}"
        case channelName = "{channelName}"
        case channelId = "{channelId}"
        case guildName = "{guildName}"
        case guildId = "{guildId}"
        case message = "{message}"
        case messageId = "{messageId}"
        case duration = "{duration}"
        case mediaFile = "{mediaFile}"
        case mediaSource = "{mediaSource}"
        case aiOutput = "{ai_output}"
        case eventName = "{eventName}"
        case eventDescription = "{eventDescription}"
        case eventURL = "{eventURL}"
        case eventStart = "{eventStart}"

        static var allTokens: [String] { allCases.map(\.rawValue) }

        var label: String {
            switch self {
            case .username: return "User's name"
            case .userId: return "User ID"
            case .userMention: return "User @-mention"
            case .channelName: return "Channel name"
            case .channelId: return "Channel ID"
            case .guildName: return "Server name"
            case .guildId: return "Server ID"
            case .message: return "Message text"
            case .messageId: return "Message ID"
            case .duration: return "Voice session duration"
            case .mediaFile: return "Media file name"
            case .mediaSource: return "Media source"
            case .eventName: return "Discord event name"
            case .eventDescription: return "Discord event description"
            case .eventURL: return "Discord event link"
            case .eventStart: return "Discord event start time"
            case .aiOutput: return "Most recent AI step output"
            }
        }

        func appliesTo(_ kind: TriggerKind) -> Bool {
            switch self {
            case .username, .userId, .userMention, .guildName, .guildId:
                return true
            case .channelName, .channelId:
                switch kind {
                case .memberJoined, .memberLeft, .mediaAdded: return false
                default: return true
                }
            case .message, .messageId:
                return kind == .messageCreated
            case .duration:
                return kind == .userJoinedVoice
                    || kind == .userLeftVoice
                    || kind == .userMovedVoice
            case .mediaFile, .mediaSource:
                return kind == .mediaAdded
            case .eventName, .eventDescription, .eventURL, .eventStart: return kind == .scheduledEvent
            case .aiOutput:
                // Always applicable — populated at step-run time by an
                // `aiTransform` step earlier in the same rule's pipeline.
                return true
            }
        }
    }

    // MARK: - Simulation Trace Models

    struct FilterTrace: Codable, Sendable, Hashable, Identifiable {
        var id: String { filterId }
        let filterId: String
        let kind: FilterKind
        let matched: Bool
        let detail: String
    }

    struct StepTrace: Codable, Sendable, Hashable, Identifiable {
        var id: String { stepId }
        let stepId: String
        let kind: StepKind
        let executed: Bool
        let detail: String
    }

    struct SimulationResult: Codable, Sendable, Hashable {
        let triggerMatched: Bool
        let filtersMatched: Bool
        let filterTraces: [FilterTrace]
        let stepTraces: [StepTrace]
        var diagnostics: [String] = []
    }
}

extension Automations.Step {
    /// Deletes the message or removes the member, so ordinary automations
    /// should not also respond to the same event.
    var isDestructiveModeration: Bool {
        (kind == .modifyMessage && messageOp == .delete)
            || (kind == .modifyMember && [.timeout, .kick, .ban].contains(memberOp))
    }
}

extension Automations.Rule {
    /// True when a run admitted under `other` would behave the same under this
    /// rule. Only the display name may differ.
    func isExecutionEquivalent(to other: Automations.Rule) -> Bool {
        var renamed = self
        renamed.name = other.name
        return renamed == other
    }
}

extension Automations {
    @Generable
    enum MemoryScope: String, Codable, Hashable, Sendable, CaseIterable { case user, channel, guild, rule }
    @Generable
    enum FailurePolicy: String, Codable, Hashable, Sendable, CaseIterable { case continueOnError, stopOnError }
    @Generable
    struct Cooldown: Codable, Hashable, Sendable, Validatable {
        var seconds: Int
        var scope: MemoryScope
        func validate() throws {
            guard (1...2_592_000).contains(seconds) else { throw ValidationError.invalidValue("Cooldown must be 1 second to 30 days") }
        }
    }
    // A flat parent-ID tree keeps generated models non-recursive, while allowing nested groups.
    @Generable
    struct ConditionGroup: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var parentId: String?
        var logic: FilterLogic
        var filters: [Filter]
    }
    @Generable
    struct Embed: Codable, Hashable, Sendable, Validatable {
        var title: String?
        var description: String?
        var color: Int?
        var imageURL: String?
        var thumbnailURL: String?
        var footer: String?
        func validate() throws {
            guard !(title ?? "").isEmpty || !(description ?? "").isEmpty else { throw ValidationError.invalidValue("An embed needs a title or description") }
            guard (title ?? "").count <= 256, (description ?? "").count <= 4096, (footer ?? "").count <= 2048,
                (title ?? "").count + (description ?? "").count + (footer ?? "").count <= 6000
            else { throw ValidationError.invalidValue("Embed text exceeds Discord's limits") }
            if let color, !(0...0xFFFFFF).contains(color) { throw ValidationError.invalidValue("Invalid embed color") }
            for value in [imageURL, thumbnailURL].compactMap({ $0 }).filter({ !$0.isEmpty }) {
                guard let url = URL(string: value), url.scheme == "https", url.host != nil else {
                    throw ValidationError.invalidValue("Embed images need HTTPS URLs")
                }
            }
        }
    }
    @Generable
    struct Schedule: Codable, Hashable, Sendable, Validatable {
        @Generable
        enum RepeatKind: String, Codable, Hashable, Sendable, CaseIterable { case once, daily, weekly, interval }
        var startAt: String
        var timeZone: String
        var repeatKind: RepeatKind
        var intervalSeconds: Int?
        static func parse(_ value: String) -> Date? {
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return format.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        func validate() throws {
            guard Self.parse(startAt) != nil, TimeZone(identifier: timeZone) != nil else {
                throw ValidationError.invalidValue("Choose a valid schedule time and time zone")
            }
            if repeatKind == .interval, !(60...2_592_000).contains(intervalSeconds ?? 0) {
                throw ValidationError.invalidValue("Repeat interval must be 1 minute to 30 days")
            }
        }
        /// Calendar arithmetic preserves local wall-clock time across daylight-saving changes.
        func latestOccurrence(at now: Date) -> Date? {
            guard let start = Self.parse(startAt), start <= now else { return nil }
            if repeatKind == .once { return start }
            if repeatKind == .interval {
                let interval = Double(max(60, intervalSeconds ?? 60))
                return start.addingTimeInterval(floor(now.timeIntervalSince(start) / interval) * interval)
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
            let component: Calendar.Component = repeatKind == .daily ? .day : .weekOfYear
            let count = max(0, calendar.dateComponents([component], from: start, to: now).value(for: component) ?? 0)
            guard var candidate = calendar.date(byAdding: component, value: count, to: start) else { return nil }
            if candidate > now { candidate = calendar.date(byAdding: component, value: -1, to: candidate) ?? start }
            if let next = calendar.date(byAdding: component, value: 1, to: candidate), next <= now { return next }
            return candidate
        }
        func nextOccurrence(after now: Date) -> Date? {
            guard let start = Self.parse(startAt) else { return nil }
            if start > now { return start }
            if repeatKind == .once { return nil }
            guard let latest = latestOccurrence(at: now) else { return nil }
            if repeatKind == .interval { return latest.addingTimeInterval(Double(max(60, intervalSeconds ?? 60))) }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
            return calendar.date(byAdding: repeatKind == .daily ? .day : .weekOfYear, value: 1, to: latest)
        }
    }
}
extension Automations.Rule {
    static func validateGroups(_ groups: [Automations.ConditionGroup]) throws {
        guard groups.count <= 32, Set(groups.map(\.id)).count == groups.count else {
            throw ValidationError.invalidValue("Use at most 32 uniquely identified condition groups")
        }
        let ids = Set(groups.map(\.id))
        for group in groups {
            for filter in group.filters { try filter.validate() }
            var seen: Set<String> = [group.id]
            var parent = group.parentId
            while let id = parent {
                guard ids.contains(id), seen.insert(id).inserted else {
                    throw ValidationError.invalidValue("Condition groups contain a missing parent or cycle")
                }
                parent = groups.first(where: { $0.id == id })?.parentId
            }
            guard !group.filters.isEmpty || groups.contains(where: { $0.parentId == group.id }) else {
                throw ValidationError.invalidValue("Every condition group needs a condition")
            }
        }
    }
}
