import XCTest
@testable import SwiftBot

final class AdminWebCopyTests: XCTestCase {
    func testSweepWebCreationCopyIsNativeFirst() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)

        XCTAssertTrue(html.contains("Create and edit Sweep rules in the macOS app."))
        XCTAssertFalse(html.contains("Web parity will follow"))
    }

    func testNativeSidebarViewsAreWiredIntoAdminWebUI() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)
        let webViewsBySidebarItem: [SidebarItem: String] = [
            .overview: "overview",
            .patchy: "patchy",
            .welcomeFlow: "welcome",
            .automations: "automations",
            .moderation: "moderation",
            .commands: "commands",
            .activity: "activity",
            .wikiBridge: "wikibridge",
            .appleIntelligence: "aibots",
            .voice: "announcer",
            .recordings: "recordings",
            .analytics: "analytics",
            .swiftMesh: "swiftmesh",
            .sweep: "sweep"
        ]

        for item in SidebarItem.allCases {
            let webView = try XCTUnwrap(webViewsBySidebarItem[item], "Missing WebUI mapping for \(item.rawValue)")
            XCTAssertTrue(html.contains(#"data-view="\#(webView)""#), "\(item.rawValue) is missing from WebUI navigation")
            XCTAssertTrue(html.contains(#"id="\#(webView)View""#), "\(item.rawValue) is missing a WebUI view section")
            XCTAssertTrue(html.contains(#"view === '\#(webView)'"#), "\(item.rawValue) is missing a WebUI selection branch")
        }
    }

    func testAdminWebUIHasNoStaleLegacyViewReferences() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)

        XCTAssertFalse(html.contains("logs.classList"), "Use activityView/logsPanels instead of the removed logs view variable")
        XCTAssertFalse(html.contains("actions.classList"), "Use automationsView instead of the removed actions view variable")
    }

    func testAuthScreenExplainsMissingDiscordOAuthButton() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)

        XCTAssertTrue(html.contains(#"id="discordAuthButton""#))
        XCTAssertTrue(html.contains(#"id="authSetupHint""#))
        XCTAssertTrue(html.contains("Discord sign-in is not configured yet."))
        XCTAssertTrue(html.contains("setupHint.style.display = authOptions.discordEnabled ? 'none' : '';"))
    }
}
