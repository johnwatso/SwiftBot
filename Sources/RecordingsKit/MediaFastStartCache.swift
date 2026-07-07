import AVFoundation
import Foundation
import os

/// Creates cached "fast start" MP4 remuxes for recordings whose metadata
/// (`moov`) lives after the media payload. The export uses passthrough, so it
/// rewrites the container for browser-friendly startup/seeking without
/// re-encoding audio or video.
public actor MediaFastStartCache {
    private var cacheRoot: URL
    private let logger = Logger(subsystem: "com.swiftbot.media", category: "faststart")
    private var inFlight: [String: Task<URL?, Never>] = [:]

    public init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    public func updateCacheRoot(_ cacheRoot: URL) {
        guard self.cacheRoot.standardizedFileURL != cacheRoot.standardizedFileURL else { return }
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
        self.cacheRoot = cacheRoot
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    public func removeAllCachedFiles() {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    public func optimizedURL(itemID: String, sourceURL: URL) async -> URL? {
        guard needsOptimization(sourceURL: sourceURL),
              let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let mtime = attributes[.modificationDate] as? Date else {
            return nil
        }

        let key = cacheKey(itemID: itemID, mtime: mtime)
        let cachedURL = cacheRoot.appendingPathComponent(key + ".mp4")
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<URL?, Never> { [cachedURL, sourceURL, logger] in
            let started = Date()
            do {
                try Task.checkCancellation()
                let asset = AVURLAsset(url: sourceURL)
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                    logger.error("fast-start remux failed: no passthrough session for \(sourceURL.lastPathComponent, privacy: .public)")
                    return nil
                }
                session.shouldOptimizeForNetworkUse = true
                try? FileManager.default.removeItem(at: cachedURL)
                try await session.export(to: cachedURL, as: .mp4)
                try Task.checkCancellation()
                let elapsed = Date().timeIntervalSince(started)
                logger.debug("fast-start remuxed \(sourceURL.lastPathComponent, privacy: .public) in \(String(format: "%.1fs", elapsed), privacy: .public)")
                return cachedURL
            } catch {
                logger.error("fast-start remux error for \(sourceURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                try? FileManager.default.removeItem(at: cachedURL)
                return nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private nonisolated func cacheKey(itemID: String, mtime: Date) -> String {
        let mtimeStamp = Int(mtime.timeIntervalSince1970)
        let safeID = itemID.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "|", with: "_")
        return "\(safeID)_faststart_\(mtimeStamp)"
    }

    private nonisolated func needsOptimization(sourceURL: URL) -> Bool {
        guard sourceURL.pathExtension.lowercased() == "mp4",
              let atoms = topLevelAtoms(sourceURL: sourceURL) else {
            return false
        }
        guard let moov = atoms.first(where: { $0.type == "moov" }),
              let mdat = atoms.first(where: { $0.type == "mdat" }) else {
            return false
        }
        return moov.offset > mdat.offset
    }

    private nonisolated func topLevelAtoms(sourceURL: URL) -> [(type: String, offset: UInt64)]? {
        guard let handle = try? FileHandle(forReadingFrom: sourceURL) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)

        var atoms: [(type: String, offset: UInt64)] = []
        var offset: UInt64 = 0
        while offset + 8 <= fileSize, atoms.count < 128 {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else {
                break
            }
            let smallSize = UInt64(header[0]) << 24
                | UInt64(header[1]) << 16
                | UInt64(header[2]) << 8
                | UInt64(header[3])
            let type = String(decoding: header[4..<8], as: UTF8.self)
            let atomSize: UInt64
            if smallSize == 1 {
                guard header.count >= 16 else { break }
                atomSize = header[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            } else if smallSize == 0 {
                atomSize = fileSize - offset
            } else {
                atomSize = smallSize
            }
            guard atomSize >= 8 else { break }
            atoms.append((type: type, offset: offset))
            offset += atomSize
        }
        return atoms
    }
}
