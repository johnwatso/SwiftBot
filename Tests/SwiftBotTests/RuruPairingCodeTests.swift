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
