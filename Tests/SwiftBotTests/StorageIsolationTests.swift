import XCTest
@testable import SwiftBot

/// The test bundle is hosted by `SwiftBot.app`, so the suite runs with the same
/// bundle identifier and the same Application Support directory as the real
/// bot. Before this was isolated, any test that built an `AppModel` wrote over
/// the live `settings.json`, discord cache and session history.
final class StorageIsolationTests: XCTestCase {

    func testStorageDoesNotResolveToTheLiveApplicationSupportDirectory() throws {
        let folder = SwiftBotStorage.folderURL()
        let live = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent(SwiftBotStorage.appFolderName, isDirectory: true)

        XCTAssertNotEqual(
            folder.standardizedFileURL,
            live.standardizedFileURL,
            "tests are writing to the real SwiftBot data directory"
        )
        XCTAssertFalse(
            folder.standardizedFileURL.path.hasPrefix(live.standardizedFileURL.path),
            "tests are writing inside the real SwiftBot data directory"
        )
    }

    /// Stores that resolve Application Support themselves opt out of the
    /// redirection above, which is exactly how the live automations file
    /// stayed reachable from tests.
    @MainActor
    func testStoresThatKeepTheirOwnPathsStayInsideTheTestDirectory() {
        let root = SwiftBotStorage.folderURL().standardizedFileURL.path
        XCTAssertTrue(
            AutomationStore.defaultFileURL().standardizedFileURL.path.hasPrefix(root),
            "AutomationStore resolved its own Application Support path"
        )
    }

    /// Every store in a process must agree on the directory, or one will write
    /// state another cannot read back.
    func testStorageDirectoryIsStableWithinTheProcess() {
        XCTAssertEqual(SwiftBotStorage.folderURL(), SwiftBotStorage.folderURL())
    }
}
