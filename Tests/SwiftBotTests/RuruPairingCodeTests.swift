import XCTest
@testable import SwiftBot

/// Ruru pairing codes (`Documentation/RURU_PAIRING_CODE.md`). Witness settings
/// go through `KeychainHelper`, which is in-memory under XCTest.
@MainActor
final class RuruPairingCodeTests: XCTestCase {
    /// The synthetic fixture from `Documentation/RURU_PAIRING_CODE.md`. Ruru's
    /// exporter must produce a code this decoder accepts.
    static let documentedFixture = "RURU1:eyJ2ZXJzaW9uIjoxLCJlbmRwb2ludCI6Imh0dHBzOi8vcnVydS5leGFtcGxlLmNvbSIsImNsdXN0ZXJJRCI6InN3aWZ0Ym90LWV4YW1wbGUiLCJ0b2tlbiI6IkVYQU1QTEUtT05MWS0wMTIzNDU2Nzg5YWJjZGVmZ2hpamtsbW5vcHFyc3R1diIsInNlcnZpY2VOYW1lIjoiU3dpZnRCb3QifQ"

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

    /// Builds a code from arbitrary JSON so tests can produce malformed payloads.
    private func code(json: String) -> String {
        RuruPairingCode.prefix + Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func assertRejects(_ code: String, _ expected: RuruPairingCode.DecodeError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RuruPairingCode.decode(code), file: file, line: line) { error in
            XCTAssertEqual(error as? RuruPairingCode.DecodeError, expected, file: file, line: line)
        }
    }

    // MARK: Valid import

    func testDocumentedFixtureDecodes() throws {
        let pairing = try RuruPairingCode.decode(Self.documentedFixture)
        XCTAssertEqual(pairing.configuration, fixtureConfiguration)
        XCTAssertEqual(pairing.serviceName, "SwiftBot")
        XCTAssertTrue(pairing.configuration.isValid)
    }

    func testSurroundingWhitespaceIsIgnoredAndServiceNameIsOptional() throws {
        let raw = code(json: #"{"version":1,"endpoint":"https://ruru.example.com","clusterID":"c1","token":"\#(String(repeating: "a", count: 40))"}"#)
        let pairing = try RuruPairingCode.decode("\n  \(raw)\t\n")
        XCTAssertNil(pairing.serviceName)
        XCTAssertEqual(pairing.configuration.clusterID, "c1")
    }

    func testUnknownFieldsAreIgnoredAndBadServiceNameIsDropped() throws {
        let raw = code(json: #"{"version":1,"endpoint":"https://ruru.example.com","clusterID":"c1","token":"\#(String(repeating: "a", count: 40))","serviceName":"bad\nname","future":true}"#)
        XCTAssertNil(try RuruPairingCode.decode(raw).serviceName)
    }

    func testEncodeRoundTripsAndUsesUnpaddedBase64URL() throws {
        // A name chosen so standard base64 would contain '+', '/' and '='.
        let encoded = try XCTUnwrap(RuruPairingCode.encode(fixtureConfiguration, serviceName: "Swift>>Bot??"))
        let body = encoded.dropFirst(RuruPairingCode.prefix.count)
        XCTAssertFalse(body.contains("+") || body.contains("/") || body.contains("="))
        let pairing = try RuruPairingCode.decode(encoded)
        XCTAssertEqual(pairing.configuration, fixtureConfiguration)
        XCTAssertEqual(pairing.serviceName, "Swift>>Bot??")
    }

    func testImportedConfigurationSavesThroughWitnessStore() throws {
        let before = KeychainHelper.realKeychainAccessCount.load(ordering: .relaxed)
        let pairing = try RuruPairingCode.decode(Self.documentedFixture)
        XCTAssertTrue(MeshWitnessSettingsStore.save(pairing.configuration))
        XCTAssertEqual(MeshWitnessSettingsStore.load(), fixtureConfiguration)
        XCTAssertEqual(KeychainHelper.realKeychainAccessCount.load(ordering: .relaxed), before)
    }

    // MARK: Malformed and unsupported codes

    func testMalformedCodesAreRejected() {
        assertRejects("   ", .empty)
        assertRejects("swiftmesh://join?b=abc", .joinCode)
        assertRejects("RURU2:abc", .wrongPrefix)
        assertRejects("ruru1:" + Self.documentedFixture.dropFirst(6), .wrongPrefix)
        assertRejects("RURU1:", .invalidEncoding)
        assertRejects("RURU1:abc$def", .invalidEncoding)
        assertRejects(Self.documentedFixture + "=", .invalidEncoding)
        assertRejects("RURU1:abcde", .invalidEncoding)
        assertRejects(code(json: "not json"), .invalidJSON)
        assertRejects(code(json: "[1]"), .invalidJSON)
        assertRejects(code(json: #"{"version":"1"}"#), .invalidJSON)
    }

    func testOversizedCodeIsRejectedBeforeDecoding() {
        assertRejects(RuruPairingCode.prefix + String(repeating: "A", count: RuruPairingCode.maximumLength), .tooLong)
        assertRejects(String(repeating: " ", count: RuruPairingCode.maximumLength * 3), .tooLong)
    }

    func testVersionIsRequiredAndOnlyVersionOneIsSupported() {
        let token = String(repeating: "a", count: 40)
        assertRejects(code(json: #"{"endpoint":"https://r.example.com","clusterID":"c","token":"\#(token)"}"#), .missingVersion)
        assertRejects(code(json: #"{"version":2,"endpoint":"https://r.example.com","clusterID":"c","token":"\#(token)"}"#), .unsupportedVersion(2))
        assertRejects(code(json: #"{"version":0,"endpoint":"https://r.example.com","clusterID":"c","token":"\#(token)"}"#), .unsupportedVersion(0))
    }

    // MARK: Invalid configurations

    func testInvalidConfigurationsAreRejected() {
        let token = String(repeating: "a", count: 40)
        func payload(endpoint: String = "https://r.example.com", clusterID: String = "c", token: String = token) -> String {
            code(json: #"{"version":1,"endpoint":"\#(endpoint)","clusterID":"\#(clusterID)","token":"\#(token)"}"#)
        }
        assertRejects(code(json: #"{"version":1,"clusterID":"c","token":"\#(token)"}"#), .missingField("address"))
        assertRejects(code(json: #"{"version":1,"endpoint":"https://r.example.com","token":"\#(token)"}"#), .missingField("cluster ID"))
        assertRejects(code(json: #"{"version":1,"endpoint":"https://r.example.com","clusterID":"c"}"#), .missingField("bearer token"))
        assertRejects(payload(endpoint: "http://r.example.com"), .invalidEndpoint)
        assertRejects(payload(endpoint: "https://user:pass@r.example.com"), .invalidEndpoint)
        assertRejects(payload(endpoint: "https://r.example.com?x=1"), .invalidEndpoint)
        assertRejects(payload(endpoint: "https://r.example.com#frag"), .invalidEndpoint)
        assertRejects(payload(endpoint: " https://r.example.com"), .invalidEndpoint)
        assertRejects(payload(endpoint: "not a url"), .invalidEndpoint)
        assertRejects(payload(clusterID: ""), .invalidClusterID)
        assertRejects(payload(clusterID: " padded"), .invalidClusterID)
        assertRejects(payload(clusterID: String(repeating: "c", count: 129)), .invalidClusterID)
        // 43 two-byte characters = 86 bytes is fine; 65 = 130 bytes is over Ruru's byte limit.
        assertRejects(payload(clusterID: String(repeating: "é", count: 65)), .invalidClusterID)
        assertRejects(payload(token: "short"), .invalidToken)
        assertRejects(payload(token: String(repeating: "a", count: 31) + " "), .invalidToken)
        assertRejects(payload(token: String(repeating: "a", count: 513)), .invalidToken)
    }

    /// Ruru's own validation allows inner spaces and caps tokens at 512 bytes.
    func testLimitsMatchRuruServer() throws {
        let spaced = code(json: #"{"version":1,"endpoint":"https://r.example.com","clusterID":"Swift Bot","token":"\#(String(repeating: "a", count: 512))"}"#)
        let pairing = try RuruPairingCode.decode(spaced)
        XCTAssertEqual(pairing.configuration.clusterID, "Swift Bot")
        XCTAssertEqual(pairing.configuration.token.utf8.count, 512)
    }

    // MARK: Ruru's current Copy output

    /// `WitnessAppModel.copyConnectionDetails` copies bare JSON with no version.
    func testRuruConnectionDetailsJSONIsAccepted() throws {
        let copied = #"{"clusterID":"swiftmesh-1a2b3c4d","token":"\#(String(repeating: "x", count: 43))","endpoint":"https://witness.example.com"}"#
        let pairing = try RuruPairingCode.decode(copied)
        XCTAssertEqual(pairing.configuration.endpoint, "https://witness.example.com")
        XCTAssertEqual(pairing.configuration.clusterID, "swiftmesh-1a2b3c4d")
        XCTAssertNil(pairing.serviceName)
    }

    func testBareJSONIsValidatedLikeACode() {
        assertRejects(#"{"clusterID":"c","token":"short","endpoint":"https://r.example.com"}"#, .invalidToken)
        assertRejects(#"{"version":2,"clusterID":"c","token":"\#(String(repeating: "x", count: 43))","endpoint":"https://r.example.com"}"#, .invalidJSON)
        assertRejects("{not json", .invalidJSON)
    }

    func testLoopbackHTTPRemainsAllowedForDevelopment() throws {
        let raw = code(json: #"{"version":1,"endpoint":"http://127.0.0.1:38990","clusterID":"c","token":"\#(String(repeating: "a", count: 40))"}"#)
        XCTAssertEqual(try RuruPairingCode.decode(raw).configuration.endpoint, "http://127.0.0.1:38990")
    }

    func testErrorsNeverEchoTheToken() {
        let secret = "SECRET-" + String(repeating: "z", count: 40)
        let raw = code(json: #"{"version":1,"endpoint":"http://r.example.com","clusterID":"c","token":"\#(secret)"}"#)
        XCTAssertThrowsError(try RuruPairingCode.decode(raw)) { error in
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            XCTAssertFalse(error.localizedDescription.contains(raw))
        }
    }

    func testFailedImportPreservesExistingSettings() {
        let existing = MeshWitnessConfiguration(endpoint: "https://old.example.com", clusterID: "old", token: String(repeating: "o", count: 40))
        XCTAssertTrue(MeshWitnessSettingsStore.save(existing))
        XCTAssertThrowsError(try RuruPairingCode.decode("RURU1:%%%"))
        XCTAssertEqual(MeshWitnessSettingsStore.load(), existing)
        // An invalid configuration is also refused by the store itself.
        XCTAssertFalse(MeshWitnessSettingsStore.save(.init(endpoint: "http://r.example.com", clusterID: "c", token: "short")))
        XCTAssertEqual(MeshWitnessSettingsStore.load(), existing)
    }

    // MARK: Join Code compatibility

    func testJoinCodeCarriesImportedWitness() throws {
        let pairing = try RuruPairingCode.decode(Self.documentedFixture)
        let bundle = SwiftMeshJoinBundle(leaderAddresses: ["https://primary.example.com"], leaderPort: 38787,
                                         sharedSecret: "mesh", leaderTerm: 4, witness: pairing.configuration)
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
