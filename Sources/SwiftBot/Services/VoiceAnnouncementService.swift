import AVFoundation
import Foundation
import OSLog

/// A one-shot race between an announcement playback operation and its deadline.
/// It intentionally does not use a structured task group: structured
/// cancellation waits for every child to return, which means a non-cooperative
/// network implementation can otherwise hold the serial announcer queue
/// forever after its deadline has passed.
private final class PlaybackDeadlineRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func installContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        let completed: Result<Void, Error>?
        lock.lock()
        completed = result
        if completed == nil {
            self.continuation = continuation
        }
        lock.unlock()
        if let completed {
            continuation.resume(with: completed)
        }
    }

    func installOperation(_ task: Task<Void, Never>) {
        let shouldCancel: Bool
        lock.lock()
        shouldCancel = result != nil
        if !shouldCancel {
            operationTask = task
        }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func installTimeout(_ task: Task<Void, Never>) {
        let shouldCancel: Bool
        lock.lock()
        shouldCancel = result != nil
        if !shouldCancel {
            timeoutTask = task
        }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func succeed() {
        resolve(.success(()), cancellingOperation: false)
    }

    func fail(_ error: Error) {
        resolve(.failure(error), cancellingOperation: false)
    }

    func timeOut() {
        resolve(.failure(VoicePipelineError.playbackTimedOut), cancellingOperation: true)
    }

    func cancel() {
        resolve(.failure(CancellationError()), cancellingOperation: true)
    }

    private func resolve(_ outcome: Result<Void, Error>, cancellingOperation: Bool) {
        let continuation: CheckedContinuation<Void, Error>?
        let operation: Task<Void, Never>?
        let timeout: Task<Void, Never>?
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        continuation = self.continuation
        self.continuation = nil
        operation = cancellingOperation ? operationTask : nil
        operationTask = nil
        timeout = timeoutTask
        timeoutTask = nil
        lock.unlock()

        timeout?.cancel()
        operation?.cancel()
        continuation?.resume(with: outcome)
    }
}

/// Serializes spoken announcements over a `VoicePlaybackService`. Queues
/// incoming text, renders each via `VoiceTTSSource`, and drains them one at a
/// time so announcements never overlap.
actor VoiceAnnouncementService {
    private static let logger = Logger(subsystem: "com.swiftbot", category: "voice.announce")

    /// Headroom between a read's own deadline and the point the owner's health
    /// watchdog calls it stalled, so the announcer's bounded retry/recovery
    /// path always gets to run first.
    static let stallGraceSeconds: TimeInterval = 20

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) +
            Double(duration.components.attoseconds) / 1e18
    }

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
    private let speechRenderTimeout: Duration
    private let speechPlaybackTimeout: Duration
    private var voice: AVSpeechSynthesisVoice?
    /// Lazily resolved fallback voice for a render the selected voice fails.
    private var fallbackVoiceID: String?
    /// In-flight engine warm-up render; the drain loop awaits it before the
    /// first real render so the two never run concurrently.
    private var prewarmTask: Task<Void, Never>?
    private var prewarmedVoiceID: String??
    private var queue: [Announcement] = []
    private var draining: Bool = false
    private var paused: Bool = false
    /// Distinguishes a pause the announcer inflicted on itself after a failure
    /// — which nothing will lift unless the owner notices — from one the owner
    /// asked for deliberately (a handshake in progress, the empty-channel
    /// grace period). Only the former is a stall the health watchdog should
    /// bound; reporting both as `.paused` is what let a failed read park the
    /// queue silently and indefinitely.
    private var pausedForRecovery: Bool = false
    /// Advances when a newer voice path tells the announcer to resume: either
    /// DAVE media becomes ready or AppModel finishes an automatic rejoin. A
    /// playback attempt from an older generation may finish with a stale
    /// recoverable error, but must never put the fresh queue back into a
    /// permanent pause.
    private var recoveryGeneration: UInt64 = 0
    private var recent: [Announcement] = []
    private let recentLimit: Int = 25
    private let maxQueueDepth: Int = 20
    private let coalesceDelay: Duration = .milliseconds(450)
    private let maxCoalescedAnnouncements: Int = 4
    private let maxCoalescedCharacters: Int = 420
    private var retryCounts: [UUID: Int] = [:]
    /// Rendering can fail transiently while macOS wakes a voice asset or the
    /// synthesizer restarts. Keep a small independent budget so a TTS failure
    /// does not silently discard the announcement before it reaches playback.
    private var renderRetryCounts: [UUID: Int] = [:]
    private var drainStartTask: Task<Void, Never>?
    private var health = VoiceAnnouncerHealth()

    private var onQueueChange: (@Sendable ([Announcement]) async -> Void)?
    private var onRecentChange: (@Sendable ([Announcement]) async -> Void)?
    private var onHealthChange: (@Sendable (VoiceAnnouncerHealth) async -> Void)?
    private var onDebug: (@Sendable (String) async -> Void)?

    init(
        playback: any AnnouncementPlayback,
        daveNotReadyRetryDelay: Duration = .seconds(1),
        speechRenderTimeout: Duration = .seconds(30),
        speechPlaybackTimeout: Duration = .seconds(45),
        renderOverride: RenderOverride? = nil
    ) throws {
        self.playback = playback
        self.ttsSource = try VoiceTTSSource()
        self.daveNotReadyRetryDelay = daveNotReadyRetryDelay
        self.speechRenderTimeout = speechRenderTimeout
        self.speechPlaybackTimeout = speechPlaybackTimeout
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
            _ = try? await self?.renderWithTimeout(text: "ok", timeout: .seconds(10), voiceIdentifier: voiceID)
        }
    }

    func setVoice(_ voice: AVSpeechSynthesisVoice?) {
        guard self.voice?.identifier != voice?.identifier else { return }
        self.voice = voice
        // The fallback is resolved relative to the selection, so a stale cache
        // could name the newly selected voice as its own fallback.
        fallbackVoiceID = nil
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

    /// The phase to report while the queue is held, or nil when it isn't.
    /// `.recovering` is bounded by the owner's health watchdog and `.paused`
    /// is not, so the distinction decides whether a stuck queue ever gets
    /// rescued.
    private var pausedPhase: VoiceAnnouncerPhase? {
        guard paused else { return nil }
        return pausedForRecovery ? .recovering : .paused
    }

    /// The phase for "there is queued work and nothing is actively reading it".
    /// Returns nil while a read is genuinely in flight, so bookkeeping like a
    /// newly queued message can't relabel it — that relabelling discarded the
    /// active read's start time and left the watchdog measuring the wrong
    /// clock in both directions.
    private var idleOrQueuedPhase: VoiceAnnouncerPhase? {
        if let pausedPhase { return pausedPhase }
        if draining, health.phase == .rendering || health.phase == .sending { return nil }
        return queue.isEmpty ? .idle : .queued
    }

    func setPaused(_ paused: Bool) async {
        if !paused {
            recoveryGeneration &+= 1
        }
        self.paused = paused
        // An explicit request from the owner, in either direction, ends any
        // self-inflicted recovery pause: the owner is driving now.
        pausedForRecovery = false
        await publishHealth(phase: idleOrQueuedPhase)
        if !paused, !queue.isEmpty, !draining {
            scheduleDrain()
        }
    }

    /// Called by the owner when the voice pipeline reports that secure media
    /// became ready again mid-connection (a DAVE re-key or downgrade
    /// finished), so reads paused on `daveNotReady` resume without waiting
    /// for a full reconnect.
    func resumeAfterMediaReady() async {
        if paused {
            await setPaused(false)
        } else {
            // Preserve a DAVE-ready signal that races a stale final retry
            // before that retry has set paused = true.
            recoveryGeneration &+= 1
        }
    }

    func clearPending() async {
        drainStartTask?.cancel()
        drainStartTask = nil
        queue.removeAll()
        retryCounts.removeAll()
        renderRetryCounts.removeAll()
        await onQueueChange?(queue)
        await publishHealth(phase: pausedPhase ?? .idle)
    }

    func markRecovering(_ reason: String) async {
        paused = true
        pausedForRecovery = true
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
                renderRetryCounts[item.id] = nil
            }
        }
        queue.append(announcement)
        // Log the event, not the content: the message text is kept out of the
        // diagnostics log (it still appears in the Recent list for the UI).
        await onDebug?("Queued Discord speech (\(spoken.count) chars); queue depth \(queue.count).")
        await onQueueChange?(queue)
        await publishHealth(phase: idleOrQueuedPhase, lastQueuedAt: Date())
        if !draining, !paused {
            // The coalesce window only pays for itself when there is something
            // to coalesce with. A message arriving into an idle queue starts
            // rendering immediately; anything that lands behind it still gets
            // batched by `nextBatch` while this one plays.
            scheduleDrain(immediately: queue.count == 1)
        }
    }

    private func scheduleDrain(immediately: Bool = false) {
        guard drainStartTask == nil else { return }
        let delay = immediately ? Duration.zero : coalesceDelay
        drainStartTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.beginScheduledDrain()
        }
    }

    private func beginScheduledDrain() async {
        drainStartTask = nil
        guard !paused, !draining, !queue.isEmpty else {
            await publishHealth(phase: idleOrQueuedPhase)
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
        await publishHealth(phase: idleOrQueuedPhase)
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
                    activeExpiresAt: Date().addingTimeInterval(
                        Self.seconds(speechRenderTimeout) + Self.stallGraceSeconds
                    ),
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
                    await handleDrainFailure(error, batch: batch, stage: .rendering)
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

            var recoveryGenerationAtPlaybackStart = recoveryGeneration
            let playbackDeadline = playbackTimeout(for: current.audio)
            do {
                await publishHealth(
                    phase: .sending,
                    activeStartedAt: Date(),
                    activeCharacterCount: current.speechText.count,
                    activeExpiresAt: Date().addingTimeInterval(
                        Self.seconds(playbackDeadline) + Self.stallGraceSeconds
                    ),
                    lastBatchSize: current.batch.count
                )
                await onDebug?("Sending speech audio to Discord.")
                recoveryGenerationAtPlaybackStart = recoveryGeneration
                try await speakWithTimeout(current.audio, timeout: playbackDeadline)
                await onDebug?("Finished Discord speech (\(current.speechText.count) chars, \(current.batch.count) message\(current.batch.count == 1 ? "" : "s")).")
                for item in current.batch {
                    retryCounts[item.id] = nil
                    renderRetryCounts[item.id] = nil
                    recordRecent(item)
                }
                await publishHealth(
                    phase: (queue.isEmpty && prefetchTask == nil) ? .idle : .queued,
                    retryStreak: 0,
                    lastSpokenAt: Date(),
                    clearActiveRead: true,
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
                await handleDrainFailure(
                    error,
                    batch: current.batch,
                    stage: .playback,
                    recoveryGenerationAtPlaybackStart: recoveryGenerationAtPlaybackStart
                )
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
        await publishHealth(phase: idleOrQueuedPhase)
    }

    private enum DrainFailureStage {
        case rendering
        case playback
    }

    private func handleDrainFailure(
        _ error: Error,
        batch: [Announcement],
        stage: DrainFailureStage,
        recoveryGenerationAtPlaybackStart: UInt64? = nil
    ) async {
        guard let first = batch.first else { return }
        if stage == .rendering, isRetryableRenderError(error) {
            let retries = renderRetryCounts[first.id, default: 0]
            if retries < 2 {
                renderRetryCounts[first.id] = retries + 1
                requeue(batch)
                await onQueueChange?(queue)
                await publishHealth(
                    phase: .recovering,
                    retryStreak: retries + 1,
                    lastFailureAt: Date(),
                    lastFailureReason: error.localizedDescription,
                    clearActiveRead: true
                )
                await onDebug?("Discord speech rendering failed; retrying the queued read (\(retries + 1)/2).")
                try? await Task.sleep(for: .milliseconds(250 * (retries + 1)))
                return
            }
            renderRetryCounts[first.id] = nil
        }
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
                    lastFailureReason: error.localizedDescription,
                    clearActiveRead: true
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
            // `speak` can return a stale daveNotReady after DAVE has already
            // reported media-ready, or after a clean auto-rejoin has resumed
            // the announcer. A newer recovery generation means this failure
            // belongs to the old path. Set paused before the next suspension
            // point too, so a later ready/rejoin callback resumes normally.
            let recoveredDuringFinalAttempt = recoveryGenerationAtPlaybackStart
                .map { $0 != recoveryGeneration } ?? false
            paused = !recoveredDuringFinalAttempt
            pausedForRecovery = paused
            await onQueueChange?(queue)
            if !paused {
                await onDebug?("Discord speech recovered while its final secure-media retry completed; continuing queued reads.")
                await publishHealth(
                    phase: .queued,
                    lastFailureAt: Date(),
                    lastFailureReason: error.localizedDescription,
                    clearActiveRead: true
                )
                return
            }
            await onDebug?("Discord speech is waiting for secure media to finish refreshing; queued reads resume automatically.")
            await publishHealth(
                phase: .recovering,
                retryStreak: health.retryStreak + 1,
                lastFailureAt: Date(),
                lastFailureReason: error.localizedDescription,
                clearActiveRead: true
            )
            return
        }
        if isReconnectablePlaybackError(error) {
            requeue(batch)
            // A send started on the prior voice connection can finish after
            // AppModel has already connected a replacement and called
            // setPaused(false). Do not let that stale completion re-pause the
            // newly recovered queue.
            let recoveredDuringPlayback = recoveryGenerationAtPlaybackStart
                .map { $0 != recoveryGeneration } ?? false
            paused = !recoveredDuringPlayback
            pausedForRecovery = paused
            await onQueueChange?(queue)
            if !paused {
                await onDebug?("Discord speech recovery completed while a stale playback failure returned; continuing queued reads.")
                await publishHealth(
                    phase: .queued,
                    lastFailureAt: Date(),
                    lastFailureReason: error.localizedDescription,
                    clearActiveRead: true
                )
                return
            }
            if case VoicePipelineError.playbackTimedOut = error {
                await onDebug?("Discord speech playback exceeded its deadline; reconnecting the voice session before retrying the queued read.")
            } else {
                await onDebug?("Discord speech paused while the voice connection recovers.")
            }
            await publishHealth(
                phase: .recovering,
                retryStreak: health.retryStreak + 1,
                lastFailureAt: Date(),
                lastFailureReason: error.localizedDescription,
                clearActiveRead: true
            )
            return
        }
        for item in batch {
            retryCounts[item.id] = nil
            renderRetryCounts[item.id] = nil
        }
        Self.logger.error("announcement failed: \(error.localizedDescription)")
        await onDebug?("Discord speech failed: \(error.localizedDescription)")
        await publishHealth(
            phase: .failed,
            retryStreak: health.retryStreak + 1,
            lastFailureAt: Date(),
            lastFailureReason: error.localizedDescription,
            clearActiveRead: true
        )
    }

    private func isRetryableRenderError(_ error: Error) -> Bool {
        !(error is CancellationError)
    }

    private func isReconnectablePlaybackError(_ error: Error) -> Bool {
        switch error {
        case VoicePipelineError.notConnected, VoicePipelineError.socketClosed, VoicePipelineError.playbackTimedOut:
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
        let fallbackVoiceID = cachedFallbackVoiceID()
        do {
            let rendered = try await renderWithTimeout(
                text: text,
                timeout: speechRenderTimeout,
                voiceIdentifier: selectedVoiceID
            )
            return try AnnouncerAudioGuardrails.validateAndRepair(rendered.buffer)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let fallbackVoiceID, fallbackVoiceID != selectedVoiceID else { throw error }
            await onDebug?("Selected speech voice produced unusable audio; retrying with fallback voice.")
            let rendered = try await renderWithTimeout(
                text: text,
                timeout: speechRenderTimeout,
                voiceIdentifier: fallbackVoiceID
            )
            return try AnnouncerAudioGuardrails.validateAndRepair(rendered.buffer)
        }
    }

    /// `AVSpeechSynthesisVoice.speechVoices()` enumerates every installed voice
    /// (~190 on a stock machine, ~90 ms). That result only changes when the user
    /// installs or removes a voice, so it must not sit on the render path — it
    /// was being paid on every announcement purely to know the fallback.
    ///
    /// Resolved against the selected voice so the retry lands on a different
    /// engine. This used to call `preferredEnglishVoice()`, which returns the
    /// selected voice on a default configuration — the retry then re-entered
    /// the engine that had just failed, which meant there was no fallback at
    /// all whenever the failure was the engine rather than the utterance.
    private func cachedFallbackVoiceID() -> String? {
        if let fallbackVoiceID { return fallbackVoiceID }
        let resolved = VoiceTTSSource.fallbackEnglishVoice(excluding: voice?.identifier)?.identifier
        fallbackVoiceID = resolved
        return resolved
    }

    private func renderWithTimeout(
        text: String,
        timeout: Duration,
        voiceIdentifier: String?
    ) async throws -> SendableAudioBuffer {
        let renderOverride = self.renderOverride
        return try await withThrowingTaskGroup(of: SendableAudioBuffer.self) { group in
            group.addTask { [ttsSource, renderOverride] in
                if let renderOverride {
                    return try await renderOverride(text, voiceIdentifier)
                }
                let resolved = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
                let buffer = try await ttsSource.render(
                    text: text,
                    voice: resolved
                )
                return SendableAudioBuffer(buffer: buffer)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw VoicePipelineError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw VoicePipelineError.timeout }
            return first
        }
    }

    /// Playback is paced in real time, so the audio's own duration is a hard
    /// floor on how long `speak` legitimately takes; `speechPlaybackTimeout`
    /// is the slack on top of it. A flat deadline could not tell a wedged UDP
    /// write from a long read: at ~17 characters per second of speech, a
    /// single 1000-character message renders to about 56 seconds of audio and
    /// blew through the flat 45-second deadline every time. That failed the
    /// read, paused the queue, forced a voice reconnect, and then retried the
    /// same message into the same deadline until the recovery budget ran out.
    private func playbackTimeout(for audio: SendableAudioBuffer) -> Duration {
        let format = audio.buffer.format
        guard format.sampleRate > 0 else { return speechPlaybackTimeout }
        let seconds = Double(audio.buffer.frameLength) / format.sampleRate
        return speechPlaybackTimeout + .milliseconds(Int(seconds * 1000))
    }

    /// A stalled UDP write must not hold the serial announcement drain forever.
    /// `VoicePlaybackService` cooperates with cancellation by failing the stale
    /// session, which lets normal auto-rejoin recovery rebuild the transport.
    private func speakWithTimeout(_ audio: SendableAudioBuffer, timeout: Duration) async throws {
        let playback = self.playback
        let race = PlaybackDeadlineRace()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                race.installContinuation(continuation)
                let operation = Task {
                    do {
                        try await playback.speak(pcm: audio)
                        race.succeed()
                    } catch {
                        race.fail(error)
                    }
                }
                race.installOperation(operation)
                let deadline = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    race.timeOut()
                }
                race.installTimeout(deadline)
            }
        } onCancel: {
            race.cancel()
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
        activeExpiresAt: Date? = nil,
        clearActiveRead: Bool = false,
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
        // Only the start and the end of a read touch these. They used to be
        // assigned unconditionally, so every unrelated update — a message
        // arriving mid-read, most of all — erased the timestamps the watchdog
        // uses to spot a read that never finishes.
        if clearActiveRead {
            health.activeStartedAt = nil
            health.activeCharacterCount = nil
            health.activeExpiresAt = nil
        } else {
            if let activeStartedAt { health.activeStartedAt = activeStartedAt }
            if let activeCharacterCount { health.activeCharacterCount = activeCharacterCount }
            if let activeExpiresAt { health.activeExpiresAt = activeExpiresAt }
        }
        if let lastBatchSize { health.lastBatchSize = lastBatchSize }
        await onHealthChange?(health)
    }
}
