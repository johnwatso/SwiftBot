import AVFoundation
import Foundation
import OSLog
import libdave_swift

/// Top-level coordinator for one Discord voice connection. Owns the WS state
/// machine, UDP transport, Opus encoder, RTP builder, and encryption state.
/// Once `connect(server:)` returns successfully the caller can submit PCM
/// audio via `speak(pcm:)` and the service will pace 20 ms Opus frames out
/// over UDP.
actor VoicePlaybackService {
    private static let logger = Logger(subsystem: "com.swiftbot", category: "voice.playback")

    enum Status: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case disconnecting
        case failed(String)
    }

    typealias GatewayFactory = @Sendable (URLSession, VoiceServerInfo) -> any VoicePlaybackGateway
    typealias TransportFactory = @Sendable (String, UInt16) -> any VoiceMediaTransport

    private let session: URLSession
    private let gatewayFactory: GatewayFactory
    private let transportFactory: TransportFactory
    private let resumeConfirmationTimeout: Duration
    /// The ordinary connection deadline protects a malformed/abandoned voice
    /// handshake. A verified DAVE sole-member reset clears this timer because
    /// the protocol intentionally waits for a future MLS group indefinitely.
    private let connectionReadinessTimeout: Duration
    /// A downgrade is only safe after Discord sends the matching Execute
    /// Transition. If that acknowledgement is lost, keeping the old MLS
    /// context alive produces a connected-looking but silent session, so bound
    /// the wait and let the normal reconnect path rebuild both transports.
    private let daveDowngradeTransitionTimeout: Duration
    private var status: Status = .idle
    private var gateway: (any VoicePlaybackGateway)?
    private var transport: (any VoiceMediaTransport)?
    private var encryption: VoiceEncryption?
    private var rtp: RTPPacketBuilder?
    private var opus: OpusFrameEncoder?
    private var ssrc: UInt32?
    private var negotiatedMode: VoiceEncryptionMode?
    private var daveCoordinator: DaveSessionCoordinator?
    private var daveMediaRequired: Bool = false
    /// Set synchronously as soon as a DAVE epoch/reset event reaches the
    /// gateway callback, before that event is serialized behind native MLS
    /// work. This closes the tiny re-entrancy window in which one stale frame
    /// could otherwise be sent under the previous media context.
    private var daveTransitionGatePending = false
    /// The DAVE transition that owns the current fail-closed gate. A late
    /// media-ready result from an older transition must never lift a gate that
    /// was armed by a newer Prepare Epoch callback.
    private var daveTransitionGateTransitionId: UInt64?
    private var daveExternalSender: Data?
    /// DAVE gateway callbacks arrive independently from the WebSocket receive
    /// loop. Swift actors are re-entrant at `await` points, so serialize their
    /// MLS work explicitly: a Welcome must never overtake its Prepare Epoch or
    /// a replayed Execute while native MLS is processing the previous event.
    private var daveEventTail: Task<Void, Never>?
    /// libdave keeps outbound gateway messages stable until the host confirms
    /// the WebSocket write. A short bounded retry lets an in-place gateway
    /// resume resend the exact key package / transition acknowledgement rather
    /// than generating a second MLS message.
    private var daveOutboxRetryTask: Task<Void, Never>?
    private var daveOutboxRetryAttempts = 0
    /// libdave owns the cryptographic readiness watchdog. This host-side task
    /// only observes its result so a stuck mid-call refresh triggers SwiftBot's
    /// normal reconnect path instead of leaving announcements paused forever.
    private var daveReadinessObservationTask: Task<Void, Never>?
    private var daveDowngradeTransitionDeadlineTask: Task<Void, Never>?
    /// Monotonically increasing ownership token for the live connection. Every
    /// gateway callback and asynchronous worker captures this token. A delayed
    /// callback from a previous WebSocket/UDP session must never be allowed to
    /// configure, fail, or send on a newer session after a reconnect.
    private var connectionGeneration: UInt64 = 0
    /// Transition id of an announced downgrade to protocol version 0. Audio
    /// keeps flowing MLS-encrypted until the matching execute-transition lands;
    /// then the session drops to transport-only encryption. Without honouring
    /// this, we keep sending frames no other client can decrypt — the bot looks
    /// connected and "speaking" while everyone hears silence.
    private var pendingDaveDowngradeTransitionId: UInt64?
    /// Discord's epoch-1 sole-member reset arrives as Prepare Transition ID
    /// zero, immediately following (or occasionally queued just ahead of)
    /// Prepare Epoch. It is not a normal Ready/Execute exchange. Retain the
    /// signal until the coordinator has consumed the epoch, then execute it
    /// internally while keeping media fail-closed.
    private var pendingDaveSoleMemberReset = false
    private var recognizedUserIds: Set<String> = []
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyContinuationGeneration: UInt64?
    /// Preserves a synchronous gateway-connect failure for the public
    /// `connect()` caller even when the worker fails before that caller has
    /// installed its readiness continuation.
    private var lastFailureGeneration: UInt64?
    private var lastFailureReason: String?
    /// `gateway.connect()` is deliberately detached from the caller's
    /// readiness wait. Some socket implementations only finish their connect
    /// call after a close; keeping it as a cancellable worker means
    /// `disconnect()` can still resolve the public `connect()` call promptly.
    private var gatewayConnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    /// True only while a `speak(...)` call is actively transmitting audio frames.
    private var isSpeaking: Bool = false
    /// The generation that owns `isSpeaking`. Without this, a cancelled old
    /// utterance can clear the flag (or fail the session) after a new
    /// connection has already begun speaking.
    private var speakingGeneration: UInt64?
    /// Used only for diagnostics. This makes it possible to distinguish a
    /// gateway-speaking update from a first successfully encrypted UDP frame
    /// when investigating reports of a lit speaking indicator with no audio.
    private var speakingStartedAt: ContinuousClock.Instant?
    private var didSendFirstAudioFrameForSpeech = false
    /// Periodic Discord UDP keepalive. Keeps the NAT/UDP mapping alive between
    /// utterances so playback doesn't go stale — without sending RTP audio, so
    /// the speaking ring stays off while idle.
    private var keepaliveTask: Task<Void, Never>?
    private var keepaliveCounter: UInt32 = 0
    private var keepaliveFailureCount: Int = 0
    /// A path monitor can report several details for one route handoff. Once a
    /// usable new route has requested recovery, ignore the rest until the next
    /// connection generation owns a fresh UDP transport.
    private var pathRecoveryRequested = false
    /// When the current connect attempt began, used to time each handshake phase
    /// in the diagnostics log (so a slow connect can be pinpointed).
    private var connectStartedAt: ContinuousClock.Instant?
    /// When the previous DAVE log line was emitted, so each line can show the gap
    /// since the last step (Δ) — the big Δ is where the handshake stalls.
    private var lastDaveStepAt: ContinuousClock.Instant?
    /// One in-place websocket RESUME is attempted per established session
    /// before falling back to a full rejoin; reset when a session connects or
    /// a resume is confirmed.
    private var voiceResumeAttemptsRemaining: Int = 1
    private var awaitingVoiceResume: Bool = false
    private var voiceResumeConfirmationTask: Task<Void, Never>?

    private var onStatusChange: (@Sendable (Status) async -> Void)?
    private var onDebug: (@Sendable (String) async -> Void)?
    /// Fired when DAVE media becomes ready again mid-connection (a re-key or
    /// downgrade finished) so the owner can resume paused announcement reads
    /// without waiting for a full reconnect.
    private var onDaveMediaReady: (@Sendable () async -> Void)?

    init(
        session: URLSession = .shared,
        gatewayFactory: @escaping GatewayFactory = { VoiceGatewayConnection(session: $0, server: $1) },
        transportFactory: @escaping TransportFactory = { VoiceUDPTransport(host: $0, port: $1) },
        resumeConfirmationTimeout: Duration = .seconds(5),
        connectionReadinessTimeout: Duration = .seconds(15),
        daveDowngradeTransitionTimeout: Duration = .seconds(12)
    ) {
        self.session = session
        self.gatewayFactory = gatewayFactory
        self.transportFactory = transportFactory
        self.resumeConfirmationTimeout = resumeConfirmationTimeout
        self.connectionReadinessTimeout = connectionReadinessTimeout
        self.daveDowngradeTransitionTimeout = daveDowngradeTransitionTimeout
    }

    func setOnStatusChange(_ handler: @escaping @Sendable (Status) async -> Void) {
        onStatusChange = handler
    }

    func setOnDebug(_ handler: @escaping @Sendable (String) async -> Void) {
        onDebug = handler
    }

    func setOnDaveMediaReady(_ handler: @escaping @Sendable () async -> Void) {
        onDaveMediaReady = handler
    }

    var currentStatus: Status { status }

    /// Run the full voice handshake: WS connect → READY → IP discovery →
    /// SELECT_PROTOCOL → SESSION_DESCRIPTION. Returns once the encrypted
    /// audio pipeline is ready to accept frames.
    func connect(server: VoiceServerInfo) async throws {
        switch status {
        case .idle, .failed:
            break
        case .connecting, .connected, .disconnecting:
            // Returning "success" here without a pipeline is how a phantom
            // Connected state happens when two connect paths race — surface
            // the conflict to the caller instead.
            throw VoicePipelineError.unexpectedPayload("voice connect requested while the pipeline is \(label(for: status)); disconnect first")
        }

        let generation = beginConnection()
        await setStatus(.connecting)
        connectStartedAt = ContinuousClock().now
        lastDaveStepAt = nil
        pendingDaveDowngradeTransitionId = nil
        pendingDaveSoleMemberReset = false
        daveTransitionGatePending = false
        daveTransitionGateTransitionId = nil
        voiceResumeAttemptsRemaining = 1
        awaitingVoiceResume = false
        voiceResumeConfirmationTask?.cancel()
        voiceResumeConfirmationTask = nil
        daveOutboxRetryAttempts = 0
        pathRecoveryRequested = false
        if Task.isCancelled {
            await cancelConnectionIfCurrent(generation)
            throw CancellationError()
        }
        startConnectionTimeout(for: generation)

        try await withTaskCancellationHandler {
            do {
                let opus = try OpusFrameEncoder()
                guard isCurrentConnection(generation) else {
                    throw VoicePipelineError.notConnected
                }
                self.opus = opus

                let gateway = gatewayFactory(session, server)
                self.gateway = gateway

                await gateway.setOnReady { [weak self] info in
                    await self?.handleReady(info, generation: generation)
                }
                await gateway.setOnSessionDescription { [weak self] key in
                    await self?.handleSessionDescription(key, generation: generation)
                }
                await gateway.setOnClose { [weak self] code in
                    await self?.handleGatewayClose(code, generation: generation)
                }
                await gateway.setOnDebug { [weak self] message in
                    await self?.debug(message, generation: generation)
                }
                await gateway.setOnProtocolError { [weak self] reason in
                    await self?.failIfCurrent("voice gateway protocol error: \(reason)", generation: generation)
                }
                await gateway.setOnClientsConnect { [weak self] userIds in
                    await self?.enqueueDaveGatewayEvent(generation: generation) { service in
                        await service.handleClientsConnect(userIds, generation: generation)
                    }
                }
                await gateway.setOnClientDisconnect { [weak self] userId in
                    await self?.enqueueDaveGatewayEvent(generation: generation) { service in
                        await service.handleClientDisconnect(userId, generation: generation)
                    }
                }
                await gateway.setOnDavePrepareEpoch { [weak self] protocolVersion, epoch, transitionId in
                    // This is deliberately a separate actor hop before the
                    // serialized MLS event. `enqueueDaveGatewayEvent` can be
                    // waiting on a slow native callback while audio is active.
                    await self?.armDaveTransitionGate(
                        transitionId: transitionId,
                        generation: generation
                    )
                    await self?.enqueueDaveGatewayEvent(generation: generation) { service in
                        await service.handleDavePrepareEpoch(
                            protocolVersion: protocolVersion,
                            epoch: epoch,
                            transitionId: transitionId,
                            generation: generation
                        )
                    }
                }
                await gateway.setOnDavePrepareTransition { [weak self] protocolVersion, transitionId in
                    if transitionId == 0 || protocolVersion > 0 {
                        await self?.armDaveTransitionGate(
                            transitionId: transitionId,
                            generation: generation
                        )
                    }
                    await self?.enqueueDaveGatewayEvent(generation: generation) { service in
                        await service.handleDavePrepareTransition(
                            protocolVersion: protocolVersion,
                            transitionId: transitionId,
                            generation: generation
                        )
                    }
                }
                await gateway.setOnDaveExecuteTransition { [weak self] transitionId in
                    await self?.enqueueDaveGatewayEvent(generation: generation) { service in
                        await service.handleDaveExecuteTransition(transitionId, generation: generation)
                    }
                }
                await gateway.setOnDaveMlsExternalSender { [weak self] data in
                    await self?.enqueueDaveGatewayEvent(generation: generation) { service in
                        await service.handleDaveExternalSender(data, generation: generation)
                    }
                }
                await gateway.setOnDaveMlsProposals { [weak self] data in
                    await self?.enqueueDaveGatewayEvent(generation: generation) { service in
                        await service.handleDaveProposals(data, generation: generation)
                    }
                }
                await gateway.setOnDaveMlsAnnounceCommit { [weak self] data, transitionId in
                    await self?.enqueueDaveGatewayEvent(generation: generation) { service in
                        await service.handleDaveAnnounceCommit(data, transitionId: transitionId, generation: generation)
                    }
                }
                await gateway.setOnDaveMlsWelcome { [weak self] data, transitionId in
                    await self?.enqueueDaveGatewayEvent(generation: generation) { service in
                        await service.handleDaveWelcome(data, transitionId: transitionId, generation: generation)
                    }
                }
                await gateway.setOnResumed { [weak self] in
                    await self?.enqueueDaveGatewayEvent(generation: generation) { service in
                        await service.handleGatewayResumed(generation: generation)
                    }
                }

                guard isCurrentConnection(generation) else {
                    throw VoicePipelineError.notConnected
                }
                startGatewayConnection(gateway, generation: generation)
                try await waitForConnectionReadiness(generation)
            } catch {
                await failIfCurrent(
                    "voice connect failed: \(error.localizedDescription)",
                    generation: generation
                )
                throw error
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelConnectionIfCurrent(generation)
            }
        }
    }

    func disconnect() async {
        let oldGateway = gateway
        let oldTransport = transport
        let oldDaveCoordinator = daveCoordinator
        let continuation = readyContinuation

        invalidateConnection()
        readyContinuation = nil
        readyContinuationGeneration = nil
        await setStatus(.disconnecting)
        gateway = nil
        transport = nil
        encryption = nil
        rtp = nil
        opus = nil
        ssrc = nil
        negotiatedMode = nil
        recognizedUserIds.removeAll()
        if oldDaveCoordinator != nil {
            await daveLog("DAVE session torn down; MLS coordinator reset.")
        }
        daveCoordinator = nil
        daveMediaRequired = false
        daveTransitionGatePending = false
        daveTransitionGateTransitionId = nil
        daveExternalSender = nil
        pendingDaveDowngradeTransitionId = nil
        pendingDaveSoleMemberReset = false
        connectStartedAt = nil
        lastDaveStepAt = nil
        continuation?.resume(throwing: VoicePipelineError.notConnected)
        await oldGateway?.disconnect()
        await oldTransport?.stop()
        await oldDaveCoordinator?.reset()
        await setStatus(.idle)
    }

    func getDaveDiagnostics() async -> DaveDiagnostics? {
        if let coordinator = daveCoordinator {
            return await coordinator.getDiagnostics()
        }
        return nil
    }

    /// The libdave coordinator is the single source of truth for DAVE media
    /// readiness. Keeping a second Boolean here caused SwiftBot to resume
    /// speech before the matching Execute Transition had installed the new
    /// outbound ratchet.
    private func isDaveMediaReadyForCurrentSession() async -> Bool {
        guard !daveTransitionGatePending else { return false }
        guard daveMediaRequired else { return true }
        guard let coordinator = daveCoordinator else { return false }
        return await coordinator.getDiagnostics().mediaReady
    }

    /// Fail closed before a DAVE event enters the serialized native callback
    /// chain. The gateway invokes this actor method before queuing the event,
    /// so a concurrently paced audio task observes the gate even if an earlier
    /// MLS event is still awaiting native work.
    private func armDaveTransitionGate(transitionId: UInt64, generation: UInt64) {
        guard isCurrentConnection(generation) else { return }
        daveMediaRequired = true
        daveTransitionGatePending = true
        daveTransitionGateTransitionId = transitionId
    }

    /// `SendableAudioBuffer` entry point so a rendered buffer can cross from the
    /// announcer actor (the wrapped `AVAudioPCMBuffer` itself isn't `Sendable`).
    func speak(pcm wrapped: SendableAudioBuffer) async throws {
        try await speak(pcm: wrapped.buffer)
    }

    /// Feed pre-resampled 48 kHz stereo Float32 PCM to the encoder. The buffer
    /// is sliced into 20 ms frames (960 samples per channel) and paced out at
    /// 20 ms intervals.
    func speak(pcm buffer: AVAudioPCMBuffer) async throws {
        let generation = connectionGeneration
        try await withTaskCancellationHandler {
            try await streamSpeech(pcm: buffer, generation: generation)
        } onCancel: {
            Task { [weak self] in
                await self?.cancelSpeechForRecovery(generation: generation)
            }
        }
    }

    private func streamSpeech(pcm buffer: AVAudioPCMBuffer, generation: UInt64) async throws {
        try Task.checkCancellation()
        guard isCurrentConnection(generation),
              status == .connected,
              let gateway = gateway,
              let transport = transport,
              let opus = opus,
              let ssrc = ssrc else {
            throw VoicePipelineError.notConnected
        }
        guard await isDaveMediaReadyForCurrentSession() else {
            throw VoicePipelineError.daveNotReady
        }
        guard isCurrentConnection(generation) else {
            throw VoicePipelineError.notConnected
        }
        do {
            try await gateway.sendSpeaking(true, ssrc: ssrc)
        } catch {
            await failIfCurrent("voice speaking update failed: \(error.localizedDescription)", generation: generation)
            throw VoicePipelineError.socketClosed
        }
        guard isCurrentConnection(generation) else {
            throw VoicePipelineError.notConnected
        }
        isSpeaking = true
        speakingGeneration = generation
        speakingStartedAt = ContinuousClock().now
        didSendFirstAudioFrameForSpeech = false
        defer {
            Task { [weak self] in
                await self?.finishSpeech(generation: generation, gateway: gateway, ssrc: ssrc)
            }
        }

        let samplesPerFrame = Int(OpusFrameEncoder.samplesPerFrame)
        let channels = Int(OpusFrameEncoder.channelCount)
        let totalFrames = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData else { return }
        let interleaved = buffer.format.isInterleaved
        let frameDuration = OpusFrameEncoder.frameDuration

        let clock = ContinuousClock()
        var nextDeadline = clock.now

        var processed = 0
        while processed < totalFrames {
            try Task.checkCancellation()
            let chunkFrames = min(samplesPerFrame, totalFrames - processed)
            guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: opus.format, frameCapacity: AVAudioFrameCount(samplesPerFrame)) else {
                break
            }
            chunkBuffer.frameLength = AVAudioFrameCount(samplesPerFrame)
            if let dest = chunkBuffer.floatChannelData {
                if interleaved {
                    // Source is interleaved Float32; only one channel pointer.
                    let src = channelData[0]
                    let dst = dest[0]
                    let copy = chunkFrames * channels
                    for i in 0..<copy {
                        dst[i] = src[processed * channels + i]
                    }
                    // Zero-pad the tail of the final partial frame.
                    if chunkFrames < samplesPerFrame {
                        for i in copy..<(samplesPerFrame * channels) {
                            dst[i] = 0
                        }
                    }
                } else {
                    for c in 0..<channels {
                        let src = channelData[c]
                        let dst = dest[c]
                        for i in 0..<chunkFrames {
                            dst[i] = src[processed + i]
                        }
                        for i in chunkFrames..<samplesPerFrame {
                            dst[i] = 0
                        }
                    }
                }
            }
            do {
                try await sendFrame(chunkBuffer, transport: transport, generation: generation)
            } catch VoicePipelineError.daveNotReady {
                throw VoicePipelineError.daveNotReady
            } catch VoicePipelineError.notConnected {
                throw VoicePipelineError.notConnected
            } catch let error as DaveError where error.recoveryHint == .retryLater {
                // libdave 2.0.1 uses this for a normal transition race (for
                // example mediaNotReady while Execute is being applied). Drop
                // the current utterance into the announcer's bounded DAVE
                // retry path instead of tearing down an otherwise healthy WS.
                await debug("DAVE media changed while encrypting audio; pausing this read until the matching transition is ready.", generation: generation)
                throw VoicePipelineError.daveNotReady
            } catch {
                await failIfCurrent("voice audio send failed: \(error.localizedDescription)", generation: generation)
                throw VoicePipelineError.socketClosed
            }
            processed += chunkFrames

            nextDeadline = nextDeadline.advanced(by: .milliseconds(Int(frameDuration * 1000)))
            try await clock.sleep(until: nextDeadline)
        }

        // Standard Discord end-of-speech marker: a short burst of Opus silence
        // flushes the receiving decoder so the next utterance isn't clipped.
        do {
            try await sendTrailingSilence(5, transport: transport, generation: generation)
        } catch VoicePipelineError.daveNotReady {
            throw VoicePipelineError.daveNotReady
        } catch VoicePipelineError.notConnected {
            throw VoicePipelineError.notConnected
        } catch let error as DaveError where error.recoveryHint == .retryLater {
            await debug("DAVE media changed while finalizing audio; pausing this read until the matching transition is ready.", generation: generation)
            throw VoicePipelineError.daveNotReady
        } catch {
            await failIfCurrent("voice end-of-speech send failed: \(error.localizedDescription)", generation: generation)
            throw VoicePipelineError.socketClosed
        }
    }

    /// Cancellation is a reliability boundary, not merely an early return:
    /// stop using the potentially wedged voice session so AppModel's existing
    /// bounded auto-rejoin can establish a fresh WebSocket and UDP transport.
    private func cancelSpeechForRecovery(generation: UInt64) async {
        guard isCurrentConnection(generation),
              speakingGeneration == generation,
              isSpeaking,
              status == .connected else { return }
        await debug("Voice playback was cancelled by its deadline; recovering the session.")
        await failIfCurrent("voice playback timed out", generation: generation)
    }

    /// Send `count` Opus silence frames at the end of an utterance. This is the
    /// standard Discord voice "end of speech" signal: it flushes the receiving
    /// client's Opus decoder so the next utterance starts cleanly. We do NOT
    /// send silence while idle — that would keep packets flowing on our SSRC and
    /// light the "speaking" ring continuously (Discord can't see the encrypted
    /// payload is silence, so any packet counts as activity).
    private func sendTrailingSilence(
        _ count: Int,
        transport: any VoiceMediaTransport,
        generation: UInt64
    ) async throws {
        guard isCurrentConnection(generation) else { throw VoicePipelineError.notConnected }
        // A DAVE Prepare can race the end-of-speech marker. Silence is still
        // media, so it must obey the same coordinator-owned gate as real Opus
        // frames; otherwise the final five packets can leak transport-only
        // payloads immediately after an upgrade is announced.
        guard await isDaveMediaReadyForCurrentSession() else { throw VoicePipelineError.daveNotReady }
        guard isCurrentConnection(generation),
              var rtp = self.rtp,
              var encryption = self.encryption,
              let ssrc = ssrc else { throw VoicePipelineError.notConnected }
        let clock = ContinuousClock()
        var nextDeadline = clock.now
        for _ in 0..<count {
            try Task.checkCancellation()
            guard isCurrentConnection(generation) else { throw VoicePipelineError.notConnected }
            guard await isDaveMediaReadyForCurrentSession() else { throw VoicePipelineError.daveNotReady }
            guard isCurrentConnection(generation) else { throw VoicePipelineError.notConnected }
            let header = rtp.nextHeader(samplesPerChannel: UInt32(OpusFrameEncoder.samplesPerFrame))
            let plainPayload = RTPPacketBuilder.opusSilenceFrame
            let encryptedPayload: Data
            if let coordinator = daveCoordinator {
                encryptedPayload = try await coordinator.encryptDiscordAudioFrame(plainPayload, ssrc: ssrc)
                guard isCurrentConnection(generation) else { throw VoicePipelineError.notConnected }
            } else {
                encryptedPayload = plainPayload
            }
            let packet = try encryption.seal(rtpHeader: header, payload: encryptedPayload)
            try await transport.send(packet)
            await noteFirstAudioFrameSent(generation: generation)
            guard isCurrentConnection(generation) else { throw VoicePipelineError.notConnected }
            nextDeadline = nextDeadline.advanced(by: .milliseconds(Int(OpusFrameEncoder.frameDuration * 1000)))
            try await clock.sleep(until: nextDeadline)
        }
        guard isCurrentConnection(generation) else { throw VoicePipelineError.notConnected }
        self.rtp = rtp
        self.encryption = encryption
    }

    // MARK: - Private

    private func sendFrame(
        _ buffer: AVAudioPCMBuffer,
        transport: any VoiceMediaTransport,
        generation: UInt64
    ) async throws {
        guard isCurrentConnection(generation),
              let opus = opus,
              var rtp = self.rtp,
              var encryption = self.encryption,
              let ssrc = ssrc else {
            throw VoicePipelineError.notConnected
        }
        guard await isDaveMediaReadyForCurrentSession() else {
            throw VoicePipelineError.daveNotReady
        }
        guard isCurrentConnection(generation) else {
            throw VoicePipelineError.notConnected
        }
        let plainPayload = try opus.encode(buffer)
        let encryptedPayload: Data
        if let coordinator = daveCoordinator {
            encryptedPayload = try await coordinator.encryptDiscordAudioFrame(plainPayload, ssrc: ssrc)
            guard isCurrentConnection(generation) else {
                throw VoicePipelineError.notConnected
            }
        } else {
            encryptedPayload = plainPayload
        }
        let header = rtp.nextHeader(samplesPerChannel: UInt32(OpusFrameEncoder.samplesPerFrame))
        let packet = try encryption.seal(rtpHeader: header, payload: encryptedPayload)
        try await transport.send(packet)
        await noteFirstAudioFrameSent(generation: generation)
        guard isCurrentConnection(generation) else {
            throw VoicePipelineError.notConnected
        }
        self.rtp = rtp
        self.encryption = encryption
    }

    private func finishSpeech(
        generation: UInt64,
        gateway: any VoicePlaybackGateway,
        ssrc: UInt32
    ) async {
        guard speakingGeneration == generation else { return }
        isSpeaking = false
        speakingGeneration = nil
        speakingStartedAt = nil
        didSendFirstAudioFrameForSpeech = false
        guard isCurrentConnection(generation) else { return }
        try? await gateway.sendSpeaking(false, ssrc: ssrc)
    }

    private func noteFirstAudioFrameSent(generation: UInt64) async {
        guard isCurrentConnection(generation),
              speakingGeneration == generation,
              !didSendFirstAudioFrameForSpeech,
              let speakingStartedAt else { return }
        didSendFirstAudioFrameForSpeech = true
        let elapsed = Self.format(ContinuousClock().now - speakingStartedAt)
        await debug("Voice speaking update sent; first encrypted UDP audio frame sent \(elapsed) later.", generation: generation)
    }

    private func handleReady(_ info: VoiceReadyInfo, generation: UInt64) async {
        guard isCurrentConnection(generation), let gateway else { return }
        guard ssrc == nil, transport == nil, negotiatedMode == nil else {
            await debug("Ignoring duplicate voice READY for the active connection.", generation: generation)
            return
        }
        guard let mode = VoiceEncryptionMode.select(from: info.modes) else {
            await failIfCurrent("no supported encryption mode in \(info.modes)", generation: generation)
            return
        }

        ssrc = info.ssrc
        rtp = RTPPacketBuilder(ssrc: info.ssrc)
        negotiatedMode = mode
        await debug("[+\(elapsedSinceConnect())] Voice gateway ready; selected transport encryption: \(mode.rawValue).")
        guard isCurrentConnection(generation) else { return }

        let existingTransport = transport
        let udp = transportFactory(info.ip, info.port)
        transport = udp
        if let existingTransport {
            await existingTransport.stop()
        }
        guard isCurrentConnection(generation) else {
            await udp.stop()
            return
        }
        await udp.setOnNetworkPathChange { [weak self] previous, current in
            await self?.handleVoiceNetworkPathChange(
                previous: previous,
                current: current,
                generation: generation
            )
        }
        do {
            try await udp.start()
            guard isCurrentConnection(generation) else {
                await udp.stop()
                return
            }
            let address = try await udp.discoverAddress(ssrc: info.ssrc)
            guard isCurrentConnection(generation) else {
                await udp.stop()
                return
            }
            await debug("[+\(elapsedSinceConnect())] Voice UDP discovery returned \(address.ip):\(address.port); selecting protocol.")
            try await gateway.sendSelectProtocol(address: address, mode: mode)
            guard isCurrentConnection(generation) else {
                await udp.stop()
                return
            }
        } catch {
            if isCurrentConnection(generation) {
                await failIfCurrent("ip discovery failed: \(error.localizedDescription)", generation: generation)
            } else {
                await udp.stop()
            }
        }
    }

    private func handleSessionDescription(_ key: VoiceSessionKey, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        guard encryption == nil else {
            await debug("Ignoring duplicate voice SESSION_DESCRIPTION for the active connection.", generation: generation)
            return
        }
        guard negotiatedMode == key.mode else {
            await failIfCurrent(
                "voice session description mode \(key.mode.rawValue) does not match negotiated mode \(negotiatedMode?.rawValue ?? "none")",
                generation: generation
            )
            return
        }
        guard key.hasValidSecretKeyLength else {
            await failIfCurrent("voice session description did not contain a 32-byte secret key", generation: generation)
            return
        }
        do {
            encryption = try VoiceEncryption(secretKey: key.secretKey, mode: key.mode)
        } catch {
            await failIfCurrent("voice transport encryption setup failed: \(error.localizedDescription)", generation: generation)
            return
        }
        guard isCurrentConnection(generation) else { return }

        if let daveVersion = key.daveProtocolVersion, daveVersion > 0, ssrc != nil, let gateway {
            // Mark media as DAVE-gated before scheduling any native work. The
            // queued event processor then establishes the MLS group before it
            // accepts later Prepare/Welcome/Execute gateway messages.
            daveMediaRequired = true
            guard isCurrentConnection(generation) else { return }
            enqueueDaveGatewayEvent(generation: generation) { service in
                await service.establishDaveSession(
                    protocolVersion: daveVersion,
                    reason: "session description",
                    applyCachedExternalSender: true,
                    generation: generation
                )
            }
            await daveLog("DAVE negotiated version \(daveVersion); preparing MLS session for guild \(gateway.server.guildID).")
        } else {
            daveMediaRequired = false
            await daveLog("DAVE not negotiated for this voice session; media is transport-encrypted only.")
            await completeConnection(reason: "transport encryption ready", generation: generation)
        }
    }

    /// Create a fresh MLS coordinator for `protocolVersion`. libdave owns the
    /// key-package order and queues outbound work until this host confirms the
    /// WebSocket write. `applyCachedExternalSender` is false for an Op 24
    /// upgrade so Prepare Epoch is consumed before a cached sender can issue a
    /// key package for the wrong freshly-created group.
    private func establishDaveSession(
        protocolVersion: UInt16,
        reason: String,
        applyCachedExternalSender: Bool,
        generation: UInt64
    ) async {
        guard isCurrentConnection(generation), let gateway else { return }
        guard let groupId = UInt64(gateway.server.guildID), groupId > 0 else {
            await failIfCurrent(
                "DAVE requires a non-zero numeric guild ID; received \(gateway.server.guildID)",
                generation: generation
            )
            return
        }
        daveMediaRequired = true
        pendingDaveDowngradeTransitionId = nil
        let previousCoordinator = daveCoordinator
        daveCoordinator = nil
        await previousCoordinator?.reset()
        guard isCurrentConnection(generation) else { return }
        // A stable auth session id keyed on the bot user gives libdave a
        // persisted MLS signature identity across sessions.
        let coordinator = DaveSessionCoordinator(authSessionId: gateway.server.userID)
        do {
            recognizedUserIds.insert(gateway.server.userID)
            try await coordinator.configureForDiscordVoice(
                groupId: groupId,
                selfUserId: gateway.server.userID,
                protocolVersion: protocolVersion
            )
            guard isCurrentConnection(generation) else {
                await coordinator.reset()
                return
            }
            self.daveCoordinator = coordinator
            await daveLog("DAVE MLS coordinator configured after \(reason) (self user \(gateway.server.userID)).")
            if applyCachedExternalSender, let externalSender = daveExternalSender {
                let result = try await consumeDaveGatewayEvent(
                    .externalSender(externalSender),
                    reason: "\(reason) (external sender cached)",
                    generation: generation
                )
                guard isCurrentConnection(generation) else { return }
                await handleDaveGatewayResult(
                    result,
                    reason: "\(reason) (external sender cached)",
                    generation: generation
                )
                await daveLog("DAVE external sender reapplied after \(reason).")
            } else {
                await daveLog("Waiting for DAVE external sender before publishing a key package.")
                await verbose("awaiting Discord → MLS external-sender package (a large next Δ means Discord is the slow side here)")
            }
        } catch {
            await daveLogError("DAVE coordinator initialization failed (\(reason)): \(error.localizedDescription)")
            await failIfCurrent("DAVE coordinator initialization failed: \(error.localizedDescription)", generation: generation)
        }
    }

    /// Discord announces transport-only downgrades with op 21. MLS protocol
    /// upgrades/rekeys arrive through op 24 (Prepare Epoch), where Discord
    /// supplies the transition ID that must later be matched by Execute.
    private func handleDavePrepareTransition(
        protocolVersion: UInt16,
        transitionId: UInt64,
        generation: UInt64
    ) async {
        guard isCurrentConnection(generation) else { return }
        if transitionId == 0 {
            // The sole-member reset is a special initialization signal, not a
            // transport-only downgrade. Set the gate before the first await so
            // an in-flight announcer cannot slip a plaintext frame through.
            daveMediaRequired = true
            pendingDaveSoleMemberReset = true
            await daveLog("DAVE sole-member reset received (Prepare Transition id 0); media is paused pending MLS group establishment.")
            await executePendingDaveSoleMemberResetIfPossible(generation: generation)
            return
        }
        if protocolVersion == 0 {
            await daveLog("DAVE prepare transition (id \(transitionId)): call downgrading to transport-only encryption.")
            guard isCurrentConnection(generation) else { return }
            pendingDaveDowngradeTransitionId = transitionId
            guard let gateway else { return }
            do {
                try await gateway.sendTransitionReady(transitionId: transitionId)
            } catch {
                guard isCurrentConnection(generation) else { return }
                await failIfCurrent(
                    "DAVE downgrade transition-ready send failed: \(error.localizedDescription)",
                    generation: generation
                )
                return
            }
            guard isCurrentConnection(generation) else { return }
            startDaveDowngradeTransitionDeadline(transitionId: transitionId, generation: generation)
            await daveLog("DAVE downgrade prepared (id \(transitionId)); transition-ready sent, awaiting execute-transition.")
        } else {
            await failIfCurrent(
                "unsupported non-zero DAVE Prepare Transition \(transitionId) (version \(protocolVersion)); expected Prepare Epoch",
                generation: generation
            )
        }
    }

    /// Drop the MLS session and return to transport-only media. From here on
    /// frames go out Opus-in-transport-encryption only, which is what every
    /// other client in a downgraded call expects to receive.
    private func applyDaveDowngrade(transitionId: UInt64, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        pendingDaveDowngradeTransitionId = nil
        daveDowngradeTransitionDeadlineTask?.cancel()
        daveDowngradeTransitionDeadlineTask = nil
        pendingDaveSoleMemberReset = false
        daveReadinessObservationTask?.cancel()
        daveReadinessObservationTask = nil
        let coordinator = daveCoordinator
        daveCoordinator = nil
        await coordinator?.reset()
        guard isCurrentConnection(generation) else { return }
        // The external sender belongs to the torn-down MLS group; Discord sends
        // a fresh one if the call later upgrades again.
        daveExternalSender = nil
        daveMediaRequired = false
        daveTransitionGatePending = false
        daveTransitionGateTransitionId = nil
        await daveLog("DAVE downgrade executed (id \(transitionId)); media is transport-encrypted only until Discord re-upgrades the call.")
        guard isCurrentConnection(generation) else { return }
        if status != .connected {
            await completeConnection(reason: "DAVE downgrade transition \(transitionId)", generation: generation)
        } else {
            await onDaveMediaReady?()
        }
    }

    private func handleClientsConnect(_ userIds: [String], generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        guard daveMediaRequired else {
            recognizedUserIds.formUnion(userIds)
            return
        }
        let added = userIds.filter { !recognizedUserIds.contains($0) }
        recognizedUserIds.formUnion(userIds)
        if !added.isEmpty {
            await daveLog("DAVE roster: \(added.count) client(s) joined the encrypted session (now \(recognizedUserIds.count)).")
        }
    }

    private func handleClientDisconnect(_ userId: String, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        let removed = recognizedUserIds.remove(userId) != nil
        if daveMediaRequired, removed {
            await daveLog("DAVE roster: a client left the encrypted session (now \(recognizedUserIds.count)).")
        }
    }

    private func handleDavePrepareEpoch(
        protocolVersion: UInt16,
        epoch: UInt64,
        transitionId: UInt64,
        generation: UInt64
    ) async {
        guard isCurrentConnection(generation) else { return }
        guard protocolVersion > 0, epoch > 0 else {
            await failIfCurrent(
                "invalid DAVE Prepare Epoch (version \(protocolVersion), epoch \(epoch), transition \(transitionId))",
                generation: generation
            )
            return
        }
        // This state change must precede any logging or MLS awaits. A
        // transport-only call can be upgraded mid-announcement, and one
        // plaintext RTP packet after Op24 is already a protocol violation.
        daveMediaRequired = true
        await daveLog("DAVE prepare epoch received (version \(protocolVersion), epoch \(epoch), transition \(transitionId)).")
        guard isCurrentConnection(generation) else { return }
        do {
            let createdCoordinator = daveCoordinator == nil
            if createdCoordinator {
                guard epoch == 1 else {
                    await failIfCurrent(
                        "DAVE epoch \(epoch) arrived without an MLS session; a full voice rejoin is required",
                        generation: generation
                    )
                    return
                }
                // The call is upgrading from transport-only media to DAVE
                // mid-session (e.g. the last non-DAVE client left). Without
                // joining the new MLS group we would keep sending plaintext
                // frames nobody can decode.
                await daveLog("DAVE upgrade requested mid-call; establishing a new MLS session (version \(protocolVersion)).")
                guard isCurrentConnection(generation) else { return }
                await establishDaveSession(
                    protocolVersion: protocolVersion,
                    reason: "prepare epoch \(epoch)",
                    applyCachedExternalSender: false,
                    generation: generation
                )
                guard isCurrentConnection(generation), daveCoordinator != nil else { return }
            }

            let result = try await consumeDaveGatewayEvent(
                .prepareEpoch(
                    protocolVersion: protocolVersion,
                    epoch: epoch,
                    transitionId: transitionId
                ),
                reason: "prepare epoch \(epoch)",
                generation: generation
            )
            guard isCurrentConnection(generation) else { return }
                await handleDaveGatewayResult(
                    result,
                    reason: "prepare epoch \(epoch)",
                    transitionId: transitionId,
                    generation: generation
            )
            await executePendingDaveSoleMemberResetIfPossible(generation: generation)
            guard isCurrentConnection(generation) else { return }

            // When creating a coordinator specifically for this Op 24 event,
            // register a sender cached before session creation only *after*
            // the event has recreated epoch 1. This prevents an obsolete key
            // package from being emitted for the pre-Prepare context.
            if createdCoordinator, epoch == 1, let externalSender = daveExternalSender {
                let senderResult = try await consumeDaveGatewayEvent(
                    .externalSender(externalSender),
                    reason: "prepare epoch \(epoch) (cached external sender)",
                    generation: generation
                )
                guard isCurrentConnection(generation) else { return }
                await handleDaveGatewayResult(
                    senderResult,
                    reason: "prepare epoch \(epoch) (cached external sender)",
                    transitionId: transitionId,
                    generation: generation
                )
            }
            if epoch == 1 {
                await daveLog("DAVE MLS session prepared for epoch \(epoch); awaiting execute-transition \(transitionId).")
            } else {
                await daveLog("DAVE retained MLS session prepared for epoch \(epoch); continuing on the active media context until execute-transition \(transitionId).")
            }
        } catch {
            await handleDaveGatewayError(error, context: "prepare epoch \(epoch)", generation: generation)
        }
    }

    /// Consumes a queued Op21 ID-zero sole-member reset only once its Op24
    /// epoch-1 preparation is present in libdave. This accommodates event
    /// dispatch ordering without ever sending a Transition Ready for ID zero.
    private func executePendingDaveSoleMemberResetIfPossible(generation: UInt64) async {
        guard isCurrentConnection(generation),
              pendingDaveSoleMemberReset,
              let coordinator = daveCoordinator else { return }
        let diagnostics = await coordinator.getDiagnostics()
        guard isCurrentConnection(generation), diagnostics.pendingEpoch == 1 else { return }

        pendingDaveSoleMemberReset = false
        do {
            let result = try await consumeDaveGatewayEvent(
                .executeTransition(0),
                reason: "sole-member reset",
                generation: generation
            )
            guard isCurrentConnection(generation) else { return }
            await handleDaveGatewayResult(
                result,
                reason: "sole-member reset",
                transitionId: 0,
                generation: generation
            )
            guard isCurrentConnection(generation) else { return }
            if status == .connecting {
                // This is an authenticated protocol state, not a stalled
                // handshake. Keep the voice socket alive and wait for Discord
                // to establish a real group; a gateway close/disconnect still
                // provides the normal recovery boundary.
                connectionTimeoutTask?.cancel()
                connectionTimeoutTask = nil
            }
            await daveLog("DAVE sole-member reset executed; media remains paused until a future MLS Commit or Welcome establishes a ratchet.")
        } catch {
            await handleDaveGatewayError(error, context: "sole-member reset", generation: generation)
        }
    }

    private func handleDaveExecuteTransition(_ transitionId: UInt64, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        await daveLog("DAVE execute transition received (id \(transitionId)).")
        guard isCurrentConnection(generation) else { return }
        if pendingDaveDowngradeTransitionId == transitionId {
            await applyDaveDowngrade(transitionId: transitionId, generation: generation)
            return
        }
        guard daveCoordinator != nil else {
            await daveLog("DAVE execute transition ignored; no active MLS session.")
            return
        }
        do {
            let result = try await consumeDaveGatewayEvent(
                .executeTransition(transitionId),
                reason: "execute transition \(transitionId)",
                generation: generation
            )
            guard isCurrentConnection(generation) else { return }
            await handleDaveGatewayResult(
                result,
                reason: "execute transition \(transitionId)",
                transitionId: transitionId,
                generation: generation
            )
        } catch {
            await handleDaveGatewayError(error, context: "execute transition \(transitionId)", generation: generation)
        }
    }

    /// A DAVE downgrade cannot be considered complete merely because we sent
    /// Transition Ready: Discord must authorize the exact transition with
    /// Execute. Treat a missing Execute as a recoverable connection failure
    /// rather than leaving media encrypted with a stale ratchet indefinitely.
    private func startDaveDowngradeTransitionDeadline(transitionId: UInt64, generation: UInt64) {
        guard isCurrentConnection(generation), pendingDaveDowngradeTransitionId == transitionId else { return }
        daveDowngradeTransitionDeadlineTask?.cancel()
        daveDowngradeTransitionDeadlineTask = Task { [weak self, daveDowngradeTransitionTimeout] in
            do {
                try await Task.sleep(for: daveDowngradeTransitionTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.failIfDaveDowngradeExecutionIsMissing(
                transitionId: transitionId,
                generation: generation
            )
        }
    }

    private func failIfDaveDowngradeExecutionIsMissing(
        transitionId: UInt64,
        generation: UInt64
    ) async {
        guard isCurrentConnection(generation), pendingDaveDowngradeTransitionId == transitionId else { return }
        await failIfCurrent(
            "DAVE downgrade transition \(transitionId) was not executed before its deadline",
            generation: generation
        )
    }

    private func handleDaveExternalSender(_ data: Data, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        await daveLog("DAVE external sender package received (\(data.count) bytes).")
        guard isCurrentConnection(generation) else { return }
        if let existing = daveExternalSender, existing != data {
            await failIfCurrent(
                "conflicting DAVE external sender packages were received for one voice session",
                generation: generation
            )
            return
        }

        // The sender can arrive before SESSION_DESCRIPTION / Prepare Epoch.
        // Cache it, but do not issue a key package until a configured libdave
        // coordinator accepts these exact bytes.
        if daveCoordinator == nil {
            daveExternalSender = data
            await daveLog("DAVE external sender cached until the MLS coordinator is configured.")
            return
        }
        do {
            let result = try await consumeDaveGatewayEvent(
                .externalSender(data),
                reason: "external sender",
                generation: generation
            )
            guard isCurrentConnection(generation) else { return }
            daveExternalSender = data
            await handleDaveGatewayResult(result, reason: "external sender", generation: generation)
            await daveLog("DAVE external sender registered; key package is queued only after this acceptance.")
            await verbose("awaiting Discord → MLS proposals")
        } catch {
            await handleDaveGatewayError(error, context: "external sender", generation: generation)
        }
    }

    private func handleDaveProposals(_ data: Data, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        guard let coordinator = daveCoordinator else {
            await daveLog("DAVE MLS proposals ignored before a local MLS group was configured (\(data.count) bytes).")
            return
        }
        let diagnostics = await coordinator.getDiagnostics()
        guard isCurrentConnection(generation) else { return }
        // Discord specifies that proposals received before we have a local
        // group are ignored. A configured coordinator alone is not enough:
        // it may only be waiting for the external sender/initial group.
        guard diagnostics.activeTransitionId != nil || diagnostics.appliedTransitionCount > 0 else {
            await daveLog("DAVE MLS proposals ignored before a local MLS group was established (\(data.count) bytes).")
            return
        }
        await daveLog("DAVE MLS proposals received (\(data.count) bytes).")
        do {
            let result = try await consumeDaveGatewayEvent(
                .proposals(data, recognizedUserIds: recognizedUserIds.sorted()),
                reason: "proposals",
                generation: generation
            )
            guard isCurrentConnection(generation) else { return }
            await handleDaveGatewayResult(result, reason: "proposals", generation: generation)
            await daveLog("DAVE MLS proposals processed; commit/welcome response is in the reliable outbox.")
            await verbose("awaiting Discord → announce-commit / welcome + execute-transition")
        } catch {
            await handleDaveGatewayError(error, context: "proposals", generation: generation)
        }
    }

    private func handleDaveAnnounceCommit(_ data: Data, transitionId: UInt64, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        await daveLog("DAVE announce commit received (id \(transitionId), \(data.count) bytes).")
        guard daveCoordinator != nil else {
            await failIfCurrent("DAVE commit arrived before a configured MLS session", generation: generation)
            return
        }
        do {
            let result = try await consumeDaveGatewayEvent(
                .commit(data, transitionId: transitionId),
                reason: "commit \(transitionId)",
                generation: generation
            )
            guard isCurrentConnection(generation) else { return }
            await handleDaveGatewayResult(
                result,
                reason: "commit \(transitionId)",
                transitionId: transitionId,
                generation: generation
            )
            if result.needsRecovery {
                await daveLog("DAVE commit rejected; coordinator reset and recovery actions remain queued (id \(transitionId)).")
                return
            }
            await daveLog("DAVE commit processed; transition-ready is queued (id \(transitionId)).")
        } catch {
            await handleDaveGatewayError(error, context: "commit \(transitionId)", generation: generation)
        }
    }

    private func handleDaveWelcome(_ data: Data, transitionId: UInt64, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        await daveLog("DAVE welcome received (id \(transitionId), \(data.count) bytes).")
        guard isCurrentConnection(generation), let gateway else { return }
        guard daveCoordinator != nil else {
            await failIfCurrent("DAVE welcome arrived before a configured MLS session", generation: generation)
            return
        }
        do {
            recognizedUserIds.insert(gateway.server.userID)
            let result = try await consumeDaveGatewayEvent(
                .welcome(
                    data,
                    transitionId: transitionId,
                    recognizedUserIds: recognizedUserIds.sorted()
                ),
                reason: "welcome \(transitionId)",
                generation: generation
            )
            guard isCurrentConnection(generation) else { return }
            await handleDaveGatewayResult(
                result,
                reason: "welcome \(transitionId)",
                transitionId: transitionId,
                generation: generation
            )
            if result.needsRecovery {
                await daveLog("DAVE welcome rejected; coordinator reset and recovery actions remain queued (id \(transitionId)).")
                return
            }
            await daveLog("DAVE welcome processed; transition-ready is queued (id \(transitionId)).")
        } catch {
            await handleDaveGatewayError(error, context: "welcome \(transitionId)", generation: generation)
        }
    }

    /// Reduces a gateway event inside libdave, then drains only the stable
    /// envelopes it owns. An action is acknowledged strictly after the write
    /// succeeds, so a resume can safely replay the same bytes.
    private func consumeDaveGatewayEvent(
        _ event: DiscordDaveGatewayEvent,
        reason: String,
        generation: UInt64
    ) async throws -> DiscordDaveGatewayResult {
        guard isCurrentConnection(generation), let coordinator = daveCoordinator else {
            throw VoicePipelineError.notConnected
        }
        let result = try await coordinator.consumeDiscordGatewayEvent(event)
        guard isCurrentConnection(generation) else {
            throw VoicePipelineError.notConnected
        }
        do {
            try await deliverDaveGatewayOutbox(reason: reason, generation: generation)
        } catch {
            guard isCurrentConnection(generation) else { throw VoicePipelineError.notConnected }
            await daveLogError("DAVE gateway outbox write failed (\(reason)); retaining exact action for retry: \(error.localizedDescription)")
            scheduleDaveOutboxRetry(generation: generation)
        }
        return result
    }

    private func deliverDaveGatewayOutbox(reason: String, generation: UInt64) async throws {
        guard isCurrentConnection(generation), let coordinator = daveCoordinator else {
            throw VoicePipelineError.notConnected
        }
        let envelopes = await coordinator.pendingDiscordGatewayActions()
        for envelope in envelopes {
            guard isCurrentConnection(generation) else {
                throw VoicePipelineError.notConnected
            }
            try await sendDaveOutboundAction(envelope.action, reason: reason, generation: generation)
            guard isCurrentConnection(generation) else {
                throw VoicePipelineError.notConnected
            }
            await coordinator.acknowledgeDiscordGatewayAction(envelope.id)
        }
        guard isCurrentConnection(generation) else { return }
        if await coordinator.pendingDiscordGatewayActions().isEmpty {
            daveOutboxRetryAttempts = 0
            daveOutboxRetryTask?.cancel()
            daveOutboxRetryTask = nil
        }
    }

    private func sendDaveOutboundAction(
        _ action: DiscordDaveOutboundAction,
        reason: String,
        generation: UInt64
    ) async throws {
        guard isCurrentConnection(generation), let gateway else {
            throw VoicePipelineError.notConnected
        }
        switch action {
        case .mlsKeyPackage(let data):
            try await gateway.sendMlsKeyPackage(data)
            await daveLog("DAVE MLS key package sent after \(reason).")
        case .mlsCommitWelcome(let data):
            try await gateway.sendMlsCommitWelcome(data)
            await daveLog("DAVE MLS commit/welcome sent after \(reason).")
        case .transitionReady(let transitionId):
            try await gateway.sendTransitionReady(transitionId: transitionId)
            await daveLog("DAVE transition-ready sent after \(reason) (id \(transitionId)).")
        case .invalidCommitWelcome(let transitionId):
            try await gateway.sendInvalidCommitWelcome(transitionId: transitionId)
            await daveLog("DAVE invalid commit/welcome sent after \(reason) (id \(transitionId)).")
        }
    }

    private func scheduleDaveOutboxRetry(generation: UInt64) {
        guard isCurrentConnection(generation), daveOutboxRetryTask == nil else { return }
        daveOutboxRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.enqueueDaveGatewayEvent(generation: generation) { service in
                await service.retryDaveGatewayOutbox(generation: generation)
            }
        }
    }

    private func retryDaveGatewayOutbox(generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        daveOutboxRetryTask = nil
        do {
            try await deliverDaveGatewayOutbox(reason: "outbox retry", generation: generation)
        } catch {
            guard isCurrentConnection(generation) else { return }
            daveOutboxRetryAttempts += 1
            if daveOutboxRetryAttempts >= 3 {
                await failIfCurrent(
                    "DAVE gateway actions could not be delivered after \(daveOutboxRetryAttempts) retries: \(error.localizedDescription)",
                    generation: generation
                )
            } else {
                await daveLogError("DAVE outbox retry \(daveOutboxRetryAttempts)/3 failed: \(error.localizedDescription)")
                scheduleDaveOutboxRetry(generation: generation)
            }
        }
    }

    private func handleDaveGatewayResult(
        _ result: DiscordDaveGatewayResult,
        reason: String,
        transitionId: UInt64? = nil,
        generation: UInt64
    ) async {
        guard isCurrentConnection(generation) else { return }
        if result.needsRecovery {
            await daveLog("DAVE \(reason) requested recovery (\(result.recoveryHint.rawValue)); coordinator has queued its safe recovery actions.")
        }
        guard result.mediaReady else {
            if status == .connected, daveMediaRequired {
                await updateDaveReadinessObservationIfNeeded(reason: reason, generation: generation)
            }
            if result.recoveryHint == .retryLater {
                await verbose("DAVE \(reason) is awaiting its matching MLS transition (\(result.diagnostics.handshakeState.rawValue)).")
            }
            return
        }

        if daveTransitionGatePending {
            guard daveTransitionGateTransitionId == transitionId else {
                await verbose("DAVE \(reason) reported media ready for an older transition; retaining the newer media gate.")
                return
            }
            daveTransitionGatePending = false
            daveTransitionGateTransitionId = nil
        }
        daveReadinessObservationTask?.cancel()
        daveReadinessObservationTask = nil
        if status == .connected {
            await logDaveState("\(reason); secure media active")
            await onDaveMediaReady?()
        } else {
            await completeConnection(reason: "DAVE \(reason) authorized secure media", generation: generation)
        }
    }

    private func handleDaveGatewayError(_ error: Error, context: String, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        await daveLogError("DAVE \(context) failed: \(error.localizedDescription)")
        if let error = error as? DaveError {
            switch error.recoveryHint {
            case .retryLater, .waitForExternalSender:
                if status == .connected, daveMediaRequired {
                    await updateDaveReadinessObservationIfNeeded(reason: context, generation: generation)
                }
                return
            case .none, .sendInvalidCommitWelcome, .recreateSession, .fatal:
                break
            }
        }
        await failIfCurrent("DAVE \(context) failed: \(error.localizedDescription)", generation: generation)
    }

    private func scheduleDaveReadinessObservation(reason: String, generation: UInt64) {
        guard isCurrentConnection(generation), status == .connected, daveMediaRequired else { return }
        daveReadinessObservationTask?.cancel()
        daveReadinessObservationTask = Task { [weak self] in
            // libdave expires its own watchdog at ten seconds. Observe just
            // after that boundary; this task never mutates cryptographic state.
            try? await Task.sleep(for: .seconds(11))
            guard !Task.isCancelled else { return }
            await self?.failIfDaveMediaRemainsUnavailable(reason: reason, generation: generation)
        }
    }

    /// The coordinator owns the actual transition deadline. Do not give an
    /// initialization-only state (notably the sole-member reset) a synthetic
    /// host timer just because its media is intentionally unavailable.
    private func updateDaveReadinessObservationIfNeeded(reason: String, generation: UInt64) async {
        guard isCurrentConnection(generation), status == .connected, daveMediaRequired,
              let coordinator = daveCoordinator else { return }
        let watchdog = await coordinator.evaluateMediaReadinessWatchdog()
        guard isCurrentConnection(generation) else { return }
        if case .pending = watchdog {
            scheduleDaveReadinessObservation(reason: reason, generation: generation)
        } else {
            daveReadinessObservationTask?.cancel()
            daveReadinessObservationTask = nil
        }
    }

    private func failIfDaveMediaRemainsUnavailable(reason: String, generation: UInt64) async {
        guard isCurrentConnection(generation), status == .connected, daveMediaRequired else { return }
        guard let coordinator = daveCoordinator else {
            await failIfCurrent("DAVE coordinator disappeared while waiting for \(reason)", generation: generation)
            return
        }
        let diagnostics = await coordinator.getDiagnostics()
        guard isCurrentConnection(generation), !diagnostics.mediaReady else { return }
        let watchdog = await coordinator.evaluateMediaReadinessWatchdog()
        guard isCurrentConnection(generation) else { return }
        if case .pending = watchdog {
            // A replacement event refreshed the coordinator-owned deadline
            // while this observer slept; it is not a failure yet.
            return
        }
        guard diagnostics.handshakeState == .failed else { return }
        await failIfCurrent(
            "DAVE media encryption did not recover after \(reason) (state \(diagnostics.handshakeState.rawValue))",
            generation: generation
        )
    }

    private func handleGatewayClose(_ code: Int, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        if status == .connected, isResumableVoiceClose(code), voiceResumeAttemptsRemaining > 0, let gateway = gateway {
            voiceResumeAttemptsRemaining -= 1
            awaitingVoiceResume = true
            await debug("Voice gateway closed (\(code)); attempting an in-place session resume before a full rejoin.")
            guard isCurrentConnection(generation) else { return }
            do {
                try await gateway.resume()
                guard isCurrentConnection(generation) else { return }
                startVoiceResumeConfirmationTimeout(generation: generation)
            } catch {
                guard isCurrentConnection(generation) else { return }
                awaitingVoiceResume = false
                await failIfCurrent("voice session resume failed: \(error.localizedDescription)", generation: generation)
            }
            return
        }
        if status == .connecting || status == .connected {
            await failIfCurrent("gateway closed (\(code))", generation: generation)
        }
    }

    /// Abnormal transport drops leave the voice session resumable, as does
    /// 4015 (voice server crashed). Codes like 4006/4009 invalidate the
    /// session and need the full rejoin path.
    private func isResumableVoiceClose(_ code: Int) -> Bool {
        switch code {
        case 0, 1001, 1006, 4015:
            return true
        default:
            return false
        }
    }

    private func handleGatewayResumed(generation: UInt64) async {
        guard isCurrentConnection(generation), awaitingVoiceResume else { return }
        awaitingVoiceResume = false
        voiceResumeConfirmationTask?.cancel()
        voiceResumeConfirmationTask = nil
        voiceResumeAttemptsRemaining = 1
        await debug("Voice session resumed in place; media continues on the existing transport.")
        guard daveCoordinator != nil else { return }
        do {
            try await deliverDaveGatewayOutbox(reason: "voice gateway resume", generation: generation)
        } catch {
            guard isCurrentConnection(generation) else { return }
            await daveLogError("DAVE gateway resume could not flush the retained outbox: \(error.localizedDescription)")
            scheduleDaveOutboxRetry(generation: generation)
        }
    }

    private func startVoiceResumeConfirmationTimeout(generation: UInt64) {
        guard isCurrentConnection(generation) else { return }
        voiceResumeConfirmationTask?.cancel()
        voiceResumeConfirmationTask = Task { [weak self, resumeConfirmationTimeout] in
            try? await Task.sleep(for: resumeConfirmationTimeout)
            guard !Task.isCancelled else { return }
            await self?.failIfResumeUnconfirmed(generation: generation)
        }
    }

    private func failIfResumeUnconfirmed(generation: UInt64) async {
        guard isCurrentConnection(generation), awaitingVoiceResume else { return }
        awaitingVoiceResume = false
        await failIfCurrent("voice session resume was not confirmed in time", generation: generation)
    }

    private func failIfCurrent(_ reason: String, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        await fail(reason, generation: generation)
    }

    private func fail(_ reason: String, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        Self.logger.error("voice pipeline failed: \(reason)")
        let oldGateway = gateway
        let oldTransport = transport
        let oldDaveCoordinator = daveCoordinator
        let continuation = readyContinuationGeneration == generation ? readyContinuation : nil

        lastFailureGeneration = generation
        lastFailureReason = reason

        invalidateConnection()
        readyContinuation = nil
        readyContinuationGeneration = nil
        gateway = nil
        transport = nil
        encryption = nil
        rtp = nil
        opus = nil
        ssrc = nil
        negotiatedMode = nil
        recognizedUserIds.removeAll()
        daveCoordinator = nil
        daveMediaRequired = false
        daveTransitionGatePending = false
        daveTransitionGateTransitionId = nil
        daveExternalSender = nil
        pendingDaveDowngradeTransitionId = nil
        pendingDaveSoleMemberReset = false
        connectStartedAt = nil
        lastDaveStepAt = nil
        await setStatus(.failed(reason))
        continuation?.resume(throwing: VoicePipelineError.unexpectedPayload(reason))
        await oldGateway?.disconnect()
        await oldTransport?.stop()
        await oldDaveCoordinator?.reset()
    }

    private func completeConnection(reason: String, generation: UInt64) async {
        guard isCurrentConnection(generation), status != .connected else { return }
        if daveMediaRequired {
            guard await isDaveMediaReadyForCurrentSession() else {
                await verbose("DAVE handshake is not authorized for media yet; awaiting the matching execute-transition.")
                return
            }
            guard isCurrentConnection(generation) else { return }
        }
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        await debug("Voice media ready in \(elapsedSinceConnect()): \(reason).")
        guard isCurrentConnection(generation) else { return }
        if daveMediaRequired {
            await logDaveState("secure session active")
            guard isCurrentConnection(generation) else { return }
        }
        let continuation = readyContinuationGeneration == generation ? readyContinuation : nil
        readyContinuation = nil
        readyContinuationGeneration = nil
        await setStatus(.connected)
        guard connectionGeneration == generation, status == .connected else {
            continuation?.resume(throwing: VoicePipelineError.notConnected)
            return
        }
        continuation?.resume()
        startKeepalive(generation: generation)
    }

    /// Discord UDP keepalive loop: every 5 s send an 8-byte datagram (a
    /// little-endian counter in the first 4 bytes) to keep the NAT/UDP mapping
    /// warm so the next utterance isn't dropped as stale. This is NOT an RTP
    /// audio packet, so Discord doesn't light the speaking ring for it.
    private func startKeepalive(generation: UInt64) {
        guard isCurrentConnection(generation), status == .connected else { return }
        keepaliveTask?.cancel()
        keepaliveCounter = 0
        keepaliveFailureCount = 0
        keepaliveTask = Task { [weak self] in
            let clock = ContinuousClock()
            let interval = Duration.seconds(5)
            var nextDeadline = clock.now.advanced(by: interval)
            while !Task.isCancelled {
                try? await clock.sleep(until: nextDeadline)
                nextDeadline = nextDeadline.advanced(by: interval)
                guard let self else { return }
                do {
                    guard try await self.sendKeepaliveDatagram(generation: generation) else { return }
                    await self.resetKeepaliveFailureCount(generation: generation)
                } catch {
                    await self.handleKeepaliveFailure(error, generation: generation)
                }
            }
        }
    }

    /// Send one keepalive datagram. Returns `false` once the connection is no
    /// longer active so the loop can exit.
    private func sendKeepaliveDatagram(generation: UInt64) async throws -> Bool {
        guard isCurrentConnection(generation), status == .connected, let transport = transport else { return false }
        var packet = Data(count: 8)
        let counter = keepaliveCounter
        packet[0] = UInt8(counter & 0xff)
        packet[1] = UInt8((counter >> 8) & 0xff)
        packet[2] = UInt8((counter >> 16) & 0xff)
        packet[3] = UInt8((counter >> 24) & 0xff)
        keepaliveCounter &+= 1
        try await transport.send(packet)
        return isCurrentConnection(generation)
    }

    private func resetKeepaliveFailureCount(generation: UInt64) {
        guard isCurrentConnection(generation) else { return }
        keepaliveFailureCount = 0
    }

    private func handleKeepaliveFailure(_ error: Error, generation: UInt64) async {
        guard isCurrentConnection(generation), status == .connected else { return }
        keepaliveFailureCount += 1
        await debug("Voice UDP keepalive failed (\(keepaliveFailureCount)/2): \(error.localizedDescription)")
        guard isCurrentConnection(generation) else { return }
        if keepaliveFailureCount >= 2 {
            await failIfCurrent("voice UDP keepalive failed repeatedly: \(error.localizedDescription)", generation: generation)
        }
    }

    /// A route change can leave a UDP socket pinned to an obsolete interface,
    /// even when no announcement is currently speaking. Rebuild once when a
    /// materially different usable route appears so the next read does not
    /// become a silent first probe. Cosmetic Network.framework changes (for
    /// example constrained/expensive flags alone) deliberately do not churn
    /// the voice session.
    private func handleVoiceNetworkPathChange(
        previous: VoiceNetworkPathSnapshot,
        current: VoiceNetworkPathSnapshot,
        generation: UInt64
    ) async {
        guard isCurrentConnection(generation), status == .connected else { return }
        guard current.status == .satisfied else {
            await debug("Voice network path became unavailable; waiting for a usable route before considering voice recovery.", generation: generation)
            return
        }
        let changedInterfaces = previous.activeInterfaceTypes != current.activeInterfaceTypes
        let recoveredUsableRoute = previous.status != .satisfied
        guard changedInterfaces || recoveredUsableRoute else {
            await debug("Voice network path detail changed without a route handoff; keeping the existing voice session.", generation: generation)
            return
        }
        guard !pathRecoveryRequested else { return }
        pathRecoveryRequested = true
        let previousInterfaces = previous.activeInterfaceTypes.map(\.rawValue).joined(separator: ",")
        let currentInterfaces = current.activeInterfaceTypes.map(\.rawValue).joined(separator: ",")
        await debug(
            "Voice network path changed (\(previousInterfaces.isEmpty ? "unknown" : previousInterfaces) → \(currentInterfaces.isEmpty ? "unknown" : currentInterfaces)); rebuilding the voice session before further audio.",
            generation: generation
        )
        await failIfCurrent("voice network path changed", generation: generation)
    }

    // MARK: - Connection lifetime

    /// Start a new ownership epoch. All prior workers are cancelled before any
    /// new gateway callbacks are installed, so old socket completions can only
    /// observe a stale generation.
    private func beginConnection() -> UInt64 {
        connectionGeneration &+= 1
        cancelConnectionWorkers()
        return connectionGeneration
    }

    /// Make every outstanding callback and worker stale before tearing down its
    /// resources. Cancellation is best-effort for URLSession/UDP work; the
    /// generation check is the hard guarantee.
    private func invalidateConnection() {
        connectionGeneration &+= 1
        cancelConnectionWorkers()
        isSpeaking = false
        speakingGeneration = nil
        speakingStartedAt = nil
        didSendFirstAudioFrameForSpeech = false
        awaitingVoiceResume = false
        keepaliveFailureCount = 0
        pathRecoveryRequested = false
    }

    private func cancelConnectionWorkers() {
        gatewayConnectTask?.cancel()
        gatewayConnectTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        voiceResumeConfirmationTask?.cancel()
        voiceResumeConfirmationTask = nil
        daveEventTail?.cancel()
        daveEventTail = nil
        daveOutboxRetryTask?.cancel()
        daveOutboxRetryTask = nil
        daveOutboxRetryAttempts = 0
        daveReadinessObservationTask?.cancel()
        daveReadinessObservationTask = nil
        daveDowngradeTransitionDeadlineTask?.cancel()
        daveDowngradeTransitionDeadlineTask = nil
    }

    /// Queue one DAVE/MLS callback behind earlier callbacks from this voice
    /// connection. The task chain is reset on every generation change, while
    /// each operation still checks the generation before it touches state.
    private func enqueueDaveGatewayEvent(
        generation: UInt64,
        _ operation: @escaping @Sendable (VoicePlaybackService) async -> Void
    ) {
        guard isCurrentConnection(generation) else { return }
        let previous = daveEventTail
        let task = Task { [weak self] in
            _ = await previous?.result
            guard !Task.isCancelled, let self else { return }
            await operation(self)
        }
        daveEventTail = task
    }

    private func isCurrentConnection(_ generation: UInt64) -> Bool {
        guard connectionGeneration == generation else { return false }
        switch status {
        case .connecting, .connected:
            return true
        case .idle, .disconnecting, .failed:
            return false
        }
    }

    private func startGatewayConnection(_ gateway: any VoicePlaybackGateway, generation: UInt64) {
        guard isCurrentConnection(generation) else { return }
        gatewayConnectTask?.cancel()
        gatewayConnectTask = Task { [weak self] in
            do {
                try await gateway.connect()
                await self?.gatewayConnectDidFinish(generation: generation)
            } catch {
                await self?.gatewayConnectDidFail(error, generation: generation)
            }
        }
    }

    private func gatewayConnectDidFinish(generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        gatewayConnectTask = nil
    }

    private func gatewayConnectDidFail(_ error: Error, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        await failIfCurrent("gateway connect failed: \(error.localizedDescription)", generation: generation)
    }

    /// The gateway can deliver READY and SESSION_DESCRIPTION before its
    /// `connect()` implementation returns. Check the state synchronously while
    /// installing the continuation so that early success/failure cannot strand
    /// the public caller waiting forever.
    private func waitForConnectionReadiness(_ generation: UInt64) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard connectionGeneration == generation else {
                if lastFailureGeneration == generation, let lastFailureReason {
                    continuation.resume(throwing: VoicePipelineError.unexpectedPayload(lastFailureReason))
                    return
                }
                continuation.resume(throwing: VoicePipelineError.notConnected)
                return
            }
            switch status {
            case .connected:
                continuation.resume()
            case .failed(let reason):
                continuation.resume(throwing: VoicePipelineError.unexpectedPayload(reason))
            case .connecting:
                readyContinuation = continuation
                readyContinuationGeneration = generation
            case .idle, .disconnecting:
                continuation.resume(throwing: VoicePipelineError.notConnected)
            }
        }
    }

    private func cancelConnectionIfCurrent(_ generation: UInt64) async {
        guard connectionGeneration == generation, status == .connecting else { return }
        await failIfCurrent("voice connection was cancelled", generation: generation)
    }

    private func startConnectionTimeout(for generation: UInt64) {
        guard isCurrentConnection(generation) else { return }
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self, connectionReadinessTimeout] in
            try? await Task.sleep(for: connectionReadinessTimeout)
            guard !Task.isCancelled else { return }
            await self?.failIfCurrent("timed out waiting for voice media readiness", generation: generation)
        }
    }

    private func setStatus(_ new: Status) async {
        status = new
        await onStatusChange?(new)
    }

    private func debug(_ message: String) async {
        await onDebug?(message)
    }

    private func debug(_ message: String, generation: UInt64) async {
        guard isCurrentConnection(generation) else { return }
        await debug(message)
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        return String(format: "%.1fs", seconds)
    }

    /// Time since the current connect attempt began, e.g. "2.1s", for timing the
    /// handshake phases in the diagnostics log. "?" before a connect starts.
    private func elapsedSinceConnect() -> String {
        guard let start = connectStartedAt else { return "?" }
        return Self.format(ContinuousClock().now - start)
    }

    /// `[+total Δsince-last-step]` prefix for DAVE lines, and advances the
    /// step clock. The large Δ on a line is the gap we spent waiting before it.
    private func daveTimingPrefix() -> String {
        let now = ContinuousClock().now
        let total = connectStartedAt.map { Self.format(now - $0) } ?? "?"
        let delta = lastDaveStepAt.map { Self.format(now - $0) } ?? total
        lastDaveStepAt = now
        return "[+\(total) Δ\(delta)]"
    }

    /// Mirror a DAVE protocol/handshake event to both the OS log (Console) and
    /// the in-app voice diagnostics log. Each line is stamped with the time since
    /// connect started and the gap since the previous step, so a slow handshake
    /// phase is obvious. Tracks key-exchange/transition state only — never
    /// spoken/decrypted content.
    private func daveLog(_ message: String) async {
        let stamped = "\(daveTimingPrefix()) \(message)"
        Self.logger.info("\(stamped, privacy: .public)")
        await debug(stamped)
    }

    /// Like `daveLog`, for failure paths (logged at error level).
    private func daveLogError(_ message: String) async {
        let stamped = "\(daveTimingPrefix()) \(message)"
        Self.logger.error("\(stamped, privacy: .public)")
        await debug(stamped)
    }

    /// Extra-detailed diagnostics that only surface in DEBUG builds (Dev), so
    /// release logs stay clean. Used for blow-by-blow voice/DAVE tracing.
    private func verbose(_ message: String) async {
        #if DEBUG
        await debug("🔍 [+\(elapsedSinceConnect())] \(message)")
        #endif
    }

    /// Snapshot the live MLS epoch + handshake state for the diagnostics log.
    private func logDaveState(_ context: String) async {
        guard let coordinator = daveCoordinator else { return }
        let d = await coordinator.getDiagnostics()
        await daveLog("DAVE \(context): \(d.appliedTransitionCount) transitions applied, handshake \(d.handshakeState.rawValue).")
    }

    private func label(for status: Status) -> String {
        switch status {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        case .failed: return "failed"
        }
    }
}
