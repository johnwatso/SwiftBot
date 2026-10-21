import XCTest
import RuruClient
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


    func testStandbyServicesHaveAnActiveRuntimeWithoutDiscord() {
        let model = AppModel()
        model.settings.clusterMode = .standby
        model.lastPublishedRole = .standby
        model.status = .stopped
        model.clusterSnapshot.serverState = .listening

        XCTAssertTrue(model.consoleHasActiveBotRuntime)
        XCTAssertEqual(model.consoleStopTitle, "Stop Standby Services")
        XCTAssertTrue(model.consoleStopMessage.contains("peer sync"))

        model.clusterSnapshot.serverState = .stopped
        XCTAssertFalse(model.consoleHasActiveBotRuntime)
        XCTAssertEqual(model.consoleStartTitle, "Start Standby Services")
    }

    func testPromotedBackupStopsBotRatherThanOnlyItsWatch() {
        let model = AppModel()
        model.settings.clusterMode = .standby
        model.lastPublishedRole = .leader
        model.status = .running

        XCTAssertTrue(model.consoleHasActiveBotRuntime)
        XCTAssertEqual(model.consoleStopTitle, "Stop Bot")
        XCTAssertTrue(model.consoleStopMessage.contains("disconnects from Discord"))
        XCTAssertTrue(model.consoleRestartMessage.contains("may take over"))
        XCTAssertFalse(model.isFailoverManagedNode)
    }

    func testConfiguredPrimaryWaitingForOwnershipCanStopRecovery() {
        let model = AppModel()
        model.settings.clusterMode = .leader
        model.lastPublishedRole = .standby
        model.status = .stopped
        model.clusterSnapshot.isOwnershipRecoveryActive = true

        XCTAssertTrue(model.consoleHasActiveBotRuntime)
        XCTAssertEqual(model.consoleStartTitle, "Retry Start")
        XCTAssertEqual(model.consoleStopTitle, "Stop Recovery")
        XCTAssertTrue(model.consoleStopMessage.contains("current owner"))
        XCTAssertTrue(model.isFailoverManagedNode)
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

    func testPublicLivenessCarriesOnlyOptionalRuruDisplayFacts() throws {
        var live = AdminWebLivePayload(status: "offline", discordConnected: false, clusterMode: "Standby",
                                       runtimeState: "idle", botUsername: "Example", generatedAt: Date())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(live)) as? [String: Any])
        XCTAssertNil(json["ruruHealth"], "Old payloads omit optional Ruru fields")
        live.ruruHealth = "unreachable"
        live.ruruLeaseValid = false
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(live)) as? [String: Any])
        XCTAssertEqual(json["ruruHealth"] as? String, "unreachable")
        XCTAssertEqual(json["ruruLeaseValid"] as? Bool, false)
        for key in ["token", "clusterID", "endpoint", "host"] { XCTAssertNil(json[key]) }
    }
}

@MainActor
final class TakeoverApplicationReadinessTests: XCTestCase {
    private func lease(nodeID: String) async throws -> RuruLease {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TakeoverLeaseFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = RuruLeaseClient(configuration: .init(endpoint: URL(string: "https://lease-fixture.invalid")!,
            clusterID: "fixture", nodeID: nodeID, token: String(repeating: "t", count: 43)), session: session)
        return try await client.acquire()
    }

    func testConfigurationInstallBlocksPromotionBeforeReadingOtherStores() async {
        let model = AppModel()
        model.meshConfigurationSyncsInFlight = 1
        let reason = await model.meshPromotionReadiness()
        XCTAssertEqual(reason, "shared configuration or credentials are being installed")
    }

    func testOldConnectionCannotReplaceTheCurrentLeaseOrDeadline() async throws {
        let model = AppModel()
        let grant = try await lease(nodeID: "fixture-node")
        let oldGeneration = model.ruruConnectionGeneration
        model.ruruConnectionGeneration = UUID()
        let deadline = ContinuousClock.now + .seconds(1)
        let installed = await model.installRuruLease(grant, generation: model.ruruConnectionGeneration, deadline: deadline)
        XCTAssertTrue(installed)
        let stale = await model.installRuruLease(grant, generation: oldGeneration, deadline: grant.deadline)
        XCTAssertFalse(stale)
        XCTAssertEqual(model.currentRuruLease, grant)
        XCTAssertEqual(model.meshOwnershipDeadline, deadline)
    }

    func testRepeatedConnectionSetupPreservesAnUnexpiredLocalGrant() async throws {
        let previous = MeshWitnessSettingsStore.load()
        defer { _ = MeshWitnessSettingsStore.save(previous) }
        let witness = MeshWitnessConfiguration(endpoint: "https://lease-fixture.invalid", clusterID: "fixture",
            token: String(repeating: "t", count: 43))
        XCTAssertTrue(MeshWitnessSettingsStore.save(witness))
        let model = AppModel()
        model.settings.clusterMode = .leader
        await model.cluster.setDesiredBotRunning(false)
        await model.configureMeshRecovery() // Standalone runtime: no network acquisition.
        let grant = try await lease(nodeID: model.meshLocalNodeID)
        let generation = model.ruruConnectionGeneration
        let installed = await model.installRuruLease(grant, generation: generation, deadline: grant.deadline)
        XCTAssertTrue(installed)
        await model.configureMeshRecovery()
        XCTAssertEqual(model.ruruConnectionGeneration, generation)
        XCTAssertEqual(model.currentRuruLease, grant)
        XCTAssertEqual(model.meshOwnershipDeadline, grant.deadline)
        // The fixture coordinator has never acquired term 9, so teardown cannot
        // send a release to the non-fixture transport created by setup.
        await model.stopBot()
    }

    func testCorruptRulesRemainVisibleAsALoadFailure() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("automations.json")
        try Data("damaged rules".utf8).write(to: file)
        let store = AutomationStore(fileURL: file)
        store.load()
        XCTAssertTrue(store.isLoaded)
        XCTAssertTrue(store.hasLoadFailure)
        try Data("[]".utf8).write(to: file)
        store.load()
        XCTAssertFalse(store.hasLoadFailure)
    }
}

private final class TakeoverLeaseFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "lease-fixture.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        // RuruLeaseClient may supply the body as an input stream.
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            data = body
        } else { data = Data() }
        let node = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["nodeID"] as? String ?? "invalid"
        let body = try! JSONSerialization.data(withJSONObject: ["ownerNodeID": node, "term": 9, "expiresInSeconds": 30])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
