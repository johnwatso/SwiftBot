import AVFoundation
import Foundation
import UniformTypeIdentifiers
import os

/// Repackages a recording into HLS (HTTP Live Streaming) — a fragmented-MP4
/// (CMAF) initialization segment plus media segments and a VOD `.m3u8`
/// playlist — so the browser can start playback immediately and seek cleanly,
/// regardless of where the source MP4 places its `moov` atom.
///
/// For H.264/HEVC + AAC sources (the OBS/game-capture norm) the audio and
/// video are passed through without re-encoding, so packaging is fast and
/// lossless. Output lives in `~/Library/Caches/SwiftBot/MediaHLS/<key>/` keyed
/// by item id and source mtime — if the source recording is replaced, the next
/// request regenerates the segments.
///
/// Concurrent requests for the same item share a single in-flight packaging
/// task instead of kicking off duplicates, mirroring `MediaTranscodeCache`.
public actor HLSPackager {
    public enum PackagingError: Error {
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
        return result
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
        let mtimeStamp = Int(mtime.timeIntervalSince1970)
        let safeID = itemID.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "|", with: "_")
        return "\(safeID)_\(mtimeStamp)"
    }

    // MARK: - Packaging

    private static func package(sourceURL: URL, into dir: URL, segmentSeconds: Double) async throws {
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw PackagingError.noVideoTrack }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = audioTracks.first

        let videoFormat = try await videoTrack.load(.formatDescriptions).first
        let audioFormat = try await audioTrack?.load(.formatDescriptions).first ?? nil

        // Reader: passthrough (compressed) sample buffers from the source.
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw PackagingError.readerSetupFailed }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
            }
        }

        // Writer: segmented fMP4 output conforming to the Apple HLS profile.
        // No output file URL — segments are delivered to the delegate.
        let collector = HLSSegmentCollector(directory: dir)
        let writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = collector

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw PackagingError.writerSetupFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) {
                writer.add(aIn)
                audioInput = aIn
            }
        }

        guard reader.startReading() else { throw PackagingError.readerFailed(reader.error) }
        guard writer.startWriting() else { throw PackagingError.writerFailed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        // Pump video and audio concurrently; each input drains its reader output
        // on its own serial queue and marks itself finished at end-of-stream.
        // Both tracks must be appended before finishWriting so the segmenter can
        // interleave them on time boundaries.
        await Self.pumpSamples(
            video: (videoOutput, videoInput),
            audio: (audioOutput != nil && audioInput != nil) ? (audioOutput!, audioInput!) : nil
        )

        if reader.status == .failed {
            throw PackagingError.readerFailed(reader.error)
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw PackagingError.writerFailed(writer.error)
        }

        try collector.writePlaylist(segmentSeconds: segmentSeconds)
    }

    /// Drains the video (and optional audio) reader outputs into their writer
    /// inputs, copying compressed sample buffers. Each input runs on its own
    /// serial queue; a `DispatchGroup` waits for both to reach end-of-stream
    /// before resuming. The AVFoundation objects never cross a task boundary,
    /// so this stays clear of Swift 6 `sending` diagnostics.
    private static func pumpSamples(
        video: (AVAssetReaderTrackOutput, AVAssetWriterInput),
        audio: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
    ) async {
        let resumer = ContinuationResumer()
        let group = DispatchGroup()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            resumer.set(continuation)

            func drain(_ output: AVAssetReaderTrackOutput, into input: AVAssetWriterInput, label: String) {
                group.enter()
                let queue = DispatchQueue(label: label)
                let finished = Once()
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        if let sample = output.copyNextSampleBuffer() {
                            if !input.append(sample) {
                                if finished.run() { input.markAsFinished(); group.leave() }
                                return
                            }
                        } else {
                            if finished.run() { input.markAsFinished(); group.leave() }
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

    init(directory: URL) {
        self.directory = directory
    }

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        lock.lock()
        defer { lock.unlock() }

        switch segmentType {
        case .initialization:
            try? segmentData.write(to: directory.appendingPathComponent(HLSPackager.initSegmentFileName), options: .atomic)
        case .separable:
            let fileName = "seg\(mediaSegmentIndex).m4s"
            mediaSegmentIndex += 1
            try? segmentData.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            let duration = segmentReport?.trackReports
                .map { CMTimeGetSeconds($0.duration) }
                .max() ?? 0
            segments.append(Segment(fileName: fileName, durationSeconds: duration))
        @unknown default:
            break
        }
    }

    /// Writes `playlist.m3u8` (HLS v7, VOD) referencing the init + media
    /// segments by bare file name. The HTTP layer rewrites those names into
    /// authorized segment URLs when serving.
    func writePlaylist(segmentSeconds: Double) throws {
        lock.lock()
        let segments = self.segments
        lock.unlock()

        let targetDuration = max(1, Int(segments.map(\.durationSeconds).max()?.rounded(.up) ?? segmentSeconds.rounded(.up)))
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MAP:URI=\"\(HLSPackager.initSegmentFileName)\""
        ]
        for segment in segments {
            let duration = segment.durationSeconds > 0 ? segment.durationSeconds : segmentSeconds
            lines.append(String(format: "#EXTINF:%.6f,", duration))
            lines.append(segment.fileName)
        }
        lines.append("#EXT-X-ENDLIST")

        let body = lines.joined(separator: "\n") + "\n"
        try body.data(using: .utf8)?.write(to: directory.appendingPathComponent(HLSPackager.playlistFileName), options: .atomic)
    }
}
