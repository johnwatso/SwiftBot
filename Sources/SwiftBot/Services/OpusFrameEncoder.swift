import AVFoundation
import Foundation
import Opus

/// Encodes 48 kHz stereo PCM frames into Opus packets sized for Discord
/// voice (20 ms frames = 960 samples per channel).
final class OpusFrameEncoder {
    /// Presets tuned for Discord's 48 kHz stereo voice transport. SwiftBot
    /// defaults to `.reliable` because announcements are speech and a small
    /// FEC overhead is preferable to a clipped sentence on a lossy route.
    enum Profile: String, Sendable {
        case lowLatency
        case balanced
        case reliable

        var configuration: Opus.Encoder.Configuration {
            switch self {
            case .lowLatency:
                .init(
                    bitrate: 96_000,
                    complexity: 5,
                    usesVariableBitrate: true,
                    usesConstrainedVariableBitrate: true,
                    usesInbandFEC: false,
                    expectedPacketLossPercentage: 0,
                    signal: .voice,
                    maximumBandwidth: .fullband
                )
            case .balanced:
                .init(
                    bitrate: 96_000,
                    complexity: 7,
                    usesVariableBitrate: true,
                    usesConstrainedVariableBitrate: true,
                    usesInbandFEC: true,
                    expectedPacketLossPercentage: 5,
                    signal: .voice,
                    maximumBandwidth: .fullband
                )
            case .reliable:
                .init(
                    bitrate: 96_000,
                    complexity: 8,
                    usesVariableBitrate: true,
                    usesConstrainedVariableBitrate: true,
                    usesInbandFEC: true,
                    expectedPacketLossPercentage: 10,
                    signal: .voice,
                    maximumBandwidth: .fullband
                )
            }
        }
    }

    static let sampleRate: Double = 48_000
    static let channelCount: AVAudioChannelCount = 2
    static let frameDuration: TimeInterval = 0.020
    static let samplesPerFrame: AVAudioFrameCount = 960 // 20 ms @ 48 kHz

    private let encoder: Opus.Encoder
    let profile: Profile
    let format: AVAudioFormat

    init(profile: Profile = .reliable) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: true
        ) else {
            throw VoicePipelineError.audioFormatUnsupported
        }
        self.format = format
        self.profile = profile
        do {
            self.encoder = try Opus.Encoder(format: format, application: .voip)
            try encoder.configure(profile.configuration)
        } catch {
            throw VoicePipelineError.opusInitFailed
        }
    }

    /// Encode a 20 ms PCM frame (must be exactly `samplesPerFrame` frames in
    /// the encoder's configured format). Returns the Opus payload bytes.
    func encode(_ buffer: AVAudioPCMBuffer) throws -> Data {
        try encoder.encode(buffer)
    }
}
