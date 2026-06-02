import XCTest
@testable import SwiftBot

final class ClusterSettingsTests: XCTestCase {

    // MARK: - Terminology and Label Mapping

    func testClusterModeDisplayNameMapping() {
        XCTAssertEqual(ClusterMode.standalone.displayName, "Standalone")
        XCTAssertEqual(ClusterMode.leader.displayName, "Primary")
        XCTAssertEqual(ClusterMode.worker.displayName, "Worker")
        XCTAssertEqual(ClusterMode.standby.displayName, "Fail Over")
    }

    func testClusterModeDescriptionUpdates() {
        XCTAssertTrue(ClusterMode.leader.description.contains("Primary node"), "Leader description must use Primary terminology")
        XCTAssertTrue(ClusterMode.standby.description.contains("Fail Over node"), "Standby description must use Fail Over terminology")
        XCTAssertTrue(ClusterMode.worker.description.contains("Primary node"), "Worker description must use Primary terminology")
    }

    // MARK: - Persistence and Compatibility

    func testClusterModeCodableStability() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for mode in ClusterMode.allCases {
            let data = try! encoder.encode(mode)
            let decoded = try decoder.decode(ClusterMode.self, from: data)
            XCTAssertEqual(mode, decoded, "Round-trip encoding must preserve internal enum cases")
            
            // Verify raw value remains stable for persistence (e.g. "Standby")
            let rawString = try decoder.decode(String.self, from: data)
            XCTAssertEqual(mode.rawValue, rawString)
        }
    }

    func testLegacyDecodingCompatibility() throws {
        let decoder = JSONDecoder()
        
        // Test "Leader" maps to .leader
        let leaderJson = "\"Leader\"".data(using: .utf8)!
        let decodedLeader = try decoder.decode(ClusterMode.self, from: leaderJson)
        XCTAssertEqual(decodedLeader, .leader)

        // Test "Standby" maps to .standby
        let standbyJson = "\"Standby\"".data(using: .utf8)!
        let decodedStandby = try decoder.decode(ClusterMode.self, from: standbyJson)
        XCTAssertEqual(decodedStandby, .standby)
    }

    func testSwiftMeshConfigDoesNotPersistSharedSecretToDisk() async throws {
        let account = "cluster-shared-secret"
        let previousSecret = KeychainHelper.load(account: account)
        defer {
            if let previousSecret {
                KeychainHelper.save(previousSecret, account: account)
            } else {
                KeychainHelper.delete(account: account)
            }
        }

        let filename = "swiftmesh-config-\(UUID().uuidString).json"
        let store = SwiftMeshConfigStore(filename: filename)
        let fileURL = SwiftBotStorage.folderURL().appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let secret = "super-secret-mesh-key"
        try await store.save(
            SwiftMeshSettings(
                mode: .leader,
                nodeName: "Primary",
                leaderAddress: "",
                leaderPort: 38787,
                listenPort: 38787,
                sharedSecret: secret,
                leaderTerm: 7
            )
        )

        let data = try Data(contentsOf: fileURL)
        let fileText = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(fileText.contains(secret), "Mesh shared secret must not be written to the config file")

        let decoded = try JSONDecoder().decode(SwiftMeshSettings.self, from: data)
        XCTAssertEqual(decoded.sharedSecret, "")
        XCTAssertEqual(KeychainHelper.load(account: account), secret)
    }

    func testSwiftMeshConfigLoadMigratesLegacyFileSecretToKeychainAndScrubsDisk() async throws {
        let account = "cluster-shared-secret"
        let previousSecret = KeychainHelper.load(account: account)
        defer {
            if let previousSecret {
                KeychainHelper.save(previousSecret, account: account)
            } else {
                KeychainHelper.delete(account: account)
            }
        }
        KeychainHelper.delete(account: account)

        let filename = "swiftmesh-config-\(UUID().uuidString).json"
        let store = SwiftMeshConfigStore(filename: filename)
        let fileURL = SwiftBotStorage.folderURL().appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let legacySecret = "legacy-file-secret"
        let legacySettings = SwiftMeshSettings(
            mode: .standby,
            nodeName: "Failover",
            leaderAddress: "http://primary.local:38787",
            leaderPort: 38787,
            listenPort: 38787,
            sharedSecret: legacySecret,
            leaderTerm: 3
        )
        let legacyData = try JSONEncoder().encode(legacySettings)
        try legacyData.write(to: fileURL, options: .atomic)

        let loaded = await store.load()

        XCTAssertEqual(loaded?.sharedSecret, legacySecret)
        XCTAssertEqual(KeychainHelper.load(account: account), legacySecret)

        let scrubbedData = try Data(contentsOf: fileURL)
        let scrubbedText = String(data: scrubbedData, encoding: .utf8) ?? ""
        XCTAssertFalse(scrubbedText.contains(legacySecret), "Legacy mesh secret must be removed from disk after load")
        let scrubbed = try JSONDecoder().decode(SwiftMeshSettings.self, from: scrubbedData)
        XCTAssertEqual(scrubbed.sharedSecret, "")
    }

    // MARK: - Snapshot and Promotion Terminology

    func testClusterSnapshotPromotionTerminology() async {
        let coordinator = ClusterCoordinator()
        
        // Setup as Fail Over (standby)
        await coordinator.applySettings(
            mode: .standby,
            nodeName: "TestFailOver",
            leaderAddress: "http://127.0.0.1:39999",
            listenPort: 38888,
            sharedSecret: "test-secret",
            leaderTerm: 0
        )
        
        // Simulate promotion
        for _ in 0..<3 {
            await coordinator.testSimulateLeaderHealthMiss()
        }
        
        let snapshot = await coordinator.testCurrentSnapshot()
        
        // Refinement from Codex: Verify promoted status copy contains "Primary"
        XCTAssertTrue(snapshot.workerStatusText.contains("Primary"), "Status should contain 'Primary', got: \(snapshot.workerStatusText)")
        
        let mode = await coordinator.testCurrentMode()
        XCTAssertEqual(mode, .leader)
        XCTAssertEqual(mode.displayName, "Primary")
    }

    // MARK: - Worker Mode Disable (UX Hotfix)

    @MainActor
    func testWorkerModeRuntimeGuard() async {
        let app = AppModel()
        // Manually set to worker (simulating legacy settings or manual override)
        app.settings.clusterMode = .worker
        
        await app.startBot()
        
        // Verify that the bot did not start and log message was added
        XCTAssertEqual(app.status, .stopped)
        XCTAssertTrue(app.logs.lines.contains { $0.contains("Worker mode is temporarily unavailable") })
    }

    @MainActor
    func testWorkerModeMigrationFlag() async {
        let app = AppModel()
        // By default on a clean init (or matching current store), it should be false
        // (unless the test machine has a legacy settings.json with worker mode)
        // This just proves the property exists and is accessible.
        XCTAssertFalse(app.workerModeMigrated)
    }
}
