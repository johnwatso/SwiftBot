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

    /// Stream 48 kHz stereo Float32 PCM to the encoder as it is produced, so
    /// playback starts before the whole utterance is rendered. Chunks are sliced
    /// into 20 ms frames (960 samples per channel) and paced out at 20 ms
    /// intervals; `onProgress` fires after each transmitted frame so a caller can
    /// run an inactivity watchdog over playback.
    func speak(
        stream: AsyncThrowingStream<SendableAudioBuffer, Error>,
        onProgress: @Sendable () -> Void = {}
    ) async throws {
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
        try await gateway.sendSpeaking(true, ssrc: ssrc)
        isSpeaking = true
        defer {
            isSpeaking = false
            Task { try? await gateway.sendSpeaking(false, ssrc: ssrc) }
        }

        let samplesPerFrame = Int(OpusFrameEncoder.samplesPerFrame)
        let channels = Int(OpusFrameEncoder.channelCount)
        let frameDuration = OpusFrameEncoder.frameDuration
        let floatsPerFrame = samplesPerFrame * channels

        let clock = ContinuousClock()
        var nextDeadline = clock.now

        // `head` marks the consumed prefix so draining a frame is O(1); the
        // consumed prefix is dropped before each append to keep memory bounded.
        var sampleQueue: [Float] = []
        var head = 0

        for try await wrappedBuffer in stream {
            let chunkBuffer = wrappedBuffer.buffer
            let totalFrames = Int(chunkBuffer.frameLength)
            guard totalFrames > 0, let channelData = chunkBuffer.floatChannelData else { continue }
            let interleaved = chunkBuffer.format.isInterleaved

            if head > 0 {
                sampleQueue.removeFirst(head)
                head = 0
            }

            if interleaved {
                sampleQueue.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: totalFrames * channels))
            } else {
                for i in 0..<totalFrames {
                    for c in 0..<channels {
                        sampleQueue.append(channelData[c][i])
                    }
                }
            }

            while sampleQueue.count - head >= floatsPerFrame {
                guard let frameBuffer = AVAudioPCMBuffer(pcmFormat: opus.format, frameCapacity: AVAudioFrameCount(samplesPerFrame)) else {
                    break
                }
                frameBuffer.frameLength = AVAudioFrameCount(samplesPerFrame)
                if let dest = frameBuffer.floatChannelData?[0] {
                    sampleQueue.withUnsafeBufferPointer { src in
                        dest.update(from: src.baseAddress! + head, count: floatsPerFrame)
                    }
                }
                head += floatsPerFrame

                try await sendFrame(frameBuffer, transport: transport)
                onProgress()

                nextDeadline = nextDeadline.advanced(by: .milliseconds(Int(frameDuration * 1000)))
                try? await clock.sleep(until: nextDeadline)
            }
        }

        // Flush the final partial frame, zero-padding the tail.
        let remaining = sampleQueue.count - head
        if remaining > 0,
           let frameBuffer = AVAudioPCMBuffer(pcmFormat: opus.format, frameCapacity: AVAudioFrameCount(samplesPerFrame)) {
            frameBuffer.frameLength = AVAudioFrameCount(samplesPerFrame)
            if let dest = frameBuffer.floatChannelData?[0] {
                sampleQueue.withUnsafeBufferPointer { src in
                    dest.update(from: src.baseAddress! + head, count: remaining)
                }
                for i in remaining..<floatsPerFrame { dest[i] = 0 }
            }
            try await sendFrame(frameBuffer, transport: transport)
            onProgress()

            nextDeadline = nextDeadline.advanced(by: .milliseconds(Int(frameDuration * 1000)))
            try? await clock.sleep(until: nextDeadline)
        }

        // Standard Discord end-of-speech marker so the next utterance is clean.
        await sendTrailingSilence(5, transport: transport)
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
        try await gateway.sendSpeaking(true, ssrc: ssrc)
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
            try await sendFrame(chunkBuffer, transport: transport)
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
        await debug("Voice selected transport encryption: \(mode.rawValue).")

        if let existing = transport {
            await existing.stop()
        }
        let udp = VoiceUDPTransport(host: info.ip, port: info.port)
        transport = udp
        do {
            try await udp.start()
            let address = try await udp.discoverAddress(ssrc: info.ssrc)
            await debug("Voice UDP discovery returned \(address.ip):\(address.port); selecting protocol.")
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
                try await coordinator.configureForDiscordVoice(
                    groupId: UInt64(gateway.server.guildID) ?? 0,
                    selfUserId: gateway.server.userID,
                    protocolVersion: daveVersion
                )
                self.daveCoordinator = coordinator
                await daveLog("DAVE MLS coordinator configured (self user \(gateway.server.userID)).")
                try await applyDaveExternalSenderIfAvailable(to: coordinator, reason: "session description")

                try await sendDaveKeyPackage(reason: "session description")
                await daveLog("Waiting for DAVE MLS transition before enabling Discord speech.")
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
                    try await coordinator.configureForDiscordVoice(
                        groupId: UInt64(gateway?.server.guildID ?? "") ?? 0,
                        selfUserId: gateway?.server.userID ?? "",
                        protocolVersion: protocolVersion
                    )
                    try await applyDaveExternalSenderIfAvailable(to: coordinator, reason: "prepare epoch")
                    try await sendDaveKeyPackage(reason: "prepare epoch")
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
        let diagnostics = await coordinator.getDiagnostics()
        guard diagnostics.handshakeState == .ready else {
            await daveLog("DAVE execute transition deferred; MLS handshake is \(diagnostics.handshakeState.rawValue) (epoch \(diagnostics.currentEpoch)).")
            return
        }
        await completeConnection(reason: "DAVE transition \(transitionId) ready")
    }

    private func handleDaveExternalSender(_ data: Data) async {
        await daveLog("DAVE external sender package received (\(data.count) bytes).")
        do {
            daveExternalSender = data
            if let coordinator = daveCoordinator {
                try await coordinator.setExternalSender(data)
            }
            await daveLog("DAVE external sender registered.")
            try await sendDaveKeyPackage(reason: "external sender")
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
            let commitWelcome = try await coordinator.processProposals(
                data,
                recognizedUserIds: Array(recognizedUserIds)
            )
            try await gateway?.sendMlsCommitWelcome(commitWelcome)
            await daveLog("DAVE MLS proposals processed; commit/welcome sent.")
        } catch {
            await daveLogError("DAVE proposal handling failed: \(error.localizedDescription)")
        }
    }

    private func handleDaveAnnounceCommit(_ data: Data, transitionId: UInt64) async {
        await daveLog("DAVE announce commit received (id \(transitionId), \(data.count) bytes).")
        do {
            try await daveCoordinator?.processDiscordTransition(.commit(data))
            await daveLog("DAVE commit processed; transition-ready sent (id \(transitionId)).")
            try await gateway?.sendTransitionReady(transitionId: transitionId)
        } catch {
            await daveLogError("DAVE commit processing failed (id \(transitionId)): \(error.localizedDescription)")
            await recoverFromInvalidDaveTransition(transitionId: transitionId)
        }
    }

    private func handleDaveWelcome(_ data: Data, transitionId: UInt64) async {
        await daveLog("DAVE welcome received (id \(transitionId), \(data.count) bytes).")
        guard let gateway = gateway else { return }
        do {
            recognizedUserIds.insert(gateway.server.userID)
            try await daveCoordinator?.processDiscordTransition(
                .welcome(data, recognizedUserIds: Array(recognizedUserIds))
            )
            await daveLog("DAVE welcome processed; transition-ready sent (id \(transitionId)).")
            try await gateway.sendTransitionReady(transitionId: transitionId)
        } catch {
            await daveLogError("DAVE welcome processing failed (id \(transitionId)): \(error.localizedDescription)")
            await recoverFromInvalidDaveTransition(transitionId: transitionId)
        }
    }

    private func sendDaveKeyPackage(reason: String) async throws {
        guard let coordinator = daveCoordinator, let gateway = gateway else { return }
        let keyPackage = try await coordinator.getMarshalledKeyPackage()
        try await gateway.sendMlsKeyPackage(keyPackage)
        await daveLog("DAVE MLS key package sent after \(reason).")
    }

    private func recoverFromInvalidDaveTransition(transitionId: UInt64) async {
        await daveLog("DAVE recovering from invalid transition (id \(transitionId)); resetting MLS session.")
        do {
            try await gateway?.sendInvalidCommitWelcome(transitionId: transitionId)
            try await daveCoordinator?.recreateSessionState()
            if let coordinator = daveCoordinator {
                try await applyDaveExternalSenderIfAvailable(to: coordinator, reason: "invalid commit/welcome recovery")
            }
            try await sendDaveKeyPackage(reason: "invalid commit/welcome recovery")
            await daveLog("DAVE session state recreated after invalid transition (id \(transitionId)).")
        } catch {
            await daveLogError("DAVE recovery failed (id \(transitionId)): \(error.localizedDescription)")
        }
    }

    private func applyDaveExternalSenderIfAvailable(to coordinator: DaveSessionCoordinator, reason: String) async throws {
        guard let externalSender = daveExternalSender else { return }
        try await coordinator.setExternalSender(externalSender)
        await daveLog("DAVE external sender reapplied after \(reason).")
    }

    private func handleGatewayClose(_ code: Int) async {
        if status == .connecting || status == .connected {
            await fail("gateway closed (\(code))")
        }
    }

    private func fail(_ reason: String) async {
        Self.logger.error("voice pipeline failed: \(reason)")
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
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        await debug("Voice media ready: \(reason).")
        if daveMediaRequired {
            await logDaveState("secure session active")
        }
        await setStatus(.connected)
        let continuation = readyContinuation
        readyContinuation = nil
        continuation?.resume()
    }

    private func setStatus(_ new: Status) async {
        status = new
        await onStatusChange?(new)
    }

    private func debug(_ message: String) async {
        await onDebug?(message)
    }

    /// Mirror a DAVE protocol/handshake event to both the OS log (Console) and
    /// the in-app voice diagnostics log. This tracks key-exchange and transition
    /// state only — it never carries decrypted or spoken message content.
    private func daveLog(_ message: String) async {
        Self.logger.info("\(message, privacy: .public)")
        await debug(message)
    }

    /// Like `daveLog`, for failure paths (logged at error level).
    private func daveLogError(_ message: String) async {
        Self.logger.error("\(message, privacy: .public)")
        await debug(message)
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
