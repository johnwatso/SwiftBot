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

    private var onQueueChange: (([Announcement]) async -> Void)?
    private var onRecentChange: (([Announcement]) async -> Void)?

    init(playback: VoicePlaybackService) throws {
        self.playback = playback
        self.ttsSource = try VoiceTTSSource()
        self.voice = VoiceTTSSource.preferredEnglishVoice()
    }

    func setVoice(_ voice: AVSpeechSynthesisVoice?) {
        self.voice = voice
    }

    func setOnQueueChange(_ handler: @escaping ([Announcement]) async -> Void) {
        onQueueChange = handler
    }

    func setOnRecentChange(_ handler: @escaping ([Announcement]) async -> Void) {
        onRecentChange = handler
    }

    var pending: [Announcement] { queue }
    var recentHistory: [Announcement] { recent }

    func enqueue(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let announcement = Announcement(text: trimmed)
        queue.append(announcement)
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
                let buffer = try await ttsSource.render(text: next.text, voice: voice)
                try await playback.speak(pcm: buffer)
                recordRecent(next)
            } catch {
                Self.logger.error("announcement failed: \(error.localizedDescription)")
            }
        }
    }

    private func recordRecent(_ announcement: Announcement) {
        recent.insert(announcement, at: 0)
        if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }
        let copy = recent
        Task { await onRecentChange?(copy) }
    }
}
