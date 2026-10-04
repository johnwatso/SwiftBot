import Foundation
import Synchronization

/// The only place SwiftBot touches the Keychain (`SecItem*`). Keep it that way:
/// the XCTest gate below only protects calls that come through here.
enum KeychainHelper {
    private static let service = "com.swiftbot.app"
    private static let account = "discord-token"

    /// Tests are hosted by SwiftBot.app and share the login Keychain. Under
    /// XCTest `AppModel` skips loading settings, so a settings save sees every
    /// secret as changed to empty and deletes it: on 2026-09-15 a test run wiped
    /// the bot's real Discord, Cloudflare and WebUI secrets that way. Tests get
    /// an in-memory store instead and never reach `SecItem*`.
    nonisolated static let isRunningUnderXCTest: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil

    private static let testStore = Mutex<[String: Data]>([:])

    #if DEBUG
    /// Real `SecItem*` calls made by this process; `KeychainIsolationTests`
    /// asserts it stays 0 under XCTest.
    static let realKeychainAccessCount = Atomic<Int>(0)
    private static func noteRealAccess() { realKeychainAccessCount.add(1, ordering: .relaxed) }
    #else
    private static func noteRealAccess() {}
    #endif

    /// Saves the token to the Keychain.
    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        save(token, account: account)
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        if isRunningUnderXCTest {
            testStore.withLock { $0[account] = data }
            return true
        }
        noteRealAccess()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        // Delete any existing item before saving the new one.
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Writes in place rather than delete-then-add, so a failure (Keychain
    /// locked, say) can't lose the existing item. Used for passkeys.
    @discardableResult
    static func update(_ data: Data, account: String) -> Bool {
        if isRunningUnderXCTest {
            testStore.withLock { $0[account] = data }
            return true
        }
        noteRealAccess()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Retrieves the token from the Keychain.
    static func loadToken() -> String? {
        load(account: account)
    }

    static func load(account: String) -> String? {
        if isRunningUnderXCTest {
            return testStore.withLock { $0[account] }.flatMap { String(data: $0, encoding: .utf8) }
        }
        noteRealAccess()

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }

        return nil
    }

    /// Deletes the token from the Keychain.
    @discardableResult
    static func deleteToken() -> Bool {
        delete(account: account)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        if isRunningUnderXCTest {
            return testStore.withLock { $0.removeValue(forKey: account) } != nil
        }
        noteRealAccess()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
}
