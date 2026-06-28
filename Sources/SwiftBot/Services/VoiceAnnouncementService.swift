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
                await onDebug?("Rendering speech audio for Discord.")
                // Render the full utterance to one buffer, then stream it out in
                // 20 ms frames. (Per-chunk resampling distorts the audio because
                // AVAudioConverter's resampler state can't be reset mid-stream,
                // so we render-then-play rather than convert-as-we-go.)
                let rendered = try await renderWithTimeout(text: next.text, seconds: 30.0)
                await onDebug?("Sending speech audio to Discord.")
                try await playback.speak(pcm: rendered)
                await onDebug?("Finished Discord speech (\(next.text.count) chars).")
                recordRecent(next)
            } catch {
                Self.logger.error("announcement failed: \(error.localizedDescription)")
                await onDebug?("Discord speech failed: \(error.localizedDescription)")
            }
        }
    }

    /// Render `text` to a single PCM buffer, bounded by `seconds` so a hung
    /// synthesiser can't stall the whole announcement queue. The voice is passed
    /// by identifier because `AVSpeechSynthesisVoice` isn't `Sendable`; the
    /// result stays wrapped in `SendableAudioBuffer` so the non-Sendable buffer
    /// can cross to the playback actor safely.
    private func renderWithTimeout(text: String, seconds: Double) async throws -> SendableAudioBuffer {
        let voiceID = voice?.identifier
        return try await withThrowingTaskGroup(of: SendableAudioBuffer.self) { group in
            group.addTask { [ttsSource] in
                let resolved = voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
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
        Task { await onRecentChange?(copy) }
    }
}
