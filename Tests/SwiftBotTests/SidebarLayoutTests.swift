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

    func testSidebarSectionsAreTitledAndPopulated() {
        XCTAssertFalse(SidebarItem.sidebarSections.isEmpty)
        for section in SidebarItem.sidebarSections {
            XCTAssertFalse(section.title.isEmpty, "A sidebar section has no title")
            XCTAssertFalse(section.items.isEmpty, "Sidebar section \(section.title) has no rows")
        }
    }

    func testRewindSitsWithTheOtherAnalyticsSurfaces() {
        let system = SidebarItem.sidebarSections.first { $0.title == "System" }
        let items = try? XCTUnwrap(system).items
        XCTAssertEqual(items?.contains(.rewind), true)
        XCTAssertEqual(items?.contains(.analytics), true)
    }
}
