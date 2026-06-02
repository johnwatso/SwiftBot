import XCTest
@testable import SwiftBot

final class GatewayEventPresentationTests: XCTestCase {
    func testDisplayNameUsesFriendlyGatewayLabels() {
        XCTAssertEqual(GatewayEventPresentation.displayName(for: "GUILD_CREATE"), "Server Available")
        XCTAssertEqual(GatewayEventPresentation.displayName(for: "MESSAGE_CREATE"), "Message Received")
        XCTAssertEqual(GatewayEventPresentation.displayName(for: "VOICE_STATE_UPDATE"), "Voice State Changed")
        XCTAssertEqual(GatewayEventPresentation.displayName(for: "READY"), "Connected")
    }

    func testUnknownEventNamesAreTitleCased() {
        XCTAssertEqual(GatewayEventPresentation.displayName(for: "AUTO_MODERATION_ACTION_EXECUTION"), "Auto Moderation Action Execution")
    }

    func testProtocolNamesAreReplacedInUserVisibleText() {
        let text = "Received GUILD_CREATE after VOICE_STATE_UPDATE"
        XCTAssertEqual(
            GatewayEventPresentation.replaceProtocolNames(in: text),
            "Received Server Available after Voice State Changed"
        )
    }
}
