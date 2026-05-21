import AVFoundation
import Foundation

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
        voicePendingGuildID = guildID
        voicePendingChannelID = channelID
        voicePendingSessionID = nil
        voicePendingServerToken = nil
        voicePendingServerEndpoint = nil
        voiceConnectionStatus = .connecting
        await service.sendVoiceStateUpdate(guildID: guildID, channelID: channelID)

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
                    self.voiceConnectionStatus = .failed("Timed out waiting for Discord VOICE_SERVER_UPDATE.")
                }
            }
        }
    }

    /// Tear down the voice connection (sends VOICE_STATE_UPDATE with null
    /// channel, then closes the playback pipeline).
    func disconnectVoice() async {
        let guildID = voicePendingGuildID ?? settings.voice.guildID
        if !guildID.isEmpty {
            await service.sendVoiceStateUpdate(guildID: guildID, channelID: nil)
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
        guard event.guildID == voicePendingGuildID else { return }
        voicePendingServerToken = event.token
        voicePendingServerEndpoint = event.endpoint
        await beginVoicePipelineIfReady()
    }

    /// Hook called from `handleVoiceStateUpdate` (in AppModel+DiscordEvents)
    /// when a VOICE_STATE_UPDATE for our own bot user lands.
    func observeSelfVoiceStateUpdate(_ event: GatewayVoiceStateUpdateEvent) async {
        guard let botUserId, event.userID == botUserId else { return }
        guard event.guildID == voicePendingGuildID else { return }
        if case let .string(sessionID)? = event.rawMap["session_id"] {
            voicePendingSessionID = sessionID
            await beginVoicePipelineIfReady()
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
        do {
            try await voicePlaybackService.connect(server: info)
            voiceConnectionStatus = .connected
            voiceLog.append(VoiceEventLogEntry(
                time: Date(),
                description: "Voice pipeline connected to channel \(voicePendingChannelID ?? "?")"
            ))
        } catch {
            voiceConnectionStatus = .failed(error.localizedDescription)
            voiceLog.append(VoiceEventLogEntry(
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
        // The main settings save path lives elsewhere; mutations to
        // `settings` are observed via @Published. Most code in this project
        // relies on auto-persistence wired up at the AppModel level, so just
        // setting `settings.voice.*` is enough. This stub gives us a hook to
        // explicitly flush in the future if needed.
    }
}
