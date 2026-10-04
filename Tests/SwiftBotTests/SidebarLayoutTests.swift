import XCTest
@testable import SwiftBot

/// The native sidebar is the mirror of `AdminWebCopyTests`: that suite proves
/// every `SidebarItem` reaches the web UI, this one proves it reaches the app.
///
/// Written after Rewind shipped with an enum case and a detail view but no
/// sidebar row — it compiled, the web UI rendered it, and the section was simply
/// unreachable in the app.
final class SidebarLayoutTests: XCTestCase {
    private var listed: [SidebarItem] { SidebarItem.sidebarSections.flatMap(\.items) }

    func testEveryNativePageIsReachableFromTheSidebar() {
        for item in SidebarItem.allCases where !SidebarItem.webOnlyItems.contains(item) {
            XCTAssertTrue(
                listed.contains(item),
                "\(item.rawValue) has no sidebar row — it is unreachable in the app"
            )
        }
    }

    /// Feature pages are managed in the WebUI; the native sidebar is the host console.
    func testWebOnlyPagesAreNotListed() {
        for item in SidebarItem.webOnlyItems {
            XCTAssertFalse(listed.contains(item), "\(item.rawValue) is WebUI-only but still has a sidebar row")
        }
    }

    func testNoPageIsBothWebOnlyAndNativeOnly() {
        XCTAssertTrue(SidebarItem.webOnlyItems.isDisjoint(with: SidebarItem.nativeOnlyItems))
    }

    func testNoSidebarItemIsListedTwice() {
        XCTAssertEqual(Set(listed).count, listed.count, "A sidebar item appears in more than one section")
    }

    func testSidebarSectionsArePopulated() {
        XCTAssertFalse(SidebarItem.sidebarSections.isEmpty)
        for section in SidebarItem.sidebarSections {
            XCTAssertFalse(section.items.isEmpty, "Sidebar section \(section.id) has no rows")
        }
    }

    func testConsoleOpensOnOverview() {
        XCTAssertEqual(listed.first, .overview)
    }
}
