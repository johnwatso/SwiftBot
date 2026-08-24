import AVFoundation
import XCTest
@testable import SwiftBot

/// Covers the gate that decides whether a message in the `/announce join`
/// read-aloud thread gets spoken.
///
/// The thread is open to anyone who can see it, so the interesting cases are
/// the limits that stand in for access control: the length cap, the per-author
/// cooldown, and the command/empty filters. Thread identity is checked first
/// because everything else depends on the message actually being in the live
/// thread.
@MainActor
final class AnnouncerReadAloudThreadTests: XCTestCase {

    private func makeEvent(
        channelID: String,
        userID: String = "user-1",
        content: String
    ) -> GatewayMessageCreateEvent {
        GatewayMessageCreateEvent(
            rawMap: [:],
            content: content,
            author: [:],
            username: "Alice",
            displayName: "Alice",
            channelID: channelID,
            userID: userID,
            memberRoleIDs: nil,
            guildID: "guild-1",
            messageID: "msg-1",
            isBot: false,
            avatarHash: nil
        )
    }

    // MARK: - Thread identity

    func testNoMessageIsSpokenWhenNoThreadIsOpen() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = nil
        let event = makeEvent(channelID: "thread-1", content: "hello")
        XCTAssertFalse(app.shouldSpeakAnnouncerThreadMessage(event))
    }

    func testMessageInTheLiveThreadIsSpoken() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = "thread-1"
        let event = makeEvent(channelID: "thread-1", content: "read this out")
        XCTAssertTrue(app.shouldSpeakAnnouncerThreadMessage(event))
    }

    func testMessageInAnotherChannelIsIgnored() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = "thread-1"
        let event = makeEvent(channelID: "some-other-channel", content: "not for the thread")
        XCTAssertFalse(app.shouldSpeakAnnouncerThreadMessage(event))
    }

    // MARK: - Content filters

    func testEmptyOrWhitespaceMessageIsIgnored() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = "thread-1"
        XCTAssertFalse(app.shouldSpeakAnnouncerThreadMessage(makeEvent(channelID: "thread-1", content: "")))
        XCTAssertFalse(app.shouldSpeakAnnouncerThreadMessage(makeEvent(channelID: "thread-1", content: "   \n ")))
    }

    func testOverlongMessageIsIgnored() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = "thread-1"
        let long = String(repeating: "a", count: AppModel.announcerThreadMaxCharacters + 1)
        XCTAssertFalse(
            app.shouldSpeakAnnouncerThreadMessage(makeEvent(channelID: "thread-1", content: long)),
            "A wall of text must not be able to monopolise the voice channel"
        )
    }

    func testMessageExactlyAtTheCapIsSpoken() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = "thread-1"
        let atCap = String(repeating: "a", count: AppModel.announcerThreadMaxCharacters)
        XCTAssertTrue(app.shouldSpeakAnnouncerThreadMessage(makeEvent(channelID: "thread-1", content: atCap)))
    }

    func testSlashCommandsAreNotReadAloud() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = "thread-1"
        XCTAssertFalse(
            app.shouldSpeakAnnouncerThreadMessage(makeEvent(channelID: "thread-1", content: "/announce disconnect")),
            "Commands are addressed to the bot, not to the room"
        )
    }

    func testConfiguredPrefixCommandsAreNotReadAloud() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = "thread-1"
        app.settings.prefix = "!"
        XCTAssertFalse(app.shouldSpeakAnnouncerThreadMessage(makeEvent(channelID: "thread-1", content: "!help")))
        XCTAssertTrue(app.shouldSpeakAnnouncerThreadMessage(makeEvent(channelID: "thread-1", content: "hello there")))
    }

    // MARK: - Per-author cooldown

    func testSameAuthorIsRateLimited() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = "thread-1"
        let start = Date()
        let first = makeEvent(channelID: "thread-1", userID: "spammer", content: "one")

        XCTAssertTrue(app.shouldSpeakAnnouncerThreadMessage(first, now: start))
        app.noteAnnouncerThreadSpoken(userID: "spammer", now: start)

        let immediately = start.addingTimeInterval(0.5)
        XCTAssertFalse(
            app.shouldSpeakAnnouncerThreadMessage(makeEvent(channelID: "thread-1", userID: "spammer", content: "two"), now: immediately),
            "A second message from the same author inside the cooldown must be dropped"
        )
    }

    func testAuthorCanSpeakAgainAfterTheCooldown() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = "thread-1"
        let start = Date()
        app.noteAnnouncerThreadSpoken(userID: "user-1", now: start)

        let later = start.addingTimeInterval(AppModel.announcerThreadPerUserCooldown + 0.1)
        XCTAssertTrue(
            app.shouldSpeakAnnouncerThreadMessage(makeEvent(channelID: "thread-1", content: "later"), now: later)
        )
    }

    func testCooldownIsPerAuthorNotGlobal() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = "thread-1"
        let start = Date()
        app.noteAnnouncerThreadSpoken(userID: "alice", now: start)

        XCTAssertTrue(
            app.shouldSpeakAnnouncerThreadMessage(
                makeEvent(channelID: "thread-1", userID: "bob", content: "my turn"),
                now: start.addingTimeInterval(0.1)
            ),
            "One person's cooldown must not silence everyone else"
        )
    }

    // MARK: - Teardown

    func testArchivingClearsThreadStateSoNothingIsSpokenAfterwards() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = "thread-1"
        app.noteAnnouncerThreadSpoken(userID: "user-1")

        app.archiveAnnouncerReadAloudThread()

        XCTAssertNil(app.announcerReadAloudThreadID, "The thread must not stay live after teardown")
        XCTAssertTrue(app.announcerThreadLastSpokenAt.isEmpty, "Cooldown state must not leak into the next session")
        XCTAssertFalse(
            app.shouldSpeakAnnouncerThreadMessage(makeEvent(channelID: "thread-1", content: "anyone there?")),
            "A message arriving after teardown must not be spoken"
        )
    }

    func testArchivingIsSafeWhenNoThreadIsOpen() async {
        let app = AppModel()
        app.announcerReadAloudThreadID = nil
        app.archiveAnnouncerReadAloudThread()
        XCTAssertNil(app.announcerReadAloudThreadID)
    }

    // MARK: - Watcher bypass
    //
    // The read-aloud thread is deliberately not added to the announcer's
    // watched-channel set, so `handle` has to be told to skip that check. This
    // is the seam the first build got wrong: the message cleared AppModel's
    // guard and was then silently dropped by the watcher's own filter.

    func testWatcherDropsUnwatchedChannelWithoutTheBypass() async throws {
        let playback = VoicePlaybackService()
        let announcer = try VoiceAnnouncementService(playback: playback)
        await announcer.setPaused(true)
        let watcher = TextChannelAnnouncer(announcer: announcer)
        await watcher.setWatchedChannels(["configured-feed"])

        await watcher.handle(makeEvent(channelID: "thread-1", content: "hello"))

        let pending = await announcer.pending
        XCTAssertTrue(pending.isEmpty, "Without the bypass the watcher must still honour its channel filter")
    }

    func testWatcherSpeaksUnwatchedChannelWithTheBypass() async throws {
        let playback = VoicePlaybackService()
        let announcer = try VoiceAnnouncementService(playback: playback)
        await announcer.setPaused(true)
        let watcher = TextChannelAnnouncer(announcer: announcer)
        await watcher.setWatchedChannels(["configured-feed"])

        await watcher.handle(makeEvent(channelID: "thread-1", content: "hello"), bypassChannelFilter: true)

        let pending = await announcer.pending
        XCTAssertEqual(pending.count, 1, "The read-aloud thread must reach the queue even though it is not a watched channel")
        XCTAssertTrue(pending.first?.text.contains("hello") == true)
    }
}
