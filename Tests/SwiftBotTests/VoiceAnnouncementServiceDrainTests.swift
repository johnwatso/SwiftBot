import AVFoundation
import XCTest
@testable import SwiftBot

final class VoiceAnnouncementServiceDrainTests: XCTestCase {

    /// Deliberately ignores cancellation until the test releases it. This
    /// models the old wedged UDP completion path and proves the announcement
    /// deadline is a true escape boundary rather than a structured task-group
    /// cancellation that waits indefinitely for the child.
    private actor NonCooperativePlayback: AnnouncementPlayback {
        private var entered = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        var hasEntered: Bool { entered }

        func speak(pcm wrapped: SendableAudioBuffer) async throws {
            entered = true
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func release() {
            let waiting = continuations
            continuations.removeAll()
            for continuation in waiting {
                continuation.resume()
            }
        }
    }

    private actor RenderAttemptCounter {
        private var attempts = 0

        func next() -> Int {
            attempts += 1
            return attempts
        }

        var count: Int { attempts }
    }

    private func makeAnnouncer(
        playback: FakeAnnouncementPlayback
    ) throws -> VoiceAnnouncementService {
        try VoiceAnnouncementService(
            playback: playback,
            daveNotReadyRetryDelay: .milliseconds(5),
            renderOverride: { _, _ in makeRenderedBuffer() }
        )
    }

    /// A long message that can't coalesce with a neighbour (two of these
    /// exceed the coalesced-character cap).
    private func longMessage(_ tag: String) -> String {
        "\(tag) " + String(repeating: "alpha ", count: 45)
    }

    func testDrainSpeaksQueuedAnnouncementsInOrder() async throws {
        let playback = FakeAnnouncementPlayback()
        let announcer = try makeAnnouncer(playback: playback)

        await announcer.enqueue(longMessage("one"))
        await announcer.enqueue(longMessage("two"))
        await announcer.enqueue(longMessage("three"))

        await waitUntil { await announcer.recentHistory.count == 3 }

        let recent = await announcer.recentHistory
        // recordRecent inserts newest-first; reversed gives spoken order.
        let spokenOrder = recent.reversed().map { String($0.text.prefix(5)) }
        XCTAssertEqual(spokenOrder, ["one a", "two a", "three"])
        let speaks = await playback.speakCount
        XCTAssertEqual(speaks, 3, "long messages must not coalesce into one utterance")
    }

    func testShortMessagesCoalesceIntoOneUtterance() async throws {
        let playback = FakeAnnouncementPlayback()
        let announcer = try makeAnnouncer(playback: playback)

        await announcer.enqueue("alpha one")
        await announcer.enqueue("beta two")
        await announcer.enqueue("gamma three")

        await waitUntil { await announcer.recentHistory.count == 3 }

        let speaks = await playback.speakCount
        XCTAssertEqual(speaks, 1, "short messages inside the coalesce window must batch")
    }

    func testProlongedDaveNotReadyPausesAndKeepsQueue() async throws {
        let playback = FakeAnnouncementPlayback()
        await playback.setError(VoicePipelineError.daveNotReady)
        let announcer = try makeAnnouncer(playback: playback)

        await announcer.enqueue("read me later")

        // After the in-loop retries exhaust, the batch must be requeued and
        // the drain paused — not dropped.
        await waitUntil {
            let health = await announcer.healthSnapshot
            return health.isPaused && health.queueDepth == 1
        }
        let pending = await announcer.pending
        XCTAssertEqual(pending.map(\.text), ["read me later"])
        let recent = await announcer.recentHistory
        XCTAssertTrue(recent.isEmpty)

        // Media becomes ready again: the resume hook must speak the kept batch.
        await playback.setError(nil)
        await announcer.resumeAfterMediaReady()
        await waitUntil { await announcer.recentHistory.count == 1 }
        let pendingAfter = await announcer.pending
        XCTAssertTrue(pendingAfter.isEmpty)
    }

    func testReconnectableFailurePausesAndRequeues() async throws {
        let playback = FakeAnnouncementPlayback()
        await playback.setError(VoicePipelineError.notConnected)
        let announcer = try makeAnnouncer(playback: playback)

        await announcer.enqueue("keep me")

        await waitUntil {
            let health = await announcer.healthSnapshot
            return health.isPaused && health.queueDepth == 1
        }
        let pending = await announcer.pending
        XCTAssertEqual(pending.map(\.text), ["keep me"])

        // Reconnect: unpausing resumes the drain and speaks the kept batch.
        await playback.setError(nil)
        await announcer.setPaused(false)
        await waitUntil { await announcer.recentHistory.count == 1 }
    }

    func testTimedOutRenderDoesNotStrandFollowingAnnouncements() async throws {
        let playback = FakeAnnouncementPlayback()
        let announcer = try VoiceAnnouncementService(
            playback: playback,
            daveNotReadyRetryDelay: .milliseconds(5),
            speechRenderTimeout: .milliseconds(10),
            renderOverride: { text, _ in
                if text.hasPrefix("stuck") {
                    // Deliberately cancellable work: the production TTS source
                    // now uses the same cancellation path when its terminal
                    // AVSpeech callback goes missing.
                    try await Task.sleep(for: .seconds(60))
                }
                return makeRenderedBuffer()
            }
        )

        await announcer.enqueue(longMessage("stuck"))
        await announcer.enqueue(longMessage("next"))

        await waitUntil { await announcer.recentHistory.count == 1 }
        let recent = await announcer.recentHistory
        XCTAssertEqual(recent.first?.text.prefix(4), "next")
        let health = await announcer.healthSnapshot
        XCTAssertNotNil(health.lastFailureAt, "the timed-out batch should be recorded")
    }

    func testTransientRenderFailureRetriesAndKeepsAnnouncement() async throws {
        let playback = FakeAnnouncementPlayback()
        let attempts = RenderAttemptCounter()
        let announcer = try VoiceAnnouncementService(
            playback: playback,
            daveNotReadyRetryDelay: .milliseconds(5),
            renderOverride: { _, _ in
                if await attempts.next() <= 2 {
                    throw VoicePipelineError.timeout
                }
                return makeRenderedBuffer()
            }
        )

        await announcer.enqueue("retry this render")
        await waitUntil { await announcer.recentHistory.count == 1 }

        let renderAttempts = await attempts.count
        let speaks = await playback.speakCount
        XCTAssertGreaterThanOrEqual(renderAttempts, 3)
        XCTAssertEqual(speaks, 1, "a transient renderer failure must not drop the queued announcement")
    }

    func testTimedOutPlaybackPausesAndPreservesQueuedAnnouncement() async throws {
        let playback = FakeAnnouncementPlayback()
        await playback.setDelay(.seconds(60))
        let announcer = try VoiceAnnouncementService(
            playback: playback,
            daveNotReadyRetryDelay: .milliseconds(5),
            speechPlaybackTimeout: .milliseconds(10),
            renderOverride: { _, _ in makeRenderedBuffer() }
        )

        await announcer.enqueue("keep this after a stalled UDP write")

        await waitUntil {
            let health = await announcer.healthSnapshot
            return health.isPaused && health.queueDepth == 1 &&
                health.lastFailureReason == VoicePipelineError.playbackTimedOut.localizedDescription
        }

        let pending = await announcer.pending
        XCTAssertEqual(pending.map(\.text), ["keep this after a stalled UDP write"])
        let recent = await announcer.recentHistory
        XCTAssertTrue(recent.isEmpty)
    }

    func testPlaybackDeadlineEscapesNonCooperativeOperation() async throws {
        let playback = NonCooperativePlayback()
        let announcer = try VoiceAnnouncementService(
            playback: playback,
            daveNotReadyRetryDelay: .milliseconds(5),
            speechPlaybackTimeout: .milliseconds(10),
            renderOverride: { _, _ in makeRenderedBuffer() }
        )

        await announcer.enqueue("keep this after a non-cooperative send")
        await waitUntil { await playback.hasEntered }
        await waitUntil(timeout: 1) {
            let health = await announcer.healthSnapshot
            return health.isPaused && health.queueDepth == 1 &&
                health.lastFailureReason == VoicePipelineError.playbackTimedOut.localizedDescription
        }

        // Clean up the intentionally detached operation so this test never
        // leaves a background task parked after the assertion has passed.
        await playback.release()
    }
}
