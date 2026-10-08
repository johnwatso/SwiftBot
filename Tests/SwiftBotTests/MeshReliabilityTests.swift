import CryptoKit
import XCTest
@testable import SwiftBot

final class MeshReliabilityTests: XCTestCase {
    private func request(_ coordinator: ClusterCoordinator, path: String, body: Data = Data(), method: String = "POST", credential: String? = nil, nodeID: String = "approved", proofPath: String? = nil) async -> Data {
        var headers = await coordinator.testMakeHMACHeaders(method: method, path: path, body: body)
        if let credential {
            let nonce = headers["X-Mesh-Nonce"]!
            let timestamp = headers["X-Mesh-Timestamp"]!
            let proof = "SwiftMesh-credential-v1:\(nodeID):\(method):\(proofPath ?? path):\(nonce):\(timestamp)"
            let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: credential)!)
            headers["X-Mesh-Credential-Node-ID"] = nodeID
            headers["X-Mesh-Credential-Signature"] = try! key.signature(for: Data(proof.utf8)).base64EncodedString()
        }
        var raw = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n"
        for (key, value) in headers { raw += "\(key): \(value)\r\n" }
        var bytes = Data((raw + "\r\n").utf8)
        bytes.append(body)
        return await coordinator.processHTTPRequest(bytes)
    }
    private func status(_ response: Data) -> Int {
        Int(String(decoding: response.prefix(40), as: UTF8.self).split(separator: " ")[1]) ?? -1
    }

    func testComputePermissionCannotFetchCredentials() async {
        let node = ClusterCoordinator()
        await node.applySettings(mode: .leader, nodeName: "CredentialBoundary", leaderAddress: "", listenPort: 48101, sharedSecret: "mesh")
        let denied = await request(node, path: "/v1/mesh/credentials", method: "GET")
        let deniedToken = await request(node, path: "/v1/mesh/discord-token", method: "GET")
        XCTAssertEqual(status(denied), 403)
        XCTAssertEqual(status(deniedToken), 403)
        await node.stopAll()
    }

    func testApprovedCredentialProofIsBoundToRequestAndCanBeRevoked() async throws {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let credential = privateKey.rawRepresentation.base64EncodedString()
        let node = ClusterCoordinator()
        await node.applySettings(mode: .leader, nodeName: "Approved", leaderAddress: "", listenPort: 48102, sharedSecret: "mesh")
        await node.setCredentialAuthorization(provider: { $0 == "approved" ? publicKey : nil }, localNodeID: "", localToken: "")
        await node.setCredentialsProvider { MeshCredentialsResponse(discordToken: "protected-token") }
        let allowed = await request(node, path: "/v1/mesh/credentials", method: "GET", credential: credential)
        XCTAssertEqual(status(allowed), 200)
        XCTAssertNil(allowed.range(of: Data("protected-token".utf8)))
        let badProof = await request(node, path: "/v1/mesh/credentials", method: "GET", credential: Data(repeating: 8, count: 32).base64EncodedString())
        XCTAssertEqual(status(badProof), 403)
        let wrongPath = await request(node, path: "/v1/mesh/credentials", method: "GET", credential: credential, proofPath: "/v1/mesh/discord-token")
        XCTAssertEqual(status(wrongPath), 403)
        await node.setCredentialAuthorization(provider: { _ in nil }, localNodeID: "", localToken: "")
        let revoked = await request(node, path: "/v1/mesh/credentials", method: "GET", credential: credential)
        XCTAssertEqual(status(revoked), 403)
        await node.stopAll()
    }

    func testReplicatedApprovalsCannotImpersonateAnotherNodeAfterRevocation() async throws {
        let store = MeshCredentialEnrollmentStore(account: "mesh-signing-test-\(UUID().uuidString)")
        let revoked = try await store.issueGrant(nodeName: "Revoked")
        let approved = try await store.issueGrant(nodeName: "Approved")
        let grants = await store.allGrants()
        let encoded = try JSONEncoder().encode(grants)
        XCTAssertNil(encoded.range(of: Data(revoked.token.utf8)))
        XCTAssertNil(encoded.range(of: Data(approved.token.utf8)))
        try await store.revoke(nodeID: revoked.nodeID)
        let node = ClusterCoordinator()
        await node.applySettings(mode: .leader, nodeName: "PublicApprovals", leaderAddress: "", listenPort: 48115, sharedSecret: "mesh")
        await node.setCredentialAuthorization(provider: { await store.authorizedPublicKey(nodeID: $0) }, localNodeID: "", localToken: "")
        let publicKey = try XCTUnwrap(grants.first { $0.nodeID == approved.nodeID }?.publicKey)
        // Both the revoked private key and shared public metadata are insufficient
        // to sign for the still-approved identity, despite knowing the mesh key.
        for attemptedKey in [revoked.token, publicKey] {
            let forged = await request(node, path: "/v1/mesh/credentials", method: "GET", credential: attemptedKey, nodeID: approved.nodeID)
            XCTAssertEqual(status(forged), 403)
        }
        let legitimate = await request(node, path: "/v1/mesh/credentials", method: "GET", credential: approved.token, nodeID: approved.nodeID)
        XCTAssertEqual(status(legitimate), 200)
        await node.stopAll()
    }

    func testOrdinarySettingsSavePreservesElectedRole() async {
        let node = ClusterCoordinator()
        await node.applySettings(mode: .standby, nodeName: "Preference", leaderAddress: "http://127.0.0.1:48100", listenPort: 48103, sharedSecret: "mesh", leaderTerm: 2)
        await node.promoteToLeader()
        await node.applySettings(mode: .standby, nodeName: "Preference", leaderAddress: "http://127.0.0.1:48100", listenPort: 48103, sharedSecret: "mesh", leaderTerm: 2)
        let role = await node.currentSnapshot().mode
        let term = await node.currentLeaderTerm()
        XCTAssertEqual(role, .leader)
        XCTAssertEqual(term, 3)
        await node.stopAll()
    }

    func testWitnessRefusalPreventsPromotion() async {
        let node = ClusterCoordinator()
        await node.applySettings(mode: .standby, nodeName: "DeniedOwner", leaderAddress: "http://127.0.0.1:48100", listenPort: 48104, sharedSecret: "mesh")
        await node.setOwnershipHandlers(acquire: { _ in nil }, renew: { _ in .lost }, release: { _ in })
        await node.promoteToLeader()
        let snapshot = await node.currentSnapshot()
        XCTAssertEqual(snapshot.mode, .standby)
        XCTAssertTrue(snapshot.diagnostics.contains("ownership unavailable"))
        await node.stopAll()
    }

    func testReadinessFailurePreventsPromotion() async {
        let node = ClusterCoordinator()
        await node.applySettings(mode: .standby, nodeName: "Unready", leaderAddress: "http://127.0.0.1:48100", listenPort: 48105, sharedSecret: "mesh")
        await node.setPromotionReadinessHandler { "missing snapshot" }
        await node.promoteToLeader()
        let role = await node.currentSnapshot().mode
        XCTAssertEqual(role, .standby)
        await node.stopAll()
    }

    func testCoordinatedHandbackClosesSourceBeforeTargetOpens() async {
        actor Order {
            var events: [String] = []
            func append(_ value: String) { events.append(value) }
        }
        let order = Order()
        let sourcePort = MeshTestPorts.free()
        let targetPort = MeshTestPorts.free()
        let source = ClusterCoordinator()
        let target = ClusterCoordinator()
        await source.configureHandlers(aiHandler: { _, _, _, _ in nil }, wikiHandler: { _, _ in nil }, onSnapshot: { _ in }, onJobLog: { _ in }, onSync: { _ in }, meshHandler: { _ in nil }, conversationFetcher: { _, _ in ([], false) })
        await source.setHandbackDrainHandler { await order.append("freeze"); return true }
        await source.setDemotionHandler { await order.append("source-closed") }
        await source.applySettings(mode: .leader, nodeName: "Temporary", leaderAddress: "", listenPort: sourcePort, sharedSecret: "mesh", leaderTerm: 4)
        let sourceListening = await source.waitUntilListeningForTesting()
        XCTAssertTrue(sourceListening)
        await target.configureHandlers(aiHandler: { _, _, _, _ in nil }, wikiHandler: { _, _ in nil }, onSnapshot: { _ in }, onJobLog: { _ in }, onSync: { _ in }, meshHandler: { _ in nil }, conversationFetcher: { _, _ in ([], false) }, onPromotion: { await order.append("target-open") })
        await target.setHandbackCatchupHandler { _, term in await order.append("catchup"); return term == 4 }
        await target.applySettings(mode: .standby, nodeName: "Preferred", leaderAddress: "http://127.0.0.1:\(sourcePort)", listenPort: targetPort, sharedSecret: "mesh", leaderTerm: 4)
        let targetListening = await target.waitUntilListeningForTesting()
        XCTAssertTrue(targetListening)
        for _ in 0..<60 where !(await source.registeredWorkerNamesForTesting()).contains("Preferred") {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let result = await target.requestCoordinatedHandback()
        let sourceRole = await source.currentSnapshot().mode
        let targetRole = await target.currentSnapshot().mode
        let events = await order.events
        XCTAssertTrue(result)
        XCTAssertEqual(sourceRole, .standby)
        XCTAssertEqual(targetRole, .leader)
        XCTAssertEqual(Array(events.prefix(4)), ["freeze", "catchup", "source-closed", "target-open"])
        await target.stopAll()
        await source.stopAll()
    }

    /// A Standby that starts before its Primary is listening must not wait out
    /// the 30 s registration heartbeat once the Primary comes up.
    func testStandbyRegistersSoonAfterPrimaryStartsListening() async {
        let primaryPort = MeshTestPorts.free()
        let primary = ClusterCoordinator()
        let standby = ClusterCoordinator()
        await standby.applySettings(mode: .standby, nodeName: "Early", leaderAddress: "http://127.0.0.1:\(primaryPort)", listenPort: MeshTestPorts.free(), sharedSecret: "mesh", leaderTerm: 1)
        try? await Task.sleep(for: .milliseconds(300))
        await primary.applySettings(mode: .leader, nodeName: "Late", leaderAddress: "", listenPort: primaryPort, sharedSecret: "mesh", leaderTerm: 1)
        var registered = false
        for _ in 0..<100 where !registered {
            registered = await primary.registeredWorkerNamesForTesting().contains("Early")
            if !registered { try? await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(registered)
        await standby.stopAll()
        await primary.stopAll()
    }

    func testFailedCatchupUnfreezesCurrentOwner() async {
        actor Resume { var called = false; func mark() { called = true } }
        let resume = Resume()
        let sourcePort = MeshTestPorts.free()
        let targetPort = MeshTestPorts.free()
        let source = ClusterCoordinator()
        let target = ClusterCoordinator()
        await source.setHandbackDrainHandler { true }
        await source.setHandbackResumeHandler { await resume.mark() }
        await source.applySettings(mode: .leader, nodeName: "Current", leaderAddress: "", listenPort: sourcePort, sharedSecret: "mesh", leaderTerm: 2)
        let sourceListening = await source.waitUntilListeningForTesting()
        XCTAssertTrue(sourceListening)
        await target.setHandbackCatchupHandler { _, _ in false }
        await target.applySettings(mode: .standby, nodeName: "Returning", leaderAddress: "http://127.0.0.1:\(sourcePort)", listenPort: targetPort, sharedSecret: "mesh", leaderTerm: 2)
        let targetListening = await target.waitUntilListeningForTesting()
        XCTAssertTrue(targetListening)
        for _ in 0..<60 where !(await source.registeredWorkerNamesForTesting()).contains("Returning") {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let handedBack = await target.requestCoordinatedHandback()
        let resumed = await resume.called
        let owns = await source.hasActiveOwnership()
        XCTAssertFalse(handedBack)
        XCTAssertTrue(resumed)
        XCTAssertTrue(owns)
        await target.stopAll()
        await source.stopAll()
    }

    func testOffloadWorksWhenWorkerCannotBeReachedInbound() async {
        let primaryPort = MeshTestPorts.free()
        let primary = ClusterCoordinator()
        let backup = ClusterCoordinator()
        await primary.configureHandlers(aiHandler: { _, _, _, _ in "local-fallback" }, wikiHandler: { _, _ in nil },
            onSnapshot: { _ in }, onJobLog: { _ in }, onSync: { _ in }, meshHandler: { _ in nil }, conversationFetcher: { _, _ in ([], false) })
        await backup.configureHandlers(aiHandler: { _, _, _, _ in "outbound-worker-result" }, wikiHandler: { _, _ in nil },
            onSnapshot: { _ in }, onJobLog: { _ in }, onSync: { _ in }, meshHandler: { _ in nil }, conversationFetcher: { _, _ in ([], false) })
        await primary.applySettings(mode: .leader, nodeName: "Dispatch", leaderAddress: "", listenPort: primaryPort, sharedSecret: "mesh", leaderTerm: 1)
        let primaryListening = await primary.waitUntilListeningForTesting()
        XCTAssertTrue(primaryListening)
        await primary.setOffloadPolicy(workerOffloadEnabled: true, aiReplies: true, wikiLookups: false)
        await backup.setPublicMeshAddress("https://127.0.0.1:1")
        await backup.applySettings(mode: .standby, nodeName: "OutboundOnly", leaderAddress: "http://127.0.0.1:\(primaryPort)", listenPort: MeshTestPorts.free(), sharedSecret: "mesh", leaderTerm: 1)
        for _ in 0..<100 {
            if !(await primary.registeredNodeInfo()).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let result = await primary.generateAIReply(messages: [])
        XCTAssertEqual(result, "outbound-worker-result")
        let role = await backup.currentSnapshot().mode
        XCTAssertEqual(role, .standby)
        await backup.stopAll()
        await primary.stopAll()
    }

    func testWebUIProxyStillRequiresMeshAuthentication() async {
        let node = ClusterCoordinator()
        let server = AdminWebServer()
        await node.applySettings(mode: .standby, nodeName: "PublicBackup", leaderAddress: "http://127.0.0.1:48100", listenPort: 48112, sharedSecret: "mesh")
        await server.setMeshRequestHandler { data, peer in await node.processHTTPRequest(data, remoteHost: peer) }
        let unsigned = Data("GET /v1/mesh/health HTTP/1.1\r\nHost: backup.example.com\r\n\r\n".utf8)
        let denied = await server.testProcessRequest(unsigned)
        XCTAssertEqual(status(denied), 401)
        let headers = await node.testMakeHMACHeaders(method: "GET", path: "/v1/mesh/health")
        var signed = "GET /v1/mesh/health HTTP/1.1\r\nHost: backup.example.com\r\n"
        for (key, value) in headers { signed += "\(key): \(value)\r\n" }
        let allowed = await server.testProcessRequest(Data((signed + "\r\n").utf8))
        XCTAssertEqual(status(allowed), 200)
        await node.stopAll()
    }

    func testOpaqueConversationCursorsAdvanceChronologicallyAndKeepScope() async {
        let store = ConversationStore()
        let later = MemoryRecord(id: "a-uuid", scope: .directMessageUser("user"), userID: "user", content: "new", timestamp: Date(timeIntervalSince1970: 20), role: .assistant)
        let earlier = MemoryRecord(id: "z-uuid", scope: .directMessageUser("user"), userID: "user", content: "old", timestamp: Date(timeIntervalSince1970: 10), role: .user)
        await store.appendMeshRecordIfAbsent(earlier)
        await store.appendMeshRecordIfAbsent(later)
        await store.appendMeshRecordIfAbsent(later)
        let advances = await store.cursorIsAfter(later.id, previous: earlier.id)
        let regresses = await store.cursorIsAfter(earlier.id, previous: later.id)
        let messages = await store.messages(in: .directMessageUser("user"))
        let replay = await store.recordsSince(fromRecordID: "missing-after-restart", limit: 1)
        XCTAssertTrue(advances)
        XCTAssertFalse(regresses)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(replay.records.map(\.id), [earlier.id])
        XCTAssertTrue(replay.hasMore)
    }

    func testTimestampedReplicationCursorRejectsDelayedOlderPage() async {
        let node = ClusterCoordinator()
        await node.updateReplicationCursor(for: "Backup", lastSentRecordID: "z-old", term: 1)
        await node.updateReplicationCursor(for: "Backup", lastSentRecordID: "a-new", term: 1,
            lastSentRecordTimestamp: Date(timeIntervalSince1970: 20), fromRecordID: "z-old")
        await node.updateReplicationCursor(for: "Backup", lastSentRecordID: "z-old", term: 1,
            lastSentRecordTimestamp: Date(timeIntervalSince1970: 10), fromRecordID: "a-new")
        let cursor = await node.currentReplicationCursor(for: "Backup")
        XCTAssertEqual(cursor?.lastSentRecordID, "a-new")
        XCTAssertEqual(cursor?.lastSentRecordTimestamp, Date(timeIntervalSince1970: 20))
    }

    @MainActor
    func testRequestedHistoryPageFillsOlderGapWithoutRegressingLocalCursor() async {
        let model = AppModel(discordRESTSession: URLSession.shared)
        let latest = MemoryRecord(id: "a-latest", scope: .guildTextChannel("channel"), userID: "user", content: "latest", timestamp: Date(timeIntervalSince1970: 20), role: .user)
        let older = MemoryRecord(id: "z-older", scope: .guildTextChannel("channel"), userID: "user", content: "older", timestamp: Date(timeIntervalSince1970: 10), role: .user)
        await model.conversationStore.appendMeshRecordIfAbsent(latest)
        model.localLastMergedRecordID = latest.id
        let page = MeshSyncPayload(conversations: [older], leaderTerm: 0, cursorRecordID: older.id, fromCursorRecordID: "missing-prior-cursor")
        await model.handleMeshSync(page, paginate: false)
        let records = await model.conversationStore.allRecordsSorted()
        XCTAssertEqual(records.map(\.id), [older.id, latest.id])
        XCTAssertEqual(model.localLastMergedRecordID, latest.id)
        XCTAssertFalse(model.logs.lines.contains { $0.contains("gap detected") })
    }

    func testLeaseDeadlineClosesOutputWithoutRenewalTask() async {
        let service = DiscordService(aiService: DiscordAIService())
        await service.setOutputAllowed(true)
        await service.setOutputLeaseDeadline(ContinuousClock.now.advanced(by: .milliseconds(30)))
        try? await Task.sleep(for: .milliseconds(60))
        let allowed = await service.outputAllowed
        XCTAssertFalse(allowed)
    }

    func testWitnessNameChangePreservesLeaseAndStableIdentity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WitnessNameURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); WitnessNameURLProtocol.setHandler(nil) }
        WitnessNameURLProtocol.setHandler { request in
            let data = WitnessNameURLProtocol.body(of: request)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["nodeID"] as? String, "stable-node-id")
            XCTAssertEqual(body["clusterID"] as? String, "cluster")
            let path = request.url!.lastPathComponent
            XCTAssertEqual(body["nodeName"] as? String, path == "acquire" ? "Primary Mac" : "Office Mac")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let reply = path == "release" ? #"{"released":true}"# : #"{"ownerNodeID":"stable-node-id","term":4,"expiresInSeconds":30}"#
            return (response, Data(reply.utf8))
        }
        let settings = MeshWitnessConfiguration(endpoint: "https://witness.example.com", clusterID: "cluster", token: String(repeating: "t", count: 32))
        let client = MeshWitnessClient(session: session)
        await client.configure(settings, nodeID: "stable-node-id", nodeName: " Primary Mac ")
        let term = await client.acquire(minimumTerm: 3)
        XCTAssertEqual(term, 4)
        let existingDeadline = await client.leaseDeadline()
        let before = try XCTUnwrap(existingDeadline)
        await client.configure(settings, nodeID: "stable-node-id", nodeName: "Office Mac")
        let afterRename = await client.leaseDeadline()
        XCTAssertEqual(afterRename, before)
        let renewed = await client.renew(term: 4)
        XCTAssertEqual(renewed, .renewed)
        await client.release(term: 4)
        let afterRelease = await client.leaseDeadline()
        XCTAssertNil(afterRelease)
    }

    /// Ruru refusing ends the lease; no answer (or its restart quarantine)
    /// only does once this Mac's own deadline has passed.
    func testRenewalSeparatesRefusalFromNoAnswer() async {
        final class Status: @unchecked Sendable { var renewal = 200 }
        let status = Status()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WitnessNameURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); WitnessNameURLProtocol.setHandler(nil) }
        WitnessNameURLProtocol.setHandler { request in
            let code = request.url!.lastPathComponent == "renew" ? status.renewal : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            let body = code == 200 ? #"{"ownerNodeID":"stable-node-id","term":4,"expiresInSeconds":30}"# : #"{"error":"x"}"#
            return (response, Data(body.utf8))
        }
        let client = MeshWitnessClient(session: session)
        await client.configure(MeshWitnessConfiguration(endpoint: "https://witness.example.com", clusterID: "cluster",
                                                        token: String(repeating: "t", count: 32)), nodeID: "stable-node-id")
        _ = await client.acquire(minimumTerm: 3)
        status.renewal = 503
        let quarantined = await client.renew(term: 4)
        XCTAssertEqual(quarantined, .unreachable(stillValid: true))
        status.renewal = 409
        let refused = await client.renew(term: 4)
        XCTAssertEqual(refused, .lost)
        let otherTerm = await client.renew(term: 9)
        XCTAssertEqual(otherTerm, .lost)
    }

    func testRuruFingerprintOmitsTheToken() {
        let witness = MeshWitnessConfiguration(endpoint: "https://Ruru.Example.com/", clusterID: "swiftmesh", token: String(repeating: "s", count: 40))
        XCTAssertEqual(witness.ownershipFingerprint, "swiftmesh@ruru.example.com")
        XCTAssertNil(MeshWitnessConfiguration().ownershipFingerprint)
    }

    func testStandbyReportsAuthenticatedPresenceWithoutAcquiringOwnership() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WitnessNameURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); WitnessNameURLProtocol.setHandler(nil) }
        WitnessNameURLProtocol.setHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "t", count: 32))
            let reply: String
            switch request.url!.path {
            case "/v1/service":
                reply = #"{"version":1,"authority":"Ruru","clusterID":"cluster","capabilities":{"participantPresence":{"version":1,"enabled":true}}}"#
            case "/v1/participants/report":
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: WitnessNameURLProtocol.body(of: request)) as? [String: Any])
                XCTAssertEqual(body["version"] as? Int, 1)
                XCTAssertEqual(body["clusterID"] as? String, "cluster")
                XCTAssertEqual(body["nodeID"] as? String, "stable-backup")
                XCTAssertEqual(body["nodeName"] as? String, "JohnBook Pro")
                XCTAssertEqual(body["role"] as? String, "standby")
                XCTAssertNil(body["term"])
                reply = #"{"version":1,"accepted":true}"#
            default:
                XCTFail("Presence must not acquire ownership: \(request.url!.path)")
                reply = "{}"
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(reply.utf8))
        }
        let client = MeshWitnessClient(session: session)
        await client.configure(.init(endpoint: "https://ruru.example.com", clusterID: "cluster", token: String(repeating: "t", count: 32)),
                               nodeID: "stable-backup", nodeName: "JohnBook Pro")
        let accepted = await client.reportPresence(role: .standby)
        XCTAssertTrue(accepted)
        let deadline = await client.leaseDeadline()
        XCTAssertNil(deadline)
    }

    func testUnsupportedOrUnauthorizedPresenceDoesNotChangeLease() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WitnessNameURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); WitnessNameURLProtocol.setHandler(nil) }
        for supported in [false, true] {
            WitnessNameURLProtocol.setHandler { request in
                let reply: String
                var status = 200
                switch request.url!.path {
                case "/v1/lease/acquire": reply = #"{"ownerNodeID":"node","term":4,"expiresInSeconds":30}"#
                case "/v1/service":
                    reply = supported
                        ? #"{"version":1,"authority":"Ruru","clusterID":"cluster","capabilities":{"participantPresence":{"version":1,"enabled":true}}}"#
                        : #"{"version":1,"authority":"Ruru","clusterID":"cluster","capabilities":{"lease":{"version":1,"enabled":true}}}"#
                case "/v1/participants/report":
                    XCTAssertTrue(supported, "Old Ruru must not receive presence reports")
                    status = 401; reply = #"{"error":"unauthorized"}"#
                default: XCTFail("Unexpected route"); reply = "{}"
                }
                return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(reply.utf8))
            }
            let client = MeshWitnessClient(session: session)
            await client.configure(.init(endpoint: "https://ruru.example.com", clusterID: "cluster", token: String(repeating: "t", count: 32)), nodeID: "node")
            _ = await client.acquire(minimumTerm: 3)
            let before = await client.leaseDeadline()
            let reported = await client.reportPresence(role: .active)
            XCTAssertFalse(reported)
            let after = await client.leaseDeadline()
            XCTAssertEqual(after, before)
        }
    }

    func testInvalidWitnessDisplayNameIsOmittedWithoutBlockingOwnership() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WitnessNameURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); WitnessNameURLProtocol.setHandler(nil) }
        WitnessNameURLProtocol.setHandler { request in
            let body = try JSONSerialization.jsonObject(with: WitnessNameURLProtocol.body(of: request)) as? [String: Any]
            XCTAssertNil(body?["nodeName"])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"ownerNodeID":"stable-node-id","term":1,"expiresInSeconds":30}"#.utf8))
        }
        let client = MeshWitnessClient(session: session)
        let settings = MeshWitnessConfiguration(endpoint: "https://witness.example.com", clusterID: "cluster", token: String(repeating: "t", count: 32))
        await client.configure(settings, nodeID: "stable-node-id", nodeName: "two\nlines")
        let acquired = await client.acquire(minimumTerm: 0)
        XCTAssertEqual(acquired, 1)
    }
}

private final class WitnessNameURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(_ value: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        lock.withLock { handler = value }
    }
    static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// Two-node mesh tests used fixed listen ports, and `-test-iterations` rebinds
/// them while the previous iteration's listener may still hold the port. The
/// standby's first registration also races the owner's listener start. These
/// helpers give each pair fresh ports and let a test wait until a node is
/// actually listening, so registration doesn't depend on retry timing.
enum MeshTestPorts {
    /// A port the kernel just handed out as free. Binding and closing an
    /// unconnected socket leaves no TIME_WAIT behind.
    static func free() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0, "socket() failed")
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        precondition(bound, "bind()/getsockname() failed")
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

extension ClusterCoordinator {
    /// Polls until the mesh listener reports ready. Returns false on timeout.
    func waitUntilListeningForTesting(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if currentSnapshot().serverState == .listening { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return currentSnapshot().serverState == .listening
    }
}
