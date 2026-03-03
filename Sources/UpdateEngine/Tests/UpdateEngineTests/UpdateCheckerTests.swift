import XCTest
@testable import UpdateEngine

final class UpdateCheckerTests: XCTestCase {
    func testFirstSeenThenUnchangedThenChanged() async throws {
        let store = InMemoryVersionStore()
        let checker = UpdateChecker(store: store)

        let key = CacheKeyBuilder.build(vendor: "NVIDIA", channel: "gameReady")

        let first = try await checker.check(identifier: "item-1", for: key)
        XCTAssertEqual(first, .firstSeen(identifier: "item-1"))

        try await checker.save(identifier: "item-1", for: key)

        let unchanged = try await checker.check(identifier: "item-1", for: key)
        XCTAssertEqual(unchanged, .unchanged(identifier: "item-1"))

        let changed = try await checker.check(identifier: "item-2", for: key)
        XCTAssertEqual(changed, .changed(old: "item-1", new: "item-2"))
    }

    func testScopedKeysAreIndependent() async throws {
        let store = InMemoryVersionStore()
        let checker = UpdateChecker(store: store)

        let baseKey = CacheKeyBuilder.build(vendor: "AMD", channel: "default")
        let guildAKey = CacheKeyBuilder.buildGuildScoped(guildID: "guild-a", baseKey: baseKey)
        let guildBKey = CacheKeyBuilder.buildGuildScoped(guildID: "guild-b", baseKey: baseKey)

        try await checker.save(identifier: "amd-24.1.0", for: guildAKey)

        let guildA = try await checker.check(identifier: "amd-24.1.0", for: guildAKey)
        let guildB = try await checker.check(identifier: "amd-24.1.0", for: guildBKey)

        XCTAssertEqual(guildA, .unchanged(identifier: "amd-24.1.0"))
        XCTAssertEqual(guildB, .firstSeen(identifier: "amd-24.1.0"))
    }

    func testItemCheckUsesIdentifierNotVersion() async throws {
        let store = InMemoryVersionStore()
        let checker = UpdateChecker(store: store)

        let item = BasicUpdateItem(
            sourceKey: CacheKeyBuilder.build(vendor: "Steam", channel: "570"),
            identifier: "steam-gid-123",
            version: "March 03, 2026"
        )

        let first = try await checker.check(item: item)
        XCTAssertEqual(first, .firstSeen(identifier: "steam-gid-123"))

        try await checker.save(item: item)

        let withDifferentDisplayVersion = BasicUpdateItem(
            sourceKey: item.sourceKey,
            identifier: "steam-gid-123",
            version: "March 04, 2026"
        )

        let result = try await checker.check(item: withDifferentDisplayVersion)
        XCTAssertEqual(result, .unchanged(identifier: "steam-gid-123"))
    }
}
