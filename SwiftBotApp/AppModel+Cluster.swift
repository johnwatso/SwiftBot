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

    func configureMeshSync() {
        meshSyncTask?.cancel()
        meshSyncTask = nil

        guard settings.clusterMode == .leader || settings.clusterMode == .standby else { return }

        meshSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                // Leader pushes, Standby pulls
                // Sync every 10 seconds so failover config changes propagate quickly.
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }

                guard let self else { break }

                if self.settings.clusterMode == .leader {
                    // 1. Push worker registry to all nodes
                    await self.cluster.pushWorkerRegistryToStandbys()
                    // 2. Push incremental conversation batches per node
                    await self.pushIncrementalConversationsToAllNodes()
                } else if self.settings.clusterMode == .standby {
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
                fromCursorRecordID: fromID
            )
            let ok = await cluster.pushConversationsToSingleNode(baseURL, payload)
            if ok, lastID != nil {
                await cluster.updateReplicationCursor(for: nodeName, lastSentRecordID: lastID, term: currentTerm)
            }
        }
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
        let imported = await store.importMeshSyncedFiles(
            data,
            excludingFileNames: Set([
                SwiftBotStorage.swiftMeshConfigFileName,
                SwiftBotStorage.clusterStateFileName
            ])
        )
        guard imported > 0 else { return }

        logs.append("SwiftMesh: pulled \(imported) config file(s) from Primary")
        await reloadSyncedConfigFromDisk()
    }

    func reloadSyncedConfigFromDisk() async {
        // Keep local mesh identity authoritative on this node.
        let currentLocalMesh = settings.swiftMeshSettings
        let currentLocalMedia = mediaLibrarySettings
        let currentLocalAdminWebUI = settings.adminWebUI
        let currentLocalRemoteAccessToken = settings.remoteAccessToken
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
            reloaded.remoteAccessToken = currentLocalRemoteAccessToken
        }
        reloaded.wikiBot.normalizeSources()
        settings = reloaded
        mediaLibrarySettings = currentLocalMedia
        await mediaLibraryIndexer.invalidate()
        await ruleStore.reloadFromDisk()
        await aiService.configureLocalAIDMReplies(
            enabled: settings.localAIDMReplyEnabled,
            provider: settings.localAIProvider,
            preferredProvider: settings.preferredAIProvider,
            endpoint: localAIEndpointForService(),
            model: settings.localAIModel,
            openAIAPIKey: effectiveOpenAIAPIKey(),
            openAIModel: settings.openAIModel,
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

        // Phase 4: Configuration Consistency - log final mesh endpoint
        if mode != .standalone {
            let host = ProcessInfo.processInfo.hostName
            logs.append("SwiftMesh listening on \(host):\(listenPort)")
        }

        await cluster.setOffloadPolicy(
            workerOffloadEnabled: settings.clusterWorkerOffloadEnabled,
            aiReplies: settings.clusterOffloadAIReplies,
            wikiLookups: settings.clusterOffloadWikiLookups
        )
        // Sync secondary safety guard: only Primary nodes may send Discord output.
        let isPrimary = mode == .standalone || mode == .leader
        await service.setOutputAllowed(isPrimary)
        configureMeshSync()
        if mode == .standby {
            await pullConfigFilesFromLeader()
        }
        await pollClusterStatus()
    }

    func pollClusterStatus() async {
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
        guard let localWorker = fallbackClusterNodes().first(where: { $0.role == .worker }) else {
            return nodes
        }

        let hasLocal = nodes.contains { node in
            guard node.role == .worker else { return false }
            if node.displayName.caseInsensitiveCompare(localWorker.displayName) == .orderedSame {
                return true
            }
            return node.hostname.caseInsensitiveCompare(localWorker.hostname) == .orderedSame
        }
        guard !hasLocal else { return nodes }

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
        let role: ClusterNodeRole = settings.clusterMode == .leader ? .leader : .worker
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

}
