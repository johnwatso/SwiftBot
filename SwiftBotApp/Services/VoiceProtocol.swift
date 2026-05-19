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
    case clientDisconnect = 13
}

enum VoiceEncryptionMode: String {
    case aeadAes256GcmRtpSize = "aead_aes256_gcm_rtpsize"
    case aeadXChaCha20Poly1305RtpSize = "aead_xchacha20_poly1305_rtpsize"

    static var preferred: [VoiceEncryptionMode] {
        [.aeadAes256GcmRtpSize]
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
    let secretKey: Data
    let mode: VoiceEncryptionMode
}

enum VoicePipelineError: LocalizedError {
    case invalidEndpoint(String)
    case missingEncryptionMode
    case ipDiscoveryFailed(String)
    case unexpectedPayload(String)
    case socketClosed
    case opusInitFailed
    case audioFormatUnsupported
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let e): return "Invalid voice endpoint: \(e)"
        case .missingEncryptionMode: return "No supported encryption mode advertised by Discord"
        case .ipDiscoveryFailed(let reason): return "IP discovery failed: \(reason)"
        case .unexpectedPayload(let reason): return "Unexpected voice payload: \(reason)"
        case .socketClosed: return "Voice socket closed"
        case .opusInitFailed: return "Opus encoder init failed"
        case .audioFormatUnsupported: return "Audio format unsupported"
        case .notConnected: return "Voice pipeline not connected"
        }
    }
}
