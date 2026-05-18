import Foundation

/// Curated (natural-language → Rule) pairs used as engine test fixtures
/// and for documentation. Updated for the new Filter-list schema.
extension Automations {

    struct Example: Sendable {
        let prompt: String
        let rule: Rule
    }

    static let examples: [Example] = [

        // messageCreated + contains + reply
        Example(
            prompt: "When someone says 'hello' in any channel, reply with a friendly greeting.",
            rule: Rule(
                name: "Hello greeter",
                trigger: Trigger(kind: .messageCreated),
                filters: [
                    Filter(kind: .messageContains, text: "hello")
                ],
                steps: [
                    Step(kind: .sendMessage, sendTarget: .replyToTrigger, content: "Hey {username}! 👋")
                ]
            )
        ),

        // memberJoined + AI welcome DM
        Example(
            prompt: "DM a personalized welcome message to new members.",
            rule: Rule(
                name: "Welcome DM",
                trigger: Trigger(kind: .memberJoined),
                steps: [
                    Step(
                        kind: .sendMessage,
                        sendTarget: .directMessage,
                        aiPrompt: "Write a short, warm welcome message for a new member named {username} joining {guildName}."
                    )
                ]
            )
        ),

        // userJoinedVoice + channel filter + log
        Example(
            prompt: "Log to the bot when someone joins the General voice channel.",
            rule: Rule(
                name: "Log General voice joins",
                trigger: Trigger(kind: .userJoinedVoice),
                filters: [
                    Filter(kind: .inChannel, channelIds: ["GENERAL_VOICE_CHANNEL_ID"])
                ],
                steps: [
                    Step(kind: .log, logText: "{username} joined #{channelName}")
                ]
            )
        ),

        // messageCreated + delete + DM warning
        Example(
            prompt: "Delete any message containing 'spam-link.example' and DM the user a warning.",
            rule: Rule(
                name: "Spam link filter",
                trigger: Trigger(kind: .messageCreated),
                filters: [
                    Filter(kind: .messageContains, text: "spam-link.example")
                ],
                steps: [
                    Step(kind: .modifyMessage, messageOp: .delete),
                    Step(
                        kind: .sendMessage,
                        sendTarget: .directMessage,
                        content: "Hi {username}, your message in #{channelName} was removed because it contained a disallowed link."
                    )
                ]
            )
        ),

        // messageCreated + OR multiple keywords
        Example(
            prompt: "If someone says 'hi', 'hello', or 'hey', react with a wave.",
            rule: Rule(
                name: "Greeting reaction",
                trigger: Trigger(kind: .messageCreated),
                filterLogic: .any,
                filters: [
                    Filter(kind: .messageContains, text: "hi"),
                    Filter(kind: .messageContains, text: "hello"),
                    Filter(kind: .messageContains, text: "hey")
                ],
                steps: [
                    Step(kind: .modifyMessage, messageOp: .react, reactEmoji: "👋")
                ]
            )
        ),

        // userLeftVoice + min duration + post in specific channel
        Example(
            prompt: "When someone leaves voice after being in for at least 30 minutes, post '{username} was in voice for {duration}' in #voice-log.",
            rule: Rule(
                name: "Voice session log",
                trigger: Trigger(kind: .userLeftVoice),
                filters: [
                    Filter(kind: .minVoiceDurationSeconds, intValue: 1800)
                ],
                steps: [
                    Step(
                        kind: .sendMessage,
                        sendTarget: .specificChannel,
                        channelId: "VOICE_LOG_CHANNEL_ID",
                        content: "{username} was in voice for {duration}"
                    )
                ]
            )
        ),

        // slashCommand + webhook
        Example(
            prompt: "When someone runs /report, POST the message details to our webhook at https://hooks.example.com/reports.",
            rule: Rule(
                name: "Forward /report to webhook",
                trigger: Trigger(kind: .slashCommand, commandName: "report"),
                steps: [
                    Step(
                        kind: .webhook,
                        webhookUrl: "https://hooks.example.com/reports",
                        webhookContent: "Report from {username} in {guildName}: {message}"
                    )
                ]
            )
        ),

        // memberLeft + log (no filters)
        Example(
            prompt: "Log when anyone leaves the server.",
            rule: Rule(
                name: "Member-leave log",
                trigger: Trigger(kind: .memberLeft),
                steps: [
                    Step(kind: .log, logText: "{username} left {guildName}")
                ]
            )
        ),
    ]
}
