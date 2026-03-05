import XCTest
@testable import SwiftBot

final class HelpEngineTests: XCTestCase {

    // MARK: - Command Catalog Integrity

    func testCommandCatalogRegistration() {
        let prefix = "!"
        let wikiCommands = [
            WikiCommandInfo(trigger: "weapon", sourceName: "Wiki", description: "Search weapons"),
            WikiCommandInfo(trigger: "weapon", sourceName: "Other", description: "Dup check")
        ]
        
        let catalog = CommandCatalog.build(prefix: prefix, wikiCommands: wikiCommands)
        
        // Verify core commands
        XCTAssertNotNil(catalog.entry(for: "help"))
        XCTAssertNotNil(catalog.entry(for: "ping"))
        XCTAssertNotNil(catalog.entry(for: "cluster"))
        
        // Verify alias lookup
        XCTAssertNotNil(catalog.entry(for: "worker"))
        XCTAssertEqual(catalog.entry(for: "worker")?.name, "cluster")
        
        // Verify category rename (Moderation -> Server)
        XCTAssertEqual(catalog.entry(for: "setchannel")?.category, .moderation)
        XCTAssertEqual(CommandCategory.moderation.rawValue, "Server")
        
        // Verify wiki command and deduplication
        XCTAssertNotNil(catalog.entry(for: "weapon"))
        let weaponCmds = catalog.entries.filter { $0.name == "weapon" }
        XCTAssertEqual(weaponCmds.count, 1, "Wiki commands with same trigger must be deduplicated")
        XCTAssertEqual(weaponCmds.first?.description, "Gathers info from a configured Wiki source.")
        XCTAssertEqual(catalog.configuredWikiSources, ["Other", "Wiki"])
    }

    func testApprovedNamesWhitelist() {
        let catalog = CommandCatalog.build(prefix: "!", wikiCommands: [])
        let approved = catalog.approvedNames
        
        XCTAssertTrue(approved.contains("help"))
        XCTAssertTrue(approved.contains("cluster"))
        XCTAssertTrue(approved.contains("worker"), "Whitelist must include aliases")
        XCTAssertFalse(approved.contains("unknown_command"))
    }

    // MARK: - Embed Rendering

    func testEmbedOverviewStructure() {
        let settings = HelpSettings(mode: .classic, tone: .friendly, customIntro: "Test Intro", customFooter: "Test Footer")
        let renderer = HelpRenderer(prefix: "!", helpSettings: settings)
        let catalog = CommandCatalog.build(prefix: "!", wikiCommands: [])
        
        let embed = renderer.embedOverview(catalog: catalog)
        
        XCTAssertEqual(embed["title"] as? String, "SwiftBot Commands")
        XCTAssertEqual(embed["description"] as? String, "Test Intro")
        
        let fields = embed["fields"] as? [[String: Any]] ?? []
        XCTAssertFalse(fields.isEmpty)
        
        // Verify category field names match new spec
        let fieldNames = fields.compactMap { $0["name"] as? String }
        XCTAssertTrue(fieldNames.contains("General"))
        XCTAssertTrue(fieldNames.contains("Server"))
        XCTAssertFalse(fieldNames.contains("Moderation"), "Moderation must be renamed to Server")
        
        // Verify no examples in overview values
        for field in fields {
            let value = field["value"] as? String ?? ""
            XCTAssertFalse(value.contains("e.g."), "Overview fields must not contain examples")
            XCTAssertFalse(value.contains("!help roll"), "Overview fields must not contain examples")
        }
        
        let footer = embed["footer"] as? [String: String]
        XCTAssertTrue(footer?["text"]?.contains("Test Footer") ?? false)
    }

    func testEmbedOverviewIncludesConfiguredWikis() {
        let settings = HelpSettings(mode: .classic, tone: .friendly, customIntro: "", customFooter: "")
        let renderer = HelpRenderer(prefix: "!", helpSettings: settings)
        let catalog = CommandCatalog.build(prefix: "!", wikiCommands: [
            WikiCommandInfo(trigger: "wiki", sourceName: "THE FINALS Wiki", description: ""),
            WikiCommandInfo(trigger: "weapon", sourceName: "Destiny Wiki", description: "")
        ])

        let embed = renderer.embedOverview(catalog: catalog)
        let fields = embed["fields"] as? [[String: Any]] ?? []
        let wikiField = fields.first { ($0["name"] as? String) == "WikiBridge" }
        let value = wikiField?["value"] as? String ?? ""
        XCTAssertTrue(value.contains("Configured wikis:"))
        XCTAssertTrue(value.contains("THE FINALS Wiki"))
        XCTAssertTrue(value.contains("Destiny Wiki"))
    }

    // MARK: - Help Renderer (Text/Fallback)

    func testTextOverviewNoExamples() {
        let settings = HelpSettings(mode: .classic, tone: .detailed, customIntro: "", customFooter: "")
        let renderer = HelpRenderer(prefix: "!", helpSettings: settings)
        let catalog = CommandCatalog.build(prefix: "!", wikiCommands: [])
        
        let output = renderer.overview(catalog: catalog)
        
        // Detailed text overview should still be grouped and concise now
        XCTAssertTrue(output.contains("**General**"))
        XCTAssertTrue(output.contains("`ping` — Checks if the bot is alive."))
        XCTAssertFalse(output.contains("e.g. !ping"), "Examples must only appear in detail view")
    }

    func testCommandDetailView() {
        let settings = HelpSettings(mode: .classic, tone: .detailed, customIntro: "", customFooter: "")
        let renderer = HelpRenderer(prefix: "!", helpSettings: settings)
        let catalog = CommandCatalog.build(prefix: "!", wikiCommands: [])
        
        guard let clusterEntry = catalog.entry(for: "cluster") else {
            XCTFail("Cluster entry missing")
            return
        }
        
        let output = renderer.detail(for: clusterEntry)
        XCTAssertTrue(output.contains("**`!cluster [status | test | probe]`**"))
        XCTAssertTrue(output.contains("Aliases: `!worker`"))
        XCTAssertTrue(output.contains("Examples:") && output.contains("`!cluster status`"))
    }

    // MARK: - AI Safety

    func testAIIntroPromptIntegrity() {
        let catalog = CommandCatalog.build(prefix: "!", wikiCommands: [])
        let settings = HelpSettings(mode: .smart, tone: .friendly, customIntro: "", customFooter: "")
        let renderer = HelpRenderer(prefix: "!", helpSettings: settings)
        
        let prompt = renderer.aiIntroPrompt(catalog: catalog)
        
        XCTAssertTrue(prompt.contains("Write a short intro sentence"))
        XCTAssertTrue(prompt.contains("Do NOT list or mention commands"))
        XCTAssertTrue(prompt.contains("Warm and friendly"))
    }

    // MARK: - Fallback Logic (AppModel Mock Simulation)

    @MainActor
    func testDeterministicFallbackSimulation() async {
        let app = AppModel()
        app.settings.help.mode = .classic
        
        let prefix = "!"
        let catalog = CommandCatalog.build(prefix: prefix, wikiCommands: [])
        let renderer = HelpRenderer(prefix: prefix, helpSettings: app.settings.help)
        
        // 1. Simulate !help (Embed Overview)
        let embed = renderer.embedOverview(catalog: catalog)
        XCTAssertEqual(embed["title"] as? String, "SwiftBot Commands")
        
        // 2. Simulate !help roll (Text Detail)
        if let entry = catalog.entry(for: "roll") {
            let detail = renderer.detail(for: entry)
            XCTAssertTrue(detail.contains("**`!roll NdS`**"))
        } else {
            XCTFail("Roll command should be in catalog")
        }
    }
}
