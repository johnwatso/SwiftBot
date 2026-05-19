import Foundation
import CryptoKit

/// AES-256-GCM RTP-size encryption as used by Discord voice gateway v8.
///
/// Layout produced by `seal`:
/// `[12-byte RTP header][AES-GCM ciphertext + 16-byte tag][4-byte BE nonce counter]`
///
/// The 12-byte AES-GCM nonce is the 32-bit packet counter written big-endian
/// at offset 0, with the trailing 8 bytes left as zero. The RTP header is fed
/// to AES-GCM as additional authenticated data (AAD).
struct VoiceEncryption {
    private let key: SymmetricKey
    private var counter: UInt32 = 0

    init(secretKey: Data) {
        self.key = SymmetricKey(data: secretKey)
    }

    mutating func seal(rtpHeader: Data, payload: Data) throws -> Data {
        counter &+= 1
        var nonceBytes = Data(count: 12)
        nonceBytes[0] = UInt8((counter >> 24) & 0xff)
        nonceBytes[1] = UInt8((counter >> 16) & 0xff)
        nonceBytes[2] = UInt8((counter >> 8) & 0xff)
        nonceBytes[3] = UInt8(counter & 0xff)

        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.seal(
            payload,
            using: key,
            nonce: nonce,
            authenticating: rtpHeader
        )

        var packet = Data()
        packet.reserveCapacity(rtpHeader.count + sealed.ciphertext.count + sealed.tag.count + 4)
        packet.append(rtpHeader)
        packet.append(sealed.ciphertext)
        packet.append(sealed.tag)
        packet.append(nonceBytes[0])
        packet.append(nonceBytes[1])
        packet.append(nonceBytes[2])
        packet.append(nonceBytes[3])
        return packet
    }
}
