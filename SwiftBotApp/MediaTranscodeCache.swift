import Foundation
import AVFoundation
import os

/// Lower-quality (and lower-bandwidth) variants of recordings, generated on
/// demand via `AVAssetExportSession`.
///
/// Used by `/api/media/stream?quality=low` so the WebUI player can fall back
/// to a smaller stream when the original recording's bitrate causes buffering.
/// Transcoded files live in `~/Library/Caches/SwiftBot/MediaTranscodes/` and
/// are keyed by item id, quality, and source mtime — if the source recording
/// is replaced, the next request regenerates the cached variant.
///
/// Concurrent requests for the same item share a single in-flight transcode
/// task instead of kicking off duplicates.
actor MediaTranscodeCache {
    enum Quality: String, Sendable {
        case low
    }

    private let cacheRoot: URL
    private let logger = Logger(subsystem: "com.swiftbot.media", category: "transcode")
    private var inFlight: [String: Task<URL?, Never>] = [:]

    init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    /// Returns the file URL of a cached low-quality variant of `sourceURL`,
    /// generating it if needed. Returns `nil` if the source can't be opened
    /// or the export fails.
    func variantURL(itemID: String, sourceURL: URL, quality: Quality) async -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let mtime = attributes[.modificationDate] as? Date else {
            return nil
        }
        let key = cacheKey(itemID: itemID, quality: quality, mtime: mtime)
        let cachedURL = cacheRoot.appendingPathComponent(key + ".mp4")

        if FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<URL?, Never> { [cachedURL, sourceURL, quality, logger] in
            let started = Date()
            do {
                let asset = AVURLAsset(url: sourceURL)
                let presetName = preset(for: quality)
                guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
                    logger.error("transcode failed: no session for \(sourceURL.lastPathComponent, privacy: .public)")
                    return nil
                }
                try? FileManager.default.removeItem(at: cachedURL)
                try await session.export(to: cachedURL, as: .mp4)
                let elapsed = Date().timeIntervalSince(started)
                logger.debug("transcoded \(sourceURL.lastPathComponent, privacy: .public) -> \(cachedURL.lastPathComponent, privacy: .public) in \(String(format: "%.1fs", elapsed), privacy: .public)")
                return cachedURL
            } catch {
                logger.error("transcode error for \(sourceURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                try? FileManager.default.removeItem(at: cachedURL)
                return nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private nonisolated func cacheKey(itemID: String, quality: Quality, mtime: Date) -> String {
        let mtimeStamp = Int(mtime.timeIntervalSince1970)
        let safeID = itemID.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(safeID)_\(quality.rawValue)_\(mtimeStamp)"
    }

    private nonisolated func preset(for quality: Quality) -> String {
        switch quality {
        case .low:
            return AVAssetExportPresetMediumQuality
        }
    }
}
