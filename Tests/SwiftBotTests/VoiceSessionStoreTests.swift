import XCTest
@testable import SwiftBot

final class VoiceSessionStoreTests: XCTestCase {
    func testRollingLeaderboardIncludesActiveSessions() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let joinedAt = now.addingTimeInterval(-20 * 60 * 60)

        await store.recordJoin(
            userId: "john-id",
            username: "john",
            guildId: "guild-1",
            channelId: "voice-1",
            channelName: "General",
            at: joinedAt
        )

        let leaders = await store.getTopVoiceUserRollingAveragesLast7Days(
            guildId: "guild-1",
            limit: 5,
            relativeTo: now
        )

        XCTAssertEqual(leaders.first?.userId, "john-id")
        XCTAssertEqual(leaders.first?.totalSeconds, 20 * 60 * 60)
        XCTAssertEqual(leaders.first?.averageSecondsPerDay, Int((Double(20 * 60 * 60) / 7.0).rounded()))
    }

    func testRollingLeaderboardClipsSessionsToSevenDayWindow() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let joinedAt = now.addingTimeInterval((-7 * 24 - 3) * 60 * 60)
        let leftAt = now.addingTimeInterval((-7 * 24 + 5) * 60 * 60)

        await store.recordJoin(
            userId: "max-id",
            username: "max",
            guildId: "guild-1",
            channelId: "voice-1",
            channelName: "General",
            at: joinedAt
        )
        await store.recordLeave(userId: "max-id", guildId: "guild-1", at: leftAt)

        let leaders = await store.getTopVoiceUserRollingAveragesLast7Days(
            guildId: "guild-1",
            limit: 5,
            relativeTo: now
        )

        XCTAssertEqual(leaders.first?.userId, "max-id")
        XCTAssertEqual(leaders.first?.totalSeconds, 5 * 60 * 60)
    }

    func testTopVoiceUsersUsesRollingDurationsByUserId() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        await store.recordJoin(
            userId: "john-id",
            username: "john",
            guildId: "guild-1",
            channelId: "voice-1",
            channelName: "General",
            at: now.addingTimeInterval(-20 * 60 * 60)
        )
        await store.recordJoin(
            userId: "gabe-id",
            username: "gabe",
            guildId: "guild-1",
            channelId: "voice-1",
            channelName: "General",
            at: now.addingTimeInterval(-2 * 60 * 60)
        )

        let users = await store.getTopVoiceUsers(limit: 5, relativeTo: now)

        XCTAssertEqual(users.map(\.username), ["john", "gabe"])
        XCTAssertEqual(users.first?.seconds, 20 * 60 * 60)
    }

    private func makeStore() -> VoiceSessionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return VoiceSessionStore(
            activeURL: directory.appendingPathComponent("active.json"),
            historyURL: directory.appendingPathComponent("history.json")
        )
    }
}
