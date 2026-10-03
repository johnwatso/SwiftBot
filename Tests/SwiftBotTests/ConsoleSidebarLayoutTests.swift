import XCTest
@testable import SwiftBot

final class ConsoleSidebarLayoutTests: XCTestCase {
    func testEveryConsoleItemAppearsExactlyOnce() {
        let listed = ConsoleItem.sidebarSections.flatMap(\.items)
        XCTAssertEqual(listed.count, ConsoleItem.allCases.count)
        for item in ConsoleItem.allCases {
            XCTAssertEqual(listed.filter { $0 == item }.count, 1, "\(item.rawValue) must appear exactly once")
        }
        XCTAssertEqual(ConsoleItem.sidebarSections.map(\.title), ["Server", "Services"])
    }
}
