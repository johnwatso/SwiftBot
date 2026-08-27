import XCTest
@testable import SwiftBot

/// Exercises the Game Tracker machinery through a provider that is *not*
/// finals.id. The app ships only finals.id today, so this stub is the only
/// second implementation the abstraction has — without it, "provider-neutral"
/// would be an untested claim.
private struct StubRankProvider: GameRankProvider {
    let descriptor: GameProviderDescriptor
    let snapshot: GameRankSnapshot
    /// Records how the request was authorized so we can assert the client never
    /// has to know the auth style itself.
    final class Recorder: @unchecked Sendable {
        var authorizedRequest: URLRequest?
    }
    let recorder: Recorder

    func fetchRankSnapshot(
        for target: GameTrackedPlayer,
        connection: GameProviderConnection
    ) async throws -> GameRankSnapshot {
        var request = URLRequest(url: URL(string: "https://stub.test/rank")!)
        connection.authorize(&request)
        recorder.authorizedRequest = request
        return snapshot
    }
}

final class GameProviderAbstractionTests: XCTestCase {

    private func makeDescriptor(
        capabilities: Set<GameTrackingCapability> = [.rankedScore],
        auth: GameProviderAuth = .header(name: "TRN-Api-Key")
    ) -> GameProviderDescriptor {
        GameProviderDescriptor(
            id: .finalsID,
            supportedGames: [.theFinals],
            capabilities: capabilities,
            auth: auth,
            defaultBaseURL: "https://stub.test"
        )
    }

    func testNonBearerProviderIsDrivenEntirelyThroughTheProtocol() async throws {
        let descriptor = makeDescriptor()
        let snapshot = GameRankSnapshot(
            game: .theFinals,
            provider: .finalsID,
            playerID: "p-1",
            displayName: "Tyr",
            season: "s11",
            rankName: "Platinum 2",
            score: 31_520,
            updatedAt: nil
        )
        let recorder = StubRankProvider.Recorder()
        let provider = StubRankProvider(descriptor: descriptor, snapshot: snapshot, recorder: recorder)

        var settings = GameProviderConnectionSettings()
        settings.token = "trn-key"
        settings.rankEndpointTemplate = "/v1/players/{playerID}/rank"

        var target = GameTrackedPlayer(displayName: "Tyr")
        target.playerID = "p-1"
        target.destinationChannelID = "channel-1"

        let result = try await provider.fetchRankSnapshot(
            for: target,
            connection: settings.connection(for: descriptor)
        )

        XCTAssertEqual(result.score, 31_520)
        // Auth applied by the connection, not by provider-specific client code.
        XCTAssertEqual(recorder.authorizedRequest?.value(forHTTPHeaderField: "TRN-Api-Key"), "trn-key")
        XCTAssertNil(recorder.authorizedRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testConnectionFallsBackToTheDescriptorDefaultBaseURL() {
        let descriptor = makeDescriptor()
        let settings = GameProviderConnectionSettings()

        XCTAssertEqual(settings.resolvedBaseURL(for: descriptor), "https://stub.test")
        XCTAssertEqual(settings.connection(for: descriptor).baseURL, "https://stub.test")
    }

    func testRegistryRefusesAProviderThatCannotReportRankedScore() async {
        // Mirrors a presence-only game such as Call of Duty being asked for SR.
        let descriptor = makeDescriptor(capabilities: [.latestSession])
        XCTAssertFalse(descriptor.capabilities.contains(.rankedScore))

        let error = GameProviderRegistryError.capabilityUnavailable(.finalsID, .rankedScore)
        XCTAssertEqual(
            error.errorDescription,
            "finals.id does not provide rankedScore data."
        )
    }

    func testEvaluatorAndEmbedStayFreeOfProviderSpecificCopy() throws {
        var target = GameTrackedPlayer(displayName: "Tyr")
        target.playerID = "p-1"
        target.destinationChannelID = "channel-1"

        let previous = GameRankBaseline(
            snapshot: GameRankSnapshot(
                game: .theFinals, provider: .finalsID, playerID: "p-1", displayName: "Tyr",
                season: "s11", rankName: "Platinum 3", score: 31_000, updatedAt: nil
            ),
            displayName: "Tyr",
            recordedAt: Date(timeIntervalSince1970: 0)
        )
        let current = GameRankSnapshot(
            game: .theFinals, provider: .finalsID, playerID: "p-1", displayName: "Tyr",
            season: "s11", rankName: "Platinum 2", score: 31_520, updatedAt: nil
        )

        guard case let .changed(change) = GameRankEvaluator.evaluate(
            target: target, current: current, previous: previous
        ) else {
            return XCTFail("Expected a ranked-score change")
        }

        let embed = GameTrackingNotificationBuilder.embed(changes: [change], checkedAt: Date())
        let title = try XCTUnwrap(embed["title"] as? String)
        let footer = try XCTUnwrap(embed["footer"] as? [String: Any])

        // Title and footer are derived from the game/provider, never literals.
        XCTAssertEqual(title, "\(GameID.theFinals.displayName) · Daily Ranked Update")
        XCTAssertEqual(footer["text"] as? String, "Data provided by \(GameProviderID.finalsID.displayName)")

        // The score unit comes from the game, so a second title reads correctly.
        let fields = try XCTUnwrap(embed["fields"] as? [[String: Any]])
        let value = try XCTUnwrap(fields.first?["value"] as? String)
        XCTAssertTrue(value.contains(GameID.theFinals.scoreUnit), "Embed should use the game's score unit")
    }
}
