import AVFoundation
import Foundation
import libdave_swift

/// Voice tab integration: owns `VoicePlaybackService`, `VoiceAnnouncementService`,
/// and `TextChannelAnnouncer`; coordinates the two main-gateway events
/// (`VOICE_STATE_UPDATE` for our own user, `VOICE_SERVER_UPDATE` for the guild)
/// into a `VoiceServerInfo` and drives the voice WS / UDP / Opus pipeline.
@MainActor
extension AppModel {
    /// Lazily-constructed playback orchestrator. Created on first access so
    /// startup cost (Opus encoder, audio format) is paid only when the
    /// Voice tab actually does something.
    var voicePlaybackService: VoicePlaybackService {
        if let existing = voicePlaybackServiceStorage {
            return existing
        }
        let service = VoicePlaybackService()
        voicePlaybackServiceStorage = service
        Task { [weak self] in
            await service.setOnStatusChange { [weak self] status in
                await self?.handleVoicePlaybackStatus(status)
            }
            await service.setOnDebug { [weak self] message in
                await MainActor.run {
                    self?.addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: message))
                }
            }
        }
        return service
    }

    var voiceAnnouncementService: VoiceAnnouncementService? {
        if let existing = voiceAnnouncementServiceStorage {
            return existing
        }
        do {
            let announcer = try VoiceAnnouncementService(playback: voicePlaybackService)
            voiceAnnouncementServiceStorage = announcer
            applyPreferredVoiceFromSettings(to: announcer)
            Task { [weak self] in
                await announcer.setOnDebug { [weak self] message in
                    await MainActor.run {
                        self?.addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: message))
                    }
                }
                await announcer.setOnHealthChange { [weak self] health in
                    await MainActor.run {
                        self?.announcerHealth = health
                    }
                }
            }
            return announcer
        } catch {
            voiceLog.append(VoiceEventLogEntry(
                time: Date(),
                description: "Voice announcer init failed: \(error.localizedDescription)"
            ))
            return nil
        }
    }

    var textChannelAnnouncer: TextChannelAnnouncer? {
        if let existing = textChannelAnnouncerStorage {
            return existing
        }
        guard let announcer = voiceAnnouncementService else { return nil }
        let watcher = TextChannelAnnouncer(announcer: announcer)
        var channelIDs = settings.voice.watchedTextChannelID.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !settings.voice.voiceChannelID.isEmpty {
            channelIDs.append(settings.voice.voiceChannelID)
        }
        if !channelIDs.isEmpty {
            Task {
                await watcher.setWatchedChannels(channelIDs)
            }
        }
        textChannelAnnouncerStorage = watcher
        return watcher
    }

    // MARK: - Public API used by Voice tab + slash commands

    func getDaveDiagnostics() async -> DaveDiagnostics? {
        await voicePlaybackService.getDaveDiagnostics()
    }

    func setVoiceGuildForAnnouncer(_ guildID: String) {
        settings.voice.guildID = guildID
        if settings.voice.voiceChannelID.isEmpty == false {
            settings.voice.voiceChannelID = ""
        }
        if settings.voice.watchedTextChannelID.isEmpty == false {
            settings.voice.watchedTextChannelID = ""
        }
        persistSettingsIfPossible()
    }

    func setVoiceChannelForAnnouncer(_ channelID: String) {
        settings.voice.voiceChannelID = channelID
        persistSettingsIfPossible()
    }

    func setTextChannelSourceEnabledForAnnouncer(_ enabled: Bool) {
        settings.voice.textChannelSourceEnabled = enabled
        persistSettingsIfPossible()
    }

    /// Connect the bot to the voice channel configured in `settings.voice`.
    func connectVoice() async {
        let guildID = settings.voice.guildID
        let channelID = settings.voice.voiceChannelID
        guard !guildID.isEmpty, !channelID.isEmpty else {
            voiceConnectionStatus = .idle
            deactivateAnnouncerSession()
            return
        }
        await connectVoice(guildID: guildID, channelID: channelID)
    }

    func connectVoice(guildID: String, channelID: String, recovering: Bool = false) async {
        if !recovering {
            cancelVoiceRecovery()
            voiceRecoveryAttemptUsed = false
        }
        // The main gateway has to be live before voice can negotiate.
        guard status == .running else {
            voiceConnectionStatus = .failed("Bot is offline — click Start Bot first.")
            deactivateAnnouncerSession()
            return
        }
        if voiceConnectionStatus == .connected,
           voicePendingGuildID == guildID,
           voicePendingChannelID == channelID {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice join skipped; already connected to channel \(channelID)."
            ))
            return
        }
        if voiceConnectionStatus == .connecting,
           voicePendingGuildID == guildID,
           voicePendingChannelID == channelID {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice join skipped; already connecting to channel \(channelID)."
            ))
            return
        }
        voicePendingGuildID = guildID
        voicePendingChannelID = channelID
        voicePendingSessionID = nil
        voicePendingServerToken = nil
        voicePendingServerEndpoint = nil
        voiceCredentialsSessionID = nil
        voiceConnectionStatus = recovering
            ? .recovering("Rejoining voice channel…")
            : .connecting
        let action = recovering ? "Voice rejoin requested" : "Voice join requested"
        addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: "\(action) for channel \(channelID)."))

        if let preflightFailure = await voiceChannelPreflightFailure(channelID: channelID) {
            voiceConnectionStatus = .failed(preflightFailure)
            finishVoiceRecoveryIfNeeded(success: false)
            deactivateAnnouncerSession()
            addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: preflightFailure))
            return
        }

        let didSendJoin = await service.sendVoiceStateUpdate(guildID: guildID, channelID: channelID)
        guard didSendJoin else {
            let message = "Voice join failed before Discord acknowledged it: main gateway send was blocked or disconnected."
            voiceConnectionStatus = .failed(message)
            finishVoiceRecoveryIfNeeded(success: false)
            deactivateAnnouncerSession()
            addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: message))
            return
        }
        addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: "Voice state update sent on main Discord gateway."))

        // Defensive timeout: if VOICE_STATE_UPDATE + VOICE_SERVER_UPDATE
        // don't both arrive within 10s, surface a clear error instead of
        // sitting in "connecting" forever.
        let attemptGuildID = guildID
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self else { return }
            await MainActor.run {
                let isMissingVoiceHandshakeData = self.voicePendingSessionID == nil ||
                    self.voicePendingServerToken == nil ||
                    self.voicePendingServerEndpoint == nil
                if self.voiceConnectionStatus.isWaitingForConnectionData,
                   self.voicePendingGuildID == attemptGuildID,
                   isMissingVoiceHandshakeData {
                    let message = "Timed out waiting for Discord voice state and voice server updates."
                    self.voiceConnectionStatus = .failed(message)
                    self.finishVoiceRecoveryIfNeeded(success: false)
                    self.deactivateAnnouncerSession()
                    self.addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: message))
                }
            }
        }
    }

    /// Tear down the voice connection (sends VOICE_STATE_UPDATE with null
    /// channel, then closes the playback pipeline).
    func disconnectVoice(preserveAnnouncerSession: Bool = false) async {
        if !preserveAnnouncerSession {
            cancelVoiceRecovery()
            if let announcer = voiceAnnouncementServiceStorage {
                await announcer.setPaused(true)
                await announcer.clearPending()
            }
        }
        let guildID = voicePendingGuildID ?? settings.voice.guildID
        if !guildID.isEmpty {
            _ = await service.sendVoiceStateUpdate(guildID: guildID, channelID: nil)
        }
        await voicePlaybackService.disconnect()
        voicePendingGuildID = nil
        voicePendingChannelID = nil
        voicePendingSessionID = nil
        voicePendingServerToken = nil
        voicePendingServerEndpoint = nil
        voiceCredentialsSessionID = nil
        if preserveAnnouncerSession {
            voiceConnectionStatus = .recovering("Preparing a clean rejoin…")
        } else {
            voiceConnectionStatus = .idle
            deactivateAnnouncerSession()
        }
    }

    /// Manually trigger an announcement (e.g. `/say` or the Test button in the
    /// Voice tab).
    func speakAnnouncement(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard voiceConnectionStatus.isConnected else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Discord speech skipped because voice is not connected."
            ))
            return
        }
        guard let announcer = voiceAnnouncementService else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Discord speech skipped because the voice announcer is unavailable."
            ))
            return
        }
        incrementSpokenToday()
        await announcer.enqueue(trimmed)
    }

    /// Speak `text` through the Mac's local speakers using
    /// `AVSpeechSynthesizer` — no Discord voice connection involved. Used as
    /// a preview while the Discord voice path is blocked by DAVE.
    func speakLocallyPreview(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        incrementSpokenToday()
        
        let preferredIdentifier = settings.voice.preferredVoiceIdentifier
        
        // AVSpeechSynthesizer must be created and driven on the MainActor.
        // Driving it from a background thread/actor triggers "unsafeForcedSync
        // called from Swift Concurrent context" faults in AXCoreUtilities and
        // crashes — same constraint as VoiceTTSSource.render(). We deliberately
        // stay on the MainActor: speak() is non-blocking (it enqueues and
        // returns), so it does not stall the UI, and the benign "priority
        // inversion" log AVSpeechSynthesizer emits internally is the price of
        // crash safety. Do NOT move this onto a background queue.
        Task { @MainActor [localSpeechPreviewSynthesizer] in
            let resolvedVoice: AVSpeechSynthesisVoice?
            if !preferredIdentifier.isEmpty,
               let v = AVSpeechSynthesisVoice(identifier: preferredIdentifier) {
                resolvedVoice = v
            } else {
                resolvedVoice = VoiceTTSSource.preferredEnglishVoice()
            }

            let utterance = AVSpeechUtterance(string: trimmed)
            utterance.voice = resolvedVoice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0
            
            if localSpeechPreviewSynthesizer.isSpeaking {
                localSpeechPreviewSynthesizer.stopSpeaking(at: .immediate)
            }
            localSpeechPreviewSynthesizer.speak(utterance)
        }
    }

    /// Apply a new watched text-channel selection from the UI.
    func setWatchedTextChannelForAnnouncer(_ channelID: String) async {
        settings.voice.watchedTextChannelID = channelID
        persistSettingsIfPossible()
        if let watcher = textChannelAnnouncer {
            var channelIDs = channelID.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !settings.voice.voiceChannelID.isEmpty {
                channelIDs.append(settings.voice.voiceChannelID)
            }
            await watcher.setWatchedChannels(channelIDs)
        }
    }

    /// Apply a new preferred-voice selection from the UI.
    func setPreferredAnnouncerVoice(_ identifier: String) async {
        settings.voice.preferredVoiceIdentifier = identifier
        if forwardsConfigEditsToPrimary {
            // Failover: the Primary owns the announcer config; forward the
            // section (no local engine to apply to here).
            forwardConfigMutationToPrimary(.replaceVoice(settings.voice), revertOnFailure: true)
            return
        }
        persistSettingsIfPossible()
        if let announcer = voiceAnnouncementService {
            applyPreferredVoiceFromSettings(to: announcer)
        }
    }

    func reconnectAnnouncerVoiceFromUI() async {
        let guildID = settings.voice.guildID
        let channelID = settings.voice.voiceChannelID
        guard status == .running else {
            voiceConnectionStatus = .failed("Bot is offline — click Start Bot first.")
            return
        }
        guard !guildID.isEmpty, !channelID.isEmpty else {
            voiceConnectionStatus = .failed("Announcer voice channel is not configured.")
            return
        }

        if let announcer = voiceAnnouncementServiceStorage {
            await announcer.markRecovering("manual voice reconnect")
        }
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Manual Announcer voice reconnect requested."
        ))
        await disconnectVoice(preserveAnnouncerSession: true)
        try? await Task.sleep(for: .milliseconds(750))
        await connectVoice(guildID: guildID, channelID: channelID, recovering: true)
    }

    func handleAnnounceJoinSlash(raw: [String: DiscordJSON]) async -> (ok: Bool, message: String) {
        await connectAnnouncerFromSlash(raw: raw, rejoin: false)
    }

    /// `/announce rejoin` — force a clean disconnect and reconnect to the
    /// caller's configured Announcer voice channel. Useful when the voice
    /// connection is degraded or stuck: a plain `join` short-circuits in
    /// `connectVoice` when the bot already believes it is connected, whereas
    /// `rejoin` tears the session down first so the reconnect always runs.
    func handleAnnounceRejoinSlash(raw: [String: DiscordJSON]) async -> (ok: Bool, message: String) {
        await connectAnnouncerFromSlash(raw: raw, rejoin: true)
    }

    /// Shared implementation for `/announce join` and `/announce rejoin`.
    private func connectAnnouncerFromSlash(raw: [String: DiscordJSON], rejoin: Bool) async -> (ok: Bool, message: String) {
        let verb = rejoin ? "rejoin" : "join"
        guard let guildID = guildId(from: raw), !guildID.isEmpty else {
            return (false, "Use `/announce \(verb)` in a server channel.")
        }
        guard let userID = authorId(from: raw), !userID.isEmpty else {
            return (false, "I couldn't identify who ran `/announce \(verb)`.")
        }

        let configuredChannels = settings.voice.announcerConfigs.filter {
            $0.enabled && !$0.voiceChannelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !configuredChannels.isEmpty else {
            return (false, "Announcer is not set up yet. Add an enabled voice channel configuration in SwiftBot first.")
        }

        guard let presence = activeVoice.first(where: { $0.guildId == guildID && $0.userId == userID }) else {
            return (false, "Join a configured voice channel first, then run `/announce \(verb)` again.")
        }
        guard let config = configuredChannels.first(where: { $0.voiceChannelID == presence.channelId }) else {
            return (false, "No enabled Announcer configuration matches your current voice channel.")
        }

        // For rejoin, tear down any existing session first so the connect below
        // isn't skipped by connectVoice's "already connected/connecting" guard.
        // The short pause lets Discord register the leave before the new join,
        // avoiding a re-join being ignored as a duplicate voice state.
        if rejoin {
            await disconnectVoice()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        guard await activateAnnouncerConfig(config, guildID: guildID) else {
            return (false, "The Announcer configuration for \(config.voiceChannelName) needs at least one readable text channel.")
        }

        await connectVoice(guildID: guildID, channelID: config.voiceChannelID)
        if case let .failed(reason) = voiceConnectionStatus {
            return (false, reason)
        }
        if config.introduceOnManualJoin {
            scheduleVoiceJoinIntro(channelID: config.voiceChannelID)
        }
        let lead = rejoin ? "Reconnecting to" : "Joining"
        return (true, "\(lead) \(config.voiceChannelName) and reading the configured text feed.")
    }

    /// Forward a `MESSAGE_CREATE` event to the text-channel announcer. Called
    /// from `handleMessageCreate` so we don't have to re-subscribe to the
    /// dispatcher.
    func forwardMessageToVoiceAnnouncer(_ event: GatewayMessageCreateEvent) async {
        guard voiceConnectionStatus.canQueueAnnouncements else { return }
        guard settings.voice.textChannelSourceEnabled else { return }
        let watchedIDs = settings.voice.watchedTextChannelID.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let activeVoiceChannelID = settings.voice.voiceChannelID
        let activeConfig = settings.voice.announcerConfigs
            .first(where: { !activeVoiceChannelID.isEmpty && $0.voiceChannelID == activeVoiceChannelID })
        // The voice channel's own chat (Text-in-Voice / stream chat) is only read
        // when the active config opts in. Defaults to true for the manual path.
        let readsVoiceChat = activeConfig?.readVoiceChannelChat ?? true
        let isVoiceChannelChat = readsVoiceChat && !activeVoiceChannelID.isEmpty && event.channelID == activeVoiceChannelID
        guard watchedIDs.contains(event.channelID) || isVoiceChannelChat else { return }
        // Don't read SwiftBot's own messages to avoid feedback loops.
        if let botUserId, event.userID == botUserId { return }
        // Optionally skip webhook posts (integrations, bridges, bots that post
        // via webhooks) so only real server members are read aloud.
        if activeConfig?.ignoreWebhooks == true, event.rawMap["webhook_id"] != nil { return }
        // Optionally skip bot-authored messages.
        if activeConfig?.skipBots == true, event.isBot { return }
        guard let watcher = textChannelAnnouncer else { return }
        let options = AnnouncerReadOptions(
            ignoreLinks: activeConfig?.ignoreLinks ?? true,
            summariseLong: activeConfig?.summariseLong ?? false,
            keepShort: activeConfig?.keepShort ?? false,
            ignoreEmojiSpam: activeConfig?.ignoreEmojiSpam ?? false
        )
        let cachedDisplayName = await discordCache.userName(for: event.userID)
        await watcher.handle(
            event,
            displayNameOverride: cachedDisplayName,
            channelNames: flattenedChannelNames(),
            roleNames: flattenedRoleNames(),
            options: options
        )
    }

    // MARK: - Gateway event handlers

    func handleVoiceServerUpdate(_ event: GatewayVoiceServerUpdateEvent) async {
        guard event.guildID == voicePendingGuildID else {
            if voicePendingGuildID != nil {
                addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Ignored voice server update for guild \(event.guildID); waiting for \(voicePendingGuildID ?? "?")."
                ))
            }
            return
        }
        guard let endpoint = event.endpoint, !endpoint.isEmpty else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice server update received without an endpoint; Discord has not allocated a voice server yet."
            ))
            return
        }
        voicePendingServerToken = event.token
        voicePendingServerEndpoint = endpoint
        // Tag these credentials with the session current at receipt so a connect
        // never fires with a token paired to a stale session id.
        voiceCredentialsSessionID = voicePendingSessionID
        addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: "Voice server update received; endpoint ready."))
        await beginVoicePipelineIfReady()
    }

    /// Hook called from `handleVoiceStateUpdate` (in AppModel+DiscordEvents)
    /// when a VOICE_STATE_UPDATE for our own bot user lands.
    func observeSelfVoiceStateUpdate(_ event: GatewayVoiceStateUpdateEvent) async {
        let expectedBotUserId = botUserId ?? {
            let cached = settings.cachedBotIdentity.userId.trimmingCharacters(in: .whitespacesAndNewlines)
            return cached.isEmpty ? nil : cached
        }()
        guard event.guildID == voicePendingGuildID else {
            if voicePendingGuildID != nil {
                addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Ignored voice state update for guild \(event.guildID); waiting for \(voicePendingGuildID ?? "?")."
                ))
            }
            return
        }
        guard let expectedBotUserId, event.userID == expectedBotUserId else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Observed voice state update for user \(event.userID); waiting for bot user \(expectedBotUserId ?? "unknown")."
            ))
            return
        }
        if case let .string(sessionID)? = event.rawMap["session_id"] {
            if voicePendingSessionID != sessionID {
                // New session: any server token/endpoint we hold predate it and
                // would be rejected with close code 4006, so discard them.
                voicePendingServerToken = nil
                voicePendingServerEndpoint = nil
                voiceCredentialsSessionID = nil
            }
            voicePendingSessionID = sessionID
            addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: "Voice state update received; session id ready."))
            await beginVoicePipelineIfReady()
        } else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice state update for bot arrived without a session id."
            ))
        }
    }

    // MARK: - Private orchestration

    private func beginVoicePipelineIfReady() async {
        guard let guildID = voicePendingGuildID,
              let sessionID = voicePendingSessionID,
              let token = voicePendingServerToken,
              let endpoint = voicePendingServerEndpoint,
              let userID = botUserId else {
            return
        }
        // Only connect when the stored credentials were received under the
        // current session. Guards against an interleaved server/state update
        // pairing a token with a stale session id and tripping close code 4006.
        guard voiceCredentialsSessionID == sessionID else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Holding voice connect: server credentials are from a previous session; awaiting a refreshed voice server update."
            ))
            return
        }
        let info = VoiceServerInfo(
            guildID: guildID,
            userID: userID,
            sessionID: sessionID,
            token: token,
            endpoint: endpoint
        )
        addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: "Voice websocket pipeline starting."))
        do {
            try await voicePlaybackService.connect(server: info)
            voiceConnectionStatus = .connected
            finishVoiceRecoveryIfNeeded(success: true)
            if let announcer = voiceAnnouncementServiceStorage {
                await announcer.setPaused(false)
            }
            startAnnouncerHealthWatchdog()
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice pipeline connected to channel \(voicePendingChannelID ?? "?")"
            ))
        } catch {
            voiceConnectionStatus = .failed(error.localizedDescription)
            finishVoiceRecoveryIfNeeded(success: false)
            deactivateAnnouncerSession()
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice pipeline connect failed: \(error.localizedDescription)"
            ))
        }
    }

    private func handleVoicePlaybackStatus(_ status: VoicePlaybackService.Status) async {
        switch status {
        case .idle:
            if voiceRecoveryInProgress {
                voiceConnectionStatus = .recovering("Preparing a clean rejoin…")
                return
            }
            voiceConnectionStatus = .idle
            deactivateAnnouncerSession()
        case .connecting:
            if !voiceRecoveryInProgress {
                voiceConnectionStatus = .connecting
            }
        case .connected:
            voiceConnectionStatus = .connected
            finishVoiceRecoveryIfNeeded(success: true)
            if let announcer = voiceAnnouncementServiceStorage {
                await announcer.setPaused(false)
            }
            startAnnouncerHealthWatchdog()
        case .disconnecting:
            if voiceRecoveryInProgress {
                voiceConnectionStatus = .recovering("Preparing a clean rejoin…")
            } else {
                voiceConnectionStatus = .disconnecting
            }
        case .failed(let reason):
            // Surface unexpected drops (e.g. a voice gateway WS close after we
            // were connected) in the activity log. Without this the announcer
            // silently stops reading — messages are dropped by the
            // `isConnected` guard in forwardMessageToVoiceAnnouncer with no
            // trace — while the bot may still appear present in Discord.
            let wasConnected = voiceConnectionStatus.isConnected
            if wasConnected, scheduleVoiceAutoRecovery(reason: reason) {
                return
            }
            voiceConnectionStatus = .failed(reason)
            if wasConnected {
                addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Voice connection lost (\(reason)). Announcer paused."
                ))
            }
            finishVoiceRecoveryIfNeeded(success: false)
            deactivateAnnouncerSession()
        }
    }

    private func scheduleVoiceAutoRecovery(reason: String) -> Bool {
        guard !voiceRecoveryAttemptUsed, !voiceRecoveryInProgress else { return false }
        let guildID = voicePendingGuildID ?? settings.voice.guildID
        let channelID = voicePendingChannelID ?? settings.voice.voiceChannelID
        guard status == .running, !guildID.isEmpty, !channelID.isEmpty else { return false }

        voiceRecoveryAttemptUsed = true
        voiceRecoveryInProgress = true
        voiceConnectionStatus = .recovering("Rejoining after voice drop…")
        if let announcer = voiceAnnouncementServiceStorage {
            Task { await announcer.markRecovering(reason) }
        }
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Voice connection lost (\(reason)). Announcer is auto-rejoining and queued reads are paused."
        ))

        voiceRecoveryTask?.cancel()
        voiceRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.performVoiceAutoRecovery(guildID: guildID, channelID: channelID, reason: reason)
        }
        return true
    }

    private func performVoiceAutoRecovery(guildID: String, channelID: String, reason: String) async {
        guard voiceRecoveryInProgress else { return }
        guard status == .running else {
            let message = "Voice auto-rejoin stopped because the bot is offline."
            voiceConnectionStatus = .failed(message)
            finishVoiceRecoveryIfNeeded(success: false)
            deactivateAnnouncerSession()
            addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: message))
            return
        }

        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Voice auto-rejoin starting after \(reason)."
        ))
        await disconnectVoice(preserveAnnouncerSession: true)
        guard voiceRecoveryInProgress else { return }
        try? await Task.sleep(for: .milliseconds(750))
        guard voiceRecoveryInProgress else { return }
        await connectVoice(guildID: guildID, channelID: channelID, recovering: true)
        voiceRecoveryTask = nil
    }

    private func finishVoiceRecoveryIfNeeded(success: Bool) {
        guard voiceRecoveryInProgress else { return }
        voiceRecoveryInProgress = false
        voiceRecoveryTask = nil
        if success {
            voiceRecoveryAttemptUsed = false
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice auto-rejoin succeeded; queued reads are resuming."
            ))
        } else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice auto-rejoin failed; announcer session was stopped."
            ))
        }
    }

    private func cancelVoiceRecovery() {
        voiceRecoveryTask?.cancel()
        voiceRecoveryTask = nil
        voiceRecoveryInProgress = false
    }

    private func startAnnouncerHealthWatchdog() {
        announcerHealthWatchdogTask?.cancel()
        announcerHealthWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self?.evaluateAnnouncerHealthWatchdog()
            }
        }
    }

    private func stopAnnouncerHealthWatchdog() {
        announcerHealthWatchdogTask?.cancel()
        announcerHealthWatchdogTask = nil
    }

    private func evaluateAnnouncerHealthWatchdog() async {
        guard voiceConnectionStatus.isConnected else { return }
        guard announcerHealth.isStalled(threshold: 60) else { return }
        guard let announcer = voiceAnnouncementServiceStorage else { return }

        let reason = "announcer health watchdog: \(announcerHealth.phase.displayLabel.lowercased()) for too long"
        await announcer.markRecovering(reason)
        _ = scheduleVoiceAutoRecovery(reason: reason)
    }

    private func applyPreferredVoiceFromSettings(to announcer: VoiceAnnouncementService) {
        applyPreferredVoice(identifier: settings.voice.preferredVoiceIdentifier, to: announcer)
    }

    /// Resolve `identifier` (empty → best English voice) and apply it to the
    /// announcer.
    private func applyPreferredVoice(identifier: String, to announcer: VoiceAnnouncementService) {
        let voice: AVSpeechSynthesisVoice?
        if identifier.isEmpty {
            voice = VoiceTTSSource.preferredEnglishVoice()
        } else {
            voice = AVSpeechSynthesisVoice(identifier: identifier) ?? VoiceTTSSource.preferredEnglishVoice()
        }
        Task { await announcer.setVoice(voice) }
    }

    private func persistSettingsIfPossible() {
        saveSettings()
    }

    private func firstReadableTextChannelID(for config: AnnouncerVoiceChannelConfig, guildID: String) -> String? {
        let selectedNames = config.textChannels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !selectedNames.isEmpty else { return nil }

        let textChannels = availableTextChannelsByServer[guildID] ?? []
        for selectedName in selectedNames {
            if let match = textChannels.first(where: { $0.id == selectedName || $0.name == selectedName }) {
                return match.id
            }
        }
        return nil
    }

    private func resolvedTextChannelIDs(for config: AnnouncerVoiceChannelConfig, guildID: String) -> [String] {
        let selectedNames = config.textChannels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !selectedNames.isEmpty else { return [] }

        let textChannels = availableTextChannelsByServer[guildID] ?? []
        var resolved: [String] = []
        for selectedName in selectedNames {
            if let match = textChannels.first(where: { $0.id == selectedName || $0.name == selectedName }) {
                resolved.append(match.id)
            }
        }
        return resolved
    }

    private func voiceChannelPreflightFailure(channelID: String) async -> String? {
        let token = normalizedDiscordToken(from: settings.token)
        guard !token.isEmpty else {
            return "Voice join failed: bot token is missing."
        }

        do {
            let channel = try await service.fetchChannel(channelId: channelID, token: token)
            if let type = discordIntValue(for: "type", in: channel), type != 2, type != 13 {
                return "Voice join failed: selected channel is not a Discord voice channel."
            }
            return nil
        } catch {
            let nsError = error as NSError
            if nsError.code == 403 {
                return "Voice join failed: SwiftBot cannot access this voice channel. Give the bot View Channel and Connect permissions, then retry."
            }
            if nsError.code == 404 {
                return "Voice join failed: Discord could not find the selected voice channel."
            }
            return "Voice join failed: channel preflight check failed (\(error.localizedDescription))."
        }
    }

    // MARK: - Auto-join / auto-disconnect

    /// Called from the gateway whenever a member joins a voice channel.
    /// Checks whether any enabled config with `autoJoin == true` matches the
    /// channel and, if so, connects and arms the relevant disconnect strategy.
    func handleAutoJoin(channelId: String, guildId: String, triggeringUserId: String) async {
        // Never auto-join because of the bot's own presence update
        guard triggeringUserId != botUserId else { return }
        // Only act when the bot is online but not already in a voice channel
        guard status == .running, !voiceConnectionStatus.isConnected else { return }

        guard let config = settings.voice.announcerConfigs.first(where: {
            $0.autoJoin && $0.voiceChannelID == channelId && $0.enabled
        }) else { return }

        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Auto-join triggered for \"\(config.name)\" — member joined \(config.voiceChannelName)."
        ))
        guard await activateAnnouncerConfig(config, guildID: guildId) else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Auto-join skipped for \"\(config.name)\" because no readable text channel is configured."
            ))
            return
        }
        await connectVoice(guildID: guildId, channelID: channelId)
        scheduleVoiceJoinIntro(channelID: channelId)

        // Arm disconnect strategy
        autoDisconnectTask?.cancel()
        if config.connectionMode == .fixed {
            let minutes = config.connectionMinutes
            autoDisconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled else { return }
                await self?.autoDisconnect(reason: "Fixed duration (\(minutes) min) elapsed for \"\(config.name)\".")
            }
        }
        // .untilEmpty is handled in handleUntilEmptyCheck below
    }

    /// Inspect a VOICE_STATE_UPDATE for a Go Live stream start/stop and fire the
    /// stream auto-join rule on the false→true edge.
    func detectStreamTransition(map: [String: DiscordJSON], guildId: String, userId: String, channelId: String?) async {
        let key = "\(guildId)-\(userId)"
        let isStreaming: Bool
        if case .bool(let value)? = map["self_stream"] {
            isStreaming = value
        } else {
            isStreaming = false
        }
        let wasStreaming = streamingMemberKeys.contains(key)

        if isStreaming, !wasStreaming {
            streamingMemberKeys.insert(key)
            if let channelId {
                await handleStreamStart(channelId: channelId, guildId: guildId, triggeringUserId: userId)
            }
        } else if !isStreaming, wasStreaming {
            streamingMemberKeys.remove(key)
        }
    }

    /// Called when a member starts a Go Live stream. Mirrors `handleAutoJoin`
    /// but is gated on `autoJoinOnStream` and uses a stream-specific intro.
    func handleStreamStart(channelId: String, guildId: String, triggeringUserId: String) async {
        // Never react to the bot's own state.
        guard triggeringUserId != botUserId else { return }
        // Only act when the bot is online but not already in a voice channel.
        guard status == .running, !voiceConnectionStatus.isConnected else { return }

        guard let config = settings.voice.announcerConfigs.first(where: {
            $0.autoJoinOnStream && $0.voiceChannelID == channelId && $0.enabled
        }) else { return }

        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Stream auto-join triggered for \"\(config.name)\" — member started streaming in \(config.voiceChannelName)."
        ))
        guard await activateAnnouncerConfig(config, guildID: guildId) else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Stream auto-join skipped for \"\(config.name)\" because no readable text channel is configured."
            ))
            return
        }
        await connectVoice(guildID: guildId, channelID: channelId)
        if config.introduceOnStreamJoin {
            scheduleVoiceJoinIntro(channelID: channelId, text: randomStreamIntro())
        }

        // Arm disconnect strategy (same options as a regular auto-join).
        autoDisconnectTask?.cancel()
        if config.connectionMode == .fixed {
            let minutes = config.connectionMinutes
            autoDisconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled else { return }
                await self?.autoDisconnect(reason: "Fixed duration (\(minutes) min) elapsed for \"\(config.name)\".")
            }
        }
        // .untilEmpty is handled in handleUntilEmptyCheck.
    }

    private func randomStreamIntro() -> String {
        [
            "SwiftBot here. I'll read notifications during the stream.",
            "Stream's live — I'll read announcements while it runs.",
            "I'll read notifications during the stream.",
            "SwiftBot online. I'll read the chat during the stream."
        ].randomElement() ?? "I'll read notifications during the stream."
    }

    private func activateAnnouncerConfig(_ config: AnnouncerVoiceChannelConfig, guildID: String) async -> Bool {
        let channelIDs = resolvedTextChannelIDs(for: config, guildID: guildID)
        // A config is usable if it has at least one readable text channel, or it
        // reads the voice channel's own chat (so a stream-join can run with no
        // separate text channel configured).
        guard !channelIDs.isEmpty || config.readVoiceChannelChat else {
            return false
        }

        let commaSeparatedIDs = channelIDs.joined(separator: ",")

        settings.voice.guildID = guildID
        settings.voice.voiceChannelID = config.voiceChannelID
        settings.voice.watchedTextChannelID = commaSeparatedIDs
        settings.voice.textChannelSourceEnabled = true
        persistSettingsIfPossible()
        if let watcher = textChannelAnnouncer {
            var allWatchedIDs = channelIDs
            if config.readVoiceChannelChat, !config.voiceChannelID.isEmpty {
                allWatchedIDs.append(config.voiceChannelID)
            }
            await watcher.setWatchedChannels(allWatchedIDs)
        }

        // Apply this rule's preferred voice (empty falls back to the global
        // setting, then the best English voice).
        if let announcer = voiceAnnouncementService {
            let identifier = config.preferredVoiceIdentifier.isEmpty
                ? settings.voice.preferredVoiceIdentifier
                : config.preferredVoiceIdentifier
            applyPreferredVoice(identifier: identifier, to: announcer)
        }

        let readableNames = channelIDs.map { id in
            for channels in availableTextChannelsByServer.values {
                if let match = channels.first(where: { $0.id == id }) {
                    return match.name
                }
            }
            return id
        }.joined(separator: ", #")

        let sourceSummary: String
        if channelIDs.isEmpty {
            sourceSummary = "the voice channel chat"
        } else if config.readVoiceChannelChat {
            sourceSummary = "text channels #\(readableNames) and the voice channel chat"
        } else {
            sourceSummary = "text channels #\(readableNames)"
        }
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Announcer reading \(sourceSummary) for \"\(config.name)\"."
        ))
        return true
    }

    private func deactivateAnnouncerSession() {
        stopAnnouncerHealthWatchdog()
        if let announcer = voiceAnnouncementServiceStorage {
            Task {
                await announcer.setPaused(true)
                await announcer.clearPending()
            }
        }
        var changed = false
        if settings.voice.textChannelSourceEnabled {
            settings.voice.textChannelSourceEnabled = false
            changed = true
        }
        if !settings.voice.watchedTextChannelID.isEmpty {
            settings.voice.watchedTextChannelID = ""
            changed = true
        }
        if changed {
            persistSettingsIfPossible()
        }
        if let watcher = textChannelAnnouncerStorage {
            Task { await watcher.setWatchedChannel(nil) }
        }
    }

    private func scheduleVoiceJoinIntro(channelID: String, text: String? = nil) {
        let text = text ?? randomAutoJoinIntro()
        Task { [weak self] in
            for _ in 0..<24 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                guard self?.isVoiceConnected(to: channelID) == true else { continue }
                await self?.speakAnnouncement(text)
                return
            }
        }
    }

    private func randomAutoJoinIntro() -> String {
        [
            "SwiftBot here. I'll read announcements.",
            "SwiftBot joined. Announcements are live.",
            "Announcer is live.",
            "SwiftBot online for announcements.",
            "I'll read announcements here.",
            "Announcement reader is on."
        ].randomElement() ?? "SwiftBot joined. Announcements are live."
    }

    private func isVoiceConnected(to channelID: String) -> Bool {
        voiceConnectionStatus.isConnected && voicePendingChannelID == channelID
    }

    /// Called from the gateway whenever a member leaves a voice channel.
    /// If the bot is connected with `untilEmpty` mode and the channel is now
    /// empty (no non-bot members), disconnects automatically.
    func handleUntilEmptyCheck(leftChannelId: String, guildId: String) async {
        guard voiceConnectionStatus.isConnected,
              voicePendingChannelID == leftChannelId else { return }

        guard let config = settings.voice.announcerConfigs.first(where: {
            $0.voiceChannelID == leftChannelId && $0.enabled && $0.connectionMode == .untilEmpty
        }) else { return }

        // Check whether any non-bot members remain in the channel
        let humanMembers = activeVoice.filter {
            $0.channelId == leftChannelId && $0.userId != botUserId
        }
        guard humanMembers.isEmpty else { return }

        await autoDisconnect(reason: "All members left \"\(config.name)\" — disconnecting (until-empty mode).")
    }

    private func autoDisconnect(reason: String) async {
        autoDisconnectTask?.cancel()
        autoDisconnectTask = nil
        addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: reason))
        await disconnectVoice()
    }

    private func incrementSpokenToday() {
        if !Calendar.current.isDateInToday(lastSpokenDate) {
            messagesSpokenToday = 0
        }
        messagesSpokenToday += 1
        lastSpokenDate = Date()
    }

    /// Fetches the most recent message from a text channel (looked up by display name) and
    /// returns a speakable string in the form "Author says: content", or a fallback phrase.
    func fetchLastMessageText(fromChannelNamed name: String) async -> String {
        var channelID: String?
        for channels in availableTextChannelsByServer.values {
            if let match = channels.first(where: { $0.name == name }) {
                channelID = match.id
                break
            }
        }
        guard let id = channelID else {
            return "No channel named \(name) found. Make sure the bot is connected to Discord."
        }
        let messages = await fetchRecentMessages(channelId: id, limit: 1)
        guard let message = messages.first else {
            return "No recent messages in #\(name)."
        }
        guard case let .string(content) = message["content"],
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "The last message in #\(name) has no readable text."
        }
        var authorName = ""
        if case let .object(author) = message["author"],
           case let .string(username) = author["username"] {
            authorName = username
        }
        return authorName.isEmpty ? content : "\(authorName) says: \(content)"
    }

    private func discordIntValue(for key: String, in map: [String: DiscordJSON]) -> Int? {
        switch map[key] {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }
}
