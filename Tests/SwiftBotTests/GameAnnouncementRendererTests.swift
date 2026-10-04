import XCTest
@testable import SwiftBot

final class GameAnnouncementRendererTests: XCTestCase {

    // MARK: - Rank tiers

    func testFinalsRankIndexResolvesToNamedDivision() {
        let ladder: [(Int, String)] = [(1, "Bronze 4"), (4, "Bronze 1"), (5, "Silver 4"), (12, "Gold 1"), (13, "Platinum 4"), (20, "Diamond 1"), (21, "Ruby")]
        for (index, name) in ladder {
            XCTAssertEqual(GameID.theFinals.rankTier(index: index, score: nil, league: nil)?.name, name, "index \(index)")
        }
    }

    func testTierAcceptsStoredFullNameAsLeague() {
        // Baselines now store "Gold 1"; reading it back must still match the league.
        XCTAssertEqual(GameID.theFinals.rankTier(index: 12, score: 28_160, league: "Gold 1")?.name, "Gold 1")
    }

    func testIndexThatContradictsLeagueFallsBackToScore() {
        XCTAssertEqual(GameID.theFinals.rankTier(index: 2, score: 28_160, league: "Gold")?.name, "Gold 1")
    }

    func testLeagueAloneIsShownUndivided() {
        XCTAssertEqual(GameID.theFinals.rankTier(index: nil, score: nil, league: "Platinum")?.name, "Platinum")
    }

    func testProgressTowardsNextDivision() throws {
        let tier = try XCTUnwrap(GameID.theFinals.rankTier(index: 12, score: 28_160, league: "Gold"))
        XCTAssertEqual(tier.nextName, "Platinum 4")
        XCTAssertEqual(try XCTUnwrap(tier.progress(score: 28_160)), 0.264, accuracy: 0.001)
        XCTAssertNil(tier.progress(score: 31_000), "A score outside the band shows no bar")
    }

    func testZeroScoreWithoutRankDataHasNoTier() {
        let change = GameRankChange(
            targetID: UUID(), game: .theFinals, provider: .finalsID, destinationChannelID: "c",
            playerID: "p", displayName: "Tyr", season: "", rankName: nil, previousScore: 0, currentScore: 0
        )
        XCTAssertNil(change.currentTier, "A metrics-only profile is not Bronze 4")
    }

    func testRankTierMetricFormatsAsDivisionName() {
        XCTAssertEqual(GameID.theFinals.formattedMetric(.rankTier, 12), "Gold 1")
        XCTAssertEqual(GameID.theFinals.formattedMetric(.wins, 12), "12")
    }

    // MARK: - Rendering

    private func promotion() -> GameRankChange {
        GameRankChange(
            targetID: UUID(), game: .theFinals, provider: .finalsID, destinationChannelID: "c",
            playerID: "tyr#1234", displayName: "Tyr", season: "s11", rankName: "Gold 1",
            previousScore: 27_300, currentScore: 28_160,
            metricChanges: [
                GameMetricChange(metric: .rankedScore, previous: 27_300, current: 28_160),
                GameMetricChange(metric: .rankTier, previous: 11, current: 12)
            ],
            previousRankName: "Gold 2",
            previousMetrics: GameMetricSet([.rankTier: 11, .leaderboardPosition: 58_070]),
            currentMetrics: GameMetricSet([.rankTier: 12, .leaderboardPosition: 56_866]),
            discordUserID: "412378964087275541"
        )
    }

    func testCardAnnouncesPromotionWithTierColourAndProgress() throws {
        let messages = GameAnnouncementRenderer.rankUpdateMessages(
            changes: [promotion()], checkedAt: Date(), style: GameAnnouncementStyle()
        )
        let embed = try XCTUnwrap((messages.first?.payload["embeds"] as? [[String: Any]])?.first)
        XCTAssertEqual(embed["title"] as? String, "▲ Ranked up to Gold 1")
        XCTAssertEqual(embed["color"] as? Int, 0xF1C40F)
        let description = try XCTUnwrap(embed["description"] as? String)
        XCTAssertTrue(description.contains("**Gold 1**"), description)
        XCTAssertTrue(description.contains("1,840 SR to Platinum 4"), description)
        let fields = try XCTUnwrap(embed["fields"] as? [[String: Any]])
        XCTAssertTrue(fields.contains { ($0["value"] as? String) == "Gold 2 → **Gold 1**" })
        XCTAssertTrue(fields.contains { ($0["value"] as? String)?.contains("#56,866") == true })
        XCTAssertFalse(fields.contains { ($0["value"] as? String)?.contains("12") == true && ($0["name"] as? String) == "Rank" })
    }

    func testCardSplitsIntoMessagesOfTenEmbeds() {
        let changes = (0..<12).map { _ in promotion() }
        let messages = GameAnnouncementRenderer.rankUpdateMessages(changes: changes, checkedAt: Date(), style: GameAnnouncementStyle())
        XCTAssertEqual(messages.map { ($0.payload["embeds"] as? [Any])?.count }, [10, 2])
        XCTAssertEqual(messages.flatMap(\.targetIDs).count, 12)
    }

    func testMentionsOnlyWhenEnabledAndNeverParseEveryone() throws {
        var style = GameAnnouncementStyle()
        let quiet = try XCTUnwrap(GameAnnouncementRenderer.rankUpdateMessages(changes: [promotion()], checkedAt: Date(), style: style).first)
        XCTAssertNil(quiet.payload["content"])

        style.mentionPlayer = true
        let loud = try XCTUnwrap(GameAnnouncementRenderer.rankUpdateMessages(changes: [promotion()], checkedAt: Date(), style: style).first)
        XCTAssertEqual(loud.payload["content"] as? String, "<@412378964087275541>")
        let allowed = try XCTUnwrap(loud.payload["allowed_mentions"] as? [String: Any])
        XCTAssertEqual((allowed["parse"] as? [String])?.isEmpty, true)
        XCTAssertEqual(allowed["users"] as? [String], ["412378964087275541"])
    }

    func testTitleTemplateFillsPlaceholders() throws {
        var style = GameAnnouncementStyle()
        style.rankTitleTemplate = "{player} hit {rank} ({delta} {unit})"
        XCTAssertEqual(GameAnnouncementRenderer.rankTitle(promotion(), style: style), "Tyr hit Gold 1 (+860 SR)")
    }

    func testMinimalLayoutIsPlainText() throws {
        var style = GameAnnouncementStyle()
        style.layout = .minimal
        let message = try XCTUnwrap(GameAnnouncementRenderer.rankUpdateMessages(changes: [promotion()], checkedAt: Date(), style: style).first)
        XCTAssertNil(message.payload["embeds"])
        let content = try XCTUnwrap(message.payload["content"] as? String)
        XCTAssertTrue(content.contains("ranked up to") && content.contains("Gold 1"), content)
    }

    func testCustomAccentColour() throws {
        var style = GameAnnouncementStyle()
        style.accent = .custom
        style.customColor = "#123ABC"
        let embed = GameAnnouncementRenderer.rankCard(promotion(), checkedAt: Date(), style: style)
        XCTAssertEqual(embed["color"] as? Int, 0x123ABC)
    }

    func testStyleDecodesWithMissingFieldsAndNormalizesBadColour() throws {
        var style = try JSONDecoder().decode(GameAnnouncementStyle.self, from: Data(#"{"layout":"minimal","customColor":"nope"}"#.utf8))
        XCTAssertEqual(style.layout, .minimal)
        XCTAssertTrue(style.showProgress)
        style.normalize()
        XCTAssertNotNil(style.customColorValue)
    }
    // MARK: - Sharing

    func testUnsharedStatsStayOffThePost() throws {
        var style = GameAnnouncementStyle()
        style.sharedStats.remove(.leaderboardPosition)
        style.sharedStats.remove(.rankTier)
        let embed = GameAnnouncementRenderer.rankCard(promotion(), checkedAt: Date(), style: style)
        let text = [embed["title"], embed["description"]].compactMap { $0 as? String }.joined()
            + ((embed["fields"] as? [[String: Any]]) ?? []).compactMap { $0["value"] as? String }.joined()
        XCTAssertFalse(text.contains("#56,866"), text)
        XCTAssertFalse(text.contains("Gold"), text)
        XCTAssertEqual(embed["title"] as? String, "▲ +860 SR", "Falls back to the shared SR headline")
    }

    func testSessionCardOnlySharesTickedStats() throws {
        var style = GameAnnouncementStyle()
        style.sharedStats = [.wins]
        var totals = GameSessionSummaryBuilder.Totals()
        totals.matches = 6; totals.wins = 2; totals.kills = 38; totals.deaths = 21; totals.damage = 21_430
        let end = Date()
        let payload = GameAnnouncementRenderer.sessionMessage(.init(
            session: GameSession(userID: "u", guildID: "g", gameName: "THE FINALS", startedAt: end.addingTimeInterval(-600), endedAt: end),
            displayName: "Tyr", game: .theFinals, providerName: "finals.id", totals: totals,
            rankName: "Gold 1", score: 28_160, rankIndex: 12
        ), style: style)
        let embed = try XCTUnwrap((payload["embeds"] as? [[String: Any]])?.first)
        let names = ((embed["fields"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["Duration", "Wins"])
    }

    func testLegacyShowSwitchesMigrateToSharedStats() throws {
        let style = try JSONDecoder().decode(
            GameAnnouncementStyle.self,
            from: Data(#"{"showLeaderboard":false,"showStats":false}"#.utf8)
        )
        XCTAssertEqual(style.sharedStats, [.rankTier, .rankedScore])
        XCTAssertEqual(style.announceOn, [.rankedScore, .rankTier])
    }

    func testStyleRoundTrips() throws {
        var style = GameAnnouncementStyle()
        style.announceOn = [.killDeathRatio]
        style.sharedStats = [.wins, .damage]
        let decoded = try JSONDecoder().decode(GameAnnouncementStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(decoded, style)
    }

    // MARK: - Recording

    func testStatsFileFromBeforeSessionsStillLoads() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // No sessionHistory or backfilledCommandLog keys, as an older build wrote it.
        try Data(#"{"days":{},"rankHistory":{"p":{"displayName":"Tyr","game":"THE FINALS","points":[{"date":"2026-10-01T00:00:00Z","score":28000,"rankName":"Gold"}]}}}"#.utf8).write(to: url)
        let store = CommunityStatsStore(url: url)
        let history = await store.rankHistory(since: .distantPast)
        XCTAssertEqual(history["p"]?.points.count, 1, "An older file must not be discarded")
    }

    func testEveryStatIsRecordedWithTheRankPoint() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CommunityStatsStore(url: url)
        await store.recordRank(
            playerID: "p", displayName: "Tyr", game: "THE FINALS", score: 28_160, rankName: "Gold 1",
            metrics: GameMetricSet([.rankedScore: 28_160, .rankTier: 12, .leaderboardPosition: 56_866])
        )
        // Same SR, but the leaderboard moved: still worth a point.
        await store.recordRank(
            playerID: "p", displayName: "Tyr", game: "THE FINALS", score: 28_160, rankName: "Gold 1",
            metrics: GameMetricSet([.rankedScore: 28_160, .rankTier: 12, .leaderboardPosition: 55_000])
        )
        let points = await store.rankHistory(since: .distantPast)["p"]?.points ?? []
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.last?.metrics?["leaderboardPosition"], 55_000)
    }
}
