import XCTest
import CryptoKit
@testable import SwiftBot

final class AdminWebPasskeyTests: XCTestCase {
    private let origin = "https://swiftbot.example.com"
    private let userID = "1234567890"
    private let credentialID = Data([1, 2, 3, 4, 5, 6, 7, 8])

    private func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func send(_ server: AdminWebServer, _ path: String, method: String = "POST", body: [String: Any] = [:],
                      session: (id: String, csrf: String)? = nil, ceremony: String? = nil, requestOrigin: String? = nil) async throws -> (status: Int, body: [String: Any], headers: String) {
        let payload = try JSONSerialization.data(withJSONObject: body)
        var headers = ["Host: swiftbot.example.com", "User-Agent: PasskeyTests", "Content-Type: application/json", "Content-Length: \(payload.count)"]
        if method != "GET" { headers.append("Origin: \(requestOrigin ?? origin)") }
        if let session { headers.append("X-Admin-CSRF: \(session.csrf)") }
        var cookies: [String] = []
        if let session { cookies.append("swiftbot_admin_session=\(session.id)") }
        if let ceremony { cookies.append("swiftbot_passkey_ceremony=\(ceremony)") }
        if !cookies.isEmpty { headers.append("Cookie: \(cookies.joined(separator: "; "))") }
        var raw = Data("\(method) /auth/passkeys/\(path) HTTP/1.1\r\n\(headers.joined(separator: "\r\n"))\r\n\r\n".utf8)
        raw.append(payload)
        let result = await server.testProcessRequest(raw, peerIP: "127.0.0.1")
        let text = String(decoding: result, as: UTF8.self)
        let status = Int(text.split(separator: " ")[1])!
        let responseBody = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        let object = (try? JSONSerialization.jsonObject(with: Data(responseBody.utf8))) as? [String: Any] ?? [:]
        return (status, object, text.components(separatedBy: "\r\n\r\n")[0])
    }

    private func setup(mfa: Bool = true) async -> (AdminWebServer, (id: String, csrf: String)) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PasskeyDiscordProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-MFA": mfa ? "true" : "false"]
        let server = AdminWebServer()
        let session = await server.testConfigurePasskeys(origin: origin, oauthSession: URLSession(configuration: configuration))
        return (server, session)
    }

    private func clientData(challenge: String, registration: Bool, origin: String? = nil, crossOrigin: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": registration ? "webauthn.create" : "webauthn.get",
            "challenge": challenge, "origin": origin ?? self.origin, "crossOrigin": crossOrigin])
    }

    private func authData(flags: UInt8, count: UInt32 = 0) -> Data {
        var data = Data(SHA256.hash(data: Data("swiftbot.example.com".utf8)))
        data.append(flags)
        data.append(contentsOf: [UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        return data
    }

    private func registration(key: P256.Signing.PrivateKey, challenge: String, origin: String? = nil, flags: UInt8 = 0x45, crossOrigin: Bool = false) throws -> [String: Any] {
        let point = Array(key.publicKey.x963Representation)
        // COSE EC2 key: kty=2, alg=-7, crv=1, x and y.
        var cose = Data([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20])
        cose.append(contentsOf: point[1..<33])
        cose.append(contentsOf: [0x22, 0x58, 0x20])
        cose.append(contentsOf: point[33..<65])
        var auth = authData(flags: flags)
        auth.append(Data(repeating: 0, count: 16)) // AAGUID
        auth.append(contentsOf: [0, UInt8(credentialID.count)])
        auth.append(credentialID)
        auth.append(cose)
        // CBOR {fmt: "none", attStmt: {}, authData: bytes}.
        var attestation = Data([0xa3, 0x63])
        attestation.append(Data("fmt".utf8)); attestation.append(0x64); attestation.append(Data("none".utf8))
        attestation.append(0x67); attestation.append(Data("attStmt".utf8)); attestation.append(0xa0)
        attestation.append(0x68); attestation.append(Data("authData".utf8)); attestation.append(contentsOf: [0x58, UInt8(auth.count)])
        attestation.append(auth)
        return ["id": base64(credentialID), "rawId": base64(credentialID), "type": "public-key",
            "response": ["clientDataJSON": base64(try clientData(challenge: challenge, registration: true, origin: origin, crossOrigin: crossOrigin)), "attestationObject": base64(attestation)]]
    }

    private func enroll(_ server: AdminWebServer, session: (id: String, csrf: String), key: P256.Signing.PrivateKey) async throws {
        let options = try await send(server, "register/options", body: ["name": "Test Mac"], session: session)
        XCTAssertEqual(options.status, 200)
        let publicKey = try XCTUnwrap(options.body["publicKey"] as? [String: Any])
        let selection = try XCTUnwrap(publicKey["authenticatorSelection"] as? [String: Any])
        XCTAssertEqual(selection["residentKey"] as? String, "required")
        XCTAssertEqual(selection["userVerification"] as? String, "required")
        let ceremony = try XCTUnwrap(options.body["ceremony"] as? String)
        let credential = try registration(key: key, challenge: XCTUnwrap(publicKey["challenge"] as? String))
        let finish = try await send(server, "register/finish", body: ["ceremony": ceremony, "credential": credential], session: session, ceremony: ceremony)
        XCTAssertEqual(finish.status, 200, "\(finish.body)")
    }

    private func assertion(key: P256.Signing.PrivateKey, challenge: String, flags: UInt8 = 0x05, origin: String? = nil, crossOrigin: Bool = false) throws -> [String: Any] {
        let client = try clientData(challenge: challenge, registration: false, origin: origin, crossOrigin: crossOrigin)
        let auth = authData(flags: flags, count: 1)
        var signed = auth
        signed.append(Data(SHA256.hash(data: client)))
        return ["id": base64(credentialID), "rawId": base64(credentialID), "type": "public-key",
            "response": ["clientDataJSON": base64(client), "authenticatorData": base64(auth), "signature": base64(try key.signature(for: signed).derRepresentation), "userHandle": base64(Data(userID.utf8))]]
    }

    func testSignedEnrollmentLoginAndReplayRejection() async throws {
        let (server, session) = await setup()
        let key = P256.Signing.PrivateKey()
        try await enroll(server, session: session, key: key)
        let options = try await send(server, "login/options")
        let ceremony = try XCTUnwrap(options.body["ceremony"] as? String)
        let publicKey = try XCTUnwrap(options.body["publicKey"] as? [String: Any])
        let credential = try assertion(key: key, challenge: XCTUnwrap(publicKey["challenge"] as? String))
        let body: [String: Any] = ["ceremony": ceremony, "credential": credential]
        let success = try await send(server, "login/finish", body: body, ceremony: ceremony)
        XCTAssertEqual(success.status, 200, "\(success.body)")
        XCTAssertTrue(success.headers.contains("; Secure"))
        XCTAssertTrue(success.headers.contains("; HttpOnly"))
        let replay = try await send(server, "login/finish", body: body, ceremony: ceremony)
        XCTAssertEqual(replay.status, 400)
    }

    func testAssertionRejectsWrongOriginSignatureChallengeVerificationAndFrame() async throws {
        for failure in ["origin", "signature", "challenge", "verification", "frame", "cookie", "expired"] {
            let (server, session) = await setup()
            let key = P256.Signing.PrivateKey()
            try await enroll(server, session: session, key: key)
            let options = try await send(server, "login/options")
            let ceremony = try XCTUnwrap(options.body["ceremony"] as? String)
            let publicKey = try XCTUnwrap(options.body["publicKey"] as? [String: Any])
            let credential = try assertion(key: failure == "signature" ? P256.Signing.PrivateKey() : key,
                challenge: failure == "challenge" ? "wrong" : XCTUnwrap(publicKey["challenge"] as? String),
                flags: failure == "verification" ? 0x01 : 0x05,
                origin: failure == "origin" ? "https://attacker.example" : nil, crossOrigin: failure == "frame")
            if failure == "expired" { await server.testExpirePasskeyChallenges() }
            let result = try await send(server, "login/finish", body: ["ceremony": ceremony, "credential": credential], ceremony: failure == "cookie" ? nil : ceremony)
            XCTAssertEqual(result.status, 400, failure)
        }
    }

    func testRegistrationRejectsWrongOriginAndMissingVerification() async throws {
        for failure in ["origin", "verification", "frame"] {
            let (server, session) = await setup()
            let options = try await send(server, "register/options", session: session)
            let ceremony = try XCTUnwrap(options.body["ceremony"] as? String)
            let publicKey = try XCTUnwrap(options.body["publicKey"] as? [String: Any])
            let credential = try registration(key: P256.Signing.PrivateKey(), challenge: XCTUnwrap(publicKey["challenge"] as? String),
                origin: failure == "origin" ? "https://attacker.example" : nil, flags: failure == "verification" ? 0x41 : 0x45, crossOrigin: failure == "frame")
            let result = try await send(server, "register/finish", body: ["ceremony": ceremony, "credential": credential], session: session, ceremony: ceremony)
            XCTAssertEqual(result.status, 400, failure)
        }
    }

    func testDiscordMFAIsRecheckedAndRevokedCredentialCannotLogin() async throws {
        let (server, session) = await setup(mfa: false)
        let key = P256.Signing.PrivateKey()
        try await enroll(server, session: session, key: key)
        let options = try await send(server, "login/options")
        let ceremony = try XCTUnwrap(options.body["ceremony"] as? String)
        let publicKey = try XCTUnwrap(options.body["publicKey"] as? [String: Any])
        let credential = try assertion(key: key, challenge: XCTUnwrap(publicKey["challenge"] as? String))
        let denied = try await send(server, "login/finish", body: ["ceremony": ceremony, "credential": credential], ceremony: ceremony)
        XCTAssertEqual(denied.status, 400)
        let removed = try await send(server, "remove", body: ["id": base64(credentialID)], session: session)
        XCTAssertEqual(removed.status, 200)
        let list = try await send(server, "list", method: "GET", session: session)
        XCTAssertEqual((list.body["credentials"] as? [[String: Any]])?.count, 0)
    }

    func testRemovedAccessAndRevokedPasskeyRejectSignedLogin() async throws {
        for revokeCredential in [false, true] {
            let (server, session) = await setup()
            let key = P256.Signing.PrivateKey()
            try await enroll(server, session: session, key: key)
            let options = try await send(server, "login/options")
            let ceremony = try XCTUnwrap(options.body["ceremony"] as? String)
            let publicKey = try XCTUnwrap(options.body["publicKey"] as? [String: Any])
            let credential = try assertion(key: key, challenge: XCTUnwrap(publicKey["challenge"] as? String))
            if revokeCredential {
                let removed = try await send(server, "remove", body: ["id": base64(credentialID)], session: session)
                XCTAssertEqual(removed.status, 200)
            } else {
                await server.testSetPasskeyAllowList(["different-user"])
            }
            let result = try await send(server, "login/finish", body: ["ceremony": ceremony, "credential": credential], ceremony: ceremony)
            XCTAssertEqual(result.status, 400)
        }
    }

    func testHTTPOriginCannotEnablePasskeys() async throws {
        let (server, _) = await setup()
        _ = await server.testConfigurePasskeys(origin: "http://192.168.1.2:38888", oauthSession: .shared)
        let result = try await send(server, "login/options")
        XCTAssertEqual(result.status, 400)
        XCTAssertEqual(result.body["error"] as? String, "passkeys_unavailable")
    }

    func testManagementRequiresSessionCSRFAndSameOrigin() async throws {
        let (server, session) = await setup()
        let anonymous = try await send(server, "register/options")
        XCTAssertEqual(anonymous.status, 403)
        let csrf = try await send(server, "register/options", session: (session.id, "wrong"))
        XCTAssertEqual(csrf.status, 403)
        let origin = try await send(server, "register/options", session: session, requestOrigin: "https://attacker.example")
        XCTAssertEqual(origin.status, 403)
    }
}

private final class PasskeyDiscordProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let object: Any
        switch request.url!.path {
        case "/api/oauth2/token": object = ["access_token": "fixture-access", "refresh_token": "fixture-rotated"]
        case "/api/users/@me": object = ["id": "1234567890", "username": "passkey-fixture", "mfa_enabled": request.value(forHTTPHeaderField: "X-Fixture-MFA") != "false"] as [String: Any]
        case "/api/users/@me/guilds": object = [[String: Any]]()
        default: XCTFail("Unexpected network request"); object = [:]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
