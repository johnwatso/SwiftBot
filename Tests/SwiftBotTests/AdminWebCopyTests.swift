import XCTest
@testable import SwiftBot

final class AdminWebCopyTests: XCTestCase {
    func testSweepWebCreationAndEditingAreAvailable() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)

        XCTAssertTrue(html.contains("showModal('New Sweep Rule'"))
        XCTAssertTrue(html.contains("showModal('Edit Sweep Rule'"))
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

    func testAIBotsWebViewMirrorsNativeAppleIntelligenceSurface() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)

        XCTAssertTrue(html.contains("/api/aibots"), "AI Bots view must read the dedicated snapshot endpoint")
        XCTAssertTrue(html.contains("/api/aibots/memory/clear"), "Conversation memory must be clearable from the web")

        // Section parity with AppleIntelligenceView.
        for panel in ["Personality", "Reply Rules", "Conversation Memory", "Capabilities"] {
            XCTAssertTrue(html.contains("</i> \(panel)</div>"), "AI Bots view is missing the \(panel) panel")
        }

        // Reply rule copy is authored natively and must not drift on the web.
        for rule in ["Reply when mentioned", "Reply to DMs", "Allow DMs from anyone", "Ignore bot accounts"] {
            XCTAssertTrue(html.contains(rule), "AI Bots view is missing the '\(rule)' reply rule")
        }
        XCTAssertFalse(
            html.contains("Guild Mention Replies"),
            "Stale WebUI-only reply rule copy should match the native Reply Rules section"
        )
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
