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
            await service.setOnDaveMediaReady { [weak self] in
                await self?.handleDaveMediaBecameReady()
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
        Task { [weak self] in
            await watcher.setOnDebug { [weak self] message in
                await MainActor.run {
                    self?.addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: message))
                }
            }
            if !channelIDs.isEmpty {
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

    var manualAnnouncerHold: AnnouncerManualHold? {
        guard let hold = settings.voice.manualAnnouncerHold, hold.isActive() else { return nil }
        return hold
    }

    var announcerManualHoldStatusText: String? {
        guard let hold = manualAnnouncerHold else { return nil }
        let minutes = max(1, Int((Double(hold.remainingSeconds()) / 60).rounded(.up)))
        return "Automatic reconnect paused for \(minutes) min"
    }

    var announcerRecoveryCircuitBreakerStatusText: String? {
        guard announcerRecoveryCircuitBreaker.isOpen else { return nil }
        let minutes = max(1, Int((Double(announcerRecoveryCircuitBreaker.remainingSeconds()) / 60).rounded(.up)))
        return "Recovery cool-off: \(minutes) min"
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
        await connectVoice(guildID: guildID, channelID: channelID, userInitiated: true)
    }

    func connectVoice(
        guildID: String,
        channelID: String,
        recovering: Bool = false,
        userInitiated: Bool = false
    ) async {
        voiceRecoveryAwaitingExternalDisconnectClosure = false
        if !userInitiated, shouldSuppressAutomaticAnnouncerConnection(guildID: guildID, channelID: channelID) {
            return
        }
        if !recovering {
            cancelVoiceRecovery()
            voiceRecovery.reset()
            if userInitiated {
                announcerRecoveryCircuitBreaker.reset()
            }
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
        voicePipelineSessionID = nil
        let attemptToken = UUID()
        voiceConnectAttemptToken = attemptToken
        voiceJoinRequestedAt = ContinuousClock().now
        voiceConnectionStatus = recovering
            ? .recovering("Rejoining voice channel…")
            : .connecting
        // Warm the TTS engine in parallel with the voice handshake so the
        // first announcement doesn't pay voice-asset loading.
        if let announcer = voiceAnnouncementService {
            Task { await announcer.prewarm() }
        }
        let action = recovering ? "Voice rejoin requested" : "Voice join requested"
        addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: "\(action) for channel \(channelID)."))

        // The REST preflight runs once per channel per app run: recovery
        // rejoins and repeat joins of an already-validated channel skip the
        // round trip. A failed connect drops the channel from the cache so a
        // permissions change is re-checked on the next attempt.
        if !recovering, !validatedVoiceChannelIDs.contains(channelID) {
            if let preflightFailure = await voiceChannelPreflightFailure(channelID: channelID) {
                voiceConnectionStatus = .failed(preflightFailure)
                finishVoiceRecoveryIfNeeded(success: false)
                deactivateAnnouncerSession()
                addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: preflightFailure))
                return
            }
            validatedVoiceChannelIDs.insert(channelID)
        }

        let didSendJoin = await service.sendVoiceStateUpdate(guildID: guildID, channelID: channelID)
        guard didSendJoin else {
            let message = "Voice join failed before Discord acknowledged it: main gateway send was blocked or disconnected."
            addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: message))
            if !finishVoiceRecoveryIfNeeded(success: false) {
                voiceConnectionStatus = .failed(message)
                deactivateAnnouncerSession()
            }
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
                guard self.voiceConnectAttemptToken == attemptToken else { return }
                let isMissingVoiceHandshakeData = self.voicePendingSessionID == nil ||
                    self.voicePendingServerToken == nil ||
                    self.voicePendingServerEndpoint == nil
                if self.voiceConnectionStatus.isWaitingForConnectionData,
                   self.voicePendingGuildID == attemptGuildID,
                   isMissingVoiceHandshakeData {
                    let message = "Timed out waiting for Discord voice state and voice server updates."
                    self.addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: message))
                    if let channelID = self.voicePendingChannelID {
                        self.validatedVoiceChannelIDs.remove(channelID)
                    }
                    if !self.finishVoiceRecoveryIfNeeded(success: false) {
                        self.voiceConnectionStatus = .failed(message)
                        self.deactivateAnnouncerSession()
                    }
                }
            }
        }
    }

    /// Tear down the voice connection (sends VOICE_STATE_UPDATE with null
    /// channel, then closes the playback pipeline).
    func disconnectVoice(
        preserveAnnouncerSession: Bool = false,
        preservingNetworkPathRecoveryCooldown: Bool = false
    ) async {
        if preserveAnnouncerSession {
            voiceDisconnectPreservesAnnouncerSession = true
        }
        defer {
            if preserveAnnouncerSession {
                voiceDisconnectPreservesAnnouncerSession = false
            }
        }

        if !preserveAnnouncerSession {
            voiceRecoveryAwaitingExternalDisconnectClosure = false
            cancelVoiceRecovery()
            emptyChannelDisconnectTask?.cancel()
            emptyChannelDisconnectTask = nil
            // A deliberate disconnect must not be undone by a later
            // channel-cache sync re-firing the startup auto-connect.
            voiceAutoConnectArmed = false
            if let announcer = voiceAnnouncementServiceStorage {
                await announcer.setPaused(true)
                await announcer.clearPending()
            }
        }
        let guildID = voicePendingGuildID ?? settings.voice.guildID
        if !guildID.isEmpty {
            _ = await service.sendVoiceStateUpdate(guildID: guildID, channelID: nil)
        }
        await voicePlaybackService.disconnect(
            preservingNetworkPathRecoveryCooldown: preservingNetworkPathRecoveryCooldown
        )
        voicePendingGuildID = nil
        voicePendingChannelID = nil
        voicePendingSessionID = nil
        voicePendingServerToken = nil
        voicePendingServerEndpoint = nil
        voiceCredentialsSessionID = nil
        voicePipelineSessionID = nil
        if preserveAnnouncerSession {
            voiceConnectionStatus = .recovering("Preparing a clean rejoin…")
        } else {
            voiceConnectionStatus = .idle
            deactivateAnnouncerSession()
        }
    }

    // MARK: - Leave acknowledgement

    /// Arm the leave-ack wait. Call BEFORE `disconnectVoice` so an ack that
    /// arrives while the disconnect is still unwinding isn't missed.
    func beginWaitingForVoiceLeaveAck() {
        voiceLeaveAckState = .pending
    }

    func noteVoiceLeaveAck() {
        guard voiceLeaveAckState == .pending else { return }
        voiceLeaveAckState = .received
        voiceLeaveAckContinuation?.resume()
        voiceLeaveAckContinuation = nil
    }

    /// Wait until Discord acknowledges the leave, or `timeout` as a fallback —
    /// typically ~100–200 ms instead of sleeping the full window.
    func waitForVoiceLeaveAck(timeout: Duration = .milliseconds(750)) async {
        switch voiceLeaveAckState {
        case .received, .none:
            voiceLeaveAckState = .none
            return
        case .pending:
            break
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            voiceLeaveAckContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                // Fallback: resume if the ack never arrived (no-op after a
                // normal resume — the continuation is cleared on use).
                self.voiceLeaveAckContinuation?.resume()
                self.voiceLeaveAckContinuation = nil
            }
        }
        voiceLeaveAckState = .none
    }

    /// Manually trigger an announcement (e.g. `/say` or the Test button in the
    /// Voice tab).
    func speakAnnouncement(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard voiceConnectionStatus.canQueueAnnouncements else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Discord speech skipped because the voice announcer is unavailable."
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
        if !voiceConnectionStatus.isConnected {
            // Preserve the direct read while the handshake/DAVE gate is still
            // settling instead of letting it make a speculative not-connected
            // playback attempt before the connected callback resumes draining.
            await announcer.setPaused(true)
        }
        incrementSpokenToday()
        await announcer.enqueue(trimmed)
        if !voiceConnectionStatus.isConnected {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Discord speech queued until the voice media path is ready."
            ))
        }
    }

    /// Speak `text` through the Mac's local speakers using
    /// `AVSpeechSynthesizer` — no Discord voice connection involved. Used as
    /// a preview while the Discord voice path is unavailable.
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

    func commitAnnouncerConfigsFromEditor(_ configs: [AnnouncerVoiceChannelConfig]) {
        guard settings.voice.announcerConfigs != configs else { return }
        settings.voice.announcerConfigs = configs

        if forwardsConfigEditsToPrimary {
            forwardConfigMutationToPrimary(.replaceVoice(settings.voice), revertOnFailure: true)
        } else {
            saveSettings()
            scheduleVoiceSettingsFinalSave()
        }
    }

    private func scheduleVoiceSettingsFinalSave() {
        voiceSettingsFinalSaveTask?.cancel()
        voiceSettingsFinalSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.25))
            guard !Task.isCancelled else { return }
            self?.saveSettings()
            self?.voiceSettingsFinalSaveTask = nil
        }
    }

    func reconnectAnnouncerVoiceFromUI() async {
        guard status == .running else {
            voiceConnectionStatus = .failed("Bot is offline — click Start Bot first.")
            return
        }

        guard let target = await prepareAnnouncerConfigForUIReconnect() else {
            voiceConnectionStatus = .failed("Announcer voice channel is not configured.")
            return
        }

        clearManualAnnouncerHold(guildID: target.guildID, channelID: target.channelID, source: "the Announcer reconnect control")
        announcerRecoveryCircuitBreaker.reset()

        if let announcer = voiceAnnouncementServiceStorage {
            await announcer.markRecovering("manual voice reconnect")
        }
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Manual Announcer voice reconnect requested."
        ))
        beginWaitingForVoiceLeaveAck()
        await disconnectVoice(preserveAnnouncerSession: true)
        await waitForVoiceLeaveAck()
        await connectVoice(guildID: target.guildID, channelID: target.channelID, recovering: true, userInitiated: true)
    }

    /// The local UI equivalent of `/announce disconnect`: it is an explicit
    /// request to keep the Announcer quiet, not merely a transport teardown.
    func manuallyDisconnectAnnouncerFromUI() async {
        let guildID = voicePendingGuildID ?? settings.voice.guildID
        let channelID = voicePendingChannelID ?? settings.voice.voiceChannelID
        if !guildID.isEmpty, !channelID.isEmpty {
            setManualAnnouncerHold(guildID: guildID, channelID: channelID, source: "the Announcer disconnect control")
        }
        await disconnectVoice()
    }

    @discardableResult
    func prepareAnnouncerConfigForUIReconnect(persist: Bool = true, logFailures: Bool = true) async -> (guildID: String, channelID: String)? {
        guard let target = preferredAnnouncerReconnectTarget() else {
            if logFailures {
                addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Manual Announcer reconnect skipped because no enabled voice channel configuration is available."
                ))
            }
            return nil
        }

        guard await activateAnnouncerConfig(target.config, guildID: target.guildID, persist: persist) else {
            if logFailures {
                addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Manual Announcer reconnect skipped because \"\(target.config.name)\" has no readable feed."
                ))
            }
            return nil
        }
        return (target.guildID, target.config.voiceChannelID)
    }

    /// Arm the startup auto-connect (`settings.voice.autoConnect`) and try it
    /// once. Called from the READY handler; safe on gateway reconnects — a
    /// live voice connection or a disarm makes it a no-op.
    func armVoiceAutoConnect() {
        guard settings.voice.autoConnect else { return }
        voiceAutoConnectArmed = true
        attemptVoiceAutoConnect()
    }

    /// Try the armed auto-connect. Fired from every channel-cache sync (each
    /// GUILD_CREATE), so the join starts the moment the configured channel
    /// becomes resolvable instead of on a polling cadence. Disarms once a
    /// connect is initiated.
    func attemptVoiceAutoConnect() {
        guard voiceAutoConnectArmed, settings.voice.autoConnect else { return }
        guard status == .running, !voiceConnectionStatus.isConnected else { return }
        guard voiceAutoConnectTask == nil else { return }
        voiceAutoConnectTask = Task { @MainActor [weak self] in
            defer { self?.voiceAutoConnectTask = nil }
            guard let self, self.voiceAutoConnectArmed else { return }
            // Channel lists may not include the configured channel yet; the
            // next cache sync retries.
            guard let target = await self.prepareAnnouncerConfigForUIReconnect(logFailures: false) else { return }
            guard !self.shouldSuppressAutomaticAnnouncerConnection(guildID: target.guildID, channelID: target.channelID) else {
                self.voiceAutoConnectArmed = false
                return
            }
            self.voiceAutoConnectArmed = false
            self.addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Auto-connect joining the configured Announcer voice channel."
            ))
            await self.connectVoice(guildID: target.guildID, channelID: target.channelID)
        }
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

    /// `/announce disconnect` — leave the caller's configured Announcer and
    /// suppress all automatic connection paths for one hour. A later manual
    /// `/announce join` or `/announce rejoin` clears the hold immediately.
    func handleAnnounceDisconnectSlash(raw: [String: DiscordJSON]) async -> (ok: Bool, message: String) {
        guard let guildID = guildId(from: raw), !guildID.isEmpty else {
            return (false, "Use `/announce disconnect` in a server channel.")
        }
        guard let userID = authorId(from: raw), !userID.isEmpty else {
            return (false, "I couldn't identify who ran `/announce disconnect`.")
        }
        guard let presence = activeVoice.first(where: { $0.guildId == guildID && $0.userId == userID }) else {
            return (false, "Join the configured Announcer voice channel before using `/announce disconnect`.")
        }
        guard let config = settings.voice.announcerConfigs.first(where: {
            $0.enabled && $0.voiceChannelID == presence.channelId
        }) else {
            return (false, "No enabled Announcer configuration matches your current voice channel.")
        }

        setManualAnnouncerHold(guildID: guildID, channelID: config.voiceChannelID, source: "`/announce disconnect`")
        await disconnectVoice()
        return (true, "Disconnected from \(config.voiceChannelName). Automatic joins and recovery are paused for one hour; `/announce join` or `/announce rejoin` resumes now.")
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

        clearManualAnnouncerHold(guildID: guildID, channelID: config.voiceChannelID, source: "`/announce \(verb)`")
        announcerRecoveryCircuitBreaker.reset()

        // For rejoin, tear down any existing session first so the connect below
        // isn't skipped by connectVoice's "already connected/connecting" guard.
        // Waiting for Discord's leave ack avoids the re-join being ignored as
        // a duplicate voice state.
        if rejoin {
            beginWaitingForVoiceLeaveAck()
            await disconnectVoice()
            await waitForVoiceLeaveAck(timeout: .milliseconds(500))
        }

        guard await activateAnnouncerConfig(config, guildID: guildID) else {
            return (false, "The Announcer configuration for \(config.voiceChannelName) needs at least one readable text channel.")
        }

        await connectVoice(guildID: guildID, channelID: config.voiceChannelID, userInitiated: true)
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
        // The `/announce join` read-aloud thread is a source for as long as the
        // session lives. It carries its own length cap and per-author cooldown
        // because, unlike a configured feed, anyone who can see it may post.
        let isReadAloudThread = shouldSpeakAnnouncerThreadMessage(event)
        guard watchedIDs.contains(event.channelID) || isVoiceChannelChat || isReadAloudThread else { return }
        // Don't read SwiftBot's own messages to avoid feedback loops.
        if let botUserId, event.userID == botUserId { return }
        // Optionally skip webhook posts (integrations, bridges, bots that post
        // via webhooks) so only real server members are read aloud.
        if activeConfig?.ignoreWebhooks == true, event.rawMap["webhook_id"] != nil { return }
        // Optionally skip bot-authored messages.
        if activeConfig?.skipBots == true, event.isBot { return }
        guard let watcher = textChannelAnnouncer else { return }
        // Charge the per-author cooldown only once the message has cleared every
        // filter that would have discarded it. Stamping it at the channel check
        // meant a self/webhook/bot post the announcer never reads still spent the
        // author's budget, silencing the real message that followed it.
        if isReadAloudThread {
            noteAnnouncerThreadSpoken(userID: event.userID)
        }
        // `smartShortenWithAppleIntelligence` is a legacy flag: the announcer no
        // longer calls a model on the read path (an on-device rewrite costs
        // 5-8 s, far longer than the read it would delay). Existing configs that
        // enabled it still expect long messages to be read, so it keeps meaning
        // "shorten instead of skip" — now via the deterministic caps.
        let shortensLongMessages = activeConfig?.summariseLong == true
            || activeConfig?.smartShortenWithAppleIntelligence == true
        let options = AnnouncerReadOptions(
            ignoreLinks: activeConfig?.ignoreLinks ?? true,
            summariseLong: shortensLongMessages,
            keepShort: activeConfig?.keepShort ?? false,
            ignoreEmojiSpam: activeConfig?.ignoreEmojiSpam ?? false,
            suppressRepeatedSpeakerNames: activeConfig?.suppressRepeatedSpeakerNames ?? true
        )
        let cachedDisplayName = await discordCache.userName(for: event.userID)
        await watcher.handle(
            event,
            displayNameOverride: cachedDisplayName,
            channelNames: flattenedChannelNames(),
            roleNames: flattenedRoleNames(),
            options: options,
            bypassChannelFilter: isReadAloudThread
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
        let channelIsNull: Bool
        switch event.rawMap["channel_id"] {
        case .null, .none:
            channelIsNull = true
        default:
            channelIsNull = false
        }
        if let expectedBotUserId, event.userID == expectedBotUserId, channelIsNull {
            // A null channel for our own bot is Discord's authoritative record
            // that it has left. During our own clean rejoin it is simply the
            // leave acknowledgement; otherwise it was a moderator/user-side
            // disconnect and needs its own controlled recovery path. Discord
            // can deliver that acknowledgement after the 750 ms fallback has
            // elapsed and the rejoin has already begun. Do not let that stale
            // acknowledgement cancel and reset the recovery which caused it:
            // doing so makes every attempt look like attempt 1 and permits an
            // unbounded join/leave loop.
            if voiceLeaveAckState == .pending {
                noteVoiceLeaveAck()
            } else if voiceRecovery.inProgress {
                addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Ignored delayed self voice-disconnect acknowledgement while controlled recovery is in progress."
                ))
            } else {
                await handleExternalVoiceDisconnect(guildID: event.guildID)
            }
            return
        }
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

    /// Handle a Discord-side removal (for example, right-click → Disconnect)
    /// before the old voice WebSocket produces its expected 4014 close. This
    /// prevents that close from being counted as a second failed rejoin and
    /// leaves a precise, exportable record of why recovery began.
    private func handleExternalVoiceDisconnect(guildID: String) async {
        guard guildID == voicePendingGuildID,
              let channelID = voicePendingChannelID,
              !channelID.isEmpty else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Discord confirmed SwiftBot is disconnected from voice, but no active Announcer session matched the event."
            ))
            return
        }
        guard voiceConnectionStatus.isConnected || voiceConnectionStatus.isWaitingForConnectionData else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Discord confirmed SwiftBot left voice channel \(channelID) while a local disconnect was already in progress."
            ))
            return
        }

        let reason = "Discord reported that SwiftBot was disconnected from voice by a server-side action"
        cancelVoiceRecovery()
        voiceRecovery.reset()
        voiceRecoveryAwaitingExternalDisconnectClosure = true
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "\(reason); starting one controlled background rejoin."
        ))
        if let announcer = voiceAnnouncementServiceStorage {
            await announcer.markRecovering(reason)
        }
        guard scheduleVoiceAutoRecovery(reason: reason) else {
            voiceRecoveryAwaitingExternalDisconnectClosure = false
            voiceConnectionStatus = .failed(reason)
            deactivateAnnouncerSession()
            return
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

        let pipelineStatus = await voicePlaybackService.currentStatus
        if voicePipelineSessionID == sessionID {
            switch pipelineStatus {
            case .connecting, .connected:
                addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Ignored duplicate Discord voice handshake for the active session."
                ))
                return
            case .idle, .disconnecting, .failed:
                voicePipelineSessionID = nil
            }
        }

        switch pipelineStatus {
        case .idle, .failed:
            break
        case .disconnecting:
            // A clean recovery already owns the teardown. Its subsequent
            // VOICE_STATE_UPDATE will start the next handshake.
            return
        case .connecting, .connected:
            // Discord may replay a fresh handshake during a main-gateway
            // reconnect before the old voice WebSocket's 4014 close reaches
            // us. Never let that second handshake mark a healthy pipeline as
            // failed; route it through the normal leave-ack/rejoin funnel.
            let reason = "Discord issued a new voice handshake while the previous pipeline was still active"
            addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: "\(reason); scheduling a clean rejoin."))
            _ = scheduleVoiceAutoRecovery(reason: reason)
            return
        }

        voicePipelineSessionID = sessionID
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
            logVoiceConnectedTiming()
            deliverPendingVoiceJoinIntroIfReady()
        } catch {
            if voicePipelineSessionID == sessionID {
                voicePipelineSessionID = nil
            }
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice pipeline connect failed: \(error.localizedDescription)"
            ))
            if let pipelineError = error as? VoicePipelineError,
               case let .unexpectedPayload(reason) = pipelineError,
               reason.hasPrefix("voice connect requested while the pipeline is") {
                let recoveryReason = "voice pipeline was still active when Discord replayed its handshake"
                addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: "\(recoveryReason); scheduling a clean rejoin."))
                _ = scheduleVoiceAutoRecovery(reason: recoveryReason)
                return
            }
            // connect() usually throws only after publishing a .failed status,
            // in which case handleVoicePlaybackStatus already ran the
            // retry/teardown funnel. The exception is the busy-pipeline guard,
            // which throws without a status change and must be handled here.
            let playbackFailed: Bool
            if case .failed = await voicePlaybackService.currentStatus {
                playbackFailed = true
            } else {
                playbackFailed = false
            }
            if !playbackFailed, !finishVoiceRecoveryIfNeeded(success: false) {
                voiceConnectionStatus = .failed(error.localizedDescription)
                deactivateAnnouncerSession()
            }
        }
    }

    private func handleVoicePlaybackStatus(_ status: VoicePlaybackService.Status) async {
        switch status {
        case .idle:
            voicePipelineSessionID = nil
            if voiceRecovery.inProgress || voiceDisconnectPreservesAnnouncerSession {
                voiceConnectionStatus = .recovering("Preparing a clean rejoin…")
                return
            }
            voiceConnectionStatus = .idle
            deactivateAnnouncerSession()
        case .connecting:
            if !voiceRecovery.inProgress {
                voiceConnectionStatus = .connecting
            }
            if let announcer = voiceAnnouncementServiceStorage {
                await announcer.setPaused(true)
            }
        case .connected:
            voiceConnectionStatus = .connected
            finishVoiceRecoveryIfNeeded(success: true)
            announcerRecoveryCircuitBreaker.reset()
            if let announcer = voiceAnnouncementServiceStorage {
                await announcer.setPaused(false)
            }
            startAnnouncerHealthWatchdog()
            logVoiceConnectedTiming()
            deliverPendingVoiceJoinIntroIfReady()
        case .disconnecting:
            if voiceRecovery.inProgress {
                voiceConnectionStatus = .recovering("Preparing a clean rejoin…")
            } else {
                voiceConnectionStatus = .disconnecting
            }
        case .failed(let reason):
            voicePipelineSessionID = nil
            if voiceRecoveryAwaitingExternalDisconnectClosure {
                voiceRecoveryAwaitingExternalDisconnectClosure = false
                addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Observed the expected stale voice socket close after Discord disconnected SwiftBot; the scheduled background rejoin remains in control."
                ))
                return
            }
            // Surface unexpected drops (e.g. a voice gateway WS close after we
            // were connected) in the activity log. Without this the announcer
            // silently stops reading — messages are dropped by the
            // `isConnected` guard in forwardMessageToVoiceAnnouncer with no
            // trace — while the bot may still appear present in Discord.
            let wasConnected = voiceConnectionStatus.isConnected
            // Re-check permissions on the next join of this channel.
            if let channelID = voicePendingChannelID {
                validatedVoiceChannelIDs.remove(channelID)
            }
            pendingVoiceJoinIntro = nil
            if wasConnected, scheduleVoiceAutoRecovery(reason: reason) {
                return
            }
            if wasConnected {
                addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Voice connection lost (\(reason))."
                ))
            }
            if finishVoiceRecoveryIfNeeded(success: false) {
                return
            }
            voiceConnectionStatus = .failed(reason)
            deactivateAnnouncerSession()
        }
    }

    /// Fired by the voice pipeline when DAVE media becomes ready again
    /// mid-connection (a re-key or downgrade finished), so reads paused on
    /// `daveNotReady` resume immediately instead of waiting for a reconnect.
    func handleDaveMediaBecameReady() async {
        guard voiceConnectionStatus.isConnected else { return }
        if let announcer = voiceAnnouncementServiceStorage {
            await announcer.resumeAfterMediaReady()
        }
    }

    private func scheduleVoiceAutoRecovery(reason: String) -> Bool {
        let guildID = voicePendingGuildID ?? settings.voice.guildID
        let channelID = voicePendingChannelID ?? settings.voice.voiceChannelID
        guard !shouldSuppressAutomaticAnnouncerConnection(guildID: guildID, channelID: channelID) else { return false }
        guard status == .running, !guildID.isEmpty, !channelID.isEmpty else { return false }
        voiceRecoveryStabilityTask?.cancel()
        voiceRecoveryStabilityTask = nil
        guard let delay = voiceRecovery.beginAttempt() else {
            openVoiceRecoveryCircuitBreakerIfExhausted()
            return false
        }

        voiceConnectionStatus = .recovering("Rejoining after voice drop…")
        if let announcer = voiceAnnouncementServiceStorage {
            Task { await announcer.markRecovering(reason) }
        }
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Voice connection lost (\(reason)). Auto-rejoin attempt \(voiceRecovery.attemptsMade) of \(voiceRecovery.attemptsAllowed); queued reads are paused."
        ))

        voiceRecoveryTask?.cancel()
        voiceRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.performVoiceAutoRecovery(guildID: guildID, channelID: channelID, reason: reason)
        }
        return true
    }

    private func performVoiceAutoRecovery(guildID: String, channelID: String, reason: String) async {
        guard voiceRecovery.inProgress else { return }
        voiceRecoveryAwaitingExternalDisconnectClosure = false
        guard status == .running else {
            let message = "Voice auto-rejoin stopped because the bot is offline."
            addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: message))
            // Offline means scheduling another attempt is pointless; the
            // funnel below fails to reschedule and we tear down.
            finishVoiceRecoveryIfNeeded(success: false)
            voiceConnectionStatus = .failed(message)
            deactivateAnnouncerSession()
            return
        }

        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Voice auto-rejoin starting after \(reason)."
        ))
        beginWaitingForVoiceLeaveAck()
        await disconnectVoice(
            preserveAnnouncerSession: true,
            preservingNetworkPathRecoveryCooldown: true
        )
        guard voiceRecovery.inProgress else { return }
        await waitForVoiceLeaveAck()
        guard voiceRecovery.inProgress else { return }
        await connectVoice(guildID: guildID, channelID: channelID, recovering: true)
    }

    /// Close out the in-flight recovery attempt. On failure, schedules the
    /// next backoff attempt when any remain — returning `true` so the caller
    /// leaves the announcer session armed — otherwise returns `false` and the
    /// caller is responsible for surfacing the failure and tearing down.
    @discardableResult
    private func finishVoiceRecoveryIfNeeded(success: Bool) -> Bool {
        guard voiceRecovery.inProgress else { return false }
        voiceRecovery.finishAttempt()
        voiceRecoveryTask = nil
        if success {
            armVoiceRecoveryStabilityWindow()
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice auto-rejoin succeeded; queued reads are resuming. The retry budget will reset after 30 seconds of stability."
            ))
            return false
        }
        if scheduleVoiceAutoRecovery(reason: "the previous rejoin attempt failed") {
            return true
        }
        openVoiceRecoveryCircuitBreakerIfExhausted()
        return false
    }

    private func openVoiceRecoveryCircuitBreakerIfExhausted() {
        guard !voiceRecovery.inProgress,
              voiceRecovery.attemptsMade >= voiceRecovery.attemptsAllowed,
              !announcerRecoveryCircuitBreaker.isOpen else { return }
        announcerRecoveryCircuitBreaker.trip(
            reason: "voice recovery exhausted after \(voiceRecovery.attemptsMade) attempts",
            attempts: voiceRecovery.attemptsMade
        )
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Voice auto-rejoin failed with no attempts remaining; recovery circuit breaker is open for 5 minutes and the announcer session was stopped."
        ))
    }

    /// A transport handshake is not enough to prove recovery when DAVE is
    /// processing a burst of add/remove proposals. Keep the consumed attempt
    /// charged until the connection survives the participant-transition
    /// window, so repeated short-lived successes eventually reach the circuit
    /// breaker instead of producing an unbounded rejoin loop.
    private func armVoiceRecoveryStabilityWindow() {
        let attemptsAtConnection = voiceRecovery.attemptsMade
        voiceRecoveryStabilityTask?.cancel()
        voiceRecoveryStabilityTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard let self else { return }
            self.voiceRecoveryStabilityTask = nil
            guard self.voiceConnectionStatus.isConnected,
                  !self.voiceRecovery.inProgress,
                  self.voiceRecovery.attemptsMade == attemptsAtConnection else { return }
            self.voiceRecovery.reset()
            self.addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice connection remained stable for 30 seconds; the auto-rejoin retry budget was restored."
            ))
        }
    }

    private func cancelVoiceRecovery() {
        voiceRecoveryTask?.cancel()
        voiceRecoveryTask = nil
        voiceRecoveryStabilityTask?.cancel()
        voiceRecoveryStabilityTask = nil
        voiceRecovery.cancel()
    }

    func setManualAnnouncerHold(guildID: String, channelID: String, source: String) {
        let hold = AnnouncerManualHold(
            guildID: guildID,
            voiceChannelID: channelID,
            expiresAt: Date().addingTimeInterval(60 * 60)
        )
        settings.voice.manualAnnouncerHold = hold
        voiceAutoConnectArmed = false
        cancelVoiceRecovery()
        announcerRecoveryCircuitBreaker.reset()
        persistSettingsIfPossible()
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Announcer manual hold armed by \(source) for \(channelID), expires at \(hold.expiresAt.formatted(date: .omitted, time: .shortened))."
        ))
    }

    private func clearManualAnnouncerHold(guildID: String, channelID: String, source: String) {
        guard let hold = settings.voice.manualAnnouncerHold,
              hold.guildID == guildID,
              hold.voiceChannelID == channelID else { return }
        settings.voice.manualAnnouncerHold = nil
        persistSettingsIfPossible()
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Announcer manual hold cleared by \(source)."
        ))
    }

    /// Returns true when a user explicitly asked this Announcer to remain
    /// quiet, or when its bounded recovery budget has just been exhausted.
    /// Every automatic entry point calls this before activating a config.
    private func shouldSuppressAutomaticAnnouncerConnection(guildID: String, channelID: String) -> Bool {
        if let hold = settings.voice.manualAnnouncerHold,
           hold.guildID == guildID,
           hold.voiceChannelID == channelID,
           hold.isActive() {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Automatic Announcer connection suppressed by manual hold (\(hold.remainingSeconds()) seconds remaining)."
            ))
            return true
        }
        if announcerRecoveryCircuitBreaker.isOpen {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Automatic Announcer connection suppressed by recovery circuit breaker (\(announcerRecoveryCircuitBreaker.remainingSeconds()) seconds remaining)."
            ))
            return true
        }
        return false
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
        guard let announcer = voiceAnnouncementServiceStorage else { return }

        if announcerHealth.isStalled(threshold: 60) {
            let reason = "announcer health watchdog: \(announcerHealth.phase.displayLabel.lowercased()) for too long"
            await announcer.markRecovering(reason)
            _ = scheduleVoiceAutoRecovery(reason: reason)
            return
        }

        // A connected WebSocket alone is not proof that the Announcer can
        // speak. Check the complete media path and the paced audio/keepalive
        // signals without producing any audible probe packet.
        let diagnostics = await voicePlaybackService.diagnosticsSnapshot()
        let mediaPathReady = diagnostics.hasGateway && diagnostics.hasTransport &&
            diagnostics.hasEncryption && diagnostics.hasOpusEncoder && diagnostics.hasSSRC
        let audioHasGoneSilentWhileSpeaking: Bool = {
            guard diagnostics.isSpeaking,
                  let lastAudio = diagnostics.lastAudioFrameSentAt else { return diagnostics.isSpeaking }
            return Date().timeIntervalSince(lastAudio) >= 15
        }()
        let reason: String?
        if !mediaPathReady {
            reason = "announcer health probe: connected state is missing a required media component"
        } else if diagnostics.keepaliveFailures >= 3 {
            reason = "announcer health probe: \(diagnostics.keepaliveFailures) consecutive UDP keepalive failures"
        } else if audioHasGoneSilentWhileSpeaking {
            reason = "announcer health probe: speech is active but no audio frame was sent for 15 seconds"
        } else {
            reason = nil
        }
        guard let reason else { return }
        addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: reason))
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
    func handleAutoJoin(
        channelId: String,
        guildId: String,
        triggeringUserId: String,
        triggeringDisplayName: String
    ) async {
        // Never auto-join because of the bot's own presence update
        guard triggeringUserId != botUserId else { return }
        // Only act when the bot is online but not already in a voice channel
        guard status == .running, !voiceConnectionStatus.isConnected else { return }
        guard !shouldSuppressAutomaticAnnouncerConnection(guildID: guildId, channelID: channelId) else { return }

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
        scheduleVoiceJoinIntro(channelID: channelId, text: "\(triggeringDisplayName) has joined.")

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
        guard !shouldSuppressAutomaticAnnouncerConnection(guildID: guildId, channelID: channelId) else { return }

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

    private func preferredAnnouncerReconnectTarget() -> (config: AnnouncerVoiceChannelConfig, guildID: String)? {
        let enabledConfigs = settings.voice.announcerConfigs.filter {
            $0.enabled && !$0.voiceChannelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // Announcer owns one voice pipeline, so its configured list is an
        // ordered set of alternatives rather than simultaneous sessions. The
        // first enabled entry is the predictable default for startup and the
        // UI reconnect control. Explicit /announce joins and live recovery
        // deliberately retain their current channel instead.
        let config = enabledConfigs.first
        guard let config, let guildID = guildID(forAnnouncerVoiceChannelID: config.voiceChannelID) else {
            return nil
        }
        return (config, guildID)
    }

    private func guildID(forAnnouncerVoiceChannelID channelID: String) -> String? {
        let configuredGuildID = settings.voice.guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredGuildID.isEmpty,
           availableVoiceChannelsByServer[configuredGuildID]?.contains(where: { $0.id == channelID }) == true {
            return configuredGuildID
        }

        if let match = availableVoiceChannelsByServer.first(where: { _, channels in
            channels.contains(where: { $0.id == channelID })
        }) {
            return match.key
        }

        return configuredGuildID.isEmpty ? nil : configuredGuildID
    }

    private func activateAnnouncerConfig(_ config: AnnouncerVoiceChannelConfig, guildID: String, persist: Bool = true) async -> Bool {
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
        if persist {
            persistSettingsIfPossible()
            scheduleVoiceSettingsFinalSave()
        }
        if let watcher = textChannelAnnouncer {
            await watcher.resetSpeakerAttribution()
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
        pendingVoiceJoinIntro = nil
        archiveAnnouncerReadAloudThread()
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
            Task {
                await watcher.resetSpeakerAttribution()
                await watcher.setWatchedChannel(nil)
            }
        }
    }

    private func scheduleVoiceJoinIntro(channelID: String, text: String? = nil) {
        let text = text ?? randomAutoJoinIntro()
        if isVoiceConnected(to: channelID) {
            Task { await speakAnnouncement(text) }
            return
        }
        // Delivered by the .connected transition the moment the pipeline is
        // live (no polling delay); dropped if the session fails first.
        pendingVoiceJoinIntro = (channelID, text)
    }

    private func deliverPendingVoiceJoinIntroIfReady() {
        guard let pending = pendingVoiceJoinIntro, isVoiceConnected(to: pending.channelID) else { return }
        pendingVoiceJoinIntro = nil
        Task { await speakAnnouncement(pending.text) }
    }

    /// One-line summary of how long the join took, from request to live
    /// pipeline — the number the user actually feels.
    private func logVoiceConnectedTiming() {
        guard let startedAt = voiceJoinRequestedAt else { return }
        voiceJoinRequestedAt = nil
        let elapsed = ContinuousClock().now - startedAt
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: String(format: "Announcer voice connected %.1fs after the join request.", seconds)
        ))
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

    /// Announces a human arrival only when Announcer is already live in that
    /// exact configured channel. The arrival which triggers an automatic join
    /// is scheduled by `handleAutoJoin` and spoken once the media path is live.
    func announceMemberVoiceJoin(
        userID: String,
        displayName: String,
        channelID: String,
        guildID: String
    ) async {
        let botIDs = knownBotUserIds.union(botUserId.map { [$0] } ?? [])
        guard !botIDs.contains(userID),
              voicePendingGuildID == guildID,
              isVoiceConnected(to: channelID),
              settings.voice.announcerConfigs.contains(where: {
                  $0.enabled && $0.voiceChannelID == channelID
              })
        else { return }

        let announcement = "\(displayName) has joined."
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Announcer introducing \(displayName) in the active voice channel."
        ))
        await speakAnnouncement(announcement)
    }

    /// Announces a human departure from the exact channel where Announcer is
    /// currently live. Voice-state moves use this for the old channel too, so
    /// leaving for another room is announced just like disconnecting. Bot and
    /// SwiftBot-owned departures are deliberately silent.
    func announceMemberVoiceDeparture(
        userID: String,
        displayName: String,
        channelID: String,
        guildID: String
    ) async {
        let botIDs = knownBotUserIds.union(botUserId.map { [$0] } ?? [])
        guard !botIDs.contains(userID),
              voicePendingGuildID == guildID,
              isVoiceConnected(to: channelID),
              settings.voice.announcerConfigs.contains(where: {
                  $0.enabled && $0.voiceChannelID == channelID
              })
        else { return }

        let announcement = "\(displayName) has left."
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Announcer saying \(displayName) has left the active voice channel."
        ))
        await speakAnnouncement(announcement)
    }

    /// Re-evaluate the optional presence-aware Announcer mode after any voice
    /// presence change. When the last human leaves, reads pause immediately and
    /// a short grace period avoids needless leave/rejoin churn for a brief hop.
    func handleAnnouncerPresenceChange(channelId: String, guildId: String) async {
        guard voiceConnectionStatus.isConnected,
              voicePendingChannelID == channelId else { return }

        guard let config = settings.voice.announcerConfigs.first(where: {
            $0.voiceChannelID == channelId && $0.enabled && $0.connectionMode == .untilEmpty
        }) else { return }

        let botIDs = knownBotUserIds.union(botUserId.map { [$0] } ?? [])
        let humanMembers = activeVoice.filter {
            $0.guildId == guildId && $0.channelId == channelId && !botIDs.contains($0.userId)
        }
        guard humanMembers.isEmpty else {
            if emptyChannelDisconnectTask != nil {
                emptyChannelDisconnectTask?.cancel()
                emptyChannelDisconnectTask = nil
                addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Human member returned to \"\(config.name)\" during the empty-channel grace period; Announcer reads resumed."
                ))
                if let announcer = voiceAnnouncementServiceStorage {
                    await announcer.setPaused(false)
                }
            }
            return
        }

        guard emptyChannelDisconnectTask == nil else { return }
        if let announcer = voiceAnnouncementServiceStorage {
            let drained = await announcer.waitUntilIdle(timeout: .seconds(10))
            if !drained {
                addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Announcer departure speech did not drain within 10 seconds; continuing the bounded empty-channel shutdown."
                ))
            }
        }
        // The goodbye can take a moment to render and play. A member may have
        // returned while that actor work was in flight, so never continue from
        // the pre-speech empty-room snapshot.
        guard voiceConnectionStatus.isConnected,
              voicePendingChannelID == channelId,
              activeVoice.allSatisfy({
                  $0.guildId != guildId || $0.channelId != channelId || botIDs.contains($0.userId)
              }) else { return }
        let graceSeconds = min(120, max(0, config.emptyChannelGraceSeconds))
        if graceSeconds == 0 {
            await autoDisconnect(reason: "No human members remain in \"\(config.name)\"; disconnecting immediately (empty-channel grace disabled).")
            return
        }
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "No human members remain in \"\(config.name)\"; pausing reads and waiting \(graceSeconds) seconds before disconnecting."
        ))
        if let announcer = voiceAnnouncementServiceStorage {
            await announcer.setPaused(true)
        }
        emptyChannelDisconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(graceSeconds)))
            guard !Task.isCancelled, let self else { return }
            self.emptyChannelDisconnectTask = nil
            let botIDs = self.knownBotUserIds.union(self.botUserId.map { [$0] } ?? [])
            let stillEmpty = self.activeVoice.allSatisfy {
                $0.guildId != guildId || $0.channelId != channelId || botIDs.contains($0.userId)
            }
            guard stillEmpty, self.voiceConnectionStatus.isConnected,
                  self.voicePendingChannelID == channelId else { return }
            await self.autoDisconnect(reason: "No members returned to \"\(config.name)\" during the \(graceSeconds)-second empty-channel grace period.")
        }
    }

    /// Compatibility entry point for the leave/move dispatcher.
    func handleUntilEmptyCheck(leftChannelId: String, guildId: String) async {
        await handleAnnouncerPresenceChange(channelId: leftChannelId, guildId: guildId)
    }

    private func autoDisconnect(reason: String) async {
        autoDisconnectTask?.cancel()
        autoDisconnectTask = nil
        emptyChannelDisconnectTask?.cancel()
        emptyChannelDisconnectTask = nil
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

// MARK: - Announcer read-aloud thread

extension AppModel {
    /// Longest message the thread will read. Beyond this the announcer's own
    /// shortening options would kick in anyway; the hard cap stops a wall of
    /// text monopolising the voice channel.
    static let announcerThreadMaxCharacters = 400
    /// Minimum gap between two reads from the same author. The thread is open to
    /// anyone who can see it, so this is what keeps one person from flooding the
    /// TTS queue.
    static let announcerThreadPerUserCooldown: TimeInterval = 3

    /// Opens the read-aloud thread on the `/announce join` reply. Called after
    /// the reply has actually been posted, since the message must exist before
    /// a thread can hang off it. Failure is non-fatal: the announcer is already
    /// live and reading its configured feed, so a missing thread costs nothing
    /// but the convenience.
    /// Records why the thread was not opened. Every early exit reports: a
    /// feature that quietly does nothing is impossible to diagnose from a
    /// server, and the first build of this shipped with five silent returns.
    func noteReadAloudThreadSkipped(_ reason: String) {
        addVoiceLogEntry(VoiceEventLogEntry(
            time: Date(),
            description: "Read-aloud thread not opened: \(reason)"
        ))
        logs.append("ℹ️ Read-aloud thread not opened: \(reason)")
    }

    func openAnnouncerReadAloudThread(interactionToken: String, channelName: String) async {
        guard announcerReadAloudThreadID == nil else {
            noteReadAloudThreadSkipped("one is already open for this session.")
            return
        }
        guard let applicationID = botUserId, !applicationID.isEmpty else {
            noteReadAloudThreadSkipped("the bot's application ID is not known yet.")
            return
        }
        guard ActionDispatcher.canSend(
            clusterMode: runtimeClusterMode,
            action: "openAnnouncerReadAloudThread",
            log: { logs.append($0) }
        ) else {
            noteReadAloudThreadSkipped("this node is not the Primary.")
            return
        }

        do {
            guard let original = try await service.fetchOriginalInteractionResponse(
                applicationID: applicationID,
                interactionToken: interactionToken
            ) else {
                noteReadAloudThreadSkipped("Discord returned no usable message for the /announce reply.")
                return
            }

            let threadID = try await service.createThreadFromMessage(
                channelId: original.channelID,
                messageId: original.messageID,
                name: "🔊 Read aloud — \(channelName)".prefix(100).description,
                token: settings.token
            )
            announcerReadAloudThreadID = threadID
            announcerThreadLastSpokenAt.removeAll()
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Opened read-aloud thread for \(channelName). Messages posted there will be spoken."
            ))
        } catch {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Could not open the read-aloud thread: \(error.localizedDescription)"
            ))
            logs.append("⚠️ Could not open the Announcer read-aloud thread: \(error.localizedDescription)")
        }
    }

    /// Collapses the thread when the announcer leaves. Archiving keeps every
    /// message readable and lets Discord reopen the thread if someone posts, so
    /// nothing anyone wrote is lost.
    func archiveAnnouncerReadAloudThread() {
        guard let threadID = announcerReadAloudThreadID else { return }
        announcerReadAloudThreadID = nil
        announcerThreadLastSpokenAt.removeAll()
        guard ActionDispatcher.canSend(
            clusterMode: runtimeClusterMode,
            action: "archiveAnnouncerReadAloudThread",
            log: { logs.append($0) }
        ) else { return }
        let token = settings.token
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.service.setThreadArchived(threadId: threadID, archived: true, token: token)
                self.addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Archived the read-aloud thread. It collapses out of the channel list but stays readable."
                ))
            } catch {
                // Surface this in the voice log rather than only the general log:
                // a thread left open after the announcer leaves is visible to the
                // whole server, so a silent failure here is worth noticing.
                self.addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Could not archive the read-aloud thread: \(error.localizedDescription)"
                ))
                self.logs.append("⚠️ Could not archive the Announcer read-aloud thread: \(error.localizedDescription)")
            }
        }
    }

    /// Whether `event` is a message in the live read-aloud thread that should be
    /// spoken. Bots and the app's own posts are excluded upstream in
    /// `forwardMessageToVoiceAnnouncer`; this adds the thread-specific limits.
    func shouldSpeakAnnouncerThreadMessage(_ event: GatewayMessageCreateEvent, now: Date = Date()) -> Bool {
        guard let threadID = announcerReadAloudThreadID, event.channelID == threadID else { return false }
        let trimmed = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count <= Self.announcerThreadMaxCharacters else { return false }
        // Commands are for the bot, not for the room.
        let commandPrefix = settings.prefix.trimmingCharacters(in: .whitespaces)
        if !commandPrefix.isEmpty, trimmed.hasPrefix(commandPrefix) { return false }
        guard !trimmed.hasPrefix("/") else { return false }
        if let last = announcerThreadLastSpokenAt[event.userID],
           now.timeIntervalSince(last) < Self.announcerThreadPerUserCooldown {
            return false
        }
        return true
    }

    /// Records that `userID` was just read aloud, starting their cooldown.
    func noteAnnouncerThreadSpoken(userID: String, now: Date = Date()) {
        announcerThreadLastSpokenAt[userID] = now
        // The map only ever holds people who posted during this session, but
        // drop stale entries so a long session doesn't accumulate them.
        let cutoff = now.addingTimeInterval(-Self.announcerThreadPerUserCooldown * 20)
        announcerThreadLastSpokenAt = announcerThreadLastSpokenAt.filter { $0.value > cutoff }
    }
}
