import AVFoundation
import XCTest
@testable import RecordingsKit

/// Proves the HLS packaging path end-to-end on a real (synthesized) H.264 clip:
/// `AVAssetReader` → segmented `AVAssetWriter` → on-disk init + media segments
/// and a valid VOD playlist. There are no sample recordings in the repo, so the
/// test generates its own source clip first.
final class HLSPackagerTests: XCTestCase {

    func testPackagesH264ClipIntoPlayableHLS() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HLSPackagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // ~10s of H.264 video so the 4s segmenter produces multiple segments.
        let sourceURL = workDir.appendingPathComponent("source.mp4")
        try await makeH264Clip(at: sourceURL, seconds: 10, fps: 15, size: CGSize(width: 320, height: 240))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path), "source clip should exist")

        let cacheRoot = workDir.appendingPathComponent("cache", isDirectory: true)
        let packager = HLSPackager(cacheRoot: cacheRoot, targetSegmentSeconds: 4)

        let itemID = "source-1"
        guard let playlistURL = await packager.playlistURL(itemID: itemID, sourceURL: sourceURL) else {
            return XCTFail("packager returned nil playlist URL")
        }

        // Playlist exists and is a well-formed fMP4 VOD manifest.
        let playlist = try String(contentsOf: playlistURL, encoding: .utf8)
        XCTAssertTrue(playlist.hasPrefix("#EXTM3U"), "playlist should start with #EXTM3U")
        XCTAssertTrue(playlist.contains("#EXT-X-VERSION:7"), "fMP4 needs HLS v7")
        XCTAssertTrue(playlist.contains("#EXT-X-MAP:URI=\"\(HLSPackager.initSegmentFileName)\""), "playlist references the init segment")
        XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"), "VOD playlist must be terminated")
        XCTAssertTrue(playlist.contains("#EXTINF:"), "playlist should contain media segments")

        let dir = playlistURL.deletingLastPathComponent()
        let initSegment = dir.appendingPathComponent(HLSPackager.initSegmentFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: initSegment.path), "init.mp4 should be written")
        let segmentCount = playlist.components(separatedBy: "#EXTINF:").count - 1
        XCTAssertGreaterThanOrEqual(segmentCount, 2, "10s @ 4s segments should yield >= 2 media segments")

        // Every referenced media segment resolves through the traversal-safe lookup.
        for line in playlist.split(separator: "\n") where line.hasSuffix(".m4s") {
            let resolved = await packager.segmentURL(itemID: itemID, sourceURL: sourceURL, segment: String(line))
            XCTAssertNotNil(resolved, "segment \(line) should resolve to a file on disk")
        }

        // A second call hits the cache and returns the same playlist.
        let cached = await packager.playlistURL(itemID: itemID, sourceURL: sourceURL)
        XCTAssertEqual(cached, playlistURL, "second call should return the cached playlist")
    }

    func testSegmentLookupRejectsPathTraversal() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HLSPackagerTests-traversal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let packager = HLSPackager(cacheRoot: cacheRoot)

        // Use a real existing file as the "source" so cacheDirectory resolves,
        // isolating the traversal guard from the mtime lookup.
        let source = cacheRoot.appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source)

        for evil in ["../secret", "sub/seg.m4s", "..", ".", "", "a/../../b"] {
            let resolved = await packager.segmentURL(itemID: "x", sourceURL: source, segment: evil)
            XCTAssertNil(resolved, "segment lookup must reject '\(evil)'")
        }
    }

    func testFastStartRemuxMovesMetadataBeforeMediaData() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaFastStartCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let sourceURL = workDir.appendingPathComponent("source.mp4")
        try await makeH264Clip(at: sourceURL, seconds: 2, fps: 15, size: CGSize(width: 320, height: 240))

        let sourceAtoms = try topLevelAtomOffsets(in: sourceURL)
        guard let sourceMoov = sourceAtoms["moov"],
              let sourceMdat = sourceAtoms["mdat"],
              sourceMoov > sourceMdat else {
            throw XCTSkip("AVAssetWriter already produced a fast-start source on this platform")
        }

        let cacheRoot = workDir.appendingPathComponent("cache", isDirectory: true)
        let cache = MediaFastStartCache(cacheRoot: cacheRoot)
        guard let optimizedURL = await cache.optimizedURL(itemID: "source-1", sourceURL: sourceURL) else {
            return XCTFail("fast-start cache returned nil for end-moov source")
        }

        let optimizedAtoms = try topLevelAtomOffsets(in: optimizedURL)
        guard let optimizedMoov = optimizedAtoms["moov"],
              let optimizedMdat = optimizedAtoms["mdat"] else {
            return XCTFail("optimized MP4 should include moov and mdat atoms")
        }
        XCTAssertLessThan(optimizedMoov, optimizedMdat, "fast-start output should place moov before mdat")

        let cached = await cache.optimizedURL(itemID: "source-1", sourceURL: sourceURL)
        XCTAssertEqual(cached, optimizedURL, "second call should return the cached fast-start file")
    }

    // MARK: - Helpers

    /// Writes a solid-color H.264 MP4 with forced periodic keyframes so the HLS
    /// segmenter has sync samples to split on.
    private func makeH264Clip(at url: URL, seconds: Int, fps: Int, size: CGSize) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: fps, // a keyframe every second
                AVVideoAverageBitRateKey: 800_000
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalFrames = seconds * fps
        let queue = DispatchQueue(label: "hls-test-encode")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var frame = 0
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if frame >= totalFrames {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    guard let pool = adaptor.pixelBufferPool else {
                        continuation.resume(throwing: NSError(domain: "hls-test", code: 1))
                        return
                    }
                    var pixelBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                    guard let buffer = pixelBuffer else {
                        continuation.resume(throwing: NSError(domain: "hls-test", code: 2))
                        return
                    }
                    // Vary the fill so the encoder produces non-trivial frames.
                    CVPixelBufferLockBaseAddress(buffer, [])
                    if let base = CVPixelBufferGetBaseAddress(buffer) {
                        let size = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
                        memset(base, Int32(frame % 256), size)
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
                    adaptor.append(buffer, withPresentationTime: time)
                    frame += 1
                }
            }
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? NSError(domain: "hls-test", code: 3)
        }
    }

    private func topLevelAtomOffsets(in url: URL) throws -> [String: UInt64] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)

        var offsets: [String: UInt64] = [:]
        var offset: UInt64 = 0
        while offset + 8 <= fileSize, offsets.count < 128 {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else {
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
            offsets[type] = offset
            offset += atomSize
        }
        return offsets
    }
}
