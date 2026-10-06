import XCTest
@testable import SwiftBot

/// Stopping a Primary is not a demotion. `ClusterCoordinator.stopAll()` runs the
/// demotion handler to close output, which used to leave the runtime role at
/// Standby and lock every settings page as "managed by the Primary node".
@MainActor
final class PrimaryStopRoleTests: XCTestCase {
    private func runningPrimary(port: Int) async -> AppModel {
        let model = AppModel()
        model.settings.clusterMode = .leader
        await model.configureMeshRecovery()
        await model.cluster.applySettings(mode: .leader, nodeName: "StopTest", leaderAddress: "", listenPort: port, sharedSecret: "mesh")
        model.clusterSnapshot = await model.cluster.currentSnapshot()
        model.lastPublishedRole = model.clusterSnapshot.mode
        return model
    }

    func testStoppedPrimaryKeepsItsRoleAndStaysEditable() async {
        let model = await runningPrimary(port: 48191)
        XCTAssertEqual(model.runtimeClusterMode, .leader)
        XCTAssertFalse(model.isFailoverManagedNode)

        await model.stopBot()

        XCTAssertEqual(model.runtimeClusterMode, .leader)
        XCTAssertFalse(model.isFailoverManagedNode)
    }

    /// With Ruru configured, Stop releases the lease. The released deadline
    /// must not later read as "ownership expired" and lock the console.
    func testStoppedPrimaryWithWitnessLeaseDoesNotLockAfterRelease() async {
        let model = await runningPrimary(port: 48192)
        await model.updateMeshOwnershipDeadline(ContinuousClock.now.advanced(by: .milliseconds(50)))

        await model.stopBot()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(model.meshOwnershipDeadline)
        XCTAssertFalse(model.meshOwnershipExpired)
        XCTAssertFalse(model.isFailoverManagedNode)
    }

    /// A running Primary that loses its lease must still lock.
    func testExpiredLeaseOnRunningPrimaryStillLocks() async {
        let model = await runningPrimary(port: 48193)
        await model.updateMeshOwnershipDeadline(ContinuousClock.now)
        XCTAssertTrue(model.meshOwnershipExpired)
        XCTAssertTrue(model.isFailoverManagedNode)
        await model.stopBot()
    }
}

/// Pair SwiftBot opens the Join Code on whichever Mac is browsing. If that is
/// the Primary itself, joining would demote it into a Fail Over of itself.
@MainActor
final class SwiftMeshSelfJoinTests: XCTestCase {
    func testPrimaryRefusesItsOwnJoinCode() async throws {
        let model = AppModel()
        model.settings.clusterMode = .leader
        model.settings.clusterSharedSecret = "primary-secret"
        let bundle = SwiftMeshJoinBundle(leaderAddresses: ["10.0.0.2"], leaderPort: 38787, sharedSecret: "primary-secret")
        let code = "swiftmesh://join?b=" + (try JSONEncoder().encode(bundle)).base64EncodedString()

        let result = await model.applySwiftMeshJoinCode(code)

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("Primary that made this Join Code"))
        XCTAssertEqual(model.settings.clusterMode, .leader)
    }

    /// The WebUI shows Ruru's host and state only; never its secrets.
    func testWebPayloadCarriesWitnessDisplayStateOnly() throws {
        let witness = AdminWebSwiftMeshPayload.Witness(host: "ruru.example.com", health: "ready", leaseHeld: true)
        let json = String(decoding: try JSONEncoder().encode(witness), as: UTF8.self)
        let keys = Set((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]).keys)
        XCTAssertTrue(keys.isSubset(of: ["host", "health", "leaseHeld", "preferenceStatus", "preferredPrimary", "preferredIsThisMac", "currentOwner"]), "\(keys)")
        for secret in ["token", "clusterID", "endpoint"] { XCTAssertFalse(json.contains(secret)) }
        XCTAssertEqual(MeshWitnessHealth.recovering.webValue, "recovering")
    }
}
