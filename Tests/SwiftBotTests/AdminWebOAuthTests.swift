import XCTest
@testable import SwiftBot

final class AdminWebOAuthTests: XCTestCase {
    func testRedirectURLUsesLocalhostForLocalAdminWebOAuth() async {
        let app = await AppModel()

        await MainActor.run {
            app.settings.adminWebUI.publicBaseURL = ""
            app.settings.adminWebUI.internetAccessEnabled = false
            app.settings.adminWebUI.redirectPath = "/auth/discord/callback"
        }

        let redirectURL = await app.adminWebDiscordRedirectURL()

        XCTAssertEqual(redirectURL, "http://localhost:38888/auth/discord/callback")
    }

    func testRedirectURLComposesProxySubpath() {
        let redirectURL = adminWebOAuthRedirectURL(
            baseURL: "https://swiftbot.example.com/admin",
            redirectPath: "auth/discord/callback"
        )

        XCTAssertEqual(redirectURL, "https://swiftbot.example.com/admin/auth/discord/callback")
    }

    func testRedirectURLDefaultsMissingSchemeToHTTPS() {
        let redirectURL = adminWebOAuthRedirectURL(
            baseURL: "swiftbot.example.com",
            redirectPath: "/auth/discord/callback"
        )

        XCTAssertEqual(redirectURL, "https://swiftbot.example.com/auth/discord/callback")
    }
}
