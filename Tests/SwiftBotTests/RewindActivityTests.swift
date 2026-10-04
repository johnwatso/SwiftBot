import XCTest
@testable import SwiftBot

final class RewindActivityTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func activity(_ name: String, type: Int = 0, details: String? = nil, startedAt: Date? = nil) -> GatewayPresenceActivity {
        GatewayPresenceActivity(name: name, type: type, applicationID: nil, details: details, state: nil, startedAt: startedAt)
    }

    private func presence(_ activities: [GatewayPresenceActivity], status: String = "online") -> GatewayPresenceUpdateEvent {
        GatewayPresenceUpdateEvent(guildID: "guild-1", userID: "user-1", status: status, activities: activities)
    }

    // MARK: Tracker

    func testSegmentClosesWhenActivityDisappears() {
        var tracker = PresenceArchiveTracker()
        XCTAssertTrue(tracker.apply(presence([activity("THE FINALS")]), now: base).closed.isEmpty)

        let closed = tracker.apply(presence([]), now: base.addingTimeInterval(600)).closed
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.name, "THE FINALS")
        XCTAssertEqual(closed.first?.duration, 600)
        XCTAssertTrue(tracker.liveSegments.isEmpty)
    }

    func testDetailChangesBecomeSpans() {
        var tracker = PresenceArchiveTracker()
        _ = tracker.apply(presence([activity("THE FINALS", details: "Main menu")]), now: base)
        _ = tracker.apply(presence([activity("THE FINALS", details: "Main menu")]), now: base.addingTimeInterval(30))
        _ = tracker.apply(presence([activity("THE FINALS", details: "Cashout — Monaco")]), now: base.addingTimeInterval(60))
        let segment = tracker.apply(presence([]), now: base.addingTimeInterval(900)).closed.first

        XCTAssertEqual(segment?.spans.map(\.details), ["Main menu", "Cashout — Monaco"])
        XCTAssertEqual(segment?.span(at: base.addingTimeInterval(120))?.details, "Cashout — Monaco")
        XCTAssertEqual(segment?.span(at: base.addingTimeInterval(10))?.details, "Main menu")
    }

    func testListeningIsNotArchived() {
        var tracker = PresenceArchiveTracker()
        _ = tracker.apply(presence([activity("Spotify", type: PresenceActivityType.listening)]), now: base)
        XCTAssertTrue(tracker.liveSegments.isEmpty)
    }

    func testGoingOfflineClosesEverything() {
        var tracker = PresenceArchiveTracker()
        _ = tracker.apply(presence([activity("A"), activity("Live", type: PresenceActivityType.streaming)]), now: base)
        let closed = tracker.apply(presence([activity("A")], status: "offline"), now: base.addingTimeInterval(60)).closed
        XCTAssertEqual(closed.count, 2)
    }

    func testStatusChangesAreJournaledOnce() {
        var tracker = PresenceArchiveTracker()
        XCTAssertNotNil(tracker.apply(presence([]), now: base).statusChange)
        XCTAssertNil(tracker.apply(presence([]), now: base.addingTimeInterval(5)).statusChange)
        XCTAssertEqual(
            tracker.apply(presence([], status: "idle"), now: base.addingTimeInterval(10)).statusChange?.event,
            RewindJournalEntry.statusEvent
        )
    }

    func testRecoveredSessionIsNotDoubleCounted() {
        var tracker = PresenceArchiveTracker()
        _ = tracker.apply(presence([activity("A", startedAt: base)]), now: base.addingTimeInterval(60))
        let checkpoint = tracker.liveSegments

        var restarted = PresenceArchiveTracker()
        let recovered = restarted.recover(checkpoint, endedAt: base.addingTimeInterval(300))
        XCTAssertEqual(recovered.first?.endedAt, base.addingTimeInterval(300))

        // Discord re-reports the original start; the new segment picks up where
        // the recovered one ended.
        _ = restarted.apply(presence([activity("A", startedAt: base)]), now: base.addingTimeInterval(400))
        XCTAssertEqual(restarted.liveSegments.first?.startedAt, base.addingTimeInterval(300))
    }

    // MARK: Parsing

    func testPresenceParsingKeepsRichDetail() throws {
        let raw: [String: DiscordJSON] = [
            "user": .object(["id": .string("user-1")]),
            "status": .string("dnd"),
            "client_status": .object(["desktop": .string("dnd")]),
            "activities": .array([.object([
                "name": .string("THE FINALS"),
                "type": .int(0),
                "details": .string("Ranked"),
                "state": .string("In a match"),
                "timestamps": .object(["start": .int(1_800_000_000_000)]),
                "assets": .object(["large_text": .string("Monaco"), "small_text": .string("Heavy")]),
                "party": .object(["id": .string("p1"), "size": .array([.int(2), .int(3)])])
            ])])
        ]
        let event = try XCTUnwrap(GatewayEventDispatcher.parsePresence(raw, guildID: "guild-1"))
        let parsed = try XCTUnwrap(event.activities.first)
        XCTAssertEqual(event.clientStatus, ["desktop": "dnd"])
        XCTAssertEqual(parsed.largeText, "Monaco")
        XCTAssertEqual(parsed.smallText, "Heavy")
        XCTAssertEqual(parsed.partySize, 2)
        XCTAssertEqual(parsed.partyMax, 3)
        XCTAssertEqual(parsed.startedAt, base)
    }

    func testMessageMetaFromRawMessage() throws {
        let raw: [String: DiscordJSON] = [
            "type": .int(19),
            "attachments": .array([.object([
                "filename": .string("clip.mp4"), "content_type": .string("video/mp4"), "size": .int(1_024)
            ])]),
            "message_reference": .object(["message_id": .string("m0")]),
            "referenced_message": .object(["author": .object(["id": .string("user-2")])]),
            "mentions": .array([.object(["id": .string("user-2")])])
        ]
        let meta = try XCTUnwrap(RewindMessageMeta(raw: raw))
        XCTAssertEqual(meta.attachments?.first?.fileName, "clip.mp4")
        XCTAssertEqual(meta.replyToMessageID, "m0")
        XCTAssertEqual(meta.replyToUserID, "user-2")
        XCTAssertEqual(meta.mentionUserIDs, ["user-2"])
        XCTAssertEqual(meta.messageType, 19)

        XCTAssertNil(RewindMessageMeta(raw: ["content": .string("hi"), "type": .int(0)]))
    }

    func testMessageWithoutMetaDecodesFromLegacyLine() throws {
        let line = #"{"c":"c1","d":1800000000,"g":"g1","i":"m1","n":"John","t":"gg","u":"u1"}"#
        let message = try JSONDecoder().decode(RewindMessage.self, from: Data(line.utf8))
        XCTAssertNil(message.meta)
        XCTAssertEqual(message.content, "gg")
    }

    // MARK: Store

    func testStoreAnswersWhatSomeoneWasPlaying() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RewindActivityStore(rootURL: root)

        await store.voiceStateChanged(guildID: "guild-1", userID: "user-1", channelID: "vc", now: base)
        await store.record(presence: presence([activity("THE FINALS", details: "Ranked")]), now: base)
        await store.record(presence: presence([]), now: base.addingTimeInterval(1_800))
        await store.flush()

        let hit = await store.activity(userID: "user-1", at: base.addingTimeInterval(900))
        XCTAssertEqual(hit?.segment.name, "THE FINALS")
        XCTAssertEqual(hit?.detail?.details, "Ranked")
        let miss = await store.activity(userID: "user-1", at: base.addingTimeInterval(7_200))
        XCTAssertNil(miss)
    }

    func testPresenceIsOnlyRecordedInVoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RewindActivityStore(rootURL: root)
        let window = (base.addingTimeInterval(-3_600), base.addingTimeInterval(36_000))

        // Playing since before joining voice: nothing yet.
        await store.record(presence: presence([activity("THE FINALS", startedAt: base.addingTimeInterval(-1_800))]), now: base)
        var segments = await store.presence(userID: "user-1", from: window.0, to: window.1)
        XCTAssertTrue(segments.isEmpty)

        // Joining starts recording from the join, using the cached presence.
        await store.voiceStateChanged(guildID: "guild-1", userID: "user-1", channelID: "vc", now: base.addingTimeInterval(600))
        // Moving channels doesn't split the segment.
        await store.voiceStateChanged(guildID: "guild-1", userID: "user-1", channelID: "vc2", now: base.addingTimeInterval(900))
        // Leaving ends it.
        await store.voiceStateChanged(guildID: "guild-1", userID: "user-1", channelID: nil, now: base.addingTimeInterval(1_200))
        // Still playing after leaving: not recorded.
        await store.record(presence: presence([activity("THE FINALS", details: "Ranked")]), now: base.addingTimeInterval(1_500))

        segments = await store.presence(userID: "user-1", from: window.0, to: window.1)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.startedAt, base.addingTimeInterval(600))
        XCTAssertEqual(segments.first?.endedAt, base.addingTimeInterval(1_200))
    }

    func testReconnectSnapshotEndsMembersWhoLeftVoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RewindActivityStore(rootURL: root)
        let playing = presence([activity("A")])

        await store.seedGuild(guildID: "guild-1", presences: [playing], voiceUserIDs: ["user-1"], now: base)
        await store.seedGuild(guildID: "guild-1", presences: [playing], voiceUserIDs: [], now: base.addingTimeInterval(300))

        let segments = await store.presence(userID: "user-1", from: base, to: base.addingTimeInterval(3_600))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.endedAt, base.addingTimeInterval(300))
    }
}
