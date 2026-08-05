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
    private(set) var keyPackagePayloads: [Data] = []
    private(set) var commitWelcomePayloads: [Data] = []
    private(set) var invalidCommitWelcomeIds: [UInt64] = []
    private var resumeError: Error?
    /// Intentionally non-cooperative test switch. It models a socket connect
    /// implementation that does not return promptly when cancellation is
    /// requested, so lifecycle tests can verify that the public pipeline call
    /// still resolves on disconnect.
    private var connectBlocked = false
    private var blockedConnectContinuations: [CheckedContinuation<Void, Never>] = []

    private var onReady: ((VoiceReadyInfo) async -> Void)?
    private var onSessionDescription: ((VoiceSessionKey) async -> Void)?
    private var onProtocolError: ((String) async -> Void)?
    private var onClose: ((Int) async -> Void)?
    private var onDebug: ((String) async -> Void)?
    private var onClientsConnect: (([String]) async -> Void)?
    private var onClientDisconnect: ((String) async -> Void)?
    private var onDavePrepareEpoch: ((UInt16, UInt64, UInt64) async -> Void)?
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
    func setConnectBlocked(_ blocked: Bool) { connectBlocked = blocked }

    func releaseBlockedConnects() {
        let continuations = blockedConnectContinuations
        blockedConnectContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func connect() async throws {
        connectCount += 1
        guard connectBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedConnectContinuations.append(continuation)
        }
    }
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

    func sendMlsKeyPackage(_ package: Data) async throws {
        keyPackagesSent += 1
        keyPackagePayloads.append(package)
    }

    func sendMlsCommitWelcome(_ payload: Data) async throws {
        commitWelcomePayloads.append(payload)
    }

    func sendInvalidCommitWelcome(transitionId: UInt64) async throws {
        invalidCommitWelcomeIds.append(transitionId)
    }

    func setOnReady(_ handler: @escaping (VoiceReadyInfo) async -> Void) { onReady = handler }
    func setOnSessionDescription(_ handler: @escaping (VoiceSessionKey) async -> Void) { onSessionDescription = handler }
    func setOnProtocolError(_ handler: @escaping (String) async -> Void) { onProtocolError = handler }
    func setOnClose(_ handler: @escaping (Int) async -> Void) { onClose = handler }
    func setOnDebug(_ handler: @escaping (String) async -> Void) { onDebug = handler }
    func setOnClientsConnect(_ handler: @escaping ([String]) async -> Void) { onClientsConnect = handler }
    func setOnClientDisconnect(_ handler: @escaping (String) async -> Void) { onClientDisconnect = handler }
    func setOnDavePrepareEpoch(_ handler: @escaping (UInt16, UInt64, UInt64) async -> Void) { onDavePrepareEpoch = handler }
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
    func emitProtocolError(_ reason: String) async { await onProtocolError?(reason) }
    func emitResumed() async { await onResumed?() }
    func emitPrepareTransition(version: UInt16, transitionId: UInt64) async {
        await onDavePrepareTransition?(version, transitionId)
    }
    func emitExecuteTransition(_ transitionId: UInt64) async {
        await onDaveExecuteTransition?(transitionId)
    }
    func emitPrepareEpoch(version: UInt16, epoch: UInt64, transitionId: UInt64) async {
        await onDavePrepareEpoch?(version, epoch, transitionId)
    }
    func emitMlsExternalSender(_ data: Data) async {
        await onDaveMlsExternalSender?(data)
    }
    func emitMlsProposals(_ data: Data) async {
        await onDaveMlsProposals?(data)
    }
    func emitMlsAnnounceCommit(_ data: Data, transitionId: UInt64) async {
        await onDaveMlsAnnounceCommit?(data, transitionId)
    }
    func emitMlsWelcome(_ data: Data, transitionId: UInt64) async {
        await onDaveMlsWelcome?(data, transitionId)
    }
}

/// In-memory stand-in for `VoiceUDPTransport`.
actor FakeVoiceTransport: VoiceMediaTransport {
    private(set) var started = false
    private(set) var stopped = false
    private(set) var sentPackets: [Data] = []
    private(set) var blockedSendCount = 0
    /// Like `FakeVoiceGateway.connectBlocked`, this deliberately ignores task
    /// cancellation until the test releases it. It gives us a deterministic
    /// way to exercise a stale speech send finishing after a replacement
    /// connection is already active.
    private var sendsBlocked = false
    private var blockedSendContinuations: [CheckedContinuation<Void, Never>] = []

    func setSendsBlocked(_ blocked: Bool) { sendsBlocked = blocked }

    func releaseBlockedSends() {
        let continuations = blockedSendContinuations
        blockedSendContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func start() async throws { started = true }
    func stop() { stopped = true }

    func discoverAddress(ssrc: UInt32) async throws -> VoiceUDPTransport.DiscoveredAddress {
        VoiceUDPTransport.DiscoveredAddress(ip: "198.51.100.4", port: 50_000)
    }

    func send(_ data: Data) async throws {
        if sendsBlocked {
            blockedSendCount += 1
            await withCheckedContinuation { continuation in
                blockedSendContinuations.append(continuation)
            }
        }
        sentPackets.append(data)
    }
}

/// Thread-safe synchronous factory script for a sequence of reconnects.
/// `VoicePlaybackService` factories are synchronous by design, so an actor
/// cannot serve this role without changing production interfaces. The lock is
/// confined to test setup and lets tests intentionally retain old gateway and
/// transport instances for late-callback scenarios.
final class SequencedVoicePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var gateways: [FakeVoiceGateway]
    private var transports: [FakeVoiceTransport]
    private var gatewayIndex = 0
    private var transportIndex = 0

    init(gateways: [FakeVoiceGateway], transports: [FakeVoiceTransport]) {
        self.gateways = gateways
        self.transports = transports
    }

    func makeGateway(_: URLSession, _: VoiceServerInfo) -> any VoicePlaybackGateway {
        lock.lock()
        defer { lock.unlock() }
        precondition(gatewayIndex < gateways.count, "test requested more gateways than scripted")
        let gateway = gateways[gatewayIndex]
        gatewayIndex += 1
        return gateway
    }

    func makeTransport(_: String, _: UInt16) -> any VoiceMediaTransport {
        lock.lock()
        defer { lock.unlock() }
        precondition(transportIndex < transports.count, "test requested more transports than scripted")
        let transport = transports[transportIndex]
        transportIndex += 1
        return transport
    }
}

/// Records `speak` calls for announcer drain tests and can be switched to
/// throw a scripted error.
actor FakeAnnouncementPlayback: AnnouncementPlayback {
    private(set) var speakCount = 0
    private var error: Error?
    private var delay: Duration?

    func setError(_ error: Error?) { self.error = error }
    func setDelay(_ delay: Duration?) { self.delay = delay }

    func speak(pcm wrapped: SendableAudioBuffer) async throws {
        speakCount += 1
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let error { throw error }
    }
}
