import XCTest
@testable import SwiftBot

final class GamePresenceSessionTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func presence(
        playing games: [String],
        status: String = "online",
        startedAt: Date? = nil
    ) -> GatewayPresenceUpdateEvent {
        GatewayPresenceUpdateEvent(
            guildID: "guild-1",
            userID: "user-1",
            status: status,
            activities: games.map {
                GatewayPresenceActivity(
                    name: $0,
                    type: GatewayPresenceActivity.playingType,
                    applicationID: nil,
                    details: nil,
                    state: nil,
                    startedAt: startedAt
                )
            }
        )
    }

    func testSessionStartsWhenAGameActivityAppears() {
        var tracker = GamePresenceSessionTracker()
        let events = tracker.apply(presence(playing: ["THE FINALS"]), now: base)

        guard case let .started(session)? = events.first else {
            return XCTFail("Expected a session start")
        }
        XCTAssertEqual(session.gameName, "THE FINALS")
        XCTAssertEqual(session.startedAt, base)
        XCTAssertEqual(tracker.activeGames(for: "user-1"), ["THE FINALS"])
    }

    func testNonPlayingActivitiesAreIgnored() {
        var tracker = GamePresenceSessionTracker()
        let listening = GatewayPresenceUpdateEvent(
            guildID: "guild-1",
            userID: "user-1",
            status: "online",
            activities: [
                GatewayPresenceActivity(
                    name: "Spotify", type: 2, applicationID: nil,
                    details: nil, state: nil, startedAt: nil
                )
            ]
        )
        XCTAssertTrue(tracker.apply(listening, now: base).isEmpty)
        XCTAssertEqual(tracker.activeSessionCount, 0)
    }

    func testBriefActivityDropDoesNotEndTheSession() {
        // A client restart or a momentary detector glitch must not close a
        // session and produce a second announcement when the game reappears.
        var tracker = GamePresenceSessionTracker(
            configuration: GameSessionTrackerConfiguration(absenceGrace: 180, minimumSessionDuration: 300)
        )
        _ = tracker.apply(presence(playing: ["THE FINALS"]), now: base)

        // Activity vanishes...
        _ = tracker.apply(presence(playing: []), now: base.addingTimeInterval(600))
        XCTAssertTrue(tracker.tick(now: base.addingTimeInterval(700)).isEmpty, "Still inside the grace window")

        // ...and returns before the grace window expires.
        let resumed = tracker.apply(presence(playing: ["THE FINALS"]), now: base.addingTimeInterval(720))
        XCTAssertTrue(resumed.isEmpty, "Resuming must not emit a second start")
        XCTAssertTrue(tracker.tick(now: base.addingTimeInterval(1_200)).isEmpty)
        XCTAssertEqual(tracker.activeSessionCount, 1)
    }

    func testSessionEndsOnceTheGraceWindowElapses() {
        var tracker = GamePresenceSessionTracker(
            configuration: GameSessionTrackerConfiguration(absenceGrace: 180, minimumSessionDuration: 300)
        )
        _ = tracker.apply(presence(playing: ["THE FINALS"]), now: base)

        let stoppedAt = base.addingTimeInterval(3_600)
        _ = tracker.apply(presence(playing: []), now: stoppedAt)

        let events = tracker.tick(now: stoppedAt.addingTimeInterval(181))
        guard case let .ended(session)? = events.first else {
            return XCTFail("Expected a session end")
        }
        // Duration reflects when play actually stopped, not when the grace
        // window expired.
        XCTAssertEqual(session.endedAt, stoppedAt)
        XCTAssertEqual(session.duration, 3_600)
        XCTAssertEqual(tracker.activeSessionCount, 0)
    }

    func testSessionsShorterThanTheMinimumAreDroppedSilently() {
        var tracker = GamePresenceSessionTracker(
            configuration: GameSessionTrackerConfiguration(absenceGrace: 60, minimumSessionDuration: 300)
        )
        _ = tracker.apply(presence(playing: ["THE FINALS"]), now: base)
        _ = tracker.apply(presence(playing: []), now: base.addingTimeInterval(120))

        XCTAssertTrue(tracker.tick(now: base.addingTimeInterval(200)).isEmpty)
        XCTAssertEqual(tracker.activeSessionCount, 0, "Session is discarded, not left dangling")
    }

    func testGoingOfflineEndsTheSessionEvenWithStaleActivities() {
        var tracker = GamePresenceSessionTracker(
            configuration: GameSessionTrackerConfiguration(absenceGrace: 60, minimumSessionDuration: 60)
        )
        _ = tracker.apply(presence(playing: ["THE FINALS"]), now: base)

        // Discord can send offline while still echoing the activity list.
        let offline = presence(playing: ["THE FINALS"], status: "offline")
        _ = tracker.apply(offline, now: base.addingTimeInterval(900))

        let events = tracker.tick(now: base.addingTimeInterval(1_000))
        guard case .ended? = events.first else {
            return XCTFail("Offline must close the session")
        }
    }

    func testDiscordReportedStartTimeIsPreferredOverFirstSighting() {
        // Joining a guild mid-game should not truncate the session length.
        var tracker = GamePresenceSessionTracker()
        let realStart = base.addingTimeInterval(-1_800)
        let events = tracker.apply(
            presence(playing: ["THE FINALS"], startedAt: realStart),
            now: base
        )

        guard case let .started(session)? = events.first else {
            return XCTFail("Expected a session start")
        }
        XCTAssertEqual(session.startedAt, realStart)
    }

    func testFutureReportedStartTimeIsRejected() {
        var tracker = GamePresenceSessionTracker()
        let events = tracker.apply(
            presence(playing: ["THE FINALS"], startedAt: base.addingTimeInterval(600)),
            now: base
        )
        guard case let .started(session)? = events.first else {
            return XCTFail("Expected a session start")
        }
        XCTAssertEqual(session.startedAt, base, "A start in the future falls back to now")
    }

    func testTwoGamesTrackSeparately() {
        var tracker = GamePresenceSessionTracker()
        _ = tracker.apply(presence(playing: ["THE FINALS", "Call of Duty"]), now: base)
        XCTAssertEqual(tracker.activeSessionCount, 2)

        // Quitting one leaves the other running.
        _ = tracker.apply(presence(playing: ["Call of Duty"]), now: base.addingTimeInterval(1_800))
        _ = tracker.tick(now: base.addingTimeInterval(2_100))
        XCTAssertEqual(tracker.activeGames(for: "user-1"), ["Call of Duty"])
    }
}

final class GameSessionSummaryTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func round(startedAt: Date, kills: Int, deaths: Int, damage: Double, mode: String) throws -> FinalsIDPlayedRound {
        let iso = ISO8601DateFormatter().string(from: startedAt)
        let json = """
        {"matchId":"m","mode":"\(mode)","gameMode":"TeamDeathmatch","startedAt":"\(iso)",
         "endedAt":"\(iso)","roundCount":1,"kills":\(kills),"deaths":\(deaths),"damage":\(damage),
         "rounds":[{"roundId":"r","matchId":"m","roundWon":true}]}
        """
        return try JSONDecoder().decode(FinalsIDPlayedRound.self, from: Data(json.utf8))
    }

    func testTotalsOnlyCountMatchesInsideTheSessionWindow() throws {
        let session = GameSession(
            userID: "u", guildID: "g", gameName: "THE FINALS",
            startedAt: base, endedAt: base.addingTimeInterval(3_600)
        )
        let inside = try round(startedAt: base.addingTimeInterval(600), kills: 14, deaths: 7, damage: 2984.6, mode: "casual")
        let alsoInside = try round(startedAt: base.addingTimeInterval(2_400), kills: 6, deaths: 3, damage: 900, mode: "ranked")
        let longBefore = try round(startedAt: base.addingTimeInterval(-86_400), kills: 99, deaths: 0, damage: 9_999, mode: "casual")

        let totals = GameSessionSummaryBuilder.totals(
            for: session,
            rounds: [inside, alsoInside, longBefore]
        )

        XCTAssertEqual(totals.matches, 2, "Yesterday's match must not be counted")
        XCTAssertEqual(totals.kills, 20)
        XCTAssertEqual(totals.deaths, 10)
        XCTAssertEqual(totals.rankedMatches, 1)
        XCTAssertEqual(totals.wins, 2)
        XCTAssertEqual(totals.killDeathRatio ?? 0, 2.0, accuracy: 0.001)
    }

    func testPresenceOnlySummaryReportsDurationWithoutInventingStats() throws {
        let session = GameSession(
            userID: "u", guildID: "g", gameName: "Call of Duty",
            startedAt: base, endedAt: base.addingTimeInterval(5_400)
        )
        let embed = GameSessionSummaryBuilder.embed(
            session: session,
            displayName: "Tyr",
            game: nil,
            providerName: nil,
            totals: nil
        )

        XCTAssertEqual(embed["title"] as? String, "Call of Duty · Session Complete")
        let fields = try XCTUnwrap(embed["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.count, 1, "Only the session duration is known")
        XCTAssertEqual(fields.first?["value"] as? String, "1h 30m")
        let footer = try XCTUnwrap(embed["footer"] as? [String: Any])
        XCTAssertEqual(footer["text"] as? String, "Detected from Discord presence")
    }

    func testDurationFormatting() {
        XCTAssertEqual(GameSessionSummaryBuilder.durationText(45), "1m")
        XCTAssertEqual(GameSessionSummaryBuilder.durationText(1_800), "30m")
        XCTAssertEqual(GameSessionSummaryBuilder.durationText(3_600), "1h")
        XCTAssertEqual(GameSessionSummaryBuilder.durationText(5_400), "1h 30m")
    }
}
