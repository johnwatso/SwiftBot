import Foundation
import XCTest
@testable import RecordingsKit
@testable import SwiftBot

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
