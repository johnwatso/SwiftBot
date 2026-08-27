import Foundation

struct GameTrackingMonitoringSnapshot: Equatable {
    let tracking: GameTrackingSettings
    let connections: GameProviderConnections
    let clusterMode: ClusterMode
    let botStatus: BotStatus
    let usesLocalRuntime: Bool
}

private struct GameAnnouncementGroupKey: Hashable {
    let channelID: String
    let game: GameID
    let provider: GameProviderID
}

extension AppModel {
    func configureGameTrackingMonitoring() {
        let snapshot = GameTrackingMonitoringSnapshot(
            tracking: settings.gameTracking,
            connections: settings.gameProviders,
            clusterMode: runtimeClusterMode,
            botStatus: status,
            usesLocalRuntime: usesLocalRuntime
        )
        guard snapshot != lastGameTrackingMonitoringSnapshot else { return }
        lastGameTrackingMonitoringSnapshot = snapshot

        gameTrackingMonitorTask?.cancel()
        gameTrackingMonitorTask = nil
        gameTrackingNextCheckAt = nil

        // Presence-driven sessions are configured independently of the daily
        // poll, so reset the sweeper whenever the tracking config changes.
        if !settings.gameTracking.sessionTrackingEnabled || !usesLocalRuntime {
            cancelGameSessionSweeper()
        }

        guard usesLocalRuntime else {
            gameTrackingStatusText = "Unavailable in Remote Control Mode"
            return
        }
        guard settings.gameTracking.enabled else {
            gameTrackingStatusText = "Not running"
            return
        }
        if let issue = settings.gameTracking.configurationIssue(connections: settings.gameProviders) {
            gameTrackingStatusText = issue
            logs.append("[INFO] Game Tracker paused: \(issue)")
            return
        }
        let mode = runtimeClusterMode
        guard mode == .standalone || mode == .leader else {
            gameTrackingStatusText = "Paused on this SwiftMesh node"
            logs.append("[INFO] Game Tracker paused on non-Primary runtime.")
            return
        }
        guard status == .running else {
            gameTrackingStatusText = "Waiting for SwiftBot to start"
            return
        }

        gameTrackingStatusText = "Scheduled"
        gameTrackingMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let state = await self.gameTrackingStateStore.load()
                self.publishGameTrackingState(state)
                let now = Date()
                let runAt = GameTrackingDailySchedule.nextRun(
                    after: now,
                    lastAttemptAt: state.lastAttemptAt,
                    hour: self.settings.gameTracking.checkHour,
                    minute: self.settings.gameTracking.checkMinute,
                    timeZoneIdentifier: self.settings.gameTracking.timeZoneIdentifier
                )
                self.gameTrackingNextCheckAt = runAt

                let delay = max(0, runAt.timeIntervalSinceNow)
                if delay > 0 {
                    let nanoseconds = UInt64(min(delay, 86_400 * 2) * 1_000_000_000)
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                await self.runGameTrackingCheck(trigger: "Scheduled")
            }
        }
        logs.append("[INFO] Game Tracker daily ranked-score monitoring scheduled.")
    }

    func runGameTrackingCheck(trigger: String = "Manual") async {
        guard !gameTrackingCheckInProgress else { return }
        guard usesLocalRuntime else {
            gameTrackingStatusText = "Unavailable in Remote Control Mode"
            return
        }
        guard settings.gameTracking.isReady(connections: settings.gameProviders) else {
            gameTrackingStatusText = settings.gameTracking.configurationIssue(connections: settings.gameProviders)
                ?? "Not configured"
            return
        }
        guard status == .running else {
            gameTrackingStatusText = "Start SwiftBot before checking"
            return
        }
        let mode = runtimeClusterMode
        guard mode == .standalone || mode == .leader else {
            gameTrackingStatusText = "Blocked on non-Primary node"
            return
        }

        gameTrackingCheckInProgress = true
        gameTrackingStatusText = "Checking…"
        defer { gameTrackingCheckInProgress = false }

        let checkedAt = Date()
        var runtimeState = await gameTrackingStateStore.load()
        runtimeState.lastAttemptAt = checkedAt
        try? await gameTrackingStateStore.save(runtimeState)

        var changedSnapshots: [(change: GameRankChange, baseline: GameRankBaseline)] = []
        var successfulFetches = 0
        var failures: [String] = []

        for target in settings.gameTracking.enabledPlayers {
            guard !Task.isCancelled else { return }
            do {
                let snapshot = try await fetchGameRankSnapshot(for: target)
                successfulFetches += 1
                let key = target.id.uuidString
                let baseline = GameRankBaseline(
                    snapshot: snapshot,
                    displayName: target.resolvedDisplayName,
                    recordedAt: checkedAt
                )
                let evaluation = GameRankEvaluator.evaluate(
                    target: target,
                    current: snapshot,
                    previous: runtimeState.baselinesByTargetID[key]
                )
                switch evaluation {
                case .establishBaseline:
                    runtimeState.baselinesByTargetID[key] = baseline
                    logs.append(
                        "[INFO] Game Tracker baseline established for \(target.resolvedDisplayName): \(snapshot.score) SR."
                    )
                case .unchanged:
                    runtimeState.baselinesByTargetID[key] = baseline
                case .seasonChanged:
                    runtimeState.baselinesByTargetID[key] = baseline
                    runtimeState.record(GameTrackingHistoryEntry(
                        timestamp: checkedAt,
                        kind: .seasonReset,
                        title: "Season baseline reset",
                        detail: "\(target.resolvedDisplayName) · \(target.game.displayName)"
                    ))
                    logs.append(
                        "[INFO] Game Tracker season changed for \(target.resolvedDisplayName); baseline reset without an announcement."
                    )
                case .changed(let change):
                    changedSnapshots.append((change, baseline))
                }
            } catch {
                failures.append("\(target.resolvedDisplayName): \(error.localizedDescription)")
            }
        }

        var sentAnnouncements = 0
        let groups = Dictionary(grouping: changedSnapshots) { entry in
            GameAnnouncementGroupKey(
                channelID: entry.change.destinationChannelID,
                game: entry.change.game,
                provider: entry.change.provider
            )
        }
        for (key, entries) in groups {
            let embed = GameTrackingNotificationBuilder.embed(
                changes: entries.map(\.change),
                checkedAt: checkedAt
            )
            let sent = await sendPayload(
                channelId: key.channelID,
                payload: ["embeds": [embed]],
                action: "gameTrackerRankUpdate"
            )
            if sent {
                sentAnnouncements += 1
                for entry in entries {
                    runtimeState.baselinesByTargetID[entry.change.targetID.uuidString] = entry.baseline
                }
                let summary = entries.map {
                    let sign = $0.change.delta > 0 ? "+" : ""
                    return "\($0.change.displayName) \(sign)\($0.change.delta)"
                }.joined(separator: ", ")
                runtimeState.record(GameTrackingHistoryEntry(
                    timestamp: checkedAt,
                    kind: .announcement,
                    title: "Rank update posted",
                    detail: "\(key.game.displayName) · \(summary)"
                ))
                logs.append("[OK] Game Tracker ranked update sent: \(summary).")
            } else {
                failures.append(
                    "Discord delivery failed for \(key.game.displayName); previous baselines were retained for retry."
                )
            }
        }

        if successfulFetches > 0 {
            runtimeState.lastSuccessfulCheckAt = checkedAt
            gameTrackingLastCheckAt = checkedAt
            if changedSnapshots.isEmpty {
                runtimeState.record(GameTrackingHistoryEntry(
                    timestamp: checkedAt,
                    kind: .check,
                    title: "Daily check complete",
                    detail: "No ranked-score changes across \(successfulFetches) profile\(successfulFetches == 1 ? "" : "s")."
                ))
            }
        }
        if !failures.isEmpty {
            runtimeState.record(GameTrackingHistoryEntry(
                timestamp: checkedAt,
                kind: .error,
                title: "Check completed with errors",
                detail: failures.joined(separator: " · ")
            ))
        }

        do {
            try await gameTrackingStateStore.save(runtimeState)
        } catch {
            failures.append("Could not persist Game Tracker baselines: \(error.localizedDescription)")
        }
        publishGameTrackingState(runtimeState)

        if failures.isEmpty {
            gameTrackingStatusText = sentAnnouncements == 0
                ? "Checked · no SR changes"
                : "Checked · update sent"
        } else {
            gameTrackingStatusText = "Check completed with errors"
            for failure in failures {
                logs.append("[ERR] Game Tracker \(trigger.lowercased()) check: \(failure)")
            }
        }
    }

    func upsertTrackedGamePlayer(_ player: GameTrackedPlayer) {
        var normalized = player
        normalized.normalize()
        var shouldClearBaseline = false
        if let index = settings.gameTracking.players.firstIndex(where: { $0.id == normalized.id }) {
            let existing = settings.gameTracking.players[index]
            shouldClearBaseline = existing.game != normalized.game
                || existing.provider != normalized.provider
                || existing.playerID != normalized.playerID
            settings.gameTracking.players[index] = normalized
        } else {
            settings.gameTracking.players.append(normalized)
        }
        gameTrackingSettingsDidChange()
        if shouldClearBaseline {
            clearGameTrackingBaseline(for: normalized.id)
        }
    }

    func setTrackedGamePlayerEnabled(_ playerID: UUID, enabled: Bool) {
        guard let index = settings.gameTracking.players.firstIndex(where: { $0.id == playerID }) else { return }
        settings.gameTracking.players[index].isEnabled = enabled
        gameTrackingSettingsDidChange()
    }

    func removeTrackedGamePlayer(_ playerID: UUID) {
        settings.gameTracking.players.removeAll { $0.id == playerID }
        gameTrackingSettingsDidChange()
        clearGameTrackingBaseline(for: playerID)
    }

    func loadGameTrackingStateForDisplay() async {
        let state = await gameTrackingStateStore.load()
        publishGameTrackingState(state)
    }

    func gameTrackingSettingsDidChange() {
        saveSettings()
        configureGameTrackingMonitoring()
        gameTrackingSettingsSaveTask?.cancel()
        gameTrackingSettingsSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.saveSettings()
        }
    }

    private func clearGameTrackingBaseline(for playerID: UUID) {
        gameTrackingBaselines[playerID] = nil
        Task {
            var state = await gameTrackingStateStore.load()
            state.baselinesByTargetID[playerID.uuidString] = nil
            try? await gameTrackingStateStore.save(state)
            publishGameTrackingState(state)
        }
    }

    private func fetchGameRankSnapshot(for target: GameTrackedPlayer) async throws -> GameRankSnapshot {
        guard let descriptor = GameProviderCatalog.descriptor(for: target.provider) else {
            throw GameProviderRegistryError.unsupportedProvider(target.provider)
        }
        let connection = settings.gameProviders[target.provider].connection(for: descriptor)
        return try await gameProviderRegistry.fetchRankSnapshot(for: target, connection: connection)
    }

    private func publishGameTrackingState(_ state: GameTrackingRuntimeState) {
        gameTrackingLastCheckAt = state.lastSuccessfulCheckAt
        gameTrackingHistory = state.history
        gameTrackingBaselines = Dictionary(uniqueKeysWithValues: state.baselinesByTargetID.compactMap { key, value in
            guard let id = UUID(uuidString: key) else { return nil }
            return (id, value)
        })
    }
}
