import XCTest
@testable import SwiftBot

final class ReplayTests: XCTestCase {

    // MARK: Periods

    func testPeriodKeysParseAndRoundTrip() {
        XCTAssertEqual(ReplayPeriod(key: "2026"), .year(2026))
        XCTAssertEqual(ReplayPeriod(key: "2026-09"), .month(year: 2026, month: 9))
        XCTAssertEqual(ReplayPeriod(key: "2026-09")?.key, "2026-09")
        XCTAssertNil(ReplayPeriod(key: "2026-13"))
        XCTAssertNil(ReplayPeriod(key: "nonsense"))
        XCTAssertNil(ReplayPeriod(key: "1999"))
    }

    func testBucketsAreMonthsOfAYearAndDaysOfAMonth() {
        XCTAssertEqual(ReplayPeriod.year(2026).buckets().count, 12)
        XCTAssertEqual(ReplayPeriod.month(year: 2026, month: 2).buckets().count, 28)
        XCTAssertEqual(ReplayPeriod.month(year: 2028, month: 2).buckets().count, 29)
    }

    func testIntervalStopsAtNowWhileThePeriodIsRunning() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
        let year = ReplayPeriod.year(2026).interval(now: now)
        XCTAssertEqual(year.end, now)
        let september = ReplayPeriod.month(year: 2026, month: 9).interval(now: now)
        XCTAssertEqual(september.end, calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        XCTAssertEqual(ReplayPeriod.previousMonth(before: now), .month(year: 2026, month: 9))
        let january = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 10))!
        XCTAssertEqual(ReplayPeriod.previousMonth(before: january), .month(year: 2026, month: 12))
    }

    func testPreviousPeriodWrapsAcrossYears() {
        XCTAssertEqual(ReplayPeriod.month(year: 2027, month: 1).previous, .month(year: 2026, month: 12))
        XCTAssertEqual(ReplayPeriod.month(year: 2026, month: 9).previous, .month(year: 2026, month: 8))
        XCTAssertEqual(ReplayPeriod.year(2026).previous, .year(2025))
    }

    // MARK: Settings

    /// Rewind settings weren't part of BotSettings' coding keys, so turning
    /// Rewind on never survived a relaunch.
    func testRewindSettingsSurviveASaveAndLoad() throws {
        var settings = BotSettings()
        settings.rewind.isEnabled = true
        settings.rewind.retentionDays = 90
        settings.rewind.replayDMOptOutUserIDs = ["123"]
        var drop = RewindRecapDrop()
        drop.channelID = "c1"
        drop.monthly = true
        drop.lastMonthlyKey = "2026-09"
        settings.rewind.recapDrops["g1"] = drop

        let data = try JSONEncoder().encode(settings)
        let loaded = try JSONDecoder().decode(BotSettings.self, from: data)
        XCTAssertTrue(loaded.rewind.isEnabled)
        XCTAssertEqual(loaded.rewind.retentionDays, 90)
        XCTAssertEqual(loaded.rewind.replayDMOptOutUserIDs, ["123"])
        XCTAssertEqual(loaded.rewind.recapDrops["g1"]?.channelID, "c1")
        XCTAssertEqual(loaded.rewind.recapDrops["g1"]?.lastMonthlyKey, "2026-09")
    }

    func testPartialRewindSettingsFallBackToDefaults() throws {
        let loaded = try JSONDecoder().decode(RewindSettings.self, from: Data(#"{"isEnabled":true}"#.utf8))
        XCTAssertTrue(loaded.isEnabled)
        XCTAssertTrue(loaded.retainMessageContent)
        XCTAssertTrue(loaded.recapDrops.isEmpty)
    }

    func testPersonalDMSettingsSurviveASaveAndLoad() throws {
        var settings = RewindSettings()
        settings.replayDMOptOutUserIDs = ["42"]
        settings.lastCatchUpAt = Date(timeIntervalSince1970: 1_790_000_000)
        var drop = RewindRecapDrop()
        drop.monthly = true
        drop.personalDMs = true
        drop.onlyDMActiveMembers = false
        drop.lastPersonalMonthlyKey = "2026-09"
        settings.recapDrops["g1"] = drop

        let loaded = try JSONDecoder().decode(RewindSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(loaded.replayDMOptOutUserIDs, ["42"])
        XCTAssertEqual(loaded.lastCatchUpAt, settings.lastCatchUpAt)
        XCTAssertEqual(loaded.recapDrops["g1"]?.personalDMs, true)
        XCTAssertEqual(loaded.recapDrops["g1"]?.onlyDMActiveMembers, false)
        XCTAssertEqual(loaded.recapDrops["g1"]?.lastPersonalMonthlyKey, "2026-09")
    }

    func testDropIsScheduledWithDMsAndNoChannel() throws {
        let old = try JSONDecoder().decode(RewindRecapDrop.self, from: Data(#"{"channelID":"c1","monthly":true}"#.utf8))
        XCTAssertFalse(old.personalDMs, "Drops saved before DMs existed stay channel-only")
        XCTAssertTrue(old.onlyDMActiveMembers, "Existing settings default to filtering occasional members")
        XCTAssertTrue(old.isScheduled)

        var dmsOnly = RewindRecapDrop()
        dmsOnly.yearly = true
        XCTAssertFalse(dmsOnly.isScheduled, "Nowhere to deliver yet")
        dmsOnly.personalDMs = true
        XCTAssertTrue(dmsOnly.isScheduled)
    }

    // MARK: Archive summaries

    func testReplayDMActivityRequiresRegularRecentChatInTheSameGuild() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rewind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RewindStore(rootURL: root)
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 12))!
        var sequence = 0
        func post(_ user: String, count: Int, daysAgo: Int, guild: String = "g") async {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            for _ in 0..<count {
                sequence += 1
                await store.record(RewindMessage(
                    id: String(sequence), guildID: guild, channelID: "general",
                    authorID: user, authorName: user, isBot: false,
                    content: "hello", createdAt: date
                ), retainContent: false)
            }
        }
        // Exactly ten messages on three days, including the oldest included
        // day and today. The window crosses the aggregate-file year boundary.
        await post("regular", count: 4, daysAgo: 29)
        await post("regular", count: 3, daysAgo: 2)
        await post("regular", count: 3, daysAgo: 0)
        await post("burst", count: 100, daysAgo: 0)
        for day in 0..<3 { await post("sparse", count: 3, daysAgo: day) }
        await post("old", count: 4, daysAgo: 30)
        await post("old", count: 3, daysAgo: 31)
        await post("old", count: 3, daysAgo: 32)
        await post("boundary", count: 4, daysAgo: 30)
        await post("boundary", count: 3, daysAgo: 1)
        await post("boundary", count: 3, daysAgo: 0)
        for day in 0..<3 { await post("other-guild", count: 4, daysAgo: day, guild: "elsewhere") }
        for day in 1...3 { await post("future", count: 4, daysAgo: -day) }

        let recipients = await store.replayDMActiveUserIDs(guildID: "g", now: now)
        XCTAssertEqual(recipients, ["regular"])
        // The query flushes buffered counts and needs no retained message text.
        let reloaded = RewindStore(rootURL: root)
        let persistedRecipients = await reloaded.replayDMActiveUserIDs(guildID: "g", now: now)
        XCTAssertEqual(persistedRecipients, recipients)
    }

    func testRangeSummaryLeavesOutOptedOutMembers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rewind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RewindStore(rootURL: root)
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 21))!
        func message(_ id: String, author: String, text: String) -> RewindMessage {
            RewindMessage(id: id, guildID: "g", channelID: "general", authorID: author, authorName: author,
                          isBot: false, content: text, createdAt: day)
        }
        _ = await store.importMessages([
            message("1", author: "alice", text: "gg guys"),
            message("2", author: "alice", text: "gg again"),
            message("3", author: "bob", text: "hello"),
            message("4", author: "hidden", text: "secret")
        ], retainContent: true)

        let period = ReplayPeriod.year(2026)
        let interval = period.interval(now: Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 31))!)
        let summary = await store.rangeSummary(
            guildID: "g", start: interval.start, end: interval.end, buckets: period.buckets(),
            excludingUsers: ["hidden"], filterStopWords: false
        )
        XCTAssertEqual(summary.totalMessages, 3)
        XCTAssertEqual(summary.topUsers.map(\.userID), ["alice", "bob"])
        XCTAssertEqual(summary.bucketCounts[2], 3, "March holds every message")
        XCTAssertEqual(summary.peakHour, 21)

        let alice = await store.userRangeSummary(guildID: "g", userID: "alice", start: interval.start, end: interval.end, excludingUsers: ["hidden"])
        XCTAssertEqual(alice.messages, 2)
        XCTAssertEqual(alice.rank, 1)
        XCTAssertEqual(alice.rankedMembers, 2)
    }

    // MARK: Discord recap

    @MainActor
    func testRecapEmbedsStayWithinDiscordLimits() {
        var replay = ServerReplay(guildID: "g", guildName: "Swift Lounge", periodKey: "2026", periodTitle: "2026", isYear: true, isComplete: true)
        replay.messages = 182_441
        replay.chattingMembers = 64
        replay.voiceSeconds = 1_840_000
        replay.voiceSessions = 2_900
        replay.busiestDay = "2026-03-14"
        replay.peakHour = 21
        replay.topMembers = (1...10).map { .init(title: "member-with-a-long-name-\($0)", count: 1_000 * $0) }
        replay.topVoiceMembers = replay.topMembers
        replay.topChannels = (1...5).map { .init(title: "#channel-\($0)", count: $0) }
        replay.topWords = (1...12).map { .init(title: "word\($0)", count: $0) }
        replay.topEmoji = ["😂", "🔥"].map { .init(title: $0, count: 1) }

        let embeds = AppModel().replayEmbeds(replay)
        XCTAssertLessThanOrEqual(embeds.count, 10)
        let text = try! JSONSerialization.data(withJSONObject: embeds)
        XCTAssertLessThan(text.count, 6_000, "Discord caps a message's embeds at 6,000 characters")
        XCTAssertNotNil(embeds.last?["footer"])
    }
}
