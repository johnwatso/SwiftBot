import AVFoundation
import XCTest
import libdave_swift
@testable import SwiftBot

final class VoicePlaybackServiceTests: XCTestCase {

    private func makePipeline(
        resumeConfirmationTimeout: Duration = .seconds(5)
    ) -> (VoicePlaybackService, FakeVoiceGateway, FakeVoiceTransport) {
        let server = makeVoiceServerInfo()
        let gateway = FakeVoiceGateway(server: server)
        let transport = FakeVoiceTransport()
        let playback = VoicePlaybackService(
            gatewayFactory: { _, _ in gateway },
            transportFactory: { _, _ in transport },
            resumeConfirmationTimeout: resumeConfirmationTimeout
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

    func testSpeakSendsFramesOverTransport() async throws {
        let (playback, gateway, transport) = makePipeline()
        try await connect(playback, gateway)

        try await playback.speak(pcm: makeRenderedBuffer())

        let packets = await transport.sentPackets
        XCTAssertFalse(packets.isEmpty, "PCM must produce RTP packets on the transport")
        let speaking = await gateway.speakingUpdates
        XCTAssertEqual(speaking.first, true)
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

    func testDaveDowngradeCompletesConnectionAndAllowsPlainAudio() async throws {
        let (playback, gateway, transport) = makePipeline()
        let connectTask = Task { try await playback.connect(server: gateway.server) }
        await waitUntil { await gateway.connectCount == 1 }
        await gateway.emitReady()
        await gateway.emitSessionDescription(daveProtocolVersion: 1)

        // Call downgrades to transport-only before the MLS handshake finishes.
        await gateway.emitPrepareTransition(version: 0, transitionId: 5)
        await waitUntil { await gateway.transitionReadyIds.contains(5) }
        await gateway.emitExecuteTransition(5)

        try await connectTask.value
        let status = await playback.currentStatus
        XCTAssertEqual(status, .connected)

        try await playback.speak(pcm: makeRenderedBuffer())
        let packets = await transport.sentPackets
        XCTAssertFalse(packets.isEmpty, "downgraded session must still send audio frames")
    }
}
