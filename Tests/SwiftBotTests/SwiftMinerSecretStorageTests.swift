import XCTest
@testable import SwiftBot

/// SwiftMiner's pairing (API key and webhook HMAC secret) lives in the
/// Keychain like every other secret: never in settings.json, which is copied
/// to SwiftMesh nodes and into backups.
final class SwiftMinerSecretStorageTests: XCTestCase {
    private let apiKeyAccount = "swiftminer-api-key"
    private let webhookSecretAccount = "swiftminer-webhook-secret"
    private var filename = ""

    override func setUp() {
        super.setUp()
        filename = "settings-swiftminer-\(UUID().uuidString).json"
        KeychainHelper.delete(account: apiKeyAccount)
        KeychainHelper.delete(account: webhookSecretAccount)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        KeychainHelper.delete(account: apiKeyAccount)
        KeychainHelper.delete(account: webhookSecretAccount)
        super.tearDown()
    }

    private var fileURL: URL { SwiftBotStorage.folderURL().appendingPathComponent(filename) }

    private func fileText() throws -> String {
        String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
    }

    private func pairedSettings() -> BotSettings {
        var settings = BotSettings()
        settings.swiftMiner.apiKey = "miner-api-key-123"
        settings.swiftMiner.webhookSecret = "miner-hmac-secret-456"
        return settings
    }

    func testSaveKeepsSecretsOutOfTheFile() async throws {
        let store = ConfigStore(filename: filename)
        _ = await store.load()
        try await store.save(pairedSettings())

        let text = try fileText()
        XCTAssertFalse(text.contains("miner-api-key-123"))
        XCTAssertFalse(text.contains("miner-hmac-secret-456"))
        XCTAssertEqual(KeychainHelper.load(account: apiKeyAccount), "miner-api-key-123")
        XCTAssertEqual(KeychainHelper.load(account: webhookSecretAccount), "miner-hmac-secret-456")

        let reloaded = await ConfigStore(filename: filename).load()
        XCTAssertEqual(reloaded.swiftMiner.apiKey, "miner-api-key-123")
        XCTAssertEqual(reloaded.swiftMiner.webhookSecret, "miner-hmac-secret-456")
        XCTAssertTrue(reloaded.swiftMiner.isPaired)
    }

    func testPlaintextFromAnOlderBuildMovesIntoTheKeychainOnLoad() async throws {
        // What an older build wrote: the pairing in plain text.
        let legacy = try JSONEncoder().encode(pairedSettings())
        try legacy.write(to: fileURL)
        XCTAssertTrue(try fileText().contains("miner-hmac-secret-456"))

        let loaded = await ConfigStore(filename: filename).load()

        XCTAssertEqual(loaded.swiftMiner.apiKey, "miner-api-key-123")
        XCTAssertEqual(loaded.swiftMiner.webhookSecret, "miner-hmac-secret-456")
        XCTAssertEqual(KeychainHelper.load(account: webhookSecretAccount), "miner-hmac-secret-456")
        // Rewritten straight away rather than at the next save.
        XCTAssertFalse(try fileText().contains("miner-hmac-secret-456"))
        XCTAssertFalse(try fileText().contains("miner-api-key-123"))
    }

    func testPlaintextOnDiskWinsOverAnOlderKeychainValue() async throws {
        // A Standby receiving a re-paired Primary's file from an older build.
        KeychainHelper.save("old-key", account: apiKeyAccount)
        try JSONEncoder().encode(pairedSettings()).write(to: fileURL)

        let loaded = await ConfigStore(filename: filename).load()

        XCTAssertEqual(loaded.swiftMiner.apiKey, "miner-api-key-123")
        XCTAssertEqual(KeychainHelper.load(account: apiKeyAccount), "miner-api-key-123")
    }

    func testDisconnectingRemovesTheKeychainItems() async throws {
        let store = ConfigStore(filename: filename)
        _ = await store.load()
        try await store.save(pairedSettings())

        var disconnected = pairedSettings()
        disconnected.swiftMiner.apiKey = ""
        disconnected.swiftMiner.webhookSecret = ""
        try await store.save(disconnected)

        XCTAssertNil(KeychainHelper.load(account: apiKeyAccount))
        XCTAssertNil(KeychainHelper.load(account: webhookSecretAccount))
    }

    func testApplyingAPairingStampsTheChangeDate() {
        var settings = SwiftMinerSettings()
        XCTAssertNil(settings.credentialsUpdatedAt)
        settings.apply(pairingBundle: SwiftMinerPairingBundle(endpoint: "http://127.0.0.1:8080", apiKey: "k", hmacSecret: "s", webhookHint: ""))
        XCTAssertNotNil(settings.credentialsUpdatedAt, "A Standby relies on this to know it must pull the new pairing")
    }
}
