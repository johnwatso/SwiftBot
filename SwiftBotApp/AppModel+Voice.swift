import AVFoundation
import Foundation
import LibDave

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
        textChannelAnnouncerStorage = watcher
        let saved = settings.voice.watchedTextChannelID
        if !saved.isEmpty {
            Task { await watcher.setWatchedChannel(saved) }
        }
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
            return
        }
        await connectVoice(guildID: guildID, channelID: channelID)
    }

    func connectVoice(guildID: String, channelID: String) async {
        // The main gateway has to be live before voice can negotiate.
        guard status == .running else {
            voiceConnectionStatus = .failed("Bot is offline — click Start Bot first.")
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
        voiceConnectionStatus = .connecting
        addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: "Voice join requested for channel \(channelID)."))

        if let preflightFailure = await voiceChannelPreflightFailure(channelID: channelID) {
            voiceConnectionStatus = .failed(preflightFailure)
            addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: preflightFailure))
            return
        }

        let didSendJoin = await service.sendVoiceStateUpdate(guildID: guildID, channelID: channelID)
        guard didSendJoin else {
            let message = "Voice join failed before Discord acknowledged it: main gateway send was blocked or disconnected."
            voiceConnectionStatus = .failed(message)
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
                if self.voiceConnectionStatus == .connecting,
                   self.voicePendingGuildID == attemptGuildID {
                    let message = "Timed out waiting for Discord VOICE_STATE_UPDATE / VOICE_SERVER_UPDATE."
                    self.voiceConnectionStatus = .failed(message)
                    self.addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: message))
                }
            }
        }
    }

    /// Tear down the voice connection (sends VOICE_STATE_UPDATE with null
    /// channel, then closes the playback pipeline).
    func disconnectVoice() async {
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
        voiceConnectionStatus = .idle
    }

    /// Manually trigger an announcement (e.g. `/say` or the Test button in the
    /// Voice tab).
    func speakAnnouncement(_ text: String) async {
        guard let announcer = voiceAnnouncementService else { return }
        await announcer.enqueue(text)
    }

    /// Speak `text` through the Mac's local speakers using
    /// `AVSpeechSynthesizer` — no Discord voice connection involved. Used as
    /// a preview while the Discord voice path is blocked by DAVE.
    func speakLocallyPreview(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        let preferredIdentifier = settings.voice.preferredVoiceIdentifier
        if !preferredIdentifier.isEmpty,
           let v = AVSpeechSynthesisVoice(identifier: preferredIdentifier) {
            utterance.voice = v
        } else {
            utterance.voice = VoiceTTSSource.preferredEnglishVoice()
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        if localSpeechPreviewSynthesizer.isSpeaking {
            localSpeechPreviewSynthesizer.stopSpeaking(at: .immediate)
        }
        localSpeechPreviewSynthesizer.speak(utterance)
    }

    /// Apply a new watched text-channel selection from the UI.
    func setWatchedTextChannelForAnnouncer(_ channelID: String) async {
        settings.voice.watchedTextChannelID = channelID
        persistSettingsIfPossible()
        if let watcher = textChannelAnnouncer {
            await watcher.setWatchedChannel(channelID.isEmpty ? nil : channelID)
        }
    }

    /// Apply a new preferred-voice selection from the UI.
    func setPreferredAnnouncerVoice(_ identifier: String) async {
        settings.voice.preferredVoiceIdentifier = identifier
        persistSettingsIfPossible()
        if let announcer = voiceAnnouncementService {
            applyPreferredVoiceFromSettings(to: announcer)
        }
    }

    /// Forward a `MESSAGE_CREATE` event to the text-channel announcer. Called
    /// from `handleMessageCreate` so we don't have to re-subscribe to the
    /// dispatcher.
    func forwardMessageToVoiceAnnouncer(_ event: GatewayMessageCreateEvent) async {
        guard settings.voice.textChannelSourceEnabled else { return }
        guard !settings.voice.watchedTextChannelID.isEmpty else { return }
        guard event.channelID == settings.voice.watchedTextChannelID else { return }
        // Don't read SwiftBot's own messages to avoid feedback loops.
        if let botUserId, event.userID == botUserId { return }
        guard let watcher = textChannelAnnouncer else { return }
        await watcher.handle(event)
    }

    // MARK: - Gateway event handlers

    func handleVoiceServerUpdate(_ event: GatewayVoiceServerUpdateEvent) async {
        guard event.guildID == voicePendingGuildID else {
            if voicePendingGuildID != nil {
                addVoiceLogEntry(VoiceEventLogEntry(
                    time: Date(),
                    description: "Ignored VOICE_SERVER_UPDATE for guild \(event.guildID); waiting for \(voicePendingGuildID ?? "?")."
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
                    description: "Ignored VOICE_STATE_UPDATE for guild \(event.guildID); waiting for \(voicePendingGuildID ?? "?")."
                ))
            }
            return
        }
        guard let expectedBotUserId, event.userID == expectedBotUserId else {
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Observed VOICE_STATE_UPDATE for user \(event.userID); waiting for bot user \(expectedBotUserId ?? "unknown")."
            ))
            return
        }
        if case let .string(sessionID)? = event.rawMap["session_id"] {
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
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice pipeline connected to channel \(voicePendingChannelID ?? "?")"
            ))
        } catch {
            voiceConnectionStatus = .failed(error.localizedDescription)
            addVoiceLogEntry(VoiceEventLogEntry(
                time: Date(),
                description: "Voice pipeline connect failed: \(error.localizedDescription)"
            ))
        }
    }

    private func handleVoicePlaybackStatus(_ status: VoicePlaybackService.Status) async {
        switch status {
        case .idle:
            voiceConnectionStatus = .idle
        case .connecting:
            voiceConnectionStatus = .connecting
        case .connected:
            voiceConnectionStatus = .connected
        case .disconnecting:
            voiceConnectionStatus = .disconnecting
        case .failed(let reason):
            voiceConnectionStatus = .failed(reason)
        }
    }

    private func applyPreferredVoiceFromSettings(to announcer: VoiceAnnouncementService) {
        let identifier = settings.voice.preferredVoiceIdentifier
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

    private func discordIntValue(for key: String, in map: [String: DiscordJSON]) -> Int? {
        switch map[key] {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }
}
