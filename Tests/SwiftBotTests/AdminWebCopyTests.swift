import XCTest

final class AdminWebCopyTests: XCTestCase {
    func testSweepWebCreationCopyIsNativeFirst() throws {
        let adminHTML = try XCTUnwrap(
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "admin")
        )
        let html = try String(contentsOf: adminHTML, encoding: .utf8)

        XCTAssertTrue(html.contains("Create and edit Sweep rules in the macOS app."))
        XCTAssertFalse(html.contains("Web parity will follow"))
    }
}
