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
    struct Rule: Codable, Identifiable, Hashable, Sendable {
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
    }

    /// Lean trigger — only the params that *define* the trigger itself (a
    /// slash command without a name is meaningless). Everything else
    /// (channel, role, message content, etc.) is expressed as a Filter.
    @Generable
    struct Trigger: Codable, Hashable, Sendable {
        @Guide(description: "Which Discord event fires this rule.")
        var kind: TriggerKind

        @Guide(description: "For slashCommand: command name without the leading slash. Required when kind is slashCommand.")
        var commandName: String?
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
    }

    @Generable
    struct Filter: Codable, Hashable, Sendable, Identifiable {
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
    struct Step: Codable, Hashable, Sendable, Identifiable {
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
}
