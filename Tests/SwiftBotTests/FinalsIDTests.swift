import Foundation
import XCTest
@testable import SwiftBot

final class FinalsIDTests: XCTestCase {
    func testRankDecoderAcceptsExplicitNestedRankedScore() throws {
        let data = Data(
            """
            {
              "data": {
                "profile": {
                  "playerId": "player-1",
                  "displayName": "Tyr#1060",
                  "season": "s11",
                  "ranked": {
                    "rankedScore": 31520,
                    "tier": "Platinum 2",
                    "updatedAt": "2026-08-27T09:00:00Z"
                  }
                }
              }
            }
            """.utf8
        )

        let snapshot = try FinalsIDRankResponseDecoder.decode(
            data: data,
            game: .theFinals,
            provider: .finalsID,
            fallbackPlayerID: "fallback",
            fallbackDisplayName: "Fallback"
        )

        XCTAssertEqual(snapshot.playerID, "player-1")
        XCTAssertEqual(snapshot.displayName, "Tyr#1060")
        XCTAssertEqual(snapshot.season, "s11")
        XCTAssertEqual(snapshot.rankName, "Platinum 2")
        XCTAssertEqual(snapshot.score, 31_520)
        XCTAssertNotNil(snapshot.updatedAt)
    }

    func testRankDecoderNeverTreatsCombatScoreAsRankedScore() {
        let data = Data(
            """
            {
              "season": "s11",
              "results": [{
                "scorecard": { "combat-score": 2029.318 },
                "score": 2029
              }]
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try FinalsIDRankResponseDecoder.decode(
                data: data,
                game: .theFinals,
                provider: .finalsID,
                fallbackPlayerID: "player-1",
                fallbackDisplayName: "Tyr"
            )
        ) { error in
            XCTAssertEqual(error as? FinalsIDAPIError, .missingRankedScore)
        }
    }

    /// Fixture mirrors the field names, types, and nesting of a real
    /// "Latest Played Round Result" response from finals.id. An earlier model
    /// read this payload's `mode` as `node`, which decoded to nil against live
    /// data while still passing a fixture written to match the model — so this
    /// test asserts on the real key names specifically.
    func testRealLatestPlayedRoundPayloadDecodes() throws {
        let data = Data(
            """
            {
              "season": "s11",
              "count": 1,
              "results": [{
                "matchId": "da7kvaianh600g6b2ni0",
                "mode": "casual",
                "gameMode": "TeamDeathmatch",
                "startedAt": "2026-08-26T20:44:03Z",
                "endedAt": "2026-08-26T20:57:48Z",
                "roundCount": 1,
                "kills": 14,
                "deaths": 7,
                "damage": 2984.6462,
                "rounds": [{
                  "roundId": "da7kvaianh600g6b2ni0",
                  "matchId": "da7kvaianh600g6b2ni0",
                  "map": "SYS$HORIZON",
                  "twists": [{ "name": "Standard Issue", "slug": "standard-issue" }],
                  "gameMode": "TeamDeathmatch",
                  "startedAt": "2026-08-26T20:44:03Z",
                  "endedAt": "2026-08-26T20:57:48Z",
                  "squadName": "The Shock & Awe",
                  "placedAt": 1,
                  "kills": 14,
                  "deaths": 7,
                  "dbnos": 0,
                  "damage": 2984.6462,
                  "respawns": 7,
                  "respawnsDone": 0,
                  "revivesDone": 0,
                  "roundWon": true,
                  "partyMembers": { "leader": "Tyr#1000", "members": [{ "name": "Tyr#1000" }] }
                }],
                "items": [
                  { "kind": "gadget", "name": "DOME", "slug": "dome", "xp": 863 },
                  { "damage": 55, "id": "-1023601953", "kind": "gadget", "name": "LOCKBOLT", "slug": "lockbolt", "xp": 890 },
                  { "damage": 672.06, "id": "104254149", "kills": 2, "kind": "gadget", "name": "RPG", "slug": "rpg", "xp": 1172 },
                  { "id": "921868764", "xp": 20000 }
                ],
                "scorecard": {
                  "assists": 10,
                  "combat-score": 2295.318,
                  "elimination-streak": 6,
                  "eliminations": 14,
                  "kill-death-ratio": 2,
                  "support": 466.005
                },
                "roster": [{ "name": "player#0001" }, { "name": "player#0001" }]
              }],
              "nextCursor": "NjAjNi0wOC0yNlQyMDo6NDowMywwMDowMHxkYTdrdmFpYW5oNjAwZzViMmE2MA"
            }
            """.utf8
        )

        let result = try JSONDecoder().decode(FinalsIDLatestRoundResponse.self, from: data)
        let round = try XCTUnwrap(result.results.first)

        XCTAssertEqual(result.season, "s11")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(round.matchID, "da7kvaianh600g6b2ni0")

        // The queue type is `mode`, not `node`.
        XCTAssertEqual(round.mode, "casual")
        XCTAssertFalse(round.isRanked)

        XCTAssertEqual(round.kills, 14)
        XCTAssertEqual(round.deaths, 7)
        XCTAssertEqual(round.damage, 2984.6462)
        XCTAssertEqual(round.scorecard?.combatScore, 2295.318)
        XCTAssertEqual(round.scorecard?.killDeathRatio, 2)
        XCTAssertEqual(round.items.count, 4)
        XCTAssertEqual(round.roster.count, 2)

        let detail = try XCTUnwrap(round.rounds.first)
        XCTAssertEqual(detail.map, "SYS$HORIZON")
        XCTAssertEqual(detail.squadName, "The Shock & Awe")
        XCTAssertEqual(detail.dbnos, 0)
        XCTAssertEqual(detail.roundWon, true)
        XCTAssertEqual(detail.twists.first?.slug, "standard-issue")

        // partyMembers arrived as a single object here; an array must also work.
        XCTAssertEqual(detail.partyMembers.first?.leader, "Tyr#1000")
        XCTAssertEqual(detail.partyMembers.first?.members.first?.name, "Tyr#1000")
        XCTAssertNotNil(result.nextCursor)
    }

    func testPartyMembersDecodesFromEitherObjectOrArray() throws {
        let asArray = Data(#"[{"leader":"Tyr#1000","members":[{"name":"Tyr#1000"}]}]"#.utf8)
        let asObject = Data(#"{"leader":"Tyr#1000","members":[{"name":"Tyr#1000"}]}"#.utf8)

        let fromArray = try JSONDecoder().decode(FinalsIDPartyMemberList.self, from: asArray)
        let fromObject = try JSONDecoder().decode(FinalsIDPartyMemberList.self, from: asObject)

        XCTAssertEqual(fromArray.entries.count, 1)
        XCTAssertEqual(fromObject.entries.count, 1)
        XCTAssertEqual(fromArray.entries, fromObject.entries)
    }

    func testRoundDecodesWhenOptionalCollectionsAreAbsent() throws {
        // A mode that omits items/roster/rounds must not fail the whole payload.
        let data = Data(#"""
        {"season":"s11","count":1,"results":[{"matchId":"m1","gameMode":"Ranked","startedAt":"a","endedAt":"b","roundCount":1,"kills":1,"deaths":0,"damage":10.5}]}
        """#.utf8)

        let result = try JSONDecoder().decode(FinalsIDLatestRoundResponse.self, from: data)
        let round = try XCTUnwrap(result.results.first)

        XCTAssertTrue(round.items.isEmpty)
        XCTAssertTrue(round.roster.isEmpty)
        XCTAssertTrue(round.rounds.isEmpty)
        XCTAssertNil(round.mode)
    }

    func testEvaluatorEstablishesAndChangesWithoutFalseSeasonReset() {
        let target = GameTrackedPlayer(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            game: .theFinals,
            provider: .finalsID,
            playerID: "player-1",
            displayName: "Tyr",
            destinationChannelID: "channel-1",
            isEnabled: true
        )
        let current = GameRankSnapshot(
            game: .theFinals,
            provider: .finalsID,
            playerID: "player-1",
            displayName: "Tyr#1060",
            season: "s11",
            rankName: "Platinum 2",
            score: 31_980,
            updatedAt: nil
        )

        XCTAssertEqual(
            GameRankEvaluator.evaluate(target: target, current: current, previous: nil),
            .establishBaseline
        )

        let previous = GameRankBaseline(
            snapshot: GameRankSnapshot(
                game: .theFinals,
                provider: .finalsID,
                playerID: "player-1",
                displayName: "Tyr#1060",
                season: "s11",
                rankName: "Platinum 2",
                score: 31_520,
                updatedAt: nil
            ),
            displayName: "Tyr",
            recordedAt: Date(timeIntervalSince1970: 1)
        )
        guard case .changed(let change) = GameRankEvaluator.evaluate(
            target: target,
            current: current,
            previous: previous
        ) else {
            return XCTFail("Expected an SR change")
        }
        XCTAssertEqual(change.delta, 460)
        XCTAssertEqual(change.game, .theFinals)
        XCTAssertEqual(change.provider, .finalsID)
        XCTAssertEqual(change.destinationChannelID, "channel-1")

        let nextSeason = GameRankSnapshot(
            game: .theFinals,
            provider: .finalsID,
            playerID: "player-1",
            displayName: "Tyr#1060",
            season: "s12",
            rankName: nil,
            score: 1_000,
            updatedAt: nil
        )
        XCTAssertEqual(
            GameRankEvaluator.evaluate(target: target, current: nextSeason, previous: previous),
            .seasonChanged
        )

        let differentProfile = GameRankSnapshot(
            game: .theFinals,
            provider: .finalsID,
            playerID: "player-2",
            displayName: "Max#1234",
            season: "s11",
            rankName: "Gold 1",
            score: 20_000,
            updatedAt: nil
        )
        XCTAssertEqual(
            GameRankEvaluator.evaluate(target: target, current: differentProfile, previous: previous),
            .establishBaseline,
            "Changing the provider identity must never create a cross-profile SR delta"
        )
    }

    func testDailyScheduleRunsAtNineAndOnlyOncePerLocalDay() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let beforeNine = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2026,
            month: 8,
            day: 27,
            hour: 8,
            minute: 30
        )))
        let nine = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2026,
            month: 8,
            day: 27,
            hour: 9
        )))

        XCTAssertEqual(
            GameTrackingDailySchedule.nextRun(
                after: beforeNine,
                lastAttemptAt: nil,
                hour: 9,
                minute: 0,
                timeZoneIdentifier: timeZone.identifier
            ),
            nine
        )

        let afterNine = nine.addingTimeInterval(60)
        XCTAssertEqual(
            GameTrackingDailySchedule.nextRun(
                after: afterNine,
                lastAttemptAt: nil,
                hour: 9,
                minute: 0,
                timeZoneIdentifier: timeZone.identifier
            ),
            afterNine,
            "A missed 9 AM check should catch up immediately"
        )

        let tomorrow = GameTrackingDailySchedule.nextRun(
            after: afterNine,
            lastAttemptAt: afterNine,
            hour: 9,
            minute: 0,
            timeZoneIdentifier: timeZone.identifier
        )
        XCTAssertEqual(calendar.component(.day, from: tomorrow), 28)
        XCTAssertEqual(calendar.component(.hour, from: tomorrow), 9)
    }

    func testNotificationShowsSignedDeltaAndTotal() throws {
        let change = GameRankChange(
            targetID: UUID(),
            game: .theFinals,
            provider: .finalsID,
            destinationChannelID: "channel-1",
            playerID: "player-1",
            displayName: "Tyr",
            season: "s11",
            rankName: "Platinum 2",
            previousScore: 31_520,
            currentScore: 31_980
        )

        let embed = GameTrackingNotificationBuilder.embed(
            changes: [change],
            checkedAt: Date(timeIntervalSince1970: 1)
        )
        let fields = try XCTUnwrap(embed["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.first?["name"] as? String, "Tyr")
        XCTAssertTrue((fields.first?["value"] as? String)?.contains("+460 SR") == true)
        XCTAssertTrue((fields.first?["value"] as? String)?.contains("31,980 total") == true)
        XCTAssertEqual(embed["title"] as? String, "THE FINALS · Daily Ranked Update")
        XCTAssertEqual(
            (embed["footer"] as? [String: String])?["text"],
            "Data provided by finals.id"
        )
    }

    func testEnabledIsDerivedFromTheTwoBehaviourSwitches() {
        var tracking = GameTrackingSettings()
        XCTAssertFalse(tracking.enabled, "Nothing on means the service is off")

        tracking.dailyCheckEnabled = true
        XCTAssertTrue(tracking.enabled)

        tracking.dailyCheckEnabled = false
        tracking.sessionTrackingEnabled = true
        XCTAssertTrue(tracking.enabled, "Sessions alone keep the service running")

        tracking.sessionTrackingEnabled = false
        XCTAssertFalse(tracking.enabled)
    }

    func testLegacyEnabledFlagMigratesToDailyCheck() throws {
        // Installs predating the daily/session split stored one `enabled` flag
        // that meant "run the daily check".
        let legacy = Data(#"{"enabled":true,"checkHour":9,"checkMinute":0}"#.utf8)
        let decoded = try JSONDecoder().decode(GameTrackingSettings.self, from: legacy)

        XCTAssertTrue(decoded.dailyCheckEnabled)
        XCTAssertFalse(decoded.sessionTrackingEnabled)
        XCTAssertTrue(decoded.enabled)

        // The legacy key is not written back out.
        let reencoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(decoded)
        ) as? [String: Any]
        XCTAssertNil(reencoded?["enabled"])
        XCTAssertEqual(reencoded?["dailyCheckEnabled"] as? Bool, true)
    }

    func testSessionOnlyModeNeedsNoProviderConnection() {
        // Presence-only announcements have no provider behind them, so
        // readiness must not demand a rank endpoint or credential.
        var tracking = GameTrackingSettings()
        tracking.sessionTrackingEnabled = true
        var player = GameTrackedPlayer(displayName: "Tyr")
        player.playerID = "p-1"
        player.destinationChannelID = "channel-1"
        player.discordUserID = "discord-1"
        tracking.players = [player]

        XCTAssertNil(
            tracking.configurationIssue(connections: GameProviderConnections()),
            "An unconfigured provider must not block session-only mode"
        )
        // But a ranked poll still requires one.
        XCTAssertFalse(tracking.canPollRanks(connections: GameProviderConnections()))
    }

    func testSessionTrackingRequiresAtLeastOneLinkedProfile() {
        var tracking = GameTrackingSettings()
        tracking.sessionTrackingEnabled = true
        var player = GameTrackedPlayer(displayName: "Tyr")
        player.playerID = "p-1"
        player.destinationChannelID = "channel-1"
        tracking.players = [player] // no discordUserID

        XCTAssertEqual(
            tracking.configurationIssue(connections: GameProviderConnections()),
            "Add a Discord User ID to a profile to announce play sessions."
        )
    }

    func testGameTrackingRequiresCompleteEnabledProfilesAndProviderConnection() {
        var tracking = GameTrackingSettings()
        tracking.dailyCheckEnabled = true
        var connections = GameProviderConnections()

        XCTAssertEqual(
            tracking.configurationIssue(connections: connections),
            "Add or enable at least one player profile."
        )

        tracking.players = [GameTrackedPlayer(displayName: "Tyr")]
        XCTAssertEqual(
            tracking.configurationIssue(connections: connections),
            "Every enabled profile needs a provider player ID."
        )

        tracking.players[0].playerID = "player-1"
        XCTAssertEqual(
            tracking.configurationIssue(connections: connections),
            "Every enabled profile needs a Discord destination channel."
        )

        tracking.players[0].destinationChannelID = "channel-1"
        XCTAssertEqual(
            tracking.configurationIssue(connections: connections),
            "finals.id: API Token is required."
        )

        connections.setToken("token", for: .finalsID)
        XCTAssertEqual(
            tracking.configurationIssue(connections: connections),
            "finals.id: the rank endpoint contract has not been configured yet."
        )

        connections[.finalsID].rankEndpointTemplate = "/v1/players/{playerID}/rank"
        XCTAssertNil(tracking.configurationIssue(connections: connections))
    }

    func testProviderConnectionAppliesEachAuthStyleCorrectly() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/v1/players/abc/rank"))

        var bearerRequest = URLRequest(url: url)
        GameProviderConnection(baseURL: "https://example.test", token: "t0ken", auth: .bearer, rankEndpointTemplate: "")
            .authorize(&bearerRequest)
        XCTAssertEqual(bearerRequest.value(forHTTPHeaderField: "Authorization"), "Bearer t0ken")

        var headerRequest = URLRequest(url: url)
        GameProviderConnection(baseURL: "https://example.test", token: "t0ken", auth: .header(name: "TRN-Api-Key"), rankEndpointTemplate: "")
            .authorize(&headerRequest)
        XCTAssertEqual(headerRequest.value(forHTTPHeaderField: "TRN-Api-Key"), "t0ken")
        XCTAssertNil(headerRequest.value(forHTTPHeaderField: "Authorization"))

        var queryRequest = URLRequest(url: url)
        GameProviderConnection(baseURL: "https://example.test", token: "t0ken", auth: .query(name: "key"), rankEndpointTemplate: "")
            .authorize(&queryRequest)
        XCTAssertEqual(queryRequest.url?.query, "key=t0ken")
    }

    func testProviderWithoutRankedScoreCapabilityNeedsNoEndpointTemplate() {
        // A presence-only game such as Call of Duty has no rank API to point at,
        // so readiness must not demand an endpoint template from its provider.
        let presenceOnly = GameProviderDescriptor(
            id: .finalsID,
            supportedGames: [.theFinals],
            capabilities: [.latestSession],
            auth: .header(name: "X-Api-Key"),
            defaultBaseURL: "https://example.test"
        )
        var connection = GameProviderConnectionSettings()
        connection.token = "key"

        XCTAssertFalse(presenceOnly.requiresRankEndpointTemplate)
        XCTAssertNil(connection.configurationIssue(for: presenceOnly))
    }

    func testLegacyFinalsIDSettingsMigrateIntoKeyedProviderConnections() throws {
        let legacyJSON = """
        {"apiBaseURL":"https://api.finals.id","apiToken":"legacy","rankEndpointTemplate":"/v1/players/{playerID}/rank"}
        """
        let legacy = try JSONDecoder().decode(LegacyFinalsIDSettings.self, from: Data(legacyJSON.utf8))
        var connections = GameProviderConnections()
        connections[.finalsID] = legacy.migratedConnection

        XCTAssertEqual(connections[.finalsID].token, "legacy")
        XCTAssertEqual(connections[.finalsID].baseURL, "https://api.finals.id")
        XCTAssertEqual(connections[.finalsID].rankEndpointTemplate, "/v1/players/{playerID}/rank")

        // Round-trips through the on-disk shape without losing entries.
        let encoded = try JSONEncoder().encode(connections)
        let decoded = try JSONDecoder().decode(GameProviderConnections.self, from: encoded)
        XCTAssertEqual(decoded, connections)
    }

    func testFinalsIDProviderAdvertisesReusableCapabilities() async {
        let descriptor = FinalsIDAPIClient().descriptor

        XCTAssertEqual(descriptor.id, .finalsID)
        XCTAssertEqual(descriptor.supportedGames, [.theFinals])
        XCTAssertTrue(descriptor.capabilities.contains(.rankedScore))
        XCTAssertTrue(descriptor.capabilities.contains(.latestSession))
    }

    func testRuntimeStateDecodesWithoutHistoryForForwardCompatibility() throws {
        let data = Data("""
        {
          "baselinesByTargetID": {},
          "lastAttemptAt": null,
          "lastSuccessfulCheckAt": null
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let state = try decoder.decode(GameTrackingRuntimeState.self, from: data)

        XCTAssertTrue(state.history.isEmpty)
    }

    // MARK: - Endpoint construction

    /// Both request paths interpolate an operator-supplied player identifier.
    /// The rounds listing used to interpolate it raw, so an identifier with a
    /// space produced a URL that would not build and quietly reduced the
    /// session summary to duration alone; one containing `/` could reshape the
    /// path outright.
    func testLatestRoundEncodesThePlayerIDAsASinglePathSegment() async throws {
        let connection = GameProviderConnection(
            baseURL: "https://example.test",
            token: "t0ken",
            auth: .bearer,
            rankEndpointTemplate: "/v1/players/{playerID}/rank"
        )

        let requestedURL = try await capturedRequestURL {
            let client = FinalsIDAPIClient(session: $0)
            _ = try? await client.fetchLatestRound(playerID: "some one/../admin", connection: connection)
        }

        XCTAssertEqual(
            requestedURL.absoluteString,
            "https://example.test/v1/players/some%20one%2F..%2Fadmin/rounds"
        )
        XCTAssertEqual(requestedURL.host, "example.test")
    }

    func testRankEndpointEncodesThePlayerIDTheSameWay() async throws {
        let connection = GameProviderConnection(
            baseURL: "https://example.test",
            token: "t0ken",
            auth: .bearer,
            rankEndpointTemplate: "/v1/players/{playerID}/rank"
        )
        var player = GameTrackedPlayer()
        player.playerID = "some one/../admin"

        let requestedURL = try await capturedRequestURL {
            let client = FinalsIDAPIClient(session: $0)
            _ = try? await client.fetchRankSnapshot(for: player, connection: connection)
        }

        XCTAssertEqual(
            requestedURL.absoluteString,
            "https://example.test/v1/players/some%20one%2F..%2Fadmin/rank"
        )
    }

    /// Runs `perform` against a stubbed session and returns the URL it requested.
    private func capturedRequestURL(
        _ perform: (URLSession) async -> Void
    ) async throws -> URL {
        defer { FinalsIDMockURLProtocol.requestHandler = nil }
        let recorded = FinalsIDRecordedURL()
        FinalsIDMockURLProtocol.requestHandler = { request in
            recorded.value = request.url
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinalsIDMockURLProtocol.self]
        await perform(URLSession(configuration: configuration))

        return try XCTUnwrap(recorded.value, "The client never issued a request.")
    }
}

private final class FinalsIDRecordedURL: @unchecked Sendable {
    var value: URL?
}

private final class FinalsIDMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler for FinalsIDMockURLProtocol.")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
