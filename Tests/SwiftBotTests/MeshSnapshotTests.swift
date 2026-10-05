import XCTest
@testable import SwiftBot

final class MeshSnapshotTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSharedConfigurationPreservesLocalTunnelAndCompanions() async throws {
        let origin = ConfigStore(folderURL: try directory())
        let destination = ConfigStore(folderURL: try directory())
        var primary = BotSettings()
        primary.prefix = "?"
        primary.adminWebUI.hostname = "primary.example.com"
        primary.adminWebUI.discordOAuth.clientID = "shared-discord-app"
        primary.adminWebUI.cloudflareAPIToken = "primary-api-secret"
        primary.adminWebUI.publicAccessTunnelToken = "primary-tunnel-secret"
        primary.swiftMiner.apiKey = "primary-companion-secret"
        try await origin.save(primary)
        var backup = BotSettings()
        backup.adminWebUI.hostname = "swiftbot2.example.com"
        backup.adminWebUI.publicBaseURL = "https://swiftbot2.example.com"
        backup.adminWebUI.additionalTunnelHostnames = [AdditionalTunnelHostname(hostname: "local.example.com", service: "http://localhost:8080", label: "Local companion")]
        backup.clusterNodeName = "Backup Mac"
        backup.clusterMode = .standby
        try await destination.save(backup)
        let snapshotValue = await origin.exportMeshSyncedFiles(excludingFileNames: [], leaderTerm: 3)
        let snapshot = try XCTUnwrap(snapshotValue)
        let decoded = try JSONDecoder().decode(MeshSyncedFilesPayload.self, from: snapshot)
        let settingsFile = try XCTUnwrap(decoded.files.first { $0.fileName == "settings.json" })
        let shared = String(decoding: try XCTUnwrap(Data(base64Encoded: settingsFile.base64Data)), as: UTF8.self)
        XCTAssertFalse(shared.contains("primary-api-secret"))
        XCTAssertFalse(shared.contains("primary-tunnel-secret"))
        XCTAssertFalse(shared.contains("primary-companion-secret"))
        let imported = await destination.importMeshSnapshot(snapshot, minimumLeaderTerm: 3)
        XCTAssertTrue(imported.accepted)
        let loaded = await destination.load()
        XCTAssertEqual(loaded.prefix, "?")
        XCTAssertEqual(loaded.adminWebUI.discordOAuth.clientID, "shared-discord-app")
        XCTAssertEqual(loaded.adminWebUI.hostname, "swiftbot2.example.com")
        XCTAssertEqual(loaded.adminWebUI.additionalTunnelHostnames, backup.adminWebUI.additionalTunnelHostnames)
        let mergedIdentity = try MeshBotConfiguration.mergingSharedData(Data(base64Encoded: settingsFile.base64Data)!, into: JSONEncoder().encode(backup))
        let identity = try JSONDecoder().decode(BotSettings.self, from: mergedIdentity)
        XCTAssertEqual(identity.clusterNodeName, "Backup Mac")
    }

    func testStaleAndConflictingSnapshotsCannotOverwriteState() async throws {
        let source = ConfigStore(folderURL: try directory())
        let target = ConfigStore(folderURL: try directory())
        var settings = BotSettings()
        try await source.save(settings)
        let firstValue = await source.exportMeshSyncedFiles(excludingFileNames: [], leaderTerm: 7)
        let first = try XCTUnwrap(firstValue)
        let initial = await target.importMeshSnapshot(first, minimumLeaderTerm: 7)
        XCTAssertTrue(initial.accepted)
        settings.prefix = "new"
        try await source.save(settings)
        let secondValue = await source.exportMeshSyncedFiles(excludingFileNames: [], leaderTerm: 7)
        let second = try XCTUnwrap(secondValue)
        let latest = await target.importMeshSnapshot(second, minimumLeaderTerm: 7)
        let stale = await target.importMeshSnapshot(first, minimumLeaderTerm: 7)
        XCTAssertTrue(latest.accepted)
        XCTAssertFalse(stale.accepted)
        var conflicting = try JSONDecoder().decode(MeshSyncedFilesPayload.self, from: first)
        conflicting.revision = try JSONDecoder().decode(MeshSyncedFilesPayload.self, from: second).revision
        let conflict = await target.importMeshSnapshot(try JSONEncoder().encode(conflicting), minimumLeaderTerm: 7)
        XCTAssertFalse(conflict.accepted)
        let loaded = await target.load()
        XCTAssertEqual(loaded.prefix, "new")
        let replay = await target.importMeshSnapshot(second, minimumLeaderTerm: 7)
        XCTAssertTrue(replay.accepted)
        XCTAssertEqual(replay.importedFileCount, 0)
    }

    func testUnknownFilesAndInvalidManifestAreRejectedAtomically() async throws {
        let source = ConfigStore(folderURL: try directory())
        let target = ConfigStore(folderURL: try directory())
        try await source.save(BotSettings())
        let snapshotValue = await source.exportMeshSyncedFiles(excludingFileNames: [], leaderTerm: 2)
        let snapshot = try XCTUnwrap(snapshotValue)
        let original = try JSONDecoder().decode(MeshSyncedFilesPayload.self, from: snapshot)
        let injected = MeshSyncedFilesPayload(generatedAt: Date(), files: original.files + [MeshSyncedFile(fileName: "../outside.json", base64Data: Data("{}".utf8).base64EncodedString())], leaderTerm: 2, revision: 1, deletedFileNames: original.deletedFileNames)
        let result = await target.importMeshSnapshot(try JSONEncoder().encode(injected), minimumLeaderTerm: 2)
        XCTAssertFalse(result.accepted)
        let version = await target.meshSnapshotVersion()
        XCTAssertNil(version)
    }
}
