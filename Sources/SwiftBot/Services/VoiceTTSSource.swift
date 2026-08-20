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
    /// Prefers Ryan Piper -> any Piper -> Premium -> Enhanced -> Default.
    static func preferredEnglishVoice() -> AVSpeechSynthesisVoice? {
        preferredEnglishVoice(from: AVSpeechSynthesisVoice.speechVoices())
    }

    static func preferredEnglishVoice(from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let englishVoices = voices.filter { $0.language.hasPrefix("en") }
        if let ryanPiper = englishVoices.first(where: isRyanPiperVoice) { return ryanPiper }
        if let piper = englishVoices.first(where: isPiperVoice) { return piper }
        if let premium = englishVoices.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = englishVoices.first(where: { $0.quality == .enhanced }) { return enhanced }
        return englishVoices.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func isPiperVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.identifier.localizedCaseInsensitiveContains("piper") ||
            voice.name.localizedCaseInsensitiveContains("piper")
    }

    static func isRyanPiperVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        isPiperVoice(voice) &&
            (voice.identifier.localizedCaseInsensitiveContains("ryan") ||
             voice.name.localizedCaseInsensitiveContains("ryan"))
    }

    /// Third-party voices ship as separate app extensions, so they can crash or
    /// fail to launch independently of SwiftBot. Apple's built-in voices are
    /// in-process assets and stay available when that happens.
    static func isSystemVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.identifier.hasPrefix("com.apple.")
    }

    /// The voice a failed render retries with. It must be a *different* engine
    /// from `selectedIdentifier`, not merely a different identifier: reusing
    /// `preferredEnglishVoice()` here resolved to the selected voice itself on
    /// a default configuration, so the retry re-entered the engine that had
    /// just failed and the fallback never did anything.
    static func fallbackEnglishVoice(excluding selectedIdentifier: String?) -> AVSpeechSynthesisVoice? {
        fallbackEnglishVoice(from: AVSpeechSynthesisVoice.speechVoices(), excluding: selectedIdentifier)
    }

    static func fallbackEnglishVoice(
        from voices: [AVSpeechSynthesisVoice],
        excluding selectedIdentifier: String?
    ) -> AVSpeechSynthesisVoice? {
        let candidates = voices
            .filter { $0.language.hasPrefix("en") }
            .filter { $0.identifier != selectedIdentifier }
        let systemVoices = candidates.filter(isSystemVoice)
        // Compact (`.default`) voices are bundled with macOS; premium and
        // enhanced ones are downloadable assets that may not be present. The
        // fallback's job is to always work, so quality comes last here.
        if let compact = systemVoices.first(where: { $0.quality == .default }) { return compact }
        if let anySystem = systemVoices.first { return anySystem }
        // No Apple voice installed for English at all; any other engine still
        // beats retrying the one that just failed.
        return candidates.first
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
        let completion = SynthesisRenderCompletion()
        let rendered: SendableAudioBuffer = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SendableAudioBuffer, Error>) in
                completion.install(continuation)
                Task { @MainActor in
                    // A render timeout can fire before this MainActor task is
                    // scheduled. Do not start a synthesizer for work that is
                    // already cancelled.
                    guard !completion.isResolved else { return }
                    let utterance = AVSpeechUtterance(string: text)
                    utterance.voice = resolvedVoice
                    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                    utterance.pitchMultiplier = 1.0
                    utterance.volume = 1.0

                    let session = SpeechRenderSession()
                    guard completion.installCancellationAction({
                        Task { @MainActor in
                            session.cancel()
                        }
                    }) else { return }

                    // The session is retained by `completion`, which releases
                    // every capture the moment it resolves. Keeping it alive
                    // through the collector instead would close a reference
                    // cycle (synthesizer -> write callback -> collector ->
                    // completion closure -> session -> synthesizer) that
                    // leaked one AVSpeechSynthesizer, and every buffer it had
                    // rendered, for the lifetime of the process.
                    completion.retainUntilResolved { Task { @MainActor in _ = session } }
                    let collector = SynthesisCollector(targetFormat: format) { result in
                        completion.resolve(result.map(SendableAudioBuffer.init))
                    }
                    session.synthesizer.write(utterance) { buffer in
                        collector.append(buffer)
                    }
                    // The completion of `write` is signalled by an empty buffer.
                }
            }
        } onCancel: {
            // `AVSpeechSynthesizer.write` can occasionally fail to deliver its
            // terminal empty buffer. Resuming here makes an upstream timeout
            // release the serial announcement queue instead of waiting forever.
            completion.cancel()
        }
        return rendered.buffer
    }
}

/// Thread-safe, one-shot bridge between an `AVSpeechSynthesizer.write` callback
/// and Swift concurrency. It also lets cancellation finish a render whose
/// synthesizer callback never arrives.
private final class SynthesisRenderCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SendableAudioBuffer, Error>?
    private var result: Result<SendableAudioBuffer, Error>?
    private var cancellationAction: (() -> Void)?
    private var sessionRelease: (() -> Void)?

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    func install(_ continuation: CheckedContinuation<SendableAudioBuffer, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Returns false if the render was already cancelled or completed before
    /// the synthesizer could be created.
    func installCancellationAction(_ action: @escaping () -> Void) -> Bool {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            action()
            return false
        }
        cancellationAction = action
        lock.unlock()
        return true
    }

    /// Holds the render's synthesizer alive until this completion resolves,
    /// then drops it. `release` is expected to hop to the main actor rather
    /// than free the synthesizer inline: the resolve usually happens inside
    /// the synthesizer's own buffer callback, which is no place to release
    /// its last reference.
    func retainUntilResolved(_ release: @escaping () -> Void) {
        lock.lock()
        let alreadyResolved = result != nil
        if !alreadyResolved { sessionRelease = release }
        lock.unlock()
        if alreadyResolved { release() }
    }

    func resolve(_ result: Result<SendableAudioBuffer, Error>) {
        finish(with: result, runCancellationAction: false)
    }

    func cancel() {
        finish(with: .failure(CancellationError()), runCancellationAction: true)
    }

    private func finish(
        with result: Result<SendableAudioBuffer, Error>,
        runCancellationAction: Bool
    ) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let cancellationAction = runCancellationAction ? self.cancellationAction : nil
        self.cancellationAction = nil
        let sessionRelease = self.sessionRelease
        self.sessionRelease = nil
        lock.unlock()

        cancellationAction?()
        continuation?.resume(with: result)
        sessionRelease?()
    }
}

@MainActor
private final class SpeechRenderSession {
    let synthesizer = AVSpeechSynthesizer()

    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// Accumulates partial PCM buffers from `AVSpeechSynthesizer.write` and
/// resamples them to the target format on completion.
final class SynthesisCollector {
    private static let logger = Logger(subsystem: "com.swiftbot", category: "voice.tts")

    private let targetFormat: AVAudioFormat
    /// Cleared once it has run. `AVSpeechSynthesizer` holds its buffer
    /// callback — and therefore this collector — so anything left in here
    /// outlives the render.
    private var completion: ((Result<AVAudioPCMBuffer, Error>) -> Void)?
    private var sourceFormat: AVAudioFormat?
    private var collected: [AVAudioPCMBuffer] = []
    /// Set when a chunk could not be reconciled with the established source
    /// format. The render fails loudly instead of returning mangled audio.
    private var failure: Error?
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
        if sourceFormat == nil {
            sourceFormat = pcm.format
            Self.logger.info("Synthesizer output format: \(pcm.format, privacy: .public)")
        }
        guard let sourceFormat else { return }
        if pcm.format == sourceFormat {
            collected.append(pcm)
            return
        }
        // A synthesizer that changes format mid-utterance used to be merged as
        // though it had not: the merge kept the first chunk's format, so the
        // whole render was resampled at the wrong ratio and came out stretched
        // and distorted. Reconcile the chunk instead, and say so.
        Self.logger.error("Synthesizer changed output format mid-render: \(sourceFormat, privacy: .public) -> \(pcm.format, privacy: .public); converting the chunk to keep the merge coherent.")
        do {
            collected.append(try convert(pcm, to: sourceFormat))
        } catch {
            failure = error
            finishLocked()
        }
    }

    private func finishLocked() {
        finished = true
        let completion = self.completion
        self.completion = nil
        defer {
            self.collected.removeAll()
            self.sourceFormat = nil
        }
        guard let completion else { return }
        if let failure {
            completion(.failure(failure))
            return
        }
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
            guard copyFrames(chunk, into: merged, atOffset: offset) else {
                Self.logger.error("Refusing to merge a synthesized chunk that does not fit the render buffer.")
                completion(.failure(VoicePipelineError.audioFormatUnsupported))
                return
            }
            offset += chunk.frameLength
        }

        do {
            let converted = try convert(merged, to: targetFormat)
            completion(.success(converted))
        } catch {
            completion(.failure(error))
        }
    }

    /// Appends one synthesized chunk into the merge buffer. Returns false if the
    /// chunk cannot be placed safely; the copies below index by the destination's
    /// own layout, so anything but an exact format match — or a chunk that runs
    /// past the allocation — would write out of bounds.
    private func copyFrames(
        _ source: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer,
        atOffset offset: AVAudioFrameCount
    ) -> Bool {
        guard source.format == destination.format,
              offset + source.frameLength <= destination.frameCapacity else {
            return false
        }
        let frames = Int(source.frameLength)
        let channels = Int(source.format.channelCount)
        if let srcF = source.floatChannelData, let dstF = destination.floatChannelData {
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
        } else if let srcI = source.int16ChannelData, let dstI = destination.int16ChannelData {
            // An Int16 synthesizer previously matched no branch here at all, so
            // its render merged as silence.
            if source.format.isInterleaved {
                let s = srcI[0]
                let d = dstI[0]
                let off = Int(offset) * channels
                for i in 0..<(frames * channels) { d[off + i] = s[i] }
            } else {
                for c in 0..<channels {
                    let s = srcI[c]
                    let d = dstI[c]
                    for i in 0..<frames { d[Int(offset) + i] = s[i] }
                }
            }
        } else {
            return false
        }
        return true
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
