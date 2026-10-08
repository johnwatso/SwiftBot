import Foundation
import Network
import XCTest
import RecordingsKit
@testable import SwiftBot

/// In-memory Ruru wire fixture and real SwiftBot HTTP routers, with loopback
/// listeners for redirects. No Keychain, Discord, login items or live folders.
final class RecordingCoordinationTests: XCTestCase {
    private static let witness = MeshWitnessConfiguration(endpoint: "https://ruru.example", clusterID: "recordings-test",
                                                    token: String(repeating: "r", count: 40))

    private static func setup(_ fixture: RecordingWireFixture, clock: RecordingTestClock = .init()) async -> RecordingDirectoryClient {
        RecordingWireProtocol.state.set(fixture)
        let directory = RecordingDirectoryClient(session: Self.session(), now: clock.now)
        await directory.configure(.init(witness: witness, nodeID: "john", nodeName: "Same name",
                                        libraryURL: "https://john.example/v1/media/library", enabled: true))
        return directory
    }

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingWireProtocol.self]
        return URLSession(configuration: config, delegate: RecordingRedirectPolicy(), delegateQueue: nil)
    }

    override func tearDown() {
        RecordingWireProtocol.state.set(nil)
        super.tearDown()
    }

    func testDirectoryReportsOneLibraryAndDropsStaleOrUnapprovedLocations() async throws {
        let fixture = RecordingWireFixture()
        await fixture.setLocations([
            .init(id: "max", url: "https://max.example/v1/media/library"),
            .init(id: "old", url: "https://max.example/v1/media/library", age: 90, fresh: false),
            .init(id: "evil", url: "https://evil.example/v1/media/library"),
            .init(id: "query", url: "https://max.example/v1/media/library?token=secret"),
            .init(id: "wrong-path", url: "https://max.example/v1/mesh/credentials")
        ])
        let directory = await Self.setup(fixture)
        let snapshot = await directory.refresh()
        XCTAssertEqual(snapshot.libraries.map(\.nodeID), ["max"])
        let requests = await fixture.requests
        let report = try XCTUnwrap(requests.first { $0.path == "/v1/coordination/report" })
        XCTAssertEqual(report.authorization, "Bearer " + Self.witness.token)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: report.body) as? [String: Any])
        XCTAssertEqual(json["nodeID"] as? String, "john")
        let resources = try XCTUnwrap(json["resources"] as? [[String: String]])
        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(resources[0]["namespace"], RecordingDirectoryClient.namespace)
        XCTAssertEqual(resources[0]["url"], "https://john.example/v1/media/library")
        XCTAssertNil(json["term"])
        XCTAssertTrue(requests.allSatisfy { $0.host == "ruru.example" && $0.path.hasPrefix("/v1/coordination/") })
    }

    func testExpiryOutageRevocationAndReReportingAfterRuruRestart() async {
        let fixture = RecordingWireFixture()
        let clock = RecordingTestClock()
        let directory = await Self.setup(fixture, clock: clock)
        let initial = await directory.refresh()
        XCTAssertEqual(initial.libraries.count, 1)
        clock.advance(30)
        await fixture.setCapabilityStatus(503)
        let outage = await directory.refresh(force: true)
        XCTAssertEqual(outage.libraries.count, 1)
        clock.advance(60)
        let expired = await directory.snapshot()
        XCTAssertTrue(expired.libraries.isEmpty)
        await fixture.setCapabilityStatus(200)
        await fixture.setLocations([])
        let restarted = await directory.refresh(force: true)
        XCTAssertTrue(restarted.libraries.isEmpty)
        let reports = await fixture.requests.filter { $0.path == "/v1/coordination/report" }
        XCTAssertEqual(reports.count, 2, "Report the local library again after Ruru loses its observations")
        await fixture.setLocations([.init(id: "max", url: "https://max.example/v1/media/library")])
        let recovered = await directory.refresh(force: true)
        XCTAssertEqual(recovered.libraries.count, 1)
        await fixture.setCapabilityStatus(403)
        let revoked = await directory.refresh(force: true)
        XCTAssertTrue(revoked.libraries.isEmpty, "Explicit revocation must discard even fresh cached destinations")
    }

    func testCatalogueConflictDiscardsPartialPagesAndRetries() async {
        let fixture = RecordingWireFixture()
        await fixture.enablePaginationConflict()
        let directory = await Self.setup(fixture)
        let snapshot = await directory.refresh()
        XCTAssertEqual(snapshot.libraries.map(\.nodeID), ["max"])
        let offsets = await fixture.requestedOffsets
        XCTAssertEqual(offsets, [0, 20, 0, 20])
    }

    func testPairingEnrollmentProposesWebsiteAndPublishesOnlyAfterOperatorApproval() async throws {
        let fixture = RecordingWireFixture()
        await fixture.setEnrollmentPolicy(enabled: false, origins: [], status: "pending")
        let directory = await Self.setup(fixture)
        let pending = await directory.refresh()
        XCTAssertTrue(pending.libraries.isEmpty)
        XCTAssertTrue(pending.message.contains("approve https://john.example"))
        let requests = await fixture.requests
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("report") })
        let proposal = try XCTUnwrap(requests.first { $0.path.hasSuffix("enrollment") })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: proposal.body) as? [String: Any])
        XCTAssertEqual(json["origin"] as? String, "https://john.example")
        XCTAssertEqual(json["nodeID"] as? String, "john")
        XCTAssertEqual(json["withdraw"] as? Bool, false)
        XCTAssertNil(json["term"])
        await fixture.setEnrollmentPolicy(enabled: true, origins: ["https://john.example", "https://max.example"], status: "approved")
        let approved = await directory.refresh(force: true)
        XCTAssertEqual(approved.libraries.map(\.nodeID), ["max"])
        let published = await fixture.requests.filter { $0.path.hasSuffix("report") }
        XCTAssertEqual(published.count, 1)
    }

    func testEnrollmentRejectionAndLegacyRuruRemainExplicitAndDoNotRetainRevokedRoutes() async {
        let fixture = RecordingWireFixture()
        let directory = await Self.setup(fixture)
        _ = await directory.refresh()
        await fixture.setEnrollmentPolicy(enabled: false, origins: [], status: "rejected")
        let rejected = await directory.refresh(force: true)
        XCTAssertTrue(rejected.libraries.isEmpty)
        XCTAssertTrue(rejected.message.contains("declined"))
        await fixture.setEnrollmentPolicy(enabled: false, origins: [], status: "pending", supported: nil)
        let before = await fixture.requests.count
        let legacy = await directory.refresh(force: true)
        XCTAssertTrue(legacy.message.contains("Enable Resource catalogue"))
        let after = await fixture.requests.dropFirst(before)
        XCTAssertFalse(after.contains { $0.path.hasSuffix("enrollment") })
    }

    @MainActor
    func testPairingSharesOnlyThisMacWebsiteUsingTheNewEnrollmentAndPersistsItsChoice() async throws {
        XCTAssertTrue(KeychainHelper.isRunningUnderXCTest)
        let realAccesses = KeychainHelper.realKeychainAccessCount.load(ordering: .relaxed)
        let previousWitness = MeshWitnessSettingsStore.load()
        let previousEnrollment = KeychainHelper.load(account: "swiftmesh-credential-enrollment")
        let issuerAccount = "recording-pairing-test-\(UUID())"
        defer {
            MeshWitnessSettingsStore.save(previousWitness)
            if let previousEnrollment { _ = KeychainHelper.save(previousEnrollment, account: "swiftmesh-credential-enrollment") }
            else { _ = KeychainHelper.delete(account: "swiftmesh-credential-enrollment") }
            _ = KeychainHelper.delete(account: issuerAccount)
        }
        let fixture = RecordingWireFixture()
        await fixture.setEnrollmentPolicy(enabled: false, origins: [], status: "pending")
        RecordingWireProtocol.state.set(fixture)
        let directory = RecordingDirectoryClient(session: Self.session())
        let app = AppModel(recordingDirectory: directory)
        addTeardownBlock { await app.cluster.stopAll() }
        app.settings.adminWebUI.enabled = true
        app.settings.adminWebUI.internetAccessEnabled = false
        app.settings.adminWebUI.publicBaseURL = "https://max.example"
        let enrollment = try await MeshCredentialEnrollmentStore(account: issuerAccount).issueGrant(nodeName: "Backup")
        let bundle = SwiftMeshJoinBundle(leaderAddresses: ["127.0.0.1"], leaderPort: 39195, sharedSecret: "test-only-pairing-secret",
                                        credentialEnrollment: enrollment, witness: Self.witness)
        let code = "swiftmesh://join?b=" + (try JSONEncoder().encode(bundle)).base64EncodedString()
        let result = await app.applySwiftMeshJoinCode(code, shareRecordings: true)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(app.meshLocalNodeID, enrollment.nodeID)
        XCTAssertEqual(app.settings.clusterMode, .standby)
        XCTAssertEqual(app.settings.adminWebUI.publicBaseURL, "https://max.example")
        XCTAssertTrue(app.mediaLibrarySettings.sharedLibraryEnabled)
        let snapshot = await directory.refresh(force: true)
        XCTAssertTrue(snapshot.message.contains("approve https://max.example"))
        let requests = await fixture.requests
        let proposal = try XCTUnwrap(requests.first { $0.path.hasSuffix("enrollment") })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: proposal.body) as? [String: Any])
        XCTAssertEqual(json["nodeID"] as? String, enrollment.nodeID)
        XCTAssertEqual(json["origin"] as? String, "https://max.example")
        XCTAssertTrue(requests.allSatisfy { $0.path.hasPrefix("/v1/coordination/") })
        let persisted = await app.mediaLibraryConfigStore.load()
        XCTAssertTrue(persisted.sharedLibraryEnabled)
        for _ in 0..<100 {
            if await app.cluster.currentSnapshot().mode == .standby { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let role = await app.cluster.currentSnapshot().mode
        XCTAssertEqual(role, .standby)
        await app.cluster.stopAll()
        XCTAssertEqual(KeychainHelper.realKeychainAccessCount.load(ordering: .relaxed), realAccesses)
    }

    func testRuruAndMediaRedirectsDoNotSendCredentialsToAnotherOrigin() async throws {
        let sink = try RecordingRedirectServer()
        try await sink.start()
        defer { sink.stop() }
        let source = try RecordingRedirectServer(redirect: "http://localhost:\(sink.port)/stolen")
        try await source.start()
        defer { source.stop() }
        let directory = RecordingDirectoryClient()
        await directory.configure(.init(witness: .init(endpoint: source.origin, clusterID: "test", token: String(repeating: "r", count: 40)),
                                        nodeID: "john", nodeName: "John", enabled: true))
        let snapshot = await directory.refresh()
        XCTAssertTrue(snapshot.libraries.isEmpty)
        let cluster = ClusterCoordinator()
        await cluster.recordingTestPlacement(.standby)
        let media = await cluster.fetchRemoteMediaStream(from: source.origin, itemID: "clip", rangeHeader: "bytes=0-3")
        XCTAssertNil(media)
        XCTAssertEqual(source.requests, 2)
        XCTAssertEqual(sink.requests, 0, "Neither bearer tokens nor mesh HMAC headers may follow a redirect")
    }

    func testDisablingWithdrawsLocationAndChangingServiceClearsRoutes() async throws {
        let fixture = RecordingWireFixture()
        let directory = await Self.setup(fixture)
        _ = await directory.refresh()
        await directory.configure(.init(witness: Self.witness, nodeID: "john", nodeName: "John",
                                        libraryURL: "https://john.example/v1/media/library", enabled: false))
        let snapshot = await directory.snapshot()
        XCTAssertTrue(snapshot.libraries.isEmpty)
        let last = await fixture.requests.last { $0.path.hasSuffix("report") }
        let removal = try XCTUnwrap(last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: removal.body) as? [String: Any])
        XCTAssertEqual((json["resources"] as? [Any])?.count, 0)
        XCTAssertEqual((json["removed"] as? [[String: String]])?.first?["resourceID"], "library")
        XCTAssertNil((json["removed"] as? [[String: String]])?.first?["url"])
        let withdrawn = await fixture.requests.last { $0.path.hasSuffix("enrollment") }
        let withdrawal = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(withdrawn).body) as? [String: Any])
        XCTAssertEqual(withdrawal["withdraw"] as? Bool, true)
    }

    @MainActor
    func testCombinedViewAndAuthenticatedMaxPlaybackRegardlessOfSavedOrRuntimeRole() async throws {
        let fixture = RecordingWireFixture()
        let clock = RecordingTestClock()
        let directory = await Self.setup(fixture, clock: clock)
        let max = ClusterCoordinator()
        await max.recordingTestPlacement(.standby)
        await max.setRecordingAccessProvider { true }
        let source = MediaLibrarySource(name: "Max captures", rootPath: "/test-only", allowedExtensions: ["mp4"])
        let clips = (0..<200).map { index in
            MediaLibraryItem(id: "max-clip-\(index)", sourceID: source.id, sourceName: source.name,
                             fileName: "clip-\(index).mp4", relativePath: "clip-\(index).mp4", absolutePath: "/test-only/clip-\(index).mp4",
                             fileExtension: "mp4", sizeBytes: 100, modifiedAt: Date(timeIntervalSince1970: 2_000_000_000 - Double(index)), ownerNodeName: "Same name",
                             ownerBaseURL: "https://evil.example")
        }
        let maxLibrary = MediaLibraryPayload(nodeName: "Same name", configFilePath: "test-only",
                                              sources: [source], items: clips, generatedAt: Date(), nodeID: "max")
        await max.configureHandlers(aiHandler: { _, _, _, _ in nil }, wikiHandler: { _, _ in nil },
            onSnapshot: { _ in }, onJobLog: { _ in }, onSync: { _ in }, meshHandler: { _ in nil },
            mediaLibraryProvider: { maxLibrary }, mediaPlaybackHandler: { _ in ("original", false) },
            mediaStreamHandler: { id, range, _ in
                guard id == "max-clip-0", range == "bytes=2-5" else { return nil }
                return BinaryHTTPResponse(status: "206 Partial Content", contentType: "video/mp4",
                    headers: ["Content-Range": "bytes 2-5/10", "Accept-Ranges": "bytes"], body: Data("2345".utf8))
            }, conversationFetcher: { _, _ in ([], false) })
        let publicServer = AdminWebServer()
        await publicServer.setRecordingRequestHandler { request, peer in
            await max.processHTTPRequest(request, remoteHost: peer)
        }
        await fixture.setMaxServer(publicServer)

        let john = ClusterCoordinator(mediaSession: Self.session())
        await john.recordingTestPlacement(.leader)
        let app = AppModel(recordingDirectory: directory, recordingCluster: john)
        app.meshLocalNodeID = "john"
        app.settings.clusterNodeName = "Same name"
        app.settings.clusterMode = .standby
        app.mediaLibrarySettings.sharedLibraryEnabled = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("john recording".utf8).write(to: folder.appendingPathComponent("john.mp4"))
        app.mediaLibrarySettings.sources = [.init(name: "John captures", rootPath: folder.path)]

        for role in [ClusterMode.leader, .standby] {
            app.lastPublishedRole = role
            let view = await app.adminWebMediaLibrarySnapshot(query: ["pageSize": "96"])
            XCTAssertEqual(view.totalItems, 201, "Full libraries are not limited to 128 Ruru recording entries")
            XCTAssertEqual(Set(view.sources.map(\.id)).count, 2, "Same display names must not collapse stable node identities")
            let payloads = await app.allMediaLibraryPayloads()
            XCTAssertEqual(Set(payloads.map(\.identity)), ["john", "max"])
            let maxItem = try XCTUnwrap(view.items.first { $0.id == "max|max-clip-0" })
            let token = try XCTUnwrap(URLComponents(string: maxItem.streamURL)?.queryItems?.first { $0.name == "id" }?.value)
            let descriptor = try XCTUnwrap(app.decodedMediaStreamToken(token))
            XCTAssertEqual(descriptor.ownerNodeID, "max")
            XCTAssertNil(descriptor.ownerBaseURL)
            let response = await app.adminWebMediaStreamResponse(token: token, rangeHeader: "bytes=2-5")
            XCTAssertEqual(response?.body, Data("2345".utf8))
            XCTAssertEqual(response?.headers["Content-Range"], "bytes 2-5/10")
        }
        let requests = await fixture.requests
        XCTAssertTrue(requests.filter { $0.path == "/v1/media/stream" }.allSatisfy { $0.host == "max.example" })
        XCTAssertTrue(requests.filter { $0.host == "ruru.example" }.allSatisfy { $0.path.hasPrefix("/v1/coordination/") })
        let role = await max.currentSnapshot().mode
        XCTAssertEqual(role, .standby, "Serving recordings must not acquire bot ownership")

        let forged = MediaStreamDescriptor(itemID: "max-clip-0", ownerNodeName: "Same name",
                                           ownerBaseURL: "https://evil.example", ownerNodeID: "unknown")
        let rejected = await app.recordingRoute(for: forged)
        XCTAssertNil(rejected)
        var changedURL = forged
        changedURL.ownerNodeID = "max"
        guard case .remote(let resolved)? = await app.recordingRoute(for: changedURL) else { return XCTFail("Expected trusted directory route") }
        XCTAssertEqual(resolved, "https://max.example")

        clock.advance(90)
        await fixture.setCapabilityStatus(503)
        let expiredRoute = await app.recordingRoute(for: changedURL)
        XCTAssertNil(expiredRoute, "Retained metadata must not authorize playback after the directory expires")
        let unavailable = await app.adminWebMediaLibrarySnapshot(query: ["pageSize": "96"])
        XCTAssertEqual(unavailable.totalItems, 201, "Keep recently known unavailable clips visible")
        XCTAssertFalse(try XCTUnwrap(unavailable.items.first { $0.id == "max|max-clip-0" }).available ?? true)
    }

    func testPublicMediaReadsRequireHMACAndOptInAndDoNotExposeExports() async {
        let max = ClusterCoordinator()
        await max.recordingTestPlacement(.standby)
        let server = AdminWebServer()
        await server.setRecordingRequestHandler { request, peer in await max.processHTTPRequest(request, remoteHost: peer) }
        let unsigned = await server.testProcessRequest(Self.rawRequest(path: "/v1/media/library"))
        XCTAssertEqual(Self.status(unsigned), 401)
        let headers = await max.testMakeHMACHeaders(method: "GET", path: "/v1/media/library")
        let disabled = await server.testProcessRequest(Self.rawRequest(path: "/v1/media/library", headers: headers))
        XCTAssertEqual(Self.status(disabled), 403)
        await max.setRecordingAccessProvider { true }
        for path in ["/v1/media/clip", "/v1/media/multiview", "/v1/media/unknown"] {
            let response = await server.testProcessRequest(Self.rawRequest(path: path, method: "POST"))
            XCTAssertEqual(Self.status(response), 404)
        }
        let unhandled = await AdminWebServer().testProcessRequest(Self.rawRequest(path: "/v1/media/library"))
        XCTAssertEqual(Self.status(unhandled), 404)
    }

    func testMemberPlaybackTokenCannotBypassClipPermission() async {
        let server = AdminWebServer()
        let member = await server.testSeedSession(memberRole: true)
        let access = await server.testMintMediaAccessToken(sessionID: member.id)
        for path in ["/api/media/stream", "/api/media/thumbnail", "/api/media/playback"] {
            let response = await server.testProcessRequest(Self.rawRequest(path: path + "?id=someone-elses-clip&token=" + access))
            XCTAssertEqual(Self.status(response), 403)
        }
    }

    func testLegacyPreferencesAndUnavailableFolders() throws {
        let settings = try JSONDecoder().decode(MediaLibrarySettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.sharedLibraryEnabled)
        let descriptor = try JSONDecoder().decode(MediaStreamDescriptor.self, from: Data(#"{"itemID":"old","ownerNodeName":"John"}"#.utf8))
        XCTAssertNil(descriptor.ownerNodeID)
        let source = UUID()
        let item = MediaLibraryItem(id: "clip", sourceID: source, sourceName: "folder", fileName: "clip.mp4",
            relativePath: "clip.mp4", absolutePath: "/test-only", fileExtension: "mp4", sizeBytes: 1,
            modifiedAt: Date(), ownerNodeName: "Max")
        let payload = MediaLibraryPayload(nodeName: "Max", configFilePath: "", sources: [], items: [item],
            generatedAt: Date(), unavailableSourceIDs: [source])
        XCTAssertFalse(payload.isAvailable(item))
    }

    static func rawRequest(path: String, method: String = "GET", headers: [String: String] = [:]) -> Data {
        let fields = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        return Data("\(method) \(path) HTTP/1.1\r\nHost: test-only\r\n\(fields)\r\n".utf8)
    }
    static func status(_ raw: Data) -> Int {
        Int(String(decoding: raw.prefix(64), as: UTF8.self).split(separator: " ").dropFirst().first ?? "0") ?? 0
    }
}

private extension ClusterCoordinator {
    func recordingTestPlacement(_ role: ClusterMode) {
        mode = role
        snapshot.mode = role
        sharedSecret = "recording-test-mesh"
    }
}

private final class RecordingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ seconds: Int) { lock.withLock { instant = instant.advanced(by: .seconds(seconds)) } }
}

private actor RecordingWireFixture {
    struct Entry: Sendable {
        var id: String
        var url: String
        var age = 0.0
        var fresh = true
    }
    struct Request: Sendable {
        var host: String
        var path: String
        var authorization: String?
        var body: Data
    }
    var requests: [Request] = []
    var requestedOffsets: [Int] = []
    private var locations: [Entry] = [.init(id: "max", url: "https://max.example/v1/media/library")]
    private var capabilityStatus = 200
    private var coordinationEnabled = true
    private var allowedOrigins = ["https://john.example", "https://max.example"]
    private var enrollmentSupported: Bool?
    private var enrollmentStatus = "pending"
    private var pagination = false
    private var conflict = false
    private var maxServer: AdminWebServer?
    func setLocations(_ next: [Entry]) { locations = next }
    func setCapabilityStatus(_ next: Int) { capabilityStatus = next }
    func setEnrollmentPolicy(enabled: Bool, origins: [String], status: String, supported: Bool? = true) {
        coordinationEnabled = enabled; allowedOrigins = origins
        enrollmentStatus = status; enrollmentSupported = supported
    }
    func enablePaginationConflict() { pagination = true; conflict = true }
    func setMaxServer(_ server: AdminWebServer) { maxServer = server }

    func respond(_ request: URLRequest, body: Data) async -> (Int, Data, [String: String]) {
        let url = request.url!
        requests.append(.init(host: url.host ?? "", path: url.path,
                              authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
        if url.host == "max.example", let maxServer {
            let path = url.path + (url.query.map { "?" + $0 } ?? "")
            let raw = RecordingCoordinationTests.rawRequest(path: path, headers: request.allHTTPHeaderFields ?? [:])
            let response = await maxServer.testProcessRequest(raw)
            guard let separator = response.range(of: Data("\r\n\r\n".utf8)) else { return (500, Data(), [:]) }
            let head = String(decoding: response[..<separator.lowerBound], as: UTF8.self)
            var headers: [String: String] = [:]
            for line in head.components(separatedBy: "\r\n").dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { headers[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces) }
            }
            return (RecordingCoordinationTests.status(response), Data(response[separator.upperBound...]), headers)
        }
        guard url.host == "ruru.example" else { return (500, Data(), [:]) }
        if url.path.hasSuffix("capabilities") {
            var reply: [String: Any] = ["version": 1, "clusterID": "recordings-test", "enabled": coordinationEnabled,
                "capabilities": coordinationEnabled ? ["resource-catalogue.v1"] : [], "allowedOrigins": allowedOrigins]
            if let enrollmentSupported { reply["enrollmentSupported"] = enrollmentSupported }
            return json(capabilityStatus, reply)
        }
        if url.path.hasSuffix("report") { return json(200, ["version": 1, "accepted": true]) }
        let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        if url.path.hasSuffix("enrollment") {
            return json(200, ["version": 1, "clusterID": "recordings-test", "status": input["withdraw"] as? Bool == true ? "withdrawn" : enrollmentStatus])
        }
        let offset = input["offset"] as? Int ?? 0
        requestedOffsets.append(offset)
        if pagination, offset == 20, conflict { conflict = false; return json(409, ["error": "catalogue_changed"]) }
        if pagination, offset == 0 {
            let fillers = (0..<20).map { index in
                ["clusterID": "recordings-test", "nodeID": "other", "resource": ["namespace": "artifacts", "resourceID": "\(index)", "url": "https://max.example/item"],
                 "ageSeconds": 0, "fresh": true] as [String: Any]
            }
            return json(200, ["version": 1, "clusterID": "recordings-test", "revision": "revision", "locations": fillers, "nextOffset": 20])
        }
        return json(200, ["version": 1, "clusterID": "recordings-test", "revision": "revision",
            "locations": locations.map { entry in
                ["clusterID": "recordings-test", "nodeID": entry.id, "nodeName": "Same name",
                 "resource": ["namespace": RecordingDirectoryClient.namespace, "resourceID": "library", "title": "Library", "url": entry.url],
                 "ageSeconds": entry.age, "fresh": entry.fresh] as [String: Any]
            }])
    }
    private func json(_ status: Int, _ value: [String: Any]) -> (Int, Data, [String: String]) {
        (status, try! JSONSerialization.data(withJSONObject: value), ["Content-Type": "application/json"])
    }
}

private final class RecordingWireState: @unchecked Sendable {
    private let lock = NSLock()
    private var fixture: RecordingWireFixture?
    func set(_ fixture: RecordingWireFixture?) { lock.withLock { self.fixture = fixture } }
    func get() -> RecordingWireFixture? { lock.withLock { fixture } }
}

private final class RecordingWireProtocol: URLProtocol {
    static let state = RecordingWireState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = Data() }
        let completion = RecordingProtocolCompletion(self)
        let request = self.request
        Task { [completion, request, body] in
            guard let fixture = Self.state.get() else { return }
            let (status, data, headers) = await fixture.respond(request, body: body)
            completion.deliver(status: status, data: data, headers: headers, request: request)
        }
    }
    override func stopLoading() {}
}

/// URLProtocol's client callbacks may be delivered from a background queue.
/// This fixture gives a single task exclusive responsibility for completion.
private final class RecordingProtocolCompletion: @unchecked Sendable {
    private let loader: URLProtocol
    init(_ loader: URLProtocol) { self.loader = loader }
    func deliver(status: Int, data: Data, headers: [String: String], request: URLRequest) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
        loader.client?.urlProtocol(loader, didLoad: data)
        loader.client?.urlProtocolDidFinishLoading(loader)
    }
}

/// Real loopback redirects exercise URLSession's delegate; URLProtocol cannot
/// emulate that transport callback reliably. Both listeners bind only loopback.
private final class RecordingRedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "recording-redirect-test")
    private let lock = NSLock()
    private var count = 0
    private var ready = false
    private let redirect: String?
    var port: UInt16 { listener.port!.rawValue }
    var origin: String { "http://127.0.0.1:\(port)" }
    var requests: Int { lock.withLock { count } }
    init(redirect: String? = nil) throws {
        self.redirect = redirect
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    if lock.withLock({ if ready { return false }; ready = true; return true }) {
                        continuation.resume()
                    }
                case .failed(let error):
                    if lock.withLock({ if ready { return false }; ready = true; return true }) {
                        continuation.resume(throwing: error)
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(connection)
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }
    private func receive(_ connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard bytes.count <= 8192 else { connection.cancel(); return }
            guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete || error != nil { connection.cancel() }
                else { receive(connection, accumulated: bytes) }
                return
            }
            lock.withLock { count += 1 }
            let response = redirect.map { "HTTP/1.1 302 Found\r\nLocation: \($0)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
                ?? "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
