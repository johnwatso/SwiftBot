import Foundation

/// Presence-driven play-session detection for Game Tracker.
///
/// Discord already sends `PRESENCE_UPDATE` for members of guilds the bot shares
/// — the `GUILD_PRESENCES` intent is part of the identify bitmask — so this adds
/// no new gateway cost. Sessions are inferred from the "Playing <game>" activity
/// and closed after a grace window so client restarts do not double-report.
extension AppModel {

    func handlePresenceUpdate(_ event: GatewayPresenceUpdateEvent) async {
        guard settings.gameTracking.sessionTrackingEnabled else { return }
        guard usesLocalRuntime else { return }
        let mode = runtimeClusterMode
        guard mode == .standalone || mode == .leader else { return }
        // Only members linked to a tracked profile are of interest.
        guard settings.gameTracking.player(forDiscordUserID: event.userID) != nil else { return }

        let now = Date()
        let started = gameSessionTracker.apply(event, now: now)
        for case let .started(session) in started {
            await recordSessionHistory(
                kind: .sessionStarted,
                title: "Session started",
                detail: "\(displayName(forDiscordUserID: session.userID)) started \(session.gameName).",
                at: now
            )
        }
        ensureGameSessionSweeper()
    }

    /// Periodically closes sessions whose grace window has elapsed. Presence
    /// stops arriving once someone quits, so an end can only be detected on a
    /// timer rather than from another event.
    func ensureGameSessionSweeper() {
        guard gameSessionSweeperTask == nil else { return }
        gameSessionSweeperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self else { return }
                let finished = await MainActor.run { self.gameSessionTracker.tick(now: Date()) }
                if finished.isEmpty {
                    let idle = await MainActor.run { self.gameSessionTracker.activeSessionCount == 0 }
                    if idle {
                        await MainActor.run { self.gameSessionSweeperTask = nil }
                        return
                    }
                    continue
                }
                for case let .ended(session) in finished {
                    await self.handleSessionEnded(session)
                }
            }
        }
    }

    func cancelGameSessionSweeper() {
        gameSessionSweeperTask?.cancel()
        gameSessionSweeperTask = nil
        gameSessionTracker.reset()
    }

    private func handleSessionEnded(_ session: GameSession) async {
        guard let player = settings.gameTracking.player(forDiscordUserID: session.userID) else { return }

        await recordSessionHistory(
            kind: .sessionEnded,
            title: "Session ended",
            detail: "\(player.resolvedDisplayName) played \(session.gameName) for \(GameSessionSummaryBuilder.durationText(session.duration)).",
            at: session.endedAt ?? Date()
        )

        // Give the game backend time to publish the final match before asking
        // the provider for it.
        let settle = max(0, settings.gameTracking.sessionSettleDelaySeconds)
        if settle > 0 {
            try? await Task.sleep(nanoseconds: UInt64(settle) * 1_000_000_000)
        }

        let totals = await sessionTotals(for: session, player: player)
        let providerName = totals == nil ? nil : player.provider.displayName

        let embed = GameSessionSummaryBuilder.embed(
            session: session,
            displayName: player.resolvedDisplayName,
            game: player.game,
            providerName: providerName,
            totals: totals
        )

        let sent = await sendPayload(
            channelId: player.destinationChannelID,
            payload: ["embeds": [embed]],
            action: "gameTrackerSessionSummary"
        )
        if sent {
            logs.append("[OK] Game Tracker session summary sent for \(player.resolvedDisplayName).")
        } else {
            logs.append("[ERR] Game Tracker could not deliver the session summary for \(player.resolvedDisplayName).")
        }
    }

    /// Pulls the session's matches from the provider when it can supply them.
    /// Returns `nil` for presence-only games, where the summary falls back to
    /// duration alone rather than inventing statistics.
    private func sessionTotals(
        for session: GameSession,
        player: GameTrackedPlayer
    ) async -> GameSessionSummaryBuilder.Totals? {
        guard let descriptor = GameProviderCatalog.descriptor(for: player.provider),
              descriptor.capabilities.contains(.latestSession) else { return nil }
        let connectionSettings = settings.gameProviders[player.provider]
        guard connectionSettings.configurationIssue(for: descriptor) == nil else { return nil }
        guard player.provider == .finalsID else { return nil }

        let connection = connectionSettings.connection(for: descriptor)
        do {
            let response = try await finalsIDLatestRoundClient.fetchLatestRound(
                endpointPath: "/v1/players/\(player.playerID)/rounds",
                connection: connection
            )
            return GameSessionSummaryBuilder.totals(for: session, rounds: response.results)
        } catch {
            logs.append("[WARN] Game Tracker could not load session rounds: \(error.localizedDescription)")
            return nil
        }
    }

    private func displayName(forDiscordUserID userID: String) -> String {
        settings.gameTracking.player(forDiscordUserID: userID)?.resolvedDisplayName ?? "A tracked player"
    }

    private func recordSessionHistory(
        kind: GameTrackingHistoryKind,
        title: String,
        detail: String,
        at timestamp: Date
    ) async {
        var state = await gameTrackingStateStore.load()
        state.record(GameTrackingHistoryEntry(
            timestamp: timestamp,
            kind: kind,
            title: title,
            detail: detail
        ))
        try? await gameTrackingStateStore.save(state)
        gameTrackingHistory = state.history
    }
}
