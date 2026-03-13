import XCTest
@testable import SwiftBot

final class RuleExecutionServiceTests: XCTestCase {
    actor Recorder {
        var sentMessages: [(channelId: String, content: String, token: String)] = []
        var sentPayloads: [(channelId: String, content: String, messageId: String?, token: String)] = []
        var sentDMs: [(userId: String, content: String)] = []

        func recordMessage(channelId: String, content: String, token: String) {
            sentMessages.append((channelId, content, token))
        }

        func recordPayload(channelId: String, payload: [String: Any], token: String) {
            let content = payload["content"] as? String ?? ""
            let reference = payload["message_reference"] as? [String: Any]
            let messageId = reference?["message_id"] as? String
            sentPayloads.append((channelId, content, messageId, token))
        }

        func recordDM(userId: String, content: String) {
            sentDMs.append((userId, content))
        }
    }

    func testReplyToTriggerSendsReferencedPayloadAndMarksHandled() async {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)

        var replyModifier = Action()
        replyModifier.type = .replyToTrigger

        var sendAction = Action()
        sendAction.type = .sendMessage
        sendAction.message = "Hi {username}"

        let event = makeEvent()
        let context = await service.executeRulePipeline(
            actions: [replyModifier, sendAction],
            for: event,
            isDirectMessage: false,
            token: "bot-token"
        )

        XCTAssertTrue(context.eventHandled)
        let wasHandled = await service.wasMessageHandledByRules(messageId: "message-1")
        XCTAssertTrue(wasHandled)

        let payloads = await recorder.sentPayloads
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads.first?.channelId, "channel-1")
        XCTAssertEqual(payloads.first?.content, "Hi Taylor")
        XCTAssertEqual(payloads.first?.messageId, "message-1")
        XCTAssertEqual(payloads.first?.token, "bot-token")
    }

    func testSendToDMRoutesThroughDMDependency() async {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)

        var dmModifier = Action()
        dmModifier.type = .sendToDM

        var sendAction = Action()
        sendAction.type = .sendMessage
        sendAction.message = "Hello {username}"

        let context = await service.executeRulePipeline(
            actions: [dmModifier, sendAction],
            for: makeEvent(),
            isDirectMessage: false,
            token: "bot-token"
        )

        XCTAssertTrue(context.eventHandled)

        let dms = await recorder.sentDMs
        XCTAssertEqual(dms.count, 1)
        XCTAssertEqual(dms.first?.userId, "user-1")
        XCTAssertEqual(dms.first?.content, "Hello Taylor")
    }

    private func makeService(recorder: Recorder) -> RuleExecutionService {
        let aiService = DiscordAIService(
            engineFactory: { _, _ in
                let engine = StubAIEngine()
                return DiscordAIService.EngineSet(apple: engine, ollama: engine, openAI: engine)
            },
            ollamaModelResolver: { _, _ in nil },
            openAIProbe: { _, _ in false },
            appleAvailability: { false },
            openAIImageGenerator: { _, _, _ in nil }
        )

        return RuleExecutionService(
            aiService: aiService,
            dependencies: .init(
                sendMessage: { channelId, content, token in
                    await recorder.recordMessage(channelId: channelId, content: content, token: token)
                },
                sendPayloadMessage: { channelId, payload, token in
                    await recorder.recordPayload(channelId: channelId, payload: payload, token: token)
                },
                sendDM: { userId, content in
                    await recorder.recordDM(userId: userId, content: content)
                },
                addReaction: { _, _, _, _ in },
                deleteMessage: { _, _, _ in },
                addRole: { _, _, _, _ in },
                removeRole: { _, _, _, _ in },
                timeoutMember: { _, _, _, _ in },
                kickMember: { _, _, _, _ in },
                moveMember: { _, _, _, _ in },
                createChannel: { _, _, _ in },
                sendWebhook: { _, _ in },
                updatePresence: { _ in },
                resolveChannelName: { _, channelId in "Channel-\(channelId)" },
                resolveGuildName: { guildId in "Guild-\(guildId)" },
                debugLog: { _ in }
            )
        )
    }

    private func makeEvent() -> VoiceRuleEvent {
        VoiceRuleEvent(
            kind: .message,
            guildId: "guild-1",
            userId: "user-1",
            username: "Taylor",
            channelId: "channel-1",
            fromChannelId: nil,
            toChannelId: nil,
            durationSeconds: nil,
            messageContent: "hello",
            messageId: "message-1",
            mediaFileName: nil,
            mediaRelativePath: nil,
            mediaSourceName: nil,
            mediaNodeName: nil,
            triggerMessageId: "message-1",
            triggerChannelId: "channel-1",
            triggerGuildId: "guild-1",
            triggerUserId: "user-1",
            isDirectMessage: false,
            authorIsBot: false,
            joinedAt: nil
        )
    }
}

private struct StubAIEngine: AIEngine {
    func generate(messages: [Message]) async -> String? {
        nil
    }
}
