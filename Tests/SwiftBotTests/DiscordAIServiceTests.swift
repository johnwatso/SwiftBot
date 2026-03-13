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

    func testGenerateSmartDMReplyUsesFirstSuccessfulEngine() async {
        // With parallel racing, all engines run simultaneously and the first
        // non-nil result wins. Only openAI returns a value here, so the
        // result is deterministic regardless of which engine finishes first.
        let recorder = CallRecorder()
        let service = DiscordAIService(
            engineFactory: { _, _ in
                DiscordAIService.EngineSet(
                    apple: StubEngine(name: "apple", reply: nil, recorder: recorder),
                    ollama: StubEngine(name: "ollama", reply: nil, recorder: recorder),
                    openAI: StubEngine(name: "openAI", reply: "openai fallback", recorder: recorder)
                )
            },
            ollamaModelResolver: { _, _ in nil },
            openAIProbe: { _, _ in false },
            appleAvailability: { false },
            openAIImageGenerator: { _, _, _ in nil }
        )

        await service.configureLocalAIDMReplies(
            enabled: true,
            provider: .appleIntelligence,
            preferredProvider: .apple,
            endpoint: "http://localhost:11434",
            model: "llama3",
            openAIAPIKey: "key",
            openAIModel: "gpt-4o-mini",
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

        XCTAssertEqual(reply, "openai fallback")
        // All engines race in parallel — verify all were invoked
        let calls = await recorder.snapshot()
        XCTAssertTrue(calls.contains("apple"))
        XCTAssertTrue(calls.contains("openAI"))
    }

    func testGenerateRuleActionAIReplyRejectsEmptyPromptWithoutInvokingEngines() async {
        let recorder = CallRecorder()
        let service = DiscordAIService(
            engineFactory: { _, _ in
                DiscordAIService.EngineSet(
                    apple: StubEngine(name: "apple", reply: "unused", recorder: recorder),
                    ollama: StubEngine(name: "ollama", reply: "unused", recorder: recorder),
                    openAI: StubEngine(name: "openAI", reply: "unused", recorder: recorder)
                )
            },
            ollamaModelResolver: { _, _ in nil },
            openAIProbe: { _, _ in false },
            appleAvailability: { false },
            openAIImageGenerator: { _, _, _ in nil }
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

        let reply = await service.generateRuleActionAIReply(
            prompt: "   ",
            event: event,
            serverName: "Guild",
            channelName: "general"
        )

        XCTAssertNil(reply)
        let calls = await recorder.snapshot()
        XCTAssertEqual(calls, [])
    }

    func testCurrentAIStatusUsesInjectedProbes() async {
        let service = DiscordAIService(
            engineFactory: { _, _ in
                DiscordAIService.EngineSet(
                    apple: StubEngine(name: "apple", reply: nil, recorder: CallRecorder()),
                    ollama: StubEngine(name: "ollama", reply: nil, recorder: CallRecorder()),
                    openAI: StubEngine(name: "openAI", reply: nil, recorder: CallRecorder())
                )
            },
            ollamaModelResolver: { baseURL, preferredModel in
                XCTAssertEqual(baseURL, "http://localhost:11434")
                XCTAssertEqual(preferredModel, "llama3")
                return "llama3:latest"
            },
            openAIProbe: { apiKey, baseURL in
                XCTAssertEqual(apiKey, "secret")
                XCTAssertEqual(baseURL, "https://api.openai.com")
                return true
            },
            appleAvailability: { true },
            openAIImageGenerator: { _, _, _ in nil }
        )

        let status = await service.currentAIStatus(
            ollamaBaseURL: "localhost:11434",
            ollamaModelHint: "llama3",
            openAIAPIKey: "secret"
        )

        XCTAssertTrue(status.appleOnline)
        XCTAssertTrue(status.ollamaOnline)
        XCTAssertEqual(status.ollamaModel, "llama3:latest")
        XCTAssertTrue(status.openAIOnline)
    }
}
