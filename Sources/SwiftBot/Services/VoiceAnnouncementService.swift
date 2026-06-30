import AVFoundation
import Foundation
import OSLog

/// Serializes spoken announcements over a `VoicePlaybackService`. Queues
/// incoming text, renders each via `VoiceTTSSource`, and drains them one at a
/// time so announcements never overlap.
actor VoiceAnnouncementService {
    private static let logger = Logger(subsystem: "com.swiftbot", category: "voice.announce")

    struct Announcement: Sendable, Equatable {
        let id: UUID
        let text: String
        let createdAt: Date

        init(text: String) {
            self.id = UUID()
            self.text = text
            self.createdAt = Date()
        }
    }

    private let playback: VoicePlaybackService
    private let ttsSource: VoiceTTSSource
    private var voice: AVSpeechSynthesisVoice?
    private var queue: [Announcement] = []
    private var draining: Bool = false
    private var paused: Bool = false
    private var recent: [Announcement] = []
    private let recentLimit: Int = 25
    private let maxQueueDepth: Int = 20
    private let coalesceDelay: Duration = .milliseconds(450)
    private let maxCoalescedAnnouncements: Int = 4
    private let maxCoalescedCharacters: Int = 420
    private var retryCounts: [UUID: Int] = [:]
    private var drainStartTask: Task<Void, Never>?
    private var health = VoiceAnnouncerHealth()

    private var onQueueChange: (@Sendable ([Announcement]) async -> Void)?
    private var onRecentChange: (@Sendable ([Announcement]) async -> Void)?
    private var onHealthChange: (@Sendable (VoiceAnnouncerHealth) async -> Void)?
    private var onDebug: (@Sendable (String) async -> Void)?

    init(playback: VoicePlaybackService) throws {
        self.playback = playback
        self.ttsSource = try VoiceTTSSource()
        self.voice = VoiceTTSSource.preferredEnglishVoice()
    }

    func setVoice(_ voice: AVSpeechSynthesisVoice?) {
        self.voice = voice
    }

    func setOnQueueChange(_ handler: @escaping @Sendable ([Announcement]) async -> Void) {
        onQueueChange = handler
    }

    func setOnRecentChange(_ handler: @escaping @Sendable ([Announcement]) async -> Void) {
        onRecentChange = handler
    }

    func setOnHealthChange(_ handler: @escaping @Sendable (VoiceAnnouncerHealth) async -> Void) async {
        onHealthChange = handler
        await onHealthChange?(health)
    }

    func setOnDebug(_ handler: @escaping @Sendable (String) async -> Void) {
        onDebug = handler
    }

    var pending: [Announcement] { queue }
    var recentHistory: [Announcement] { recent }
    var healthSnapshot: VoiceAnnouncerHealth { health }

    func setPaused(_ paused: Bool) async {
        self.paused = paused
        await publishHealth(phase: paused ? .paused : (queue.isEmpty ? .idle : .queued))
        if !paused, !queue.isEmpty, !draining {
            scheduleDrain()
        }
    }

    func clearPending() async {
        drainStartTask?.cancel()
        drainStartTask = nil
        queue.removeAll()
        retryCounts.removeAll()
        await onQueueChange?(queue)
        await publishHealth(phase: paused ? .paused : .idle)
    }

    func markRecovering(_ reason: String) async {
        paused = true
        await onDebug?("Discord speech recovery started: \(reason).")
        await publishHealth(
            phase: .recovering,
            retryStreak: health.retryStreak,
            lastFailureReason: reason,
            lastRecoveryAt: Date()
        )
    }

    func enqueue(_ text: String) async {
        guard let spoken = AnnouncerSpeechSanitizer.sanitized(text) else {
            await onDebug?("Skipped Discord speech because the message had no readable text.")
            return
        }
        let announcement = Announcement(text: spoken)
        if queue.count >= maxQueueDepth {
            let overflow = queue.count - maxQueueDepth + 1
            let removed = queue.prefix(overflow)
            queue.removeFirst(overflow)
            for item in removed {
                retryCounts[item.id] = nil
            }
        }
        queue.append(announcement)
        // Log the event, not the content: the message text is kept out of the
        // diagnostics log (it still appears in the Recent list for the UI).
        await onDebug?("Queued Discord speech (\(spoken.count) chars); queue depth \(queue.count).")
        await onQueueChange?(queue)
        await publishHealth(phase: paused ? .paused : .queued, lastQueuedAt: Date())
        if !draining, !paused {
            scheduleDrain()
        }
    }

    private func scheduleDrain() {
        guard drainStartTask == nil else { return }
        let delay = coalesceDelay
        drainStartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.beginScheduledDrain()
        }
    }

    private func beginScheduledDrain() async {
        drainStartTask = nil
        guard !paused, !draining, !queue.isEmpty else {
            await publishHealth(phase: paused ? .paused : (queue.isEmpty ? .idle : .queued))
            return
        }
        await drain()
    }

    private func drain() async {
        draining = true
        await publishHealth(phase: paused ? .paused : .queued)
        while !queue.isEmpty {
            if paused { break }
            let batch = nextBatch()
            guard let first = batch.first else { break }
            let speechText = coalescedSpeech(for: batch)
            await onQueueChange?(queue)
            do {
                await publishHealth(
                    phase: .rendering,
                    activeStartedAt: Date(),
                    activeCharacterCount: speechText.count,
                    lastBatchSize: batch.count
                )
                await onDebug?("Rendering speech audio for Discord.")
                // Render the full utterance to one buffer, then stream it out in
                // 20 ms frames. (Per-chunk resampling distorts the audio because
                // AVAudioConverter's resampler state can't be reset mid-stream,
                // so we render-then-play rather than convert-as-we-go.)
                let rendered = try await renderSpeechAudio(text: speechText)
                await publishHealth(
                    phase: .sending,
                    activeStartedAt: Date(),
                    activeCharacterCount: speechText.count,
                    lastBatchSize: batch.count
                )
                await onDebug?("Sending speech audio to Discord.")
                try await playback.speak(pcm: rendered)
                await onDebug?("Finished Discord speech (\(speechText.count) chars, \(batch.count) message\(batch.count == 1 ? "" : "s")).")
                for item in batch {
                    retryCounts[item.id] = nil
                    recordRecent(item)
                }
                await publishHealth(
                    phase: queue.isEmpty ? .idle : .queued,
                    retryStreak: 0,
                    lastSpokenAt: Date(),
                    activeStartedAt: nil,
                    activeCharacterCount: nil,
                    lastBatchSize: batch.count
                )
            } catch {
                if case VoicePipelineError.daveNotReady = error {
                    let retries = retryCounts[first.id, default: 0]
                    if retries < 5 {
                        retryCounts[first.id] = retries + 1
                        requeue(batch)
                        await onQueueChange?(queue)
                        await publishHealth(
                            phase: .recovering,
                            retryStreak: retries + 1,
                            lastFailureAt: Date(),
                            lastFailureReason: error.localizedDescription
                        )
                        await onDebug?("Discord speech paused while DAVE media encryption refreshes; retrying.")
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                    retryCounts[first.id] = nil
                }
                if isReconnectablePlaybackError(error) {
                    requeue(batch)
                    await onQueueChange?(queue)
                    await onDebug?("Discord speech paused while the voice connection recovers.")
                    paused = true
                    await publishHealth(
                        phase: .recovering,
                        retryStreak: health.retryStreak + 1,
                        lastFailureAt: Date(),
                        lastFailureReason: error.localizedDescription
                    )
                    continue
                }
                Self.logger.error("announcement failed: \(error.localizedDescription)")
                await onDebug?("Discord speech failed: \(error.localizedDescription)")
                await publishHealth(
                    phase: .failed,
                    retryStreak: health.retryStreak + 1,
                    lastFailureAt: Date(),
                    lastFailureReason: error.localizedDescription,
                    activeStartedAt: nil,
                    activeCharacterCount: nil
                )
            }
        }
        draining = false
        await publishHealth(phase: paused ? .paused : (queue.isEmpty ? .idle : .queued))
    }

    private func isReconnectablePlaybackError(_ error: Error) -> Bool {
        switch error {
        case VoicePipelineError.notConnected, VoicePipelineError.socketClosed:
            return true
        default:
            return false
        }
    }

    /// Render `text` to a single PCM buffer, bounded by `seconds` so a hung
    /// synthesiser can't stall the whole announcement queue. The voice is passed
    /// by identifier because `AVSpeechSynthesisVoice` isn't `Sendable`; the
    /// result stays wrapped in `SendableAudioBuffer` so the non-Sendable buffer
    /// can cross to the playback actor safely.
    private func nextBatch() -> [Announcement] {
        guard !queue.isEmpty else { return [] }
        var batch = [queue.removeFirst()]
        var combined = batch[0].text
        while batch.count < maxCoalescedAnnouncements, !queue.isEmpty {
            let candidate = queue[0]
            let nextCombined = combined + ". " + candidate.text
            guard nextCombined.count <= maxCoalescedCharacters else { break }
            combined = nextCombined
            batch.append(queue.removeFirst())
        }
        return batch
    }

    private func coalescedSpeech(for batch: [Announcement]) -> String {
        batch.map(\.text).joined(separator: ". ")
    }

    private func requeue(_ batch: [Announcement]) {
        queue.insert(contentsOf: batch, at: 0)
    }

    private func renderSpeechAudio(text: String) async throws -> SendableAudioBuffer {
        let selectedVoiceID = voice?.identifier
        let fallbackVoiceID = VoiceTTSSource.preferredEnglishVoice()?.identifier
        do {
            let rendered = try await renderWithTimeout(text: text, seconds: 30.0, voiceIdentifier: selectedVoiceID)
            return try AnnouncerAudioGuardrails.validateAndRepair(rendered.buffer)
        } catch {
            guard let fallbackVoiceID, fallbackVoiceID != selectedVoiceID else { throw error }
            await onDebug?("Selected speech voice produced unusable audio; retrying with fallback voice.")
            let rendered = try await renderWithTimeout(text: text, seconds: 30.0, voiceIdentifier: fallbackVoiceID)
            return try AnnouncerAudioGuardrails.validateAndRepair(rendered.buffer)
        }
    }

    private func renderWithTimeout(text: String, seconds: Double, voiceIdentifier: String?) async throws -> SendableAudioBuffer {
        return try await withThrowingTaskGroup(of: SendableAudioBuffer.self) { group in
            group.addTask { [ttsSource] in
                let resolved = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
                let buffer = try await ttsSource.render(text: text, voice: resolved)
                return SendableAudioBuffer(buffer: buffer)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw VoicePipelineError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw VoicePipelineError.timeout }
            return first
        }
    }

    private func recordRecent(_ announcement: Announcement) {
        recent.insert(announcement, at: 0)
        if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }
        let copy = recent
        health.recentCount = recent.count
        Task { await onRecentChange?(copy) }
    }

    private func publishHealth(
        phase: VoiceAnnouncerPhase? = nil,
        retryStreak: Int? = nil,
        lastQueuedAt: Date? = nil,
        lastSpokenAt: Date? = nil,
        lastFailureAt: Date? = nil,
        lastFailureReason: String? = nil,
        lastRecoveryAt: Date? = nil,
        activeStartedAt: Date? = nil,
        activeCharacterCount: Int? = nil,
        lastBatchSize: Int? = nil
    ) async {
        if let phase { health.phase = phase }
        health.queueDepth = queue.count
        health.recentCount = recent.count
        health.isPaused = paused
        health.isDraining = draining
        if let retryStreak { health.retryStreak = retryStreak }
        if let lastQueuedAt { health.lastQueuedAt = lastQueuedAt }
        if let lastSpokenAt { health.lastSpokenAt = lastSpokenAt }
        if let lastFailureAt { health.lastFailureAt = lastFailureAt }
        if let lastFailureReason { health.lastFailureReason = lastFailureReason }
        if let lastRecoveryAt { health.lastRecoveryAt = lastRecoveryAt }
        health.activeStartedAt = activeStartedAt
        health.activeCharacterCount = activeCharacterCount
        if let lastBatchSize { health.lastBatchSize = lastBatchSize }
        await onHealthChange?(health)
    }
}
