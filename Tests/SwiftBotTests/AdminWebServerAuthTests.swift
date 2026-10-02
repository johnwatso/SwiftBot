import XCTest
@testable import SwiftBot

/// Covers the authentication and authorisation gates on the admin web server.
///
/// Everything here drives raw HTTP bytes through `process` — the same entry
/// point the NIO and Network listeners feed — so the assertions are about what
/// a real client would receive, not about internal state. The server is left
/// unconfigured on purpose: none of these paths need a provider, and a route
/// that reaches its provider returns a distinguishable status, which is what
/// separates "the CSRF gate let me through" from "the gate rejected me".
final class AdminWebServerAuthTests: XCTestCase {

    // MARK: - Helpers

    private func makeRequest(
        method: String = "GET",
        path: String,
        cookie: String? = nil,
        bearer: String? = nil,
        userAgent: String? = nil,
        csrf: String? = nil,
        body: Data = Data()
    ) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n"
        if let cookie { head += "Cookie: swiftbot_admin_session=\(cookie)\r\n" }
        if let bearer { head += "Authorization: Bearer \(bearer)\r\n" }
        if let userAgent { head += "User-Agent: \(userAgent)\r\n" }
        if let csrf { head += "X-Admin-CSRF: \(csrf)\r\n" }
        if !body.isEmpty { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private func statusCode(from response: Data) -> Int {
        guard let text = String(data: response.prefix(64), encoding: .utf8),
              let line = text.split(separator: "\r\n").first else { return -1 }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return -1 }
        return code
    }

    private func bodyString(from response: Data) -> String {
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)) else { return "" }
        return String(data: response[separator.upperBound...], encoding: .utf8) ?? ""
    }

    private let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15"

    // MARK: - Session authentication

    func testUnauthenticatedRequestIsRejected() async {
        let server = AdminWebServer()
        let response = await server.testProcessRequest(makeRequest(path: "/api/me"))
        XCTAssertEqual(statusCode(from: response), 401, "No credentials must not reach a protected route")
    }

    func testUnknownSessionCookieIsRejected() async {
        let server = AdminWebServer()
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/me", cookie: "not-a-real-session-id")
        )
        XCTAssertEqual(statusCode(from: response), 401, "A forged cookie must not authenticate")
    }

    func testValidSessionCookieAuthenticates() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession()
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/me", cookie: session.id)
        )
        XCTAssertEqual(statusCode(from: response), 200)
        XCTAssertTrue(bodyString(from: response).contains(session.csrf), "/api/me should hand back the session CSRF token")
    }

    func testBearerTokenAuthenticates() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession()
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/me", bearer: session.id)
        )
        XCTAssertEqual(statusCode(from: response), 200, "The Remote client's bearer path must authenticate too")
    }

    func testExpiredSessionIsRejected() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession(expiresIn: -1)
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/me", cookie: session.id)
        )
        XCTAssertEqual(statusCode(from: response), 401, "A session past its expiry must not authenticate")
    }

    func testRevokedSessionIsRejected() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession()
        await server.testRevokeSession(session.id)
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/me", cookie: session.id)
        )
        XCTAssertEqual(statusCode(from: response), 401, "A revoked session must stop working immediately")
    }

    // MARK: - User-agent binding

    func testSessionBoundToUserAgentRejectsADifferentOne() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession(userAgent: browserUA)
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/me", cookie: session.id, userAgent: "curl/8.4.0")
        )
        XCTAssertEqual(statusCode(from: response), 401, "A stolen cookie replayed from another client must be rejected")
    }

    func testSessionBoundToUserAgentAcceptsTheSameOne() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession(userAgent: browserUA)
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/me", cookie: session.id, userAgent: browserUA)
        )
        XCTAssertEqual(statusCode(from: response), 200)
    }

    func testSessionWithoutBoundUserAgentIsNotEnforced() async {
        // Native Remote clients send no UA. Binding must stay opt-in, or those
        // installs break.
        let server = AdminWebServer()
        let session = await server.testSeedSession(userAgent: nil)
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/me", bearer: session.id, userAgent: "SwiftBot-Remote/1.0")
        )
        XCTAssertEqual(statusCode(from: response), 200, "An unbound session must not start enforcing binding")
    }

    // MARK: - Role gating

    func testViewerRoleIsForbiddenFromAdminRoute() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession(viewerRole: true)
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/me", cookie: session.id)
        )
        XCTAssertEqual(statusCode(from: response), 403, "A viewer must be refused, not silently upgraded")
    }

    // MARK: - Members

    /// A server member signs in to their own Replay. The gate in `process`
    /// must keep them off every admin route, including the ones that only
    /// check for a signed-in session.
    func testMemberIsKeptOffAdminRoutes() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession(memberRole: true)
        for path in ["/api/overview", "/api/config", "/api/status", "/api/commands", "/api/access", "/api/rewind/replay", "/api/media"] {
            let response = await server.testProcessRequest(makeRequest(path: path, cookie: session.id))
            XCTAssertEqual(statusCode(from: response), 403, "\(path) must be refused to a member")
        }
        let write = await server.testProcessRequest(
            makeRequest(method: "POST", path: "/api/access/members", cookie: session.id, csrf: session.csrf, body: Data(#"{"enabled":true}"#.utf8))
        )
        XCTAssertEqual(statusCode(from: write), 403, "A member must not change who can sign in")
    }

    func testMemberReachesTheirOwnRoutes() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession(memberRole: true)
        let me = await server.testProcessRequest(makeRequest(path: "/api/me", cookie: session.id))
        XCTAssertEqual(statusCode(from: me), 200)
        XCTAssertTrue(bodyString(from: me).contains(#""role":"member""#))
        // No provider in an unconfigured server: 503 means the gate let it through.
        let replay = await server.testProcessRequest(makeRequest(path: "/api/member/replay", cookie: session.id))
        XCTAssertEqual(statusCode(from: replay), 503)
        let page = await server.testProcessRequest(makeRequest(path: "/", cookie: session.id))
        XCTAssertNotEqual(statusCode(from: page), 403)
    }

    /// Members can only play clips they're in. With no clip index (an
    /// unconfigured server), every playback request is refused.
    func testMemberPlaybackNeedsAClipTheyAreIn() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession(memberRole: true)
        for path in ["/api/media/stream?id=abc", "/api/media/thumbnail?id=abc", "/api/media/hls?id=abc", "/api/media/stream"] {
            let response = await server.testProcessRequest(makeRequest(path: path, cookie: session.id))
            XCTAssertEqual(statusCode(from: response), 403, "\(path) must be refused")
        }
        let clips = await server.testProcessRequest(makeRequest(path: "/api/member/clips", cookie: session.id))
        XCTAssertEqual(statusCode(from: clips), 503, "Their own clip list gets through the gate")
    }

    // MARK: - CSRF

    func testMutationWithoutCSRFHeaderIsRejected() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession()
        let response = await server.testProcessRequest(
            makeRequest(
                method: "POST",
                path: "/api/settings/prefix",
                cookie: session.id,
                body: Data(#"{"prefix":"!"}"#.utf8)
            )
        )
        XCTAssertEqual(statusCode(from: response), 403)
        XCTAssertTrue(bodyString(from: response).contains("csrf_mismatch"))
    }

    func testMutationWithWrongCSRFTokenIsRejected() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession()
        let other = await server.testSeedSession()
        let response = await server.testProcessRequest(
            makeRequest(
                method: "POST",
                path: "/api/settings/prefix",
                cookie: session.id,
                csrf: other.csrf,
                body: Data(#"{"prefix":"!"}"#.utf8)
            )
        )
        XCTAssertEqual(statusCode(from: response), 403, "A CSRF token from another session must not be accepted")
    }

    func testMutationWithCorrectCSRFTokenClearsTheGate() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession()
        let response = await server.testProcessRequest(
            makeRequest(
                method: "POST",
                path: "/api/settings/prefix",
                cookie: session.id,
                csrf: session.csrf,
                body: Data(#"{"prefix":"!"}"#.utf8)
            )
        )
        // No updatePrefix provider is wired, so the route fails at the provider
        // rather than the gate. 400 proves the CSRF check passed; 403 would mean
        // it did not.
        XCTAssertEqual(statusCode(from: response), 400, "A matching CSRF token must clear the gate")
        XCTAssertFalse(bodyString(from: response).contains("csrf_mismatch"))
    }

    // MARK: - Media access tokens

    func testMediaTokenMintedForASessionIsAccepted() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession()
        let token = await server.testMintMediaAccessToken(sessionID: session.id)
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/media/stream?id=abc&token=\(token)")
        )
        XCTAssertNotEqual(statusCode(from: response), 401, "A freshly minted media token must authorise")
    }

    func testTamperedMediaTokenIsRejected() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession()
        let token = await server.testMintMediaAccessToken(sessionID: session.id)
        let parts = token.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else {
            XCTFail("Expected a payload.signature media token")
            return
        }

        // Mutate the first encoded signature character. Mutating the final
        // character can alter only discarded base64 padding bits and decode
        // back to the original HMAC.
        var signature = parts[1]
        let first = signature.removeFirst()
        signature.insert(first == "A" ? "B" : "A", at: signature.startIndex)
        let tampered = "\(parts[0]).\(signature)"
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/media/stream?id=abc&token=\(tampered)")
        )
        XCTAssertEqual(statusCode(from: response), 401, "A media token with a broken HMAC must be rejected")
    }

    func testMediaTokenStopsWorkingOnceItsSessionIsRevoked() async {
        // The token carries its own expiry, so it must also be checked against
        // the session it was bound to — otherwise logout leaves a live handle.
        let server = AdminWebServer()
        let session = await server.testSeedSession()
        let token = await server.testMintMediaAccessToken(sessionID: session.id)
        await server.testRevokeSession(session.id)
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/media/stream?id=abc&token=\(token)")
        )
        XCTAssertEqual(statusCode(from: response), 401, "Revoking a session must invalidate tokens minted from it")
    }

    func testMediaTokenFromAnotherServerIsRejected() async {
        // Signing keys are per-install; a token minted elsewhere must not verify.
        let issuer = AdminWebServer()
        let verifier = AdminWebServer()
        let session = await issuer.testSeedSession()
        let token = await issuer.testMintMediaAccessToken(sessionID: session.id)
        let response = await verifier.testProcessRequest(
            makeRequest(path: "/api/media/stream?id=abc&token=\(token)")
        )
        XCTAssertEqual(statusCode(from: response), 401)
    }

    // MARK: - Login rate limiting

    func testLocalLoginLocksOutAfterRepeatedFailures() async {
        let server = AdminWebServer()
        let belowThreshold = await server.testRegisterFailedLogins(
            count: 4, peerIP: "10.0.0.9", username: "admin"
        )
        XCTAssertFalse(belowThreshold, "Four failures must not lock the account out")

        let atThreshold = await server.testRegisterFailedLogins(
            count: 1, peerIP: "10.0.0.9", username: "admin"
        )
        XCTAssertTrue(atThreshold, "The fifth failure must trigger the lockout")
    }

    func testLockoutIsScopedToTheAttemptingIP() async {
        let server = AdminWebServer()
        _ = await server.testRegisterFailedLogins(count: 5, peerIP: "10.0.0.9", username: "admin")
        let otherIP = await server.testRegisterFailedLogins(count: 1, peerIP: "10.0.0.10", username: "admin")
        XCTAssertFalse(otherIP, "One attacker must not be able to lock every other client out")
    }

    // MARK: - Response hardening

    func testProtectedResponsesCarrySecurityHeaders() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession()
        let response = await server.testProcessRequest(
            makeRequest(path: "/api/me", cookie: session.id)
        )
        let head = String(data: response.prefix(1_024), encoding: .utf8) ?? ""
        XCTAssertTrue(head.contains("X-Content-Type-Options: nosniff"), "Missing nosniff")
        XCTAssertTrue(head.contains("X-Frame-Options: DENY"), "Missing frame protection")
        XCTAssertTrue(head.contains("Referrer-Policy: no-referrer"), "no-referrer is what keeps ?token= out of Referer")
        XCTAssertTrue(head.contains("Cache-Control: no-store"), "Authenticated payloads must not be cached")
    }

    func testMalformedRequestIsRejected() async {
        let server = AdminWebServer()
        let response = await server.testProcessRequest(Data("not an http request at all".utf8))
        XCTAssertEqual(statusCode(from: response), 400)
    }

    // MARK: - Provider credentials

    private actor CredentialRecorder {
        var calls: [(provider: String, token: String?)] = []
        func record(_ provider: String, _ token: String?) { calls.append((provider, token)) }
    }

    /// A session signed in just now: sessions last a day, so a fresh one
    /// expires 24 hours out.
    private func freshSession(_ server: AdminWebServer) async -> (id: String, csrf: String) {
        await server.testSeedSession(expiresIn: 24 * 60 * 60)
    }

    private func credentialRequest(_ session: (id: String, csrf: String), body: String) -> Data {
        makeRequest(method: "POST", path: "/api/gametracker/credential", cookie: session.id, csrf: session.csrf, body: Data(body.utf8))
    }

    func testCredentialIsRefusedOverPlainHTTPFromTheNetwork() async {
        let server = AdminWebServer()
        let recorder = CredentialRecorder()
        await server.setGameProviderCredentialUpdater { provider, token in await recorder.record(provider, token); return "saved" }
        let session = await freshSession(server)

        let response = await server.testProcessRequest(
            credentialRequest(session, body: #"{"provider":"finalsID","token":"fid_secret_123456789"}"#),
            peerIP: "192.168.1.20"
        )

        XCTAssertEqual(statusCode(from: response), 400)
        XCTAssertTrue(bodyString(from: response).contains("insecure_transport"))
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty, "The key must not reach the updater over plain http")
    }

    func testCredentialNeedsARecentSignIn() async {
        let server = AdminWebServer()
        let recorder = CredentialRecorder()
        await server.setGameProviderCredentialUpdater { provider, token in await recorder.record(provider, token); return "saved" }
        // Signed in about 23 hours ago.
        let session = await server.testSeedSession(expiresIn: 3_600)

        let response = await server.testProcessRequest(
            credentialRequest(session, body: #"{"provider":"finalsID","token":"fid_secret_123456789"}"#),
            peerIP: "127.0.0.1"
        )

        XCTAssertEqual(statusCode(from: response), 401)
        XCTAssertTrue(bodyString(from: response).contains("reauth_required"))
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCredentialIsSavedButNeverEchoed() async {
        let server = AdminWebServer()
        let recorder = CredentialRecorder()
        await server.setGameProviderCredentialUpdater { provider, token in await recorder.record(provider, token); return "saved" }
        let session = await freshSession(server)

        let response = await server.testProcessRequest(
            credentialRequest(session, body: #"{"provider":"finalsID","token":"fid_secret_123456789"}"#),
            peerIP: "127.0.0.1"
        )

        XCTAssertEqual(statusCode(from: response), 200)
        XCTAssertFalse(bodyString(from: response).contains("fid_secret"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.first?.provider, "finalsID")
        XCTAssertEqual(calls.first?.token, "fid_secret_123456789")
    }

    func testRejectedCredentialReportsWithoutEchoingTheKey() async {
        let server = AdminWebServer()
        await server.setGameProviderCredentialUpdater { _, _ in "rejected" }
        let session = await freshSession(server)

        let response = await server.testProcessRequest(
            credentialRequest(session, body: #"{"provider":"finalsID","token":"fid_wrong_123456789"}"#),
            peerIP: "::1"
        )

        XCTAssertEqual(statusCode(from: response), 400)
        XCTAssertTrue(bodyString(from: response).contains("rejected"))
        XCTAssertFalse(bodyString(from: response).contains("fid_wrong"))
    }

    func testRemovingACredentialPassesNil() async {
        let server = AdminWebServer()
        let recorder = CredentialRecorder()
        await server.setGameProviderCredentialUpdater { provider, token in await recorder.record(provider, token); return "saved" }
        let session = await freshSession(server)

        let response = await server.testProcessRequest(
            credentialRequest(session, body: #"{"provider":"finalsID","remove":true}"#),
            peerIP: "127.0.0.1"
        )

        XCTAssertEqual(statusCode(from: response), 200)
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls.first?.token)
    }

    func testViewersCannotSetCredentials() async {
        let server = AdminWebServer()
        let session = await server.testSeedSession(expiresIn: 24 * 60 * 60, viewerRole: true)
        let response = await server.testProcessRequest(
            credentialRequest(session, body: #"{"provider":"finalsID","token":"fid_secret_123456789"}"#),
            peerIP: "127.0.0.1"
        )
        XCTAssertEqual(statusCode(from: response), 403)
    }

    func testCredentialHintIsOnlyTheLastFourOfALongKey() {
        var connection = GameProviderConnectionSettings()
        connection.token = "fid_secret_123456789"
        XCTAssertEqual(connection.credentialHint, "6789")
        connection.token = "short"
        XCTAssertNil(connection.credentialHint, "A short key would give too much of itself away")
    }

    func testLoopbackPeerDetection() {
        for peer in ["127.0.0.1", "::1", "::1%lo0", "::ffff:127.0.0.1", "127.0.0.2"] {
            XCTAssertTrue(AdminWebServer.isLoopbackPeer(peer), peer)
        }
        for peer in ["192.168.1.20", "10.0.0.1", "fe80::1", "", "1127.0.0.1"] {
            XCTAssertFalse(AdminWebServer.isLoopbackPeer(peer), peer)
        }
        XCTAssertFalse(AdminWebServer.isLoopbackPeer(nil))
    }
}
