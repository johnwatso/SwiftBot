import XCTest
@testable import SwiftBot

final class DiscordAIServiceTests: XCTestCase {
    actor CallRecorder {
        private var calls: [String] = []

        func record(_ name: String) {
            calls.append(name)
        }

        func snapshot() -> [String] {
            calls
        }
    }

    struct StubEngine: AIEngine {
        let name: String
        let reply: String?
        let recorder: CallRecorder

        func generate(messages: [Message]) async -> String? {
            await recorder.record(name)
            return reply
        }
    }

    func testGenerateSmartDMReplyUsesAppleIntelligenceEngine() async {
        let recorder = CallRecorder()
        let service = DiscordAIService(
            engineFactory: { _ in StubEngine(name: "apple", reply: "hello from apple", recorder: recorder) },
            appleAvailability: { true }
        )

        await service.configureLocalAIDMReplies(
            enabled: true,
            systemPrompt: "You are helpful."
        )

        let reply = await service.generateSmartDMReply(
            messages: [
                Message(
                    channelID: "channel",
                    userID: "user",
                    username: "Taylor",
                    content: "How do I join?",
                    role: .user
                )
            ]
        )

        XCTAssertEqual(reply, "hello from apple")
        let calls = await recorder.snapshot()
        XCTAssertEqual(calls, ["apple"])
    }

    func testGenerateStepAIReplyRejectsEmptyPromptWithoutInvokingEngine() async {
        let recorder = CallRecorder()
        let service = DiscordAIService(
            engineFactory: { _ in StubEngine(name: "apple", reply: "unused", recorder: recorder) },
            appleAvailability: { true }
        )

        let event = VoiceRuleEvent(
            kind: .message,
            guildId: "guild",
            userId: "user",
            username: "Taylor",
            channelId: "channel",
            fromChannelId: nil,
            toChannelId: nil,
            durationSeconds: nil,
            messageContent: nil,
            messageId: nil,
            mediaFileName: nil,
            mediaRelativePath: nil,
            mediaSourceName: nil,
            mediaNodeName: nil,
            triggerMessageId: nil,
            triggerChannelId: nil,
            triggerGuildId: "guild",
            triggerUserId: "user",
            isDirectMessage: false,
            authorIsBot: false,
            joinedAt: nil
        )

        let reply = await service.generateStepAIReply(
            prompt: "   ",
            event: event,
            serverName: "Guild",
            channelName: "general"
        )

        XCTAssertNil(reply)
        let calls = await recorder.snapshot()
        XCTAssertEqual(calls, [])
    }

    func testCurrentAIStatusReportsAppleAvailability() async {
        let recorder = CallRecorder()
        let onlineService = DiscordAIService(
            engineFactory: { _ in StubEngine(name: "apple", reply: nil, recorder: recorder) },
            appleAvailability: { true }
        )
        let offlineService = DiscordAIService(
            engineFactory: { _ in StubEngine(name: "apple", reply: nil, recorder: recorder) },
            appleAvailability: { false }
        )

        let online = await onlineService.currentAIStatus()
        let offline = await offlineService.currentAIStatus()

        XCTAssertTrue(online)
        XCTAssertFalse(offline)
    }
}
