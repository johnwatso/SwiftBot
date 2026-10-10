import AVFoundation
import Foundation
import UniformTypeIdentifiers
import os
import CryptoKit
import VideoToolbox

/// Packages recordings into Apple HLS fMP4 segments. Streaming renditions use
/// AVAssetReader and VideoToolbox hardware H.264/AAC encoding, with source-time
/// reads and rebased timestamps for on-demand seeks. The legacy packaging API
/// can pass compatible compressed tracks through without re-encoding.
///
/// Caches include source revision, quality and starting offset. Concurrent
/// requests share an encode; at most two encoders run on a recording's Mac.
public actor HLSPackager {
    public enum PackagingError: Error {
        case invalidStartTime
        case noVideoTrack
        case readerSetupFailed
        case writerSetupFailed
        case readerFailed(Error?)
        case writerFailed(Error?)
    }

    public static let playlistFileName = "playlist.m3u8"
    public static let initSegmentFileName = "init.mp4"

    private let cacheRoot: URL
    private let logger = Logger(subsystem: "com.swiftbot.media", category: "hls")
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private let targetSegmentSeconds: Double
    private var streamingJobs: [String: Task<Void, Never>] = [:]
    private var streamingItems: [String: String] = [:]
    private var streamingAccess: [String: Date] = [:]
    private var failedStreams: [String: Date] = [:]

    public init(cacheRoot: URL, targetSegmentSeconds: Double = 6) {
        self.cacheRoot = cacheRoot
        self.targetSegmentSeconds = targetSegmentSeconds
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    /// Returns the URL of the cached HLS playlist for `sourceURL`, generating
    /// the init + media segments on first request. Concurrent callers for the
    /// same item share one packaging task. Returns `nil` on failure.
    public func playlistURL(itemID: String, sourceURL: URL) async -> URL? {
        guard let dir = cacheDirectory(itemID: itemID, sourceURL: sourceURL) else { return nil }
        let playlist = dir.appendingPathComponent(Self.playlistFileName)
        if FileManager.default.fileExists(atPath: playlist.path) {
            try? Data().write(to: dir.appendingPathComponent(".access"))
            return playlist
        }

        let key = dir.lastPathComponent
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<URL?, Never> { [dir, playlist, sourceURL, targetSegmentSeconds, logger] in
            let started = Date()
            do {
                try await Self.package(sourceURL: sourceURL, into: dir, segmentSeconds: targetSegmentSeconds)
                let elapsed = Date().timeIntervalSince(started)
                logger.debug("packaged \(sourceURL.lastPathComponent, privacy: .public) -> HLS in \(String(format: "%.1fs", elapsed), privacy: .public)")
                return playlist
            } catch {
                logger.error("hls packaging failed for \(sourceURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                try? FileManager.default.removeItem(at: dir)
                return nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        trimCache(protecting: Set(inFlight.keys).union(streamingJobs.keys).union([key]))
        return result
    }

    /// Starts hardware encoding directly into HLS, without first exporting a
    /// complete MP4. At most two renditions encode concurrently on this Mac.
    /// Partial caches left by an interrupted process are discarded on restart.
    public func prepareStream(itemID: String, sourceURL: URL, quality: MediaTranscodeCache.Quality, startSeconds: Int = 0) {
        guard startSeconds >= 0, startSeconds <= 604_800, let dir = streamDirectory(itemID: itemID, sourceURL: sourceURL, quality: quality, startSeconds: startSeconds) else { return }
        let key = dir.lastPathComponent
        failedStreams = failedStreams.filter { Date().timeIntervalSince($0.value) < 60 }
        touch(dir)
        // A seek takes priority over this recording's least recently requested
        // encode. Published chunks remain playable; its viewers can continue at
        // their current timestamp rather than losing their already buffered video.
        if startSeconds > 0, streamingJobs[key] == nil, streamingJobs.count >= 2,
           failedStreams[key] == nil,
           !streamingJobs.values.contains(where: { $0.isCancelled }),
           !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".complete").path),
           let victim = streamingJobs.keys.filter({ streamingItems[$0] == itemID && streamingJobs[$0]?.isCancelled == false })
            .min(by: { (streamingAccess[$0] ?? .distantPast) < (streamingAccess[$1] ?? .distantPast) }) {
            streamingJobs[victim]?.cancel()
        }
        guard streamingJobs[key] == nil,
              !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".complete").path),
              streamingJobs.count < 2,
              failedStreams[key].map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        touch(dir)
        streamingItems[key] = itemID
        streamingAccess[key] = Date()
        streamingJobs[key] = Task { [sourceURL, quality, dir, targetSegmentSeconds, startSeconds] in
            do {
                try await Self.package(sourceURL: sourceURL, into: dir, segmentSeconds: targetSegmentSeconds, quality: quality, startSeconds: startSeconds)
                try Data().write(to: dir.appendingPathComponent(".complete"), options: .atomic)
            } catch {
                if !Task.isCancelled { logger.error("stream encode failed: \(String(describing: error), privacy: .public)") }
                if Task.isCancelled, let raw = try? String(contentsOf: dir.appendingPathComponent(Self.playlistFileName), encoding: .utf8),
                   raw.contains("seg0.m4s"), raw.contains("#EXT-X-ENDLIST") {
                    // The collector froze only complete published fragments.
                    try? Data().write(to: dir.appendingPathComponent(".complete"), options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: dir)
                    if !Task.isCancelled { failedStreams[key] = Date() }
                }
            }
            streamingJobs[key] = nil
            streamingItems[key] = nil
            streamingAccess[key] = nil
            trimCache(protecting: Set(inFlight.keys).union(streamingJobs.keys))
        }
    }

    /// Returns once the first playable segment is published, not at the end
    /// of the recording. The HTTP caller can retry a busy encoder later.
    public func streamingPlaylistURL(itemID: String, sourceURL: URL, quality: MediaTranscodeCache.Quality, startSeconds: Int = 0) async -> URL? {
        prepareStream(itemID: itemID, sourceURL: sourceURL, quality: quality, startSeconds: startSeconds)
        guard startSeconds >= 0, startSeconds <= 604_800, let dir = streamDirectory(itemID: itemID, sourceURL: sourceURL, quality: quality, startSeconds: startSeconds) else { return nil }
        let playlist = dir.appendingPathComponent(Self.playlistFileName)
        for _ in 0..<80 {
            guard !Task.isCancelled, failedStreams[dir.lastPathComponent] == nil else { return nil }
            touch(dir)
            if (streamingJobs[dir.lastPathComponent] != nil || FileManager.default.fileExists(atPath: dir.appendingPathComponent(".complete").path)),
               FileManager.default.fileExists(atPath: playlist.path) { return playlist }
            if streamingJobs[dir.lastPathComponent] == nil {
                prepareStream(itemID: itemID, sourceURL: sourceURL, quality: quality, startSeconds: startSeconds)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    public func streamingFailed(itemID: String, sourceURL: URL, quality: MediaTranscodeCache.Quality, startSeconds: Int = 0) -> Bool {
        guard startSeconds >= 0, startSeconds <= 604_800, let dir = streamDirectory(itemID: itemID, sourceURL: sourceURL, quality: quality, startSeconds: startSeconds),
              let failed = failedStreams[dir.lastPathComponent] else { return false }
        return Date().timeIntervalSince(failed) < 60
    }

    public func streamingSegmentURL(itemID: String, sourceURL: URL, quality: MediaTranscodeCache.Quality, segment: String, startSeconds: Int = 0) -> URL? {
        guard Self.isSegmentName(segment),
              let dir = streamDirectory(itemID: itemID, sourceURL: sourceURL, quality: quality, startSeconds: startSeconds),
              streamingJobs[dir.lastPathComponent] != nil || FileManager.default.fileExists(atPath: dir.appendingPathComponent(".complete").path)
        else { return nil }
        touch(dir)
        let url = dir.appendingPathComponent(segment)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public nonisolated static func isSegmentName(_ name: String) -> Bool {
        name == initSegmentFileName || name.range(of: #"^seg[0-9]+\.m4s$"#, options: .regularExpression) != nil
    }

    public func streamingIdentity(itemID: String, sourceURL: URL, quality: MediaTranscodeCache.Quality, startSeconds: Int = 0) -> String? {
        streamDirectory(itemID: itemID, sourceURL: sourceURL, quality: quality, startSeconds: startSeconds)?.lastPathComponent
    }

    private func streamDirectory(itemID: String, sourceURL: URL, quality: MediaTranscodeCache.Quality, startSeconds: Int = 0) -> URL? {
        guard (0...604_800).contains(startSeconds), let values = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let modified = values[.modificationDate] as? Date,
              let size = values[.size] as? NSNumber else { return nil }
        let identity = "\(itemID)|\(sourceURL.path)|\(modified.timeIntervalSince1970)|\(size.int64Value)|\(quality.rawValue)|stream_v2|\(startSeconds)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheRoot.appendingPathComponent(key, isDirectory: true)
    }

    private func touch(_ directory: URL) {
        if streamingJobs[directory.lastPathComponent] != nil { streamingAccess[directory.lastPathComponent] = Date() }
        try? Data().write(to: directory.appendingPathComponent(".access"))
    }

    /// File URL of a previously-generated segment (the init segment or a media
    /// segment) for `itemID`. Validated against path traversal; `nil` if the
    /// segment doesn't exist in the cache for the current source mtime.
    public func segmentURL(itemID: String, sourceURL: URL, segment: String) -> URL? {
        // Reject anything that isn't a bare file name living directly in the
        // cache directory (no separators, no parent-directory escapes).
        guard !segment.isEmpty,
              !segment.contains("/"),
              !segment.contains("\\"),
              segment != ".",
              segment != ".." else {
            return nil
        }
        guard let dir = cacheDirectory(itemID: itemID, sourceURL: sourceURL) else { return nil }
        let candidate = dir.appendingPathComponent(segment)
        guard candidate.deletingLastPathComponent().path == dir.path,
              FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        try? Data().write(to: dir.appendingPathComponent(".access"))
        return candidate
    }

    private func cacheDirectory(itemID: String, sourceURL: URL) -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let mtime = attributes[.modificationDate] as? Date else {
            return nil
        }
        return cacheRoot.appendingPathComponent(cacheKey(itemID: itemID, mtime: mtime), isDirectory: true)
    }

    private nonisolated func cacheKey(itemID: String, mtime: Date) -> String {
        let identity = "\(itemID)|\(mtime.timeIntervalSince1970)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Bound old cache entries while retaining recent playback sessions.
    private func trimCache(protecting keys: Set<String>) {
        let directories = (try? FileManager.default.contentsOfDirectory(at: cacheRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
        var entries: [(URL, Int64, Date)] = []
        for directory in directories {
            guard let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let size = files.reduce(Int64(0)) { total, file in
                total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let access = try? directory.appendingPathComponent(".access").resourceValues(forKeys: [.contentModificationDateKey])
            entries.append((directory, size, access?.contentModificationDate ?? values.contentModificationDate ?? .distantPast))
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        for (url, size, date) in entries.sorted(by: { $0.2 < $1.2 }) where total > 10 * 1024 * 1024 * 1024 {
            guard !keys.contains(url.lastPathComponent), date < Date().addingTimeInterval(-3600) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }

    // MARK: - Packaging

    private static func package(sourceURL: URL, into dir: URL, segmentSeconds: Double, quality: MediaTranscodeCache.Quality? = nil, startSeconds: Int = 0) async throws {
        if quality == nil { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if quality != nil { try Data().write(to: dir.appendingPathComponent(".access")) }

        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw PackagingError.noVideoTrack }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = audioTracks.first

        let videoFormat = try await videoTrack.load(.formatDescriptions).first
        let audioFormat = try await audioTrack?.load(.formatDescriptions).first ?? nil

        // Decode for streaming, or retain compressed samples for legacy remuxing.
        let duration = try await asset.load(.duration)
        let startTime = CMTime(seconds: Double(startSeconds), preferredTimescale: 600)
        guard startSeconds >= 0, startTime < duration else { throw PackagingError.invalidStartTime }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: startTime, duration: duration - startTime)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: quality == nil ? nil : [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw PackagingError.readerSetupFailed }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: quality == nil ? nil : [AVFormatIDKey: kAudioFormatLinearPCM])
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { throw PackagingError.readerSetupFailed }
            reader.add(out)
            audioOutput = out
        }

        // Writer: segmented fMP4 output conforming to the Apple HLS profile.
        // No output file URL — segments are delivered to the delegate.
        let collector = HLSSegmentCollector(directory: dir, segmentSeconds: segmentSeconds, progressive: quality != nil)
        let writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentSeconds, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero
        writer.delegate = collector

        var videoSettings: [String: Any]?
        if let quality {
            let size = try await videoTrack.load(.naturalSize)
            let scale = min(1, (quality == .low ? 1280.0 : 1920.0) / max(size.width, size.height))
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: max(2, Int(size.width * scale) / 2 * 2),
                AVVideoHeightKey: max(2, Int(size.height * scale) / 2 * 2),
                AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: quality == .low ? 3_000_000 : 8_000_000,
                    AVVideoMaxKeyFrameIntervalDurationKey: segmentSeconds,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: quality == nil ? videoFormat : nil)
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw PackagingError.writerSetupFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let audioSettings: [String: Any]? = quality == nil ? nil : [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: quality == nil ? audioFormat : nil)
            aIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(aIn) else { throw PackagingError.writerSetupFailed }
            writer.add(aIn)
            audioInput = aIn
        }

        guard reader.startReading() else { throw PackagingError.readerFailed(reader.error) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw PackagingError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let idleReader = QueueConfined(value: reader)
        let idleWriter = QueueConfined(value: writer)
        let idleMonitor = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard quality != nil else { continue }
                let access = try? dir.appendingPathComponent(".access").resourceValues(forKeys: [.contentModificationDateKey])
                if Date().timeIntervalSince(access?.contentModificationDate ?? .distantPast) > 90 {
                    idleReader.value.cancelReading()
                    idleWriter.value.cancelWriting()
                    return
                }
            }
        }
        defer { idleMonitor.cancel() }

        // Pump video and audio concurrently; each input drains its reader output
        // on its own serial queue and marks itself finished at end-of-stream.
        // Both tracks must be appended before finishWriting so the segmenter can
        // interleave them on time boundaries.
        await withTaskCancellationHandler {
            await Self.pumpSamples(
                video: (videoOutput, videoInput),
                audio: (audioOutput != nil && audioInput != nil) ? (audioOutput!, audioInput!) : nil,
                reader: reader, writer: writer, sourceStart: startTime
            )
        } onCancel: {
            // Let both writer-input callbacks register and drain before cancelling
            // the writer; cancelling it here races requestMediaDataWhenReady.
            idleReader.value.cancelReading()
        }
        if Task.isCancelled {
            writer.cancelWriting()
            try? collector.finish()
            throw CancellationError()
        }

        if reader.status != .completed {
            writer.cancelWriting()
            throw PackagingError.readerFailed(reader.error)
        }

        guard writer.status == .writing else {
            reader.cancelReading()
            throw PackagingError.writerFailed(writer.error)
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw PackagingError.writerFailed(writer.error)
        }

        try collector.finish()
    }

    /// Drains the video (and optional audio) reader outputs into their writer
    /// inputs, copying compressed sample buffers. Each input runs on its own
    /// serial queue; a `DispatchGroup` waits for both to reach end-of-stream
    /// before resuming. The AVFoundation objects never cross a task boundary,
    /// so this stays clear of Swift 6 `sending` diagnostics.
    static func pumpSamples(
        video: (AVAssetReaderTrackOutput, AVAssetWriterInput),
        audio: (AVAssetReaderTrackOutput, AVAssetWriterInput)?,
        reader: AVAssetReader, writer: AVAssetWriter, sourceStart: CMTime = .zero
    ) async {
        let resumer = ContinuationResumer()
        let group = DispatchGroup()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            resumer.set(continuation)

            func drain(_ output: AVAssetReaderTrackOutput, into input: AVAssetWriterInput, label: String) {
                group.enter()
                let queue = DispatchQueue(label: label)
                let finished = Once()
                // AVFoundation invokes this callback only on `queue`. Wrap the
                // queue-confined references so Swift's @Sendable checking does
                // not mistake the callback handoff for concurrent access.
                let sendableOutput = QueueConfined(value: output)
                let sendableInput = QueueConfined(value: input)
                // A failed reader/writer can stop readiness callbacks entirely.
                // Observe failure on the same queue so every group entry is balanced.
                let sessionReader = QueueConfined(value: reader)
                let sessionWriter = QueueConfined(value: writer)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
                timer.setEventHandler {
                    if [.failed, .cancelled].contains(sessionReader.value.status) || [.failed, .cancelled].contains(sessionWriter.value.status) {
                        if finished.run() {
                            if sessionWriter.value.status == .writing { sendableInput.value.markAsFinished() }
                            group.leave()
                        }
                        timer.cancel()
                    }
                }
                timer.resume()
                input.requestMediaDataWhenReady(on: queue) {
                    while sendableInput.value.isReadyForMoreMediaData {
                        if let sample = sendableOutput.value.copyNextSampleBuffer() {
                            // Segmented writers preserve sample timestamps. Rebase
                            // both tracks together so every seek stream starts at 0.
                            if CMSampleBufferGetPresentationTimeStamp(sample) < sourceStart { continue }
                            guard let rebased = Self.rebasedSample(sample, subtracting: sourceStart),
                                  sendableInput.value.append(rebased) else {
                                if finished.run() { timer.cancel(); if sessionWriter.value.status == .writing { sendableInput.value.markAsFinished() }; group.leave() }
                                return
                            }
                        } else {
                            if finished.run() { timer.cancel(); if sessionWriter.value.status == .writing { sendableInput.value.markAsFinished() }; group.leave() }
                            return
                        }
                    }
                }
            }

            drain(video.0, into: video.1, label: "com.swiftbot.media.hls.video")
            if let audio {
                drain(audio.0, into: audio.1, label: "com.swiftbot.media.hls.audio")
            }

            group.notify(queue: DispatchQueue(label: "com.swiftbot.media.hls.done")) {
                resumer.resume()
            }
        }
    }

    private nonisolated static func rebasedSample(_ sample: CMSampleBuffer, subtracting start: CMTime) -> CMSampleBuffer? {
        guard start != .zero else { return sample }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil) == noErr else { return nil }
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - start
            if timing[index].decodeTimeStamp.isNumeric { timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - start }
        }
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &output) == noErr else { return nil }
        return output
    }

}

/// A reference that is deliberately confined to one dispatch queue. This is
/// used only to bridge AVFoundation callback APIs whose imported types do not
/// yet conform to `Sendable`.
private struct QueueConfined<Value>: @unchecked Sendable {
    let value: Value
}

/// Runs its first invocation exactly once; later calls are no-ops. Used to
/// balance a `DispatchGroup` enter/leave from a callback that may re-fire.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func run() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Resume-once guard for a `CheckedContinuation` captured by an AVFoundation
/// callback that may fire repeatedly.
private final class ContinuationResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

/// Receives fMP4 segments from `AVAssetWriter` and writes them to disk, then
/// emits the VOD playlist. Callbacks are serialized by AVFoundation but we lock
/// defensively so the collected state is safe to read after `finishWriting`.
private final class HLSSegmentCollector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private struct Segment {
        let fileName: String
        let durationSeconds: Double
    }

    private let directory: URL
    private let lock = NSLock()
    private var segments: [Segment] = []
    private var mediaSegmentIndex = 0
    private let segmentSeconds: Double
    private let progressive: Bool
    private var writeError: Error?
    private var bytesWritten = 0

    init(directory: URL, segmentSeconds: Double, progressive: Bool) {
        self.directory = directory
        self.segmentSeconds = segmentSeconds
        self.progressive = progressive
    }

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard writeError == nil, writer.status != .cancelled else { return }
        do {
            bytesWritten += segmentData.count
            guard bytesWritten <= 5 * 1024 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
            switch segmentType {
            case .initialization:
                try segmentData.write(to: directory.appendingPathComponent(HLSPackager.initSegmentFileName), options: .atomic)
            case .separable:
                let fileName = "seg\(mediaSegmentIndex).m4s"
                try segmentData.write(to: directory.appendingPathComponent(fileName), options: .atomic)
                mediaSegmentIndex += 1
                let duration = segmentReport?.trackReports.map { CMTimeGetSeconds($0.duration) }.max() ?? segmentSeconds
                segments.append(Segment(fileName: fileName, durationSeconds: duration))
                if progressive { try writePlaylist(complete: false) }
            @unknown default: break
            }
        } catch {
            writeError = error
            let failedWriter = QueueConfined(value: writer)
            DispatchQueue.global(qos: .utility).async { failedWriter.value.cancelWriting() }
        }
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        if let writeError { throw writeError }
        guard !segments.isEmpty else { throw HLSPackager.PackagingError.writerSetupFailed }
        try writePlaylist(complete: true)
    }

    /// Writes `playlist.m3u8` (HLS v7, VOD) referencing the init + media
    /// segments by bare file name. The HTTP layer rewrites those names into
    /// authorized segment URLs when serving.
    private func writePlaylist(complete: Bool) throws {

        let targetDuration = progressive ? max(1, Int(segmentSeconds.rounded(.up)) + 1)
            : max(1, Int(segments.map(\.durationSeconds).max()?.rounded(.up) ?? segmentSeconds.rounded(.up)))
        guard segments.allSatisfy({ $0.durationSeconds <= Double(targetDuration) + 0.5 }) else { throw HLSPackager.PackagingError.writerSetupFailed }
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            progressive ? "#EXT-X-PLAYLIST-TYPE:EVENT" : "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MAP:URI=\"\(HLSPackager.initSegmentFileName)\""
        ]
        for segment in segments {
            let duration = segment.durationSeconds > 0 ? segment.durationSeconds : segmentSeconds
            lines.append(String(format: "#EXTINF:%.6f,", duration))
            lines.append(segment.fileName)
        }
        if complete { lines.append("#EXT-X-ENDLIST") }

        let body = lines.joined(separator: "\n") + "\n"
        try body.data(using: .utf8)?.write(to: directory.appendingPathComponent(HLSPackager.playlistFileName), options: .atomic)
    }
}
