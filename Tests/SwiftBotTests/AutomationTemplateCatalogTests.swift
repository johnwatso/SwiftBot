import XCTest
@testable import SwiftBot

final class AutomationTemplateCatalogTests: XCTestCase {
    func testEveryTemplateValidates() {
        for template in AutomationTemplate.catalog {
            XCTAssertNoThrow(try template.rule.validate(), "Template \(template.id) does not validate")
            XCTAssertFalse(template.rule.steps.isEmpty, "Template \(template.id) has no steps")
        }
    }

    func testTemplateIDsAreUnique() {
        let ids = AutomationTemplate.catalog.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate template IDs: \(ids)")
    }

    func testTemplatesSitInTheirCatalogsCategory() {
        for category in Automations.Category.allCases {
            for template in AutomationTemplate.catalog(for: category) {
                XCTAssertEqual(template.rule.category, category, "Template \(template.id) is in the wrong catalog")
                XCTAssertTrue(
                    Automations.TriggerKind.visibleCases(for: category).contains(template.rule.trigger.kind),
                    "Template \(template.id) uses a trigger the \(category) editor can't show"
                )
            }
        }
    }

    // An empty inChannel filter matches every channel, so a template that
    // relies on the user picking channels must not start enabled.
    func testTemplatesNeedingAChannelStartDisabled() {
        for template in AutomationTemplate.catalog {
            let needsChannel = template.rule.filters.contains { $0.kind == .inChannel && ($0.channelIds ?? []).isEmpty }
            if needsChannel {
                XCTAssertFalse(template.rule.enabled, "Template \(template.id) would act on every channel until configured")
            }
        }
    }
}
