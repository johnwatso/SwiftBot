import XCTest
@testable import SwiftBot

final class WikiLookupTests: XCTestCase {

    // MARK: - Infobox parsing (markup trimmed from the real pages)

    func testPortableInfoboxRowsAndSmartGroups() {
        // Elden Ring (Fandom): plain rows plus a smart group joined by data-source.
        let html = """
        <aside class="portable-infobox">
          <div class="pi-item pi-data"><h3 class="pi-data-label">Type</h3><div class="pi-data-value">Katana</div></div>
          <div class="pi-item pi-data"><h3 class="pi-data-label">Weight</h3><div class="pi-data-value">6.5</div></div>
          <section class="pi-item pi-smart-group">
            <section class="pi-smart-group-head">
              <h3 class="pi-smart-data-label" data-source="phys">Phys</h3>
              <h3 class="pi-smart-data-label" data-source="magic">Magic</h3>
            </section>
            <section class="pi-smart-group-body">
              <div class="pi-smart-data-value" data-source="phys">73</div>
              <div class="pi-smart-data-value" data-source="magic">87</div>
            </section>
          </section>
        </aside>
        """
        let fields = WikiInfoboxParser.fields(html: html)
        XCTAssertEqual(fields.map(\.name), ["Type", "Weight", "Phys", "Magic"])
        XCTAssertEqual(fields.map(\.value), ["Katana", "6.5", "73", "87"])
    }

    func testTableInfoboxSkipsHeaderRows() {
        // Minecraft/Terraria style: th + td rows; a th + th row is a section title.
        let html = """
        <div class="infobox notaninfobox"><table class="infobox-rows">
          <tr><th>Attack Power</th><th>Guard Negation</th></tr>
          <tr><th>Attack damage</th><td>7 HP</td></tr>
          <tr><th>Durability</th><td>1561</td></tr>
          <tr><th>Rarity</th><td></td></tr>
        </table></div>
        """
        let fields = WikiInfoboxParser.fields(html: html)
        XCTAssertEqual(fields.map(\.name), ["Attack damage", "Durability"])
    }

    func testDivRowInfoboxAndIconLabels() {
        // WARFRAME: .row > .label/.value, with damage types labelled by icon alt text.
        let html = """
        <div class="infobox">
          <div class="row"><div class="label">Magazine Size</div><div class="value">45</div></div>
          <div class="row"><div class="label">&lt;impact&gt;</div><div class="value">7.92</div></div>
          <div class="row"><div class="label">Reload Time [1]</div><div class="value">2.00 s</div></div>
        </div>
        """
        let fields = WikiInfoboxParser.fields(html: html)
        XCTAssertEqual(fields.map(\.name), ["Magazine Size", "Impact", "Reload Time"])
    }

    func testWikitableIsOnlyAFallback() {
        let infoboxPlusTable = """
        <div class="infobox"><table>
          <tr><th>A</th><td>1</td></tr><tr><th>B</th><td>2</td></tr><tr><th>C</th><td>3</td></tr>
        </table></div>
        <table class="wikitable"><tr><td>Recipe</td><td>Wood</td></tr></table>
        """
        XCTAssertFalse(WikiInfoboxParser.fields(html: infoboxPlusTable).map(\.name).contains("Recipe"))

        let tableOnly = #"<table class="wikitable"><tr><td>Recipe</td><td>Wood</td></tr></table>"#
        XCTAssertEqual(WikiInfoboxParser.fields(html: tableOnly).map(\.name), ["Recipe"])
    }

    // MARK: - Compare

    func testNumbersAndDirections() {
        XCTAssertEqual(WikiStatComparison.number(in: "2.00 s"), 2)
        XCTAssertEqual(WikiStatComparison.number(in: "JE : 1,561 BE : 1562"), 1561)
        XCTAssertNil(WikiStatComparison.number(in: "Assault Rifle"))
        XCTAssertEqual(WikiStatComparison.higherIsBetter("Body Damage"), true)
        XCTAssertEqual(WikiStatComparison.higherIsBetter("Short Reload"), false)
        XCTAssertEqual(WikiStatComparison.higherIsBetter("Use time"), false)
        XCTAssertNil(WikiStatComparison.higherIsBetter("Released"))
    }

    func testRowsPutSharedStatsFirstAndPickWinners() {
        let akm = [
            WikiResultField(name: "Type", value: "Assault Rifle"),
            WikiResultField(name: "Damage", value: "18"),
            WikiResultField(name: "Short Reload", value: "1.9s"),
            WikiResultField(name: "Notes", value: "Only on AKM")
        ]
        let fcar = [
            WikiResultField(name: "Damage", value: "20"),
            WikiResultField(name: "Short Reload", value: "2.3s"),
            WikiResultField(name: "Type", value: "Assault Rifle")
        ]
        let rows = WikiStatComparison.rows(left: akm, right: fcar)
        XCTAssertEqual(rows.map(\.name), ["Type", "Damage", "Short Reload", "Notes"])
        XCTAssertNil(rows[0].winner)
        XCTAssertEqual(rows[1].winner, .right)
        XCTAssertEqual(rows[2].winner, .left)
        XCTAssertNil(rows[3].right)
    }

    func testSplitVersus() {
        XCTAssertEqual(WikiStatComparison.splitVersus("akm vs fcar")?.0, "akm")
        XCTAssertEqual(WikiStatComparison.splitVersus("Night's Edge VERSUS Excalibur")?.1, "Excalibur")
        XCTAssertEqual(WikiStatComparison.splitVersus("akm vs. fcar")?.1, "fcar")
        XCTAssertNil(WikiStatComparison.splitVersus("vsr-10"))
        XCTAssertNil(WikiStatComparison.splitVersus("akm vs "))
    }

    // MARK: - Aliases and settings

    func testAliasResolution() {
        var source = WikiSource()
        source.aliases = [WikiAlias(from: "AK", to: "AKM"), WikiAlias(from: "nights edge", to: "Night's Edge")]
        XCTAssertEqual(source.resolvingAlias("ak"), "AKM")
        XCTAssertEqual(source.resolvingAlias("Night's Edge"), "Night's Edge")
        XCTAssertEqual(source.resolvingAlias("night's-edge"), "Night's Edge")
        XCTAssertEqual(source.resolvingAlias("fcar"), "fcar")
    }

    func testOlderSettingsDecodeWithNewDefaults() throws {
        let json = #"{"isEnabled":true,"sources":[{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","name":"Wiki","baseURL":"https://minecraft.wiki"}]}"#
        let decoded = try JSONDecoder().decode(WikiBotSettings.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.answersQuestions)
        XCTAssertEqual(decoded.sources.first?.aliases, [])
    }

    func testDefaultFinalsUsesTheWorkingAPIPath() {
        XCTAssertEqual(WikiSource.defaultFinals().apiPath, "/w/api.php")
    }

    @MainActor
    func testAlternativesCustomIDFitsDiscordLimit() {
        let id = AppModel.wikiAlternativesCustomID(sourceID: UUID(), query: String(repeating: "long query ", count: 20))
        XCTAssertLessThanOrEqual(id.count, 100)
        XCTAssertTrue(id.hasPrefix(AppModel.wikiAlternativesCustomIDPrefix))
    }

    // MARK: - Usage

    func testUsageSummaryCountsTopItemsAndOpenMisses() async {
        let store = WikiLookupUsageStore(filename: nil)
        let source = UUID()
        let now = Date()
        await store.record(sourceID: source, query: "akm", title: "AKM", at: now)
        await store.record(sourceID: source, query: "ak", title: "AKM", at: now)
        await store.record(sourceID: source, query: "AKM", title: "AKM", at: now)
        await store.record(sourceID: source, query: "fcar", title: "FCAR", at: now)
        await store.record(sourceID: source, query: "akm2", title: nil, at: now)
        // Missed once, then found: no longer a miss.
        await store.record(sourceID: source, query: "sledge", title: nil, at: now.addingTimeInterval(-60))
        await store.record(sourceID: source, query: "sledge", title: "Sledgehammer", at: now)
        // Older than a week: counts toward top items, not "this week".
        await store.record(sourceID: source, query: "fcar", title: "FCAR", at: now.addingTimeInterval(-10 * 24 * 60 * 60))

        let summary = await store.summaries(now: now)[source]
        XCTAssertEqual(summary?.lookupsThisWeek, 7)
        XCTAssertEqual(summary?.topItems.first?.title, "AKM")
        XCTAssertEqual(summary?.topItems.first?.count, 3)
        XCTAssertEqual(summary?.recentMisses, ["akm2"])
    }

    // MARK: - Questions in chat

    @MainActor
    func testQuestionSubject() {
        XCTAssertEqual(AppModel.wikiQuestionSubject(in: "what's the AKM damage?"), "akm")
        XCTAssertEqual(AppModel.wikiQuestionSubject(in: "<@123> how much damage does night's edge do in terraria"), "night's edge terraria")
        XCTAssertNil(AppModel.wikiQuestionSubject(in: "good morning everyone"))
        XCTAssertNil(AppModel.wikiQuestionSubject(in: "what do you all think about the new season of the show we watched?"))
    }

    // MARK: - WebUI parity

    func testWebStarterListMatchesNative() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)
        for starter in WikiSource.starters {
            XCTAssertTrue(html.contains("baseURL: '\(starter.baseURL)', apiPath: '\(starter.apiPath)'"), starter.name)
        }
    }
}
