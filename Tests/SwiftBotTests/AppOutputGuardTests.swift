import XCTest
@testable import SwiftBot

@MainActor
final class AppOutputGuardTests: XCTestCase {
    func testBlockedTypingIndicatorLogsActionDispatcherWarning() async {
        let model = AppModel()
        model.settings.clusterMode = .worker
        model.logs.clear()

        await model.sendTypingIndicator("channel-1")

        XCTAssertTrue(
            model.logs.lines.contains { line in
                line.contains("ActionDispatcher") && line.contains("triggerTyping")
            }
        )
    }

    func testBlockedOutputHelpersReturnFalseAndLogWarnings() async {
        let model = AppModel()
        model.settings.clusterMode = .worker
        model.logs.clear()

        let removedReaction = await model.removeOwnReaction(
            channelId: "channel-1",
            messageId: "message-1",
            emoji: "%F0%9F%91%8D"
        )
        let pinnedMessage = await model.pinMessage(channelId: "channel-1", messageId: "message-1")
        let unpinnedMessage = await model.unpinMessage(channelId: "channel-1", messageId: "message-1")
        let createdThread = await model.createThreadFromMessage(
            channelId: "channel-1",
            messageId: "message-1",
            name: "thread-1"
        )

        XCTAssertFalse(removedReaction)
        XCTAssertFalse(pinnedMessage)
        XCTAssertFalse(unpinnedMessage)
        XCTAssertFalse(createdThread)
        XCTAssertTrue(model.logs.lines.contains { $0.contains("removeOwnReaction") })
        XCTAssertTrue(model.logs.lines.contains { $0.contains("pinMessage") })
        XCTAssertTrue(model.logs.lines.contains { $0.contains("unpinMessage") })
        XCTAssertTrue(model.logs.lines.contains { $0.contains("createThreadFromMessage") })
    }
}
