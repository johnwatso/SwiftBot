import XCTest
@testable import SwiftBot

final class SwiftMinerDMThemeTests: XCTestCase {

    // MARK: - Default Theme

    func testDefaultThemeProducesLinkedEmbed() {
        let theme = SwiftMinerDMTheme.default
        let router = SwiftMinerDMRouter(theme: theme)
        let result = router.route(
            request: .init(messageType: .linked, priorityGames: ["Game A"]),
            discordName: nil
        )

        XCTAssertTrue(embedHasField(result, where: { name, _ in
            name.contains("priorities")
        }))
    }

    func testWelcomeIncludesProjectLink() {
        let router = SwiftMinerDMRouter(theme: .default)
        let result = router.route(request: .init(messageType: .welcome), discordName: nil)

        XCTAssertTrue(embedHasField(result, where: { name, value in
            name.contains("SwiftMiner") &&
            value.contains("github.com/johnwatso/SwiftMiner")
        }))
    }

    // MARK: - Custom Theme Override

    func testCustomThemeOverridesSectionLabel() {
        var custom = SwiftMinerDMTheme.default
        custom.prioritisationSectionLabel = "🎯 Mining targets"

        let router = SwiftMinerDMRouter(theme: custom)
        let result = router.route(
            request: .init(messageType: .linked, priorityGames: ["Game A"]),
            discordName: nil
        )

        XCTAssertTrue(embedHasField(result, where: { name, _ in
            name == "🎯 Mining targets"
        }))
    }

    func testCustomThemeOverridesFooter() {
        var custom = SwiftMinerDMTheme.default
        custom.statusFooter = "Custom footer copy"

        let router = SwiftMinerDMRouter(theme: custom)
        let result = router.route(request: .init(messageType: .linked), discordName: nil)

        let footer = embedFooter(result)
        XCTAssertEqual(footer, "Custom footer copy")
    }

    func testCustomThemeOverridesSetupDescription() {
        var custom = SwiftMinerDMTheme.default
        custom.setupDescription = "Custom setup instructions here."

        let router = SwiftMinerDMRouter(theme: custom)
        let result = router.route(request: .init(messageType: .setup), discordName: nil)

        XCTAssertTrue(embedDescription(result).contains("Custom setup instructions here."))
    }

    // MARK: - Style Color Consistency

    func testSuccessStyleColorIsStable() {
        XCTAssertEqual(SwiftMinerDMStyle.success.color, 3_062_954)
    }

    func testWarningStyleColorIsStable() {
        XCTAssertEqual(SwiftMinerDMStyle.warning.color, 15_179_008)
    }

    func testInfoStyleColorIsStable() {
        XCTAssertEqual(SwiftMinerDMStyle.info.color, 3_447_003)
    }

    func testRecoveryStyleColorIsStable() {
        XCTAssertEqual(SwiftMinerDMStyle.recovery.color, 15_132_320)
    }

    // MARK: - Debug Style

    func testDebugPrefixIsStable() {
        XCTAssertEqual(SwiftMinerDMDebugStyle.titlePrefix, "[TEST] ")
    }

    func testDebugFooterSuffixIsStable() {
        XCTAssertTrue(SwiftMinerDMDebugStyle.footerSuffix.contains("TEST"))
    }

    // MARK: - Helpers

    private func embedDescription(_ result: SwiftMinerDMResult) -> String {
        result.embed["description"] as? String ?? ""
    }

    private func embedFooter(_ result: SwiftMinerDMResult) -> String {
        (result.embed["footer"] as? [String: String])?["text"] ?? ""
    }

    private func embedHasField(_ result: SwiftMinerDMResult, where predicate: (String, String) -> Bool) -> Bool {
        let fields = result.embed["fields"] as? [[String: Any]] ?? []
        return fields.contains { field in
            guard let name = field["name"] as? String,
                  let value = field["value"] as? String else { return false }
            return predicate(name, value)
        }
    }
}
