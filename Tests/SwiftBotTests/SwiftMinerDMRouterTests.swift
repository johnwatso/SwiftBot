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
        // Interactive controls live on the web dashboard. Without a portal deep
        // link from SwiftMiner there is nothing to link to either, so a DM that
        // carries no `portal_url` stays buttonless.
        for type in SwiftMinerDMMessageType.allCases {
            let result = router.route(request: .init(messageType: type), discordName: nil)
            XCTAssertTrue(result.components.isEmpty, "expected no components for \(type.rawValue)")
        }
    }

    // MARK: - Portal Deep Links

    private static let portal = "https://swiftminer.example.com"

    func testPortalLinkBecomesTheOneButtonLabelledByItsDestination() {
        let result = router.route(
            request: .init(
                messageType: .reauth,
                portalURL: "\(Self.portal)/app#/account/connection",
                portalDestination: .accountConnection
            ),
            discordName: nil
        )

        let buttons = linkButtons(result)
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(buttons.first?.label, "Reconnect Twitch")
        XCTAssertEqual(buttons.first?.url, "\(Self.portal)/app#/account/connection")
    }

    func testEveryDestinationRendersItsOwnLabel() {
        let expected: [SwiftMinerPortalDestination: String] = [
            .dashboard: "Open Dashboard",
            .miner: "View Miner",
            .accountConnection: "Reconnect Twitch",
            .campaign: "View Campaign",
            .campaigns: "View Campaigns",
            .drops: "View Drops"
        ]

        for destination in SwiftMinerPortalDestination.allCases {
            let result = router.route(
                request: .init(
                    messageType: .campaignCompleted,
                    portalURL: "\(Self.portal)/app",
                    portalDestination: destination
                ),
                discordName: nil
            )
            XCTAssertEqual(linkButtons(result).first?.label, expected[destination], destination.rawValue)
        }
    }

    /// The specific route is better than the dashboard root, so a DM must never
    /// show both.
    func testDeepLinkedDMDropsTheGenericDashboardFooter() {
        let dashboardRouter = SwiftMinerDMRouter(dashboardURL: Self.portal)
        let result = dashboardRouter.route(
            request: .init(
                messageType: .campaignCompleted,
                portalURL: "\(Self.portal)/app#/drops",
                portalDestination: .drops
            ),
            discordName: nil
        )

        XCTAssertFalse(embedDescription(result).contains("Manage your miner"))
        XCTAssertEqual(linkButtons(result).first?.url, "\(Self.portal)/app#/drops")
    }

    func testHelpArticleIsSecondaryToThePortalButton() {
        let result = router.route(
            request: .init(
                messageType: .accountActionRequired,
                portalURL: "\(Self.portal)/app#/campaign/camp-1",
                portalDestination: .campaign,
                issueKind: .subscriptionRequired,
                helpURL: "https://swiftminer.app/help/subscription-required-drops/"
            ),
            discordName: nil
        )

        XCTAssertEqual(linkButtons(result).map(\.label), ["View Campaign", "Learn More"])
    }

    /// A help article on its own is not the action the DM is asking for.
    func testHelpArticleAloneRendersNoButton() {
        let result = router.route(
            request: .init(
                messageType: .accountActionRequired,
                issueKind: .subscriptionRequired,
                helpURL: "https://swiftminer.app/help/subscription-required-drops/"
            ),
            discordName: nil
        )

        XCTAssertTrue(result.components.isEmpty)
    }

    /// Discord rejects the whole message over a malformed link button, so a bad
    /// URL has to cost the button rather than the DM.
    func testMalformedPortalURLDropsTheButtonNotTheDM() {
        for bad in ["", "not a url", "javascript:alert(1)", "ftp://example.com/x"] {
            let result = router.route(
                request: .init(messageType: .reauth, portalURL: bad, portalDestination: .accountConnection),
                discordName: nil
            )
            XCTAssertTrue(result.components.isEmpty, "expected no button for \(bad)")
            XCTAssertFalse(embedTitle(result).isEmpty, "DM itself should still render for \(bad)")
        }
    }

    func testUnknownDestinationStillLinksUsingTheDashboardLabel() throws {
        // SwiftMiner may add a destination before this build knows it; the URL
        // is the authority, so the button must still render.
        let json = #"{"message_type":"reauth","portal_url":"https://swiftminer.example.com/app#/something/new","portal_destination":"something_new"}"#
        let request = try JSONDecoder().decode(SwiftMinerDMRequest.self, from: Data(json.utf8))
        XCTAssertNil(request.portalDestination)

        let result = router.route(request: request, discordName: nil)
        XCTAssertEqual(linkButtons(result).first?.label, "Open Dashboard")
        XCTAssertEqual(linkButtons(result).first?.url, "\(Self.portal)/app#/something/new")
    }

    // MARK: - Specific Language

    func testKnownCauseTitlesTheDMInsteadOfNeedsALook() {
        let cases: [(SwiftMinerIssueKind, String)] = [
            (.subscriptionRequired, "Twitch Subscription Required"),
            (.accountLinkRequired, "Account Linking Required"),
            (.connectionExpired, "Twitch Connection Expired")
        ]

        for (kind, expected) in cases {
            let result = router.route(
                request: .init(messageType: .accountActionRequired, issueKind: kind),
                discordName: nil
            )
            XCTAssertTrue(embedTitle(result).contains(expected), "\(kind.rawValue) produced \(embedTitle(result))")
            XCTAssertFalse(embedTitle(result).lowercased().contains("needs a look"))
        }
    }

    func testUnclassifiedCauseKeepsTheGenericTitle() {
        for kind in [SwiftMinerIssueKind.unknown, nil] {
            let result = router.route(
                request: .init(messageType: .accountActionRequired, issueKind: kind),
                discordName: nil
            )
            XCTAssertTrue(embedTitle(result).lowercased().contains("needs a look"))
        }
    }

    func testCampaignIsNamedAheadOfTheRawReason() {
        let result = router.route(
            request: .init(
                messageType: .accountActionRequired,
                affectedGame: "Cyberpunk 2077",
                campaignName: "Phantom Liberty Drops",
                recoveryReason: "Requires an active Twitch subscription.",
                issueKind: .subscriptionRequired
            ),
            discordName: nil
        )

        XCTAssertTrue(hasField(result, matching: { _, value in
            value.contains("Cyberpunk 2077: Phantom Liberty Drops")
                && value.contains("Requires an active Twitch subscription.")
        }))
    }

    // MARK: - Claimed but undelivered

    /// Telling someone to go and earn rewards they already hold reads as a bug,
    /// so the claimed case gets its own wording.
    func testDeliveryPendingLinkDMDoesNotTellTheUserToEarnAnything() {
        let result = router.route(
            request: .init(
                messageType: .prioritisedGameNeedsLinking,
                affectedGame: "Call of Duty: Modern Warfare 4",
                issueKind: .accountLinkDeliveryPending
            ),
            discordName: nil
        )

        let body = embedTitle(result) + " " + embedDescription(result)
        XCTAssertTrue(body.contains("waiting"), body)
        XCTAssertTrue(body.contains("cannot be delivered"), body)
        XCTAssertFalse(body.contains("can claim its Drops yet"), body)
    }

    func testUnclaimedLinkDMKeepsTheEarningWording() {
        let result = router.route(
            request: .init(
                messageType: .prioritisedGameNeedsLinking,
                affectedGame: "Call of Duty: Modern Warfare 4",
                issueKind: .accountLinkRequired
            ),
            discordName: nil
        )

        let body = embedTitle(result) + " " + embedDescription(result)
        XCTAssertTrue(body.contains("can claim its Drops yet"), body)
        XCTAssertFalse(body.contains("waiting"), body)
    }

    /// An older SwiftMiner sends no issue_kind at all; that must keep the
    /// original wording rather than silently switching to the claimed variant.
    func testLinkDMWithoutAnIssueKindKeepsTheOriginalWording() {
        let result = router.route(
            request: .init(
                messageType: .prioritisedGameNeedsLinking,
                affectedGame: "Call of Duty: Modern Warfare 4"
            ),
            discordName: nil
        )

        XCTAssertTrue(embedDescription(result).contains("can claim its Drops yet"))
    }

    func testDeliveryPendingKindDecodesFromTheWire() throws {
        let payload = #"{"message_type":"prioritised_game_needs_linking","issue_kind":"account_link_delivery_pending"}"#
        let request = try JSONDecoder().decode(SwiftMinerDMRequest.self, from: Data(payload.utf8))

        XCTAssertEqual(request.issueKind, .accountLinkDeliveryPending)
        XCTAssertEqual(request.issueKind?.title, "Rewards Waiting on an Account Link")
    }

    // MARK: - Payload compatibility

    func testPayloadsWithoutTheNewFieldsStillDecode() throws {
        let legacy = #"{"message_type":"welcome","debug":false,"priority_games":[]}"#
        let request = try JSONDecoder().decode(SwiftMinerDMRequest.self, from: Data(legacy.utf8))

        XCTAssertEqual(request.messageType, .welcome)
        XCTAssertNil(request.portalURL)
        XCTAssertNil(request.portalDestination)
        XCTAssertNil(request.issueKind)
        XCTAssertNil(request.campaignId)
        XCTAssertNil(request.helpURL)
    }

    func testSwiftMinerPayloadDecodesEndToEnd() throws {
        // The shape SwiftMiner emits for a subscription-gated campaign; see
        // Documentation/SwiftBotDMContract.md in the SwiftMiner repo.
        let payload = #"""
        {"message_type":"account_action_required","debug":false,
         "twitch_username":"john","priority_games":["Cyberpunk 2077"],
         "affected_game":"Cyberpunk 2077","campaign_name":"Phantom Liberty Drops",
         "account_id":"123456","miner_display_name":"John",
         "recovery_reason":"A paid Twitch subscription is required.",
         "portal_url":"https://portal.example.com/app#/campaign/camp%2D1",
         "portal_destination":"campaign","issue_kind":"subscription_required",
         "campaign_id":"camp-1",
         "help_url":"https://swiftminer.app/help/subscription-required-drops/"}
        """#
        let request = try JSONDecoder().decode(SwiftMinerDMRequest.self, from: Data(payload.utf8))

        XCTAssertEqual(request.portalDestination, .campaign)
        XCTAssertEqual(request.issueKind, .subscriptionRequired)
        XCTAssertEqual(request.campaignId, "camp-1")

        let result = router.route(request: request, discordName: "John")
        XCTAssertTrue(embedTitle(result).contains("Twitch Subscription Required"))
        XCTAssertEqual(linkButtons(result).map(\.label), ["View Campaign", "Learn More"])
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

    private func linkButtons(_ result: SwiftMinerDMResult) -> [(label: String, url: String)] {
        result.components
            .compactMap { $0["components"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { ($0["style"] as? Int) == 5 }
            .compactMap { button in
                guard let label = button["label"] as? String,
                      let url = button["url"] as? String else { return nil }
                return (label, url)
            }
    }

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
