import Foundation

extension AppModel {
    /// The witness settings live in the Keychain; read them off the main
    /// thread so a Keychain prompt can't freeze the app during launch.
    nonisolated static func loadWitnessSettingsOffMain() async -> MeshWitnessConfiguration {
        await Task.detached(priority: .userInitiated) { MeshWitnessSettingsStore.load() }.value
    }

    /// Install recovery hooks before applying the configured placement. The
    /// coordinator, rather than saved preferences, owns the live output role.
    func configureMeshRecovery() async {
        do {
            let enrollment = try await meshCredentialStore.loadOrCreateLocalEnrollment()
            if settings.clusterMode == .leader {
                try await meshCredentialStore.authorize(enrollment: enrollment, nodeName: settings.clusterNodeName)
            }
            await cluster.setCredentialAuthorization(provider: { [weak self] id in
                await self?.meshCredentialStore.authorizedPublicKey(nodeID: id)
            }, localNodeID: enrollment.nodeID, localToken: enrollment.token)
            let witness = await Self.loadWitnessSettingsOffMain()
            await meshWitnessClient.configure(witness, nodeID: enrollment.nodeID, nodeName: settings.clusterNodeName)
            if witness.isConfigured && settings.clusterMode != .standalone {
                await cluster.setOwnershipHandlers(acquire: { [weak self] term in
                    guard let self else { return nil }
                    let grant = await self.meshWitnessClient.acquire(minimumTerm: term)
                    await self.updateMeshOwnershipDeadline(await self.meshWitnessClient.leaseDeadline() ?? ContinuousClock.now)
                    return grant
                }, renew: { [weak self] term in
                    guard let self else { return false }
                    let renewed = await self.meshWitnessClient.renew(term: term)
                    await self.updateMeshOwnershipDeadline(await self.meshWitnessClient.leaseDeadline() ?? ContinuousClock.now)
                    return renewed
                }, release: { [weak self] term in
                    guard let self else { return }
                    await self.service.setOutputAllowed(false)
                    await self.meshWitnessClient.release(term: term)
                })
            } else {
                await cluster.setOwnershipHandlers(acquire: nil, renew: nil, release: nil)
                await updateMeshOwnershipDeadline(nil)
            }
        } catch {
            if await Self.loadWitnessSettingsOffMain().isConfigured && settings.clusterMode != .standalone {
                await cluster.setOwnershipHandlers(acquire: { _ in nil }, renew: { _ in false }, release: { _ in })
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

    func meshCredentialsSnapshot() async -> MeshCredentialsResponse {
        let term = await cluster.currentLeaderTerm()
        _ = await store.exportMeshSyncedFiles(excludingFileNames: [], leaderTerm: term)
        let version = await store.meshSnapshotVersion()
        let grants = await meshCredentialStore.allGrants()
        return MeshCredentialsResponse(
            gameProviderTokens: Dictionary(uniqueKeysWithValues: GameProviderID.allCases.map { ($0.rawValue, settings.gameProviders.token(for: $0)) }),
            discordOAuthClientSecret: settings.adminWebUI.discordOAuth.clientSecret,
            discordToken: settings.token,
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
