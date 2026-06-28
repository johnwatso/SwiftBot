import AVFoundation
import Foundation
import Opus

/// Encodes 48 kHz stereo PCM frames into Opus packets sized for Discord
/// voice (20 ms frames = 960 samples per channel).
final class OpusFrameEncoder {
    static let sampleRate: Double = 48_000
    static let channelCount: AVAudioChannelCount = 2
    static let frameDuration: TimeInterval = 0.020
    static let samplesPerFrame: AVAudioFrameCount = 960 // 20 ms @ 48 kHz

    private let encoder: Opus.Encoder
    let format: AVAudioFormat

    init() throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: true
        ) else {
            throw VoicePipelineError.audioFormatUnsupported
        }
        self.format = format
        do {
            self.encoder = try Opus.Encoder(format: format, application: .voip)
        } catch {
            throw VoicePipelineError.opusInitFailed
        }
    }

    /// Encode a 20 ms PCM frame (must be exactly `samplesPerFrame` frames in
    /// the encoder's configured format). Returns the Opus payload bytes.
    func encode(_ buffer: AVAudioPCMBuffer) throws -> Data {
        var output = Data(count: 4000)
        let written = try output.withUnsafeMutableBytes { raw -> Int in
            try encoder.encode(buffer, to: raw)
        }
        output.removeSubrange(written..<output.count)
        return output
    }
}
