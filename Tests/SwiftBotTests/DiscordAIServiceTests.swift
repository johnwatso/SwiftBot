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

    func testPatchySummaryUsesShortcutWhenDirectAppleModelIsUnavailable() async {
        let recorder = PromptRecorder()
        let service = DiscordAIService(
            engineFactory: { _ in
                StubEngine(name: "unused", reply: nil, recorder: CallRecorder())
            },
            appleAvailability: { false },
            shortcutSummaryProvider: { prompt, profile in
                await recorder.record(prompt, profile: profile)
                return "THE FINALS 12.0 reduces the XP-54’s close-range damage while strengthening several underused gadgets and specializations. Exact tuning values are retained for competitive players, alongside the ranked-mode changes, important crash fixes, and the known regression that may affect loadouts after updating."
            }
        )

        let summary = await service.summarizePatchyUpdateWithAppleIntelligence(
            updateText: "Summary brief: THE FINALS 12.0. Full notes: XP-54 damage changed.",
            source: "THE FINALS Steam patch notes"
        )

        XCTAssertNotNil(summary)
        let prompt = await recorder.value
        XCTAssertTrue(prompt.contains("<update-notes>"))
        XCTAssertFalse(prompt.contains("Lead with balance changes"))
        let profile = await recorder.profile
        XCTAssertEqual(profile, .gamingPatch)
    }

    func testPatchySummaryProfilesAreSourceSpecific() {
        XCTAssertTrue(
            DiscordAIService.patchySummaryInstructions(source: "NVIDIA driver release")
                .contains("affected hardware")
        )
        XCTAssertTrue(
            DiscordAIService.patchySummaryInstructions(source: "GitHub commit")
                .contains("breaking behavior")
        )
        XCTAssertTrue(
            DiscordAIService.patchySummaryInstructions(source: "THE FINALS Steam patch notes")
                .contains("Preserve exact before/after numbers")
        )
        XCTAssertEqual(
            DiscordAIService.shortcutProfile(source: "THE FINALS Steam patch notes"),
            .gamingPatch
        )
        XCTAssertEqual(
            DiscordAIService.shortcutProfile(source: "NVIDIA driver release"),
            .softwareUpdate
        )
        XCTAssertEqual(
            DiscordAIService.shortcutProfile(source: "GitHub commit"),
            .generalPatch
        )
    }

    func testBundledIntelligenceBridgeShortcutsExist() throws {
        for profile in ShortcutIntelligenceBridge.Profile.allCases {
            let url = try XCTUnwrap(
                Bundle.main.url(
                    forResource: profile.shortcutName,
                    withExtension: "shortcut",
                    subdirectory: "Shortcuts"
                )
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertGreaterThan(attributes[.size] as? Int ?? 0, 0)
        }
    }
}

private actor PromptRecorder {
    private(set) var value = ""
    private(set) var profile: ShortcutIntelligenceBridge.Profile?

    func record(_ prompt: String, profile: ShortcutIntelligenceBridge.Profile) {
        value = prompt
        self.profile = profile
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
