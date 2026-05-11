import XCTest
@testable import SwiftBot

final class SwiftMinerDMStateTests: XCTestCase {

    // MARK: - Settings Codable Round-Trip

    func testSwiftMinerSettingsRoundTripsNewStateFields() throws {
        var settings = SwiftMinerSettings()
        settings.enabled = true
        settings.baseURL = "http://localhost:9999"
        settings.welcomeMessageSentUserIds = ["123456789012345678", "987654321098765432"]
        settings.completedInitialDMFlowUserIds = ["123456789012345678"]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SwiftMinerSettings.self, from: data)

        XCTAssertEqual(decoded.enabled, true)
        XCTAssertEqual(decoded.baseURL, "http://localhost:9999")
        XCTAssertEqual(decoded.welcomeMessageSentUserIds, ["123456789012345678", "987654321098765432"])
        XCTAssertEqual(decoded.completedInitialDMFlowUserIds, ["123456789012345678"])
    }

    func testSwiftMinerSettingsDefaultsAreEmpty() {
        let settings = SwiftMinerSettings()
        XCTAssertTrue(settings.welcomeMessageSentUserIds.isEmpty)
        XCTAssertTrue(settings.completedInitialDMFlowUserIds.isEmpty)
    }

    func testSwiftMinerSettingsApplyPairingPreservesStateFields() {
        var settings = SwiftMinerSettings()
        settings.welcomeMessageSentUserIds = ["123"]
        settings.completedInitialDMFlowUserIds = ["123"]

        let bundle = SwiftMinerPairingBundle(
            endpoint: "http://localhost:8080",
            swiftMinerEndpoint: "http://localhost:8080",
            swiftBotEndpoint: "http://localhost:38888",
            apiKey: String(repeating: "a", count: 32),
            hmacSecret: String(repeating: "b", count: 32),
            webhookHint: "test"
        )
        settings.apply(pairingBundle: bundle)

        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.welcomeMessageSentUserIds, ["123"])
        XCTAssertEqual(settings.completedInitialDMFlowUserIds, ["123"])
    }

    // MARK: - DM Request Codable

    func testSwiftMinerDMRequestRoundTrip() throws {
        let request = SwiftMinerDMRequest(
            messageType: .setup,
            debug: true,
            twitchUsername: "tester",
            priorityGames: ["Game 1"],
            activationCode: "CODE-1234",
            activationExpiresInMinutes: 15,
            affectedGame: "A Game",
            campaignName: "A Campaign",
            milestoneTitle: "Halfway",
            recoveryReason: "Expired"
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["message_type"] as? String, "setup")
        XCTAssertEqual(json?["debug"] as? Bool, true)
        XCTAssertEqual(json?["twitch_username"] as? String, "tester")
        XCTAssertEqual(json?["priority_games"] as? [String], ["Game 1"])
        XCTAssertEqual(json?["activation_code"] as? String, "CODE-1234")
        XCTAssertEqual(json?["activation_expires_in_minutes"] as? Int, 15)
    }

    func testSwiftMinerDMRequestDecodesFromSwiftMinerJSON() throws {
        let json = """
        {
            "message_type": "drop_claimed",
            "debug": false,
            "twitch_username": "streamer_x",
            "priority_games": ["A", "B"],
            "campaign_name": "Holiday Drops"
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(SwiftMinerDMRequest.self, from: json)
        XCTAssertEqual(request.messageType, .dropClaimed)
        XCTAssertFalse(request.debug)
        XCTAssertEqual(request.twitchUsername, "streamer_x")
        XCTAssertEqual(request.priorityGames, ["A", "B"])
        XCTAssertEqual(request.campaignName, "Holiday Drops")
    }

    func testSwiftMinerDMRequestDebugDefaultsToFalse() throws {
        let json = """
        {
            "message_type": "welcome"
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(SwiftMinerDMRequest.self, from: json)
        XCTAssertFalse(request.debug)
    }
}
