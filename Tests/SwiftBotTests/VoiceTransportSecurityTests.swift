import Foundation
import XCTest
@testable import SwiftBot

final class VoiceTransportSecurityTests: XCTestCase {
    func testUDPCompletionDeadlineStopsTransportWhenNetworkNeverCompletesSend() async {
        let transport = VoiceUDPTransport(
            host: "127.0.0.1",
            port: 9,
            testingSendCompletionTimeout: .milliseconds(25),
            testingSendImplementation: { _, _ in
                // Deliberately never invoke the content-processed completion.
                // This models the Network.framework wedge that previously
                // held idle keepalive sends forever.
            }
        )

        do {
            try await transport.send(Data([0x01]))
            XCTFail("a lost UDP completion must fail at its deadline")
        } catch let error as VoicePipelineError {
            guard case .timeout = error else {
                return XCTFail("expected UDP send timeout, got \(error)")
            }
        } catch {
            XCTFail("expected VoicePipelineError.timeout, got \(error)")
        }

        // The deadline is a transport failure, not merely a returned error:
        // stopping the one-shot socket wakes any sibling send and lets the
        // playback keepalive loop turn this into normal session recovery.
        do {
            try await transport.send(Data([0x02]))
            XCTFail("the timed-out UDP transport must be stopped")
        } catch let error as VoicePipelineError {
            guard case .socketClosed = error else {
                return XCTFail("expected stopped transport, got \(error)")
            }
        } catch {
            XCTFail("expected VoicePipelineError.socketClosed, got \(error)")
        }
    }

    func testEncryptionModeSelectsAESWhenBothModesAreAdvertised() {
        let mode = VoiceEncryptionMode.select(from: [
            VoiceEncryptionMode.aeadXChaCha20Poly1305RtpSize.rawValue,
            VoiceEncryptionMode.aeadAes256GcmRtpSize.rawValue
        ])

        XCTAssertEqual(mode, .aeadAes256GcmRtpSize)
    }

    func testEncryptionModeFallsBackToRequiredXChaCha() {
        let mode = VoiceEncryptionMode.select(from: [
            VoiceEncryptionMode.aeadXChaCha20Poly1305RtpSize.rawValue
        ])

        XCTAssertEqual(mode, .aeadXChaCha20Poly1305RtpSize)
    }

    func testEncryptionModeRejectsDeprecatedAndUnknownModes() {
        XCTAssertNil(VoiceEncryptionMode.select(from: [
            "xsalsa20_poly1305_lite_rtpsize",
            "not-a-real-mode"
        ]))
    }

    func testTransportEncryptionRejectsMalformedSecretKey() {
        XCTAssertThrowsError(try VoiceEncryption(
            secretKey: Data(repeating: 0, count: VoiceSessionKey.secretKeyByteCount - 1),
            mode: .aeadXChaCha20Poly1305RtpSize
        ))
    }

    func testHChaCha20MatchesReferenceVector() throws {
        let subkey = try XChaCha20Poly1305.hChaCha20(
            key: data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            nonce: data(hex: "000000090000004a0000000031415927")
        )

        XCTAssertEqual(
            subkey,
            data(hex: "82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc")
        )
    }

    func testXChaCha20Poly1305MatchesReferenceVector() throws {
        let sealed = try XChaCha20Poly1305.seal(
            data(hex: "4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e"),
            using: data(hex: "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"),
            nonce: data(hex: "404142434445464748494a4b4c4d4e4f5051525354555657"),
            authenticating: data(hex: "50515253c0c1c2c3c4c5c6c7")
        )

        XCTAssertEqual(
            sealed.ciphertext,
            data(hex: "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b4522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff921f9664c97637da9768812f615c68b13b52e")
        )
        XCTAssertEqual(sealed.tag, data(hex: "c0875924c1c7987947deafd8780acf49"))
    }

    func testXChaChaRtpSizePreservesHeaderAndAppendsCounter() throws {
        var encryption = try VoiceEncryption(
            secretKey: Data(repeating: 0x42, count: VoiceSessionKey.secretKeyByteCount),
            mode: .aeadXChaCha20Poly1305RtpSize
        )
        let header = data(hex: "80780001000003c00000002a")
        let payload = Data([0xf8, 0xff, 0xfe])

        let first = try encryption.seal(rtpHeader: header, payload: payload)
        let second = try encryption.seal(rtpHeader: header, payload: payload)

        XCTAssertEqual(first.prefix(header.count), header)
        XCTAssertEqual(first.suffix(4), data(hex: "00000000"))
        XCTAssertEqual(second.suffix(4), data(hex: "00000001"))
        XCTAssertEqual(first.count, header.count + payload.count + 16 + 4)
    }

    func testExactTransitionIDParsingDoesNotLoseUInt64Precision() throws {
        let data = Data("""
        {"op":21,"seq":7,"d":{"transition_id":"18446744073709551615","protocol_version":1}}
        """.utf8)

        let envelope = try JSONDecoder().decode(VoiceGatewayIncomingEnvelope.self, from: data)
        let transition = try JSONDecoder().decode(VoiceGatewayPrepareTransition.self, from: data)

        XCTAssertEqual(envelope.opcode, VoiceOpcode.davePrepareTransition.rawValue)
        XCTAssertEqual(envelope.sequence, 7)
        XCTAssertEqual(transition.data.transitionID.value, UInt64.max)
        XCTAssertEqual(transition.data.protocolVersion.value, 1)
    }

    func testPrepareEpochPreservesExactTransitionID() throws {
        let data = Data("""
        {"op":24,"seq":8,"d":{"transition_id":"18446744073709551615","protocol_version":1,"epoch":2}}
        """.utf8)

        let epoch = try JSONDecoder().decode(VoiceGatewayPrepareEpoch.self, from: data)

        XCTAssertEqual(epoch.data.transitionID.value, UInt64.max)
        XCTAssertEqual(epoch.data.protocolVersion.value, 1)
        XCTAssertEqual(epoch.data.epoch.value, 2)
    }

    func testExactTransitionIDRejectsFractionalAndOutOfRangeValues() {
        let fractional = Data("{\"transition_id\":1.5}".utf8)
        let overflow = Data("{\"transition_id\":18446744073709551616}".utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(TransitionIDEnvelope.self, from: fractional))
        XCTAssertThrowsError(try JSONDecoder().decode(TransitionIDEnvelope.self, from: overflow))
    }

    private func data(hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            UInt8(hex[hex.index(hex.startIndex, offsetBy: offset)..<hex.index(hex.startIndex, offsetBy: offset + 2)], radix: 16)!
        })
    }
}

private struct TransitionIDEnvelope: Decodable {
    let transitionID: VoiceExactUInt64

    enum CodingKeys: String, CodingKey {
        case transitionID = "transition_id"
    }
}
