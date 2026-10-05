import Foundation

/// The WebUI's SwiftMesh page: the same state and actions as `SwiftMeshView`.
extension AppModel {
    func adminWebSwiftMeshJoinCode() async -> String? {
        guard settings.clusterMode == .leader,
              await cluster.currentSnapshot().mode == .leader else { return nil }
        let code = await generateSwiftMeshJoinCode()
        // Address discovery suspends; ownership may have changed meanwhile.
        guard settings.clusterMode == .leader,
              await cluster.currentSnapshot().mode == .leader else { return nil }
        return code
    }

    func adminWebSwiftMeshSnapshot() async -> AdminWebSwiftMeshPayload {
        // The native view polls while it's open; the web page polls this
        // endpoint instead, so refresh here too.
        await pollClusterStatus()
        let snapshot = await cluster.currentSnapshot()
        clusterSnapshot = snapshot

        let followers = Array(snapshot.followerStates.values)
        let nodes = clusterNodes.map { node -> AdminWebSwiftMeshPayload.Node in
            let follower = followers.first { $0.nodeName.caseInsensitiveCompare(node.displayName) == .orderedSame }
            var result = AdminWebSwiftMeshPayload.Node(
                id: node.id,
                displayName: node.displayName,
                hostname: node.hostname,
                role: node.role.rawValue,
                status: node.status.rawValue,
                hardwareModel: node.hardwareModel,
                cpuName: node.cpuName,
                memoryBytes: node.physicalMemoryBytes,
                uptimeSeconds: node.uptime,
                jobsActive: node.jobsActive,
                latencyMs: node.latencyMs,
                isThisNode: node.displayName.caseInsensitiveCompare(settings.clusterNodeName) == .orderedSame,
                follower: follower.map {
                    AdminWebSwiftMeshPayload.Follower(
                        mode: $0.mode,
                        gatewayConnected: $0.gatewayConnected,
                        outputAllowed: $0.outputAllowed,
                        lastEventAt: $0.lastEventAt,
                        activeVoiceMembers: $0.activeVoiceMembers,
                        discordLatencyMs: $0.discordGatewayLatencyMs,
                        collectedAt: $0.collectedAt
                    )
                }
            )
            result.operatorID = operatorID(forNode: node.displayName)
            result.iconOverride = settings.clusterNodeIconOverrides[node.displayName]
            return result
        }

        let isTestPending = snapshot.isHandoverTestActive || snapshot.scheduledHandoverTestAt != nil
        return AdminWebSwiftMeshPayload(
            configuredMode: settings.clusterMode.rawValue,
            runtimeMode: snapshot.mode.rawValue,
            runtimeState: snapshot.runtimeState.rawValue,
            nodeName: settings.clusterNodeName,
            leaderAddress: settings.clusterLeaderAddress,
            leaderPort: settings.clusterLeaderPort,
            listenPort: settings.clusterListenPort,
            leaderTerm: snapshot.leaderTerm,
            workerOffloadEnabled: settings.clusterWorkerOffloadEnabled,
            offloadAIReplies: settings.clusterOffloadAIReplies,
            offloadWikiLookups: settings.clusterOffloadWikiLookups,
            automaticHandbackEnabled: settings.clusterAutomaticHandbackEnabled,
            autoReclaimAfterHours: settings.clusterAutoReclaimAfterHours,
            autoReclaimRemainingSeconds: autoReclaimRemainingSeconds,
            server: .init(state: snapshot.serverState.rawValue, text: snapshot.serverStatusText),
            worker: .init(state: snapshot.workerState.rawValue, text: snapshot.workerStatusText),
            diagnostics: snapshot.diagnostics,
            lastJobRoute: snapshot.lastJobRoute.rawValue,
            lastJobNode: snapshot.lastJobNode,
            lastJobSummary: snapshot.lastJobSummary,
            registeredWorkers: registeredWorkersDebugCount,
            localGatewayLatencyMs: connectionDiagnostics.heartbeatLatencyMs,
            handover: .init(
                isActive: snapshot.isHandoverTestActive,
                scheduledAt: snapshot.scheduledHandoverTestAt,
                endsAt: snapshot.handoverTestEndsAt,
                lastRunAt: settings.clusterLastHandoverTestAt,
                lastRunOK: settings.clusterLastHandoverTestOK,
                canRun: settings.clusterMode == .leader && registeredWorkersDebugCount > 0 && !isTestPending
            ),
            nodes: nodes,
            iconOptions: SwiftMeshNodeIconCatalog.all.map { .init(symbol: $0.symbol, label: $0.label) }
        )
    }

    /// Runs a SwiftMesh action from the web page. Returns nil when done, or
    /// why it couldn't run.
    func runAdminWebSwiftMeshAction(_ request: AdminWebSwiftMeshAction) async -> String? {
        switch request.action {
        case "handoverTest":
            guard settings.clusterMode == .leader else { return "Only the Primary can run a handover test." }
            guard registeredWorkersDebugCount > 0 else { return "There's no Fail Over node to hand over to." }
            let snapshot = await cluster.currentSnapshot()
            guard !snapshot.isHandoverTestActive, snapshot.scheduledHandoverTestAt == nil else {
                return "A handover test is already scheduled or running."
            }
            await runSwiftMeshHandoverTest()
        case "cancelHandoverTest":
            let snapshot = await cluster.currentSnapshot()
            guard snapshot.scheduledHandoverTestAt != nil, !snapshot.isHandoverTestActive else {
                return "Only a test that hasn't started yet can be cancelled."
            }
            await cancelScheduledHandoverTest()
        case "promote":
            guard settings.clusterMode == .standby else { return "Only a Fail Over node can be promoted." }
            await manuallyPromoteToPrimary()
        case "forget":
            let name = request.node?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let node = clusterNodes.first(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) else {
                return "That node isn't in the cluster."
            }
            guard node.status == .disconnected else { return "Only disconnected nodes can be forgotten." }
            await forgetClusterNode(displayName: node.displayName)
        case "setIcon":
            let name = request.node?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let node = clusterNodes.first(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) else {
                return "That node isn't in the cluster."
            }
            if let icon = request.icon {
                guard SwiftMeshNodeIconCatalog.all.contains(where: { $0.symbol == icon }) else { return "Unknown icon." }
                settings.clusterNodeIconOverrides[node.displayName] = icon
            } else {
                settings.clusterNodeIconOverrides.removeValue(forKey: node.displayName)
            }
            saveSettings()
        default:
            return "Unknown action."
        }
        refreshClusterStatus()
        return nil
    }
}
