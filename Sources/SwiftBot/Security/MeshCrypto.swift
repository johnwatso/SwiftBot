import CryptoKit
import Foundation

/// Body-level encryption for SwiftMesh inter-node traffic. AES-256-GCM with
/// the symmetric key derived from `clusterSharedSecret` via HKDF-SHA256.
///
/// Threat model: limited port forwards over WAN. The shared secret already
/// authenticates peers via HMAC; this layer adds confidentiality of message
/// payloads (Discord token, conversation sync, config files, etc.) so a
/// network observer between the two nodes can't read them.
///
/// Trade-offs accepted:
/// - No forward secrecy. If `clusterSharedSecret` is leaked later, captured
///   traffic can be decrypted retroactively. Mitigated by the
///   `RevealableSecretField`'s regenerate button — rotate the shared secret
///   if you suspect compromise.
/// - Symmetric crypto only. No certificate validation, no PKI. The HMAC
///   layer remains the authenticity gate.
enum MeshCrypto {
    /// Versioned header value sent alongside an encrypted request body.
    /// Bump if the wire format ever changes.
    static let headerValueV1 = "v1"
    /// Request/response header name that flags an encrypted body.
    static let headerName = "X-Mesh-Encrypted"

    /// HKDF salt and context info are constant per protocol version, so both
    /// sides derive the same key without any handshake exchange.
    private static let salt = Data("SwiftMesh-v1".utf8)
    private static let keyInfo = Data("SwiftMesh-body-encryption-v1".utf8)

    enum Error: Swift.Error, LocalizedError {
        case emptySharedSecret
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .emptySharedSecret: return "Cluster shared secret is empty — mesh encryption requires a secret"
            case .decryptionFailed: return "Mesh body decryption failed (auth tag mismatch or malformed ciphertext)"
            }
        }
    }

    /// Derives the 256-bit symmetric key used for both seal and open. Same
    /// shared secret in → same key out, on both peers.
    static func deriveKey(from sharedSecret: String) throws -> SymmetricKey {
        let trimmed = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.emptySharedSecret }
        let ikm = SymmetricKey(data: Data(trimmed.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: keyInfo,
            outputByteCount: 32
        )
    }

    /// Seals `plaintext` and returns `nonce(12) ‖ ciphertext ‖ tag(16)`. The
    /// returned bytes are what gets sent on the wire as the request body.
    /// Empty plaintext is returned as empty (no-op) so GET/empty-body calls
    /// don't carry a 28-byte overhead for no benefit; callers must omit the
    /// `X-Mesh-Encrypted` header in that case.
    static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        guard !plaintext.isEmpty else { return Data() }
        // CryptoKit's AES.GCM.seal generates a random 96-bit nonce by default,
        // which is the recommended choice when message counts are small and a
        // dedicated counter would add complexity for no gain.
        let sealed = try AES.GCM.seal(plaintext, using: key)
        // `combined` is non-nil for the default 12-byte nonce path. Force-unwrap
        // is safe here — the only case it returns nil is custom non-96-bit nonces.
        return sealed.combined ?? Data()
    }

    /// Reverses `seal`. Throws on tampering — the AES-GCM auth tag covers
    /// every byte of the ciphertext, so any modification fails closed.
    static func open(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        guard !ciphertext.isEmpty else { return Data() }
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw Error.decryptionFailed
        }
    }
}
