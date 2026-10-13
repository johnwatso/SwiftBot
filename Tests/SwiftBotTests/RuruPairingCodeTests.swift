import XCTest
@testable import SwiftBot

/// Ruru witness settings and storage. Witness settings go through
/// `KeychainHelper`, which is in-memory under XCTest.
@MainActor
final class RuruWitnessSettingsTests: XCTestCase {

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

    func testValidInheritedWitnessIsSavedButInvalidPayloadCannotReplaceIt() {
        XCTAssertTrue(MeshWitnessSettingsStore.inherit(fixtureConfiguration))
        XCTAssertEqual(MeshWitnessSettingsStore.load(), fixtureConfiguration)
        XCTAssertFalse(MeshWitnessSettingsStore.inherit(.init(endpoint: "http://not-ruru.example", clusterID: "bad", token: "short")))
        XCTAssertEqual(MeshWitnessSettingsStore.load(), fixtureConfiguration)
        XCTAssertTrue(MeshWitnessSettingsStore.inherit(nil), "Older Primaries omit this optional field")
        XCTAssertEqual(MeshWitnessSettingsStore.load(), fixtureConfiguration)
    }


    func testWitnessConfigurationJSONShapeIsStable() throws {
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
