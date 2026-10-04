import XCTest
@testable import SwiftBot

final class AdminWebGameTrackerUpdateTests: XCTestCase {
    private func player(
        game: String = GameID.theFinals.rawValue,
        provider: String = GameProviderID.finalsID.rawValue,
        playerID: String = "name#1234",
        channel: String = "123"
    ) -> AdminWebGameTrackerUpdate.PlayerInput {
        .init(
            id: nil, game: game, provider: provider, playerID: playerID, displayName: "",
            destinationChannelID: channel, isEnabled: true, discordUserID: ""
        )
    }

    func testValidPlayerPasses() {
        let update = AdminWebGameTrackerUpdate(action: .upsertPlayer, player: player())
        XCTAssertNoThrow(try update.validate())
    }

    func testPlayerNeedsIDChannelAndKnownProvider() {
        XCTAssertThrowsError(try AdminWebGameTrackerUpdate(action: .upsertPlayer, player: player(playerID: "  ")).validate())
        XCTAssertThrowsError(try AdminWebGameTrackerUpdate(action: .upsertPlayer, player: player(channel: "")).validate())
        XCTAssertThrowsError(try AdminWebGameTrackerUpdate(action: .upsertPlayer, player: player(provider: "nope")).validate())
        XCTAssertThrowsError(try AdminWebGameTrackerUpdate(action: .upsertPlayer, player: nil).validate())
    }

    func testPlayerActionsNeedAValidUUID() {
        XCTAssertThrowsError(try AdminWebGameTrackerUpdate(action: .deletePlayer, playerID: "not-a-uuid").validate())
        XCTAssertNoThrow(try AdminWebGameTrackerUpdate(action: .setPlayerEnabled, playerID: UUID().uuidString, enabled: false).validate())
    }

    func testCheckHourMustBeAnHourOfTheDay() {
        XCTAssertNoThrow(try AdminWebGameTrackerUpdate(action: .updateSettings, checkHour: 23).validate())
        XCTAssertThrowsError(try AdminWebGameTrackerUpdate(action: .updateSettings, checkHour: 24).validate())
    }
}
