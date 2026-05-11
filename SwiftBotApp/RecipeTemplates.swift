import Foundation

/// A prebuilt automation recipe ("if this then that" style).
/// Picking a template + filling in 1–2 fields yields a complete `Rule`.
struct RecipeTemplate: Identifiable, Hashable {
    enum Field: Hashable {
        case textChannel              // Discord text channel picker (required, used as action target)
        case voiceChannel             // Discord voice channel picker (required, used as action target)
        case role                     // Server role picker
        case message                  // Message body (textarea)
        case keyword                  // Plain string for messageContains condition
        case emoji                    // Single emoji
        case optionalVoiceFilter      // Optional: restrict trigger to one voice channel
        case optionalTextChannelFilter // Optional: restrict trigger to one text channel
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let trigger: TriggerType
    let actionType: ActionType
    let fields: [Field]
    /// Pre-filled message template using the trigger's placeholders.
    let messageDraft: String
    /// Optional condition the template wires up automatically (uses `keyword` field if any).
    let conditionType: ConditionType?

    static let catalog: [RecipeTemplate] = [
        RecipeTemplate(
            id: "welcome-members",
            title: "Welcome new members",
            subtitle: "Greets each new member in a chosen channel.",
            symbol: "hand.wave.fill",
            trigger: .memberJoined,
            actionType: .sendMessage,
            fields: [.textChannel, .message],
            messageDraft: "👋 Welcome to {server}, <@{userId}>! You're member #{memberCount}.",
            conditionType: nil
        ),
        RecipeTemplate(
            id: "welcome-dm",
            title: "Send a welcome DM",
            subtitle: "DMs each new member with a custom note.",
            symbol: "envelope.fill",
            trigger: .memberJoined,
            actionType: .sendDM,
            fields: [.message],
            messageDraft: "Hey {username}, welcome to {server}! Let me know if you need anything.",
            conditionType: nil
        ),
        RecipeTemplate(
            id: "auto-role-on-join",
            title: "Auto-assign a role on join",
            subtitle: "Gives every new member a role automatically.",
            symbol: "person.crop.circle.badge.plus",
            trigger: .memberJoined,
            actionType: .addRole,
            fields: [.role],
            messageDraft: "",
            conditionType: nil
        ),
        RecipeTemplate(
            id: "goodbye-members",
            title: "Goodbye message",
            subtitle: "Posts when a member leaves the server.",
            symbol: "door.right.hand.open",
            trigger: .memberLeft,
            actionType: .sendMessage,
            fields: [.textChannel, .message],
            messageDraft: "👋 {username} left the server.",
            conditionType: nil
        ),
        RecipeTemplate(
            id: "voice-join-log",
            title: "Log voice channel joins",
            subtitle: "Posts a notice when someone joins voice.",
            symbol: "waveform.badge.plus",
            trigger: .userJoinedVoice,
            actionType: .sendMessage,
            fields: [.optionalVoiceFilter, .textChannel, .message],
            messageDraft: "🔊 <@{userId}> connected to <#{channelId}>",
            conditionType: nil
        ),
        RecipeTemplate(
            id: "voice-leave-log",
            title: "Log voice channel leaves",
            subtitle: "Posts a notice when someone leaves voice.",
            symbol: "waveform.badge.minus",
            trigger: .userLeftVoice,
            actionType: .sendMessage,
            fields: [.optionalVoiceFilter, .textChannel, .message],
            messageDraft: "🔌 <@{userId}> disconnected from <#{channelId}> (online for {duration})",
            conditionType: nil
        ),
        RecipeTemplate(
            id: "keyword-reply",
            title: "Auto-reply to a keyword",
            subtitle: "Replies whenever a message contains a phrase.",
            symbol: "text.bubble.fill",
            trigger: .messageCreated,
            actionType: .sendMessage,
            fields: [.keyword, .optionalTextChannelFilter, .message],
            messageDraft: "👋 Hey <@{userId}>!",
            conditionType: .messageContains
        ),
        RecipeTemplate(
            id: "auto-react-media",
            title: "Auto-react to new media",
            subtitle: "Adds a reaction whenever new media is detected.",
            symbol: "face.smiling.inverse",
            trigger: .mediaAdded,
            actionType: .addReaction,
            fields: [.emoji],
            messageDraft: "",
            conditionType: nil
        ),
        RecipeTemplate(
            id: "keyword-react",
            title: "Auto-react to a keyword",
            subtitle: "Reacts to messages containing a phrase.",
            symbol: "face.smiling",
            trigger: .messageCreated,
            actionType: .addReaction,
            fields: [.keyword, .emoji],
            messageDraft: "",
            conditionType: .messageContains
        ),
        RecipeTemplate(
            id: "reaction-notify",
            title: "Notify on reaction",
            subtitle: "Posts to a channel when someone reacts.",
            symbol: "bell.badge.fill",
            trigger: .reactionAdded,
            actionType: .sendMessage,
            fields: [.textChannel, .message],
            messageDraft: "👀 <@{userId}> reacted with {reaction.emoji}",
            conditionType: nil
        )
    ]
}

/// User-supplied values for a recipe's fields, keyed by `Field`.
struct RecipeFieldValues: Equatable {
    var textChannelId: String = ""
    var voiceChannelId: String = ""
    var roleId: String = ""
    var message: String = ""
    var keyword: String = ""
    var emoji: String = "👍"
    var filterVoiceChannelId: String = ""    // Optional: condition restricting voice trigger
    var filterTextChannelId: String = ""     // Optional: condition restricting message trigger

    func isComplete(for template: RecipeTemplate) -> Bool {
        for field in template.fields {
            switch field {
            case .textChannel: if textChannelId.isEmpty { return false }
            case .voiceChannel: if voiceChannelId.isEmpty { return false }
            case .role: if roleId.isEmpty { return false }
            case .message: if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            case .keyword: if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            case .emoji: if emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            case .optionalVoiceFilter, .optionalTextChannelFilter:
                continue // optional fields never block "complete"
            }
        }
        return true
    }
}

enum RecipeBuilder {
    /// Produces a `Rule` from a template, the user's field values, and the chosen server.
    static func makeRule(template: RecipeTemplate, values: RecipeFieldValues, serverId: String) -> Rule {
        var rule = Rule.empty()
        rule.name = template.title
        rule.trigger = template.trigger
        rule.triggerServerId = serverId

        // Conditions
        var conditions: [Condition] = []
        if !serverId.isEmpty {
            conditions.append(Condition(type: .server, value: serverId))
        }
        if let cond = template.conditionType, template.fields.contains(.keyword) {
            conditions.append(Condition(type: cond, value: values.keyword))
        }
        if template.fields.contains(.optionalVoiceFilter), !values.filterVoiceChannelId.isEmpty {
            conditions.append(Condition(type: .voiceChannel, value: values.filterVoiceChannelId))
        }
        if template.fields.contains(.optionalTextChannelFilter), !values.filterTextChannelId.isEmpty {
            conditions.append(Condition(type: .channelIs, value: values.filterTextChannelId))
        }
        rule.conditions = conditions

        // Action
        var action = RuleAction()
        action.type = template.actionType
        action.serverId = serverId

        switch template.actionType {
        case .sendMessage:
            action.channelId = values.textChannelId
            action.message = values.message.isEmpty ? template.messageDraft : values.message
            action.destinationMode = values.textChannelId.isEmpty
                ? MessageDestination.defaultMode(for: template.trigger)
                : .specificChannel
        case .sendDM:
            action.dmContent = values.message.isEmpty ? template.messageDraft : values.message
        case .addReaction:
            action.emoji = values.emoji
        case .addRole, .removeRole:
            action.roleId = values.roleId
        case .moveMember:
            action.targetVoiceChannelId = values.voiceChannelId
        default:
            break
        }

        rule.actions = [action]
        return rule
    }

    /// Produces a minimal `Rule` for "from scratch" — just a trigger picked, ready for the canvas editor.
    static func makeBlankRule(trigger: TriggerType, serverId: String) -> Rule {
        var rule = Rule.empty()
        rule.name = trigger.defaultRuleName
        rule.trigger = trigger
        rule.triggerServerId = serverId
        if !serverId.isEmpty {
            rule.conditions = [Condition(type: .server, value: serverId)]
        }
        return rule
    }
}
