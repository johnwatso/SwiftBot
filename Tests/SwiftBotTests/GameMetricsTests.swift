import XCTest
@testable import SwiftBot

final class GameMetricsTests: XCTestCase {

    private func player(
        trigger: Set<GameMetricID>,
        context: Set<GameMetricID> = []
    ) -> GameTrackedPlayer {
        var p = GameTrackedPlayer(displayName: "Tyr")
        p.playerID = "p-1"
        p.destinationChannelID = "channel-1"
        p.triggerMetrics = trigger
        p.contextMetrics = context
        return p
    }

    private func snapshot(score: Int, metrics: [GameMetricID: Double]) -> GameRankSnapshot {
        GameRankSnapshot(
            game: .theFinals, provider: .finalsID, playerID: "p-1", displayName: "Tyr",
            season: "s11", rankName: nil, score: score, updatedAt: nil,
            metrics: GameMetricSet(metrics)
        )
    }

    // MARK: - Formatting

    func testEachFormatRendersItsMetricCorrectly() {
        XCTAssertEqual(GameMetricID.kills.formatted(1234), "1,234")
        XCTAssertEqual(GameMetricID.killDeathRatio.formatted(2.0), "2.00")
        XCTAssertEqual(GameMetricID.timePlayed.formatted(5_400), "1h 30m")
        // Providers report percentages as either a fraction or 0-100.
        XCTAssertEqual(GameMetricID.winRate.formatted(0.55), "55.0%")
        XCTAssertEqual(GameMetricID.winRate.formatted(55), "55.0%")
    }

    func testDeltasAreSignedAndUseTheMetricFormat() {
        XCTAssertEqual(GameMetricID.rankedScore.formattedDelta(320), "+320")
        XCTAssertEqual(GameMetricID.rankedScore.formattedDelta(-150), "-150")
        XCTAssertEqual(GameMetricID.killDeathRatio.formattedDelta(-0.04), "-0.04")
    }

    // MARK: - Derived ratios

    func testRatiosAreDerivedFromCountersWhenTheProviderOmitsThem() {
        let snap = snapshot(score: 0, metrics: [.kills: 300, .deaths: 150, .wins: 6, .losses: 4, .timePlayed: 3_600])

        XCTAssertEqual(snap.metrics[.killDeathRatio] ?? 0, 2.0, accuracy: 0.001)
        XCTAssertEqual(snap.metrics[.winRate] ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(snap.metrics[.killsPerMinute] ?? 0, 5.0, accuracy: 0.001)
    }

    func testProviderSuppliedRatioIsNotOverwritten() {
        let snap = snapshot(score: 0, metrics: [.kills: 300, .deaths: 150, .killDeathRatio: 1.87])
        XCTAssertEqual(snap.metrics[.killDeathRatio] ?? 0, 1.87, accuracy: 0.001)
    }

    func testDivisionByZeroDoesNotProduceInfinity() {
        let snap = snapshot(score: 0, metrics: [.kills: 42, .deaths: 0])
        XCTAssertEqual(snap.metrics[.killDeathRatio] ?? 0, 42, accuracy: 0.001)
    }

    // MARK: - Trigger rules

    func testCountersCanNeverTriggerAnAnnouncement() {
        // The whole point: kills only climb, so triggering on one would post
        // after every single match.
        XCTAssertFalse(GameMetricID.kills.canTriggerAnnouncement)
        XCTAssertFalse(GameMetricID.matchesPlayed.canTriggerAnnouncement)
        XCTAssertFalse(GameMetricID.timePlayed.canTriggerAnnouncement)

        XCTAssertTrue(GameMetricID.killDeathRatio.canTriggerAnnouncement)
        XCTAssertTrue(GameMetricID.rankedScore.canTriggerAnnouncement)
        XCTAssertTrue(GameMetricID.winRate.canTriggerAnnouncement)
    }

    func testSelectingACounterAsATriggerIsFilteredOut() {
        let p = player(trigger: [.rankedScore, .kills, .timePlayed])
        XCTAssertEqual(p.effectiveTriggerMetrics, [.rankedScore])
    }

    func testKillDeathChangeTriggersWithoutAnyRankedScoreMovement() {
        let target = player(trigger: [.killDeathRatio], context: [.kills])
        let previous = GameRankBaseline(
            snapshot: snapshot(score: 0, metrics: [.kills: 300, .deaths: 150]),
            displayName: "Tyr",
            recordedAt: Date(timeIntervalSince1970: 0)
        )
        let current = snapshot(score: 0, metrics: [.kills: 320, .deaths: 170])

        guard case let .changed(change) = GameRankEvaluator.evaluate(
            target: target, current: current, previous: previous
        ) else {
            return XCTFail("A K/D move must trigger even with no ranked score")
        }

        XCTAssertEqual(change.delta, 0, "No ranked score involved")
        XCTAssertEqual(change.metricChanges.count, 1)
        XCTAssertEqual(change.metricChanges.first?.metric, .killDeathRatio)
        XCTAssertLessThan(change.metricChanges.first?.delta ?? 0, 0, "K/D fell")
        XCTAssertEqual(change.contextMetrics[.kills], 320)
    }

    func testCounterMovementAloneDoesNotTrigger() {
        // Playing a match bumps kills; that must stay silent.
        let target = player(trigger: [.killDeathRatio])
        let previous = GameRankBaseline(
            snapshot: snapshot(score: 0, metrics: [.kills: 300, .deaths: 150]),
            displayName: "Tyr",
            recordedAt: Date(timeIntervalSince1970: 0)
        )
        // Kills and deaths both rise, leaving K/D exactly 2.0.
        let current = snapshot(score: 0, metrics: [.kills: 400, .deaths: 200])

        guard case .unchanged = GameRankEvaluator.evaluate(
            target: target, current: current, previous: previous
        ) else {
            return XCTFail("An unchanged ratio must not announce")
        }
    }

    func testRatingOnlyProviderBehavesExactlyAsBefore() {
        let target = player(trigger: [.rankedScore])
        let previous = GameRankBaseline(
            snapshot: snapshot(score: 31_000, metrics: [:]),
            displayName: "Tyr",
            recordedAt: Date(timeIntervalSince1970: 0)
        )
        let current = snapshot(score: 31_520, metrics: [:])

        guard case let .changed(change) = GameRankEvaluator.evaluate(
            target: target, current: current, previous: previous
        ) else {
            return XCTFail("Expected a ranked-score change")
        }
        XCTAssertEqual(change.delta, 520)
    }

    // MARK: - Embed

    func testEmbedNamesNonScoreMetricsExplicitly() throws {
        let target = player(trigger: [.killDeathRatio], context: [.wins])
        let previous = GameRankBaseline(
            snapshot: snapshot(score: 0, metrics: [.kills: 300, .deaths: 150, .wins: 40]),
            displayName: "Tyr",
            recordedAt: Date(timeIntervalSince1970: 0)
        )
        let current = snapshot(score: 0, metrics: [.kills: 340, .deaths: 155, .wins: 46])

        guard case let .changed(change) = GameRankEvaluator.evaluate(
            target: target, current: current, previous: previous
        ) else {
            return XCTFail("Expected a change")
        }

        let embed = GameTrackingNotificationBuilder.embed(changes: [change], checkedAt: Date())
        let fields = try XCTUnwrap(embed["fields"] as? [[String: Any]])
        let value = try XCTUnwrap(fields.first?["value"] as? String)

        XCTAssertTrue(value.contains("K/D"), "Non-score metrics must be labelled: \(value)")
        XCTAssertTrue(value.contains("Wins 46"), "Context metric should appear: \(value)")
        XCTAssertFalse(value.contains("SR"), "No ranked score moved, so no SR line: \(value)")
    }

    func testMetricSetSurvivesCodableRoundTrip() throws {
        let original = GameMetricSet([.kills: 300, .killDeathRatio: 2.0, .winRate: 0.55])
        let decoded = try JSONDecoder().decode(
            GameMetricSet.self, from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    func testBaselineWrittenBeforeMetricsExistedStillDecodes() throws {
        let legacy = Data(#"""
        {"game":"theFinals","provider":"finalsID","playerID":"p-1","displayName":"Tyr",
         "season":"s11","score":31000,"recordedAt":0}
        """#.utf8)
        let decoded = try JSONDecoder().decode(GameRankBaseline.self, from: legacy)

        XCTAssertEqual(decoded.score, 31_000)
        XCTAssertTrue(decoded.metrics.isEmpty)
    }
}
