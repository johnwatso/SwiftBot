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
            id: "voice-join-notify",
            title: "Voice join notify",
            subtitle: "Announce in the voice channel when someone joins.",
            symbol: "speaker.wave.2.fill",
            tint: .green,
            rule: Automations.Rule(
                name: "Voice join notify",
                trigger: Automations.Trigger(kind: .userJoinedVoice),
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .sameChannel,
                        content: "🔊 {userMention} has joined #{channelName}"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "voice-leave-notify",
            title: "Voice leave notify",
            subtitle: "Announce in the voice channel when someone leaves, with their session length.",
            symbol: "speaker.slash.fill",
            tint: .orange,
            rule: Automations.Rule(
                name: "Voice leave notify",
                trigger: Automations.Trigger(kind: .userLeftVoice),
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .sameChannel,
                        content: "👋 {userMention} has left #{channelName} ({duration})"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "faq-responder",
            title: "FAQ responder",
            subtitle: "Reply with a canned answer when someone asks a common question.",
            symbol: "text.bubble.fill",
            tint: .blue,
            rule: Automations.Rule(
                name: "FAQ responder",
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageContains, text: "how do I")
                ],
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .replyToTrigger,
                        content: "Hey {username}, check the pinned guide in this channel."
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "keyword-reaction",
            title: "Keyword reaction",
            subtitle: "React with an emoji whenever a message contains a chosen keyword.",
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
            id: "summarize-long-post",
            title: "Summarize long post",
            subtitle: "AI-summarize any message over 500 characters and reply with the summary.",
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
            id: "keyword-webhook",
            title: "Keyword webhook",
            subtitle: "Call a webhook when a message contains an important keyword.",
            symbol: "network",
            tint: .purple,
            rule: Automations.Rule(
                name: "Keyword webhook",
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageContains, text: "incident")
                ],
                steps: [
                    Automations.Step(
                        kind: .webhook,
                        webhookUrl: "https://hooks.example.com/swiftbot",
                        webhookContent: "{username} in {guildName}: {message}"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "media-announce",
            title: "Media announcer",
            subtitle: "Wait 10 seconds after media is added, then announce that it is ready.",
            symbol: "movieclapper.fill",
            tint: .indigo,
            rule: Automations.Rule(
                name: "Media announcement",
                trigger: Automations.Trigger(kind: .mediaAdded),
                steps: [
                    Automations.Step(kind: .delay, delaySeconds: 10),
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .sameChannel,
                        content: "{mediaFile} is ready"
                    )
                ]
            )
        ),

        // MARK: Voice

        AutomationTemplate(
            id: "voice-move-notify",
            title: "Voice move notice",
            subtitle: "Post in the new channel when someone hops between voice channels.",
            symbol: "arrow.left.arrow.right",
            tint: .blue,
            rule: Automations.Rule(
                name: "Voice move notice",
                trigger: Automations.Trigger(kind: .userMovedVoice),
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .sameChannel,
                        content: "🔀 {userMention} moved to #{channelName}"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "voice-marathon-shoutout",
            title: "Long session shout-out",
            subtitle: "Celebrate anyone who spends two hours or more in voice.",
            symbol: "trophy.fill",
            tint: .orange,
            rule: Automations.Rule(
                name: "Long session shout-out",
                trigger: Automations.Trigger(kind: .userLeftVoice),
                filters: [
                    Automations.Filter(kind: .minVoiceDurationSeconds, intValue: 7200)
                ],
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .sameChannel,
                        content: "🏆 {userMention} just wrapped a {duration} session in #{channelName}!"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "voice-role-add",
            title: "In Voice role: add",
            subtitle: "Give members a role while they're in voice. Pick the role, then turn it on.",
            symbol: "person.badge.plus",
            tint: .green,
            rule: Automations.Rule(
                name: "In Voice role: add",
                enabled: false,
                trigger: Automations.Trigger(kind: .userJoinedVoice),
                steps: [
                    Automations.Step(kind: .modifyMember, memberOp: .addRole)
                ]
            )
        ),

        AutomationTemplate(
            id: "voice-role-remove",
            title: "In Voice role: remove",
            subtitle: "Take the In Voice role away when members leave voice. Pick the same role.",
            symbol: "person.badge.minus",
            tint: .orange,
            rule: Automations.Rule(
                name: "In Voice role: remove",
                enabled: false,
                trigger: Automations.Trigger(kind: .userLeftVoice),
                steps: [
                    Automations.Step(kind: .modifyMember, memberOp: .removeRole)
                ]
            )
        ),

        // MARK: Messages

        AutomationTemplate(
            id: "thanks-reaction",
            title: "Thank-you reaction",
            subtitle: "React with 🙏 when someone says thanks.",
            symbol: "hands.clap.fill",
            tint: .green,
            rule: Automations.Rule(
                name: "Thank-you reaction",
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageContainsAny, textValues: ["thanks", "thank you", "thx", "ty"])
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .react, reactEmoji: "🙏")
                ]
            )
        ),

        AutomationTemplate(
            id: "gg-reaction",
            title: "GG reaction",
            subtitle: "Celebrate with 🎉 whenever someone says GG.",
            symbol: "party.popper.fill",
            tint: .purple,
            rule: Automations.Rule(
                name: "GG reaction",
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageContainsAny, textValues: ["gg", "good game"])
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .react, reactEmoji: "🎉")
                ]
            )
        ),

        AutomationTemplate(
            id: "translate-on-request",
            title: "Translate on request",
            subtitle: "Reply with an English translation when a message starts with “translate:”.",
            symbol: "character.bubble.fill",
            tint: .indigo,
            rule: Automations.Rule(
                name: "Translate on request",
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageMatchesRegex, text: "(?i)^translate:")
                ],
                steps: [
                    Automations.Step(
                        kind: .aiTransform,
                        aiPrompt: "Translate the text after 'translate:' into natural English. Reply with only the translation: {message}"
                    ),
                    Automations.Step(kind: .sendMessage, sendTarget: .replyToTrigger, content: "🌐 {ai_output}")
                ]
            )
        ),

        AutomationTemplate(
            id: "link-log",
            title: "Link log",
            subtitle: "Keep a local log of every link people share.",
            symbol: "link",
            tint: .blue,
            rule: Automations.Rule(
                name: "Link log",
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageMatchesRegex, text: #"https?://\S+"#),
                    Automations.Filter(kind: .fromBot, boolValue: false)
                ],
                steps: [
                    Automations.Step(kind: .log, logText: "{username} shared a link in #{channelName}: {message}")
                ]
            )
        ),

        // MARK: Reactions & commands

        AutomationTemplate(
            id: "star-reaction-log",
            title: "Starred messages",
            subtitle: "Log messages people react to with ⭐ so you can find highlights later.",
            symbol: "star.fill",
            tint: .orange,
            rule: Automations.Rule(
                name: "Starred messages",
                trigger: Automations.Trigger(kind: .reactionAdded, reactionEmoji: "⭐"),
                steps: [
                    Automations.Step(kind: .log, logText: "{username} starred a message in #{channelName}")
                ]
            )
        ),

        AutomationTemplate(
            id: "rules-command",
            title: "/rules command",
            subtitle: "Answer a /rules slash command with your server rules.",
            symbol: "list.bullet.rectangle",
            tint: .blue,
            rule: Automations.Rule(
                name: "/rules command",
                trigger: Automations.Trigger(kind: .slashCommand, commandName: "rules"),
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .replyToTrigger,
                        content: "📜 **{guildName} rules**\n1. Be kind.\n2. No spam or self-promo.\n3. Keep it on topic."
                    )
                ]
            )
        ),
    ]

    // MARK: - Moderation catalog
    //
    // Focus on templates that map cleanly to moderation actions the engine
    // can execute today: delete, DM, timeout, kick, and local audit logging.
    // Avoid role-filter examples until member role state is plumbed through
    // SwiftBotEvent; those filters are currently informational in the UI.

    static let moderationCatalog: [AutomationTemplate] = [

        AutomationTemplate(
            id: "mod-banned-link-cleanup",
            title: "Banned link cleanup",
            subtitle: "Delete messages containing a banned URL and DM the user a warning.",
            symbol: "link.badge.plus",
            tint: .red,
            rule: Automations.Rule(
                name: "Banned link cleanup",
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
            id: "mod-discord-invite-block",
            title: "Invite link blocker",
            subtitle: "Remove unsolicited Discord invites and send the user a short warning.",
            symbol: "person.2.badge.minus",
            tint: .red,
            rule: Automations.Rule(
                name: "Invite link blocker",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageMatchesRegex, text: #"(?i)(discord\.gg|discord\.com/invite)/[a-z0-9-]+"#)
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete),
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .directMessage,
                        content: "Hi {username}, invite links are not allowed here unless a moderator approves them."
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-blocked-words-delete",
            title: "Blocked word filter",
            subtitle: "Delete messages containing any blocked phrase from a starter list.",
            symbol: "exclamationmark.bubble.fill",
            tint: .red,
            rule: Automations.Rule(
                name: "Blocked word filter",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filterLogic: .any,
                filters: [
                    Automations.Filter(kind: .messageContainsAny, textValues: ["badword1", "badword2"])
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete)
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-blocked-words-timeout",
            title: "Blocked word timeout",
            subtitle: "Delete a severe phrase and timeout the user for five minutes.",
            symbol: "timer",
            tint: .red,
            rule: Automations.Rule(
                name: "Blocked word timeout",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageContains, text: "severe-keyword")
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
            id: "mod-mention-spam-timeout",
            title: "Mention spam timeout",
            subtitle: "Delete messages with repeated user mentions and timeout the sender.",
            symbol: "at.badge.plus",
            tint: .red,
            rule: Automations.Rule(
                name: "Mention spam timeout",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageMatchesRegex, text: #"(<@!?\d+>.*){5,}"#)
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete),
                    Automations.Step(
                        kind: .modifyMember,
                        memberOp: .timeout,
                        timeoutSeconds: 600
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-caps-spam",
            title: "ALL-CAPS cleanup",
            subtitle: "Delete shouty messages that are mostly uppercase letters.",
            symbol: "textformat.size.larger",
            tint: .orange,
            rule: Automations.Rule(
                name: "ALL-CAPS cleanup",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageMatchesRegex, text: #"^[A-Z\s!?.,]{12,}$"#)
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete)
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-secret-leak-cleanup",
            title: "Secret leak cleanup",
            subtitle: "Delete likely token or key leaks before they linger in chat.",
            symbol: "key.slash.fill",
            tint: .orange,
            rule: Automations.Rule(
                name: "Secret leak cleanup",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageMatchesRegex, text: #"(?i)(token|api[_ -]?key|secret)\s*[:=]\s*\S{12,}"#)
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete),
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .directMessage,
                        content: "Hi {username}, SwiftBot removed a message that looked like it might contain a secret. Please rotate the exposed key if it was real."
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-bot-message-cleanup",
            title: "Bot message cleanup",
            subtitle: "Delete bot-authored messages. Add a channel condition before enabling broadly.",
            symbol: "person.crop.square.badge.camera",
            tint: .orange,
            rule: Automations.Rule(
                name: "Bot message cleanup",
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
            id: "mod-severe-keyword-kick",
            title: "Severe keyword kick",
            subtitle: "Delete a message containing a severe keyword and kick the user.",
            symbol: "person.fill.xmark",
            tint: .red,
            rule: Automations.Rule(
                name: "Severe keyword kick",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageContains, text: "severe-keyword")
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete),
                    Automations.Step(kind: .modifyMember, memberOp: .kick, kickReason: "Disallowed content")
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-member-join-audit",
            title: "Member join audit",
            subtitle: "Write a local audit entry when a member joins the server.",
            symbol: "person.crop.circle.badge.plus",
            tint: .green,
            rule: Automations.Rule(
                name: "Member join audit",
                category: .moderation,
                trigger: Automations.Trigger(kind: .memberJoined),
                steps: [
                    Automations.Step(
                        kind: .log,
                        logText: "{username} joined {guildName}"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-voice-join-audit",
            title: "Voice join audit",
            subtitle: "Write a local audit entry when someone joins a voice channel.",
            symbol: "speaker.wave.2.fill",
            tint: .green,
            rule: Automations.Rule(
                name: "Voice join audit",
                category: .moderation,
                trigger: Automations.Trigger(kind: .userJoinedVoice),
                steps: [
                    Automations.Step(
                        kind: .log,
                        logText: "{username} joined #{channelName}"
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-member-leave-audit",
            title: "Member leave audit",
            subtitle: "Write a local audit entry when a member leaves the server.",
            symbol: "door.left.hand.open",
            tint: .orange,
            rule: Automations.Rule(
                name: "Member leave audit",
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

        // MARK: Scams & spam

        AutomationTemplate(
            id: "mod-scam-link-timeout",
            title: "Scam link blocker",
            subtitle: "Delete free-Nitro and gift scam links, timeout the sender for an hour and log it.",
            symbol: "exclamationmark.shield.fill",
            tint: .red,
            rule: Automations.Rule(
                name: "Scam link blocker",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageContainsSpamLink)
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete),
                    Automations.Step(kind: .modifyMember, memberOp: .timeout, timeoutSeconds: 3600),
                    Automations.Step(kind: .log, logText: "Removed a scam link from {username} in #{channelName}")
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-caps-warning",
            title: "Shouting warning",
            subtitle: "Gently remind people when a message is 80% or more capital letters.",
            symbol: "speaker.wave.3.fill",
            tint: .orange,
            rule: Automations.Rule(
                name: "Shouting warning",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageCapsPercentage, intValue: 80),
                    Automations.Filter(kind: .fromBot, boolValue: false)
                ],
                steps: [
                    Automations.Step(kind: .sendMessage, sendTarget: .replyToTrigger, content: "Easy on the caps, {username} 🙂")
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-mass-mention-kick",
            title: "Mass mention kick",
            subtitle: "Delete messages that ping 10 or more people and kick the sender.",
            symbol: "at.circle.fill",
            tint: .red,
            rule: Automations.Rule(
                name: "Mass mention kick",
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageMentionsCount, intValue: 10)
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete),
                    Automations.Step(kind: .modifyMember, memberOp: .kick, kickReason: "Mass mention spam")
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-no-links-channel",
            title: "No links in a channel",
            subtitle: "Remove links posted in channels you choose. Pick the channels, then turn it on.",
            symbol: "link.badge.plus",
            tint: .orange,
            rule: Automations.Rule(
                name: "No links in a channel",
                enabled: false,
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .inChannel, channelIds: []),
                    Automations.Filter(kind: .messageMatchesRegex, text: #"https?://\S+"#)
                ],
                steps: [
                    Automations.Step(kind: .modifyMessage, messageOp: .delete),
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .directMessage,
                        content: "Hi {username}, links aren't allowed in #{channelName}. Your message was removed."
                    )
                ]
            )
        ),

        // MARK: Reports & alerts

        AutomationTemplate(
            id: "mod-report-command",
            title: "/report command",
            subtitle: "Let members report a problem with /report; it's logged for moderators.",
            symbol: "flag.fill",
            tint: .orange,
            rule: Automations.Rule(
                name: "/report command",
                category: .moderation,
                trigger: Automations.Trigger(kind: .slashCommand, commandName: "report"),
                steps: [
                    Automations.Step(kind: .log, logText: "Report from {username} in #{channelName}: {message}"),
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .replyToTrigger,
                        content: "Thanks {username} — the moderators have been notified."
                    )
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-keyword-alert",
            title: "Moderator alert",
            subtitle: "Alert a mod channel when a watched phrase appears. Pick the channel, then turn it on.",
            symbol: "bell.badge.fill",
            tint: .red,
            rule: Automations.Rule(
                name: "Moderator alert",
                enabled: false,
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filters: [
                    Automations.Filter(kind: .messageContainsAny, textValues: ["dox", "swat", "threat"])
                ],
                steps: [
                    Automations.Step(
                        kind: .sendMessage,
                        sendTarget: .specificChannel,
                        content: "🚨 {username} in #{channelName}: {message}"
                    )
                ]
            )
        ),

        // MARK: Audit

        AutomationTemplate(
            id: "mod-voice-leave-audit",
            title: "Voice leave audit",
            subtitle: "Log when someone leaves voice, with how long they stayed.",
            symbol: "speaker.slash.fill",
            tint: .green,
            rule: Automations.Rule(
                name: "Voice leave audit",
                category: .moderation,
                trigger: Automations.Trigger(kind: .userLeftVoice),
                steps: [
                    Automations.Step(kind: .log, logText: "{username} left #{channelName} after {duration}")
                ]
            )
        ),

        AutomationTemplate(
            id: "mod-voice-move-audit",
            title: "Voice move audit",
            subtitle: "Log when someone moves between voice channels.",
            symbol: "arrow.left.arrow.right",
            tint: .green,
            rule: Automations.Rule(
                name: "Voice move audit",
                category: .moderation,
                trigger: Automations.Trigger(kind: .userMovedVoice),
                steps: [
                    Automations.Step(kind: .log, logText: "{username} moved to #{channelName}")
                ]
            )
        ),
    ]
}
