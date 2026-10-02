import Foundation
import AVFoundation
import os
import VideoToolbox
import CryptoKit

/// Lower-quality (and lower-bandwidth) variants of recordings, generated on
/// demand via AVFoundation with a required VideoToolbox hardware encoder.
///
/// Used by adaptive HLS and `/api/media/stream?quality=standard|low`.
/// Both profiles preserve source frame cadence and avoid upscaling.
/// Transcoded files live in `~/Library/Caches/SwiftBot/MediaTranscodes/` and
/// are keyed by item id, quality, and source mtime — if the source recording
/// is replaced, the next request regenerates the cached variant.
///
/// Concurrent requests for the same item share a single in-flight transcode
/// task instead of kicking off duplicates.
public actor MediaTranscodeCache {
    public enum Quality: String, Sendable {
        case low
        case standard
    }

    private let cacheRoot: URL
    private let logger = Logger(subsystem: "com.swiftbot.media", category: "transcode")
    private var encodeTail: Task<URL?, Never>?
    private var preparation: Task<Void, Never>?
    private var inFlight: [String: Task<URL?, Never>] = [:]

    public init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    /// Returns the file URL of a cached hardware-encoded variant of `sourceURL`,
    /// generating it if needed. Returns `nil` if the source can't be opened
    /// or the export fails.
    public func variantURL(itemID: String, sourceURL: URL, quality: Quality) async -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let mtime = attributes[.modificationDate] as? Date else {
            return nil
        }
        let key = cacheKey(itemID: itemID, quality: quality, mtime: mtime)
        let cachedURL = cacheRoot.appendingPathComponent(key + ".mp4")

        if FileManager.default.fileExists(atPath: cachedURL.path) {
            try? Data().write(to: cachedURL.appendingPathExtension("access"))
            return cachedURL
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let previous = encodeTail
        let task = Task<URL?, Never> { [cachedURL, sourceURL, quality, logger] in
            _ = await previous?.value
            let started = Date()
            do {
                let temporaryURL = cachedURL.deletingPathExtension().appendingPathExtension("partial.mp4")
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                try? FileManager.default.removeItem(at: temporaryURL)
                try await Self.transcode(sourceURL: sourceURL, outputURL: temporaryURL, quality: quality)
                try FileManager.default.moveItem(at: temporaryURL, to: cachedURL)
                let elapsed = Date().timeIntervalSince(started)
                logger.debug("transcoded \(sourceURL.lastPathComponent, privacy: .public) -> \(cachedURL.lastPathComponent, privacy: .public) in \(String(format: "%.1fs", elapsed), privacy: .public)")
                return cachedURL
            } catch {
                logger.error("transcode error for \(sourceURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                try? FileManager.default.removeItem(at: cachedURL)
                return nil
            }
        }
        encodeTail = task
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        trimCache(protecting: Set(inFlight.keys).union([key]))
        return result
    }

    private nonisolated func cacheKey(itemID: String, quality: Quality, mtime: Date) -> String {
        let identity = "\(itemID)|\(quality.rawValue)|\(mtime.timeIntervalSince1970)|hardware_v1"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The prepared copy if it's already on disk; never starts an encode.
    public func cachedVariantURL(itemID: String, sourceURL: URL, quality: Quality) -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let mtime = attributes[.modificationDate] as? Date else { return nil }
        let url = cacheRoot.appendingPathComponent(cacheKey(itemID: itemID, quality: quality, mtime: mtime) + ".mp4")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? Data().write(to: url.appendingPathExtension("access"))
        return url
    }

    /// Whether a copy is being encoded right now.
    public func isPreparing(itemID: String, sourceURL: URL, quality: Quality) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let mtime = attributes[.modificationDate] as? Date else { return false }
        return inFlight[cacheKey(itemID: itemID, quality: quality, mtime: mtime)] != nil
    }

    /// Starts making a copy in the background (queued behind any other
    /// encode) and returns straight away.
    public func prepareInBackground(itemID: String, sourceURL: URL, quality: Quality) {
        guard cachedVariantURL(itemID: itemID, sourceURL: sourceURL, quality: quality) == nil,
              !isPreparing(itemID: itemID, sourceURL: sourceURL, quality: quality) else { return }
        Task { _ = await self.variantURL(itemID: itemID, sourceURL: sourceURL, quality: quality) }
    }

    /// Prepare the newest recording without delaying the library response.
    /// One preparation task and one hardware encode may run at a time.
    public func prepareNewest(itemID: String, sourceURL: URL) {
        guard preparation == nil else { return }
        preparation = Task {
            _ = await variantURL(itemID: itemID, sourceURL: sourceURL, quality: .low)
            _ = await variantURL(itemID: itemID, sourceURL: sourceURL, quality: .standard)
            preparation = nil
        }
    }

    private func trimCache(protecting keys: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheRoot,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.filter { $0.pathExtension == "mp4" && !$0.lastPathComponent.contains("partial") }
            .compactMap { url -> (URL, Int, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                let access = try? url.appendingPathExtension("access").resourceValues(forKeys: [.contentModificationDateKey])
                return (url, values.fileSize ?? 0, access?.contentModificationDate ?? values.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(Int64(0)) { $0 + Int64($1.1) }
        for (url, size, date) in entries where total > 10 * 1024 * 1024 * 1024 {
            guard !keys.contains(url.deletingPathExtension().lastPathComponent), date < Date().addingTimeInterval(-3600) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                try? FileManager.default.removeItem(at: url.appendingPathExtension("access"))
                total -= Int64(size)
            }
        }
    }

    private static func transcode(sourceURL: URL, outputURL: URL, quality: Quality) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw HLSPackager.PackagingError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let limit: CGFloat = quality == .low ? 1280 : 1920
        let scale = min(1, limit / max(size.width, size.height))
        let width = max(2, Int(size.width * scale) / 2 * 2)
        let height = max(2, Int(size.height * scale) / 2 * 2)
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        reader.add(videoOutput)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality == .low ? 3_000_000 : 8_000_000,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        videoInput.transform = transform
        writer.add(videoInput)
        var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ])
            reader.add(output)
            writer.add(input)
            audioPair = (output, input)
        }
        guard reader.startReading() else { throw HLSPackager.PackagingError.readerFailed(reader.error) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw HLSPackager.PackagingError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)
        await HLSPackager.pumpSamples(video: (videoOutput, videoInput), audio: audioPair, reader: reader, writer: writer)
        guard writer.status == .writing else {
            reader.cancelReading()
            throw HLSPackager.PackagingError.writerFailed(writer.error)
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw HLSPackager.PackagingError.readerFailed(reader.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw HLSPackager.PackagingError.writerFailed(writer.error) }
    }
}
