import Foundation
import SwiftUI
import AppKit

extension AppModel {

    // MARK: - Cluster / SwiftMesh

    func refreshClusterStatus() {
        print("[DEBUG] AppModel.refreshClusterStatus() called")
        Task {
            print("[DEBUG] AppModel.refreshClusterStatus() Task started")
            await pollClusterStatus()
            let snapshot = await cluster.currentSnapshot()
            await MainActor.run {
                print("[DEBUG] AppModel.refreshClusterStatus() UI update")
                self.clusterSnapshot = snapshot
                self.lastClusterStatusRefreshAt = Date()
                self.logSwiftMeshStatus(snapshot, context: "Refresh")
            }
        }
    }

    func testWorkerLeaderConnection(leaderAddress: String? = nil, leaderPort: Int? = nil) {
        let address = leaderAddress ?? settings.clusterLeaderAddress
        let port = leaderPort ?? settings.clusterLeaderPort

        print("[DEBUG] AppModel.testWorkerLeaderConnection() called with address=\(address), port=\(port)")
        Task {
            print("[DEBUG] AppModel.testWorkerLeaderConnection() Task started")
            await MainActor.run {
                self.workerConnectionTestInProgress = true
                self.workerConnectionTestIsSuccess = false
                self.workerConnectionTestStatus = "Testing connection..."
                self.workerConnectionTestOutcome = nil
            }

            let outcome = await performWorkerConnectionTest(
                leaderAddress: address,
                leaderPort: port
            )
            print("[DEBUG] AppModel.testWorkerLeaderConnection() outcome: \(outcome.isSuccess)")

            await MainActor.run {
                self.workerConnectionTestInProgress = false
                self.workerConnectionTestIsSuccess = outcome.isSuccess
                self.workerConnectionTestStatus = outcome.message
                self.workerConnectionTestOutcome = outcome
                self.lastClusterStatusRefreshAt = Date()
                self.logs.append("SwiftMesh worker connection test: \(outcome.message)")
            }
        }
    }

    func refreshClusterStatusNow() async -> ClusterSnapshot {
        await pollClusterStatus()
        let snapshot = await cluster.currentSnapshot()
        self.clusterSnapshot = snapshot
        logSwiftMeshStatus(snapshot, context: "Refresh")
        return snapshot
    }

    func scheduleClusterNodesRefresh() {
        clusterNodesRefreshTask?.cancel()
        clusterNodesRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            await self.pollClusterStatus()
        }
    }

    func handleClusterRoleChange() async {
        // 1. Reconfigure mesh sync (to switch between pushing and pulling)
        configureMeshSync()

        // 2. Reconfigure Patchy (to ensure it starts/pauses correctly)
        configurePatchyMonitoring()

        // 3. Ensure Media Monitor is running or paused correctly
        startMediaMonitor()

        // 4. Update UI state (triggers refresh of banners and status indicators)
        await MainActor.run {
            self.objectWillChange.send()
        }
    }

    func configureMeshSync() {
        meshSyncTask?.cancel()
        meshSyncTask = nil

        let mode = runtimeClusterMode
        guard mode == .leader || mode == .standby else { return }

        meshSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                // Leader pushes, Standby pulls
                // Sync every 60 seconds.
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }

                guard let self else { break }

                let currentMode = self.runtimeClusterMode
                if currentMode == .leader {
                    // 1. Push worker registry to all nodes
                    await self.cluster.pushWorkerRegistryToStandbys()
                    // 2. Push incremental conversation batches per node
                    await self.pushIncrementalConversationsToAllNodes()
                } else if currentMode == .standby {
                    // 3. Standby: Pull config files and wiki cache from Primary
                    await self.pullConfigFilesFromLeader()
                    await self.pullWikiCacheFromLeader()
                }
            }
        }
    }

    func setupBackgroundRefreshScheduler() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.swiftbot.meshBackgroundRefresh")
        scheduler.repeats = true
        scheduler.interval = 15 * 60        // 15 minutes
        scheduler.tolerance = 5 * 60        // 5-minute tolerance window
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completion in
            guard let self else { completion(.finished); return }
            Task {
                await self.runBackgroundMeshRefresh()
                completion(.finished)
            }
        }
        backgroundRefreshScheduler = scheduler
    }

    func runBackgroundMeshRefresh() async {
        guard settings.clusterMode == .standby || settings.clusterMode == .worker else { return }
        await pullConfigFilesFromLeader()
        await requestResyncFromLeader(fromRecordID: localLastMergedRecordID)
    }

    func pushIncrementalConversationsToAllNodes() async {
        let nodes = await cluster.registeredNodeInfo()
        guard !nodes.isEmpty else { return }
        let currentTerm = await cluster.currentLeaderTerm()
        let liveSnapshot = await MainActor.run { buildMeshLiveSnapshot() }
        for (nodeName, baseURL) in nodes {
            let cursor = await cluster.currentReplicationCursor(for: nodeName)
            let fromID = cursor?.lastSentRecordID ?? ""
            let (records, hasMore) = await conversationStore.recordsSince(fromRecordID: fromID, limit: 500)
            let lastID = records.last?.id
            let payload = MeshSyncPayload(
                conversations: records,
                commandLog: Array(commandLog.prefix(200)),
                voiceLog: Array(voiceLog.prefix(200)),
                activeVoice: activeVoice,
                leaderTerm: currentTerm,
                cursorRecordID: lastID,
                hasMore: hasMore,
                fromCursorRecordID: fromID,
                liveSnapshot: liveSnapshot
            )
            let ok = await cluster.pushConversationsToSingleNode(baseURL, payload)
            if ok, lastID != nil {
                await cluster.updateReplicationCursor(for: nodeName, lastSentRecordID: lastID, term: currentTerm)
            }
        }
    }

    /// Pushes the live snapshot (bot identity, guilds, counters, etc.) to all
    /// registered Standbys *immediately*, bypassing the 60s sync tick. Use
    /// from event handlers where the Failover dashboard would feel stale
    /// otherwise (identity change at READY, GUILD_CREATE, GUILD_DELETE,
    /// promotion/demotion). Conversations are NOT included — they go via the
    /// incremental path on the next tick. Quiet no-op when not Primary or
    /// when no nodes are registered.
    func pushLiveSnapshotEagerly(reason: String) async {
        let isLeader: Bool = await MainActor.run { settings.clusterMode == .leader }
        guard isLeader else { return }
        let nodes = await cluster.registeredNodeInfo()
        guard !nodes.isEmpty else { return }
        let currentTerm = await cluster.currentLeaderTerm()
        let liveSnapshot = await MainActor.run { buildMeshLiveSnapshot() }
        let payload = MeshSyncPayload(
            conversations: [],
            commandLog: nil,
            voiceLog: nil,
            activeVoice: nil,
            leaderTerm: currentTerm,
            liveSnapshot: liveSnapshot
        )
        for (_, baseURL) in nodes {
            _ = await cluster.pushConversationsToSingleNode(baseURL, payload)
        }
        await MainActor.run {
            logs.append("[SwiftMesh] Pushed live snapshot eagerly (reason: \(reason))")
        }
    }

    /// Captures the "feel-alive" snapshot for Standby dashboards (bot identity,
    /// connected guilds, gateway counters, uptime). MainActor-only — all the
    /// source fields are `@Published` on AppModel.
    @MainActor
    func buildMeshLiveSnapshot() -> MeshLiveSnapshot {
        MeshLiveSnapshot(
            botUserId: botUserId,
            botUsername: botUsername.isEmpty ? nil : botUsername,
            botDiscriminator: botDiscriminator,
            botAvatarHash: botAvatarHash,
            connectedServers: connectedServers.isEmpty ? nil : connectedServers,
            gatewayEventCount: gatewayEventCount,
            voiceStateEventCount: voiceStateEventCount,
            readyEventCount: readyEventCount,
            guildCreateEventCount: guildCreateEventCount,
            lastGatewayEventName: lastGatewayEventName,
            lastVoiceStateAt: lastVoiceStateAt,
            lastVoiceStateSummary: lastVoiceStateSummary,
            botStatusRaw: status.rawValue,
            uptimeStartedAt: uptime?.startedAt,
            isHandoverTestActive: clusterSnapshot.isHandoverTestActive,
            handoverTestEndsAt: clusterSnapshot.handoverTestEndsAt,
            scheduledHandoverTestAt: clusterSnapshot.scheduledHandoverTestAt,
            scheduledHandoverTargetNodeName: clusterSnapshot.scheduledHandoverTargetNodeName,
            primaryPublicURL: publicPrimaryURLForSnapshot(),
            runtimeState: clusterSnapshot.runtimeState.rawValue
        )
    }

    private struct PrimaryLiveProbePayload: Decodable {
        let status: String
        let discordConnected: Bool?
    }

    /// Standby-side `/live` HTTPS probe. Used as a second opinion alongside
    /// the direct mesh socket before promoting:
    /// - `true`  → Primary is connected to Discord (abort promotion)
    /// - `false` → Primary is reachable but Discord is offline (promote)
    /// - `nil`   → no public URL configured / probe inapplicable (fall back
    ///   to mesh-only behavior)
    func probePrimaryLiveEndpoint() async -> Bool? {
        let base = await MainActor.run { peerPrimaryPublicURL }
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            return nil
        }
        // Append /live to whatever path is configured. publicBaseURL is
        // usually bare ("https://swiftbot.example.com"), but tolerate a
        // trailing slash or pre-existing path.
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/live"
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            if let payload = try? JSONDecoder().decode(PrimaryLiveProbePayload.self, from: data) {
                if let connected = payload.discordConnected {
                    return connected
                }
                switch payload.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "online", "passive": return true
                case "offline": return false
                default: return nil
                }
            }
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            switch body {
            case "online", "passive": return true
            case "offline": return false
            default: return nil
            }
        } catch {
            return nil
        }
    }

    /// Returns the Primary's publicly-reachable admin URL when one is actively
    /// serving (Cloudflare tunnel or user-configured public base URL). Returns
    /// `nil` when the Primary only listens locally — in that case the Failover
    /// has no usable secondary reachability path anyway.
    @MainActor
    private func publicPrimaryURLForSnapshot() -> String? {
        if adminWebPublicAccessStatus.isEnabled {
            let url = adminWebPublicAccessStatus.publicURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty { return url }
        }
        let explicit = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        return nil
    }

    func pullWikiCacheFromLeader() async {
        guard let data = await cluster.fetchWikiCache() else { return }
        if let entries = try? JSONDecoder().decode([WikiContextEntry].self, from: data) {
            for entry in entries {
                await wikiContextCache.upsertEntry(entry)
            }
            logs.append("SwiftMesh: pulled \(entries.count) wiki entry(s) from Primary")
        }
    }

    func pullConfigFilesFromLeader() async {
        guard settings.clusterMode == .standby || settings.clusterMode == .worker else { return }
        guard let data = await cluster.fetchConfigFiles() else { return }
        await applyMeshSyncedConfigFiles(data, sourceDescription: "pulled")
    }

    func applyMeshSyncedConfigFiles(_ data: Data, sourceDescription: String) async {
        let imported = await store.importMeshSyncedFiles(
            data,
            excludingFileNames: Set([
                SwiftBotStorage.swiftMeshConfigFileName,
                SwiftBotStorage.clusterStateFileName
            ])
        )
        guard imported > 0 else { return }

        logs.append("SwiftMesh: \(sourceDescription) \(imported) config file(s) from Primary")
        await reloadSyncedConfigFromDisk()
    }

    func reloadSyncedConfigFromDisk() async {
        // Keep local mesh identity authoritative on this node.
        let currentLocalMesh = settings.swiftMeshSettings
        let currentLocalMedia = mediaLibrarySettings
        let currentLocalAdminWebUI = settings.adminWebUI
        var reloaded = await store.load()
        let meshFromFile = await swiftMeshConfigStore.load()
        let effectiveLocalMesh = meshFromFile ?? currentLocalMesh
        reloaded.swiftMeshSettings = effectiveLocalMesh
        if meshFromFile == nil {
            // Self-heal missing mesh file so future reloads remain stable.
            try? await swiftMeshConfigStore.save(effectiveLocalMesh)
        }
        if effectiveLocalMesh.mode == .standby || effectiveLocalMesh.mode == .worker {
            reloaded.adminWebUI = currentLocalAdminWebUI
        }
        reloaded.wikiBot.normalizeSources()
        settings = reloaded
        mediaLibrarySettings = currentLocalMedia
        await mediaLibraryIndexer.invalidate()
        await ruleStore.reloadFromDisk()
        await aiService.configureLocalAIDMReplies(
            enabled: settings.localAIDMReplyEnabled,
            systemPrompt: settings.localAISystemPrompt
        )
        configurePatchyMonitoring()
        await configureAdminWebServer()
        await refreshAIStatus()
    }

    func applyClusterSettingsRuntime(mode: ClusterMode, nodeName: String, leaderAddress: String, leaderPort: Int, listenPort: Int, sharedSecret: String) async {
        // Phase 5 Safety Guard: Prevent invalid mesh ports from being used.
        guard listenPort > 0 && listenPort <= 65535 else {
            logs.append("❌ [SwiftMesh] Invalid port '\(listenPort)' — aborting mesh connection.")
            return
        }

        await cluster.applySettings(
            mode: mode,
            nodeName: nodeName,
            leaderAddress: leaderAddress,
            leaderPort: leaderPort,
            listenPort: listenPort,
            sharedSecret: sharedSecret,
            leaderTerm: settings.clusterLeaderTerm
        )

        // Phase 4: Configuration Consistency - log final mesh endpoint only
        // when mode or port actually changes to avoid spam during rapid saves.
        let snapshot = await cluster.currentSnapshot()
        if mode != .standalone, (snapshot.mode != mode || snapshot.listenPort != listenPort) {
            let host = ProcessInfo.processInfo.hostName
            logs.append("SwiftMesh listening on \(host):\(listenPort)")
        }

        await cluster.setOffloadPolicy(
            workerOffloadEnabled: settings.clusterWorkerOffloadEnabled,
            aiReplies: settings.clusterOffloadAIReplies,
            wikiLookups: settings.clusterOffloadWikiLookups
        )
        await cluster.setAutoReclaimPolicy(
            isConfiguredPrimary: settings.clusterMode == .leader,
            afterHours: settings.clusterAutoReclaimAfterHours
        )
        // Sync secondary safety guard from the reconciled runtime role, not
        // only the configured role. A returning Primary may start as Standby
        // when another healthy Primary already exists.
        let runtimeMode = await cluster.currentSnapshot().mode
        let isPrimary = runtimeMode == .standalone || runtimeMode == .leader
        await service.setOutputAllowed(isPrimary)
        configureMeshSync()
        if mode == .standby {
            await pullConfigFilesFromLeader()
        }
        await pollClusterStatus()
    }

    func pollClusterStatus() async {
        // Phase 4: refresh auto-reclaim countdown on every poll tick so the
        // SwiftMesh GUI can show a live "Auto-reclaim in Xh Ym" indicator.
        autoReclaimRemainingSeconds = await cluster.autoReclaimCountdownSeconds()
        guard settings.clusterMode != .standalone else {
            clusterNodes = []
            await refreshRegisteredWorkersDebugInfo()
            return
        }

        let emptyBody = Data()
        let localStatusHeaders = await meshStatusAuthHeaders(path: "/cluster/status", method: "GET", body: emptyBody)
        let localURL = URL(string: "http://127.0.0.1:\(settings.clusterListenPort)/cluster/status")

        if settings.clusterMode == .standby,
           let remoteNodes = await fetchRemoteLeaderNodesIfAvailable() {
            await applyClusterNodes(remoteNodes)
            return
        }

        if let localURL,
           let response = await clusterStatusService.fetchStatus(from: localURL, headers: localStatusHeaders) {
            let resolvedNodes = response.nodes.isEmpty ? fallbackClusterNodes() : response.nodes
            await applyClusterNodes(resolvedNodes)
            return
        }

        if settings.clusterMode == .worker || settings.clusterMode == .standby,
           let remoteNodes = await fetchRemoteLeaderNodesIfAvailable() {
            await applyClusterNodes(remoteNodes)
            return
        }

        let graceWindow: TimeInterval = 12
        if let lastSuccess = lastClusterStatusSuccessAt,
           Date().timeIntervalSince(lastSuccess) <= graceWindow,
           !lastGoodClusterNodes.isEmpty {
            clusterNodes = lastGoodClusterNodes
        } else {
            clusterNodes = fallbackClusterNodes()
        }
        await refreshRegisteredWorkersDebugInfo()
    }

    private func applyClusterNodes(_ nodes: [ClusterNodeStatus]) async {
        clusterNodes = nodes
        lastGoodClusterNodes = nodes
        lastClusterStatusSuccessAt = Date()
        await refreshRegisteredWorkersDebugInfo()
    }

    private func refreshRegisteredWorkersDebugInfo() async {
        let info = await cluster.registeredWorkersDebugInfo()
        registeredWorkersDebugCount = info.count
        registeredWorkersDebugSummary = info.summary
    }

    private func fetchRemoteLeaderNodesIfAvailable() async -> [ClusterNodeStatus]? {
        guard let baseURL = normalizedSwiftMeshBaseURL(from: settings.clusterLeaderAddress, defaultPort: settings.clusterLeaderPort),
              let statusURL = URL(string: baseURL.absoluteString + "/cluster/status"),
              let host = baseURL.host else {
            return nil
        }

        let emptyBody = Data()
        let statusHeaders = await meshStatusAuthHeaders(path: "/cluster/status", method: "GET", body: emptyBody)
        if let response = await clusterStatusService.fetchStatus(from: statusURL, headers: statusHeaders) {
            let nodes = response.nodes.isEmpty ? fallbackClusterNodes() : response.nodes
            if settings.clusterMode == .standby {
                return ensureLocalStandbyNodePresent(in: nodes)
            }
            return nodes
        }

        guard let pingURL = URL(string: baseURL.absoluteString + "/cluster/ping") else {
            return nil
        }
        let pingHeaders = await meshStatusAuthHeaders(path: "/cluster/ping", method: "GET", body: emptyBody)
        guard let ping = await clusterStatusService.fetchPing(from: pingURL, headers: pingHeaders),
              ping.response.status.caseInsensitiveCompare("ok") == .orderedSame,
              ping.response.role.caseInsensitiveCompare("leader") == .orderedSame else {
            return nil
        }

        var nodes = fallbackClusterNodes()
        if let leaderIndex = nodes.firstIndex(where: { $0.role == .leader }) {
            nodes[leaderIndex].status = .healthy
            nodes[leaderIndex].latencyMs = ping.latencyMs
            nodes[leaderIndex].displayName = ping.response.node
            nodes[leaderIndex].hostname = host
            return nodes
        }

        nodes.append(
            ClusterNodeStatus(
                id: "leader-\(host.lowercased())",
                hostname: host,
                displayName: ping.response.node,
                role: .leader,
                hardwareModel: "Unknown",
                cpu: 0,
                mem: 0,
                cpuName: "Unknown CPU",
                physicalMemoryBytes: 0,
                uptime: 0,
                latencyMs: ping.latencyMs,
                status: .healthy,
                jobsActive: 0
            )
        )
        if settings.clusterMode == .standby {
            return ensureLocalStandbyNodePresent(in: nodes)
        }
        return nodes
    }

    private func ensureLocalStandbyNodePresent(in nodes: [ClusterNodeStatus]) -> [ClusterNodeStatus] {
        guard settings.clusterMode == .standby else { return nodes }
        guard let localWorker = fallbackClusterNodes().first(where: { $0.role != .leader }) else {
            return nodes
        }

        // Match on the non-leader entry that represents *us* in the leader's
        // payload. The leader doesn't know our hardware/cpu/mem (it just
        // emits an `unreachableWorkerNode` stub), so when we find ourselves
        // we *replace* the impoverished entry with our local-rich one,
        // preserving the leader-observed latency.
        let matchIndex = nodes.firstIndex { node in
            guard node.role != .leader else { return false }
            if node.displayName.caseInsensitiveCompare(localWorker.displayName) == .orderedSame {
                return true
            }
            return node.hostname.caseInsensitiveCompare(localWorker.hostname) == .orderedSame
        }

        if let idx = matchIndex {
            var merged = nodes
            var enriched = localWorker
            // Keep the leader's observed latency if we have nothing better locally.
            if enriched.latencyMs == nil { enriched.latencyMs = nodes[idx].latencyMs }
            merged[idx] = enriched
            return merged
        }

        var merged = nodes
        merged.append(localWorker)
        return merged
    }

    private func meshStatusAuthHeaders(path: String, method: String, body: Data) async -> [String: String] {
        let secret = settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return [:] }

        let nonce = UUID().uuidString
        let timestamp = Int(Date().timeIntervalSince1970)
        let signature = await cluster.meshSignature(
            method: method,
            nonce: nonce,
            timestamp: timestamp,
            path: path,
            body: body
        )
        return [
            "X-Mesh-Nonce": nonce,
            "X-Mesh-Timestamp": String(timestamp),
            "X-Mesh-Signature": signature
        ]
    }

    func fallbackClusterNodes() -> [ClusterNodeStatus] {
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = ProcessInfo.processInfo.hostName
        let role: ClusterNodeRole = {
            switch settings.clusterMode {
            case .leader:  return .leader
            case .standby: return .standby
            default:       return .worker
            }
        }()
        let uptime = max(0, Date().timeIntervalSince(launchedAt))
        let hardwareInfo = HardwareInfo.current()
        var nodes: [ClusterNodeStatus] = [
            ClusterNodeStatus(
                id: "\(role.rawValue)-\(hostname.lowercased())-\(settings.clusterListenPort)",
                hostname: hostname,
                displayName: localNodeName,
                role: role,
                hardwareModel: hardwareInfo.modelIdentifier,
                cpu: 0,
                mem: 0,
                cpuName: hardwareInfo.cpuName,
                physicalMemoryBytes: hardwareInfo.physicalMemoryBytes,
                uptime: uptime,
                latencyMs: nil,
                status: clusterSnapshot.serverState.nodeHealthStatus,
                jobsActive: 0
            )
        ]

        if settings.clusterMode == .worker || settings.clusterMode == .standby,
           !settings.clusterLeaderAddress.isEmpty {
            let host = URL(string: settings.clusterLeaderAddress)?.host ?? "Primary"
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
                    latencyMs: nil,
                    status: .disconnected,
                    jobsActive: 0
                )
            )
        }

        return nodes
    }

    // MARK: - SwiftMesh Join Code Support

    /// Fetches the public WAN IP address of the primary node asynchronously.
    /// Tries a couple of endpoints so a single provider being slow or blocked
    /// doesn't silently drop the WAN address from the generated Join Code.
    func fetchPublicIPAddress() async -> String? {
        let endpoints = [
            URL(string: "https://api.ipify.org")!,
            URL(string: "https://ifconfig.me/ip")!,
            URL(string: "https://icanhazip.com")!
        ]
        for url in endpoints {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let ip = String(data: data, encoding: .utf8)?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !ip.isEmpty {
                    return ip
                }
            } catch {
                continue
            }
        }
        return nil
    }

    /// Fetches all active local IPv4 interface addresses (Wi-Fi/Ethernet en0, en1, etc.).
    private func getLocalIPAddresses() -> [String] {
        var addresses = [String]()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            guard let interface = ptr?.pointee else { break }
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                        let ipBytes = hostname
                            .prefix { $0 != 0 }
                            .map { UInt8(bitPattern: $0) }
                        let ip = String(bytes: ipBytes, encoding: .utf8) ?? ""
                        if !ip.isEmpty && ip != "127.0.0.1" {
                            addresses.append(ip)
                        }
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return addresses
    }

    /// Generates a base64-encoded SwiftMesh Join Code containing the leader's address details and secret.
    func generateSwiftMeshJoinCode() async -> String? {
        var addresses = [String]()

        // Local LAN IPs first — preferred when pairing on the same network.
        let lanAddresses = getLocalIPAddresses()
        addresses.append(contentsOf: lanAddresses)

        // Public WAN IP next — used by standby nodes off-LAN.
        let wanAddress = await fetchPublicIPAddress()
        if let wanAddress, !addresses.contains(wanAddress) {
            addresses.append(wanAddress)
        }

        // Add configured leader address if not already present and not a loopback.
        let configured = settings.clusterLeaderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty && configured != "localhost" && configured != "127.0.0.1" {
            if !addresses.contains(configured) {
                addresses.append(configured)
            }
        }

        if addresses.isEmpty {
            addresses.append("127.0.0.1")
        }

        let port = settings.clusterListenPort
        let sharedSecret = ensureSwiftMeshSharedSecret()

        let bundle = SwiftMeshJoinBundle(
            leaderAddresses: addresses,
            leaderPort: port,
            sharedSecret: sharedSecret,
            leaderTerm: settings.clusterLeaderTerm
        )

        // Surface what's in the code so the user can see at a glance whether
        // both LAN and WAN routes are included.
        let lanSummary = lanAddresses.isEmpty ? "none" : lanAddresses.joined(separator: ", ")
        let wanSummary = wanAddress ?? "unavailable (public IP lookup failed)"
        logs.append("[SwiftMesh] Join Code generated — LAN: \(lanSummary); WAN: \(wanSummary); port: \(port).")
        if wanAddress == nil {
            logs.append("[SwiftMesh] ⚠️ Public IP lookup failed — Join Code will only work for standby nodes on the same LAN. Check internet access and try again.")
        }

        guard let data = try? JSONEncoder().encode(bundle) else { return nil }
        let b64 = data.base64EncodedString()
        return "swiftmesh://join?b=\(b64)"
    }

    private func ensureSwiftMeshSharedSecret() -> String {
        let existing = settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        settings.clusterSharedSecret = generated
        saveSettings()
        logs.append("[SwiftMesh] Generated a shared secret for the Join Code.")
        return generated
    }

    /// Decodes a SwiftMesh Join Code into a configuration bundle.
    func decodeSwiftMeshJoinCode(_ rawCode: String) throws -> SwiftMeshJoinBundle {
        let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SwiftMeshJoinError.empty }

        let base64: String
        if trimmed.hasPrefix("swiftmesh://join?") {
            guard let components = URLComponents(string: trimmed),
                  let value = components.queryItems?.first(where: { $0.name == "b" })?.value else {
                throw SwiftMeshJoinError.invalidCode
            }
            base64 = value
        } else {
            base64 = trimmed
        }

        guard let data = Data(base64Encoded: base64) else {
            throw SwiftMeshJoinError.invalidBase64
        }

        do {
            return try JSONDecoder().decode(SwiftMeshJoinBundle.self, from: data)
        } catch {
            throw SwiftMeshJoinError.invalidJSON
        }
    }

    /// Applies a SwiftMesh Join Code bundle to settings.
    func applySwiftMeshJoinCode(_ rawCode: String) -> (ok: Bool, message: String) {
        do {
            let bundle = try decodeSwiftMeshJoinCode(rawCode)

            // We do not save a single leaderAddress yet. We let the Standby's
            // connection tester cycle through `bundle.leaderAddresses` to find
            // the working one, and save the winner. But as a safe fallback we set
            // the first address now.
            if let firstAddress = bundle.leaderAddresses.first {
                settings.clusterLeaderAddress = firstAddress
            } else {
                settings.clusterLeaderAddress = "127.0.0.1"
            }

            settings.clusterLeaderPort = bundle.leaderPort
            settings.clusterListenPort = bundle.leaderPort // Keep them aligned by default
            settings.clusterSharedSecret = bundle.sharedSecret
            settings.clusterLeaderTerm = max(0, bundle.leaderTerm)
            settings.clusterMode = .standby
            settings.launchMode = .swiftMeshClusterNode

            // Auto-generate a node name if none is configured
            if settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let name = Host.current().localizedName ?? "Standby Node"
                let randomID = String(UUID().uuidString.prefix(4)).lowercased()
                settings.clusterNodeName = "\(name)-\(randomID)"
            }

            saveSettings()
            return (true, "Join code parsed successfully.")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Asynchronously tests each address in the Join Code (tries local LAN IPs first, then falls back to public WAN IP) and binds to the winner.
    func testWorkerJoinCodeConnection(addresses: [String], port: Int) async -> Bool {
        await MainActor.run {
            self.workerConnectionTestInProgress = true
            self.workerConnectionTestIsSuccess = false
            self.workerConnectionTestStatus = "Testing connection..."
            self.workerConnectionTestOutcome = nil
        }

        var workingAddress: String?
        var finalOutcome: WorkerConnectionTestOutcome?

        // Try local LAN IPs first, then fall back to public WAN IP
        for addr in addresses {
            await MainActor.run {
                self.workerConnectionTestStatus = "Trying \(addr)..."
            }
            let outcome = await performWorkerConnectionTest(
                leaderAddress: addr,
                leaderPort: port
            )
            if outcome.isSuccess {
                workingAddress = addr
                finalOutcome = outcome
                break
            } else {
                finalOutcome = outcome
            }
        }

        let success = workingAddress != nil
        let statusMessage = finalOutcome?.message ?? "Connection failed."

        await MainActor.run {
            if let winner = workingAddress {
                self.settings.clusterLeaderAddress = winner
                self.saveSettings()
            }
            self.workerConnectionTestInProgress = false
            self.workerConnectionTestIsSuccess = success
            self.workerConnectionTestStatus = success ? "Success! Bound to \(workingAddress ?? "")" : statusMessage
            self.workerConnectionTestOutcome = finalOutcome
            self.lastClusterStatusRefreshAt = Date()
            self.logs.append("SwiftMesh worker connection test: \(success ? "Success on \(workingAddress ?? "")" : statusMessage)")
        }

        return success
    }

    /// Decodes an incoming `swiftmesh://join?b=...` deep link and routes it to
    /// the right surface:
    ///
    /// - Mid-onboarding: stash the raw code so `OnboardingRootView` can switch
    ///   to the SwiftMesh setup step and auto-apply it — no extra window.
    /// - Post-onboarding: stash a pending request so `RootView` shows a
    ///   confirmation sheet before applying. Never auto-apply post-onboarding;
    ///   a malicious link could otherwise silently repoint this node.
    @MainActor
    @discardableResult
    func handleSwiftMeshDeepLink(_ url: URL) -> Bool {
        guard url.scheme == "swiftmesh", url.host == "join" else { return false }
        let raw = url.absoluteString
        do {
            let bundle = try decodeSwiftMeshJoinCode(raw)
            if isOnboardingComplete {
                pendingSwiftMeshJoin = PendingSwiftMeshJoin(rawCode: raw, bundle: bundle)
                logs.append("[SwiftMesh] Received join code via deep link; awaiting confirmation.")
            } else {
                pendingMeshOnboardingCode = raw
                logs.append("[SwiftMesh] Received join code via deep link; routing through onboarding.")
            }
            return true
        } catch {
            logs.append("[SwiftMesh] Ignoring invalid join deep link: \(error.localizedDescription)")
            return false
        }
    }

    /// Generates a fresh shared secret, invalidating any previously distributed
    /// Join Codes. Existing connected workers will need to re-pair.
    @MainActor
    func rotateSwiftMeshSharedSecret() {
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        settings.clusterSharedSecret = generated
        saveSettings()
        logs.append("[SwiftMesh] Rotated shared secret — existing Join Codes are now invalid.")
    }
}

struct SwiftMeshJoinBundle: Codable {
    let leaderAddresses: [String]
    let leaderPort: Int
    let sharedSecret: String
    let leaderTerm: Int

    init(leaderAddresses: [String], leaderPort: Int, sharedSecret: String, leaderTerm: Int = 0) {
        self.leaderAddresses = leaderAddresses
        self.leaderPort = leaderPort
        self.sharedSecret = sharedSecret
        self.leaderTerm = leaderTerm
    }

    private enum CodingKeys: String, CodingKey {
        case leaderAddresses
        case leaderPort
        case sharedSecret
        case leaderTerm
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leaderAddresses = try container.decode([String].self, forKey: .leaderAddresses)
        leaderPort = try container.decode(Int.self, forKey: .leaderPort)
        sharedSecret = try container.decode(String.self, forKey: .sharedSecret)
        leaderTerm = try container.decodeIfPresent(Int.self, forKey: .leaderTerm) ?? 0
    }
}

/// Pending deep-link join request, presented as a confirmation sheet in `RootView`.
struct PendingSwiftMeshJoin: Identifiable, Equatable {
    let id = UUID()
    let rawCode: String
    let bundle: SwiftMeshJoinBundle

    static func == (lhs: PendingSwiftMeshJoin, rhs: PendingSwiftMeshJoin) -> Bool {
        lhs.id == rhs.id
    }
}

enum SwiftMeshJoinError: LocalizedError {
    case empty
    case invalidCode
    case invalidBase64
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The copied code is empty. Please copy a valid SwiftMesh join code first."
        case .invalidCode:
            return "That does not look like a valid SwiftMesh join code."
        case .invalidBase64:
            return "The SwiftMesh join payload could not be decoded."
        case .invalidJSON:
            return "The SwiftMesh join payload is corrupted."
        }
    }
}
