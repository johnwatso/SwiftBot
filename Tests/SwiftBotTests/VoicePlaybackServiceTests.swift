import AVFoundation
import XCTest
import libdave_swift
@testable import SwiftBot

final class VoicePlaybackServiceTests: XCTestCase {

    private actor CompletionSignal {
        private var completed = false

        func finish() { completed = true }
        var isCompleted: Bool { completed }
    }

    private func makePipeline(
        resumeConfirmationTimeout: Duration = .seconds(5),
        connectionReadinessTimeout: Duration = .seconds(15),
        daveDowngradeTransitionTimeout: Duration = .seconds(12),
        daveTransitionGateProgressTimeout: Duration = .seconds(15)
    ) -> (VoicePlaybackService, FakeVoiceGateway, FakeVoiceTransport) {
        let server = makeVoiceServerInfo()
        let gateway = FakeVoiceGateway(server: server)
        let transport = FakeVoiceTransport()
        let playback = VoicePlaybackService(
            gatewayFactory: { _, _ in gateway },
            transportFactory: { _, _ in transport },
            resumeConfirmationTimeout: resumeConfirmationTimeout,
            connectionReadinessTimeout: connectionReadinessTimeout,
            daveDowngradeTransitionTimeout: daveDowngradeTransitionTimeout,
            daveTransitionGateProgressTimeout: daveTransitionGateProgressTimeout
        )
        return (playback, gateway, transport)
    }

    /// Drives the fake handshake to `.connected` with no DAVE negotiation.
    private func connect(
        _ playback: VoicePlaybackService,
        _ gateway: FakeVoiceGateway
    ) async throws {
        let connectTask = Task { try await playback.connect(server: gateway.server) }
        await waitUntil { await gateway.connectCount == 1 }
        await gateway.emitReady()
        await gateway.emitSessionDescription(daveProtocolVersion: nil)
        try await connectTask.value
    }

    private func makePath(
        status: VoiceNetworkPathSnapshot.Status,
        interfaces: [VoiceNetworkPathSnapshot.InterfaceType]
    ) -> VoiceNetworkPathSnapshot {
        VoiceNetworkPathSnapshot(
            status: status,
            activeInterfaceTypes: interfaces,
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            supportsDNS: true
        )
    }

    func testConnectCompletesWithoutDave() async throws {
        let (playback, gateway, transport) = makePipeline()
        try await connect(playback, gateway)

        let status = await playback.currentStatus
        XCTAssertEqual(status, .connected)
        let started = await transport.started
        XCTAssertTrue(started)
        let selects = await gateway.selectProtocolCount
        XCTAssertEqual(selects, 1)
    }

    func testConnectingVoiceSessionAcceptsQueuedAnnouncements() {
        XCTAssertTrue(VoiceConnectionStatus.connecting.canQueueAnnouncements)
        XCTAssertTrue(VoiceConnectionStatus.recovering("rejoining").canQueueAnnouncements)
        XCTAssertFalse(VoiceConnectionStatus.failed("offline").canQueueAnnouncements)
    }

    func testDuplicateHandshakeEventsAreIdempotent() async throws {
        let (playback, gateway, transport) = makePipeline()
        let connectTask = Task { try await playback.connect(server: gateway.server) }
        await waitUntil { await gateway.connectCount == 1 }

        await gateway.emitReady()
        await gateway.emitReady(ssrc: 999)
        let selects = await gateway.selectProtocolCount
        XCTAssertEqual(selects, 1, "a replayed READY must not replace the active UDP transport")

        await gateway.emitSessionDescription(daveProtocolVersion: nil)
        await gateway.emitSessionDescription(daveProtocolVersion: nil)
        try await connectTask.value

        let status = await playback.currentStatus
        let stopped = await transport.stopped
        XCTAssertEqual(status, .connected)
        XCTAssertFalse(stopped)
    }

    func testSpeakSendsFramesOverTransport() async throws {
        let (playback, gateway, transport) = makePipeline()
        try await connect(playback, gateway)

        try await playback.speak(pcm: makeRenderedBuffer())

        let packets = await transport.sentPackets
        XCTAssertFalse(packets.isEmpty, "PCM must produce RTP packets on the transport")
        let speaking = await gateway.speakingUpdates
        XCTAssertEqual(speaking.first, true)
    }

    func testCancellingActiveSpeechFailsSessionForCleanRecovery() async throws {
        let (playback, gateway, transport) = makePipeline()
        try await connect(playback, gateway)

        // Keep the task in the pacing loop long enough to cancel mid-utterance.
        let speaking = Task {
            try await playback.speak(pcm: makeRenderedBuffer(frames: 48_000))
        }
        await waitUntil { !(await transport.sentPackets).isEmpty }

        speaking.cancel()
        _ = try? await speaking.value
        await waitUntil {
            if case .failed = await playback.currentStatus { return true }
            return false
        }
    }

    func testCancellingBlockedSpeechReturnsWithoutManualSendRelease() async throws {
        let (playback, gateway, transport) = makePipeline()
        try await connect(playback, gateway)
        await transport.setSendsBlocked(true)
        let completion = CompletionSignal()

        let speech = Task {
            _ = try? await playback.speak(pcm: makeRenderedBuffer(frames: 48_000))
            await completion.finish()
        }
        await waitUntil { await transport.blockedSendCount == 1 }

        speech.cancel()
        await waitUntil(timeout: 1) { await completion.isCompleted }
        await waitUntil(timeout: 1) {
            if case .failed = await playback.currentStatus { return true }
            return false
        }
        _ = await speech.result
    }

    func testCancellingSpeechBeforeSpeakingIndicatorFailsSessionForRecovery() async throws {
        let (playback, gateway, _) = makePipeline()
        try await connect(playback, gateway)
        await gateway.setSpeakingSendsBlocked(true)

        let speech = Task {
            _ = try? await playback.speak(pcm: makeRenderedBuffer(frames: 48_000))
        }
        await waitUntil { await gateway.blockedSpeakingSendCount == 1 }

        // The websocket write is wedged before `streamSpeech` has set
        // `isSpeaking`. Cancellation must still fail this generation rather
        // than leave a connected-looking silent voice session behind.
        speech.cancel()
        await waitUntil(timeout: 1) {
            if case .failed = await playback.currentStatus { return true }
            return false
        }

        await gateway.releaseBlockedSpeakingSends()
        _ = await speech.result
    }

    func testSpeakingUpdatesStayOrderedAcrossOverlappingUtterances() async throws {
        let (playback, gateway, _) = makePipeline()
        try await connect(playback, gateway)
        await gateway.setSpeakingFalseSendsBlocked(true)

        // Let A reach its asynchronous teardown, then begin B while A's
        // `speaking: false` write is still in flight. Discord must see A's
        // false before B's true; otherwise the delayed false can mute B.
        let first = Task {
            try await playback.speak(pcm: makeRenderedBuffer())
        }
        await waitUntil { await gateway.blockedSpeakingFalseSendCount == 1 }

        let second = Task {
            try await playback.speak(pcm: makeRenderedBuffer())
        }
        try? await Task.sleep(for: .milliseconds(80))
        let updatesWhileTeardownBlocked = await gateway.speakingUpdates
        XCTAssertEqual(
            updatesWhileTeardownBlocked,
            [true],
            "the next speaking update must wait behind the prior teardown"
        )

        await gateway.setSpeakingFalseSendsBlocked(false)
        await gateway.releaseBlockedSpeakingFalseSends()
        try await first.value
        try await second.value
        await waitUntil { (await gateway.speakingUpdates).count == 4 }
        let finalUpdates = await gateway.speakingUpdates
        XCTAssertEqual(finalUpdates, [true, false, true, false])
    }

    func testNewSpeechReservesSpeakingOwnershipBeforeItsTrueUpdateCompletes() async throws {
        let (playback, gateway, _) = makePipeline()
        try await connect(playback, gateway)

        // Let A start normally, then hold B's `speaking: true` write. A's
        // asynchronous teardown now runs while B's update is in flight. It
        // must see B's reserved receipt and not queue a stale false behind it.
        let first = Task {
            try await playback.speak(pcm: makeRenderedBuffer())
        }
        await waitUntil { (await gateway.speakingUpdates) == [true] }

        await gateway.setSpeakingSendsBlocked(true)
        let second = Task {
            try await playback.speak(pcm: makeRenderedBuffer())
        }
        await waitUntil { await gateway.blockedSpeakingSendCount == 1 }

        try await first.value
        try? await Task.sleep(for: .milliseconds(80))
        await gateway.setSpeakingSendsBlocked(false)
        await gateway.releaseBlockedSpeakingSends()
        try await second.value

        await waitUntil { (await gateway.speakingUpdates).count >= 3 }
        try? await Task.sleep(for: .milliseconds(80))
        let updates = await gateway.speakingUpdates
        XCTAssertEqual(
            updates,
            [true, true, false],
            "an old teardown must not enqueue false after a newer true update"
        )
    }

    func testNetworkPathBaselineDoesNotRecoverHealthyIdleSession() async throws {
        let (playback, gateway, transport) = makePipeline()
        try await connect(playback, gateway)

        await transport.emitNetworkPathUpdate(makePath(status: .satisfied, interfaces: [.wifi]))
        let status = await playback.currentStatus
        XCTAssertEqual(status, .connected, "the first path observation is only a baseline")
    }

    func testUsableNetworkPathChangeRebuildsIdleSessionBeforeNextRead() async throws {
        let (playback, gateway, transport) = makePipeline()
        try await connect(playback, gateway)

        await transport.emitNetworkPathUpdate(makePath(status: .satisfied, interfaces: [.wifi]))
        await transport.emitNetworkPathUpdate(makePath(status: .satisfied, interfaces: [.cellular]))
        await waitUntil(timeout: 1) {
            if case .failed = await playback.currentStatus { return true }
            return false
        }
    }

    func testSameInterfaceRouteChangeRebuildsSessionBeforeNextRead() async throws {
        let (playback, gateway, transport) = makePipeline()
        try await connect(playback, gateway)

        let wifi = makePath(status: .satisfied, interfaces: [.wifi])
        // `NWPath` can change when a device roams between Wi-Fi access points
        // even if its public interface summary is still `satisfied Wi-Fi`.
        // The transport already suppressed the initial baseline, so this later
        // callback must rebuild rather than leave UDP pinned to the old route.
        await transport.emitNetworkPathRouteChange(from: wifi, to: wifi)

        await waitUntil(timeout: 1) {
            if case .failed = await playback.currentStatus { return true }
            return false
        }
    }

    func testRouteSettleCooldownSurvivesAutomaticRecoveryConnection() async throws {
        let server = makeVoiceServerInfo()
        let firstGateway = FakeVoiceGateway(server: server)
        let secondGateway = FakeVoiceGateway(server: server)
        let firstTransport = FakeVoiceTransport()
        let secondTransport = FakeVoiceTransport()
        let pipeline = SequencedVoicePipeline(
            gateways: [firstGateway, secondGateway],
            transports: [firstTransport, secondTransport]
        )
        let playback = VoicePlaybackService(
            gatewayFactory: { session, info in pipeline.makeGateway(session, info) },
            transportFactory: { host, port in pipeline.makeTransport(host, port) }
        )

        let firstConnect = Task { try await playback.connect(server: server) }
        await waitUntil { await firstGateway.connectCount == 1 }
        await firstGateway.emitReady()
        await firstGateway.emitSessionDescription(daveProtocolVersion: nil)
        try await firstConnect.value

        let wifi = makePath(status: .satisfied, interfaces: [.wifi])
        await firstTransport.emitNetworkPathRouteChange(from: wifi, to: wifi)
        await waitUntil(timeout: 1) {
            if case .failed = await playback.currentStatus { return true }
            return false
        }

        // This is the service-level equivalent of AppModel's automatic
        // recovery teardown: retain the path cooldown, then establish a clean
        // replacement connection on the route that is still settling.
        await playback.disconnect(preservingNetworkPathRecoveryCooldown: true)
        let secondConnect = Task { try await playback.connect(server: server) }
        await waitUntil { await secondGateway.connectCount == 1 }
        await secondGateway.emitReady(ssrc: 84)
        await secondGateway.emitSessionDescription(daveProtocolVersion: nil)
        try await secondConnect.value

        await secondTransport.emitNetworkPathRouteChange(from: wifi, to: wifi)
        try? await Task.sleep(for: .milliseconds(50))
        let status = await playback.currentStatus
        XCTAssertEqual(status, .connected, "route-settle churn must not consume another automatic rejoin")
        let replacementStopped = await secondTransport.stopped
        XCTAssertFalse(replacementStopped)

        await playback.disconnect()
    }

    func testPathRecoveryBudgetDefersChurnThenRearmsAfterStability() async throws {
        let server = makeVoiceServerInfo()
        let firstGateway = FakeVoiceGateway(server: server)
        let secondGateway = FakeVoiceGateway(server: server)
        let firstTransport = FakeVoiceTransport()
        let secondTransport = FakeVoiceTransport()
        let pipeline = SequencedVoicePipeline(
            gateways: [firstGateway, secondGateway],
            transports: [firstTransport, secondTransport]
        )
        let playback = VoicePlaybackService(
            gatewayFactory: { session, info in pipeline.makeGateway(session, info) },
            transportFactory: { host, port in pipeline.makeTransport(host, port) },
            networkPathRecoveryBudgetStabilityWindow: .milliseconds(100)
        )

        let firstConnect = Task { try await playback.connect(server: server) }
        await waitUntil { await firstGateway.connectCount == 1 }
        await firstGateway.emitReady()
        await firstGateway.emitSessionDescription(daveProtocolVersion: nil)
        try await firstConnect.value

        let wifi = makePath(status: .satisfied, interfaces: [.wifi])
        await firstTransport.emitNetworkPathRouteChange(from: wifi, to: wifi)
        await waitUntil(timeout: 1) {
            if case .failed = await playback.currentStatus { return true }
            return false
        }

        // Preserve the automatic-recovery policy, then reconnect. A route
        // returning from unavailable normally bypasses the settle cooldown;
        // it must still respect the one proactive-rebuild budget rather than
        // consume every AppModel rejoin attempt during path churn.
        await playback.disconnect(preservingNetworkPathRecoveryCooldown: true)
        let secondConnect = Task { try await playback.connect(server: server) }
        await waitUntil { await secondGateway.connectCount == 1 }
        await secondGateway.emitReady(ssrc: 85)
        await secondGateway.emitSessionDescription(daveProtocolVersion: nil)
        try await secondConnect.value

        let unavailable = makePath(status: .unsatisfied, interfaces: [])
        await secondTransport.emitNetworkPathRouteChange(from: unavailable, to: wifi)
        try? await Task.sleep(for: .milliseconds(50))
        let status = await playback.currentStatus
        XCTAssertEqual(status, .connected, "a recovered route must not spend a second automatic path rebuild")
        let replacementStopped = await secondTransport.stopped
        XCTAssertFalse(replacementStopped)

        // Once the replacement has stayed quiet beyond the route-settle
        // window, restore the proactive guard. A later genuine handoff must
        // not be ignored permanently just because an earlier route churned.
        try? await Task.sleep(for: .milliseconds(150))
        await secondTransport.emitNetworkPathRouteChange(from: unavailable, to: wifi)
        await waitUntil(timeout: 1) {
            if case .failed = await playback.currentStatus { return true }
            return false
        }

        await playback.disconnect()
    }

    func testUsableNetworkPathChangeDuringSpeechFailsForFreshRecovery() async throws {
        let (playback, gateway, transport) = makePipeline()
        try await connect(playback, gateway)

        let speech = Task {
            try await playback.speak(pcm: makeRenderedBuffer(frames: 48_000))
        }
        await waitUntil { (await gateway.speakingUpdates).contains(true) }

        await transport.emitNetworkPathUpdate(makePath(status: .satisfied, interfaces: [.wifi]))
        await transport.emitNetworkPathUpdate(makePath(status: .unsatisfied, interfaces: []))
        let statusAfterRouteLoss = await playback.currentStatus
        XCTAssertEqual(statusAfterRouteLoss, .connected, "route loss alone waits for a usable route")
        await transport.emitNetworkPathUpdate(makePath(status: .satisfied, interfaces: [.cellular]))

        await waitUntil(timeout: 1) {
            if case .failed = await playback.currentStatus { return true }
            return false
        }
        _ = try? await speech.value
    }

    func testConnectWhileConnectingThrows() async throws {
        let (playback, gateway, _) = makePipeline()
        let firstConnect = Task { try await playback.connect(server: gateway.server) }
        await waitUntil { await gateway.connectCount == 1 }

        do {
            try await playback.connect(server: gateway.server)
            XCTFail("second connect while connecting must throw")
        } catch {
            // expected
        }

        // Unblock and fail the first attempt cleanly.
        await gateway.emitClose(4006)
        _ = try? await firstConnect.value
    }

    func testAbnormalCloseResumesInPlace() async throws {
        let (playback, gateway, _) = makePipeline()
        try await connect(playback, gateway)

        await gateway.emitClose(1006)
        await waitUntil { await gateway.resumeCount == 1 }

        await gateway.emitResumed()
        let status = await playback.currentStatus
        XCTAssertEqual(status, .connected, "a confirmed resume must keep the session connected")
    }

    func testNonResumableCloseFailsWithoutResume() async throws {
        let (playback, gateway, _) = makePipeline()
        try await connect(playback, gateway)

        await gateway.emitClose(4006)
        await waitUntil {
            if case .failed = await playback.currentStatus { return true }
            return false
        }
        let resumes = await gateway.resumeCount
        XCTAssertEqual(resumes, 0, "4006 invalidates the session; resume must not be attempted")
    }

    func testUnconfirmedResumeFailsAfterTimeout() async throws {
        let (playback, gateway, _) = makePipeline(resumeConfirmationTimeout: .milliseconds(100))
        try await connect(playback, gateway)

        await gateway.emitClose(1006)
        await waitUntil { await gateway.resumeCount == 1 }

        await waitUntil {
            if case .failed = await playback.currentStatus { return true }
            return false
        }
    }

    /// Regression: a coordinator configured the way `establishDaveSession`
    /// does — including the persistent `authSessionId` — must be able to
    /// marshal its MLS key package. On framework builds with a null key
    /// store (pre-1.3.1 libdave-swift), a non-nil id aborts leaf-node init
    /// and the handshake dies at the media-readiness timeout with no audio.
    func testDaveCoordinatorWithAuthSessionIdProducesKeyPackage() async throws {
        let coordinator = DaveSessionCoordinator(authSessionId: "1077354549104345159")
        _ = try await coordinator.configureDiscordVoiceSession(
            groupId: 1_480_049_140_082_933_860,
            selfUserId: "1077354549104345159",
            protocolVersion: 1
        )
        let keyPackage = try await coordinator.getMarshalledKeyPackage()
        XCTAssertFalse(keyPackage.isEmpty, "configured session must yield a non-empty MLS key package")
    }

    func testPreGroupMlsProposalsAreIgnoredWithoutFailingConnection() async throws {
        let (playback, gateway, transport) = makePipeline()
        let connectTask = Task { try await playback.connect(server: gateway.server) }
        await waitUntil { await gateway.connectCount == 1 }
        await gateway.emitReady()

        // Discord can replay buffered binary MLS gateway traffic before the
        // SESSION_DESCRIPTION has given us a DAVE group. These bytes must be
        // ignored, rather than parsed as an MLS proposal or treated as a fatal
        // protocol failure. Deliberately do not pretend this is a valid MLS
        // message: native acceptance needs a real Discord fixture.
        await gateway.emitMlsProposals(Data([0x01, 0x02, 0x03]))
        await gateway.emitSessionDescription(daveProtocolVersion: 1)

        await waitUntil { await playback.getDaveDiagnostics() != nil }
        try? await Task.sleep(for: .milliseconds(50))

        let status = await playback.currentStatus
        let commitWelcomes = await gateway.commitWelcomePayloads
        let packets = await transport.sentPackets
        XCTAssertEqual(status, .connecting, "a pre-group proposal must not fail the pending DAVE handshake")
        XCTAssertTrue(commitWelcomes.isEmpty, "pre-group proposals must not generate an MLS commit/welcome")
        XCTAssertTrue(packets.isEmpty)

        await playback.disconnect()
        _ = await connectTask.result
    }

    func testDaveDowngradeWaitsForMatchingExecuteBeforeCompletingConnection() async throws {
        let (playback, gateway, transport) = makePipeline()
        let connectTask = Task { try await playback.connect(server: gateway.server) }
        await waitUntil { await gateway.connectCount == 1 }
        await gateway.emitReady()
        await gateway.emitSessionDescription(daveProtocolVersion: 1)

        // Call downgrades to transport-only before the MLS handshake finishes.
        await gateway.emitPrepareTransition(version: 0, transitionId: 5)
        await waitUntil { await gateway.transitionReadyIds.contains(5) }

        // `transition-ready` only acknowledges preparation. It is unsafe to
        // complete the pipeline (and allow media) until Discord authorizes the
        // exact same transition ID with Execute.
        let statusBeforeExecute = await playback.currentStatus
        let packetsBeforeExecute = await transport.sentPackets
        XCTAssertEqual(statusBeforeExecute, .connecting)
        XCTAssertTrue(packetsBeforeExecute.isEmpty)

        await gateway.emitExecuteTransition(4)
        try? await Task.sleep(for: .milliseconds(50))
        let statusAfterWrongExecute = await playback.currentStatus
        XCTAssertEqual(statusAfterWrongExecute, .connecting, "an Execute for a different transition must not downgrade media")

        await gateway.emitExecuteTransition(5)

        try await connectTask.value
        let status = await playback.currentStatus
        XCTAssertEqual(status, .connected)

        try await playback.speak(pcm: makeRenderedBuffer())
        let packets = await transport.sentPackets
        XCTAssertFalse(packets.isEmpty, "downgraded session must still send audio frames")
    }

    func testDaveDowngradeHonorsExecuteAlreadyProcessedBeforePrepareHandler() async throws {
        let (playback, gateway, _) = makePipeline(
            daveDowngradeTransitionTimeout: .milliseconds(500)
        )
        let connectTask = Task { try await playback.connect(server: gateway.server) }
        await waitUntil { await gateway.connectCount == 1 }
        await gateway.emitReady()
        await gateway.emitSessionDescription(daveProtocolVersion: 1)
        await waitUntil { await playback.getDaveDiagnostics() != nil }

        // A retained/replayed Execute can reach the callback before the
        // serialized Prepare handler runs. Once transition-ready is sent, the
        // recorded earlier receipt must finish the downgrade rather than let
        // its watchdog mistake the already-seen Execute for packet loss.
        await gateway.emitExecuteTransition(17)
        try? await Task.sleep(for: .milliseconds(20))
        await gateway.emitPrepareTransition(version: 0, transitionId: 17)
        await waitUntil { await gateway.transitionReadyIds.contains(17) }

        try await connectTask.value
        let status = await playback.currentStatus
        XCTAssertEqual(status, .connected)
    }

    func testDaveDowngradeRetainsExecuteQueuedDuringCoordinatorSetup() async throws {
        let (playback, gateway, _) = makePipeline(
            daveDowngradeTransitionTimeout: .milliseconds(500)
        )
        let connectTask = Task { try await playback.connect(server: gateway.server) }
        await waitUntil { await gateway.connectCount == 1 }
        await gateway.emitReady()

        // SESSION_DESCRIPTION queues coordinator setup, but it does not wait
        // for libdave to finish configuring. A replayed Execute can therefore
        // be recorded before setup reaches the event tail; clearing it during
        // construction would strand the following Prepare v0 until timeout.
        await gateway.emitSessionDescription(daveProtocolVersion: 1)
        await gateway.emitExecuteTransition(18)
        await gateway.emitPrepareTransition(version: 0, transitionId: 18)
        await waitUntil { await gateway.transitionReadyIds.contains(18) }

        try await connectTask.value
        let status = await playback.currentStatus
        XCTAssertEqual(status, .connected)
    }

    func testDaveDowngradeMissingExecuteFailsAtDeadline() async throws {
        let (playback, gateway, _) = makePipeline(
            daveDowngradeTransitionTimeout: .milliseconds(100)
        )
        let connectTask = Task { try await playback.connect(server: gateway.server) }
        await waitUntil { await gateway.connectCount == 1 }
        await gateway.emitReady()
        await gateway.emitSessionDescription(daveProtocolVersion: 1)
        await gateway.emitPrepareTransition(version: 0, transitionId: 9)
        await waitUntil { await gateway.transitionReadyIds.contains(9) }

        await waitUntil(timeout: 1) {
            if case .failed = await playback.currentStatus { return true }
            return false
        }
        let result = await connectTask.result
        if case .success = result {
            XCTFail("a DAVE downgrade without Execute must not leave the pipeline connected")
        }
    }

    func testPrepareEpochImmediatelyGatesMediaAndRetainsTransitionID() async throws {
        let (playback, gateway, transport) = makePipeline()
        try await connect(playback, gateway)

        // Use an ID that would be corrupted by an `Int`/floating-point bridge.
        // This drives the full VoicePlaybackGateway callback path, rather than
        // testing the JSON decoder in isolation.
        let transitionID = UInt64.max - 1
        await gateway.emitPrepareEpoch(version: 1, epoch: 1, transitionId: transitionID)

        await waitUntil {
            guard let diagnostics = await playback.getDaveDiagnostics() else { return false }
            return diagnostics.pendingEpoch == 1
                && diagnostics.pendingTransitionId == transitionID
                && !diagnostics.mediaReady
        }

        do {
            try await playback.speak(pcm: makeRenderedBuffer())
            XCTFail("media must remain blocked until DAVE receives the matching Execute Transition")
        } catch VoicePipelineError.daveNotReady {
            // Expected: libdave owns readiness and has not activated this
            // transition's outbound ratchet.
        } catch {
            XCTFail("expected daveNotReady before Execute, got \(error)")
        }

        let speakingUpdates = await gateway.speakingUpdates
        let packetsBeforeExecute = await transport.sentPackets
        XCTAssertTrue(speakingUpdates.isEmpty, "DAVE gating must happen before a speaking update or trailing-silence send")
        XCTAssertTrue(packetsBeforeExecute.isEmpty)
        await playback.disconnect()
    }

    func testDaveGateProgressWatchdogRecoversStalledSecureTransition() async throws {
        let (playback, gateway, _) = makePipeline(
            daveTransitionGateProgressTimeout: .milliseconds(100)
        )
        try await connect(playback, gateway)

        // No external sender/Execute follows this upgrade. The gate remains
        // closed, so the host watchdog must recover rather than leave a
        // connected-looking announcer paused indefinitely.
        await gateway.emitPrepareEpoch(version: 1, epoch: 1, transitionId: 19)
        await waitUntil(timeout: 1) {
            if case .failed = await playback.currentStatus { return true }
            return false
        }
    }

    func testDaveGateWatchdogIsNotDeferredByCallbacksBehindStalledTail() async throws {
        let (playback, gateway, _) = makePipeline(
            daveTransitionGateProgressTimeout: .milliseconds(100)
        )
        let connectTask = Task { try await playback.connect(server: gateway.server) }
        await waitUntil { await gateway.connectCount == 1 }
        await gateway.emitReady()
        await gateway.emitSessionDescription(daveProtocolVersion: 1)
        await waitUntil { await playback.getDaveDiagnostics() != nil }

        // Hold a downgrade handler in its transition-ready write. The next
        // Execute is a gated callback waiting behind that serial tail event;
        // a continuing stream of later Executes must not restart its host
        // deadline merely because they reached the gateway boundary.
        await gateway.setTransitionReadySendsBlocked(true)
        await gateway.emitPrepareTransition(version: 0, transitionId: 50)
        await waitUntil { await gateway.blockedTransitionReadySendCount == 1 }

        await gateway.emitExecuteTransition(50)
        let callbackFlood = Task {
            var transitionID: UInt64 = 51
            while !Task.isCancelled {
                await gateway.emitExecuteTransition(transitionID)
                transitionID &+= 1
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return
                }
            }
        }

        await waitUntil(timeout: 1) {
            if case .failed = await playback.currentStatus { return true }
            return false
        }
        callbackFlood.cancel()
        _ = await callbackFlood.result

        // The fake deliberately models a non-cooperative write. Release it so
        // the queued task can unwind after the generation is invalidated.
        await gateway.releaseBlockedTransitionReadySends()
        _ = await connectTask.result
    }

    func testZeroIDSoleMemberResetFollowsPrepareEpochWithoutLiftingDaveGate() async throws {
        let (playback, gateway, transport) = makePipeline(
            connectionReadinessTimeout: .milliseconds(250),
            daveTransitionGateProgressTimeout: .milliseconds(100)
        )
        let connectTask = Task { try await playback.connect(server: gateway.server) }
        await waitUntil { await gateway.connectCount == 1 }
        await gateway.emitReady()
        await gateway.emitSessionDescription(daveProtocolVersion: 1)
        await waitUntil { await playback.getDaveDiagnostics() != nil }

        // Discord first prepares the epoch with a normal transition ID. The
        // following Op21 ID-zero signal is the sole-member-reset discriminator;
        // its protocol version is non-zero and it must never be treated as a
        // normal transport-only downgrade or acknowledged with transition-ready.
        let epochTransitionID: UInt64 = 77
        await gateway.emitPrepareEpoch(version: 1, epoch: 1, transitionId: epochTransitionID)
        await waitUntil(timeout: 1) {
            guard let diagnostics = await playback.getDaveDiagnostics() else { return false }
            return diagnostics.pendingEpoch == 1
                && diagnostics.pendingTransitionId == epochTransitionID
                && !diagnostics.mediaReady
        }

        await gateway.emitPrepareTransition(version: 1, transitionId: 0)
        await waitUntil(timeout: 1) {
            guard let diagnostics = await playback.getDaveDiagnostics() else { return false }
            return diagnostics.lastRecoveryAction == .pauseMedia
                && diagnostics.pendingEpoch == nil
                && diagnostics.pendingTransitionId == nil
                && !diagnostics.mediaReady
        }

        let status = await playback.currentStatus
        let diagnostics = await playback.getDaveDiagnostics()
        let readyIDs = await gateway.transitionReadyIds
        let packets = await transport.sentPackets
        XCTAssertEqual(status, .connecting, "sole-member reset must not fail the pending voice connection")
        XCTAssertEqual(diagnostics?.lastRecoveryAction, .pauseMedia)
        XCTAssertNil(diagnostics?.pendingEpoch)
        XCTAssertNil(diagnostics?.pendingTransitionId)
        XCTAssertFalse(diagnostics?.mediaReady ?? true)
        XCTAssertFalse(readyIDs.contains(0), "sole-member reset must not emit a transition-ready gateway message")
        XCTAssertTrue(packets.isEmpty)

        // A normal connection deadline is appropriate for a malformed
        // handshake, but not for this valid indefinite solo state. Let the
        // injected deadline pass and prove the transport remains safely
        // connected-but-DAVE-gated rather than entering the rejoin loop.
        try? await Task.sleep(for: .milliseconds(350))
        let statusAfterOrdinaryDeadline = await playback.currentStatus
        XCTAssertEqual(statusAfterOrdinaryDeadline, .connecting)

        await playback.disconnect()
        _ = await connectTask.result
    }

    func testDisconnectResolvesConnectWhenGatewayConnectNeverReturns() async throws {
        let server = makeVoiceServerInfo()
        let gateway = FakeVoiceGateway(server: server)
        await gateway.setConnectBlocked(true)
        let transport = FakeVoiceTransport()
        let playback = VoicePlaybackService(
            gatewayFactory: { _, _ in gateway },
            transportFactory: { _, _ in transport }
        )
        let completion = CompletionSignal()

        let connectTask = Task {
            do {
                try await playback.connect(server: server)
            } catch {
                // The test expects disconnect to resolve this call even while
                // the underlying gateway ignores cancellation.
            }
            await completion.finish()
        }
        await waitUntil { await gateway.connectCount == 1 }

        await playback.disconnect()
        await waitUntil(timeout: 1) { await completion.isCompleted }
        let status = await playback.currentStatus
        XCTAssertEqual(status, .idle)

        // Let the intentionally non-cooperative fake finish its detached
        // worker so the test leaves no background work behind.
        await gateway.releaseBlockedConnects()
        _ = await connectTask.result
    }

    func testLateGatewayCallbacksCannotMutateReplacementConnection() async throws {
        let server = makeVoiceServerInfo()
        let firstGateway = FakeVoiceGateway(server: server)
        let secondGateway = FakeVoiceGateway(server: server)
        let firstTransport = FakeVoiceTransport()
        let secondTransport = FakeVoiceTransport()
        let pipeline = SequencedVoicePipeline(
            gateways: [firstGateway, secondGateway],
            transports: [firstTransport, secondTransport]
        )
        let playback = VoicePlaybackService(
            gatewayFactory: { session, info in pipeline.makeGateway(session, info) },
            transportFactory: { host, port in pipeline.makeTransport(host, port) }
        )

        let firstConnect = Task { try await playback.connect(server: server) }
        await waitUntil { await firstGateway.connectCount == 1 }
        await firstGateway.emitReady()
        await firstGateway.emitSessionDescription(daveProtocolVersion: nil)
        try await firstConnect.value
        await playback.disconnect()

        let secondConnect = Task { try await playback.connect(server: server) }
        await waitUntil { await secondGateway.connectCount == 1 }
        await secondGateway.emitReady(ssrc: 84)
        await secondGateway.emitSessionDescription(daveProtocolVersion: nil)
        try await secondConnect.value

        // Simulate callbacks retained by the closed socket arriving after the
        // replacement session is healthy. These used to overwrite the active
        // RTP/UDP state or fail the new connection.
        await firstGateway.emitReady(ssrc: 777)
        await firstGateway.emitSessionDescription(daveProtocolVersion: nil)
        await firstGateway.emitClose(4006)
        await firstGateway.emitResumed()

        let status = await playback.currentStatus
        let replacementSelects = await secondGateway.selectProtocolCount
        let staleSelects = await firstGateway.selectProtocolCount
        let replacementStopped = await secondTransport.stopped
        XCTAssertEqual(status, .connected)
        XCTAssertEqual(replacementSelects, 1)
        XCTAssertEqual(staleSelects, 1)
        XCTAssertFalse(replacementStopped, "a late READY must not stop the replacement UDP transport")

        await playback.disconnect()
    }

    func testCancellingStaleSpeechCannotFailReplacementConnection() async throws {
        let server = makeVoiceServerInfo()
        let firstGateway = FakeVoiceGateway(server: server)
        let secondGateway = FakeVoiceGateway(server: server)
        let firstTransport = FakeVoiceTransport()
        let secondTransport = FakeVoiceTransport()
        let pipeline = SequencedVoicePipeline(
            gateways: [firstGateway, secondGateway],
            transports: [firstTransport, secondTransport]
        )
        let playback = VoicePlaybackService(
            gatewayFactory: { session, info in pipeline.makeGateway(session, info) },
            transportFactory: { host, port in pipeline.makeTransport(host, port) }
        )

        let firstConnect = Task { try await playback.connect(server: server) }
        await waitUntil { await firstGateway.connectCount == 1 }
        await firstGateway.emitReady()
        await firstGateway.emitSessionDescription(daveProtocolVersion: nil)
        try await firstConnect.value

        await firstTransport.setSendsBlocked(true)
        let speechFinished = CompletionSignal()
        let staleSpeech = Task {
            _ = try? await playback.speak(pcm: makeRenderedBuffer(frames: 48_000))
            await speechFinished.finish()
        }
        await waitUntil { await firstTransport.blockedSendCount == 1 }

        await playback.disconnect()
        let secondConnect = Task { try await playback.connect(server: server) }
        await waitUntil { await secondGateway.connectCount == 1 }
        await secondGateway.emitReady(ssrc: 84)
        await secondGateway.emitSessionDescription(daveProtocolVersion: nil)
        try await secondConnect.value

        staleSpeech.cancel()
        await waitUntil(timeout: 1) { await speechFinished.isCompleted }

        let status = await playback.currentStatus
        let replacementStopped = await secondTransport.stopped
        XCTAssertEqual(status, .connected)
        XCTAssertFalse(replacementStopped)

        _ = await staleSpeech.result
        await playback.disconnect()
    }
}
