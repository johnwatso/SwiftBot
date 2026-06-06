import XCTest
@testable import SwiftBot

final class SwiftMinerEditGamesModalTests: XCTestCase {

    func testParseTrimsBlankLinesAndDeduplicates() {
        let input = "  Marvel Rivals \n\nDelta Force\nmarvel rivals\n   \nFortnite\n"
        let games = SwiftMinerDMEmbedBuilders.parseEditGamesInput(input)
        XCTAssertEqual(games, ["Marvel Rivals", "Delta Force", "Fortnite"])
    }

    func testParseEmptyInputReturnsEmpty() {
        XCTAssertTrue(SwiftMinerDMEmbedBuilders.parseEditGamesInput("\n  \n").isEmpty)
    }

    func testModalIsPrefilledWithCurrentGames() {
        let modal = SwiftMinerDMEmbedBuilders.buildEditGamesModal(currentGames: ["Marvel Rivals", "Delta Force"])
        XCTAssertEqual(modal["type"] as? Int, 9)

        let data = modal["data"] as? [String: Any]
        XCTAssertEqual(data?["custom_id"] as? String, SwiftMinerDMEmbedBuilders.editGamesModalCustomID)

        let row = (data?["components"] as? [[String: Any]])?.first
        let input = (row?["components"] as? [[String: Any]])?.first
        XCTAssertEqual(input?["type"] as? Int, 4)
        XCTAssertEqual(input?["custom_id"] as? String, SwiftMinerDMEmbedBuilders.editGamesInputID)
        XCTAssertEqual(input?["value"] as? String, "Marvel Rivals\nDelta Force")
    }

    func testStandardActionsIncludeEditGamesButton() {
        let rows = SwiftMinerDMEmbedBuilders.buildStandardActionComponents()
        let buttons = rows.flatMap { ($0["components"] as? [[String: Any]]) ?? [] }
        let customIDs = buttons.compactMap { $0["custom_id"] as? String }
        XCTAssertTrue(customIDs.contains(SwiftMinerDMEmbedBuilders.editGamesCustomID))
    }
}
