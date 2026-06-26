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
    private var recent: [Announcement] = []
    private let recentLimit: Int = 25

    private var onQueueChange: (@Sendable ([Announcement]) async -> Void)?
    private var onRecentChange: (@Sendable ([Announcement]) async -> Void)?
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

    func setOnDebug(_ handler: @escaping @Sendable (String) async -> Void) {
        onDebug = handler
    }

    var pending: [Announcement] { queue }
    var recentHistory: [Announcement] { recent }

    func enqueue(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let announcement = Announcement(text: trimmed)
        queue.append(announcement)
        // Log the event, not the content: the message text is kept out of the
        // diagnostics log (it still appears in the Recent list for the UI).
        await onDebug?("Queued Discord speech (\(trimmed.count) chars); queue depth \(queue.count).")
        await onQueueChange?(queue)
        if !draining {
            Task { await self.drain() }
        }
    }

    private func drain() async {
        draining = true
        defer { draining = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            await onQueueChange?(queue)
            do {
                await onDebug?("Rendering and streaming speech audio to Discord.")
                // Stream synthesis straight into playback so audio starts before
                // the whole utterance is rendered (lower latency).
                let stream = ttsSource.renderStream(text: next.text, voice: voice)
                try await playWithStallTimeout(stream: stream, stallSeconds: 15.0)
                await onDebug?("Finished Discord speech (\(next.text.count) chars).")
                recordRecent(next)
            } catch {
                Self.logger.error("announcement failed: \(error.localizedDescription)")
                await onDebug?("Discord speech failed: \(error.localizedDescription)")
            }
        }
    }

    /// Play `stream` with an inactivity watchdog: the timeout fires only when no
    /// audio frame is transmitted for `stallSeconds`, so a legitimately long
    /// message plays in full while a hung synthesiser or stalled network is still
    /// bounded. Cancelling playback terminates the render stream, which stops the
    /// underlying synthesiser.
    private func playWithStallTimeout(
        stream: AsyncThrowingStream<SendableAudioBuffer, Error>,
        stallSeconds: Double
    ) async throws {
        let progress = ProgressTracker()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [playback] in
                try await playback.speak(stream: stream, onProgress: { progress.tick() })
            }
            group.addTask {
                let clock = ContinuousClock()
                while true {
                    try await Task.sleep(for: .seconds(1))
                    if clock.now - progress.last > .seconds(stallSeconds) {
                        throw VoicePipelineError.timeout
                    }
                }
            }
            defer { group.cancelAll() }
            // First child to finish decides the outcome: playback returns on
            // success, the watchdog (or a playback error) throws otherwise.
            try await group.next()
        }
    }

    private func recordRecent(_ announcement: Announcement) {
        recent.insert(announcement, at: 0)
        if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }
        let copy = recent
        Task { await onRecentChange?(copy) }
    }
}

/// Thread-safe record of the last playback-progress timestamp, shared between
/// the playback task (which ticks it) and the stall watchdog (which reads it).
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _last: ContinuousClock.Instant = ContinuousClock().now

    var last: ContinuousClock.Instant {
        lock.lock(); defer { lock.unlock() }
        return _last
    }

    func tick() {
        let now = ContinuousClock().now
        lock.lock(); _last = now; lock.unlock()
    }
}
