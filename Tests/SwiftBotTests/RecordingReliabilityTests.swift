import Foundation
import XCTest
@testable import RecordingsKit
@testable import SwiftBot

final class RecordingReliabilityTests: XCTestCase {
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
        try FileManager.default.moveItem(at: offline, to: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("clip.mp4"))
        let deleted = await snapshot()
        XCTAssertTrue(deleted.items.isEmpty)
        try Data().write(to: root.appendingPathComponent("new.mp4"))
        let restored = await snapshot()
        XCTAssertEqual(restored.items.map(\.fileName), ["new.mp4"])
        source.isEnabled = false
        let disabled = await snapshot()
        XCTAssertTrue(disabled.items.isEmpty)
    }
}
