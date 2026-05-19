import Foundation

/// A ready-made `Automations.Rule` the user can clone and tweak. Replaces
/// the legacy `RecipeTemplate` from the deleted block-builder.
///
/// Templates carry a fully-populated `Rule` so they appear in the editor
/// the same way as a hand-built one — the user just picks one, the rule
/// opens in the editor sheet with `isNew: true`, and Save commits it.
struct AutomationTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let tint: TemplateTint
    let rule: Automations.Rule

    enum TemplateTint: Hashable {
        case blue, green, purple, orange, red, indigo
    }

    static var catalog: [AutomationTemplate] { automationCatalog + moderationCatalog }

    /// Templates filtered to a specific category. Each template's rule is
    /// already tagged with the matching category, so we just filter.
    static func catalog(for category: Automations.Category) -> [AutomationTemplate] {
        switch category {
        case .automation: return automationCatalog
        case .moderation: return moderationCatalog
        }
    }

    static let automationCatalog: [AutomationTemplate] = [

        AutomationTemplate(
            id: "voice-join-announce",
            title: "Voice join announcement",
            subtitle: "When someone joins a voice channel, post a connection notice in a text channel.",
            symbol: "speaker.wave.2.fill",
            tint: .green,
            rule: Automations.Rule(
                name: "Voice join announcement",
                trigger: Automations.Trigger(kind: .userJoinedVoice),
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .specificChannel,
                        content: "🔊 {userMention} connected to {channelName}"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "voice-leave-announce",
            title: "Voice leave announcement",
            subtitle: "When someone leaves voice, post how long they were in.",
            symbol: "speaker.slash.fill",
            tint: .orange,
            rule: Automations.Rule(
                name: "Voice leave announcement",
                trigger: Automations.Trigger(kind: .userLeftVoice),
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .specificChannel,
                        content: "🔇 {userMention} disconnected from {channelName} (Online For {duration})"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "trigger-message",
            title: "Trigger message",
            subtitle: "When someone posts a keyword, reply with a canned response.",
            symbol: "text.bubble.fill",
            tint: .blue,
            rule: Automations.Rule(
                name: "Trigger message",
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageContains, text: "hello")
                ],
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .replyToTrigger,
                        content: "Hey {username}! 👋"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "welcome-dm",
            title: "Welcome DM",
            subtitle: "DM a friendly hello to new members.",
            symbol: "hand.wave.fill",
            tint: .green,
            rule: Automations.Rule(
                name: "Welcome DM",
                trigger: Automations.Trigger(kind: .memberJoined),
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .directMessage,
                        content: "Hey {username}, welcome to {guildName}! 👋"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "ai-welcome",
            title: "AI Welcome",
            subtitle: "Let Apple Intelligence write a unique welcome for each new member.",
            symbol: "sparkles",
            tint: .purple,
            rule: Automations.Rule(
                name: "AI welcome",
                trigger: Automations.Trigger(kind: .memberJoined),
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .directMessage,
                        aiPrompt: "Write a short, warm welcome message for {username} joining {guildName}."
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "keyword-reaction",
            title: "Keyword reaction",
            subtitle: "React with an emoji whenever a message contains a keyword.",
            symbol: "face.smiling",
            tint: .blue,
            rule: Automations.Rule(
                name: "Keyword reaction",
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageContains, text: "eyes")
                ],
                steps: [
                    Automations.Step(
                        kind: .modifyMessage,
                        messageOp: .react,
                        reactEmoji: "👀"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "summarize-long",
            title: "Summarize walls of text",
            subtitle: "AI-summarize any message over 500 characters and post the summary as a reply.",
            symbol: "doc.text.below.ecg",
            tint: .purple,
            rule: Automations.Rule(
                name: "Summarize long posts",
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageMatchesRegex, text: "^.{500,}$")
                ],
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .replyToTrigger,
                        aiPrompt: "Summarize this message in one sentence: {message}"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "media-announce",
            title: "Media announcer",
            subtitle: "Wait 10 seconds after media is added, then announce it in a channel.",
            symbol: "music.note",
            tint: .indigo,
            rule: Automations.Rule(
                name: "Media announcement",
                trigger: Automations.Trigger(kind: .mediaAdded),
                steps: [
                    Automations.Step(kind: .delay, delaySeconds: 10),
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .specificChannel,
                        content: "{mediaFile} is ready"
                    )
                ]
            )
        ),
    ]

    // MARK: - Moderation catalog
    //
    // Includes both block-bad-stuff rules and audit/log rules. Logging
    // member joins/leaves and voice sessions is server-management work,
    // not "do something cool", so it lives here.

    static let moderationCatalog: [AutomationTemplate] = [

        AutomationTemplate(
            id: "mod-leave-log",
            title: "Member leave log",
            subtitle: "Write a log entry when a member leaves the server.",
            symbol: "door.left.hand.open",
            tint: .orange,
            rule: Automations.Rule(
                name: "Member leave log",
                category: .moderation,
                trigger: Automations.Trigger(kind: .memberLeft),
                steps: [
                    Automations.Step(
                        kind: .log,
                        logText: "{username} left {guildName}"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-voice-log",
            title: "Voice session log",
            subtitle: "Log when someone leaves a voice channel and how long they were in.",
            symbol: "waveform",
            tint: .indigo,
            rule: Automations.Rule(
                name: "Voice session log",
                category: .moderation,
                trigger: Automations.Trigger(kind: .userLeftVoice),
                steps: [
                    Automations.Step(
                        kind: .log,
                        logText: "{username} left voice after {duration}"
                    )
                ]
            )
        ),


        AutomationTemplate(
            id: "mod-link-cleanup",
            title: "Banned link filter",
            subtitle: "Delete messages containing a banned URL and DM the user a warning.",
            symbol: "link.badge.plus",
            tint: .red,
            rule: Automations.Rule(
                name: "Banned link filter",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageContains, text: "example.com/spam")
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete),
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .directMessage,
                        content: "Hi {username}, your message in #{channelName} was removed because it contained a disallowed link."
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-bad-words",
            title: "Word filter",
            subtitle: "Delete messages containing any blocked word from a list.",
            symbol: "exclamationmark.bubble.fill",
            tint: .red,
            rule: Automations.Rule(
                name: "Blocked-word filter",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filterLogic: .any,
                filters: [
                    Automations.Filter(kind: .messageContains, text: "badword1"),
                    Automations.Filter(kind: .messageContains, text: "badword2")
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete)
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-muted",
            title: "Muted enforcement",
            subtitle: "Delete and time out any post from a user with the Muted role.",
            symbol: "speaker.slash.fill",
            tint: .red,
            rule: Automations.Rule(
                name: "Muted enforcement",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .userHasAnyRole, roleIds: [])
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete),
                    Automations.Step(
                        kind: .modifyMember,
                        memberOp: .timeout,
                        timeoutSeconds: 300
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-caps-spam",
            title: "ALL-CAPS filter",
            subtitle: "Delete shouty messages (mostly uppercase letters).",
            symbol: "textformat.size.larger",
            tint: .orange,
            rule: Automations.Rule(
                name: "ALL-CAPS filter",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageMatchesRegex, text: "^[A-Z\\s!?.,]{12,}$")
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete)
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-bot-cleanup",
            title: "Auto-delete bot messages",
            subtitle: "Delete every message posted by a bot in a specific channel.",
            symbol: "person.crop.square.badge.camera",
            tint: .orange,
            rule: Automations.Rule(
                name: "Auto-delete bot messages",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .fromBot, boolValue: true)
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete)
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-kick-keyword",
            title: "Auto-kick keyword",
            subtitle: "Kick any user whose message contains an egregious keyword.",
            symbol: "person.fill.xmark",
            tint: .red,
            rule: Automations.Rule(
                name: "Auto-kick on keyword",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageContains, text: "")
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete),
                    Automations.Step(kind: .modifyMember, memberOp: .kick, kickReason: "Disallowed content")
                ]
            )
        ),
    ]
}
