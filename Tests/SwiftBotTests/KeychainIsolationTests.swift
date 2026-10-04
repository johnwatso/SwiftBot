import XCTest
@testable import SwiftBot

/// Tests run inside SwiftBot.app and share the developer's login Keychain. These
/// guard the in-memory store that keeps them off it: on 2026-09-15 a test run
/// saved blank settings and deleted the bot's real secrets.
final class KeychainIsolationTests: XCTestCase {
    func testHelperUsesInMemoryStoreUnderXCTest() {
        XCTAssertTrue(KeychainHelper.isRunningUnderXCTest)
        let before = KeychainHelper.realKeychainAccessCount.load(ordering: .relaxed)
        let account = "keychain-isolation-\(UUID().uuidString)"

        XCTAssertTrue(KeychainHelper.save("secret", account: account))
        XCTAssertEqual(KeychainHelper.load(account: account), "secret")
        XCTAssertTrue(KeychainHelper.update(Data("rotated".utf8), account: account))
        XCTAssertEqual(KeychainHelper.load(account: account), "rotated")
        XCTAssertTrue(KeychainHelper.delete(account: account))
        XCTAssertNil(KeychainHelper.load(account: account))

        XCTAssertEqual(KeychainHelper.realKeychainAccessCount.load(ordering: .relaxed), before)
    }

    /// The exact path that wiped the secrets: saving settings whose secrets are
    /// blank because they were never loaded.
    func testSavingBlankSettingsNeverReachesTheRealKeychain() async throws {
        let before = KeychainHelper.realKeychainAccessCount.load(ordering: .relaxed)
        let store = ConfigStore(filename: "keychain-isolation-\(UUID().uuidString).json")
        try await store.save(BotSettings())
        XCTAssertEqual(KeychainHelper.realKeychainAccessCount.load(ordering: .relaxed), before)
    }
}
