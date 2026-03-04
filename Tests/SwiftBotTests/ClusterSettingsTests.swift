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
        
        // Refinement from Codex: Verify promoted status copy = "Primary (Promoted)"
        XCTAssertEqual(snapshot.workerStatusText, "Primary (Promoted)")
        
        let mode = await coordinator.testCurrentMode()
        XCTAssertEqual(mode, .leader)
        XCTAssertEqual(mode.displayName, "Primary")
    }
}
