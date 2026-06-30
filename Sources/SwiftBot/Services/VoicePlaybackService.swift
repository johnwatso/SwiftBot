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

    private let session: URLSession
    private var status: Status = .idle
    private var gateway: VoiceGatewayConnection?
    private var transport: VoiceUDPTransport?
    private var encryption: VoiceEncryption?
    private var rtp: RTPPacketBuilder?
    private var opus: OpusFrameEncoder?
    private var ssrc: UInt32?
    private var negotiatedMode: VoiceEncryptionMode?
    private var daveCoordinator: DaveSessionCoordinator?
    private var daveMediaRequired: Bool = false
    private var daveMediaReady: Bool = false
    private var daveExternalSender: Data?
    private var recognizedUserIds: Set<String> = []
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var connectionTimeoutTask: Task<Void, Never>?
    /// True only while a `speak(...)` call is actively transmitting audio frames.
    private var isSpeaking: Bool = false
    /// Periodic Discord UDP keepalive. Keeps the NAT/UDP mapping alive between
    /// utterances so playback doesn't go stale — without sending RTP audio, so
    /// the speaking ring stays off while idle.
    private var keepaliveTask: Task<Void, Never>?
    private var keepaliveCounter: UInt32 = 0
    private var keepaliveFailureCount: Int = 0
    /// When the current connect attempt began, used to time each handshake phase
    /// in the diagnostics log (so a slow connect can be pinpointed).
    private var connectStartedAt: ContinuousClock.Instant?
    /// When the previous DAVE log line was emitted, so each line can show the gap
    /// since the last step (Δ) — the big Δ is where the handshake stalls.
    private var lastDaveStepAt: ContinuousClock.Instant?
    /// Whether we've published our MLS key package for the current handshake.
    /// The key package must be sent only AFTER the server's external sender
    /// arrives; sending it earlier (or twice) makes Discord build its Welcome for
    /// a stale key package and forces a slow MLS reset/recovery.
    private var daveInitialKeyPackageSent = false
    /// Fallback that publishes the key package if the external sender is slow to
    /// arrive, so a missing external sender can't stall the handshake.
    private var daveKeyPackageFallbackTask: Task<Void, Never>?
    /// Watchdog used only after an established voice session receives a DAVE
    /// re-key. Initial connection has its own media-readiness timeout.
    private var daveMediaReadinessWatchdogTask: Task<Void, Never>?

    private var onStatusChange: (@Sendable (Status) async -> Void)?
    private var onDebug: (@Sendable (String) async -> Void)?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func setOnStatusChange(_ handler: @escaping @Sendable (Status) async -> Void) {
        onStatusChange = handler
    }

    func setOnDebug(_ handler: @escaping @Sendable (String) async -> Void) {
        onDebug = handler
    }

    var currentStatus: Status { status }

    /// Run the full voice handshake: WS connect → READY → IP discovery →
    /// SELECT_PROTOCOL → SESSION_DESCRIPTION. Returns once the encrypted
    /// audio pipeline is ready to accept frames.
    func connect(server: VoiceServerInfo) async throws {
        guard status == .idle || status == .failed("") || isFailed(status) else {
            return
        }
        await setStatus(.connecting)
        connectStartedAt = ContinuousClock().now
        lastDaveStepAt = nil
        daveInitialKeyPackageSent = false
        daveKeyPackageFallbackTask?.cancel()
        daveKeyPackageFallbackTask = nil
        daveMediaReadinessWatchdogTask?.cancel()
        daveMediaReadinessWatchdogTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.fail("timed out waiting for voice media readiness")
        }

        let opus = try OpusFrameEncoder()
        self.opus = opus

        let gateway = VoiceGatewayConnection(session: session, server: server)
        self.gateway = gateway

        await gateway.setOnReady { [weak self] info in
            await self?.handleReady(info)
        }
        await gateway.setOnSessionDescription { [weak self] key in
            await self?.handleSessionDescription(key)
        }
        await gateway.setOnClose { [weak self] code in
            await self?.handleGatewayClose(code)
        }
        await gateway.setOnDebug { [weak self] message in
            await self?.debug(message)
        }
        await gateway.setOnClientsConnect { [weak self] userIds in
            await self?.handleClientsConnect(userIds)
        }
        await gateway.setOnClientDisconnect { [weak self] userId in
            await self?.handleClientDisconnect(userId)
        }
        await gateway.setOnDavePrepareEpoch { [weak self] protocolVersion, epoch in
            await self?.handleDavePrepareEpoch(protocolVersion: protocolVersion, epoch: epoch)
        }
        await gateway.setOnDaveExecuteTransition { [weak self] transitionId in
            await self?.handleDaveExecuteTransition(transitionId)
        }
        await gateway.setOnDaveMlsExternalSender { [weak self] data in
            await self?.handleDaveExternalSender(data)
        }
        await gateway.setOnDaveMlsProposals { [weak self] data in
            await self?.handleDaveProposals(data)
        }
        await gateway.setOnDaveMlsAnnounceCommit { [weak self] data, transitionId in
            await self?.handleDaveAnnounceCommit(data, transitionId: transitionId)
        }
        await gateway.setOnDaveMlsWelcome { [weak self] data, transitionId in
            await self?.handleDaveWelcome(data, transitionId: transitionId)
        }

        do {
            try await gateway.connect()
        } catch {
            await setStatus(.failed("gateway connect failed: \(error.localizedDescription)"))
            throw error
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyContinuation = continuation
        }
    }

    func disconnect() async {
        await setStatus(.disconnecting)
        keepaliveTask?.cancel()
        keepaliveTask = nil
        keepaliveFailureCount = 0
        daveKeyPackageFallbackTask?.cancel()
        daveKeyPackageFallbackTask = nil
        daveMediaReadinessWatchdogTask?.cancel()
        daveMediaReadinessWatchdogTask = nil
        isSpeaking = false
        await gateway?.disconnect()
        await transport?.stop()
        gateway = nil
        transport = nil
        encryption = nil
        rtp = nil
        opus = nil
        ssrc = nil
        negotiatedMode = nil
        recognizedUserIds.removeAll()
        if daveCoordinator != nil {
            await daveLog("DAVE session torn down; MLS coordinator reset.")
        }
        await daveCoordinator?.reset()
        daveCoordinator = nil
        daveMediaRequired = false
        daveMediaReady = false
        daveExternalSender = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        await setStatus(.idle)
    }

    func getDaveDiagnostics() async -> DaveDiagnostics? {
        if let coordinator = daveCoordinator {
            return await coordinator.getDiagnostics()
        }
        return nil
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
        guard status == .connected,
              let gateway = gateway,
              let transport = transport,
              let opus = opus,
              let ssrc = ssrc else {
            throw VoicePipelineError.notConnected
        }
        guard !daveMediaRequired || daveMediaReady else {
            throw VoicePipelineError.daveNotReady
        }
        do {
            try await gateway.sendSpeaking(true, ssrc: ssrc)
        } catch {
            await fail("voice speaking update failed: \(error.localizedDescription)")
            throw VoicePipelineError.socketClosed
        }
        isSpeaking = true
        defer {
            isSpeaking = false
            Task { try? await gateway.sendSpeaking(false, ssrc: ssrc) }
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
                try await sendFrame(chunkBuffer, transport: transport)
            } catch VoicePipelineError.daveNotReady {
                throw VoicePipelineError.daveNotReady
            } catch {
                await fail("voice audio send failed: \(error.localizedDescription)")
                throw VoicePipelineError.socketClosed
            }
            processed += chunkFrames

            nextDeadline = nextDeadline.advanced(by: .milliseconds(Int(frameDuration * 1000)))
            try? await clock.sleep(until: nextDeadline)
        }

        // Standard Discord end-of-speech marker: a short burst of Opus silence
        // flushes the receiving decoder so the next utterance isn't clipped.
        await sendTrailingSilence(5, transport: transport)
    }

    /// Send `count` Opus silence frames at the end of an utterance. This is the
    /// standard Discord voice "end of speech" signal: it flushes the receiving
    /// client's Opus decoder so the next utterance starts cleanly. We do NOT
    /// send silence while idle — that would keep packets flowing on our SSRC and
    /// light the "speaking" ring continuously (Discord can't see the encrypted
    /// payload is silence, so any packet counts as activity).
    private func sendTrailingSilence(_ count: Int, transport: VoiceUDPTransport) async {
        guard var rtp = self.rtp, var encryption = self.encryption, let ssrc = ssrc else { return }
        for _ in 0..<count {
            let header = rtp.nextHeader(samplesPerChannel: UInt32(OpusFrameEncoder.samplesPerFrame))
            let plainPayload = RTPPacketBuilder.opusSilenceFrame
            let encryptedPayload: Data
            if let coordinator = daveCoordinator {
                guard let encrypted = try? await coordinator.encryptDiscordAudioFrame(plainPayload, ssrc: ssrc) else { return }
                encryptedPayload = encrypted
            } else {
                encryptedPayload = plainPayload
            }
            guard let packet = try? encryption.seal(rtpHeader: header, payload: encryptedPayload) else { return }
            try? await transport.send(packet)
        }
        self.rtp = rtp
        self.encryption = encryption
    }

    // MARK: - Private

    private func sendFrame(_ buffer: AVAudioPCMBuffer, transport: VoiceUDPTransport) async throws {
        guard let opus = opus,
              var rtp = self.rtp,
              var encryption = self.encryption,
              let ssrc = ssrc else {
            return
        }
        guard !daveMediaRequired || daveMediaReady else {
            throw VoicePipelineError.daveNotReady
        }
        let plainPayload = try opus.encode(buffer)
        let encryptedPayload: Data
        if let coordinator = daveCoordinator {
            encryptedPayload = try await coordinator.encryptDiscordAudioFrame(plainPayload, ssrc: ssrc)
        } else {
            encryptedPayload = plainPayload
        }
        let header = rtp.nextHeader(samplesPerChannel: UInt32(OpusFrameEncoder.samplesPerFrame))
        let packet = try encryption.seal(rtpHeader: header, payload: encryptedPayload)
        try await transport.send(packet)
        self.rtp = rtp
        self.encryption = encryption
    }

    private func handleReady(_ info: VoiceReadyInfo) async {
        ssrc = info.ssrc
        rtp = RTPPacketBuilder(ssrc: info.ssrc)

        guard let mode = info.modes.first(where: { mode in
            VoiceEncryptionMode.preferred.contains(where: { $0.rawValue == mode })
        }).flatMap(VoiceEncryptionMode.init(rawValue:)) else {
            await fail("no supported encryption mode in \(info.modes)")
            return
        }
        negotiatedMode = mode
        await debug("[+\(elapsedSinceConnect())] Voice gateway ready; selected transport encryption: \(mode.rawValue).")

        if let existing = transport {
            await existing.stop()
        }
        let udp = VoiceUDPTransport(host: info.ip, port: info.port)
        transport = udp
        do {
            try await udp.start()
            let address = try await udp.discoverAddress(ssrc: info.ssrc)
            await debug("[+\(elapsedSinceConnect())] Voice UDP discovery returned \(address.ip):\(address.port); selecting protocol.")
            try await gateway?.sendSelectProtocol(address: address, mode: mode)
        } catch {
            await fail("ip discovery failed: \(error.localizedDescription)")
        }
    }

    private func handleSessionDescription(_ key: VoiceSessionKey) async {
        encryption = VoiceEncryption(secretKey: key.secretKey)

        if let daveVersion = key.daveProtocolVersion, daveVersion > 0, ssrc != nil, let gateway = gateway {
            daveMediaRequired = true
            daveMediaReady = false
            await daveLog("DAVE negotiated version \(daveVersion); preparing MLS session for guild \(gateway.server.guildID).")
            let coordinator = DaveSessionCoordinator(authSessionId: nil)
            do {
                recognizedUserIds.insert(gateway.server.userID)
                let result = try await coordinator.configureDiscordVoiceSession(
                    groupId: UInt64(gateway.server.guildID) ?? 0,
                    selfUserId: gateway.server.userID,
                    protocolVersion: daveVersion
                )
                self.daveCoordinator = coordinator
                await daveLog("DAVE MLS coordinator configured (self user \(gateway.server.userID)).")
                try await sendDaveOutboundActions(result.outboundActions, reason: "session description")

                // Publish the key package only AFTER the external sender arrives
                // (the MLS-correct order). If the external sender was already
                // cached (reconnect), send now; otherwise wait for it, with a
                // fallback so a missing external sender can't stall us.
                if let externalSender = daveExternalSender {
                    let registration = try await coordinator.registerDiscordExternalSender(
                        externalSender,
                        publishInitialKeyPackage: true
                    )
                    await daveLog("DAVE external sender reapplied after session description.")
                    try await sendDaveOutboundActions(
                        registration.outboundActions,
                        reason: "session description (external sender cached)"
                    )
                } else {
                    await daveLog("Waiting for DAVE external sender before publishing key package.")
                    await verbose("awaiting Discord → MLS external-sender package (a large next Δ means Discord is the slow side here)")
                    startDaveKeyPackageFallback()
                }
            } catch {
                await daveLogError("DAVE coordinator initialization failed: \(error.localizedDescription)")
                await fail("DAVE coordinator initialization failed: \(error.localizedDescription)")
            }
        } else {
            daveMediaRequired = false
            daveMediaReady = true
            await daveLog("DAVE not negotiated for this voice session; media is transport-encrypted only.")
            await completeConnection(reason: "transport encryption ready")
        }
    }

    private func handleClientsConnect(_ userIds: [String]) async {
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

    private func handleClientDisconnect(_ userId: String) async {
        let removed = recognizedUserIds.remove(userId) != nil
        if daveMediaRequired, removed {
            await daveLog("DAVE roster: a client left the encrypted session (now \(recognizedUserIds.count)).")
        }
    }

    private func handleDavePrepareEpoch(protocolVersion: UInt16, epoch: UInt64) async {
        guard protocolVersion > 0 else { return }
        await daveLog("DAVE prepare epoch received (version \(protocolVersion), epoch \(epoch)).")
        do {
            if let coordinator = daveCoordinator {
                if epoch == 1 {
                    await pauseDaveMediaForRefresh(reason: "prepare epoch \(epoch)")
                    daveInitialKeyPackageSent = false
                    let result = try await coordinator.prepareDiscordEpoch(
                        protocolVersion: protocolVersion,
                        epoch: epoch
                    )
                    try await sendDaveOutboundActions(result.outboundActions, reason: "prepare epoch")
                    if result.recoveryHint == .waitForExternalSender {
                        await daveLog("DAVE prepare epoch is waiting for external sender before a fresh key package.")
                        startDaveKeyPackageFallback()
                    }
                    await daveLog("DAVE MLS session re-initialised for epoch \(epoch).")
                }
            } else {
                await daveLog("DAVE prepare epoch ignored; no active MLS session.")
            }
        } catch {
            await daveLogError("DAVE prepare epoch failed: \(error.localizedDescription)")
        }
    }

    private func handleDaveExecuteTransition(_ transitionId: UInt64) async {
        await daveLog("DAVE execute transition received (id \(transitionId)).")
        guard let coordinator = daveCoordinator else {
            await daveLog("DAVE execute transition ignored; no active MLS session.")
            return
        }
        let result = await coordinator.executeDiscordTransition(transitionId)
        guard result.recoveryHint != .retryLater else {
            await daveLog("DAVE execute transition deferred; MLS handshake is \(result.diagnostics.handshakeState.rawValue) (epoch \(result.diagnostics.currentEpoch)).")
            return
        }
        if status == .connected {
            await resumeDaveMedia(reason: "transition \(transitionId) ready; media resumed")
            return
        }
        await completeConnection(reason: "DAVE transition \(transitionId) ready")
    }

    private func handleDaveExternalSender(_ data: Data) async {
        await daveLog("DAVE external sender package received (\(data.count) bytes).")
        do {
            daveExternalSender = data
            if let coordinator = daveCoordinator {
                let result = try await coordinator.registerDiscordExternalSender(
                    data,
                    publishInitialKeyPackage: !daveInitialKeyPackageSent
                )
                try await sendDaveOutboundActions(result.outboundActions, reason: "external sender")
            }
            await daveLog("DAVE external sender registered.")
            await verbose("awaiting Discord → MLS proposals")
        } catch {
            await daveLogError("DAVE external sender registration failed: \(error.localizedDescription)")
        }
    }

    private func handleDaveProposals(_ data: Data) async {
        await daveLog("DAVE MLS proposals received (\(data.count) bytes).")
        do {
            guard let coordinator = daveCoordinator else {
                await daveLog("DAVE MLS proposals ignored; no active MLS session.")
                return
            }
            let result = try await coordinator.processDiscordProposalsForOutbound(
                data,
                recognizedUserIds: Array(recognizedUserIds)
            )
            try await sendDaveOutboundActions(result.outboundActions, reason: "proposals")
            await daveLog("DAVE MLS proposals processed; commit/welcome sent.")
            await verbose("awaiting Discord → announce-commit / welcome + execute-transition")
        } catch {
            // Before we've joined the group (no welcome processed yet), Discord
            // may send proposals we can't act on — "not for this group" — which is
            // expected: the upcoming welcome makes us a member. Only treat it as a
            // real error once we're an established member.
            let joined = (await daveCoordinator?.getDiagnostics().handshakeState) == .ready
            if joined {
                await daveLogError("DAVE proposal handling failed: \(error.localizedDescription)")
            } else {
                await daveLog("DAVE proposals not actionable yet (awaiting welcome to join group): \(error.localizedDescription)")
            }
        }
    }

    private func handleDaveAnnounceCommit(_ data: Data, transitionId: UInt64) async {
        await daveLog("DAVE announce commit received (id \(transitionId), \(data.count) bytes).")
        do {
            guard let coordinator = daveCoordinator else {
                await daveLog("DAVE commit ignored; no active MLS session.")
                return
            }
            let result = try await coordinator.processDiscordCommitForOutbound(
                data,
                transitionId: transitionId
            )
            if result.needsRecovery {
                daveInitialKeyPackageSent = false
                await pauseDaveMediaForRefresh(reason: "invalid transition \(transitionId) recovery")
            }
            try await sendDaveOutboundActions(result.outboundActions, reason: "commit \(transitionId)")
            if result.needsRecovery {
                await daveLog("DAVE commit rejected; recovery actions sent (id \(transitionId)).")
                if result.recoveryHint == .waitForExternalSender {
                    startDaveKeyPackageFallback()
                }
                return
            }
            await daveLog("DAVE commit processed; transition-ready sent (id \(transitionId)).")
            await completeConnectionIfHandshakeReady(reason: "DAVE commit \(transitionId) ready")
        } catch {
            await daveLogError("DAVE commit processing failed (id \(transitionId)): \(error.localizedDescription)")
            await recoverFromInvalidDaveTransition(transitionId: transitionId)
        }
    }

    private func handleDaveWelcome(_ data: Data, transitionId: UInt64) async {
        await daveLog("DAVE welcome received (id \(transitionId), \(data.count) bytes).")
        guard let gateway = gateway else { return }
        do {
            guard let coordinator = daveCoordinator else {
                await daveLog("DAVE welcome ignored; no active MLS session.")
                return
            }
            recognizedUserIds.insert(gateway.server.userID)
            let result = try await coordinator.processDiscordWelcomeForOutbound(
                data,
                transitionId: transitionId,
                recognizedUserIds: Array(recognizedUserIds)
            )
            if result.needsRecovery {
                daveInitialKeyPackageSent = false
                await pauseDaveMediaForRefresh(reason: "invalid transition \(transitionId) recovery")
            }
            try await sendDaveOutboundActions(result.outboundActions, reason: "welcome \(transitionId)")
            if result.needsRecovery {
                await daveLog("DAVE welcome rejected; recovery actions sent (id \(transitionId)).")
                if result.recoveryHint == .waitForExternalSender {
                    startDaveKeyPackageFallback()
                }
                return
            }
            await daveLog("DAVE welcome processed; transition-ready sent (id \(transitionId)).")
            await completeConnectionIfHandshakeReady(reason: "DAVE welcome \(transitionId) ready")
        } catch {
            await daveLogError("DAVE welcome processing failed (id \(transitionId)): \(error.localizedDescription)")
            await recoverFromInvalidDaveTransition(transitionId: transitionId)
        }
    }

    /// A successful welcome/commit already advances us to the new epoch with the
    /// key ratchet installed (see DaveSessionCoordinator.processDiscordTransition),
    /// so we're ready to send audio immediately. Some servers — notably the
    /// initial epoch (transition id 0) — never send a separate execute-transition,
    /// so complete the connection here once the handshake is ready rather than
    /// waiting for one (which previously caused a 15s media-readiness timeout).
    /// `completeConnection` self-guards against double-completion.
    private func completeConnectionIfHandshakeReady(reason: String) async {
        guard let coordinator = daveCoordinator else { return }
        let diagnostics = await coordinator.getDiagnostics()
        guard diagnostics.handshakeState == .ready else {
            await verbose("handshake not ready after transition (\(diagnostics.handshakeState.rawValue)); awaiting Discord → execute-transition")
            return
        }
        if status == .connected {
            await resumeDaveMedia(reason: "\(reason); media resumed")
            return
        }
        await completeConnection(reason: reason)
    }

    private func sendDaveKeyPackage(reason: String) async throws {
        guard let coordinator = daveCoordinator else { return }
        let result = try await coordinator.publishDiscordInitialKeyPackage()
        try await sendDaveOutboundActions(result.outboundActions, reason: reason)
    }

    /// Publish the initial key package exactly once per handshake (guarded so the
    /// external-sender path and the fallback timer can't double-send, which is
    /// what caused the "Welcome not intended for key package" failure).
    private func sendInitialDaveKeyPackage(reason: String) async {
        guard !daveInitialKeyPackageSent, daveCoordinator != nil else { return }
        daveInitialKeyPackageSent = true
        daveKeyPackageFallbackTask?.cancel()
        daveKeyPackageFallbackTask = nil
        do {
            try await sendDaveKeyPackage(reason: reason)
        } catch {
            await daveLogError("DAVE key package send failed (\(reason)): \(error.localizedDescription)")
        }
    }

    /// If the server's external sender doesn't arrive shortly after the session
    /// description, publish the key package anyway so the handshake can't stall.
    private func startDaveKeyPackageFallback() {
        daveKeyPackageFallbackTask?.cancel()
        daveKeyPackageFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.fireDaveKeyPackageFallback()
        }
    }

    private func fireDaveKeyPackageFallback() async {
        guard !daveInitialKeyPackageSent else { return }
        await daveLog("DAVE external sender not received in ~3s; publishing key package as fallback.")
        await sendInitialDaveKeyPackage(reason: "fallback (external sender delayed)")
    }

    private func recoverFromInvalidDaveTransition(transitionId: UInt64) async {
        await daveLog("DAVE recovering from invalid transition (id \(transitionId)); resetting MLS session.")
        do {
            daveInitialKeyPackageSent = false
            await pauseDaveMediaForRefresh(reason: "invalid transition \(transitionId) recovery")
            let result = try await daveCoordinator?.recoverDiscordInvalidTransition(transitionId: transitionId)
            try await sendDaveOutboundActions(result?.outboundActions ?? [], reason: "invalid commit/welcome recovery")
            if result?.recoveryHint == .waitForExternalSender {
                startDaveKeyPackageFallback()
            }
            await daveLog("DAVE session state recreated after invalid transition (id \(transitionId)).")
        } catch {
            await daveLogError("DAVE recovery failed (id \(transitionId)): \(error.localizedDescription)")
        }
    }

    private func sendDaveOutboundActions(_ actions: [DiscordDaveOutboundAction], reason: String) async throws {
        guard let gateway = gateway else { return }
        for action in actions {
            switch action {
            case .mlsKeyPackage(let data):
                try await gateway.sendMlsKeyPackage(data)
                daveInitialKeyPackageSent = true
                daveKeyPackageFallbackTask?.cancel()
                daveKeyPackageFallbackTask = nil
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
    }

    private func handleGatewayClose(_ code: Int) async {
        if status == .connecting || status == .connected {
            await fail("gateway closed (\(code))")
        }
    }

    private func fail(_ reason: String) async {
        Self.logger.error("voice pipeline failed: \(reason)")
        keepaliveTask?.cancel()
        keepaliveTask = nil
        daveKeyPackageFallbackTask?.cancel()
        daveKeyPackageFallbackTask = nil
        daveMediaReadinessWatchdogTask?.cancel()
        daveMediaReadinessWatchdogTask = nil
        isSpeaking = false
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        await setStatus(.failed(reason))
        let continuation = readyContinuation
        readyContinuation = nil
        continuation?.resume(throwing: VoicePipelineError.unexpectedPayload(reason))
    }

    private func completeConnection(reason: String) async {
        guard status != .connected else { return }
        daveMediaReady = true
        daveMediaReadinessWatchdogTask?.cancel()
        daveMediaReadinessWatchdogTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        await debug("Voice media ready in \(elapsedSinceConnect()): \(reason).")
        if daveMediaRequired {
            await logDaveState("secure session active")
        }
        await setStatus(.connected)
        startKeepalive()
        let continuation = readyContinuation
        readyContinuation = nil
        continuation?.resume()
    }

    /// Discord UDP keepalive loop: every 5 s send an 8-byte datagram (a
    /// little-endian counter in the first 4 bytes) to keep the NAT/UDP mapping
    /// warm so the next utterance isn't dropped as stale. This is NOT an RTP
    /// audio packet, so Discord doesn't light the speaking ring for it.
    private func startKeepalive() {
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
                    guard try await self.sendKeepaliveDatagram() else { return }
                    await self.resetKeepaliveFailureCount()
                } catch {
                    await self.handleKeepaliveFailure(error)
                }
            }
        }
    }

    private func pauseDaveMediaForRefresh(reason: String) async {
        guard daveMediaRequired else { return }
        daveMediaReady = false
        _ = await daveCoordinator?.markDiscordMediaNotReady(reason: reason)
        guard status == .connected else { return }
        await daveLog("DAVE media paused for \(reason); awaiting refreshed MLS transition.")
        startDaveMediaReadinessWatchdog(reason: reason)
    }

    private func resumeDaveMedia(reason: String) async {
        let wasPaused = daveMediaRequired && !daveMediaReady
        daveMediaReady = true
        _ = await daveCoordinator?.markDiscordMediaReady(reason: reason)
        daveMediaReadinessWatchdogTask?.cancel()
        daveMediaReadinessWatchdogTask = nil
        if wasPaused {
            await logDaveState(reason)
        }
    }

    private func startDaveMediaReadinessWatchdog(reason: String) {
        daveMediaReadinessWatchdogTask?.cancel()
        daveMediaReadinessWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.failIfDaveMediaStillNotReady(reason: reason)
        }
    }

    private func failIfDaveMediaStillNotReady(reason: String) async {
        guard status == .connected, daveMediaRequired, !daveMediaReady else { return }
        await fail("DAVE media encryption did not recover after \(reason)")
    }

    /// Send one keepalive datagram. Returns `false` once the connection is no
    /// longer active so the loop can exit.
    private func sendKeepaliveDatagram() async throws -> Bool {
        guard status == .connected, let transport = transport else { return false }
        var packet = Data(count: 8)
        let counter = keepaliveCounter
        packet[0] = UInt8(counter & 0xff)
        packet[1] = UInt8((counter >> 8) & 0xff)
        packet[2] = UInt8((counter >> 16) & 0xff)
        packet[3] = UInt8((counter >> 24) & 0xff)
        keepaliveCounter &+= 1
        try await transport.send(packet)
        return true
    }

    private func resetKeepaliveFailureCount() {
        keepaliveFailureCount = 0
    }

    private func handleKeepaliveFailure(_ error: Error) async {
        guard status == .connected else { return }
        keepaliveFailureCount += 1
        await debug("Voice UDP keepalive failed (\(keepaliveFailureCount)/2): \(error.localizedDescription)")
        if keepaliveFailureCount >= 2 {
            await fail("voice UDP keepalive failed repeatedly: \(error.localizedDescription)")
        }
    }

    private func setStatus(_ new: Status) async {
        status = new
        await onStatusChange?(new)
    }

    private func debug(_ message: String) async {
        await onDebug?(message)
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
        await daveLog("DAVE \(context): epoch \(d.currentEpoch), handshake \(d.handshakeState.rawValue).")
    }

    private func isFailed(_ status: Status) -> Bool {
        if case .failed = status { return true }
        return false
    }
}
