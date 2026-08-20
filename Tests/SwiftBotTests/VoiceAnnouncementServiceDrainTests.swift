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

    /// Emits five ordinary DAVE-not-ready failures, then holds the sixth
    /// (final) retry open until the test injects a media-ready callback. The
    /// held failure models a stale media send completing after DAVE has
    /// already announced that its new ratchet is ready.
    private actor FinalDaveRetryPlayback: AnnouncementPlayback {
        private var attempts = 0
        private var finalFailureContinuation: CheckedContinuation<Void, Never>?
        private var waitingForFinalFailure = false

        var isWaitingForFinalFailure: Bool { waitingForFinalFailure }

        func speak(pcm wrapped: SendableAudioBuffer) async throws {
            attempts += 1
            if attempts <= 5 {
                throw VoicePipelineError.daveNotReady
            }
            if attempts == 6 {
                waitingForFinalFailure = true
                await withCheckedContinuation { continuation in
                    finalFailureContinuation = continuation
                }
                waitingForFinalFailure = false
                throw VoicePipelineError.daveNotReady
            }
        }

        func releaseFinalFailure() {
            let continuation = finalFailureContinuation
            finalFailureContinuation = nil
            continuation?.resume()
        }
    }

    /// Holds the first send open until a replacement voice session has
    /// resumed, then returns a stale reconnectable error. The next send
    /// succeeds, proving that the old error cannot re-pause the fresh queue.
    private actor StaleReconnectablePlayback: AnnouncementPlayback {
        private var attempts = 0
        private var staleFailureContinuation: CheckedContinuation<Void, Never>?
        private var waitingForStaleFailure = false

        var isWaitingForStaleFailure: Bool { waitingForStaleFailure }
        var speakCount: Int { attempts }

        func speak(pcm wrapped: SendableAudioBuffer) async throws {
            attempts += 1
            if attempts == 1 {
                waitingForStaleFailure = true
                await withCheckedContinuation { continuation in
                    staleFailureContinuation = continuation
                }
                waitingForStaleFailure = false
                throw VoicePipelineError.notConnected
            }
        }

        func releaseStaleFailure() {
            let continuation = staleFailureContinuation
            staleFailureContinuation = nil
            continuation?.resume()
        }
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

        // Queue everything before the drain starts. An idle queue now drains
        // immediately (that is what removes ~450 ms from the first read), so
        // coalescing is exercised the way it happens live: messages landing
        // while an earlier read is already in flight.
        await announcer.setPaused(true)
        await announcer.enqueue("alpha one")
        await announcer.enqueue("beta two")
        await announcer.enqueue("gamma three")
        await announcer.setPaused(false)

        await waitUntil { await announcer.recentHistory.count == 3 }

        let speaks = await playback.speakCount
        XCTAssertEqual(speaks, 1, "short messages queued together must batch into one utterance")
    }

    func testIdleQueueStartsReadingWithoutTheCoalesceDelay() async throws {
        let playback = FakeAnnouncementPlayback()
        let announcer = try makeAnnouncer(playback: playback)

        let start = ContinuousClock().now
        await announcer.enqueue("read me now")
        await waitUntil { await playback.speakCount == 1 }

        let elapsed = ContinuousClock().now - start
        XCTAssertLessThan(
            elapsed,
            .milliseconds(300),
            "a message arriving into an idle queue must not wait out the coalesce window"
        )
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

    func testMediaReadyDuringFinalDaveRetryDoesNotLeaveQueuePaused() async throws {
        let playback = FinalDaveRetryPlayback()
        let announcer = try VoiceAnnouncementService(
            playback: playback,
            daveNotReadyRetryDelay: .milliseconds(1),
            renderOverride: { _, _ in makeRenderedBuffer() }
        )

        await announcer.enqueue("resume the final DAVE retry")
        await waitUntil { await playback.isWaitingForFinalFailure }

        // This deliberately arrives while `speak` is still in flight, before
        // its stale daveNotReady reaches the final pause branch. Previously
        // the callback saw paused == false and was dropped, leaving the batch
        // paused forever once that failure completed.
        await announcer.resumeAfterMediaReady()
        await playback.releaseFinalFailure()

        await waitUntil { await announcer.recentHistory.count == 1 }
        let health = await announcer.healthSnapshot
        let pending = await announcer.pending
        XCTAssertFalse(health.isPaused)
        XCTAssertTrue(pending.isEmpty)
    }

    func testAutoRejoinUnpauseOutrunsStaleReconnectableFailure() async throws {
        let playback = StaleReconnectablePlayback()
        let announcer = try VoiceAnnouncementService(
            playback: playback,
            renderOverride: { _, _ in makeRenderedBuffer() }
        )

        await announcer.enqueue("keep reading after a fresh voice rejoin")
        await waitUntil { await playback.isWaitingForStaleFailure }

        // Model AppModel's .connecting -> .connected callbacks while a send
        // from the old voice session is still completing.
        await announcer.setPaused(true)
        await announcer.setPaused(false)
        await playback.releaseStaleFailure()

        await waitUntil { await announcer.recentHistory.count == 1 }
        let health = await announcer.healthSnapshot
        let pending = await announcer.pending
        let speaks = await playback.speakCount
        XCTAssertFalse(health.isPaused)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(speaks, 2)
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

    // MARK: - Health reporting

    /// The stall watchdog only bounds `.recovering`. A pause the announcer
    /// imposed on itself after a failed read must therefore report
    /// `.recovering`, not `.paused` — the drain loop's own exit used to
    /// overwrite it with `.paused`, which `isStalled` treats as healthy
    /// forever, so a failed read parked the queue silently and nothing ever
    /// rescued it.
    func testReconnectableFailureReportsRecoveringSoTheWatchdogCanSeeIt() async throws {
        let playback = FakeAnnouncementPlayback()
        await playback.setError(VoicePipelineError.notConnected)
        let announcer = try makeAnnouncer(playback: playback)

        await announcer.enqueue("keep me")
        await waitUntil {
            let health = await announcer.healthSnapshot
            return health.isPaused && health.queueDepth == 1 && !health.isDraining
        }

        let health = await announcer.healthSnapshot
        XCTAssertEqual(health.phase, .recovering)
        XCTAssertTrue(health.isStalled(now: Date().addingTimeInterval(120)))
    }

    /// A message arriving while the queue is parked must not relabel the
    /// recovery as an ordinary pause; that relabelling is what hid the stall
    /// from the watchdog exactly when reads were piling up.
    func testMessageArrivingDuringRecoveryKeepsTheRecoveringPhase() async throws {
        let playback = FakeAnnouncementPlayback()
        let announcer = try makeAnnouncer(playback: playback)

        await announcer.markRecovering("voice connection lost")
        await announcer.enqueue("arrived while recovering")

        let health = await announcer.healthSnapshot
        XCTAssertEqual(health.phase, .recovering)
        XCTAssertEqual(health.queueDepth, 1)
        XCTAssertTrue(health.isStalled(now: Date().addingTimeInterval(120)))
    }

    /// An owner-requested hold (handshake in progress, empty-channel grace)
    /// is lifted by the owner, so it must stay unbounded.
    func testOwnerRequestedPauseStaysUnbounded() async throws {
        let playback = FakeAnnouncementPlayback()
        let announcer = try makeAnnouncer(playback: playback)

        await announcer.setPaused(true)
        await announcer.enqueue("held deliberately")

        let health = await announcer.healthSnapshot
        XCTAssertEqual(health.phase, .paused)
        XCTAssertFalse(health.isStalled(now: Date().addingTimeInterval(600)))
    }

    /// Resuming clears the recovery marking, so a later deliberate hold is not
    /// mistaken for a stall.
    func testResumingClearsTheRecoveryMarking() async throws {
        let playback = FakeAnnouncementPlayback()
        let announcer = try makeAnnouncer(playback: playback)

        await announcer.markRecovering("voice connection lost")
        await announcer.setPaused(false)
        await waitUntil { await announcer.healthSnapshot.isPaused == false }
        await announcer.setPaused(true)

        let health = await announcer.healthSnapshot
        XCTAssertEqual(health.phase, .paused)
    }

    /// A message queued mid-read used to overwrite the active read's phase and
    /// wipe its start time, leaving the watchdog measuring time-since-last-
    /// message instead of the read itself — a false negative on a wedged read
    /// and a false positive on a healthy backlog.
    func testQueuingDuringAReadDoesNotDisturbTheActiveReadTimestamps() async throws {
        let playback = NonCooperativePlayback()
        let announcer = try VoiceAnnouncementService(
            playback: playback,
            daveNotReadyRetryDelay: .milliseconds(5),
            speechPlaybackTimeout: .seconds(30),
            renderOverride: { _, _ in makeRenderedBuffer() }
        )

        await announcer.enqueue("the read in flight")
        await waitUntil { await playback.hasEntered }
        await waitUntil { await announcer.healthSnapshot.phase == .sending }
        let duringRead = await announcer.healthSnapshot
        let activeStartedAt = try XCTUnwrap(duringRead.activeStartedAt)

        await announcer.enqueue("arrives mid-read")

        let afterQueuing = await announcer.healthSnapshot
        XCTAssertEqual(afterQueuing.phase, .sending)
        XCTAssertEqual(afterQueuing.activeStartedAt, activeStartedAt)
        XCTAssertNotNil(afterQueuing.activeExpiresAt)

        await playback.release()
    }

    // MARK: - Playback deadline

    /// Playback is paced in real time, so the deadline has to scale with the
    /// audio. A flat deadline failed every message long enough to outlast it,
    /// then retried it into the same deadline until recovery gave up.
    func testPlaybackDeadlineScalesWithAudioDuration() async throws {
        let playback = SlowPlayback(duration: .seconds(2))
        // Ten seconds of audio: a flat 3s deadline would fail this read, but
        // the deadline is slack *on top of* the audio's own length.
        let longAudio = makeRenderedBuffer(frames: AVAudioFrameCount(OpusFrameEncoder.sampleRate * 10))
        let announcer = try VoiceAnnouncementService(
            playback: playback,
            daveNotReadyRetryDelay: .milliseconds(5),
            speechPlaybackTimeout: .seconds(3),
            renderOverride: { _, _ in longAudio }
        )

        await announcer.enqueue("a long message that takes a while to read out")
        await waitUntil(timeout: 10) { await announcer.recentHistory.count == 1 }

        let health = await announcer.healthSnapshot
        XCTAssertNil(health.lastFailureReason)
    }

    /// The slack still applies: a send that outlasts audio duration plus the
    /// configured timeout is still a wedged write.
    func testPlaybackDeadlineStillFiresOnAWedgedSend() async throws {
        let playback = NonCooperativePlayback()
        let announcer = try VoiceAnnouncementService(
            playback: playback,
            daveNotReadyRetryDelay: .milliseconds(5),
            speechPlaybackTimeout: .milliseconds(50),
            renderOverride: { _, _ in makeRenderedBuffer() }
        )

        await announcer.enqueue("never completes")
        await waitUntil(timeout: 2) {
            let health = await announcer.healthSnapshot
            return health.lastFailureReason == VoicePipelineError.playbackTimedOut.localizedDescription
        }

        await playback.release()
    }
}

/// Completes each send after a fixed delay, modelling a real paced read.
private actor SlowPlayback: AnnouncementPlayback {
    private let duration: Duration

    init(duration: Duration) {
        self.duration = duration
    }

    func speak(pcm wrapped: SendableAudioBuffer) async throws {
        try await Task.sleep(for: duration)
    }
}
