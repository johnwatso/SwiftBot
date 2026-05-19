import AVFoundation
import Foundation
import OSLog

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
    private var readyContinuation: CheckedContinuation<Void, Error>?

    private var onStatusChange: ((Status) async -> Void)?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func setOnStatusChange(_ handler: @escaping (Status) async -> Void) {
        onStatusChange = handler
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
        await gateway?.disconnect()
        await transport?.stop()
        gateway = nil
        transport = nil
        encryption = nil
        rtp = nil
        opus = nil
        ssrc = nil
        negotiatedMode = nil
        await setStatus(.idle)
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
        try await gateway.sendSpeaking(true, ssrc: ssrc)
        defer { Task { try? await gateway.sendSpeaking(false, ssrc: ssrc) } }

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
    }

    /// Heartbeat-style silence frame to keep the connection alive between
    /// announcements.
    func sendKeepalive() async throws {
        guard status == .connected,
              let transport = transport,
              var rtp = self.rtp,
              var encryption = self.encryption else {
            return
        }
        let header = rtp.nextHeader(samplesPerChannel: UInt32(OpusFrameEncoder.samplesPerFrame))
        let packet = try encryption.seal(rtpHeader: header, payload: RTPPacketBuilder.opusSilenceFrame)
        try await transport.send(packet)
        self.rtp = rtp
        self.encryption = encryption
    }

    // MARK: - Private

    private func sendFrame(_ buffer: AVAudioPCMBuffer, transport: VoiceUDPTransport) async throws {
        guard let opus = opus,
              var rtp = self.rtp,
              var encryption = self.encryption else {
            return
        }
        let payload = try opus.encode(buffer)
        let header = rtp.nextHeader(samplesPerChannel: UInt32(OpusFrameEncoder.samplesPerFrame))
        let packet = try encryption.seal(rtpHeader: header, payload: payload)
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

        let udp = VoiceUDPTransport(host: info.ip, port: info.port)
        transport = udp
        do {
            try await udp.start()
            let address = try await udp.discoverAddress(ssrc: info.ssrc)
            try await gateway?.sendSelectProtocol(address: address, mode: mode)
        } catch {
            await fail("ip discovery failed: \(error.localizedDescription)")
        }
    }

    private func handleSessionDescription(_ key: VoiceSessionKey) async {
        encryption = VoiceEncryption(secretKey: key.secretKey)
        await setStatus(.connected)
        let continuation = readyContinuation
        readyContinuation = nil
        continuation?.resume()
    }

    private func handleGatewayClose(_ code: Int) async {
        if status == .connecting || status == .connected {
            await fail("gateway closed (\(code))")
        }
    }

    private func fail(_ reason: String) async {
        Self.logger.error("voice pipeline failed: \(reason)")
        await setStatus(.failed(reason))
        let continuation = readyContinuation
        readyContinuation = nil
        continuation?.resume(throwing: VoicePipelineError.unexpectedPayload(reason))
    }

    private func setStatus(_ new: Status) async {
        status = new
        await onStatusChange?(new)
    }

    private func isFailed(_ status: Status) -> Bool {
        if case .failed = status { return true }
        return false
    }
}
