import XCTest
@testable import SwiftBot

final class LegacySettingsMigrationTests: XCTestCase {
    func testRemovedRemoteControlModeLoadsAsStandalone() throws {
        // Settings saved while Remote Control mode existed must still load:
        // the mode falls back to a standalone bot and the old connection is dropped.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BotSettings())) as! [String: Any]
        json["launchMode"] = "remoteControl"
        json["remoteMode"] = ["primaryNodeAddress": "https://bot.example.com", "accessToken": "old-session"]
        let data = try JSONSerialization.data(withJSONObject: json)

        let loaded = try JSONDecoder().decode(BotSettings.self, from: data)
        XCTAssertEqual(loaded.launchMode, .standaloneBot)

        let saved = String(decoding: try JSONEncoder().encode(loaded), as: UTF8.self)
        XCTAssertFalse(saved.contains("old-session"), "The old Remote access token must not be written back")
        XCTAssertFalse(saved.contains("remoteMode"))
    }

    func testCurrentLaunchModesStillRoundTrip() throws {
        var settings = BotSettings()
        settings.launchMode = .swiftMeshClusterNode
        let loaded = try JSONDecoder().decode(BotSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(loaded.launchMode, .swiftMeshClusterNode)
    }
}
