import XCTest
@testable import SwiftBot

final class CommunityStatsStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("community-stats-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func command(_ text: String, user: String = "111111111111111111", ok: Bool = true, at date: Date = Date()) -> CommandLogEntry {
        CommandLogEntry(time: date, user: user, server: "Server", command: text, channel: "general", executionRoute: "", executionNode: "", ok: ok)
    }

    func testPeriodBucketsCoverTheWindowAndEndToday() {
        let now = Date()
        XCTAssertEqual(AnalyticsPeriod.week.buckets(now: now).count, 7)
        XCTAssertEqual(AnalyticsPeriod.month.buckets(now: now).count, 30)
        XCTAssertEqual(AnalyticsPeriod.year.buckets(now: now).count, 12)
        for period in AnalyticsPeriod.allCases {
            XCTAssertTrue(period.buckets(now: now).last?.contains(now) == true, "\(period) should end with the current bucket")
            XCTAssertEqual(period.previousWindow(now: now).end, period.window(now: now).start)
        }
        XCTAssertEqual(AnalyticsPeriod(query: "nonsense"), .week)
    }

    func testCommandsJoinsAndLeavesLandInTheirBuckets() async {
        let store = CommunityStatsStore(url: url)
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        await store.recordCommand(command("/rank"))
        await store.recordCommand(command("/rank extra args", ok: false))
        await store.recordCommand(command("/roll 2d6", at: yesterday))
        await store.recordMemberJoin(at: now)
        await store.recordMemberLeave(at: yesterday)

        let buckets = AnalyticsPeriod.week.buckets(now: now)
        let summary = await store.summary(buckets: buckets, in: AnalyticsPeriod.week.window(now: now))
        XCTAssertEqual(summary.commandCount, 3)
        XCTAssertEqual(summary.failedCommands, 1)
        XCTAssertEqual(summary.commands["/rank"], 2, "Arguments are stripped to the command name")
        XCTAssertEqual(summary.commandsPerBucket.last, 2)
        XCTAssertEqual(summary.commandsPerBucket[buckets.count - 2], 1)
        XCTAssertEqual(summary.joins, 1)
        XCTAssertEqual(summary.leavesPerBucket[buckets.count - 2], 1)
    }

    func testFeatureUsageFiltersDatesAndSurvivesReload() async {
        let store = CommunityStatsStore(url: url)
        let now = Date()
        let older = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        await store.recordFeatureUse("announcer", count: 4, at: now)
        await store.recordFeatureUse("announcer", count: 2, at: now)
        await store.recordFeatureUse("patchy", count: 1, at: older)
        await store.recordFeatureUse("sweep", count: 0, at: now)
        await store.recordFeatureUse("sweep", count: -1, at: now)
        await store.flush()
        let reloaded = CommunityStatsStore(url: url)
        let summary = await reloaded.summary(buckets: AnalyticsPeriod.week.buckets(now: now), in: AnalyticsPeriod.week.window(now: now))
        XCTAssertEqual(summary.featureUses, ["announcer": 6])
    }

    func testLegacyDayWithoutFeatureUsageStillDecodes() throws {
        let data = Data(#"{"commands":{"/rank":2},"users":{},"channels":{},"commandCount":2,"failedCommands":0,"joins":1,"leaves":0}"#.utf8)
        let day = try JSONDecoder().decode(CommunityDayStats.self, from: data)
        XCTAssertEqual(day.commandCount, 2)
        XCTAssertNil(day.featureUses)
    }

    func testBackfillOnlyHappensOnce() async {
        let store = CommunityStatsStore(url: url)
        let log = [command("/rank"), command("/roll")]
        await store.backfillIfNeeded(from: log)
        await store.backfillIfNeeded(from: log)
        let summary = await store.summary(buckets: AnalyticsPeriod.week.buckets(), in: AnalyticsPeriod.week.window())
        XCTAssertEqual(summary.commandCount, 2)
    }

    func testRankHistorySkipsRepeatsAndSurvivesReload() async {
        let store = CommunityStatsStore(url: url)
        let start = Date().addingTimeInterval(-3_600)
        await store.recordRank(playerID: "p", displayName: "jonwatso", game: "THE FINALS", score: 28_000, rankName: "Gold", at: start)
        await store.recordRank(playerID: "p", displayName: "jonwatso", game: "THE FINALS", score: 28_000, rankName: "Gold", at: start.addingTimeInterval(60))
        await store.recordRank(playerID: "p", displayName: "jonwatso", game: "THE FINALS", score: 28_160, rankName: "Gold", at: start.addingTimeInterval(120))
        await store.recordRank(playerID: "p", displayName: "jonwatso", game: "THE FINALS", score: 0, rankName: nil)
        await store.flush()

        let reloaded = CommunityStatsStore(url: url)
        let series = await reloaded.rankHistory(since: start.addingTimeInterval(-1))
        XCTAssertEqual(series["p"]?.points.map(\.score), [28_000, 28_160])
    }
}
