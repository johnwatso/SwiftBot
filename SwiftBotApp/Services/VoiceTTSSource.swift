@preconcurrency import AVFoundation
import Foundation
import OSLog

/// Produces 48 kHz stereo Float32 PCM buffers from `AVSpeechSynthesizer`,
/// suitable for feeding straight into `VoicePlaybackService.speak(pcm:)`.
final class VoiceTTSSource: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.swiftbot", category: "voice.tts")

    /// The Opus pipeline's input format: 48 kHz stereo interleaved Float32.
    private let targetFormat: AVAudioFormat

    init() throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: OpusFrameEncoder.sampleRate,
            channels: OpusFrameEncoder.channelCount,
            interleaved: true
        ) else {
            throw VoicePipelineError.audioFormatUnsupported
        }
        self.targetFormat = format
    }

    var format: AVAudioFormat { targetFormat }

    /// Pick the best available voice for an English locale.
    /// Prefers Nathan Enhanced → Premium → Enhanced → Default.
    static func preferredEnglishVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        if let nathan = englishVoices.first(where: { $0.name == "Nathan (Enhanced)" }) { return nathan }
        if let nathan = englishVoices.first(where: { $0.identifier == "com.apple.voice.enhanced.en-US.Nathan" }) { return nathan }
        if let premium = englishVoices.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = englishVoices.first(where: { $0.quality == .enhanced }) { return enhanced }
        return englishVoices.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Synthesize `text` and return one fully-rendered AVAudioPCMBuffer in the
    /// pipeline's target format (48 kHz, stereo, interleaved Float32).
    func render(text: String, voice: AVSpeechSynthesisVoice?) async throws -> AVAudioPCMBuffer {
        // AVSpeechSynthesizer's internal accessibility setup must run on the
        // main thread. Creating/driving it from a background actor triggers
        // "unsafeForcedSync called from Swift Concurrent context" faults in
        // AXCoreUtilities, so set the synthesizer up on the MainActor.
        let format = targetFormat
        let resolvedVoice = voice ?? Self.preferredEnglishVoice()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVAudioPCMBuffer, Error>) in
            Task { @MainActor in
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = resolvedVoice
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                utterance.pitchMultiplier = 1.0
                utterance.volume = 1.0

                let synthesizer = AVSpeechSynthesizer()
                let collector = SynthesisCollector(targetFormat: format) { result in
                    switch result {
                    case .success(let buffer):
                        continuation.resume(returning: buffer)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                    _ = synthesizer // keep alive until completion
                }
                synthesizer.write(utterance) { buffer in
                    collector.append(buffer)
                }
                // The completion of `write` is signalled by an empty buffer.
            }
        }
    }

    /// Synthesize `text` and yield partial buffers via AsyncThrowingStream as they
    /// are produced by AVSpeechSynthesizer. Each chunk is converted to the target
    /// format (48 kHz, stereo, interleaved Float32).
    func renderStream(text: String, voice: AVSpeechSynthesisVoice?) -> AsyncThrowingStream<SendableAudioBuffer, Error> {
        let format = targetFormat
        let resolvedVoice = voice ?? Self.preferredEnglishVoice()
        // The converter state is owned by a lock-guarded helper rather than a
        // captured `var`: AVSpeechSynthesizer delivers buffers on its own
        // (non-main) thread, so mutating shared converter state straight from
        // the callback would be a data race.
        let converter = StreamingConverter(targetFormat: format)
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = resolvedVoice
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                utterance.pitchMultiplier = 1.0
                utterance.volume = 1.0

                // Box the synthesizer so the @Sendable termination handler can
                // hold and stop it (AVSpeechSynthesizer isn't Sendable). The box
                // also keeps the synthesizer alive for the stream's lifetime.
                let box = SpeechSynthesizerBox()

                // If the consumer terminates early — e.g. a stall timeout cancels
                // playback — stop synthesis so a half-rendered utterance doesn't
                // keep running in the background.
                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in box.synthesizer.stopSpeaking(at: .immediate) }
                }

                box.synthesizer.write(utterance) { buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    do {
                        guard let converted = try converter.convert(pcm) else {
                            // An empty buffer signals end-of-synthesis.
                            continuation.finish()
                            return
                        }
                        continuation.yield(SendableAudioBuffer(buffer: converted))
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
}

/// Holds an `AVSpeechSynthesizer` so a `@Sendable` closure can retain and stop
/// it. The synthesizer is only ever touched on the MainActor; this box just
/// carries the reference across the Sendable boundary.
private final class SpeechSynthesizerBox: @unchecked Sendable {
    let synthesizer = AVSpeechSynthesizer()
}

/// Converts partial PCM buffers from `AVSpeechSynthesizer.write` to the target
/// format. The write callback is invoked off the main thread, so the lazily
/// built `AVAudioConverter` is guarded by a lock — the buffer callbacks are
/// serialised in practice, but the lock makes the shared state access correct
/// rather than relying on that.
private final class StreamingConverter: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()
    private var converter: AVAudioConverter?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    /// Returns `buffer` converted to `targetFormat`, or `nil` for an empty
    /// (end-of-synthesis) buffer. Throws on unsupported format / conversion error.
    func convert(_ pcm: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard pcm.frameLength > 0 else { return nil }
        if pcm.format == targetFormat { return pcm }

        lock.lock()
        defer { lock.unlock() }

        if converter == nil {
            guard let newConverter = AVAudioConverter(from: pcm.format, to: targetFormat) else {
                throw VoicePipelineError.audioFormatUnsupported
            }
            converter = newConverter
        }
        guard let converter else { throw VoicePipelineError.audioFormatUnsupported }

        let ratio = targetFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw VoicePipelineError.audioFormatUnsupported
        }

        var sourceConsumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if sourceConsumed {
                status.pointee = .endOfStream
                return nil
            }
            sourceConsumed = true
            status.pointee = .haveData
            return pcm
        }
        if status == .error, let conversionError {
            throw conversionError
        }
        return output
    }
}

/// Accumulates partial PCM buffers from `AVSpeechSynthesizer.write` and
/// resamples them to the target format on completion.
private final class SynthesisCollector {
    private let targetFormat: AVAudioFormat
    private let completion: (Result<AVAudioPCMBuffer, Error>) -> Void
    private var sourceFormat: AVAudioFormat?
    private var collected: [AVAudioPCMBuffer] = []
    private var finished = false
    private let lock = NSLock()

    init(targetFormat: AVAudioFormat, completion: @escaping (Result<AVAudioPCMBuffer, Error>) -> Void) {
        self.targetFormat = targetFormat
        self.completion = completion
    }

    func append(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        guard let pcm = buffer as? AVAudioPCMBuffer else {
            return
        }
        if pcm.frameLength == 0 {
            finishLocked()
            return
        }
        if sourceFormat == nil { sourceFormat = pcm.format }
        collected.append(pcm)
    }

    private func finishLocked() {
        finished = true
        guard let sourceFormat = sourceFormat, !collected.isEmpty else {
            completion(.failure(VoicePipelineError.audioFormatUnsupported))
            return
        }

        let totalFrames = collected.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard let merged = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: totalFrames) else {
            completion(.failure(VoicePipelineError.audioFormatUnsupported))
            return
        }
        merged.frameLength = totalFrames
        var offset: AVAudioFrameCount = 0
        for chunk in collected {
            copyFrames(chunk, into: merged, atOffset: offset)
            offset += chunk.frameLength
        }

        do {
            let converted = try convert(merged, to: targetFormat)
            completion(.success(converted))
        } catch {
            completion(.failure(error))
        }
    }

    private func copyFrames(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer, atOffset offset: AVAudioFrameCount) {
        let frames = Int(source.frameLength)
        if let srcF = source.floatChannelData, let dstF = destination.floatChannelData {
            let channels = Int(source.format.channelCount)
            if source.format.isInterleaved {
                let s = srcF[0]
                let d = dstF[0]
                let off = Int(offset) * channels
                for i in 0..<(frames * channels) { d[off + i] = s[i] }
            } else {
                for c in 0..<channels {
                    let s = srcF[c]
                    let d = dstF[c]
                    for i in 0..<frames { d[Int(offset) + i] = s[i] }
                }
            }
        } else if let srcI = source.int16ChannelData, let dstF = destination.floatChannelData {
            // Float dest, Int16 source: shouldn't happen because dest matches source format,
            // but guard anyway.
            let channels = Int(source.format.channelCount)
            for c in 0..<channels {
                let s = srcI[c]
                let d = dstF[c]
                for i in 0..<frames { d[Int(offset) + i] = Float(s[i]) / 32768.0 }
            }
        }
    }

    private func convert(_ source: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if source.format == targetFormat { return source }
        guard let converter = AVAudioConverter(from: source.format, to: targetFormat) else {
            throw VoicePipelineError.audioFormatUnsupported
        }
        let ratio = targetFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw VoicePipelineError.audioFormatUnsupported
        }

        final class ConversionState: @unchecked Sendable {
            var sourceConsumed = false
        }
        let state = ConversionState()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if state.sourceConsumed {
                status.pointee = .endOfStream
                return nil
            }
            state.sourceConsumed = true
            status.pointee = .haveData
            return source
        }
        if status == .error, let conversionError {
            throw conversionError
        }
        return output
    }
}
