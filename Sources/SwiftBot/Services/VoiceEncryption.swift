import CryptoKit
import Foundation

/// RTP-size transport encryption for Discord voice.
///
/// Both supported modes authenticate the complete unencrypted RTP header as
/// additional data and append a four-byte, big-endian packet counter after the
/// ciphertext and authentication tag. Discord requires XChaCha20-Poly1305
/// support and prefers AES-256-GCM when the server offers it.
struct VoiceEncryption {
    private let secretKey: Data
    private let mode: VoiceEncryptionMode
    /// Stored wider than the wire counter so wrapping is impossible. Reusing a
    /// nonce with either AEAD would compromise the session, so callers must
    /// reconnect rather than silently returning to zero after 2^32 packets.
    private var nextPacketCounter: UInt64 = 0

    init(secretKey: Data, mode: VoiceEncryptionMode) throws {
        guard secretKey.count == VoiceSessionKey.secretKeyByteCount else {
            throw VoicePipelineError.invalidTransportEncryption(
                "expected a \(VoiceSessionKey.secretKeyByteCount)-byte secret key, got \(secretKey.count) bytes"
            )
        }
        self.secretKey = secretKey
        self.mode = mode
    }

    mutating func seal(rtpHeader: Data, payload: Data) throws -> Data {
        guard nextPacketCounter <= UInt64(UInt32.max) else {
            throw VoicePipelineError.transportNonceExhausted
        }

        let counter = UInt32(nextPacketCounter)
        nextPacketCounter += 1
        let counterBytes = Self.bigEndianBytes(counter)

        let ciphertext: Data
        let tag: Data
        switch mode {
        case .aeadAes256GcmRtpSize:
            var nonceBytes = Data(count: 12)
            nonceBytes.replaceSubrange(0..<counterBytes.count, with: counterBytes)
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let sealed = try AES.GCM.seal(
                payload,
                using: SymmetricKey(data: secretKey),
                nonce: nonce,
                authenticating: rtpHeader
            )
            ciphertext = sealed.ciphertext
            tag = sealed.tag

        case .aeadXChaCha20Poly1305RtpSize:
            var nonceBytes = Data(count: XChaCha20Poly1305.nonceByteCount)
            nonceBytes.replaceSubrange(0..<counterBytes.count, with: counterBytes)
            let sealed = try XChaCha20Poly1305.seal(
                payload,
                using: secretKey,
                nonce: nonceBytes,
                authenticating: rtpHeader
            )
            ciphertext = sealed.ciphertext
            tag = sealed.tag
        }

        var packet = Data()
        packet.reserveCapacity(rtpHeader.count + ciphertext.count + tag.count + counterBytes.count)
        packet.append(rtpHeader)
        packet.append(ciphertext)
        packet.append(tag)
        packet.append(counterBytes)
        return packet
    }

    private static func bigEndianBytes(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ])
    }
}

/// XChaCha20-Poly1305 built from CryptoKit's 96-bit-nonce ChaCha20-Poly1305.
/// CryptoKit exposes ChaCha20-Poly1305 but not its 192-bit XChaCha variant, so
/// derive the HChaCha20 subkey locally and hand the standard 12-byte nonce to
/// the audited CryptoKit primitive. This is the construction used by
/// libsodium/BoringSSL and required by Discord's RTP-size fallback mode.
enum XChaCha20Poly1305 {
    static let keyByteCount = 32
    static let nonceByteCount = 24

    static func seal(
        _ plaintext: Data,
        using key: Data,
        nonce: Data,
        authenticating authenticatedData: Data
    ) throws -> (ciphertext: Data, tag: Data) {
        guard key.count == keyByteCount else {
            throw VoicePipelineError.invalidTransportEncryption(
                "XChaCha20-Poly1305 requires a \(keyByteCount)-byte key"
            )
        }
        guard nonce.count == nonceByteCount else {
            throw VoicePipelineError.invalidTransportEncryption(
                "XChaCha20-Poly1305 requires a \(nonceByteCount)-byte nonce"
            )
        }

        let subkey = try hChaCha20(key: key, nonce: Data(nonce.prefix(16)))
        var chachaNonce = Data(repeating: 0, count: 4)
        chachaNonce.append(nonce.suffix(8))
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: subkey),
            nonce: ChaChaPoly.Nonce(data: chachaNonce),
            authenticating: authenticatedData
        )
        return (sealed.ciphertext, sealed.tag)
    }

    /// HChaCha20: run the ChaCha20 rounds over the key and first 16 bytes of
    /// the XChaCha nonce, then return state words 0...3 and 12...15.
    static func hChaCha20(key: Data, nonce: Data) throws -> Data {
        guard key.count == keyByteCount, nonce.count == 16 else {
            throw VoicePipelineError.invalidTransportEncryption(
                "HChaCha20 requires a 32-byte key and 16-byte nonce"
            )
        }

        var state: [UInt32] = [
            0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574
        ]
        for offset in stride(from: 0, to: key.count, by: 4) {
            state.append(littleEndianWord(in: key, at: offset))
        }
        for offset in stride(from: 0, to: nonce.count, by: 4) {
            state.append(littleEndianWord(in: nonce, at: offset))
        }

        for _ in 0..<10 {
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }

        var subkey = Data()
        subkey.reserveCapacity(keyByteCount)
        for index in [0, 1, 2, 3, 12, 13, 14, 15] {
            appendLittleEndian(state[index], to: &subkey)
        }
        return subkey
    }

    private static func littleEndianWord(in bytes: Data, at offset: Int) -> UInt32 {
        let start = bytes.startIndex + offset
        return UInt32(bytes[start])
            | (UInt32(bytes[start + 1]) << 8)
            | (UInt32(bytes[start + 2]) << 16)
            | (UInt32(bytes[start + 3]) << 24)
    }

    private static func appendLittleEndian(_ value: UInt32, to output: inout Data) {
        output.append(UInt8(truncatingIfNeeded: value))
        output.append(UInt8(truncatingIfNeeded: value >> 8))
        output.append(UInt8(truncatingIfNeeded: value >> 16))
        output.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func quarterRound(
        _ state: inout [UInt32],
        _ a: Int,
        _ b: Int,
        _ c: Int,
        _ d: Int
    ) {
        var aValue = state[a]
        var bValue = state[b]
        var cValue = state[c]
        var dValue = state[d]

        aValue &+= bValue
        dValue = (dValue ^ aValue).rotatedLeft(by: 16)
        cValue &+= dValue
        bValue = (bValue ^ cValue).rotatedLeft(by: 12)
        aValue &+= bValue
        dValue = (dValue ^ aValue).rotatedLeft(by: 8)
        cValue &+= dValue
        bValue = (bValue ^ cValue).rotatedLeft(by: 7)

        state[a] = aValue
        state[b] = bValue
        state[c] = cValue
        state[d] = dValue
    }
}

private extension UInt32 {
    func rotatedLeft(by count: UInt32) -> UInt32 {
        (self << count) | (self >> (32 - count))
    }
}
