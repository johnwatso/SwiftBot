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

    /// Test seam: renders `(text, voiceIdentifier)` to a buffer in place of
    /// the real `VoiceTTSSource` pipeline.
    typealias RenderOverride = @Sendable (String, String?) async throws -> SendableAudioBuffer

    private let playback: any AnnouncementPlayback
    private let ttsSource: VoiceTTSSource
    private let renderOverride: RenderOverride?
    private let daveNotReadyRetryDelay: Duration
    private var voice: AVSpeechSynthesisVoice?
    /// In-flight engine warm-up render; the drain loop awaits it before the
    /// first real render so the two never run concurrently.
    private var prewarmTask: Task<Void, Never>?
    private var prewarmedVoiceID: String??
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

    init(
        playback: any AnnouncementPlayback,
        daveNotReadyRetryDelay: Duration = .seconds(1),
        renderOverride: RenderOverride? = nil
    ) throws {
        self.playback = playback
        self.ttsSource = try VoiceTTSSource()
        self.daveNotReadyRetryDelay = daveNotReadyRetryDelay
        self.renderOverride = renderOverride
        self.voice = VoiceTTSSource.preferredEnglishVoice()
    }

    /// Load the speech engine and the selected voice's assets ahead of the
    /// first real announcement. The first AVSpeech render after launch can pay
    /// 1s+ of voice-asset loading; a token render at connect time moves that
    /// cost off the first spoken message. Re-runs only when the voice changes.
    func prewarm() {
        let voiceID = voice?.identifier
        guard prewarmedVoiceID != .some(voiceID) else { return }
        prewarmedVoiceID = .some(voiceID)
        guard renderOverride == nil else { return }
        prewarmTask = Task { [weak self] in
            _ = try? await self?.renderWithTimeout(text: "ok", seconds: 10.0, voiceIdentifier: voiceID)
        }
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

    /// Called by the owner when the voice pipeline reports that secure media
    /// became ready again mid-connection (a DAVE re-key or downgrade
    /// finished), so reads paused on `daveNotReady` resume without waiting
    /// for a full reconnect.
    func resumeAfterMediaReady() async {
        guard paused else { return }
        await setPaused(false)
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

    private struct RenderedBatch {
        let batch: [Announcement]
        let speechText: String
        let audio: SendableAudioBuffer
    }

    private enum PrefetchOutcome {
        case rendered(RenderedBatch)
        case failed([Announcement])
    }

    private func drain() async {
        draining = true
        await publishHealth(phase: paused ? .paused : .queued)
        // Let an in-flight engine warm-up finish so two renders never overlap.
        if let prewarm = prewarmTask {
            await prewarm.value
            prewarmTask = nil
        }
        var prefetched: RenderedBatch?
        while !queue.isEmpty || prefetched != nil {
            if paused {
                if let pending = prefetched {
                    requeue(pending.batch)
                    prefetched = nil
                    await onQueueChange?(queue)
                }
                break
            }

            // Take the batch rendered during the previous playback if there is
            // one, otherwise render the next batch in the foreground.
            let current: RenderedBatch
            if let pending = prefetched {
                prefetched = nil
                current = pending
            } else {
                let batch = nextBatch()
                guard !batch.isEmpty else { break }
                let speechText = coalescedSpeech(for: batch)
                await onQueueChange?(queue)
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
                do {
                    let rendered = try await renderSpeechAudio(text: speechText)
                    current = RenderedBatch(batch: batch, speechText: speechText, audio: rendered)
                } catch {
                    await handleDrainFailure(error, batch: batch)
                    continue
                }
            }

            // Render the following batch while this one streams out, so
            // back-to-back announcements don't serialize TTS synthesis behind
            // playback. Only one render is ever in flight at a time.
            var prefetchTask: Task<PrefetchOutcome, Never>?
            if !queue.isEmpty {
                let nextItems = nextBatch()
                if !nextItems.isEmpty {
                    let nextText = coalescedSpeech(for: nextItems)
                    await onQueueChange?(queue)
                    prefetchTask = Task {
                        do {
                            let rendered = try await self.renderSpeechAudio(text: nextText)
                            return .rendered(RenderedBatch(batch: nextItems, speechText: nextText, audio: rendered))
                        } catch {
                            return .failed(nextItems)
                        }
                    }
                }
            }

            do {
                await publishHealth(
                    phase: .sending,
                    activeStartedAt: Date(),
                    activeCharacterCount: current.speechText.count,
                    lastBatchSize: current.batch.count
                )
                await onDebug?("Sending speech audio to Discord.")
                try await playback.speak(pcm: current.audio)
                await onDebug?("Finished Discord speech (\(current.speechText.count) chars, \(current.batch.count) message\(current.batch.count == 1 ? "" : "s")).")
                for item in current.batch {
                    retryCounts[item.id] = nil
                    recordRecent(item)
                }
                await publishHealth(
                    phase: (queue.isEmpty && prefetchTask == nil) ? .idle : .queued,
                    retryStreak: 0,
                    lastSpokenAt: Date(),
                    activeStartedAt: nil,
                    activeCharacterCount: nil,
                    lastBatchSize: current.batch.count
                )
            } catch {
                // Reclaim the prefetched items first so nothing is lost, then
                // requeue the failed batch ahead of them (requeue inserts at
                // the front, so the original order is preserved).
                if let task = prefetchTask {
                    switch await task.value {
                    case .rendered(let next): requeue(next.batch)
                    case .failed(let items): requeue(items)
                    }
                    await onQueueChange?(queue)
                }
                await handleDrainFailure(error, batch: current.batch)
                continue
            }

            if let task = prefetchTask {
                switch await task.value {
                case .rendered(let next):
                    prefetched = next
                case .failed(let items):
                    // Requeue and let the foreground path retry the render;
                    // if it fails again the normal failure handling applies.
                    requeue(items)
                    await onQueueChange?(queue)
                }
            }
        }
        draining = false
        await publishHealth(phase: paused ? .paused : (queue.isEmpty ? .idle : .queued))
    }

    private func handleDrainFailure(_ error: Error, batch: [Announcement]) async {
        guard let first = batch.first else { return }
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
                await onDebug?("Discord speech paused while secure media refreshes; retrying.")
                try? await Task.sleep(for: daveNotReadyRetryDelay)
                return
            }
            // A secure-media refresh is outlasting the quick retry loop (e.g.
            // a mid-call MLS re-key). Keep the batch queued and pause; the
            // media-ready signal from the voice pipeline resumes the drain,
            // and the pipeline's own watchdog fails the connection if the
            // refresh never completes.
            retryCounts[first.id] = nil
            requeue(batch)
            await onQueueChange?(queue)
            paused = true
            await onDebug?("Discord speech is waiting for secure media to finish refreshing; queued reads resume automatically.")
            await publishHealth(
                phase: .recovering,
                retryStreak: health.retryStreak + 1,
                lastFailureAt: Date(),
                lastFailureReason: error.localizedDescription
            )
            return
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
            return
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
            let rendered = try await renderWithTimeout(
                text: text,
                seconds: 30.0,
                voiceIdentifier: selectedVoiceID
            )
            return try AnnouncerAudioGuardrails.validateAndRepair(rendered.buffer)
        } catch {
            guard let fallbackVoiceID, fallbackVoiceID != selectedVoiceID else { throw error }
            await onDebug?("Selected speech voice produced unusable audio; retrying with fallback voice.")
            let rendered = try await renderWithTimeout(
                text: text,
                seconds: 30.0,
                voiceIdentifier: fallbackVoiceID
            )
            return try AnnouncerAudioGuardrails.validateAndRepair(rendered.buffer)
        }
    }

    private func renderWithTimeout(
        text: String,
        seconds: Double,
        voiceIdentifier: String?
    ) async throws -> SendableAudioBuffer {
        if let renderOverride {
            return try await renderOverride(text, voiceIdentifier)
        }
        return try await withThrowingTaskGroup(of: SendableAudioBuffer.self) { group in
            group.addTask { [ttsSource] in
                let resolved = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
                let buffer = try await ttsSource.render(
                    text: text,
                    voice: resolved
                )
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
