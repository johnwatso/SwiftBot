import XCTest
@testable import SwiftBot

final class SwiftMinerDMRouterTests: XCTestCase {

    private let router = SwiftMinerDMRouter()

    // MARK: - Embed Kind Routing

    func testWelcomeRouteHasWelcomeSemantics() {
        let result = router.route(request: .init(messageType: .welcome), discordName: "Taylor")
        XCTAssertTrue(embedHasWelcomeSemantics(result))
        XCTAssertTrue(result.components.isEmpty)
        XCTAssertTrue(result.shouldTrackWelcome)
        XCTAssertFalse(result.shouldTrackCompletion)
    }

    func testSetupRouteHasSetupSemantics() {
        let result = router.route(
            request: .init(messageType: .setup, activationCode: "CODE-1234", activationExpiresInMinutes: 15),
            discordName: nil
        )
        XCTAssertTrue(embedHasSetupSemantics(result))
        XCTAssertTrue(hasField(result, matching: { name, value in
            value.contains("CODE-1234") && value.contains("```")
        }))
        // Falls back to relative minute text when no absolute expiry is supplied.
        XCTAssertTrue(hasField(result, matching: { _, value in value.contains("15 minute") }))
        // Setup starts onboarding but does NOT complete it.
        XCTAssertFalse(result.shouldTrackCompletion)
        XCTAssertFalse(result.shouldTrackWelcome)
    }

    func testSetupRouteUsesDiscordRelativeTimestampWhenAbsoluteExpirySupplied() {
        let expiresAt = Date(timeIntervalSince1970: 1_800_000_000)
        let result = router.route(
            request: .init(
                messageType: .setup,
                activationCode: "CODE-1234",
                activationExpiresInMinutes: 15,
                activationExpiresAt: expiresAt
            ),
            discordName: nil
        )
        // Absolute timestamp wins over the relative minute count so Discord
        // renders a live-updating countdown.
        XCTAssertTrue(hasField(result, matching: { _, value in
            value.contains("<t:1800000000:R>") &&
            value.contains("/miner action:setup") // expired-code hint
        }))
        XCTAssertFalse(hasField(result, matching: { _, value in value.contains("15 minute") }))
    }

    func testLinkedRouteRanksPriorityGamesWithMedalsAndNumbers() {
        let result = router.route(
            request: .init(
                messageType: .linked,
                twitchUsername: "tester",
                priorityGames: ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India"]
            ),
            discordName: nil
        )
        XCTAssertTrue(hasField(result, matching: { _, value in
            value.contains("🥇 **1.** Alpha") &&
            value.contains("🥈 **2.** Bravo") &&
            value.contains("🥉 **3.** Charlie") &&
            value.contains("**4.** Delta") &&
            value.contains("**8.** Hotel") &&
            value.contains("…and 1 more") &&
            !value.contains("India")
        }))
    }

    func testLinkedRouteHasLinkedSemantics() {
        let result = router.route(
            request: .init(messageType: .linked, twitchUsername: "tester", priorityGames: ["A", "B"]),
            discordName: nil
        )
        XCTAssertTrue(embedHasLinkedSemantics(result))
        XCTAssertTrue(hasField(result, matching: { name, _ in name.contains("priorities") }))
        XCTAssertTrue(result.shouldTrackCompletion)
        XCTAssertFalse(result.shouldTrackWelcome)
    }

    func testReauthRouteHasReauthSemantics() {
        let result = router.route(
            request: .init(messageType: .reauth, recoveryReason: "Token expired"),
            discordName: nil
        )
        XCTAssertTrue(embedHasReauthSemantics(result))
        XCTAssertTrue(hasField(result, matching: { _, value in value.contains("Token expired") }))
        XCTAssertFalse(result.shouldTrackCompletion)
        XCTAssertFalse(result.shouldTrackWelcome)
    }

    func testDropClaimedRouteHasCelebrationSemantics() {
        let result = router.route(
            request: .init(messageType: .dropClaimed, campaignName: "Summer Drops"),
            discordName: nil
        )
        XCTAssertTrue(embedHasCelebrationSemantics(result))
        XCTAssertTrue(embedDescription(result).contains("Summer Drops"))
    }

    func testCampaignCompletedRouteHasCompletionSemantics() {
        let result = router.route(
            request: .init(messageType: .campaignCompleted, campaignName: "Winter Event"),
            discordName: nil
        )
        XCTAssertTrue(embedHasCompletionSemantics(result))
        XCTAssertTrue(embedDescription(result).contains("Winter Event"))
    }

    func testCampaignCompletedRouteUsesGameArtAsFocalImage() {
        let result = router.route(
            request: .init(
                messageType: .campaignCompleted,
                affectedGame: "THE FINALS",
                campaignName: "Winter Event",
                gameArtworkURL: "https://example.com/game.jpg"
            ),
            discordName: nil
        )

        // Game art is the large focal image (not a thumbnail).
        XCTAssertEqual(
            (result.embed["image"] as? [String: String])?["url"],
            "https://example.com/game.jpg"
        )
        XCTAssertNil(result.embed["thumbnail"])
        // Title leads with the game name.
        XCTAssertTrue((result.embed["title"] as? String ?? "").contains("THE FINALS"))
        XCTAssertNil(result.embed["url"])
        XCTAssertTrue(hasField(result, matching: { name, value in
            name == "Twitch inventory" &&
            value.contains("Open Twitch Drops inventory") &&
            value.contains("https://www.twitch.tv/drops/inventory")
        }))
    }

    func testCampaignCompletedRouteOmitsTitleGameWhenUnknown() {
        let result = router.route(
            request: .init(messageType: .campaignCompleted, campaignName: "Winter Event"),
            discordName: nil
        )
        XCTAssertEqual(result.embed["title"] as? String, "🏁 Campaign complete")
        XCTAssertNil(result.embed["url"])
        XCTAssertTrue(hasField(result, matching: { name, value in
            name == "Twitch inventory" &&
            value.contains("https://www.twitch.tv/drops/inventory")
        }))
    }

    func testCampaignDetectedRouteHasDetectionSemantics() {
        let result = router.route(
            request: .init(
                messageType: .campaignDetected,
                affectedGame: "Rocket League",
                gameArtworkURL: "https://example.com/rocket.jpg",
                accountId: "account-1",
                eventId: "campaignDetected:campaign-1"
            ),
            discordName: nil
        )
        XCTAssertTrue(embedHasDetectionSemantics(result))
        XCTAssertTrue(embedTitle(result).contains("Rocket League"))
        XCTAssertTrue(embedDescription(result).contains("Rocket League"))
        XCTAssertTrue(embedDescription(result).contains("priority list"))
        XCTAssertEqual(embedFooter(result), SwiftMinerDMTheme.default.statusFooter)
        XCTAssertEqual(
            (result.embed["image"] as? [String: String])?["url"],
            "https://example.com/rocket.jpg"
        )
        XCTAssertNil(result.embed["thumbnail"])
        XCTAssertNil(result.embed["url"])
        XCTAssertTrue(hasField(result, matching: { name, value in
            name == "Twitch inventory" &&
            value.contains("Open Twitch Drops inventory") &&
            value.contains("https://www.twitch.tv/drops/inventory")
        }))
        // Actions moved to the web dashboard — DMs carry no buttons.
        XCTAssertTrue(result.components.isEmpty)
    }

    func testAccountActionRequiredRouteHasAlertSemantics() {
        let result = router.route(
            request: .init(messageType: .accountActionRequired, recoveryReason: "2FA needed"),
            discordName: nil
        )
        XCTAssertTrue(embedHasAlertSemantics(result))
        XCTAssertTrue(hasField(result, matching: { _, value in value.contains("2FA needed") }))
    }

    func testPrioritisedGameNeedsLinkingRouteHasLinkingSemantics() {
        let result = router.route(
            request: .init(messageType: .prioritisedGameNeedsLinking, affectedGame: "Valorant"),
            discordName: nil
        )
        XCTAssertTrue(embedHasLinkingSemantics(result))
        XCTAssertTrue(embedTitle(result).contains("Valorant"))
        XCTAssertNil(result.embed["url"])
        XCTAssertTrue(hasField(result, matching: { _, value in
            value.contains("https://www.twitch.tv/drops/inventory")
        }))
        XCTAssertTrue(result.components.isEmpty)
    }

    func testDMsCarryNoInteractiveControls() {
        // Actions live on the web dashboard now; every DM is buttonless.
        for type in SwiftMinerDMMessageType.allCases {
            let result = router.route(request: .init(messageType: type), discordName: nil)
            XCTAssertTrue(result.components.isEmpty, "expected no components for \(type.rawValue)")
        }
    }

    func testDashboardFooterAppendedWhenURLConfigured() {
        let dashboardRouter = SwiftMinerDMRouter(dashboardURL: "https://swiftminer.example.com")
        let result = dashboardRouter.route(request: .init(messageType: .campaignCompleted), discordName: nil)
        XCTAssertTrue(embedDescription(result).contains("https://swiftminer.example.com"))
        XCTAssertTrue(result.components.isEmpty)
    }

    func testWebDashboardAvailableRouteIsSimpleAnnouncement() {
        let dashboardRouter = SwiftMinerDMRouter(dashboardURL: "https://swiftminer.example.com")
        let result = dashboardRouter.route(request: .init(messageType: .webDashboardAvailable), discordName: nil)
        XCTAssertTrue(embedTitle(result).contains("dashboard"))
        XCTAssertTrue(embedDescription(result).contains("https://swiftminer.example.com"))
        XCTAssertTrue(result.components.isEmpty)
        XCTAssertFalse(result.shouldTrackWelcome)
        XCTAssertFalse(result.shouldTrackCompletion)
    }

    func testWelcomeBackRouteHasWelcomeBackSemantics() {
        let result = router.route(request: .init(messageType: .welcomeBack), discordName: "Alex")
        XCTAssertTrue(embedHasWelcomeBackSemantics(result))
        XCTAssertTrue(embedDescription(result).contains("Alex"))
    }

    // MARK: - Debug Isolation

    func testDebugModePrefixesTitle() {
        let result = router.route(request: .init(messageType: .linked, debug: true), discordName: nil)
        XCTAssertTrue(embedTitle(result).hasPrefix("[TEST]"))
    }

    func testDebugModeDoesNotTrackWelcome() {
        let result = router.route(request: .init(messageType: .welcome, debug: true), discordName: nil)
        XCTAssertFalse(result.shouldTrackWelcome)
    }

    func testDebugModeDoesNotTrackCompletion() {
        let result = router.route(request: .init(messageType: .linked, debug: true), discordName: nil)
        XCTAssertFalse(result.shouldTrackCompletion)
    }

    func testDebugModeMarksFooterAsTest() {
        let result = router.route(request: .init(messageType: .linked, debug: true), discordName: nil)
        XCTAssertTrue(embedFooter(result).contains("TEST"))
    }

    // MARK: - Greeting Personalization

    func testDiscordNamePersonalisesDescription() {
        let result = router.route(request: .init(messageType: .welcome), discordName: "Sam")
        XCTAssertTrue(embedDescription(result).contains("Sam"))
    }

    func testNilDiscordNameDoesNotInjectGreeting() {
        let result = router.route(request: .init(messageType: .welcome), discordName: nil)
        XCTAssertFalse(embedDescription(result).contains("Hi **"))
    }

    // MARK: - Embed Structure

    func testAllMessageTypesProduceNonEmptyTitle() {
        for type in SwiftMinerDMMessageType.allCases {
            let result = router.route(request: .init(messageType: type), discordName: nil)
            XCTAssertFalse(embedTitle(result).isEmpty, "\(type) should produce a title")
        }
    }

    func testAllMessageTypesProduceNonEmptyDescription() {
        for type in SwiftMinerDMMessageType.allCases {
            let result = router.route(request: .init(messageType: type), discordName: nil)
            XCTAssertFalse(embedDescription(result).isEmpty, "\(type) should produce a description")
        }
    }

    // MARK: - Helpers

    private func embedTitle(_ result: SwiftMinerDMResult) -> String {
        result.embed["title"] as? String ?? ""
    }

    private func embedDescription(_ result: SwiftMinerDMResult) -> String {
        result.embed["description"] as? String ?? ""
    }

    private func embedFooter(_ result: SwiftMinerDMResult) -> String {
        (result.embed["footer"] as? [String: String])?["text"] ?? ""
    }

    private func embedColor(_ result: SwiftMinerDMResult) -> Int {
        result.embed["color"] as? Int ?? 0
    }

    private func hasField(_ result: SwiftMinerDMResult, matching predicate: (String, String) -> Bool) -> Bool {
        let fields = result.embed["fields"] as? [[String: Any]] ?? []
        return fields.contains { field in
            guard let name = field["name"] as? String,
                  let value = field["value"] as? String else { return false }
            return predicate(name, value)
        }
    }


    // Semantic checks that are resilient to exact wording changes

    private func embedHasWelcomeSemantics(_ result: SwiftMinerDMResult) -> Bool {
        embedTitle(result).contains("Welcome") && embedColorMatches(result, style: .neutral)
    }

    private func embedHasSetupSemantics(_ result: SwiftMinerDMResult) -> Bool {
        let title = embedTitle(result)
        let hasActivate = embedDescription(result).contains("activate") || hasField(result, matching: { _, v in v.contains("activate") })
        return title.contains("Link") && hasActivate
    }

    private func embedHasLinkedSemantics(_ result: SwiftMinerDMResult) -> Bool {
        embedTitle(result).contains("connected") && embedDescription(result).contains("linked")
    }

    private func embedHasReauthSemantics(_ result: SwiftMinerDMResult) -> Bool {
        embedTitle(result).contains("expired") && embedColorMatches(result, style: .warning)
    }

    private func embedHasCelebrationSemantics(_ result: SwiftMinerDMResult) -> Bool {
        embedTitle(result).contains("claimed") && embedColorMatches(result, style: .success)
    }

    private func embedHasCompletionSemantics(_ result: SwiftMinerDMResult) -> Bool {
        embedTitle(result).contains("complete") && embedColorMatches(result, style: .success)
    }

    private func embedHasDetectionSemantics(_ result: SwiftMinerDMResult) -> Bool {
        embedTitle(result).contains("campaign") && embedColorMatches(result, style: .info)
    }

    private func embedHasAlertSemantics(_ result: SwiftMinerDMResult) -> Bool {
        embedTitle(result).contains("look") && embedColorMatches(result, style: .recovery)
    }

    private func embedHasLinkingSemantics(_ result: SwiftMinerDMResult) -> Bool {
        embedTitle(result).contains("Link") && embedColorMatches(result, style: .warning)
    }

    private func embedHasWelcomeBackSemantics(_ result: SwiftMinerDMResult) -> Bool {
        embedTitle(result).contains("back") && embedColorMatches(result, style: .neutral)
    }

    private func embedColorMatches(_ result: SwiftMinerDMResult, style: SwiftMinerDMStyle) -> Bool {
        embedColor(result) == style.color
    }
}
