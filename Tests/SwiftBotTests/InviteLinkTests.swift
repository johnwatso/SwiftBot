import XCTest
@testable import SwiftBot

final class InviteLinkTests: XCTestCase {
    func testGenerateInviteURL() async {
        // Use a dummy service instance - we just need the function
        let service = DiscordService()
        let clientId = "123456789"
        
        // Test with slash commands
        if let urlWithSlash = await service.generateInviteURL(clientId: clientId, includeSlashCommands: true) {
            XCTAssertTrue(urlWithSlash.contains("https://discord.com/oauth2/authorize"), "Missing /api/ prefix")
            XCTAssertTrue(urlWithSlash.contains("client_id=123456789"), "Missing client_id")
            XCTAssertTrue(urlWithSlash.contains("permissions=274877991936"), "Missing permissions")
            XCTAssertTrue(urlWithSlash.contains("scope=bot+applications.commands"), "Missing bot+applications.commands scope with + separator")
        } else {
            XCTFail("URL generation failed for slash commands")
        }
        
        // Test without slash commands
        if let urlWithoutSlash = await service.generateInviteURL(clientId: clientId, includeSlashCommands: false) {
            XCTAssertTrue(urlWithoutSlash.contains("https://discord.com/oauth2/authorize"), "Missing /api/ prefix")
            XCTAssertTrue(urlWithoutSlash.contains("client_id=123456789"), "Missing client_id")
            XCTAssertTrue(urlWithoutSlash.contains("permissions=274877991936"), "Missing permissions")
            XCTAssertTrue(urlWithoutSlash.contains("scope=bot"), "Missing bot scope")
            XCTAssertFalse(urlWithoutSlash.contains("applications.commands"), "Should NOT contain applications.commands scope")
        } else {
            XCTFail("URL generation failed for no slash commands")
        }
    }
}
