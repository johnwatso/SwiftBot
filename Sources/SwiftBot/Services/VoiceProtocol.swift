import AVFoundation
import Foundation

enum VoiceOpcode: Int {
    case identify = 0
    case selectProtocol = 1
    case ready = 2
    case heartbeat = 3
    case sessionDescription = 4
    case speaking = 5
    case heartbeatAck = 6
    case resume = 7
    case hello = 8
    case resumed = 9
    case clientsConnect = 11
    case clientDisconnect = 13
    case davePrepareTransition = 21
    case daveExecuteTransition = 22
    case daveTransitionReady = 23
    case davePrepareEpoch = 24
    case mlsExternalSenderPackage = 25
    case daveMlsKeyPackage = 26
    case daveMlsProposals = 27
    case daveMlsCommitWelcome = 28
    case daveMlsAnnounceCommitTransition = 29
    case daveMlsWelcome = 30
    case daveMlsInvalidCommitWelcome = 31
}

enum VoiceBinaryFrame {
    static func decodeServerFrame(_ data: Data) -> (sequence: UInt16, opcode: VoiceOpcode, payload: Data)? {
        guard data.count >= 3 else { return nil }
        let sequence = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
        guard let opcode = VoiceOpcode(rawValue: Int(data[data.startIndex + 2])) else { return nil }
        return (sequence, opcode, Data(data.dropFirst(3)))
    }

    static func encodeClientFrame(opcode: VoiceOpcode, payload: Data = Data()) -> Data {
        var frame = Data([UInt8(clamping: opcode.rawValue)])
        frame.append(payload)
        return frame
    }

    static func uint16BigEndian(from payload: Data) -> UInt16? {
        guard payload.count >= 2 else { return nil }
        return UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
    }
}

enum VoiceEncryptionMode: String, Sendable, CaseIterable {
    case aeadAes256GcmRtpSize = "aead_aes256_gcm_rtpsize"
    case aeadXChaCha20Poly1305RtpSize = "aead_xchacha20_poly1305_rtpsize"

    /// Discord requires XChaCha20-Poly1305 support, but recommends AES-GCM
    /// when the server advertises both modes. Keep this order client-owned;
    /// trusting server order accidentally selected the slower fallback on
    /// otherwise capable voice servers.
    static var preferred: [VoiceEncryptionMode] {
        [.aeadAes256GcmRtpSize, .aeadXChaCha20Poly1305RtpSize]
    }

    /// Chooses only from modes advertised by the current voice server.
    static func select(from advertisedModes: some Sequence<String>) -> VoiceEncryptionMode? {
        let advertised = Set(advertisedModes)
        return preferred.first { advertised.contains($0.rawValue) }
    }
}

struct VoiceServerInfo: Sendable, Equatable {
    let guildID: String
    let userID: String
    let sessionID: String
    let token: String
    let endpoint: String
}

struct VoiceReadyInfo: Sendable, Equatable {
    let ssrc: UInt32
    let ip: String
    let port: UInt16
    let modes: [String]
}

struct VoiceSessionKey: Sendable, Equatable {
    static let secretKeyByteCount = 32

    let secretKey: Data
    let mode: VoiceEncryptionMode
    let daveProtocolVersion: UInt16?

    var hasValidSecretKeyLength: Bool {
        secretKey.count == Self.secretKeyByteCount
    }
}

enum VoicePipelineError: LocalizedError {
    case invalidEndpoint(String)
    case missingEncryptionMode
    case ipDiscoveryFailed(String)
    case unexpectedPayload(String)
    case invalidTransportEncryption(String)
    case transportNonceExhausted
    case socketClosed
    case opusInitFailed
    case audioFormatUnsupported
    case audioRenderInvalid(String)
    case notConnected
    case daveNotReady
    case timeout
    case playbackTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let e): return "Invalid voice endpoint: \(e)"
        case .missingEncryptionMode: return "No supported encryption mode advertised by Discord"
        case .ipDiscoveryFailed(let reason): return "IP discovery failed: \(reason)"
        case .unexpectedPayload(let reason): return "Unexpected voice payload: \(reason)"
        case .invalidTransportEncryption(let reason): return "Invalid voice transport encryption: \(reason)"
        case .transportNonceExhausted: return "Voice transport nonce counter exhausted; reconnect before sending more audio"
        case .socketClosed: return "Voice socket closed"
        case .opusInitFailed: return "Opus encoder init failed"
        case .audioFormatUnsupported: return "Audio format unsupported"
        case .audioRenderInvalid(let reason): return "Speech audio invalid: \(reason)"
        case .notConnected: return "Voice pipeline not connected"
        case .daveNotReady: return "DAVE media encryption is not ready yet"
        case .timeout: return "Voice operation timed out"
        case .playbackTimedOut: return "Voice playback timed out"
        }
    }
}

struct SendableAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
