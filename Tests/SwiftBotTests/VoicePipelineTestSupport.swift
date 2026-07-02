import AVFoundation
import Foundation
import XCTest
@testable import SwiftBot

/// Polls `condition` until it holds or `timeout` elapses.
func waitUntil(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("condition not met within \(timeout)s", file: file, line: line)
}

/// A valid 48 kHz stereo render result that passes `AnnouncerAudioGuardrails`.
func makeRenderedBuffer(frames: AVAudioFrameCount = 960) -> SendableAudioBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: OpusFrameEncoder.sampleRate,
        channels: OpusFrameEncoder.channelCount,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(OpusFrameEncoder.channelCount) {
        for index in 0..<Int(frames) {
            buffer.floatChannelData![channel][index] = 0.1
        }
    }
    return SendableAudioBuffer(buffer: buffer)
}

func makeVoiceServerInfo() -> VoiceServerInfo {
    VoiceServerInfo(guildID: "100", userID: "200", sessionID: "sess", token: "tok", endpoint: "voice.example.com")
}

// MARK: - Fakes

/// Scripted stand-in for `VoiceGatewayConnection`: records outbound calls and
/// lets tests fire the server-event callbacks in any order.
actor FakeVoiceGateway: VoicePlaybackGateway {
    nonisolated let server: VoiceServerInfo

    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var resumeCount = 0
    private(set) var selectProtocolCount = 0
    private(set) var speakingUpdates: [Bool] = []
    private(set) var transitionReadyIds: [UInt64] = []
    private(set) var keyPackagesSent = 0
    private var resumeError: Error?

    private var onReady: ((VoiceReadyInfo) async -> Void)?
    private var onSessionDescription: ((VoiceSessionKey) async -> Void)?
    private var onClose: ((Int) async -> Void)?
    private var onDebug: ((String) async -> Void)?
    private var onClientsConnect: (([String]) async -> Void)?
    private var onClientDisconnect: ((String) async -> Void)?
    private var onDavePrepareEpoch: ((UInt16, UInt64) async -> Void)?
    private var onDavePrepareTransition: ((UInt16, UInt64) async -> Void)?
    private var onDaveExecuteTransition: ((UInt64) async -> Void)?
    private var onDaveMlsExternalSender: ((Data) async -> Void)?
    private var onDaveMlsProposals: ((Data) async -> Void)?
    private var onDaveMlsAnnounceCommit: ((Data, UInt64) async -> Void)?
    private var onDaveMlsWelcome: ((Data, UInt64) async -> Void)?
    private var onResumed: (() async -> Void)?

    init(server: VoiceServerInfo) {
        self.server = server
    }

    func setResumeError(_ error: Error?) { resumeError = error }

    func connect() async throws { connectCount += 1 }
    func disconnect() async { disconnectCount += 1 }
    func resume() async throws {
        resumeCount += 1
        if let resumeError { throw resumeError }
    }

    func sendSelectProtocol(address: VoiceUDPTransport.DiscoveredAddress, mode: VoiceEncryptionMode) async throws {
        selectProtocolCount += 1
    }

    func sendSpeaking(_ speaking: Bool, ssrc: UInt32) async throws {
        speakingUpdates.append(speaking)
    }

    func sendTransitionReady(transitionId: UInt64) async throws {
        transitionReadyIds.append(transitionId)
    }

    func sendMlsKeyPackage(_ package: Data) async throws { keyPackagesSent += 1 }
    func sendMlsCommitWelcome(_ payload: Data) async throws {}
    func sendInvalidCommitWelcome(transitionId: UInt64) async throws {}

    func setOnReady(_ handler: @escaping (VoiceReadyInfo) async -> Void) { onReady = handler }
    func setOnSessionDescription(_ handler: @escaping (VoiceSessionKey) async -> Void) { onSessionDescription = handler }
    func setOnClose(_ handler: @escaping (Int) async -> Void) { onClose = handler }
    func setOnDebug(_ handler: @escaping (String) async -> Void) { onDebug = handler }
    func setOnClientsConnect(_ handler: @escaping ([String]) async -> Void) { onClientsConnect = handler }
    func setOnClientDisconnect(_ handler: @escaping (String) async -> Void) { onClientDisconnect = handler }
    func setOnDavePrepareEpoch(_ handler: @escaping (UInt16, UInt64) async -> Void) { onDavePrepareEpoch = handler }
    func setOnDavePrepareTransition(_ handler: @escaping (UInt16, UInt64) async -> Void) { onDavePrepareTransition = handler }
    func setOnDaveExecuteTransition(_ handler: @escaping (UInt64) async -> Void) { onDaveExecuteTransition = handler }
    func setOnDaveMlsExternalSender(_ handler: @escaping (Data) async -> Void) { onDaveMlsExternalSender = handler }
    func setOnDaveMlsProposals(_ handler: @escaping (Data) async -> Void) { onDaveMlsProposals = handler }
    func setOnDaveMlsAnnounceCommit(_ handler: @escaping (Data, UInt64) async -> Void) { onDaveMlsAnnounceCommit = handler }
    func setOnDaveMlsWelcome(_ handler: @escaping (Data, UInt64) async -> Void) { onDaveMlsWelcome = handler }
    func setOnResumed(_ handler: @escaping () async -> Void) { onResumed = handler }

    // Test drivers

    func emitReady(ssrc: UInt32 = 42) async {
        await onReady?(VoiceReadyInfo(
            ssrc: ssrc,
            ip: "203.0.113.9",
            port: 4000,
            modes: [VoiceEncryptionMode.aeadAes256GcmRtpSize.rawValue]
        ))
    }

    func emitSessionDescription(daveProtocolVersion: UInt16?) async {
        await onSessionDescription?(VoiceSessionKey(
            secretKey: Data(repeating: 7, count: 32),
            mode: .aeadAes256GcmRtpSize,
            daveProtocolVersion: daveProtocolVersion
        ))
    }

    func emitClose(_ code: Int) async { await onClose?(code) }
    func emitResumed() async { await onResumed?() }
    func emitPrepareTransition(version: UInt16, transitionId: UInt64) async {
        await onDavePrepareTransition?(version, transitionId)
    }
    func emitExecuteTransition(_ transitionId: UInt64) async {
        await onDaveExecuteTransition?(transitionId)
    }
    func emitPrepareEpoch(version: UInt16, epoch: UInt64) async {
        await onDavePrepareEpoch?(version, epoch)
    }
}

/// In-memory stand-in for `VoiceUDPTransport`.
actor FakeVoiceTransport: VoiceMediaTransport {
    private(set) var started = false
    private(set) var stopped = false
    private(set) var sentPackets: [Data] = []
    private(set) var probeCount = 0
    private var probeError: Error?
    private var inboundAgeSeconds: Double?

    func setProbeError(_ error: Error?) { probeError = error }
    func setInboundAgeSeconds(_ seconds: Double?) { inboundAgeSeconds = seconds }

    func start() async throws { started = true }
    func stop() { stopped = true }

    func discoverAddress(ssrc: UInt32) async throws -> VoiceUDPTransport.DiscoveredAddress {
        VoiceUDPTransport.DiscoveredAddress(ip: "198.51.100.4", port: 50_000)
    }

    func send(_ data: Data) async throws { sentPackets.append(data) }
    func startInboundMonitor() {}
    func secondsSinceLastInbound() -> Double? { inboundAgeSeconds }

    func probeLiveness(ssrc: UInt32, timeout: Duration) async throws {
        probeCount += 1
        if let probeError { throw probeError }
    }
}

/// Records `speak` calls for announcer drain tests and can be switched to
/// throw a scripted error.
actor FakeAnnouncementPlayback: AnnouncementPlayback {
    private(set) var speakCount = 0
    private var error: Error?

    func setError(_ error: Error?) { self.error = error }

    func speak(pcm wrapped: SendableAudioBuffer) async throws {
        speakCount += 1
        if let error { throw error }
    }
}
