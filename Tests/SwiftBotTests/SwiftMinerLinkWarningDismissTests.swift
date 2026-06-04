import XCTest
@testable import SwiftBot

final class SwiftMinerLinkWarningDismissTests: XCTestCase {

    // MARK: - Dismiss intent

    func testRecognisesDismissKeywords() {
        for word in ["ignore", "Dismiss", "STOP", "mute", "unsubscribe", "unsub", "off"] {
            XCTAssertTrue(SwiftMinerLinkWarningDismiss.isDismissIntent(word), "\(word) should be a dismiss intent")
        }
    }

    func testRecognisesKeywordFollowedByText() {
        XCTAssertTrue(SwiftMinerLinkWarningDismiss.isDismissIntent("ignore this game"))
        XCTAssertTrue(SwiftMinerLinkWarningDismiss.isDismissIntent("  stop please  "))
    }

    func testRejectsNonDismissText() {
        XCTAssertFalse(SwiftMinerLinkWarningDismiss.isDismissIntent(""))
        XCTAssertFalse(SwiftMinerLinkWarningDismiss.isDismissIntent("hello there"))
        // "ignored" must not match — only the bare word or word + space.
        XCTAssertFalse(SwiftMinerLinkWarningDismiss.isDismissIntent("ignored the warning"))
        XCTAssertFalse(SwiftMinerLinkWarningDismiss.isDismissIntent("stopwatch"))
    }

    // MARK: - Game extraction from title

    func testExtractsGameFromTitle() {
        XCTAssertEqual(
            SwiftMinerLinkWarningDismiss.game(fromNeedsLinkingTitle: "🔗 Link Twitch for The Finals"),
            "The Finals"
        )
    }

    func testExtractsGameDespiteDebugPrefix() {
        XCTAssertEqual(
            SwiftMinerLinkWarningDismiss.game(fromNeedsLinkingTitle: "[TEST] 🔗 Link Twitch for Valorant"),
            "Valorant"
        )
    }

    func testReturnsNilForUnrelatedTitle() {
        XCTAssertNil(SwiftMinerLinkWarningDismiss.game(fromNeedsLinkingTitle: "🏁 Campaign complete"))
        XCTAssertNil(SwiftMinerLinkWarningDismiss.game(fromNeedsLinkingTitle: "🔗 Link Twitch for "))
    }

    // MARK: - Combined

    func testGameToDismissRequiresBothIntentAndTitle() {
        // Intent + our title -> game.
        XCTAssertEqual(
            SwiftMinerLinkWarningDismiss.gameToDismiss(
                replyContent: "ignore",
                referencedEmbedTitle: "🔗 Link Twitch for The Finals"
            ),
            "The Finals"
        )
        // Intent but no referenced title -> nil.
        XCTAssertNil(SwiftMinerLinkWarningDismiss.gameToDismiss(replyContent: "ignore", referencedEmbedTitle: nil))
        // Referenced title but no dismiss intent -> nil.
        XCTAssertNil(SwiftMinerLinkWarningDismiss.gameToDismiss(
            replyContent: "thanks!",
            referencedEmbedTitle: "🔗 Link Twitch for The Finals"
        ))
        // Reply to a different DM type -> nil even with intent.
        XCTAssertNil(SwiftMinerLinkWarningDismiss.gameToDismiss(
            replyContent: "ignore",
            referencedEmbedTitle: "🏁 The Finals — Campaign complete"
        ))
    }
}
