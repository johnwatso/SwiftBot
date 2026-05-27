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

        init(
            id: String = UUID().uuidString,
            name: String,
            enabled: Bool = true,
            category: Category = .automation,
            trigger: Trigger,
            filterLogic: FilterLogic = .all,
            filters: [Filter] = [],
            steps: [Step]
        ) {
            self.id = id
            self.name = name
            self.enabled = enabled
            self.category = category
            self.trigger = trigger
            self.filterLogic = filterLogic
            self.filters = filters
            self.steps = steps
        }

        func validate() throws {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.invalidValue("Rule name cannot be empty")
            }
            try trigger.validate()
            for filter in filters {
                try filter.validate()
            }
            for step in steps {
                try step.validate()
            }
        }
    }

    @Generable
    enum Category: String, Codable, Hashable, Sendable, CaseIterable {
        case automation
        case moderation
    }

    @Generable
    enum FilterLogic: String, Codable, Hashable, Sendable, CaseIterable {
        case all   // AND
        case any   // OR
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

        static func visibleCases(for category: Category) -> [TriggerKind] {
            switch category {
            case .automation:
                return allCases
            case .moderation:
                return [
                    .messageCreated,
                    .memberJoined,
                    .memberLeft,
                    .userJoinedVoice,
                    .userLeftVoice,
                    .userMovedVoice,
                    .reactionAdded,
                    .slashCommand
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

        func validate() throws {
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
        case inChannel                  // channelIds: at least one matches event.channelId
        case directMessage              // boolValue: true = DMs only, false = guild only
        // User
        case userIsOneOf                // userIds
        case userHasAnyRole             // roleIds
        case userHasAllRoles            // roleIds
        case userHasNoneOfRoles         // roleIds
        // Message content
        case messageContains            // text (case-insensitive substring)
        case messageContainsAny         // textValues (any substring matches)
        case messageEquals              // text (exact, trimmed)
        case messageDoesNotContain      // text
        case messageMatchesRegex        // text
        case messageIsReply             // boolValue: true = is reply, false = is not
        // Author
        case fromBot                    // boolValue
        // Voice
        case minVoiceDurationSeconds    // intValue
        // Reaction
        case reactionEmoji              // text
        // Media
        case mediaSource                // text
        // Moderation
        case messageContainsSpamLink
        case messageCapsPercentage
        case messageMentionsCount
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

        init(
            id: String = UUID().uuidString,
            kind: FilterKind,
            channelIds: [String]? = nil,
            roleIds: [String]? = nil,
            userIds: [String]? = nil,
            text: String? = nil,
            textValues: [String]? = nil,
            boolValue: Bool? = nil,
            intValue: Int? = nil
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
        }

        func validate() throws {
            switch kind {
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
        case kick
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

        @Guide(description: "For sendMessage: where to send. Default replyToTrigger for message triggers, sameChannel for voice triggers, directMessage for member triggers.")
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

        @Guide(description: "For kick: reason string.")
        var kickReason: String?

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

        @Guide(description: "For webhook: body content.")
        var webhookContent: String?

        @Guide(description: "For delay: seconds to wait before the next step.")
        var delaySeconds: Int?

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
            targetVoiceChannelId: String? = nil,
            messageOp: MessageOp? = nil,
            reactEmoji: String? = nil,
            logText: String? = nil,
            webhookUrl: String? = nil,
            webhookContent: String? = nil,
            delaySeconds: Int? = nil
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
            self.targetVoiceChannelId = targetVoiceChannelId
            self.messageOp = messageOp
            self.reactEmoji = reactEmoji
            self.logText = logText
            self.webhookUrl = webhookUrl
            self.webhookContent = webhookContent
            self.delaySeconds = delaySeconds
        }

        func validate() throws {
            switch kind {
            case .webhook:
                try validateSecureURL(webhookUrl)
            case .delay:
                if let val = delaySeconds {
                    if val < 0 || val > 3600 {
                        throw ValidationError.outOfRange("delaySeconds", min: 0, max: 3600)
                    }
                }
            case .modifyMember:
                if memberOp == .timeout, let val = timeoutSeconds {
                    if val < 0 || val > 2419200 { // 28 days
                        throw ValidationError.outOfRange("timeoutSeconds", min: 0, max: 2419200)
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: - Template variables

    enum Variable: String, CaseIterable {
        case username       = "{username}"
        case userId         = "{userId}"
        case userMention    = "{userMention}"
        case channelName    = "{channelName}"
        case channelId      = "{channelId}"
        case guildName      = "{guildName}"
        case guildId        = "{guildId}"
        case message        = "{message}"
        case messageId      = "{messageId}"
        case duration       = "{duration}"
        case mediaFile      = "{mediaFile}"
        case mediaSource    = "{mediaSource}"

        static var allTokens: [String] { allCases.map(\.rawValue) }

        var label: String {
            switch self {
            case .username:    return "User's name"
            case .userId:      return "User ID"
            case .userMention: return "User @-mention"
            case .channelName: return "Channel name"
            case .channelId:   return "Channel ID"
            case .guildName:   return "Server name"
            case .guildId:     return "Server ID"
            case .message:     return "Message text"
            case .messageId:   return "Message ID"
            case .duration:    return "Voice session duration"
            case .mediaFile:   return "Media file name"
            case .mediaSource: return "Media source"
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
            }
        }
    }

    // MARK: - Simulation Trace Models

    struct FilterTrace: Sendable, Hashable, Identifiable {
        var id: String { filterId }
        let filterId: String
        let kind: FilterKind
        let matched: Bool
        let detail: String
    }

    struct StepTrace: Sendable, Hashable, Identifiable {
        var id: String { stepId }
        let stepId: String
        let kind: StepKind
        let executed: Bool
        let detail: String
    }

    struct SimulationResult: Sendable, Hashable {
        let triggerMatched: Bool
        let filtersMatched: Bool
        let filterTraces: [FilterTrace]
        let stepTraces: [StepTrace]
    }
}
