import XCTest
@testable import SwiftBot

final class PatchySwiftMinerCampaignRouterTests: XCTestCase {
    func testDecodesCampaignAnnouncementAndBuildsLimitedArtworkEmbeds() throws {
        let body = """
        {
          "eventId": "evt_campaign_1",
          "eventType": "swiftminer.campaignAnnounced",
          "data": {
            "campaignId": "campaign-1",
            "campaignName": "Finals Launch Drops",
            "gameId": "game-finals",
            "gameName": "The Finals",
            "status": "active",
            "startsAt": "2026-06-18T01:00:00Z",
            "endsAt": "2026-06-20T01:00:00Z",
            "dropCount": 4,
            "gameArtworkURL": "https://cdn.example.com/finals.png",
            "dropArtwork": [
              { "dropId": "drop-1", "name": "One", "imageURL": "https://cdn.example.com/one.png" },
              { "dropId": "drop-2", "name": "Two", "imageURL": "https://cdn.example.com/two.png" },
              { "dropId": "drop-3", "name": "Three", "imageURL": "https://cdn.example.com/three.png" },
              { "dropId": "drop-4", "name": "Four", "imageURL": "https://cdn.example.com/four.png" }
            ]
          }
        }
        """.data(using: .utf8)!

        let announcement = try PatchySwiftMinerCampaignRouter.decodeAnnouncement(from: body)
        let matchingTarget = PatchySourceTarget(
            source: .swiftMiner,
            swiftMinerGameName: "the finals",
            embedColorHex: "#00A7D8",
            channelId: "channel-1"
        )
        let otherTarget = PatchySourceTarget(
            source: .swiftMiner,
            swiftMinerGameName: "Valorant",
            channelId: "channel-1"
        )

        XCTAssertTrue(PatchySwiftMinerCampaignRouter.target(matchingTarget, matches: announcement))
        XCTAssertFalse(PatchySwiftMinerCampaignRouter.target(otherTarget, matches: announcement))
        XCTAssertEqual(announcement.dropArtwork.count, 3)

        let embedJSON = PatchySwiftMinerCampaignRouter.embedJSON(for: announcement, target: matchingTarget)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(embedJSON.utf8)) as? [String: Any])
        let embeds = try XCTUnwrap(payload["embeds"] as? [[String: Any]])

        XCTAssertEqual(embeds.count, 4)
        XCTAssertEqual(embeds[0]["title"] as? String, "New Drops campaign")
        XCTAssertEqual((embeds[0]["image"] as? [String: Any])?["url"] as? String, "https://cdn.example.com/finals.png")
        XCTAssertEqual(embeds[1]["title"] as? String, "One")
        XCTAssertEqual(embeds[3]["title"] as? String, "Three")
    }
}
