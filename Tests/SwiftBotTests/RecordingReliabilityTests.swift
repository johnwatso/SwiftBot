import Foundation
import AVFoundation
import XCTest
@testable import RecordingsKit
@testable import SwiftBot

final class RecordingCommentTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCommentsSurviveReloadAndRetriesWithoutMixingClipsOrOwners() throws {
        let url = try directory().appendingPathComponent(RecordingCommentLog.fileName)
        let log = RecordingCommentLog(fileURL: url)
        let id = UUID()
        let comment = try log.append(id: id, key: "mac-a|clip", authorID: "123", authorName: "John", text: " Great clutch! \n")
        _ = try log.append(id: UUID(), key: "mac-b|clip", authorID: "456", authorName: "Sam", text: "Different recording")
        let reloaded = RecordingCommentLog(fileURL: url)
        XCTAssertEqual(try reloaded.comments(for: "mac-a|clip"), [comment])
        XCTAssertEqual(comment.text, "Great clutch!")
        XCTAssertEqual(try reloaded.append(id: id, key: "mac-a|clip", authorID: "123", authorName: "Renamed", text: "Great clutch!"), comment)
        XCTAssertEqual(try reloaded.load().count, 2)
        XCTAssertThrowsError(try reloaded.append(id: id, key: "mac-a|clip", authorID: "456", authorName: "Sam", text: "Great clutch!"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testInvalidTextCorruptLogsAndFailedWritesNeverReplaceHistory() throws {
        let folder = try directory()
        let log = RecordingCommentLog(fileURL: folder.appendingPathComponent(RecordingCommentLog.fileName))
        for text in [" \n\t", String(repeating: "a", count: 2001), String(repeating: "😀", count: 1001)] {
            XCTAssertThrowsError(try log.append(id: UUID(), key: "clip", authorID: "123", authorName: "John", text: text))
        }
        let damaged = Data("damaged history".utf8)
        try damaged.write(to: log.fileURL)
        XCTAssertThrowsError(try log.append(id: UUID(), key: "clip", authorID: "123", authorName: "John", text: "New comment"))
        XCTAssertEqual(try Data(contentsOf: log.fileURL), damaged)
        let blocked = folder.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let unavailable = RecordingCommentLog(fileURL: blocked.appendingPathComponent("comments.json"))
        XCTAssertThrowsError(try unavailable.append(id: UUID(), key: "clip", authorID: "123", authorName: "John", text: "Cannot save"))
    }

    func testCommentsTravelThroughRevisionedMeshSnapshotAndReload() async throws {
        let sourceFolder = try directory(), targetFolder = try directory()
        let source = ConfigStore(folderURL: sourceFolder), target = ConfigStore(folderURL: targetFolder)
        try await source.save(BotSettings())
        try await target.save(BotSettings())
        let log = RecordingCommentLog(fileURL: sourceFolder.appendingPathComponent(RecordingCommentLog.fileName))
        let comment = try log.append(id: UUID(), key: "remote-node|clip", authorID: "123", authorName: "John", text: "Shared clip comment")
        let targetLog = RecordingCommentLog(fileURL: targetFolder.appendingPathComponent(RecordingCommentLog.fileName))
        XCTAssertEqual(try targetLog.load(), [])
        let data = await source.exportMeshSyncedFiles(excludingFileNames: [], leaderTerm: 3)
        let imported = await target.importMeshSnapshot(try XCTUnwrap(data), minimumLeaderTerm: 3)
        XCTAssertTrue(imported.accepted)
        XCTAssertEqual(try targetLog.comments(for: "remote-node|clip"), [comment])
    }

    @MainActor
    func testModelOnlyAttachesCommentsToAnExistingRecordingAndStopsWritesOnStandby() async throws {
        let folder = try directory()
        try Data([0]).write(to: folder.appendingPathComponent("THE FINALS.mp4"))
        let app = AppModel()
        app.recordingCommentLog = RecordingCommentLog(fileURL: folder.appendingPathComponent("comments.json"))
        app.mediaLibrarySettings.sources = [.init(name: "Comment fixture", rootPath: folder.path)]
        let library = await app.localMediaLibrarySnapshot()
        let payload = app.adminWebMediaLibrarySnapshot(payloads: [library], query: [:], people: [:])
        let item = try XCTUnwrap(payload.items.first)
        let token = try XCTUnwrap(URLComponents(string: item.streamURL)?.queryItems?.first(where: { $0.name == "id" })?.value)
        let saved = try await app.addRecordingComment(token: token, id: UUID(), authorID: "123", authorName: "John", text: "Saved")
        XCTAssertNotNil(saved)
        let comments = try await app.recordingComments(token: token)
        XCTAssertEqual(comments?.count, 1)
        let missing = try await app.recordingComments(token: "forged-recording")
        XCTAssertNil(missing)
        app.meshWritesPaused = true
        let refused = try await app.addRecordingComment(token: token, id: UUID(), authorID: "123", authorName: "John", text: "Refused")
        XCTAssertNil(refused)
        XCTAssertEqual(try app.recordingCommentLog.load().count, 1)
    }
}

final class RecordingReliabilityTests: XCTestCase {
    func testQueuedSettingsSnapshotsCannotOverwriteCommittedLocalSharingChoice() async throws {
        let store = MediaLibraryConfigStore(filename: "recording-preference-test-\(UUID()).json")
        let url = await store.fileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = MediaLibrarySettings()
        try await store.save(original)
        var enabled = original
        enabled.sharedLibraryEnabled = true
        try await store.saveSharingChoice(enabled)
        try await store.save(original)
        let retained = await store.load()
        XCTAssertTrue(retained.sharedLibraryEnabled)
        try await store.saveSharingChoice(original)
        try await store.save(enabled)
        let disabled = await store.load()
        XCTAssertFalse(disabled.sharedLibraryEnabled, "A delayed snapshot cannot revive sharing after opt-out")
    }
    func testBrowserOpenEndedAndSuffixRanges() {
        let initial = AppModel.parseByteRange("bytes=0-", fileSize: 20_000_000)
        XCTAssertEqual(initial?.offset, 0)
        XCTAssertEqual(initial?.length, 20_000_000)
        let next = AppModel.parseByteRange("bytes=8388608-", fileSize: 20_000_000)
        XCTAssertEqual(next?.offset, 8_388_608)
        XCTAssertEqual(next?.length, 11_611_392)
        let tail = AppModel.parseByteRange("bytes=-1024", fileSize: 20_000_000)
        XCTAssertEqual(tail?.offset, 19_998_976)
        XCTAssertEqual(tail?.length, 1_024)
        let bounded = AppModel.parseByteRange("bytes=100-199", fileSize: 1_000)
        XCTAssertEqual(bounded?.offset, 100)
        XCTAssertEqual(bounded?.length, 100)
        for invalid in ["bytes=-0", "bytes=1000-", "bytes=200-100", "bytes=abc-", "bytes=0-1,4-5"] {
            XCTAssertNil(AppModel.parseByteRange(invalid, fileSize: 1_000))
        }
    }

    @MainActor
    func testDownloadSendsEntireOriginalBeyondPlaybackChunkLimitAndSupportsResume() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var original = Data(repeating: 0x5A, count: 20 * 1024 * 1024 + 37)
        original[8_388_608] = 0xA1
        original[16_777_216] = 0xB2
        original[original.count - 1] = 0xC3
        try original.write(to: folder.appendingPathComponent("Full clip — test.mp4"))
        let app = AppModel()
        app.mediaLibrarySettings.sources = [.init(name: "Download fixture", rootPath: folder.path)]
        let library = await app.localMediaLibrarySnapshot()
        let item = try XCTUnwrap(library.items.first)
        let server = AdminWebServer()
        await server.testSetMediaStreamProvider { _, range, quality in
            XCTAssertEqual(quality, "original", "A download must never select encoded/cache quality")
            return await app.localMediaStreamResponse(itemID: item.id, rangeHeader: range, quality: quality)
        }
        let session = await server.testSeedSession()
        let headers = ["Cookie": "swiftbot_admin_session=\(session.id)"]
        let output = RecordingDownloadCollector()
        let response = await server.testProcessRequest(RecordingCoordinationTests.rawRequest(path: "/api/media/download?id=clip", headers: headers),
            streamSender: { bytes in await output.append(bytes) })
        XCTAssertTrue(response.isEmpty, "The transport has already sent the response incrementally")
        let wire = await output.data
        let boundary = try XCTUnwrap(wire.range(of: Data("\r\n\r\n".utf8)))
        let head = String(decoding: wire[..<boundary.upperBound], as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(head.contains("Content-Length: \(original.count)"))
        XCTAssertTrue(head.contains("Content-Disposition: attachment; filename*=UTF-8''Full%20clip%20%E2%80%94%20test.mp4"))
        XCTAssertEqual(Data(wire[boundary.upperBound...]), original)
        let maximum = await output.maximumChunk
        XCTAssertLessThanOrEqual(maximum, 8 * 1024 * 1024)

        let resumed = RecordingDownloadCollector()
        var resumeHeaders = headers
        resumeHeaders["Range"] = "bytes=8388608-"
        _ = await server.testProcessRequest(RecordingCoordinationTests.rawRequest(path: "/api/media/download?id=clip", headers: resumeHeaders),
            streamSender: { bytes in await resumed.append(bytes) })
        let remaining = await resumed.data
        let resumeBoundary = try XCTUnwrap(remaining.range(of: Data("\r\n\r\n".utf8)))
        XCTAssertTrue(String(decoding: remaining.prefix(40), as: UTF8.self).contains("206 Partial Content"))
        XCTAssertEqual(Data(remaining[resumeBoundary.upperBound...]), original.subdata(in: 8_388_608..<original.count))
        resumeHeaders["If-Range"] = "\"an-old-source-revision\""
        let restarted = RecordingDownloadCollector()
        _ = await server.testProcessRequest(RecordingCoordinationTests.rawRequest(path: "/api/media/download?id=clip", headers: resumeHeaders),
            streamSender: { bytes in await restarted.append(bytes) })
        let restartedWire = await restarted.data
        let restartedBoundary = try XCTUnwrap(restartedWire.range(of: Data("\r\n\r\n".utf8)))
        XCTAssertTrue(String(decoding: restartedWire.prefix(40), as: UTF8.self).contains("200 OK"))
        XCTAssertEqual(Data(restartedWire[restartedBoundary.upperBound...]), original, "A stale resume validator must restart the complete original")
        resumeHeaders["If-Range"] = nil
        let headResponse = await server.testProcessRequest(RecordingCoordinationTests.rawRequest(path: "/api/media/download?id=clip", method: "HEAD", headers: headers))
        XCTAssertTrue(String(decoding: headResponse, as: UTF8.self).contains("Content-Length: \(original.count)"))
        let unauthenticated = await server.testProcessRequest(RecordingCoordinationTests.rawRequest(path: "/api/media/download?id=clip"))
        XCTAssertEqual(RecordingCoordinationTests.status(unauthenticated), 401)
        resumeHeaders["Range"] = "bytes=999999999-"
        let invalid = await server.testProcessRequest(RecordingCoordinationTests.rawRequest(path: "/api/media/download?id=clip", headers: resumeHeaders))
        XCTAssertEqual(RecordingCoordinationTests.status(invalid), 416)
        for useNIO in [false, true] {
            let base = try await server.testStartMediaTransport(useNIO: useNIO)
            let client = URLSession(configuration: .ephemeral)
            var request = URLRequest(url: base.appendingPathComponent("api/media/download").appending(queryItems: [URLQueryItem(name: "id", value: "clip")]))
            request.setValue("swiftbot_admin_session=\(session.id)", forHTTPHeaderField: "Cookie")
            request.timeoutInterval = 15
            do {
                let (file, response) = try await client.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertEqual(file, original, "Every byte must cross the actual \(useNIO ? "NIO" : "Network") socket")
                client.invalidateAndCancel()
                await server.stop()
            } catch {
                client.invalidateAndCancel()
                await server.stop()
                throw error
            }
        }
        let interrupted = RecordingDownloadCollector()
        _ = await server.testProcessRequest(RecordingCoordinationTests.rawRequest(path: "/api/media/download?id=clip", headers: headers), streamSender: { bytes in
            await interrupted.append(bytes)
            if bytes.count == 8 * 1024 * 1024 {
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: folder.appendingPathComponent(item.fileName).path)
            }
        })
        let truncated = await interrupted.data
        let truncatedBoundary = try XCTUnwrap(truncated.range(of: Data("\r\n\r\n".utf8)))
        XCTAssertEqual(truncated.count - truncatedBoundary.upperBound, 8 * 1024 * 1024, "A replaced source must fail the transfer rather than mix old/new bytes")
    }

    @MainActor
    func testWatchSearchFindsOlderRecordingsBeforePaginationAndKeepsVisibilityFilters() {
        let app = AppModel()
        let source = MediaLibrarySource(name: "Gameplay", rootPath: "/test-only", allowedExtensions: ["mp4"])
        let items = (0..<30).map { index in
            MediaLibraryItem(
                id: "clip-\(index)", sourceID: source.id, sourceName: source.name,
                fileName: index == 29 ? "THE_FINALS_Ranked_Chaos.mp4" : "capture-\(index).mp4",
                relativePath: "Season 11/capture-\(index).mp4", absolutePath: "/test-only/capture-\(index).mp4",
                fileExtension: "mp4", sizeBytes: 100,
                modifiedAt: Date(timeIntervalSince1970: 2_000_000_000 - Double(index)), ownerNodeName: "Capture Mac"
            )
        }
        let payload = MediaLibraryPayload(nodeName: "Capture Mac", configFilePath: "test-only", sources: [source], items: items, generatedAt: Date())
        let firstPage = app.adminWebMediaLibrarySnapshot(payloads: [payload], query: ["pageSize": "12"], people: [:])
        XCTAssertFalse(firstPage.items.contains { $0.fileName.contains("Ranked") })
        let match = app.adminWebMediaLibrarySnapshot(payloads: [payload], query: ["search": "  ranked_chaos  ", "pageSize": "12"], people: [:])
        XCTAssertEqual(match.items.map(\.fileName), ["THE_FINALS_Ranked_Chaos.mp4"])
        XCTAssertEqual(match.totalItems, 1)
        XCTAssertEqual(match.totalPages, 1)
        let sourceMatch = app.adminWebMediaLibrarySnapshot(payloads: [payload], query: ["search": "gameplay"], people: [:])
        XCTAssertEqual(sourceMatch.totalItems, 30)
        let pathMatch = app.adminWebMediaLibrarySnapshot(payloads: [payload], query: ["search": "season 11"], people: [:])
        XCTAssertEqual(pathMatch.totalItems, 30)
        let noMatch = app.adminWebMediaLibrarySnapshot(payloads: [payload], query: ["search": "missing"], people: [:])
        XCTAssertTrue(noMatch.items.isEmpty)
        let hidden = app.adminWebMediaLibrarySnapshot(payloads: [payload], query: ["search": "ranked"], people: [:], onlyItems: ["\(payload.identity)|clip-0"])
        XCTAssertTrue(hidden.items.isEmpty, "Search must never broaden a member's allowed recordings")
        let otherSource = app.adminWebMediaLibrarySnapshot(payloads: [payload], query: ["search": "ranked", "source": "other-source"], people: [:])
        XCTAssertTrue(otherSource.items.isEmpty)
    }

    @MainActor
    func testHLSRewritingKeepsViewerGrantsOnSameOriginAndRejectsForeignURLs() {
        let app = AppModel()
        let raw = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2,\nseg0.m4s\n#EXT-X-ENDLIST\n"
        let rewritten = app.rewriteHLSPlaylist(raw, idToken: "clip/id", accessToken: "viewer+grant", prefix: "low-")
        XCTAssertTrue(rewritten?.contains("id=clip%2Fid&seg=low-init.mp4&token=viewer%2Bgrant") == true)
        XCTAssertTrue(rewritten?.contains("seg=low-seg0.m4s") == true)
        let revision = String(repeating: "a", count: 64)
        let versioned = raw.replacingOccurrences(of: "init.mp4", with: revision + "-init.mp4")
            .replacingOccurrences(of: "seg0.m4s", with: revision + "-seg0.m4s")
        let versionedResult = app.rewriteHLSPlaylist(versioned, idToken: "clip", accessToken: "grant", prefix: "low-")
        XCTAssertTrue(versionedResult?.contains("seg=low-" + revision + "-seg0.m4s&token=grant") == true)
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000000\nlow-" + revision + "-playlist.m3u8\n"
        XCTAssertTrue(app.rewriteHLSPlaylist(master, idToken: "clip", accessToken: "grant")?.contains("seg=low-" + revision + "-playlist.m3u8") == true)
        let seekMaster = master.replacingOccurrences(of: "low-", with: "seek-180-low-")
        XCTAssertTrue(app.rewriteHLSPlaylist(seekMaster, idToken: "clip", accessToken: "grant")?.contains("seg=seek-180-low-" + revision) == true)
        let seekRendition = app.rewriteHLSPlaylist(versioned, idToken: "clip", accessToken: "grant", prefix: "seek-180-low-")
        XCTAssertTrue(seekRendition?.contains("seg=seek-180-low-" + revision + "-seg0.m4s&token=grant") == true)
        for invalid in ["seek-180-../low-playlist.m3u8", "seek--180-low-playlist.m3u8", "https://evil.example/seg0.m4s", "../seg0.m4s", "#EXT-X-KEY:METHOD=AES-128,URI=\"https://evil.example\"",
                        "#EXT-X-MAP:URI=\"../init.mp4\""] {
            XCTAssertNil(app.rewriteHLSPlaylist("#EXTM3U\n" + invalid, idToken: "clip", accessToken: "grant"))
        }
        for invalid in ["../seg0.m4s", "seg0.m4s/access", ".access", "playlist.m3u8", "seg-1.m4s"] {
            XCTAssertFalse(HLSPackager.isSegmentName(invalid))
        }
    }

    func testHardwareStreamPublishesPlayableAudioVideoChunksAndReusesCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await Self.writeStreamingFixture(to: source)
        let packager = HLSPackager(cacheRoot: root.appendingPathComponent("cache"), targetSegmentSeconds: 2)
        async let first = packager.streamingPlaylistURL(itemID: "clip", sourceURL: source, quality: .low)
        async let second = packager.streamingPlaylistURL(itemID: "clip", sourceURL: source, quality: .low)
        let (firstURL, secondURL) = await (first, second)
        let url = try XCTUnwrap(firstURL)
        XCTAssertEqual(url, secondURL, "Concurrent viewers must share one encode")
        var manifest = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(manifest.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        XCTAssertTrue(manifest.contains("seg0.m4s"))
        let deadline = Date().addingTimeInterval(20)
        while !manifest.contains("#EXT-X-ENDLIST"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            _ = await packager.streamingPlaylistURL(itemID: "clip", sourceURL: source, quality: .low)
            manifest = try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertTrue(manifest.contains("#EXT-X-ENDLIST"), "A completed recording must become seekable VOD")
        var movie = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("init.mp4"))
        for name in manifest.split(separator: "\n").map(String.init) where name.hasSuffix(".m4s") {
            let segment = await packager.streamingSegmentURL(itemID: "clip", sourceURL: source, quality: .low, segment: name)
            movie.append(try Data(contentsOf: XCTUnwrap(segment)))
        }
        let assembled = root.appendingPathComponent("assembled.mp4")
        try movie.write(to: assembled)
        let asset = AVURLAsset(url: assembled)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let size = try await XCTUnwrap(videoTracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 180), "Small recordings must not be upscaled")
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 12, accuracy: 0.15)
        let cached = await packager.streamingPlaylistURL(itemID: "clip", sourceURL: source, quality: .low)
        XCTAssertEqual(cached, url)
        let invalidSegment = await packager.streamingSegmentURL(itemID: "clip", sourceURL: source, quality: .low, segment: "../source.mp4")
        XCTAssertNil(invalidSegment)
        let before = await packager.streamingIdentity(itemID: "clip", sourceURL: source, quality: .low)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: source.path)
        let after = await packager.streamingIdentity(itemID: "clip", sourceURL: source, quality: .low)
        XCTAssertNotEqual(before, after, "A replaced recording must invalidate all old rendition URLs")
        let stale = await packager.streamingSegmentURL(itemID: "clip", sourceURL: source, quality: .low, segment: "seg0.m4s")
        XCTAssertNil(stale, "An unprepared replacement must not return chunks from the previous file")
        let missing = await packager.streamingPlaylistURL(itemID: "missing", sourceURL: root.appendingPathComponent("missing.mp4"), quality: .low)
        XCTAssertNil(missing)
    }

    func testHardwareSeekingEncodesOnlyRequestedTailWithRebasedAudioVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await Self.writeStreamingFixture(to: source)
        let packager = HLSPackager(cacheRoot: root.appendingPathComponent("cache"), targetSegmentSeconds: 2)
        // Occupy both encoder slots before a new seek; it must get capacity
        // without waiting for two entire recording exports to finish.
        await packager.prepareStream(itemID: "clip", sourceURL: source, quality: .low)
        await packager.prepareStream(itemID: "clip", sourceURL: source, quality: .standard)
        async let first = packager.streamingPlaylistURL(itemID: "clip", sourceURL: source, quality: .low, startSeconds: 8)
        async let second = packager.streamingPlaylistURL(itemID: "clip", sourceURL: source, quality: .low, startSeconds: 8)
        let (firstURL, secondURL) = await (first, second)
        let url = try XCTUnwrap(firstURL)
        XCTAssertEqual(url, secondURL)
        let zeroIdentity = await packager.streamingIdentity(itemID: "clip", sourceURL: source, quality: .low)
        let seekIdentity = await packager.streamingIdentity(itemID: "clip", sourceURL: source, quality: .low, startSeconds: 8)
        XCTAssertNotEqual(zeroIdentity, seekIdentity)
        var manifest = try String(contentsOf: url, encoding: .utf8)
        let deadline = Date().addingTimeInterval(20)
        while !manifest.contains("#EXT-X-ENDLIST"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            manifest = try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertTrue(manifest.contains("#EXT-X-ENDLIST"))
        var movie = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("init.mp4"))
        for name in manifest.split(separator: "\n").map(String.init) where name.hasSuffix(".m4s") {
            let chunk = await packager.streamingSegmentURL(itemID: "clip", sourceURL: source, quality: .low, segment: name, startSeconds: 8)
            movie.append(try Data(contentsOf: XCTUnwrap(chunk)))
        }
        let assembled = root.appendingPathComponent("seek.mp4")
        try movie.write(to: assembled)
        let asset = AVURLAsset(url: assembled)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 4, accuracy: 0.2, "The output must contain the tail, not eight seconds of leading footage")
        for track in [try XCTUnwrap(video.first), try XCTUnwrap(audio.first)] {
            let range = try await track.load(.timeRange)
            XCTAssertLessThan(abs(range.start.seconds), 0.15, "Both timelines must start near zero after a source seek")
        }
        // The fixture changes brightness each frame. Compare the requested
        // source frame with the new first frames to detect accidentally reading 0.
        let sourceGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        let seekGenerator = AVAssetImageGenerator(asset: asset)
        for generator in [sourceGenerator, seekGenerator] {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        let sourceImage = try await sourceGenerator.image(at: CMTime(seconds: 8.1, preferredTimescale: 600)).image
        let seekImage = try await seekGenerator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        func brightness(_ image: CGImage) throws -> Double {
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Double(bytes[0])
        }
        XCTAssertEqual(try brightness(seekImage), try brightness(sourceImage), accuracy: 15)
        let reused = await packager.streamingPlaylistURL(itemID: "clip", sourceURL: source, quality: .low, startSeconds: 8)
        XCTAssertEqual(reused, url)
        let invalid = await packager.streamingPlaylistURL(itemID: "clip", sourceURL: source, quality: .low, startSeconds: -1)
        XCTAssertNil(invalid)
        let pastEnd = await packager.streamingPlaylistURL(itemID: "clip", sourceURL: source, quality: .low, startSeconds: 60)
        XCTAssertNil(pastEnd)
    }

    @MainActor
    func testOwnerSeekPlaylistPinsOffsetAndRevisionAndReturnsFullDuration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await Self.writeStreamingFixture(to: source)
        let app = AppModel()
        app.mediaLibrarySettings.sources = [.init(name: "Seek fixture", rootPath: root.path)]
        let library = await app.localMediaLibrarySnapshot()
        let item = try XCTUnwrap(library.items.first { $0.fileName == "source.mov" })
        var cacheDirectories: [URL] = []
        defer { for directory in cacheDirectories { try? FileManager.default.removeItem(at: directory) } }
        let masterResponse = await app.localMediaHLSResponse(itemID: item.id, segment: "seek-8-master.m3u8")
        let master = try XCTUnwrap(masterResponse)
        XCTAssertEqual(try XCTUnwrap(Double(try XCTUnwrap(master.headers["X-SwiftBot-Duration"]))), 12, accuracy: 0.2)
        let text = String(decoding: master.body, as: UTF8.self)
        let names = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("seek-8-") })
        let rendition = try XCTUnwrap(names.first)
        let firstResponse = await app.localMediaHLSResponse(itemID: item.id, segment: rendition)
        var response = try XCTUnwrap(firstResponse)
        XCTAssertEqual(response.status, "200 OK")
        let deadline = Date().addingTimeInterval(10)
        while !String(decoding: response.body, as: UTF8.self).contains("#EXT-X-ENDLIST"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            let nextResponse = await app.localMediaHLSResponse(itemID: item.id, segment: rendition)
            response = try XCTUnwrap(nextResponse)
        }
        let raw = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(raw.contains("#EXT-X-ENDLIST"))
        let prefix = "seek-8-low-"
        let identity = String(rendition.dropFirst(prefix.count).dropLast("-playlist.m3u8".count))
        cacheDirectories.append(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftBot/MediaHLS/" + identity))
        let initResponse = await app.localMediaHLSResponse(itemID: item.id, segment: prefix + identity + "-init.mp4")
        XCTAssertEqual(initResponse?.contentType, "video/mp4")
        let chunk = try XCTUnwrap(raw.split(separator: "\n").first { $0.hasSuffix(".m4s") })
        let chunkResponse = await app.localMediaHLSResponse(itemID: item.id, segment: prefix + chunk)
        XCTAssertEqual(chunkResponse?.status, "200 OK")
        XCTAssertFalse(chunkResponse?.body.isEmpty ?? true)
        for name in ["seek--1-master.m3u8", "seek-08-master.m3u8", "seek-604801-master.m3u8", "seek-8-../init.mp4", "seek-60-master.m3u8"] {
            let invalid = await app.localMediaHLSResponse(itemID: item.id, segment: name)
            XCTAssertNil(invalid)
        }
        let wrongOffset = await app.localMediaHLSResponse(itemID: item.id, segment: rendition.replacingOccurrences(of: "seek-8-", with: "seek-6-"))
        XCTAssertNil(wrongOffset, "An offset cannot reuse another timeline's revision")
    }

    func testSamplePumpHonoursCancellationBeforeCallbacksRegister() async throws {
        try await exerciseSamplePump(cancelBeforeStarting: true, stopDuringRead: false)
    }

    func testSamplePumpStopsBothTracksAfterAnInFlightRead() async throws {
        try await exerciseSamplePump(cancelBeforeStarting: false, stopDuringRead: true)
    }

    func testSamplePumpIgnoresLateCallbacksAfterFinishing() async throws {
        try await exerciseSamplePump(cancelBeforeStarting: false, stopDuringRead: false)
    }

    private func exerciseSamplePump(cancelBeforeStarting: Bool, stopDuringRead: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await Self.writeStreamingFixture(to: source)
        let asset = AVURLAsset(url: source)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: root.appendingPathComponent("output.mov"), fileType: .mov)
        let stopRequest = MediaPumpStopRequest()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoOutput = StopDuringReadOutput(track: try XCTUnwrap(videoTracks.first), outputSettings: nil)
        videoOutput.stopRequest = stopDuringRead ? stopRequest : nil
        let audioOutput = AVAssetReaderTrackOutput(track: try XCTUnwrap(audioTracks.first), outputSettings: nil)
        reader.add(videoOutput)
        reader.add(audioOutput)
        let videoInput = ReplayableReadinessInput(mediaType: .video, outputSettings: nil)
        let audioInput = ReplayableReadinessInput(mediaType: .audio, outputSettings: nil)
        writer.add(videoInput)
        writer.add(audioInput)
        XCTAssertTrue(reader.startReading())
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let done = expectation(description: "Both tracks stop without hanging")
        let session = SamplePumpTestSession(reader: reader, writer: writer, videoOutput: videoOutput,
            audioOutput: audioOutput, videoInput: videoInput, audioInput: audioInput)
        let task = Task {
            if cancelBeforeStarting { withUnsafeCurrentTask { $0?.cancel() } }
            await HLSPackager.pumpSamples(video: (session.videoOutput, session.videoInput), audio: (session.audioOutput, session.audioInput),
                reader: session.reader, writer: session.writer, stopRequest: stopRequest)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        await task.value

        if cancelBeforeStarting || stopDuringRead {
            XCTAssertEqual(reader.status, .cancelled)
            XCTAssertEqual(videoOutput.readCount, stopDuringRead ? 1 : 0)
            writer.cancelWriting()
        } else {
            XCTAssertEqual(reader.status, .completed)
            await writer.finishWriting()
            XCTAssertEqual(writer.status, .completed)
        }
        // Explicitly replay callbacks after terminal teardown: no status/readiness
        // access is permitted, even if AVFoundation already queued more work.
        for input in [videoInput, audioInput] {
            let checks = input.readinessChecks
            await input.replayCallback()
            XCTAssertEqual(input.readinessChecks, checks, "A finished track must ignore stale callbacks")
        }
    }

    private static func writeStreamingFixture(to url: URL) async throws {
        let videoURL = url.deletingLastPathComponent().appendingPathComponent("video.mp4")
        let audioURL = url.deletingLastPathComponent().appendingPathComponent("audio.m4a")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180
        ])
        writer.add(video)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(10)
        for index in 0..<288 {
            while !video.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw try XCTUnwrap(writer.error) }
                if Date() > deadline { writer.cancelWriting(); throw CocoaError(.coderInvalidValue) }
                try await Task.sleep(for: .milliseconds(1))
            }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(index % 255), CVPixelBufferGetBytesPerRow(buffer) * 180)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 12, preferredTimescale: 600))
        video.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 576_000))
        pcm.frameLength = pcm.frameCapacity
        for channel in 0..<2 { pcm.floatChannelData?[channel].initialize(repeating: 0, count: Int(pcm.frameLength)) }
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
            ])
            try file.write(from: pcm)
        }
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        for (type, asset) in [(AVMediaType.video, videoAsset), (.audio, audioAsset)] {
            let tracks = try await asset.loadTracks(withMediaType: type)
            let track = try XCTUnwrap(tracks.first)
            let output = try XCTUnwrap(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            let duration = try await asset.load(.duration)
            try output.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await exporter.export(to: url, as: .mov)
        withExtendedLifetime((videoAsset, audioAsset)) {}
    }

    func testDiscoveryRetainsUnavailableFolderButHonoursDeletionAndDisabledSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let offline = root.appendingPathExtension("offline")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: offline)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Discovery must use directory metadata even for unfinalized captures.
        try Data("unfinished capture".utf8).write(to: root.appendingPathComponent("clip.mp4"))
        try Data().write(to: root.appendingPathComponent("ignore.txt"))
        var source = MediaLibrarySource(name: "Capture", rootPath: root.path, allowedExtensions: ["mp4"])
        let indexer = MediaLibraryIndexer(cacheTTL: 0)
        func snapshot() async -> MediaLibraryPayload {
            await indexer.snapshot(sources: [source], ownerNodeName: "Test", ownerBaseURL: nil, configFilePath: "test.json")
        }
        let initial = await snapshot()
        XCTAssertEqual(initial.items.map(\.fileName), ["clip.mp4"])
        try FileManager.default.moveItem(at: root, to: offline)
        let unavailable = await snapshot()
        XCTAssertEqual(unavailable.items, initial.items)
        XCTAssertEqual(unavailable.unavailableSourceIDs, [source.id])
        XCTAssertFalse(unavailable.isAvailable(try XCTUnwrap(unavailable.items.first)))
        try FileManager.default.moveItem(at: offline, to: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("clip.mp4"))
        let deleted = await snapshot()
        XCTAssertTrue(deleted.items.isEmpty)
        try Data().write(to: root.appendingPathComponent("new.mp4"))
        let restored = await snapshot()
        XCTAssertEqual(restored.items.map(\.fileName), ["new.mp4"])
        XCTAssertTrue(restored.isAvailable(try XCTUnwrap(restored.items.first)))
        source.isEnabled = false
        let disabled = await snapshot()
        XCTAssertTrue(disabled.items.isEmpty)
    }
}

actor RecordingDownloadCollector {
    var data = Data()
    var maximumChunk = 0
    func append(_ bytes: Data) {
        data.append(bytes)
        maximumChunk = max(maximumChunk, bytes.count)
    }
}

/// Requests shutdown while a real copyNextSampleBuffer call is in flight.
/// Only the pump queue reads/writes readCount; the test observes it after join.
private final class StopDuringReadOutput: AVAssetReaderTrackOutput {
    var stopRequest: MediaPumpStopRequest?
    private(set) var readCount = 0

    override func copyNextSampleBuffer() -> CMSampleBuffer? {
        readCount += 1
        stopRequest?.request()
        return super.copyNextSampleBuffer()
    }
}

/// Replays on the original callback queue, after the pump has completed.
private final class ReplayableReadinessInput: AVAssetWriterInput, @unchecked Sendable {
    private let stateLock = NSLock()
    private var checks = 0
    private var callback: (@Sendable () -> Void)?
    private var callbackQueue: DispatchQueue?

    var readinessChecks: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return checks
    }

    override var isReadyForMoreMediaData: Bool {
        stateLock.lock()
        checks += 1
        stateLock.unlock()
        return super.isReadyForMoreMediaData
    }

    override func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        stateLock.lock()
        callback = block
        callbackQueue = queue
        stateLock.unlock()
        super.requestMediaDataWhenReady(on: queue, using: block)
    }

    func replayCallback() async {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            let block = callback
            let queue = callbackQueue
            stateLock.unlock()
            guard let queue, let block else { continuation.resume(); return }
            queue.async {
                block()
                continuation.resume()
            }
        }
    }
}

/// AVFoundation references are exclusively handed to the pump task until join.
private struct SamplePumpTestSession: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let videoOutput: AVAssetReaderTrackOutput
    let audioOutput: AVAssetReaderTrackOutput
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput
}
