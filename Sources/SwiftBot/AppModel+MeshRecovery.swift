import Foundation
import RuruClient

extension AppModel {
    /// Called when the app is about to terminate. A confirmed system logout or
    /// power-off is reported before the existing stop/drain/release sequence.
    /// The lease is released only if local work and settings drain successfully;
    /// otherwise it expires under its existing deadline after this process exits.
    func prepareForApplicationTermination(systemEnding: Bool) async -> Bool {
        let presenceTask = meshWitnessHealthTask
        meshWitnessHealthTask?.cancel()
        meshWitnessHealthTask = nil
        await presenceTask?.value

        if systemEnding {
            let role: MeshWitnessClient.ParticipantRole
            switch runtimeClusterMode {
            case .leader: role = meshOwnershipExpired ? .unknown : .active
            case .standby: role = .standby
            case .worker: role = .worker
            default: role = .unknown
            }
            let power = PowerSourceMonitor.current()
            _ = await meshWitnessClient.reportPresence(role: role, webUIURL: localMeshPublicAddress,
                power: power.source != .unknown ? power : nil, sessionEnding: true)
        }

        return await freezeMeshWrites()
    }

    /// The witness settings live in the Keychain; read them off the main
    /// thread so a Keychain prompt can't freeze the app during launch.
    nonisolated static func loadWitnessSettingsOffMain() async -> MeshWitnessConfiguration {
        await Task.detached(priority: .userInitiated) { MeshWitnessSettingsStore.load() }.value
    }

    /// Install recovery hooks before applying the configured placement. The
    /// coordinator, rather than saved preferences, owns the live output role.
    func configureMeshRecovery() async {
        recordingWitnessConfiguration = .init()
        do {
            let enrollment = try await meshCredentialStore.loadOrCreateLocalEnrollment()
            if settings.clusterMode == .leader {
                try await meshCredentialStore.authorize(enrollment: enrollment, nodeName: settings.clusterNodeName)
            }
            await cluster.setCredentialAuthorization(provider: { [weak self] id in
                await self?.meshCredentialStore.authorizedPublicKey(nodeID: id)
            }, localNodeID: enrollment.nodeID, localToken: enrollment.token)
            let witness = await Self.loadWitnessSettingsOffMain()
            recordingWitnessConfiguration = witness
            await meshWitnessClient.configure(witness, nodeID: enrollment.nodeID, nodeName: settings.clusterNodeName)
            meshLocalNodeID = enrollment.nodeID
            if let ruruConfig = witness.toRuruConfiguration(nodeID: enrollment.nodeID, nodeName: settings.clusterNodeName) {
                ruruLeaseClient = RuruLeaseClient(configuration: ruruConfig)
            } else {
                ruruLeaseClient = nil
            }
            currentRuruLease = nil
            let leaseClient = ruruLeaseClient
            updateMeshWitnessMonitoring(witness)
            if witness.isConfigured && settings.clusterMode != .standalone {
                await cluster.setOwnershipHandlers(acquire: { [weak self] term in
                    guard let self, let leaseClient else { return nil }
                    do {
                        let lease = try await leaseClient.acquire()
                        guard Int(lease.term) >= term else {
                            try? await leaseClient.release(lease)
                            return nil
                        }
                        await self.setRuruLease(lease)
                        await self.updateMeshOwnershipDeadline(lease.deadline)
                        return Int(lease.term)
                    } catch {
                        return nil
                    }
                }, renew: { [weak self] term in
                    guard let self, let leaseClient else { return .lost }
                    let lease = await self.currentRuruLease
                    guard let lease else { return .lost }
                    do {
                        let renewed = try await leaseClient.renew(lease)
                        await self.setRuruLease(renewed)
                        await self.updateMeshOwnershipDeadline(renewed.deadline)
                        return .renewed
                    } catch RuruError.ownershipLost {
                        await self.setRuruLease(nil)
                        await self.updateMeshOwnershipDeadline(ContinuousClock.now)
                        return .lost
                    } catch {
                        return .unreachable(stillValid: lease.isValid)
                    }
                }, release: { [weak self] term in
                    guard let self else { return }
                    await self.service.setOutputAllowed(false)
                    if let leaseClient, let lease = await self.currentRuruLease {
                        try? await leaseClient.release(lease)
                    }
                    await self.setRuruLease(nil)
                }, witnessFingerprint: witness.ownershipFingerprint)
            } else {
                await cluster.setOwnershipHandlers(acquire: nil, renew: nil, release: nil)
                await updateMeshOwnershipDeadline(nil)
            }
        } catch {
            if await Self.loadWitnessSettingsOffMain().isConfigured && settings.clusterMode != .standalone {
                await cluster.setOwnershipHandlers(acquire: { _ in nil }, renew: { _ in .lost }, release: { _ in },
                                                   witnessFingerprint: (await Self.loadWitnessSettingsOffMain()).ownershipFingerprint)
                await updateMeshOwnershipDeadline(ContinuousClock.now)
            }
            logs.append("SwiftMesh credential setup failed: \(error.localizedDescription)")
            await service.setOutputAllowed(false)
        }
        await cluster.setServiceHealthProvider { [weak self] in
            await self?.status == .running
        }
        await cluster.setDemotionHandler { [weak self] in await self?.meshDidDemote() }
        await cluster.setPromotionReadinessHandler { [weak self] in
            guard let self else { return "host unavailable" }
            return await self.meshPromotionReadiness()
        }
        await cluster.setHandbackDrainHandler { [weak self] in
            guard let self else { return false }
            return await self.freezeMeshWrites()
        }
        await cluster.setHandbackResumeHandler { [weak self] in await self?.resumeMeshWrites() }
        await cluster.setHandbackCatchupHandler { [weak self] _, term in
            guard let self else { return false }
            return await self.catchUpForHandback(term: term)
        }
        await cluster.setPublicMeshAddress(localMeshPublicAddress)
        await cluster.setAutoReclaimPolicy(
            isConfiguredPrimary: settings.clusterMode == .leader,
            afterHours: settings.clusterAutoReclaimAfterHours,
            automaticHandbackEnabled: settings.clusterAutomaticHandbackEnabled
        )
        await configureRecordingCoordination()
    }

    /// Polls Ruru's `/health` for the SwiftMesh map. Display only: ownership
    /// still comes solely from lease grants and the local deadline.
    func updateMeshWitnessMonitoring(_ witness: MeshWitnessConfiguration) {
        meshWitnessHealthTask?.cancel()
        meshWitnessHealthTask = nil
        restartMeshPrimaryPolicyPolling(configured: witness.isValid && settings.clusterMode != .standalone)
        guard witness.isValid, settings.clusterMode != .standalone else {
            meshWitnessHealth = nil
            meshWitnessEndpoint = ""
            return
        }
        if meshWitnessEndpoint != witness.endpoint { meshWitnessHealth = .checking }
        meshWitnessEndpoint = witness.endpoint
        guard !Self.isRunningUnderXCTest else { return }
        meshWitnessHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let client = self?.meshWitnessClient else { return }
                let health = await client.health()
                guard !Task.isCancelled else { return }
                self?.meshWitnessHealth = health
                // Automatic handback waits for Ruru to be ready (not in restart quarantine).
                self?.meshPrimaryPreferenceTracker.setAuthorityReady(health == .ready)
                await self?.publishMeshPrimaryPreference()
                guard !Task.isCancelled else { return }
                let role: MeshWitnessClient.ParticipantRole
                switch self?.runtimeClusterMode {
                case .leader: role = self?.meshOwnershipExpired == false ? .active : .unknown
                case .standby: role = .standby
                case .worker: role = .worker
                default: role = .unknown
                }
                let power = PowerSourceMonitor.current()
                await client.reportPresence(role: role, webUIURL: self?.localMeshPublicAddress,
                                            power: power.source != .unknown ? power : nil)
                guard let self else { return }
                let readiness = await self.currentMeshOperationalReadiness()
                self.meshOperationalReadiness = readiness
                _ = await client.reportOperationalStatus(readiness)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Clears cached intent (any endpoint, cluster or token change, or stop)
    /// and, when configured, polls `POST /v1/service/policy` every 5 s. Results
    /// from an earlier generation are dropped by the tracker.
    func restartMeshPrimaryPolicyPolling(configured: Bool) {
        meshPrimaryPolicyTask?.cancel()
        meshPrimaryPolicyTask = nil
        let generation = meshPrimaryPreferenceTracker.reset(configured: configured)
        meshPrimaryPreferenceTracker.setAuthorityReady(meshWitnessHealth == .ready)
        Task { await publishMeshPrimaryPreference() }
        guard configured, !Self.isRunningUnderXCTest else { return }
        meshPrimaryPolicyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let client = self?.meshWitnessClient else { return }
                let fetch = await client.primaryPolicy()
                guard !Task.isCancelled, let self else { return }
                if let fetch, self.meshPrimaryPreferenceTracker.ingest(fetch, generation: generation, at: .now) {
                    await self.publishMeshPrimaryPreference()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The Mac that runs the bot now, from the cluster map.
    var meshCurrentOwnerName: String {
        if runtimeClusterMode == .leader, !meshOwnershipExpired {
            return settings.clusterNodeName.isEmpty ? "This Mac" : "\(settings.clusterNodeName) (this Mac)"
        }
        return clusterNodes.first { $0.role == .leader && $0.status != .disconnected }?.displayName ?? "None"
    }

    /// A node's name from its stable ID: this Mac, or a paired grant.
    func meshNodeName(forNodeID id: String, grants: [MeshCredentialGrant]) -> String {
        if id == meshLocalNodeID {
            return settings.clusterNodeName.isEmpty ? "This Mac" : "\(settings.clusterNodeName) (this Mac)"
        }
        if let grant = grants.first(where: { $0.nodeID == id }), !grant.nodeName.isEmpty {
            return grant.nodeName
        }
        return "Node \(id.prefix(8))"
    }

    func meshPreferredPrimaryText(grants: [MeshCredentialGrant]) -> String {
        let preference = meshPrimaryPreference
        let preferred = preference.policy?.preferredPrimaryNodeID.map { meshNodeName(forNodeID: $0, grants: grants) }
        switch preference.status {
        case .notConfigured: return "—"
        case .checking: return "Checking Ruru…"
        case .unsupported: return "Not supported by this Ruru"
        case .unavailable: return preferred.map { "Unavailable (last: \($0))" } ?? "Unavailable"
        case .current: return preferred ?? "None set in Ruru"
        }
    }

    func publishMeshPrimaryPreference() async {
        let preference = meshPrimaryPreferenceTracker.preference
        if meshPrimaryPreference != preference { meshPrimaryPreference = preference }
        await cluster.setPrimaryPreference(preference)
    }

    func setRuruLease(_ lease: RuruLease?) {
        currentRuruLease = lease
    }

    var meshOwnershipExpired: Bool {
        meshOwnershipDeadline.map { ContinuousClock.now >= $0 } ?? false
    }

    func updateMeshOwnershipDeadline(_ deadline: ContinuousClock.Instant?) async {
        meshOwnershipDeadline = deadline
        await service.setOutputLeaseDeadline(deadline)
    }

    var localMeshPublicAddress: String {
        guard settings.adminWebUI.enabled else { return "" }
        if settings.adminWebUI.internetAccessEnabled, !settings.adminWebUI.normalizedHostname.isEmpty {
            return "https://" + settings.adminWebUI.normalizedHostname
        }
        let active = adminWebPublicAccessStatus.publicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return active.isEmpty ? settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) : active
    }

    func restoreMeshCommandCooldowns() {
        let url = SwiftBotStorage.folderURL().appendingPathComponent("bot-command-cooldowns.json")
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: Date].self, from: data) else { return }
        lastCommandTimeByUserId = values.filter { Date().timeIntervalSince($0.value) < commandCooldown }
    }

    func persistMeshCommandCooldowns() {
        let url = SwiftBotStorage.folderURL().appendingPathComponent("bot-command-cooldowns.json")
        let recent = lastCommandTimeByUserId.filter { Date().timeIntervalSince($0.value) < commandCooldown }
        try? JSONEncoder().encode(recent).write(to: url, options: .atomic)
    }

    func meshPromotionReadiness() async -> String? {
        guard automationStore.isLoaded else { return "automation rules are not loaded" }
        guard !settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Discord token has not been paired" }
        guard await store.meshSnapshotVersion() != nil else { return "shared configuration has not completed its first sync" }
        guard let enrollment = try? await meshCredentialStore.loadOrCreateLocalEnrollment(),
              await meshCredentialStore.authorizedPublicKey(nodeID: enrollment.nodeID) != nil else { return "this failover has no credential approval" }
        return nil
    }

    /// Builds a local report only. No caller may use this result to change
    /// cluster ownership, output gating, or a Ruru lease.
    func currentMeshOperationalReadiness() async -> MeshOperationalReadiness {
        let hasSnapshot = await store.meshSnapshotVersion() != nil
        let credentialsApproved: Bool
        if let enrollment = try? await meshCredentialStore.loadOrCreateLocalEnrollment() {
            credentialsApproved = await meshCredentialStore.authorizedPublicKey(nodeID: enrollment.nodeID) != nil
        } else {
            credentialsApproved = false
        }
        let peerState: RuruOperationalState
        if settings.clusterMode == .standalone {
            peerState = .unknown
        } else if clusterNodes.contains(where: { $0.status == .disconnected }) {
            peerState = .degraded
        } else if settings.clusterMode == .standby, meshLastSuccessfulSync == nil {
            peerState = .synchronizing
        } else if let lastSync = meshLastSuccessfulSync, Date().timeIntervalSince(lastSync) > 60 {
            peerState = .degraded
        } else if clusterNodes.isEmpty {
            peerState = .unknown
        } else {
            peerState = .ready
        }
        return MeshOperationalReadiness.evaluate(automationsLoaded: automationStore.isLoaded,
                                                 hasDiscordToken: !settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                                 hasSnapshot: hasSnapshot, credentialsApproved: credentialsApproved,
                                                 peerState: peerState, discordConnected: status == .running)
    }

    func meshCredentialsSnapshot() async -> MeshCredentialsResponse {
        let term = await cluster.currentLeaderTerm()
        _ = await store.exportMeshSyncedFiles(excludingFileNames: [], leaderTerm: term)
        let version = await store.meshSnapshotVersion()
        let grants = await meshCredentialStore.allGrants()
        return MeshCredentialsResponse(
            gameProviderTokens: Dictionary(uniqueKeysWithValues: GameProviderID.allCases.map { ($0.rawValue, settings.gameProviders.token(for: $0)) }),
            discordOAuthClientSecret: settings.adminWebUI.discordOAuth.clientSecret,
            discordToken: settings.token,
            automationWebhookURLs: AutomationWebhookVault.urls(for: automationStore.rules),
            authorizedCredentialGrants: grants, leaderTerm: term, configRevision: version?.revision ?? 0
        )
    }

    @discardableResult
    func pullMeshConfiguration() async -> Bool {
        guard await cluster.currentSnapshot().mode == .standby,
              let data = await cluster.fetchConfigFiles() else { return false }
        return await applyMeshSyncedConfigFiles(data, sourceDescription: "pulled")
    }

    func catchUpForHandback(term: Int) async -> Bool {
        guard await pullMeshConfiguration(), await syncMeshCredentials() else { return false }
        var cursor = localLastMergedRecordID
        // Bounded iterative paging: a frozen owner cannot grow this history.
        for _ in 0..<100 {
            guard let page = await cluster.fetchResyncPage(fromRecordID: cursor, pageSize: 500),
                  page.leaderTerm == term else { return false }
            await handleMeshSync(page, paginate: false)
            let next = page.cursorRecordID ?? page.conversations.last?.id
            if page.hasMore, next == nil || next == cursor { return false }
            cursor = next
            if !page.hasMore {
                await pullWikiCacheFromLeader()
                guard await pullMeshConfiguration(), await syncMeshCredentials() else { return false }
                meshLastSuccessfulSync = Date()
                return await cluster.currentLeaderTerm() == term
            }
        }
        return false
    }

    func freezeMeshWrites() async -> Bool {
        meshWritesPaused = true
        await service.setOutputAllowed(false)
        guard await automationService.pauseAndDrain() else { return false }
        patchyMonitorTask?.cancel()
        patchyMonitorTask = nil
        gameTrackingMonitorTask?.cancel()
        gameTrackingMonitorTask = nil
        cancelGameSessionSweeper()
        await communityStatsStore.flush()
        await automationStore.saveNow()
        do { try await store.save(settings) } catch { return false }
        return true
    }

    func resumeMeshWrites() async {
        let owns = await cluster.hasActiveOwnership()
        guard owns else { return }
        meshWritesPaused = false
        await automationService.resume()
        await service.setOutputAllowed(true)
        configurePatchyMonitoring()
        lastGameTrackingMonitoringSnapshot = nil
        configureGameTrackingMonitoring()
        await automationService.resumePendingExecutions(token: settings.token, rules: automationStore.rules)
    }

    func meshDidPromote() async {
        lastPublishedRole = .leader
        restoreMeshCommandCooldowns()
        meshWritesPaused = false
        await automationService.resume()
        logs.append("SwiftMesh promoted to Primary after checking shared state and ownership.")
        await handleClusterRoleChange()
        await connectDiscordAfterPromotion()
    }

    /// A deliberate Stop is not a demotion. `ClusterCoordinator.stopAll()` runs
    /// the demotion handler to close output, which marks this Mac as Standby
    /// and leaves the released lease's deadline to expire; either one locked a
    /// stopped Primary's settings as "managed by the Primary node". Output is
    /// already closed here, and Start acquires ownership again before enabling it.
    func meshDidStop() async {
        // Stale intent must not survive a stop; Start polls again.
        meshPrimaryPolicyTask?.cancel()
        meshPrimaryPolicyTask = nil
        meshPrimaryPreferenceTracker.reset(configured: meshWitnessHealth != nil)
        await publishMeshPrimaryPreference()
        lastPublishedRole = nil
        clusterSnapshot = await cluster.currentSnapshot()
        currentRuruLease = nil
        await updateMeshOwnershipDeadline(nil)
    }

    func meshDidDemote() async {
        meshWritesPaused = true
        await service.setOutputAllowed(false)
        _ = await automationService.pauseAndDrain()
        await service.disconnect()
        lastPublishedRole = .standby
        status = .stopped
        logs.append("SwiftMesh returned to Standby; Discord output closed.")
        await handleClusterRoleChange()
        meshWritesPaused = false
    }

    @discardableResult
    func syncMeshCredentials() async -> Bool {
        guard await cluster.currentSnapshot().mode == .standby,
              let payload = await cluster.fetchCredentials(),
              let term = payload.leaderTerm, term == (await cluster.currentLeaderTerm()),
              let revision = payload.configRevision,
              let version = await store.meshSnapshotVersion(), version.leaderTerm == term,
              revision >= version.revision, let grants = payload.authorizedCredentialGrants,
              let token = payload.discordToken, !token.isEmpty else { return false }
        do {
            try await meshCredentialStore.replaceGrants(grants)
            settings.token = token
            settings.adminWebUI.discordOAuth.clientSecret = payload.discordOAuthClientSecret ?? ""
            for id in GameProviderID.allCases {
                settings.gameProviders.setToken(payload.gameProviderTokens[id.rawValue] ?? "", for: id)
            }
            for (id, url) in payload.automationWebhookURLs ?? [:] where !url.isEmpty {
                AutomationWebhookVault.store(url, id: id)
            }
            // Companion credentials and tunnel routes belong to their host Mac.
            try await store.save(settings)
            meshLastSuccessfulSync = Date()
            return true
        } catch {
            logs.append("SwiftMesh could not persist paired credentials: \(error.localizedDescription)")
            return false
        }
    }
}
