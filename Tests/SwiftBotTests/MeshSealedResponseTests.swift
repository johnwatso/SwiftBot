import CryptoKit
import XCTest
@testable import SwiftBot

/// Mesh responses that carry secrets are sealed with the mesh key. Requests
/// are signed and their bodies encrypted, but the mesh usually runs over plain
/// http, so without this anyone on the LAN could read the Discord token,
/// provider API keys or the SwiftMiner pairing in settings.json as a Standby
/// pulled them.
final class MeshSealedResponseTests: XCTestCase {

    private let secret = "s"

    private func makeLeader(port: Int, configFiles: Data? = nil) async -> ClusterCoordinator {
        let c = ClusterCoordinator()
        await c.applySettings(
            mode: .leader,
            nodeName: "Leader",
            leaderAddress: "",
            listenPort: port,
            sharedSecret: secret,
            leaderTerm: 1
        )
        await c.configureHandlers(
            aiHandler: { _, _, _, _ in nil },
            wikiHandler: { _, _ in nil },
            onSnapshot: { _ in },
            onJobLog: { _ in },
            onSync: { _ in },
            meshHandler: { kind in kind == "config-files" ? configFiles : nil },
            conversationFetcher: { _, _ in ([], false) },
            onPromotion: {}
        )
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        await c.setCredentialAuthorization(provider: { $0 == "approved" ? publicKey : nil }, localNodeID: "", localToken: "")
        await c.setDiscordTokenProvider { "bot-token-do-not-leak" }
        await c.setCredentialsProvider {
            MeshCredentialsResponse(
                gameProviderTokens: ["finalsID": "fid-key-do-not-leak"],
                swiftMinerAPIKey: "miner-key-do-not-leak",
                swiftMinerWebhookSecret: "miner-hmac-do-not-leak"
            )
        }
        return c
    }

    private func signedGET(_ c: ClusterCoordinator, path: String) async -> Data {
        var headers = await c.testMakeHMACHeaders(method: "GET", path: path)
        let proof = "SwiftMesh-credential-v1:approved:GET:\(path):\(headers["X-Mesh-Nonce"]!):\(headers["X-Mesh-Timestamp"]!)"
        headers["X-Mesh-Credential-Node-ID"] = "approved"
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        headers["X-Mesh-Credential-Signature"] = try! key.signature(for: Data(proof.utf8)).base64EncodedString()
        var raw = "GET \(path) HTTP/1.1\r\nHost: localhost\r\n"
        for (k, v) in headers { raw += "\(k): \(v)\r\n" }
        raw += "Content-Length: 0\r\n\r\n"
        return await c.testProcessHTTPRequest(Data(raw.utf8))
    }

    private func split(_ response: Data) -> (status: Int, body: Data) {
        guard let marker = response.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: response[..<marker.lowerBound], encoding: .utf8),
              let code = head.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            return (-1, Data())
        }
        return (code, Data(response[marker.upperBound...]))
    }

    private func open(_ body: Data) throws -> String {
        let key = try MeshCrypto.deriveKey(from: secret)
        return String(decoding: try MeshCrypto.open(body, using: key), as: UTF8.self)
    }

    private func assertSealed(_ response: Data, hides plaintext: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let (status, body) = split(response)
        XCTAssertEqual(status, 200, file: file, line: line)
        XCTAssertNil(body.range(of: Data(plaintext.utf8)), "The secret must not appear on the wire", file: file, line: line)
        XCTAssertTrue(try open(body).contains(plaintext), "The mesh key must open it", file: file, line: line)
    }

    func testDiscordTokenResponseIsSealed() async throws {
        let leader = await makeLeader(port: 39710)
        let response = await signedGET(leader, path: "/v1/mesh/discord-token")
        try assertSealed(response, hides: "bot-token-do-not-leak")
    }

    func testCredentialsResponseIsSealed() async throws {
        let leader = await makeLeader(port: 39720)
        for secret in ["fid-key-do-not-leak", "miner-key-do-not-leak", "miner-hmac-do-not-leak"] {
            let response = await signedGET(leader, path: "/v1/mesh/credentials")
            try assertSealed(response, hides: secret)
        }
    }

    func testConfigFilesResponseIsSealed() async throws {
        let settings = Data(#"{"swiftMiner":{"webhookSecret":"miner-secret-do-not-leak"}}"#.utf8)
        let payload = MeshSyncedFilesPayload(
            generatedAt: Date(),
            files: [MeshSyncedFile(fileName: "settings.json", base64Data: settings.base64EncodedString())]
        )
        let leader = await makeLeader(port: 39730, configFiles: try JSONEncoder().encode(payload))
        let response = await signedGET(leader, path: "/v1/mesh/sync/config-files")

        let (status, body) = split(response)
        XCTAssertEqual(status, 200)
        // The file travels base64-encoded inside the JSON, so check for that too.
        XCTAssertNil(body.range(of: Data(settings.base64EncodedString().utf8)))
        XCTAssertTrue(try open(body).contains(settings.base64EncodedString()))
    }

    func testUnsignedRequestsStillGetNothing() async {
        let leader = await makeLeader(port: 39740)
        let raw = Data("GET /v1/mesh/credentials HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n".utf8)
        let (status, body) = split(await leader.testProcessHTTPRequest(raw))
        XCTAssertEqual(status, 401)
        XCTAssertNil(body.range(of: Data("fid-key".utf8)))
    }
}
