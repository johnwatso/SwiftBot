import Foundation
import Network
import Darwin
import OSLog
import CryptoKit

struct HardwareInfo: Sendable, Hashable {
    let modelIdentifier: String
    let cpuName: String
    let physicalMemoryBytes: UInt64

    static func current() -> HardwareInfo {
        HardwareInfo(
            modelIdentifier: readSysctlString("hw.model") ?? "Mac",
            cpuName: readSysctlString("machdep.cpu.brand_string") ?? "Unknown CPU",
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    private static func readSysctlString(_ key: String) -> String? {
        var length: Int = 0
        guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 1 else {
            return nil
        }

        var value = [CChar](repeating: 0, count: length)
        guard sysctlbyname(key, &value, &length, nil, 0) == 0 else {
            return nil
        }

        let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }
}

actor ClusterCoordinator {
    private let meshLogger = Logger(subsystem: "com.swiftbot", category: "mesh")

    typealias AIHandler = @Sendable ([Message], String?, String?, String?) async -> String?
    typealias WikiHandler = @Sendable (String, WikiSource) async -> FinalsWikiLookupResult?
    typealias JobLogHandler = @Sendable (CommandLogEntry) async -> Void
    typealias SyncHandler = @Sendable (MeshSyncPayload) async -> Void
    typealias MeshHandler = @Sendable (String) async -> Data?
    /// Returns (records, hasMore) for the given cursor position and batch limit.
    typealias ConversationFetcher = @Sendable (String?, Int) async -> (records: [MemoryRecord], hasMore: Bool)

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let startedAt = Date()
    private let hardwareInfo = HardwareInfo.current()
    private let workerRegistrationIntervalNanoseconds: UInt64 = 4_000_000_000
    private let registrationStaleAfter: TimeInterval = 20
    static let maxHTTPRequestSize = 1_024 * 1024
    private static let httpReadTimeout: TimeInterval = 5.0
    static let maxSyncBatchSize: Int = 500

    var mode: ClusterMode = .standalone
    var nodeName: String = Host.current().localizedName ?? "SwiftBot Node"
    var leaderAddress: String = ""
    var listenPort: Int = 38787
    var sharedSecret: String = ""
    var offloadAIReplies: Bool = true
    var offloadWikiLookups: Bool = true
    /// Nonce replay cache: maps nonce → expiry time. Swept opportunistically on each auth check.
    private var usedNonces: [String: Date] = [:]
    private var activeJobs = 0
    private var registeredWorkers: [String: RegisteredWorker] = [:]
    private var workerRegistrationTask: Task<Void, Never>?

    // SwiftMesh failover state
    var leaderTerm: Int = 0
    private var standbyMonitorTask: Task<Void, Never>?
    var standbyHealthMisses: Int = 0
    static let standbyHealthInterval: TimeInterval = 10.0
    static let standbyPromotionThreshold: Int = 3

    // Phase 2: per-node replication cursors (keyed by nodeName, persisted on leader)
    var replicationCursors: [String: ReplicationCursor] = [:]
    private var onCursorsChanged: (@Sendable ([String: ReplicationCursor]) async -> Void)?

    // P1b: LAN peer discovery via Bonjour/mDNS
    private var meshBrowser: NWBrowser?
    var discoveredPeers: [String: DiscoveredPeer] = [:]

    private var aiHandler: AIHandler?
    private var wikiHandler: WikiHandler?
    private var conversationFetcher: ConversationFetcher?
    private var listener: NWListener?
    private var listenerActivePort: Int? = nil
    private var onSnapshot: (@Sendable (ClusterSnapshot) async -> Void)?
    private var onJobLog: JobLogHandler?
    private var onSync: SyncHandler?
    private var meshHandler: MeshHandler?
    private var onTermChanged: (@Sendable (Int) async -> Void)?
    private var onPromotion: (@Sendable () async -> Void)?
    var snapshot = ClusterSnapshot()

    func configureHandlers(
        aiHandler: @escaping AIHandler,
        wikiHandler: @escaping WikiHandler,
        onSnapshot: @escaping @Sendable (ClusterSnapshot) async -> Void,
        onJobLog: @escaping JobLogHandler,
        onSync: @escaping SyncHandler,
        meshHandler: @escaping MeshHandler,
        conversationFetcher: @escaping ConversationFetcher,
        onPromotion: @escaping @Sendable () async -> Void
    ) {
        self.aiHandler = aiHandler
        self.wikiHandler = wikiHandler
        self.onSnapshot = onSnapshot
        self.onJobLog = onJobLog
        self.onSync = onSync
        self.meshHandler = meshHandler
        self.conversationFetcher = conversationFetcher
        self.onPromotion = onPromotion
    }

    func setTermChangedHandler(_ handler: @escaping @Sendable (Int) async -> Void) {
        self.onTermChanged = handler
    }

    func setCursorsChangedHandler(_ handler: @escaping @Sendable ([String: ReplicationCursor]) async -> Void) {
        self.onCursorsChanged = handler
    }

    func applyRestoredCursors(_ cursors: [String: ReplicationCursor]) {
        // Only restore cursors from the current or newer term to avoid stale replay.
        for (nodeName, cursor) in cursors where cursor.leaderTerm >= leaderTerm {
            replicationCursors[nodeName] = cursor
        }
    }

    /// Returns (nodeName, baseURL) pairs for all currently registered workers/nodes.
    func registeredNodeInfo() -> [(nodeName: String, baseURL: String)] {
        registeredWorkers.values.map { ($0.nodeName, $0.baseURL) }
    }

    func currentReplicationCursor(for nodeName: String) -> ReplicationCursor? {
        replicationCursors[nodeName]
    }

    func updateReplicationCursor(for nodeName: String, lastSentRecordID: String?, term: Int) async {
        if let existing = replicationCursors[nodeName], existing.leaderTerm > term {
            return
        }
        replicationCursors[nodeName] = ReplicationCursor(leaderTerm: term, lastSentRecordID: lastSentRecordID, updatedAt: Date())
        await onCursorsChanged?(replicationCursors)
    }

    func applySettings(mode: ClusterMode, nodeName: String, leaderAddress: String, listenPort: Int, sharedSecret: String, leaderTerm: Int = 0) async {
        // Restore persisted term; never go backwards.
        if leaderTerm > self.leaderTerm {
            self.leaderTerm = leaderTerm
            snapshot.leaderTerm = leaderTerm
        }
        self.nodeName = nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.listenPort = listenPort
        self.leaderAddress = normalizedBaseURL(leaderAddress) ?? leaderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sharedSecret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mode = await startupReconciledMode(requestedMode: mode)

        snapshot.mode = self.mode
        snapshot.nodeName = self.nodeName
        snapshot.listenPort = listenPort
        snapshot.leaderAddress = self.leaderAddress
        snapshot.diagnostics = "Applied mode \(self.mode.rawValue)"
        snapshot.lastJobNode = self.nodeName

        if self.mode != .leader {
            registeredWorkers.removeAll()
        }

        await restartServerIfNeeded()
        await restartWorkerRegistrationIfNeeded()
        await restartStandbyMonitorIfNeeded()
        await refreshWorkerHealth()
        await publishSnapshot()
    }

    func setOffloadPolicy(aiReplies: Bool, wikiLookups: Bool) async {
        offloadAIReplies = aiReplies
        offloadWikiLookups = wikiLookups
        snapshot.diagnostics = "Offload policy updated (AI: \(aiReplies ? "on" : "off"), Wiki: \(wikiLookups ? "on" : "off"))"
        await publishSnapshot()
    }

    /// Startup reconciliation to prevent split-brain:
    /// if this node is configured as leader but can reach a healthy existing leader
    /// at the configured leaderAddress, demote to standby and register with that leader.
    private func startupReconciledMode(requestedMode: ClusterMode) async -> ClusterMode {
        guard requestedMode == .leader else { return requestedMode }
        guard let configuredLeader = normalizedBaseURL(leaderAddress), !configuredLeader.isEmpty else {
            return requestedMode
        }
        guard !isSelfClusterEndpoint(configuredLeader) else { return requestedMode }
        guard let remoteStatus = await fetchRemoteClusterStatus(baseURL: configuredLeader) else {
            return requestedMode
        }

        let localLeaderID = "leader-\(ProcessInfo.processInfo.hostName.lowercased())-\(listenPort)"
        let remoteLeader = remoteStatus.response.nodes.first {
            $0.role == .leader && $0.status != .disconnected
        }
        if let remoteLeader, remoteLeader.id != localLeaderID {
            meshLogger.warning(
                "Startup reconciliation: discovered active leader \(remoteLeader.displayName, privacy: .public) at \(configuredLeader, privacy: .public); starting in standby mode"
            )
            leaderAddress = configuredLeader
            return .standby
        }

        return requestedMode
    }

    func stopAll() async {
        stopMeshDiscovery()
        workerRegistrationTask?.cancel()
        workerRegistrationTask = nil
        standbyMonitorTask?.cancel()
        standbyMonitorTask = nil
        listener?.cancel()
        listener = nil
        listenerActivePort = nil
        registeredWorkers.removeAll()
        standbyHealthMisses = 0
        snapshot.serverState = .stopped
        snapshot.serverStatusText = "Stopped"
        snapshot.workerState = .inactive
        snapshot.workerStatusText = "Stopped"
        snapshot.diagnostics = "Cluster services stopped"
        await publishSnapshot()
    }

    func currentSnapshot() -> ClusterSnapshot {
        snapshot
    }

    func currentLeaderTerm() -> Int {
        leaderTerm
    }

    func normalizedLeaderBaseURL(_ raw: String) -> String? {
        normalizedBaseURL(raw)
    }

    func refreshWorkerHealth() async {
        switch mode {
        case .standby:
            guard let leaderBaseURL = normalizedBaseURL(leaderAddress), !leaderBaseURL.isEmpty else {
                snapshot.workerState = .inactive
                snapshot.workerStatusText = "Primary not configured"
                snapshot.diagnostics = "Fail Over requires a Primary Address"
                await publishSnapshot()
                return
            }
            snapshot.workerState = .connected
            snapshot.workerStatusText = "Monitoring Primary (term \(leaderTerm))"
            snapshot.diagnostics = "Fail Over — watching \(leaderBaseURL)"
            await publishSnapshot()
        case .standalone:
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "Not applicable"
            snapshot.diagnostics = "Cluster mode is standalone"
            await publishSnapshot()
        case .leader:
            pruneStaleRegistrations()
            let workers = sortedRegisteredWorkers()
            guard !workers.isEmpty else {
                snapshot.workerState = .inactive
                snapshot.workerStatusText = "No workers registered"
                snapshot.diagnostics = "Waiting for workers to register"
                await publishSnapshot()
                return
            }

            var reachable = 0
            for worker in workers {
                if await isWorkerReachable(worker.baseURL) {
                    reachable += 1
                }
            }

            if reachable == workers.count {
                snapshot.workerState = .connected
                snapshot.workerStatusText = "\(reachable) workers reachable"
            } else if reachable > 0 {
                snapshot.workerState = .degraded
                snapshot.workerStatusText = "\(reachable)/\(workers.count) workers reachable"
            } else {
                snapshot.workerState = .failed
                snapshot.workerStatusText = "No workers reachable"
            }
            snapshot.diagnostics = "Registered workers: \(workers.count), reachable: \(reachable)"
            await publishSnapshot()
        case .worker:
            guard let leaderBaseURL = normalizedBaseURL(leaderAddress), !leaderBaseURL.isEmpty else {
                snapshot.workerState = .inactive
                snapshot.workerStatusText = "Primary not configured"
                snapshot.diagnostics = "Worker requires a Primary Address"
                await publishSnapshot()
                return
            }

            guard let url = URL(string: leaderBaseURL + "/health") else {
                snapshot.workerState = .failed
                snapshot.workerStatusText = "Invalid Primary address"
                snapshot.diagnostics = "Primary Address is invalid: \(leaderAddress)"
                await publishSnapshot()
                return
            }

            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    snapshot.workerState = .connected
                    snapshot.workerStatusText = "Primary reachable"
                    snapshot.diagnostics = "Primary reachable via \(url.absoluteString)"
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    snapshot.workerState = .degraded
                    snapshot.workerStatusText = "Primary health check failed (\(status))"
                    snapshot.diagnostics = "Primary health returned HTTP \(status) via \(url.absoluteString)"
                }
            } catch {
                snapshot.workerState = .failed
                snapshot.workerStatusText = "Primary unavailable"
                snapshot.diagnostics = "Primary health request failed for \(url.absoluteString): \(error.localizedDescription)"
            }
            await publishSnapshot()
        }
    }

    func generateAIReply(
        messages: [Message],
        serverName: String? = nil,
        channelName: String? = nil,
        wikiContext: String? = nil
        ) async -> String? {
        // AI reply override for unit tests (compliant with March 2026 standards).
#if DEBUG
        if let override = AITestOverrides.replyOverride {
            if AITestOverrides.replyDelaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(AITestOverrides.replyDelaySeconds * 1_000_000_000))
            }
            return override.isEmpty ? nil : override
        }
#endif

        guard let aiHandler else { return nil }

        let job = AIJobRequest(
            messages: messages,
            serverName: serverName,
            channelName: channelName,
            wikiContext: wikiContext
        )
        if mode == .leader, offloadAIReplies, let remote = await performRemoteAI(job) {
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "AI reply via worker"
            snapshot.lastJobNode = remote.nodeName
            await publishSnapshot()
            return remote.reply
        }

        let local = await aiHandler(messages, serverName, channelName, wikiContext)
        snapshot.lastJobRoute = local == nil ? .unavailable : .local
        snapshot.lastJobSummary = local == nil ? "AI reply unavailable" : "AI reply local"
        snapshot.lastJobNode = nodeName
        if local != nil {
            snapshot.diagnostics = "Handled AI reply locally on \(nodeName)"
        }
        await publishSnapshot()
        return local
    }

    func lookupWiki(query: String, source: WikiSource) async -> FinalsWikiLookupResult? {
        if mode == .leader, offloadWikiLookups, let remote = await performRemoteWikiLookup(query: query, source: source) {
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Wiki lookup via worker (\(source.name))"
            snapshot.lastJobNode = remote.nodeName
            await publishSnapshot()
            return remote.result
        }

        let local = await wikiHandler?(query, source)
        snapshot.lastJobRoute = local == nil ? .unavailable : .local
        snapshot.lastJobSummary = local == nil ? "Wiki lookup unavailable" : "Wiki lookup local (\(source.name))"
        snapshot.lastJobNode = nodeName
        if local != nil {
            snapshot.diagnostics = "Handled wiki lookup locally on \(nodeName) for \(source.name)"
        }
        await publishSnapshot()
        return local
    }

    func probeWorker() async -> ClusterProbeResponse? {
        guard mode == .leader else {
            snapshot.diagnostics = "Remote cluster worker probe is only available in Primary mode"
            await publishSnapshot()
            return nil
        }

        let workers = sortedRegisteredWorkers()
        guard !workers.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "No workers registered"
            snapshot.diagnostics = "No workers registered for probe"
            await publishSnapshot()
            return nil
        }

        for worker in workers {
            guard let url = URL(string: worker.baseURL + "/v1/probe") else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                applyMeshAuth(to: &request, path: "/v1/probe")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continue
                }

                let decoded = try decoder.decode(ClusterProbeResponse.self, from: data)
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Remote probe OK"
                snapshot.lastJobRoute = .remote
                snapshot.lastJobSummary = "Remote cluster worker probe"
                snapshot.lastJobNode = decoded.nodeName
                snapshot.diagnostics = "Worker \(decoded.nodeName) responded via \(url.absoluteString)"
                await publishSnapshot()
                return decoded
            } catch {
                continue
            }
        }

        snapshot.workerState = .failed
        snapshot.workerStatusText = "Remote probe unavailable"
        snapshot.diagnostics = "Remote probe failed for all registered workers"
        await publishSnapshot()
        return nil
    }

    // MARK: - Mesh Auth (HMAC-SHA256)

    /// Computes HMAC-SHA256 over `METHOD:path:nonce:timestamp:` + body bytes using sharedSecret as key.
    /// Returns a lowercase hex string. Returns empty string if sharedSecret is empty.
    private func pruneNonces(now: Date) {
        usedNonces = usedNonces.filter { now.timeIntervalSince($0.value) < 60 }
    }

    func meshSignature(method: String, nonce: String, timestamp: Int, path: String, body: Data) -> String {
        guard !sharedSecret.isEmpty,
              let keyData = sharedSecret.data(using: .utf8) else { return "" }
        let key = SymmetricKey(data: keyData)
        var input = Data("\(method.uppercased()):\(path):\(nonce):\(timestamp):".utf8)
        input.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Adds `X-Mesh-Nonce`, `X-Mesh-Timestamp`, and `X-Mesh-Signature` headers to a URLRequest.
    /// Only adds headers when sharedSecret is non-empty; otherwise leaves the request untouched
    /// (standalone mode makes no clustered calls so this is safe).
    private func applyMeshAuth(to request: inout URLRequest, path: String) {
        guard !sharedSecret.isEmpty else { return }
        let method = request.httpMethod ?? "GET"
        let nonce = UUID().uuidString
        let timestamp = Int(Date().timeIntervalSince1970)
        let body = request.httpBody ?? Data()
        let sig = meshSignature(method: method, nonce: nonce, timestamp: timestamp, path: path, body: body)
        request.setValue(nonce, forHTTPHeaderField: "X-Mesh-Nonce")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Mesh-Timestamp")
        request.setValue(sig, forHTTPHeaderField: "X-Mesh-Signature")
    }

    /// Verifies inbound mesh auth headers. Returns true only if:
    /// - All required headers present
    /// - Timestamp within ±300s skew window
    /// - Nonce has not been seen before (replay protection)
    /// - HMAC-SHA256 signature is valid (constant-time via CryptoKit)
    private func verifyMeshAuth(headers: [String: String], method: String, path: String, body: Data) -> Bool {
        guard !sharedSecret.isEmpty else { return false }
        guard let nonce = headers["x-mesh-nonce"],
              let tsStr = headers["x-mesh-timestamp"],
              let timestamp = Int(tsStr),
              let sigHex = headers["x-mesh-signature"] else { return false }

        // Opportunistic sweep of expired nonces (older than 60s).
        let now = Date()
        let nowEpoch = Int(now.timeIntervalSince1970)
        pruneNonces(now: now)

        // Timestamp skew check — fail-closed if outside ±60s window.
        let skew = abs(nowEpoch - timestamp)
        guard skew <= 60 else {
            meshLogger.warning("Mesh auth rejected: timestamp skew \(skew)s exceeds 60s window")
            return false
        }

        // Nonce replay check — reject if this nonce has been seen within the skew window.
        guard usedNonces[nonce] == nil else {
            meshLogger.warning("Mesh auth rejected: nonce replay detected")
            return false
        }

        guard let keyData = sharedSecret.data(using: .utf8) else { return false }
        let key = SymmetricKey(data: keyData)
        var input = Data("\(method.uppercased()):\(path):\(nonce):\(timestamp):".utf8)
        input.append(body)

        // Convert hex signature back to bytes for constant-time comparison.
        guard sigHex.count % 2 == 0 else { return false }
        var expectedBytes = [UInt8]()
        var idx = sigHex.startIndex
        while idx < sigHex.endIndex {
            let nextIdx = sigHex.index(idx, offsetBy: 2)
            guard let byte = UInt8(sigHex[idx..<nextIdx], radix: 16) else { return false }
            expectedBytes.append(byte)
            idx = nextIdx
        }

        guard HMAC<SHA256>.isValidAuthenticationCode(expectedBytes, authenticating: input, using: key) else {
            return false
        }

        // Record nonce as used (keyed to expiry time).
        usedNonces[nonce] = now
        return true
    }

    private func restartServerIfNeeded() async {
        // Skip if already listening on the correct port — prevents double-bind from
        // multiple applySettings call sites (startup, settings save, bot start).
        if listener != nil, listenerActivePort == listenPort, mode != .standalone {
            return
        }

        stopMeshDiscovery()
        listener?.cancel()
        listener = nil

        guard mode != .standalone else {
            snapshot.serverState = .inactive
            snapshot.serverStatusText = "Disabled"
            return
        }

        do {
            snapshot.serverState = .starting
            snapshot.serverStatusText = "Starting on :\(listenPort)"
            snapshot.diagnostics = "Starting worker server on port \(listenPort)"
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(listenPort)))
            // P1b: advertise this node over Bonjour so LAN peers can discover it.
            let txtRecord = NWTXTRecord([
                "node": nodeName,
                "port": "\(listenPort)",
                "host": ProcessInfo.processInfo.hostName
            ])
            listener.service = NWListener.Service(name: nodeName, type: "_swiftbot-mesh._tcp", txtRecord: txtRecord)
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handleConnection(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleListenerState(state) }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            snapshot.serverState = .failed
            snapshot.serverStatusText = "Server failed: \(error.localizedDescription)"
            snapshot.diagnostics = "Failed to bind port \(listenPort): \(error.localizedDescription)"
        }

        // P1b: start browsing for other LAN nodes regardless of role.
        startMeshDiscovery()
    }

    private func handleListenerState(_ state: NWListener.State) async {
        switch state {
        case .ready:
            listenerActivePort = listenPort
            snapshot.serverState = .listening
            snapshot.serverStatusText = "Listening on :\(listenPort)"
            snapshot.diagnostics = "Worker server listening on port \(listenPort)"
            meshLogger.info("Mesh server started on port \(self.listenPort, privacy: .public)")
        case .failed(let error):
            listenerActivePort = nil
            snapshot.serverState = .failed
            snapshot.serverStatusText = "Server failed: \(error.localizedDescription)"
            snapshot.diagnostics = "Worker server failed: \(error.localizedDescription)"
        case .cancelled:
            listenerActivePort = nil
            snapshot.serverState = .stopped
            snapshot.serverStatusText = "Stopped"
            snapshot.diagnostics = "Worker server stopped"
        default:
            break
        }
        await publishSnapshot()
    }

    // MARK: - P1b: LAN peer discovery

    /// Returns base URLs of LAN-discovered peers, sorted by discovery time (oldest first).
    /// Peers are discovered via Bonjour (_swiftbot-mesh._tcp) and keyed by node name for dedupe.
    /// Does NOT replace the manual leaderAddress path; purely additive.
    func discoveredPeerBaseURLs() -> [String] {
        // Primary: discovery time (oldest first). Secondary: nodeName (lexicographic) for
        // fully deterministic output when two peers are discovered within the same tick.
        discoveredPeers.values
            .sorted {
                if $0.discoveredAt != $1.discoveredAt { return $0.discoveredAt < $1.discoveredAt }
                return $0.nodeName < $1.nodeName
            }
            .map { $0.baseURL }
    }

    private func startMeshDiscovery() {
        meshBrowser?.cancel()
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_swiftbot-mesh._tcp", domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.handleDiscoveryResults(results) }
        }
        browser.start(queue: .global(qos: .utility))
        meshBrowser = browser
    }

    private func stopMeshDiscovery() {
        meshBrowser?.cancel()
        meshBrowser = nil
        discoveredPeers.removeAll()
    }

    private func handleDiscoveryResults(_ results: Set<NWBrowser.Result>) {
        // Single timestamp for the entire batch so all newly seen peers in the same
        // browse update share the same discoveredAt — preventing Set iteration order
        // from producing different primary-sort values across runs.
        let batchTimestamp = Date()
        var active: [String: DiscoveredPeer] = [:]
        for result in results {
            guard case let .bonjour(txtRecord) = result.metadata else { continue }
            let peerName = txtRecord["node"] ?? ""
            let host = txtRecord["host"] ?? ""
            let portStr = txtRecord["port"] ?? ""
            guard !peerName.isEmpty, !host.isEmpty,
                  let port = Int(portStr), port > 0 else { continue }
            guard peerName != nodeName else { continue }  // skip self
            let baseURL = "http://\(host):\(port)"
            if let existing = active[peerName] {
                // Deterministic collision rule: when the same nodeName appears more than once
                // in a single browse batch, prefer the lexicographically smallest baseURL so
                // the result is independent of Set iteration order.
                if baseURL < existing.baseURL {
                    active[peerName] = DiscoveredPeer(
                        nodeName: peerName,
                        baseURL: baseURL,
                        discoveredAt: existing.discoveredAt
                    )
                }
            } else {
                // New peer: use batchTimestamp (not per-item Date()) so all peers first seen
                // in the same batch share an identical discoveredAt; secondary nodeName sort
                // then provides stable output ordering within the batch.
                active[peerName] = DiscoveredPeer(
                    nodeName: peerName,
                    baseURL: baseURL,
                    discoveredAt: discoveredPeers[peerName]?.discoveredAt ?? batchTimestamp
                )
            }
        }
        discoveredPeers = active
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .utility))
        let remoteHost = remoteHostFromConnection(connection)
        do {
            let requestData = try await readHTTPRequest(connection)
            let response = await processHTTPRequest(requestData, remoteHost: remoteHost)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            let body = #"{"error":"bad_request"}"#.data(using: .utf8) ?? Data()
            let response = httpResponse(status: "400 Bad Request", body: body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func remoteHostFromConnection(_ connection: NWConnection) -> String? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return address.debugDescription
        case .ipv6(let address):
            return address.debugDescription
        @unknown default:
            return nil
        }
    }

    private func readHTTPRequest(_ connection: NWConnection) async throws -> Data {
        var buffer = Data()
        let start = Date()

        while buffer.count < Self.maxHTTPRequestSize {
            if Date().timeIntervalSince(start) > Self.httpReadTimeout {
                throw NWError.posix(.ETIMEDOUT)
            }

            let chunk = try await receiveChunk(from: connection)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[..<headerRange.upperBound]
                let contentLength = parseContentLength(headerData)
                let bodyLength = buffer.count - headerRange.upperBound
                
                if contentLength > Self.maxHTTPRequestSize {
                    throw NWError.posix(.EMSGSIZE)
                }

                if bodyLength >= contentLength {
                    return buffer
                }
            }
        }
        
        if buffer.count >= Self.maxHTTPRequestSize {
            throw NWError.posix(.EMSGSIZE)
        }
        
        return buffer
    }

    private func receiveChunk(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }

    private func parseContentLength(_ headerData: Data.SubSequence) -> Int {
        guard let headerText = String(data: Data(headerData), encoding: .utf8) else { return 0 }
        for line in headerText.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:"),
               let value = lower.split(separator: ":").last,
               let intValue = Int(value.trimmingCharacters(in: .whitespaces)) {
                return intValue
            }
        }
        return 0
    }

    func processHTTPRequest(_ requestData: Data, remoteHost: String? = nil) async -> Data {
        guard let request = parseRequest(requestData) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_request"}"#.utf8))
        }

        // Enforce HMAC auth on all routes except /health.
        // Policy:
        //   - Non-standalone mode + empty sharedSecret → fail-closed (401): clustered nodes must have a secret.
        //   - Any mode + non-empty sharedSecret → require valid HMAC signature.
        //   - Standalone mode + empty sharedSecret → open (local-only node, no cluster traffic expected).
        if request.path != "/health" {
            if mode != .standalone && sharedSecret.isEmpty {
                meshLogger.warning("Mesh auth rejected: non-standalone mode with no shared secret configured")
                return httpResponse(status: "401 Unauthorized", body: Data(#"{"error":"unauthorized"}"#.utf8))
            }
            if !sharedSecret.isEmpty {
                guard verifyMeshAuth(headers: request.headers, method: request.method, path: request.path, body: request.body) else {
                    meshLogger.warning("Mesh auth rejected: invalid HMAC, stale timestamp, or replay for path \(request.path, privacy: .public)")
                    return httpResponse(status: "401 Unauthorized", body: Data(#"{"error":"unauthorized"}"#.utf8))
                }
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            let payload = HealthResponse(nodeName: nodeName, mode: mode.rawValue, status: "ok")
            let body = (try? encoder.encode(payload)) ?? Data()
            return httpResponse(status: "200 OK", body: body)
        case ("GET", "/cluster/ping"):
            let payload = ClusterPingResponse(
                status: "ok",
                role: mode == .leader ? "leader" : "worker",
                node: nodeName
            )
            let body = (try? encoder.encode(payload)) ?? Data()
            return httpResponse(status: "200 OK", body: body)
        case ("POST", "/cluster/register"):
            return await handleWorkerRegistration(request.body, remoteHost: remoteHost)
        case ("GET", "/cluster/status"):
            let payload = await clusterStatusPayload()
            let body = (try? encoder.encode(payload)) ?? Data()
            return httpResponse(status: "200 OK", body: body)
        case ("GET", "/v1/probe"):
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Served remote worker probe"
            snapshot.lastJobNode = nodeName
            snapshot.diagnostics = "Handled remote probe on \(nodeName)"
            await publishSnapshot()
            await recordJobLog(
                user: "Cluster",
                server: "Cluster",
                command: "GET /v1/probe",
                channel: "worker",
                executionRoute: "Worker",
                ok: true
            )
            let payload = ClusterProbeResponse(
                nodeName: nodeName,
                mode: mode.rawValue,
                listenPort: listenPort,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
            let body = (try? encoder.encode(payload)) ?? Data()
            return httpResponse(status: "200 OK", body: body)
        case ("POST", "/v1/ai-reply"):
            activeJobs += 1
            defer { activeJobs = max(0, activeJobs - 1) }
            guard let aiHandler,
                  let body = try? decoder.decode(AIJobRequest.self, from: request.body),
                  let reply = await aiHandler(body.messages, body.serverName, body.channelName, body.wikiContext) else {
                return httpResponse(status: "503 Service Unavailable", body: Data(#"{"error":"ai_unavailable"}"#.utf8))
            }
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Served remote AI reply"
            snapshot.lastJobNode = nodeName
            let requestUser = body.messages.last(where: { $0.role == .user })?.username ?? "Unknown"
            snapshot.diagnostics = "Handled remote AI reply for \(requestUser) on \(nodeName)"
            await publishSnapshot()
            await recordJobLog(
                user: requestUser,
                server: "Remote AI",
                command: "AI reply",
                channel: "worker",
                executionRoute: "Worker",
                ok: true
            )
            let response = AIJobResponse(nodeName: nodeName, reply: reply)
            let bodyData = (try? encoder.encode(response)) ?? Data()
            return httpResponse(status: "200 OK", body: bodyData)
        case ("POST", "/v1/wiki-lookup"), ("POST", "/v1/finals-wiki"):
            activeJobs += 1
            defer { activeJobs = max(0, activeJobs - 1) }
            guard let wikiHandler,
                  let body = decodeWikiJobRequest(from: request.body),
                  let result = await wikiHandler(body.query, body.source) else {
                await recordJobLog(
                    user: "Remote Wiki",
                    server: "Cluster",
                    command: "Wiki lookup failed",
                    channel: "worker",
                    executionRoute: "Worker",
                    ok: false
                )
                return httpResponse(status: "404 Not Found", body: Data(#"{"error":"not_found"}"#.utf8))
            }
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Served remote wiki lookup"
            snapshot.lastJobNode = nodeName
            snapshot.diagnostics = "Handled remote wiki lookup for \"\(body.query)\" on \(nodeName) (\(body.source.name))"
            await publishSnapshot()
            await recordJobLog(
                user: body.source.name,
                server: "Remote Wiki",
                command: "!wiki \(body.query)",
                channel: "worker",
                executionRoute: "Worker",
                ok: true
            )
            let response = WikiJobResponse(nodeName: nodeName, result: result)
            let bodyData = (try? encoder.encode(response)) ?? Data()
            return httpResponse(status: "200 OK", body: bodyData)
        case ("POST", "/v1/mesh/leader-changed"):
            return await handleMeshLeaderChanged(request.body)
        case ("GET", "/v1/mesh/workers"):
            return handleMeshWorkersRequest()
        case ("POST", "/v1/mesh/sync/worker-registry"):
            return await handleMeshWorkerRegistrySync(request.body)
        case ("POST", "/v1/mesh/sync/conversations"):
            return await handleMeshConversationSync(request.body)
        case ("POST", "/v1/mesh/sync/conversations/resync"):
            return await handleMeshConversationResync(request.body)
        case ("GET", "/v1/mesh/sync/wiki-cache"):
            return await handleMeshWikiCacheSync()
        case ("GET", "/v1/mesh/sync/config-files"):
            return await handleMeshConfigFilesSync()
        default:
            return httpResponse(status: "404 Not Found", body: Data(#"{"error":"unknown_route"}"#.utf8))
        }
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<marker.lowerBound], encoding: .utf8) else {
            return nil
        }

        let body = Data(data[marker.upperBound...])
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }

    private func httpResponse(status: String, body: Data) -> Data {
        let header = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    private func restartStandbyMonitorIfNeeded() async {
        standbyMonitorTask?.cancel()
        standbyMonitorTask = nil
        standbyHealthMisses = 0

        guard mode == .standby else { return }
        guard let leaderBaseURL = normalizedBaseURL(leaderAddress), !leaderBaseURL.isEmpty else {
            return
        }

        standbyMonitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.standbyHealthInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await monitorLeaderHealth(leaderBaseURL)
            }
        }
    }

    private func monitorLeaderHealth(_ leaderBaseURL: String) async {
        guard mode == .standby else { return }
        
        let isHealthy = await isWorkerReachable(leaderBaseURL)
        if isHealthy {
            if standbyHealthMisses > 0 {
                snapshot.diagnostics = "Primary recovered after \(standbyHealthMisses) misses"
                await publishSnapshot()
            }
            standbyHealthMisses = 0
        } else {
            standbyHealthMisses += 1
            snapshot.diagnostics = "Primary health miss \(standbyHealthMisses)/\(Self.standbyPromotionThreshold)"
        meshLogger.warning("Primary health miss \(self.standbyHealthMisses, privacy: .public)/\(Self.standbyPromotionThreshold, privacy: .public)")
            await publishSnapshot()
            
            if standbyHealthMisses >= Self.standbyPromotionThreshold {
                await promoteToLeader()
            }
        }
    }
    func promoteToLeader() async {
        guard mode == .standby else { return }

        mode = .leader
        leaderTerm += 1
        snapshot.mode = .leader
        snapshot.leaderTerm = leaderTerm
        snapshot.diagnostics = "PROMOTED TO PRIMARY (Term \(leaderTerm))"
        meshLogger.critical("Node promoted to Primary — term \(self.leaderTerm, privacy: .public), node \(self.nodeName, privacy: .public)")
        snapshot.workerState = .connected
        snapshot.workerStatusText = "Primary (Promoted)"
        await publishSnapshot()

        // Persist the new term immediately so a restart cannot emit a stale term.
        await onTermChanged?(leaderTerm)
        
        // Notify AppModel to start bot services
        await onPromotion?()

        // New term = new epoch: reset all cursors so standby/workers get a full resync.
        replicationCursors.removeAll()
        await onCursorsChanged?(replicationCursors)

        // Stop standby monitoring and registration — no longer a standby.
        standbyMonitorTask?.cancel()
        standbyMonitorTask = nil
        workerRegistrationTask?.cancel()
        workerRegistrationTask = nil

        // Restart server as leader
        await restartServerIfNeeded()
        
        // Notify workers of the new leader
        let workers = Array(registeredWorkers.values)
        if !workers.isEmpty {
            snapshot.diagnostics = "Promoted to Primary. Notifying \(workers.count) workers..."
            await publishSnapshot()
            
            let payload = MeshLeaderChangedPayload(
                term: leaderTerm,
                leaderAddress: localWorkerAdvertisedBaseURL(),
                leaderNodeName: nodeName,
                sharedSecret: sharedSecret
            )
            
            for worker in workers {
                await notifyWorkerOfLeaderChange(worker, payload: payload)
            }
        }
    }

    private func notifyWorkerOfLeaderChange(_ worker: RegisteredWorker, payload: MeshLeaderChangedPayload) async {
        guard let url = URL(string: worker.baseURL + "/v1/mesh/leader-changed") else { return }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)
            applyMeshAuth(to: &request, path: "/v1/mesh/leader-changed")
            request.timeoutInterval = 5
            _ = try await URLSession.shared.data(for: request)
        } catch {
            // Best effort — worker will re-register on its own next cycle if missed
        }
    }

    func pushWorkerRegistryToStandbys() async {
        guard mode == .leader else { return }
        let workers = Array(registeredWorkers.values)
        guard !workers.isEmpty else { return }
        let entries = workers.map {
            MeshWorkerRegistryPayload.WorkerEntry(nodeName: $0.nodeName, baseURL: $0.baseURL, listenPort: $0.listenPort)
        }
        let payload = MeshWorkerRegistryPayload(workers: entries, leaderTerm: leaderTerm)
        for worker in workers {
            await syncToNode(worker, path: "/v1/mesh/sync/worker-registry", payload: payload)
        }
    }

    func pushSyncPayloadToNodes(_ payload: MeshSyncPayload) async {
        guard mode == .leader else { return }
        let workers = Array(registeredWorkers.values)
        guard !workers.isEmpty else { return }
        for worker in workers {
            await syncToNode(worker, path: "/v1/mesh/sync/conversations", payload: payload)
        }
    }

    /// Push an incremental batch to a single node and return whether the delivery succeeded.
    @discardableResult
    func pushConversationsToSingleNode(_ baseURL: String, _ payload: MeshSyncPayload) async -> Bool {
        guard mode == .leader else { return false }
        guard let worker = registeredWorkers[baseURL.lowercased()] else { return false }
        guard let url = URL(string: worker.baseURL + "/v1/mesh/sync/conversations") else { return false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)
            applyMeshAuth(to: &request, path: "/v1/mesh/sync/conversations")
            request.timeoutInterval = 10
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
            return true
        } catch {
            return false
        }
    }

    private func syncToNode<T: Codable>(_ worker: RegisteredWorker, path: String, payload: T) async {
        guard let url = URL(string: worker.baseURL + path) else { return }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)
            applyMeshAuth(to: &request, path: path)
            request.timeoutInterval = 10
            _ = try await URLSession.shared.data(for: request)
        } catch {
            // best effort
        }
    }

    private func restartWorkerRegistrationIfNeeded() async {
        workerRegistrationTask?.cancel()
        workerRegistrationTask = nil

        guard mode == .worker || mode == .standby else { return }
        guard let normalizedLeader = normalizedBaseURL(leaderAddress), !normalizedLeader.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "Primary not configured"
            snapshot.diagnostics = "Set Primary Address to enable registration"
            return
        }

        workerRegistrationTask = Task {
            while !Task.isCancelled {
                await registerWithLeader(normalizedLeader)
                try? await Task.sleep(nanoseconds: workerRegistrationIntervalNanoseconds)
            }
        }
    }

    private func registerWithLeader(_ leaderBaseURL: String) async {
        guard mode == .worker || mode == .standby else { return }
        guard let url = URL(string: leaderBaseURL + "/cluster/register") else {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Invalid Primary address"
            snapshot.diagnostics = "Invalid registration URL: \(leaderBaseURL)"
            await publishSnapshot()
            return
        }

        let payload = WorkerRegistrationRequest(
            nodeName: nodeName,
            baseURL: localWorkerAdvertisedBaseURL(),
            listenPort: listenPort
        )

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)
            applyMeshAuth(to: &request, path: "/cluster/register")
            request.timeoutInterval = 3
            let authMode = sharedSecret.isEmpty ? "none" : "HMAC"
            snapshot.diagnostics = "Registering with Primary: POST \(describeEndpoint(url)) auth=\(authMode) node=\(nodeName) listenPort=\(listenPort)"
            await publishSnapshot()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                snapshot.workerState = .degraded
                snapshot.workerStatusText = "Registration failed (\(code))"
                let bodySnippet = String(data: data, encoding: .utf8)?
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
                snapshot.diagnostics = "Registration failed: POST \(describeEndpoint(url)) status=\(code) body=\(String(bodySnippet.prefix(180)))"
                await publishSnapshot()
                return
            }

            let ack = try? decoder.decode(WorkerRegistrationResponse.self, from: data)
            snapshot.workerState = .connected
            snapshot.workerStatusText = mode == .standby ? "Standby Registered with Primary" : "Worker Registered with Primary"
            if let ack {
                snapshot.diagnostics = "\(mode == .standby ? "Standby" : "Worker") registered with Primary \(ack.leaderNodeName) (\(ack.registeredWorkers) nodes total)"
            } else {
                snapshot.diagnostics = "\(mode == .standby ? "Standby" : "Worker") registered with Primary via \(url.absoluteString)"
            }
            await publishSnapshot()
        } catch {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Primary unavailable"
            if let urlError = error as? URLError {
                snapshot.diagnostics = "Registration request failed: POST \(describeEndpoint(url)) urlError=\(urlError.code.rawValue) reason=\(urlError.localizedDescription)"
            } else {
                snapshot.diagnostics = "Registration request failed: POST \(describeEndpoint(url)) reason=\(error.localizedDescription)"
            }
            await publishSnapshot()
        }
    }

    private func handleWorkerRegistration(_ body: Data, remoteHost: String?) async -> Data {
        guard mode == .leader else {
            return httpResponse(status: "409 Conflict", body: Data(#"{"error":"leader_mode_required"}"#.utf8))
        }

        guard let registration = try? decoder.decode(WorkerRegistrationRequest.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_registration"}"#.utf8))
        }
        let advertisedBaseURL = normalizedBaseURL(registration.baseURL)
        let observedBaseURL = observedRegistrationBaseURL(remoteHost: remoteHost, listenPort: registration.listenPort)
        guard let baseURL = observedBaseURL ?? advertisedBaseURL, !baseURL.isEmpty else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_registration"}"#.utf8))
        }

        let workerName = registration.nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Worker"
            : registration.nodeName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Keep one registration per node name to avoid duplicate stale entries
        // when public/private endpoints for the same standby vary over time.
        registeredWorkers = registeredWorkers.filter { $0.value.nodeName.lowercased() != workerName.lowercased() }

        let key = baseURL.lowercased()
        registeredWorkers[key] = RegisteredWorker(
            nodeName: workerName,
            baseURL: baseURL,
            listenPort: registration.listenPort,
            lastSeen: Date()
        )
        pruneStaleRegistrations()

        snapshot.workerState = .connected
        let workerCount = registeredWorkers.count
        snapshot.workerStatusText = "\(workerCount) worker\(workerCount == 1 ? "" : "s") registered"
        if let advertisedBaseURL,
           let observedBaseURL,
           advertisedBaseURL.lowercased() != observedBaseURL.lowercased() {
            snapshot.diagnostics = "Worker \(workerName) registered from \(baseURL) (advertised \(advertisedBaseURL))"
        } else {
            snapshot.diagnostics = "Worker \(workerName) registered from \(baseURL)"
        }
        await publishSnapshot()

        let response = WorkerRegistrationResponse(
            status: "ok",
            leaderNodeName: nodeName,
            registeredWorkers: workerCount
        )
        let payload = (try? encoder.encode(response)) ?? Data()
        return httpResponse(status: "200 OK", body: payload)
    }

    private func observedRegistrationBaseURL(remoteHost: String?, listenPort: Int) -> String? {
        guard let remoteHost = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteHost.isEmpty,
              (1...Int(UInt16.max)).contains(listenPort) else { return nil }
        let hostLiteral = remoteHost.contains(":") && !remoteHost.hasPrefix("[")
            ? "[\(remoteHost)]"
            : remoteHost
        return normalizedBaseURL("http://\(hostLiteral):\(listenPort)")
    }

    private func sortedRegisteredWorkers() -> [RegisteredWorker] {
        registeredWorkers.values
            .filter { !isSelfClusterEndpoint($0.baseURL) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    private func pruneStaleRegistrations() {
        let cutoff = Date().addingTimeInterval(-registrationStaleAfter)
        registeredWorkers = registeredWorkers.filter { $0.value.lastSeen >= cutoff }
    }

    private func localWorkerAdvertisedBaseURL() -> String {
        let host = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = host.isEmpty ? "127.0.0.1" : host
        return "http://\(resolvedHost):\(listenPort)"
    }

    func normalizedBaseURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hadExplicitScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
        let candidate: String
        if hadExplicitScheme {
            candidate = trimmed
        } else {
            candidate = "http://\(trimmed)"
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme,
              let host = url.host,
              !scheme.isEmpty,
              !host.isEmpty else {
            return nil
        }
        
        // Mesh host guard: allow internet peers while still blocking obvious unsafe targets.
        if !isSSRFSafeHost(host) {
            return nil
        }

        // For host-only input (no scheme), require an explicit port to avoid
        // silently targeting the wrong endpoint.
        if !hadExplicitScheme, url.port == nil {
            return nil
        }
        let resolvedPort: Int = {
            if let explicit = url.port { return explicit }
            if scheme.lowercased() == "https" { return 443 }
            return 80
        }()
        return "\(scheme)://\(host):\(resolvedPort)"
    }

    func isSSRFSafeHost(_ host: String) -> Bool {
        let lowerHost = host.lowercased()
        if lowerHost == "localhost" || lowerHost == "127.0.0.1" || lowerHost == "::1" {
            return true
        }

        // Deny wildcard/unspecified endpoints.
        if lowerHost == "0.0.0.0" || lowerHost == "::" {
            return false
        }

        // Deny cloud metadata and link-local ranges.
        if lowerHost == "169.254.169.254"
            || lowerHost.hasPrefix("169.254.")
            || lowerHost == "metadata.google.internal" {
            return false
        }

        // Allow private LAN, public internet, and mDNS hosts.
        return true
    }

    private func isWorkerReachable(_ baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL + "/health") else { return false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyMeshAuth(to: &request, path: "/health")
            request.timeoutInterval = 2
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func describeEndpoint(_ url: URL) -> String {
        let scheme = url.scheme ?? "http"
        let host = url.host ?? "-"
        let port = url.port ?? (scheme.lowercased() == "https" ? 443 : 80)
        let path = url.path.isEmpty ? "/" : url.path
        return "\(scheme.uppercased()) \(host):\(port)\(path)"
    }

    private func performRemoteAI(_ job: AIJobRequest) async -> AIJobResponse? {
        let workers = sortedRegisteredWorkers()
        guard !workers.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "No workers registered"
            snapshot.diagnostics = "No registered workers available for remote AI"
            await publishSnapshot()
            return nil
        }

        for worker in workers {
            guard let url = URL(string: worker.baseURL + "/v1/ai-reply") else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try encoder.encode(job)
                applyMeshAuth(to: &request, path: "/v1/ai-reply")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continue
                }

                let decoded = try decoder.decode(AIJobResponse.self, from: data)
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Remote AI available"
                snapshot.diagnostics = "Remote AI succeeded via \(url.absoluteString)"
                await publishSnapshot()
                return decoded
            } catch {
                continue
            }
        }

        snapshot.workerState = .failed
        snapshot.workerStatusText = "Remote AI unavailable"
        snapshot.diagnostics = "Remote AI failed for all registered workers"
        await publishSnapshot()
        return nil
    }

    private func performRemoteWikiLookup(query: String, source: WikiSource) async -> WikiJobResponse? {
        let workers = sortedRegisteredWorkers()
        guard !workers.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "No workers registered"
            snapshot.diagnostics = "No registered workers available for remote wiki lookup"
            await publishSnapshot()
            return nil
        }

        for worker in workers {
            guard let url = URL(string: worker.baseURL + "/v1/wiki-lookup") else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try encoder.encode(WikiJobRequest(query: query, source: source))
                applyMeshAuth(to: &request, path: "/v1/wiki-lookup")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continue
                }

                let decoded = try decoder.decode(WikiJobResponse.self, from: data)
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Remote wiki available"
                snapshot.diagnostics = "Remote wiki succeeded via \(url.absoluteString)"
                await publishSnapshot()
                return decoded
            } catch {
                continue
            }
        }

        snapshot.workerState = .failed
        snapshot.workerStatusText = "Remote wiki unavailable"
        snapshot.diagnostics = "Remote wiki failed for all registered workers"
        await publishSnapshot()
        return nil
    }

    private func clusterStatusPayload() async -> ClusterStatusResponse {
        var nodes: [ClusterNodeStatus] = [localNodeStatus()]

        if mode == .leader {
            pruneStaleRegistrations()
            let workers = sortedRegisteredWorkers()
            var reachable = 0

            for worker in workers {
                if let remoteStatus = await fetchRemoteClusterStatus(baseURL: worker.baseURL) {
                    reachable += 1
                    for var node in remoteStatus.response.nodes where !nodes.contains(where: { $0.id == node.id }) {
                        if node.role == .worker, node.latencyMs == nil {
                            node.latencyMs = remoteStatus.latencyMs
                        }
                        nodes.append(node)
                    }
                } else {
                    let recentlySeen = Date().timeIntervalSince(worker.lastSeen) <= registrationStaleAfter
                    if recentlySeen {
                        reachable += 1
                    }
                    nodes.append(
                        unreachableWorkerNode(
                            worker: worker,
                            status: recentlySeen ? .degraded : .disconnected
                        )
                    )
                }
            }

            if workers.isEmpty {
                snapshot.workerState = .inactive
                snapshot.workerStatusText = "No workers registered"
                snapshot.diagnostics = "Waiting for worker registrations via /cluster/register"
            } else if reachable == workers.count {
                snapshot.workerState = .connected
                snapshot.workerStatusText = "\(reachable) workers connected"
                snapshot.diagnostics = "All registered workers reachable"
            } else if reachable > 0 {
                snapshot.workerState = .degraded
                snapshot.workerStatusText = "\(reachable)/\(workers.count) workers connected"
                snapshot.diagnostics = "Some registered workers are unreachable"
            } else {
                snapshot.workerState = .failed
                snapshot.workerStatusText = "Cluster status unavailable"
                snapshot.diagnostics = "Unable to reach any registered workers"
            }
        }

        if mode == .standby,
           let leaderBaseURL = normalizedBaseURL(leaderAddress),
           !leaderBaseURL.isEmpty,
           !isSelfClusterEndpoint(leaderBaseURL) {
            if let remoteStatus = await fetchRemoteClusterStatus(baseURL: leaderBaseURL) {
                var leaderFound = false
                for var node in remoteStatus.response.nodes where !nodes.contains(where: { $0.id == node.id }) {
                    if node.role == .leader {
                        node.latencyMs = remoteStatus.latencyMs
                        leaderFound = true
                    }
                    nodes.append(node)
                }
                if !leaderFound {
                    let host = URL(string: leaderBaseURL)?.host ?? "Primary"
                    nodes.append(
                        ClusterNodeStatus(
                            id: "leader-\(host.lowercased())",
                            hostname: host,
                            displayName: host,
                            role: .leader,
                            hardwareModel: "Unknown",
                            cpu: 0,
                            mem: 0,
                            cpuName: "Unknown CPU",
                            physicalMemoryBytes: 0,
                            uptime: 0,
                            latencyMs: remoteStatus.latencyMs,
                            status: .healthy,
                            jobsActive: 0
                        )
                    )
                }
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Primary reachable"
                snapshot.diagnostics = "Fail Over monitoring \(leaderBaseURL) (latency \(Int(remoteStatus.latencyMs)) ms)"
            } else {
                snapshot.workerState = .degraded
                snapshot.workerStatusText = "Primary unreachable"
                snapshot.diagnostics = "Fail Over could not fetch \(leaderBaseURL)/cluster/status"
            }
        }

        return ClusterStatusResponse(
            mode: mode,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            nodes: deduplicateClusterNodes(nodes)
        )
    }

    private func deduplicateClusterNodes(_ nodes: [ClusterNodeStatus]) -> [ClusterNodeStatus] {
        var byKey: [String: ClusterNodeStatus] = [:]
        for node in nodes {
            let roleKey = node.role.rawValue
            let nameKey = node.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let key = "\(roleKey)|\(nameKey)"
            if let existing = byKey[key] {
                byKey[key] = preferredNode(existing, node)
            } else {
                byKey[key] = node
            }
        }
        return byKey.values.sorted {
            if $0.role != $1.role { return $0.role.rawValue < $1.role.rawValue }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func preferredNode(_ lhs: ClusterNodeStatus, _ rhs: ClusterNodeStatus) -> ClusterNodeStatus {
        let lhsScore = nodeStatusScore(lhs.status)
        let rhsScore = nodeStatusScore(rhs.status)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore ? lhs : rhs
        }
        if let l = lhs.latencyMs, let r = rhs.latencyMs, l != r {
            return l <= r ? lhs : rhs
        }
        if lhs.latencyMs != nil, rhs.latencyMs == nil { return lhs }
        if rhs.latencyMs != nil, lhs.latencyMs == nil { return rhs }
        if lhs.jobsActive != rhs.jobsActive {
            return lhs.jobsActive >= rhs.jobsActive ? lhs : rhs
        }
        return lhs
    }

    private func nodeStatusScore(_ status: ClusterNodeHealthStatus) -> Int {
        switch status {
        case .healthy: return 3
        case .degraded: return 2
        case .disconnected: return 1
        }
    }

    private func localNodeStatus() -> ClusterNodeStatus {
        let hostname = ProcessInfo.processInfo.hostName
        let role: ClusterNodeRole = mode == .leader ? .leader : .worker
        let uptime = max(0, Date().timeIntervalSince(startedAt))
        let status = snapshot.serverState.nodeHealthStatus

        return ClusterNodeStatus(
            id: "\(role.rawValue)-\(hostname.lowercased())-\(listenPort)",
            hostname: hostname,
            displayName: nodeName,
            role: role,
            hardwareModel: hardwareInfo.modelIdentifier,
            cpu: currentCPUPercent(),
            mem: currentMemoryPercent(),
            cpuName: hardwareInfo.cpuName,
            physicalMemoryBytes: hardwareInfo.physicalMemoryBytes,
            uptime: uptime,
            latencyMs: nil,
            status: status,
            jobsActive: activeJobs
        )
    }

    private func unreachableWorkerNode(worker: RegisteredWorker, status: ClusterNodeHealthStatus = .disconnected) -> ClusterNodeStatus {
        let host = URL(string: worker.baseURL)?.host ?? worker.nodeName

        return ClusterNodeStatus(
            id: "worker-\(host.lowercased())-\(worker.listenPort)",
            hostname: host,
            displayName: worker.nodeName,
            role: .worker,
            hardwareModel: "Unknown",
            cpu: 0,
            mem: 0,
            cpuName: "Unknown CPU",
            physicalMemoryBytes: 0,
            uptime: 0,
            latencyMs: nil,
            status: status,
            jobsActive: 0
        )
    }

    private func fetchRemoteClusterStatus(baseURL: String) async -> (response: ClusterStatusResponse, latencyMs: Double)? {
        guard let url = URL(string: baseURL + "/cluster/status") else {
            return nil
        }

        do {
            let started = Date()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyMeshAuth(to: &request, path: "/cluster/status")
            request.timeoutInterval = 3
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }

            let decoded = try decoder.decode(ClusterStatusResponse.self, from: data)
            let latencyMs = max(0, Date().timeIntervalSince(started) * 1000)
            return (decoded, latencyMs)
        } catch {
            return nil
        }
    }

    private func currentCPUPercent() -> Double {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(cpuInfo.cpu_ticks.0)
        let system = Double(cpuInfo.cpu_ticks.1)
        let idle = Double(cpuInfo.cpu_ticks.2)
        let nice = Double(cpuInfo.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle
        guard total > 0 else { return 0 }
        return min(100, max(0, (used / total) * 100))
    }

    private func currentMemoryPercent() -> Double {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        let usedPages = Double(vmStats.active_count)
            + Double(vmStats.inactive_count)
            + Double(vmStats.wire_count)
            + Double(vmStats.compressor_page_count)
        let usedBytes = usedPages * Double(vm_kernel_page_size)
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        guard totalBytes > 0 else { return 0 }
        return min(100, max(0, (usedBytes / totalBytes) * 100))
    }

    private func isSelfClusterEndpoint(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL),
              let host = url.host?.lowercased() else {
            return false
        }

        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let localHosts = Set([
            "127.0.0.1",
            "localhost",
            "::1",
            ProcessInfo.processInfo.hostName.lowercased(),
            Host.current().name?.lowercased(),
            Host.current().localizedName?.replacingOccurrences(of: " ", with: "-").lowercased()
        ].compactMap { $0 })

        return localHosts.contains(host) && port == listenPort
    }

    func publishSnapshot() async {
        await onSnapshot?(snapshot)
    }

    private func recordJobLog(
        user: String,
        server: String,
        command: String,
        channel: String,
        executionRoute: String,
        ok: Bool
    ) async {
        let entry = CommandLogEntry(
            time: Date(),
            user: user,
            server: server,
            command: command,
            channel: channel,
            executionRoute: executionRoute,
            executionNode: nodeName,
            ok: ok
        )
        await onJobLog?(entry)
    }

    private func decodeWikiJobRequest(from data: Data) -> WikiJobRequest? {
        if let request = try? decoder.decode(WikiJobRequest.self, from: data) {
            return request
        }
        if let legacy = try? decoder.decode(LegacyWikiJobRequest.self, from: data) {
            return WikiJobRequest(query: legacy.query, source: .defaultFinals())
        }
        return nil
    }

    private func handleMeshLeaderChanged(_ body: Data) async -> Data {
        guard let payload = try? decoder.decode(MeshLeaderChangedPayload.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_payload"}"#.utf8))
        }
        // Split-brain guard: reject stale or equal terms.
        guard payload.term > leaderTerm else {
            return httpResponse(status: "409 Conflict", body: Data(#"{"error":"stale_term"}"#.utf8))
        }

        leaderTerm = payload.term
        leaderAddress = payload.leaderAddress
        snapshot.leaderTerm = leaderTerm
        snapshot.leaderAddress = leaderAddress
        snapshot.diagnostics = "Primary changed to \(payload.leaderNodeName) at \(payload.leaderAddress) (term \(leaderTerm))"
        snapshot.workerState = .starting
        snapshot.workerStatusText = "Re-registering with new Primary"
        await publishSnapshot()

        if mode == .worker, let normalizedLeader = normalizedBaseURL(leaderAddress) {
            await registerWithLeader(normalizedLeader)
        }

        return httpResponse(status: "200 OK", body: Data(#"{"status":"ok"}"#.utf8))
    }

    /// Leader: return registered workers list for standby to replicate.
    private func handleMeshWorkersRequest() -> Data {
        let entries = sortedRegisteredWorkers().map {
            MeshWorkerRegistryPayload.WorkerEntry(nodeName: $0.nodeName, baseURL: $0.baseURL, listenPort: $0.listenPort)
        }
        let payload = MeshWorkerRegistryPayload(workers: entries, leaderTerm: leaderTerm)
        let body = (try? encoder.encode(payload)) ?? Data()
        return httpResponse(status: "200 OK", body: body)
    }

    private func handleMeshWorkerRegistrySync(_ body: Data) async -> Data {
        guard mode == .standby else {
            return httpResponse(status: "409 Conflict", body: Data(#"{"error":"standby_mode_required"}"#.utf8))
        }

        guard let payload = try? decoder.decode(MeshWorkerRegistryPayload.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_payload"}"#.utf8))
        }
        guard payload.leaderTerm >= leaderTerm else {
            meshLogger.warning("Worker registry sync rejected: stale term \(payload.leaderTerm, privacy: .public) < current \(self.leaderTerm, privacy: .public)")
            return httpResponse(status: "409 Conflict", body: Data(#"{"error":"stale_term"}"#.utf8))
        }

        for worker in payload.workers {
            let key = worker.baseURL.lowercased()
            registeredWorkers[key] = RegisteredWorker(
                nodeName: worker.nodeName,
                baseURL: worker.baseURL,
                listenPort: worker.listenPort,
                lastSeen: Date()
            )
        }
        
        snapshot.diagnostics = "Synced worker registry (\(payload.workers.count) workers)"
        await publishSnapshot()

        return httpResponse(status: "200 OK", body: Data(#"{"status":"ok"}"#.utf8))
    }

    private func handleMeshConversationSync(_ body: Data) async -> Data {
        guard mode == .standby else {
            return httpResponse(status: "409 Conflict", body: Data(#"{"error":"standby_mode_required"}"#.utf8))
        }
        guard let payload = try? decoder.decode(MeshSyncPayload.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_payload"}"#.utf8))
        }
        guard payload.leaderTerm >= leaderTerm else {
            meshLogger.warning("Conversation sync rejected: stale term \(payload.leaderTerm, privacy: .public) < current \(self.leaderTerm, privacy: .public)")
            return httpResponse(status: "409 Conflict", body: Data(#"{"error":"stale_term"}"#.utf8))
        }
        await onSync?(payload)
        return httpResponse(status: "200 OK", body: Data(#"{"status":"ok"}"#.utf8))
    }

    /// Leader handles a standby/worker resync request: return bounded page from the requested cursor.
    private func handleMeshConversationResync(_ body: Data) async -> Data {
        guard mode == .leader else {
            return httpResponse(status: "409 Conflict", body: Data(#"{"error":"leader_mode_required"}"#.utf8))
        }
        guard let req = try? decoder.decode(MeshResyncRequest.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_payload"}"#.utf8))
        }
        guard let fetcher = conversationFetcher else {
            return httpResponse(status: "503 Service Unavailable", body: Data(#"{"error":"fetcher_unavailable"}"#.utf8))
        }

        let limit = min(max(1, req.pageSize), Self.maxSyncBatchSize)
        let (records, hasMore) = await fetcher(req.fromRecordID, limit)
        let lastID = records.last?.id
        
        // Also fetch current image usage if this is the last page (or just always for simplicity)
        let imageUsage = await meshHandler?("image-usage")
        let decodedUsage = imageUsage.flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) }

        let payload = MeshSyncPayload(
            conversations: records,
            imageUsage: decodedUsage,
            leaderTerm: leaderTerm,
            cursorRecordID: lastID,
            hasMore: hasMore,
            fromCursorRecordID: req.fromRecordID
        )
        guard let body = try? encoder.encode(payload) else {
            return httpResponse(status: "500 Internal Server Error", body: Data(#"{"error":"encode_failed"}"#.utf8))
        }
        return httpResponse(status: "200 OK", body: body)
    }

    private func handleMeshWikiCacheSync() async -> Data {
        if let data = await meshHandler?("wiki-cache") {
            return httpResponse(status: "200 OK", body: data)
        }
        return httpResponse(status: "404 Not Found", body: Data(#"{"error":"cache_unavailable"}"#.utf8))
    }

    private func handleMeshConfigFilesSync() async -> Data {
        if let data = await meshHandler?("config-files") {
            return httpResponse(status: "200 OK", body: data)
        }
        return httpResponse(status: "404 Not Found", body: Data(#"{"error":"config_unavailable"}"#.utf8))
    }

    /// Standby: fetch one page of conversation records from the leader using correct HMAC auth.
    func fetchResyncPage(fromRecordID: String?, pageSize: Int) async -> MeshSyncPayload? {
        guard mode == .standby,
              let baseURL = normalizedBaseURL(leaderAddress),
              !baseURL.isEmpty,
              let url = URL(string: baseURL + "/v1/mesh/sync/conversations/resync") else { return nil }
        let req = MeshResyncRequest(fromRecordID: fromRecordID, pageSize: pageSize)
        guard let body = try? encoder.encode(req) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        applyMeshAuth(to: &request, path: "/v1/mesh/sync/conversations/resync")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try? decoder.decode(MeshSyncPayload.self, from: data)
        } catch {
            return nil
        }
    }

    /// Standby: fetch wiki cache entries from the leader using correct HMAC auth.
    func fetchWikiCache() async -> Data? {
        guard mode == .standby,
              let baseURL = normalizedBaseURL(leaderAddress),
              !baseURL.isEmpty,
              let url = URL(string: baseURL + "/v1/mesh/sync/wiki-cache") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyMeshAuth(to: &request, path: "/v1/mesh/sync/wiki-cache")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    func fetchConfigFiles() async -> Data? {
        guard mode == .standby,
              let baseURL = normalizedBaseURL(leaderAddress),
              !baseURL.isEmpty,
              let url = URL(string: baseURL + "/v1/mesh/sync/config-files") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyMeshAuth(to: &request, path: "/v1/mesh/sync/config-files")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

struct RegisteredWorker: Hashable, Sendable {
    var nodeName: String
    var baseURL: String
    var listenPort: Int
    var lastSeen: Date
}

/// A LAN peer discovered via Bonjour (_swiftbot-mesh._tcp).
struct DiscoveredPeer: Sendable {
    let nodeName: String
    var baseURL: String
    let discoveredAt: Date
}

private struct WorkerRegistrationRequest: Codable {
    let nodeName: String
    let baseURL: String
    let listenPort: Int
}

private struct WorkerRegistrationResponse: Codable {
    let status: String
    let leaderNodeName: String
    let registeredWorkers: Int
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct AIJobRequest: Codable {
    let messages: [Message]
    let serverName: String?
    let channelName: String?
    let wikiContext: String?
}

private struct AIJobResponse: Codable {
    let nodeName: String
    let reply: String
}

private struct WikiJobRequest: Codable {
    let query: String
    let source: WikiSource
}

private struct LegacyWikiJobRequest: Codable {
    let query: String
}

private struct WikiJobResponse: Codable {
    let nodeName: String
    let result: FinalsWikiLookupResult
}

private struct HealthResponse: Codable {
    let nodeName: String
    let mode: String
    let status: String
}

private struct ClusterPingResponse: Codable {
    let status: String
    let role: String
    let node: String
}

struct ClusterProbeResponse: Codable {
    let nodeName: String
    let mode: String
    let listenPort: Int
    let timestamp: String
}
