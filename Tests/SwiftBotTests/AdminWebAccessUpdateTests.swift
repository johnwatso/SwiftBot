import XCTest
@testable import SwiftBot

final class AdminWebAccessUpdateTests: XCTestCase {
    private let me = "412378964087275541"
    private let other = "280129381292318720"

    private func update(_ restrict: Bool, _ ids: [String]) -> AdminWebAccessUpdate {
        AdminWebAccessUpdate(restrictToListedUsers: restrict, allowedUserIDs: ids)
    }

    func testListThatIncludesTheEditorPasses() {
        XCTAssertNoThrow(try update(true, [me, other]).validate(editorUserID: me))
    }

    func testCannotTurnOnWithAnEmptyList() {
        XCTAssertThrowsError(try update(true, ["  "]).validate(editorUserID: me)) { error in
            XCTAssertEqual(error as? AdminWebAccessUpdate.GuardFailure, .emptyList)
        }
    }

    func testCannotLockYourselfOut() {
        XCTAssertThrowsError(try update(true, [other]).validate(editorUserID: me)) { error in
            XCTAssertEqual(error as? AdminWebAccessUpdate.GuardFailure, .selfLockout)
        }
    }

    // The password fallback never goes through the list, so a local admin can
    // hand access over to Discord accounts without listing themselves.
    func testLocalFallbackAdminIsNotSubjectToTheList() {
        XCTAssertNoThrow(try update(true, [other]).validate(editorUserID: "local:admin"))
    }

    // With the list off, server managers decide access, so a list that leaves
    // the editor out is harmless and is kept for next time.
    func testListIsFreeToEditWhileOff() {
        XCTAssertNoThrow(try update(false, [other]).validate(editorUserID: me))
        XCTAssertNoThrow(try update(false, []).validate(editorUserID: me))
    }

    func testRejectsThingsThatAreNotDiscordIDs() {
        XCTAssertThrowsError(try update(false, ["jonwatso"]).validate(editorUserID: me)) { error in
            XCTAssertEqual(error as? AdminWebAccessUpdate.GuardFailure, .invalidID)
        }
    }

    func testNormalisesWhitespaceAndDuplicates() {
        XCTAssertEqual(update(true, [" \(me) ", me, "", other]).normalizedIDs, [me, other])
    }
}
