import XCTest
@testable import SwiftBot

@MainActor
final class GatewayDMHandlingTests: XCTestCase {

    func testDMBlockedWhenAllowDMsDisabled() async {
        let model = AppModel()
        model.settings.behavior.allowDMs = false
        model.logs.clear()

        let event = makeDMEvent(userID: "user-1", username: "alice", channelID: "ch-1", messageID: "msg-1")
        await model.handleMessageCreate(event)

        // When DMs are disabled the function returns before checkRateLimit
        // runs, so the per-user cooldown timestamp must not be recorded.
        // (If the path had progressed, lastCommandTimeByUserId would hold an
        // entry for "user-1".)
        XCTAssertNil(model.lastCommandTimeByUserId["user-1"])
        XCTAssertFalse(
            model.logs.lines.contains { $0.contains("Throttling") },
            "Rate-limit path should not run when DMs are disabled"
        )
    }

    func testDMRateLimitSendsCooldownMessage() async {
        let model = AppModel()
        model.settings.behavior.allowDMs = true
        model.settings.localAIDMReplyEnabled = true
        model.logs.clear()
        // Pre-arm: a very recent command means the next DM is throttled.
        model.lastCommandTimeByUserId["user-1"] = Date()

        let event = makeDMEvent(userID: "user-1", username: "alice", channelID: "ch-1", messageID: "msg-2")
        await model.handleMessageCreate(event)

        XCTAssertTrue(
            model.logs.lines.contains { $0.contains("Throttling alice") },
            "Expected throttling log for the rate-limited user. Logs: \(model.logs.lines)"
        )
    }

    func testDMSkippedWhenHandledByRules() async {
        let model = AppModel()
        model.settings.behavior.allowDMs = true
        model.settings.localAIDMReplyEnabled = true
        model.logs.clear()

        // Wire the automation service into DiscordService and pre-mark the
        // message as handled so the AI reply path short-circuits.
        await model.service.setAutomationService(model.automationService, store: model.automationStore)
        await model.automationService.markMessageHandledForTesting("msg-3")

        let event = makeDMEvent(userID: "user-1", username: "alice", channelID: "ch-1", messageID: "msg-3")
        await model.handleMessageCreate(event)

        XCTAssertTrue(
            model.logs.lines.contains { $0.contains("AI DM reply skipped") && $0.contains("msg-3") },
            "Expected skip log when message was handled by rule actions. Logs: \(model.logs.lines)"
        )
    }

    // MARK: - Helpers

    private func makeDMEvent(
        userID: String,
        username: String,
        channelID: String,
        messageID: String
    ) -> GatewayMessageCreateEvent {
        GatewayMessageCreateEvent(
            rawMap: ["channel_type": .int(1)],
            content: "hello",
            author: [:],
            username: username,
            displayName: username,
            channelID: channelID,
            userID: userID,
            guildID: nil,
            messageID: messageID,
            isBot: false,
            avatarHash: nil
        )
    }
}
