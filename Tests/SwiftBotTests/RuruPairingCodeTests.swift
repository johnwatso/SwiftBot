import XCTest
@testable import SwiftBot

/// Ruru witness settings, storage and Join Code carriage. Pairing itself uses
/// short codes (`RuruShortCodePairingTests`). Witness settings go through
/// `KeychainHelper`, which is in-memory under XCTest.
@MainActor
final class RuruWitnessSettingsTests: XCTestCase {
    func testWebPairingSharingChoiceRequiresLocalConfirmation() throws {
        let bundle = SwiftMeshJoinBundle(leaderAddresses: ["https://john.example"], leaderPort: 38787,
                                        sharedSecret: "example-only", witness: fixtureConfiguration)
        let payload = try JSONEncoder().encode(bundle).base64EncodedString()
        var link = URLComponents(string: "swiftmesh://join")!
        link.queryItems = [.init(name: "b", value: payload), .init(name: "recordings", value: "1")]
        let url = try XCTUnwrap(link.url)
        let model = AppModel()
        model.isOnboardingComplete = true
        XCTAssertTrue(model.handleSwiftMeshDeepLink(url))
        XCTAssertEqual(SwiftMeshJoinBundle.recordingSharingChoice(from: model.pendingSwiftMeshJoin!.rawCode), true)
        XCTAssertFalse(model.mediaLibrarySettings.sharedLibraryEnabled, "A web handoff only preselects the confirmation")
        model.isOnboardingComplete = false
        link.queryItems = [.init(name: "b", value: payload), .init(name: "recordings", value: "0")]
        XCTAssertTrue(model.handleSwiftMeshDeepLink(try XCTUnwrap(link.url)))
        XCTAssertEqual(SwiftMeshJoinBundle.recordingSharingChoice(from: model.pendingMeshOnboardingCode!), false)
        XCTAssertFalse(model.mediaLibrarySettings.sharedLibraryEnabled)
        XCTAssertEqual(try model.decodeSwiftMeshJoinCode(url.absoluteString).witness, fixtureConfiguration)
        XCTAssertEqual(try model.decodeSwiftMeshJoinCode(url.absoluteString).sharedSecret, "example-only")
    }

    func testLegacyOrAmbiguousWebSharingChoicesDoNotPreselectSharing() {
        XCTAssertNil(SwiftMeshJoinBundle.recordingSharingChoice(from: "swiftmesh://join?b=example"))
        XCTAssertNil(SwiftMeshJoinBundle.recordingSharingChoice(from: "swiftmesh://join?recordings=true"))
        XCTAssertNil(SwiftMeshJoinBundle.recordingSharingChoice(from: "swiftmesh://join?recordings=1&recordings=0"))
        XCTAssertNil(SwiftMeshJoinBundle.recordingSharingChoice(from: "https://john.example/?recordings=1"))
        XCTAssertNil(SwiftMeshJoinBundle.recordingSharingChoice(from: "swiftmesh://other?recordings=1"))
    }

    private let fixtureConfiguration = MeshWitnessConfiguration(
        endpoint: "https://ruru.example.com",
        clusterID: "swiftbot-example",
        token: "EXAMPLE-ONLY-0123456789abcdefghijklmnopqrstuv"
    )

    override func setUp() {
        super.setUp()
        XCTAssertTrue(KeychainHelper.isRunningUnderXCTest)
        MeshWitnessSettingsStore.save(.init())
    }

    override func tearDown() {
        MeshWitnessSettingsStore.save(.init())
        super.tearDown()
    }

    func testConfigurationSavesThroughWitnessStoreWithoutRealKeychain() throws {
        let before = KeychainHelper.realKeychainAccessCount.load(ordering: .relaxed)
        XCTAssertTrue(MeshWitnessSettingsStore.save(fixtureConfiguration))
        XCTAssertEqual(MeshWitnessSettingsStore.load(), fixtureConfiguration)
        XCTAssertEqual(KeychainHelper.realKeychainAccessCount.load(ordering: .relaxed), before)
    }

    func testLoopbackHTTPRemainsAllowedForDevelopment() {
        XCTAssertTrue(MeshWitnessConfiguration.isValidEndpoint("http://127.0.0.1:38990"))
        XCTAssertFalse(MeshWitnessConfiguration.isValidEndpoint("http://ruru.example.com"))
        XCTAssertFalse(MeshWitnessConfiguration.isValidEndpoint("https://user:pass@ruru.example.com"))
    }

    func testInvalidSettingsNeverReplaceExistingOnes() {
        let existing = MeshWitnessConfiguration(endpoint: "https://old.example.com", clusterID: "old", token: String(repeating: "o", count: 40))
        XCTAssertTrue(MeshWitnessSettingsStore.save(existing))
        XCTAssertEqual(MeshWitnessSettingsStore.load(), existing)
        // An invalid configuration is also refused by the store itself.
        XCTAssertFalse(MeshWitnessSettingsStore.save(.init(endpoint: "http://r.example.com", clusterID: "c", token: "short")))
        XCTAssertEqual(MeshWitnessSettingsStore.load(), existing)
    }

    // MARK: Join Code compatibility

    func testJoinCodeCarriesImportedWitness() throws {
        let bundle = SwiftMeshJoinBundle(leaderAddresses: ["https://primary.example.com"], leaderPort: 38787,
                                         sharedSecret: "mesh", leaderTerm: 4, witness: fixtureConfiguration)
        let joinCode = "swiftmesh://join?b=" + (try JSONEncoder().encode(bundle)).base64EncodedString()
        let decoded = try AppModel().decodeSwiftMeshJoinCode(joinCode)
        XCTAssertEqual(decoded.witness, fixtureConfiguration)
        XCTAssertEqual(decoded.leaderTerm, 4)
    }

    func testLegacyJoinCodeWithoutWitnessStillDecodes() throws {
        let legacy = #"{"leaderAddresses":["10.0.0.2"],"leaderPort":38787,"sharedSecret":"mesh"}"#
        let decoded = try AppModel().decodeSwiftMeshJoinCode("swiftmesh://join?b=" + Data(legacy.utf8).base64EncodedString())
        XCTAssertNil(decoded.witness)
        XCTAssertNil(decoded.credentialEnrollment)
        XCTAssertEqual(decoded.leaderTerm, 0)
    }

    func testApplyingJoinCodeInstallsRuruWithoutAnotherPairingCode() async throws {
        let model = AppModel()
        model.settings.clusterListenPort = MeshTestPorts.free()
        model.settings.clusterLeaderTerm = 12
        let localPort = model.settings.clusterListenPort
        let enrollment = try await model.meshCredentialStore.issueGrant(nodeName: "Backup")
        let bundle = SwiftMeshJoinBundle(leaderAddresses: ["https://primary.example.com"], leaderPort: 38787,
                                        sharedSecret: "mesh", leaderTerm: 4,
                                        credentialEnrollment: enrollment, witness: fixtureConfiguration)
        let code = "swiftmesh://join?b=" + (try JSONEncoder().encode(bundle)).base64EncodedString()

        let result = await model.applySwiftMeshJoinCode(code)

        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(MeshWitnessSettingsStore.load(), fixtureConfiguration)
        XCTAssertEqual(model.meshLocalNodeID, enrollment.nodeID)
        XCTAssertEqual(model.settings.clusterMode, .standby)
        XCTAssertEqual(model.settings.clusterListenPort, localPort)
        XCTAssertEqual(model.settings.clusterLeaderTerm, 12, "An invitation cannot lower an existing term")
        let stored = await model.swiftMeshConfigStore.load()
        XCTAssertEqual(stored?.mode, .standby)
        XCTAssertEqual(stored?.leaderAddress, "https://primary.example.com")
        let deadline = await model.meshWitnessClient.leaseDeadline()
        XCTAssertNil(deadline, "Installing Ruru must not acquire its lease")
        await model.stopBot()
    }

    func testIncompleteRuruInvitationPreservesExistingConfiguration() async throws {
        XCTAssertTrue(MeshWitnessSettingsStore.save(fixtureConfiguration))
        let model = AppModel()
        model.settings.clusterMode = .leader
        model.settings.clusterSharedSecret = "original"
        let enrollment = try await model.meshCredentialStore.issueGrant(nodeName: "Backup")
        let bundle = SwiftMeshJoinBundle(leaderAddresses: ["https://primary.example.com"], leaderPort: 38787,
                                        sharedSecret: "new", credentialEnrollment: enrollment,
                                        witness: .init(endpoint: "https://ruru.example.com", clusterID: "c", token: "short"))
        let result = await model.pairSwiftMeshFailover("swiftmesh://join?b=" + (try JSONEncoder().encode(bundle)).base64EncodedString())

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("Ruru settings are incomplete"))
        XCTAssertEqual(MeshWitnessSettingsStore.load(), fixtureConfiguration)
        XCTAssertEqual(model.settings.clusterMode, .leader)
        XCTAssertEqual(model.settings.clusterSharedSecret, "original")
        XCTAssertFalse(model.meshPairingInProgress)
    }

    func testExistingWitnessJSONShapeIsUnchanged() throws {
        // Join Codes from earlier builds embed the witness with these keys.
        let json = #"{"endpoint":"https://w.example.com","clusterID":"c","token":"\#(String(repeating: "t", count: 32))"}"#
        let config = try JSONDecoder().decode(MeshWitnessConfiguration.self, from: Data(json.utf8))
        XCTAssertTrue(config.isValid)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["endpoint", "clusterID", "token"])
    }
}

/// The SwiftMesh map's Ruru chip uses `GET /health`; it never affects ownership.
final class MeshWitnessHealthTests: XCTestCase {
    private func client(status: Int, body: String?) async -> MeshWitnessClient {
        HealthStubURLProtocol.response = body.map { (status, Data($0.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthStubURLProtocol.self]
        let client = MeshWitnessClient(session: URLSession(configuration: configuration))
        await client.configure(.init(endpoint: "https://ruru.example.com/", clusterID: "c", token: String(repeating: "t", count: 32)), nodeID: "node")
        return client
    }

    override func tearDown() {
        HealthStubURLProtocol.response = nil
        HealthStubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testReadyRecoveringAndUnreachable() async {
        let ready = await client(status: 200, body: #"{"ready":true}"#).health()
        XCTAssertEqual(ready, .ready)
        XCTAssertEqual(HealthStubURLProtocol.lastRequest?.url?.absoluteString, "https://ruru.example.com/health")
        XCTAssertEqual(HealthStubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertNil(HealthStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))

        let recovering = await client(status: 503, body: #"{"ready":false}"#).health()
        XCTAssertEqual(recovering, .recovering)
        let failed = await client(status: 503, body: #"{"error":"authority_unavailable"}"#).health()
        XCTAssertEqual(failed, .unreachable)
        let wrongPage = await client(status: 200, body: "<html>").health()
        XCTAssertEqual(wrongPage, .unreachable)
        let offline = await client(status: 0, body: nil).health()
        XCTAssertEqual(offline, .unreachable)
    }

    func testUnconfiguredWitnessHasNoHealth() async {
        let health = await MeshWitnessClient().health()
        XCTAssertNil(health)
    }
}

@MainActor
final class SwiftMeshBackupSetupTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MeshWitnessSettingsStore.save(.init())
    }

    func testPairingSyncsCredentialsAndStartsPassiveBackupWithoutManualSettings() async throws {
        try await exercisePairing(approveCredentials: true)
    }

    func testMissingCredentialApprovalNeverReportsReadyOrEnablesTakeover() async throws {
        try await exercisePairing(approveCredentials: false)
    }

    func testInvitationWithoutThePrimarysRuruNeverReportsBackupReady() async throws {
        try await exercisePairing(approveCredentials: false, primaryWitness: "service@ruru.example.com")
    }

    private func exercisePairing(approveCredentials: Bool, primaryWitness: String? = nil) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ConfigStore(folderURL: directory)
        var primarySettings = BotSettings()
        primarySettings.prefix = "paired-prefix"
        try await source.save(primarySettings)
        let enrollmentStore = MeshCredentialEnrollmentStore(account: "pairing-test-\(UUID())")
        let enrollment = try await enrollmentStore.issueGrant(nodeName: "Backup")
        if !approveCredentials { try await enrollmentStore.revoke(nodeID: enrollment.nodeID) }
        let primary = ClusterCoordinator()
        let destinationVersion = await ConfigStore().meshSnapshotVersion()
        let term = max(100, (destinationVersion?.leaderTerm ?? 0) + 1)
        if let primaryWitness {
            await primary.setOwnershipHandlers(acquire: { $0 }, renew: { _ in .renewed }, release: { _ in }, witnessFingerprint: primaryWitness)
        }
        let primaryPort = MeshTestPorts.free()
        await primary.configureHandlers(
            aiHandler: { _, _, _, _ in nil }, wikiHandler: { _, _ in nil },
            onSnapshot: { _ in }, onJobLog: { _ in }, onSync: { _ in },
            meshHandler: { type in
                type == "config-files" ? await source.exportMeshSyncedFiles(excludingFileNames: [], leaderTerm: term) : nil
            }, conversationFetcher: { _, _ in ([], false) }
        )
        await primary.setCredentialAuthorization(provider: { await enrollmentStore.authorizedPublicKey(nodeID: $0) }, localNodeID: "primary", localToken: "")
        await primary.setCredentialsProvider {
            let version = await source.meshSnapshotVersion()
            return MeshCredentialsResponse(gameProviderTokens: [:], discordToken: "fixture-discord-token",
                                           authorizedCredentialGrants: await enrollmentStore.allGrants(),
                                           leaderTerm: term, configRevision: version?.revision ?? 0)
        }
        await primary.applySettings(mode: .leader, nodeName: "Pairing Primary", leaderAddress: "", listenPort: primaryPort, sharedSecret: "pairing-secret", leaderTerm: term)
        let listening = await primary.waitUntilListeningForTesting()
        XCTAssertTrue(listening)
        let model = AppModel()
        model.settings.clusterListenPort = MeshTestPorts.free()
        model.settings.adminWebUI.enabled = false
        let bundle = SwiftMeshJoinBundle(leaderAddresses: ["http://127.0.0.1:\(primaryPort)"], leaderPort: primaryPort,
                                        sharedSecret: "pairing-secret", leaderTerm: term, credentialEnrollment: enrollment)
        let code = "swiftmesh://join?b=" + (try JSONEncoder().encode(bundle)).base64EncodedString()
        var progress: [String] = []
        let result = await model.pairSwiftMeshFailover(code) { progress.append($0) }
        let snapshot = await model.cluster.currentSnapshot()
        let outputAllowed = await model.service.outputAllowed
        XCTAssertEqual(result.ok, approveCredentials, "\(result.message)\n\(model.logs.lines.suffix(12).joined(separator: "\n"))")
        XCTAssertEqual(snapshot.mode, .standby)
        XCTAssertFalse(outputAllowed, "Pairing must never open Discord output")
        XCTAssertFalse(model.meshPairingInProgress)
        if approveCredentials {
            XCTAssertEqual(model.settings.token, "fixture-discord-token")
            XCTAssertEqual(model.settings.prefix, "paired-prefix")
            XCTAssertTrue(model.settings.autoStart)
            XCTAssertTrue(progress.contains("Checking backup readiness…"))
            let readiness = await model.meshPromotionReadiness()
            XCTAssertNil(readiness)
            let health = await model.cluster.processHTTPRequest(Data("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
            XCTAssertTrue(String(decoding: health, as: UTF8.self).contains("200 OK"))
        } else {
            XCTAssertFalse(result.message.contains("Backup ready"))
            XCTAssertFalse(progress.contains("Checking backup readiness…"))
            if primaryWitness != nil { XCTAssertTrue(result.message.contains("Generate a new pairing link")) }
        }
        await model.stopBot()
        await primary.stopAll()
    }
}

final class RuruBackupConnectionTests: XCTestCase {
    override func tearDown() {
        BackupRuruURLProtocol.serviceStatus = 200
        BackupRuruURLProtocol.clusterID = "service"
        BackupRuruURLProtocol.leaseEnabled = true
        BackupRuruURLProtocol.healthStatus = 200
        BackupRuruURLProtocol.requests = []
        super.tearDown()
    }

    private func client() async -> MeshWitnessClient {
        BackupRuruURLProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackupRuruURLProtocol.self]
        let client = MeshWitnessClient(session: URLSession(configuration: configuration))
        await client.configure(.init(endpoint: "https://ruru.example.com", clusterID: "service", token: String(repeating: "t", count: 32)), nodeID: "backup")
        return client
    }

    func testVerifiesServiceTokenWithoutAcquiringOrReleasingOwnership() async {
        let client = await client()
        let verified = await client.verifyServiceConnection()
        XCTAssertTrue(verified)
        XCTAssertEqual(BackupRuruURLProtocol.requests.map { $0.url!.path }, ["/v1/service", "/health"])
        XCTAssertTrue(BackupRuruURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertEqual(BackupRuruURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "t", count: 32))
        XCTAssertNil(BackupRuruURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"))
        let deadline = await client.leaseDeadline()
        XCTAssertNil(deadline)
    }

    func testPublicHealthCannotMakeWrongTokenOrServiceReady() async {
        for status in [401, 403, 503] {
            BackupRuruURLProtocol.serviceStatus = status
            let verified = await client().verifyServiceConnection()
            XCTAssertFalse(verified)
            XCTAssertEqual(BackupRuruURLProtocol.requests.count, 1)
        }
        BackupRuruURLProtocol.serviceStatus = 200
        BackupRuruURLProtocol.clusterID = "another-service"
        let wrongService = await client().verifyServiceConnection()
        XCTAssertFalse(wrongService)
    }

    func testRecoveringOrUnsupportedAuthorityCannotMarkBackupReady() async {
        BackupRuruURLProtocol.healthStatus = 503
        let recovering = await client().verifyServiceConnection()
        XCTAssertFalse(recovering)
        BackupRuruURLProtocol.healthStatus = 200
        BackupRuruURLProtocol.leaseEnabled = false
        let unsupported = await client().verifyServiceConnection()
        XCTAssertFalse(unsupported)
    }
}

private final class BackupRuruURLProtocol: URLProtocol {
    nonisolated(unsafe) static var serviceStatus = 200
    nonisolated(unsafe) static var clusterID = "service"
    nonisolated(unsafe) static var leaseEnabled = true
    nonisolated(unsafe) static var healthStatus = 200
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let isService = request.url!.path == "/v1/service"
        let status = isService ? Self.serviceStatus : Self.healthStatus
        let body: [String: Any] = isService
            ? ["version": 1, "authority": "Ruru", "clusterID": Self.clusterID,
               "capabilities": ["lease": ["version": 1, "enabled": Self.leaseEnabled]]]
            : ["ready": status == 200]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class HealthStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (Int, Data)?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        guard let (status, body) = Self.response, let url = request.url,
              let reply = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
