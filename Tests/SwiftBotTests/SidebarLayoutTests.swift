import XCTest
@testable import SwiftBot

/// The native sidebar is the mirror of `AdminWebCopyTests`: that suite proves
/// every `SidebarItem` reaches the web UI, this one proves it reaches the app.
///
/// Written after Rewind shipped with an enum case and a detail view but no
/// sidebar row — it compiled, the web UI rendered it, and the section was simply
/// unreachable in the app.
final class SidebarLayoutTests: XCTestCase {
    func testEverySidebarItemIsReachableFromTheSidebar() {
        let listed = SidebarItem.sidebarSections.flatMap(\.items)

        for item in SidebarItem.allCases {
            XCTAssertTrue(
                listed.contains(item),
                "\(item.rawValue) has no sidebar row — it is unreachable in the app"
            )
        }
    }

    func testNoSidebarItemIsListedTwice() {
        let listed = SidebarItem.sidebarSections.flatMap(\.items)
        XCTAssertEqual(Set(listed).count, listed.count, "A sidebar item appears in more than one section")
    }

    func testSidebarSectionsArePopulated() {
        XCTAssertFalse(SidebarItem.sidebarSections.isEmpty)
        for section in SidebarItem.sidebarSections {
            XCTAssertFalse(section.items.isEmpty, "Sidebar section \(section.id) has no rows")
        }
    }

    /// Only the leading Overview group goes without a header; every other
    /// group needs one to read as a group.
    func testOnlyOverviewIsUntitled() {
        let untitled = SidebarItem.sidebarSections.filter { $0.title?.isEmpty ?? true }
        XCTAssertEqual(untitled.map(\.items), [[.overview]])
        XCTAssertEqual(SidebarItem.sidebarSections.first?.items, [.overview])
    }

    func testRewindSitsWithTheOtherAnalyticsSurfaces() {
        let system = SidebarItem.sidebarSections.first { $0.title == "System" }
        let items = try? XCTUnwrap(system).items
        XCTAssertEqual(items?.contains(.rewind), true)
        XCTAssertEqual(items?.contains(.analytics), true)
    }
}
