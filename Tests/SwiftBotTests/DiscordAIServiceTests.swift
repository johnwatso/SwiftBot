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

        let event = SwiftBotEvent.message(
            SwiftBotEvent.MessagePayload(
                guildId: "guild",
                userId: "user",
                username: "Taylor",
                channelId: "channel",
                messageId: "message",
                content: "How do I join?",
                isDirectMessage: false,
                authorIsBot: false
            )
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

    func testCurrentAIStatusCachesAnUnavailableModelCheck() async {
        let recorder = CallRecorder()
        let availability = SynchronousCallCounter()
        let service = DiscordAIService(
            engineFactory: { _ in StubEngine(name: "apple", reply: nil, recorder: recorder) },
            appleAvailability: {
                availability.increment()
                return false
            },
            appleModelName: {
                XCTFail("An unavailable model must not ask for its display name")
                return nil
            }
        )

        let firstStatus = await service.currentAIStatus()
        let modelName = await service.currentAIModelName()
        let secondStatus = await service.currentAIStatus()

        XCTAssertFalse(firstStatus)
        XCTAssertNil(modelName)
        XCTAssertFalse(secondStatus)
        XCTAssertEqual(availability.value, 1)
    }

    func testPatchySummaryCleanupRemovesToolLeadIn() {
        XCTAssertEqual(
            DiscordAIService.cleanPatchySummary("Patchy reports NVIDIA 580.12 improves game stability."),
            "NVIDIA 580.12 improves game stability."
        )
        XCTAssertEqual(
            DiscordAIService.cleanPatchySummary("Patchy has detected a Steam patch with balance changes."),
            "a Steam patch with balance changes."
        )
        XCTAssertEqual(
            DiscordAIService.cleanPatchySummary("AMD 26.3.1 fixes crashes and adds compatibility notes."),
            "AMD 26.3.1 fixes crashes and adds compatibility notes."
        )
        XCTAssertEqual(
            DiscordAIService.cleanPatchySummary("Patchy update summary goes here."),
            ""
        )
    }

    func testPatchySummaryUsefulnessRejectsThinOrVagueOutput() {
        XCTAssertFalse(DiscordAIService.isUsefulPatchySummary("NVIDIA has a new driver update."))
        XCTAssertFalse(DiscordAIService.isUsefulPatchySummary("This update includes fixes and improvements for users across the product with better reliability and compatibility."))
        XCTAssertTrue(DiscordAIService.isUsefulPatchySummary(
            "NVIDIA 580.12 focuses on game stability, adds support for newer titles, and calls out compatibility notes for affected systems. It also fixes crash regressions and gives users a clearer reason to upgrade when they rely on those games or hardware paths."
        ))
    }
}

private final class SynchronousCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
