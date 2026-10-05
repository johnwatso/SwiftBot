import AVFoundation
import XCTest
@testable import RecordingsKit
@testable import SwiftBot

/// Proves the HLS packaging path end-to-end on a real (synthesized) H.264 clip:
/// `AVAssetReader` → segmented `AVAssetWriter` → on-disk init + media segments
/// and a valid VOD playlist. There are no sample recordings in the repo, so the
/// test generates its own source clip first.
final class HLSPackagerTests: XCTestCase {

    @MainActor
    func testLibraryHidesManagedExportsWithoutRemovingSavedSources() async {
        let app = AppModel()
        let exportID = UUID()
        let managed = MediaLibrarySource(id: exportID, name: "Exports", rootPath: "")
        let custom = MediaLibrarySource(name: "Exports", rootPath: "")
        app.mediaLibrarySettings = MediaLibrarySettings(sources: [managed, custom], exportSourceID: exportID)
        let before = app.mediaLibrarySettings

        let library = await app.localMediaLibrarySnapshot()

        XCTAssertEqual(library.sources.map(\.id), [custom.id])
        XCTAssertEqual(app.localRecordingSources.map(\.id), [custom.id])
        XCTAssertEqual(app.mediaLibrarySettings, before)
    }

    @MainActor
    func testLibraryDoesNotAutomaticallyAddAnExportsFolder() async {
        let app = AppModel()
        app.mediaLibrarySettings = MediaLibrarySettings()

        let library = await app.localMediaLibrarySnapshot()

        XCTAssertTrue(library.sources.isEmpty)
        XCTAssertTrue(app.mediaLibrarySettings.sources.isEmpty)
        XCTAssertNil(app.mediaLibrarySettings.exportSourceID)
    }

    @MainActor
    func testFixMatchPrefersTheClipThenItsDetectedGameThenTheFilename() {
        let app = AppModel()
        app.settings.recordingGameAliases = ["the finals": "Splitgate 2"]
        app.settings.recordingGameOverrides = ["Mac|a|clip.mp4": "Black Ops 6"]

        XCTAssertEqual(app.resolvedMediaGameName(itemKey: "Mac|a|clip.mp4", detected: "THE FINALS"), "Black Ops 6")
        XCTAssertEqual(app.resolvedMediaGameName(itemKey: "Mac|a|other.mp4", detected: "THE FINALS"), "Splitgate 2")
        XCTAssertEqual(app.resolvedMediaGameName(itemKey: "Mac|a|other.mp4", detected: "Minecraft"), "Minecraft")
    }

    @MainActor
    func testTrademarkMarksDoNotSplitAGame() {
        XCTAssertEqual(AppModel.canonicalMediaGameName("Call of Duty® Modern Warfare® II Warzone™ 2.0"), "Call of Duty Modern Warfare II")
        XCTAssertEqual(AppModel.tidiedMediaGameName("Call of Duty®: Black Ops 6"), "Call of Duty: Black Ops 6")
        XCTAssertEqual(AppModel.canonicalMediaGameName("Call of Duty Modern Warfare 4 - Beta"), "Call of Duty Modern Warfare 4")
        XCTAssertEqual(AppModel.canonicalMediaGameName("Marvel Rivals (Open Beta)"), "Marvel Rivals")
    }

    func testArtworkMatchNeedsTheSameWordsInOrder() {
        XCTAssertFalse(RecordingSteamArtworkService.containsInOrder("Call of Duty Modern Warfare 4", within: "Call of Duty® 4: Modern Warfare®"))
        XCTAssertTrue(RecordingSteamArtworkService.containsInOrder("Call of Duty Modern Warfare 4", within: "Call of Duty®: Modern Warfare® 4"))
        XCTAssertTrue(RecordingSteamArtworkService.containsInOrder("Elder Scrolls Online", within: "The Elder Scrolls Online"))
    }

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

    func testMediaLibrarySettingsDefaultsFastStartOffForLegacyJSON() throws {
        let json = """
        {
          "sources": [],
          "exportRootPath": "",
          "exportIncludeInLibrary": true
        }
        """

        let settings = try JSONDecoder().decode(MediaLibrarySettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.fastStartOptimizationEnabled)
        XCTAssertEqual(settings.fastStartOutputPath, "")
    }

    func testMediaLibrarySettingsRoundTripsFastStartPreference() throws {
        let settings = MediaLibrarySettings(
            fastStartOptimizationEnabled: true,
            fastStartOutputPath: "/Volumes/CaptureScratch/SwiftBotFastStart"
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(MediaLibrarySettings.self, from: data)
        XCTAssertTrue(decoded.fastStartOptimizationEnabled)
        XCTAssertEqual(decoded.fastStartOutputPath, "/Volumes/CaptureScratch/SwiftBotFastStart")
    }

    func testFastStartCacheCanBeCleared() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaFastStartCacheClearTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let staleURL = cacheRoot.appendingPathComponent("stale.mp4")
        try Data("stale".utf8).write(to: staleURL)

        let cache = MediaFastStartCache(cacheRoot: cacheRoot)
        await cache.removeAllCachedFiles()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)
        XCTAssertTrue(remaining.isEmpty)
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

    func testHardwareStreamingVariantsArePlayableAndDeduplicateRequests() async throws {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("HardwareStreamTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let source = workDir.appendingPathComponent("source.mp4")
        try await makeH264Clip(at: source, seconds: 4, fps: 15, size: CGSize(width: 1920, height: 1080))
        let cache = MediaTranscodeCache(cacheRoot: workDir.appendingPathComponent("transcodes"))
        async let first = cache.variantURL(itemID: "clip", sourceURL: source, quality: .low)
        async let second = cache.variantURL(itemID: "clip", sourceURL: source, quality: .low)
        let (firstURL, secondURL) = await (first, second)
        let low = try XCTUnwrap(firstURL, "hardware encoding must succeed on this Mac")
        XCTAssertEqual(low, secondURL)
        let lowAsset = AVURLAsset(url: low)
        let lowTracks = try await lowAsset.loadTracks(withMediaType: .video)
        let lowTrack = try XCTUnwrap(lowTracks.first)
        let lowSize = try await lowTrack.load(.naturalSize)
        XCTAssertEqual(lowSize.width, 1280)
        XCTAssertEqual(lowSize.height, 720)
        let duration = try await lowAsset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 4, accuracy: 0.1)
        let standardURL = await cache.variantURL(itemID: "clip", sourceURL: source, quality: .standard)
        let standard = try XCTUnwrap(standardURL)
        XCTAssertNotEqual(standard, low)
        let standardTracks = try await AVURLAsset(url: standard).loadTracks(withMediaType: .video)
        let standardSize = try await XCTUnwrap(standardTracks.first).load(.naturalSize)
        XCTAssertEqual(standardSize.width, 1920)
        let packager = HLSPackager(cacheRoot: workDir.appendingPathComponent("hls"), targetSegmentSeconds: 2)
        let playlist = await packager.playlistURL(itemID: "low", sourceURL: low)
        XCTAssertNotNil(playlist, "the hardware output must also package as HLS")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "original stays intact")
        let failed = await cache.variantURL(itemID: "missing", sourceURL: workDir.appendingPathComponent("missing.mp4"), quality: .standard)
        XCTAssertNil(failed)
    }

    func testHardwareStreamingPreservesAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HardwareAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("video.mp4")
        try await makeH264Clip(at: videoURL, seconds: 2, fps: 15, size: CGSize(width: 320, height: 240))
        let audioURL = root.appendingPathComponent("audio.m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        for channel in 0..<2 {
            for frame in 0..<96_000 {
                buffer.floatChannelData?[channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.2
            }
        }
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
            ])
            try file.write(from: buffer)
        }
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 48_000))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: XCTUnwrap(videoTracks.first), at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: XCTUnwrap(audioTracks.first), at: .zero)
        let source = root.appendingPathComponent("source.mov")
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: source, as: .mov)
        withExtendedLifetime((videoAsset, audioAsset)) {}
        let cache = MediaTranscodeCache(cacheRoot: root.appendingPathComponent("cache"))
        let result = await cache.variantURL(itemID: "audio", sourceURL: source, quality: .low)
        let output = try XCTUnwrap(result)
        let outputAudioTracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        let outputTrack = try XCTUnwrap(outputAudioTracks.first)
        let timeRange = try await outputTrack.load(.timeRange)
        XCTAssertEqual(CMTimeGetSeconds(timeRange.duration), 2, accuracy: 0.1)
        let descriptions = try await outputTrack.load(.formatDescriptions)
        XCTAssertEqual(descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) }, kAudioFormatMPEG4AAC)
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
