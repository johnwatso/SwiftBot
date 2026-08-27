import XCTest
@testable import SwiftBot

/// `untilEmpty` mode must part the bot as soon as the last human is gone —
/// whether they disconnected or moved to another channel, and regardless of
/// which other bots are sitting in the channel.
final class VoiceUntilEmptyTests: XCTestCase {

    @MainActor
    private func makeConnectedApp() -> AppModel {
        let app = AppModel()
        app.voiceConnectionStatus = .connected
        app.voicePendingGuildID = "guild-1"
        app.voicePendingChannelID = "voice-1"
        app.botUserId = "swiftbot-self"
        app.settings.voice.announcerConfigs = [
            AnnouncerVoiceChannelConfig(
                id: "config-1",
                name: "General",
                voiceChannelID: "voice-1",
                voiceChannelName: "General",
                connectionMode: .untilEmpty,
                emptyChannelGraceSeconds: 0,
                textChannels: ["text-1"]
            )
        ]
        return app
    }

    private func presence(_ userId: String, channelId: String = "voice-1") -> VoiceMemberPresence {
        VoiceMemberPresence(
            id: "guild-1-\(userId)",
            userId: userId,
            username: userId,
            guildId: "guild-1",
            channelId: channelId,
            channelName: "General",
            joinedAt: Date()
        )
    }

    @MainActor
    func testDisconnectsWhenOnlyBotsRemain() async throws {
        let app = makeConnectedApp()
        app.knownBotUserIds = ["music-bot"]
        // SwiftBot itself plus an unrelated bot. Neither is a reason to stay.
        app.activeVoice = [presence("swiftbot-self"), presence("music-bot")]

        await app.handleUntilEmptyCheck(leftChannelId: "voice-1", guildId: "guild-1")

        XCTAssertFalse(
            app.voiceConnectionStatus.isConnected,
            "a channel holding only bots is empty — the announcer must leave"
        )
    }

    @MainActor
    func testStaysConnectedWhileAHumanRemains() async throws {
        let app = makeConnectedApp()
        app.knownBotUserIds = ["music-bot"]
        app.activeVoice = [presence("swiftbot-self"), presence("music-bot"), presence("alice")]

        await app.handleUntilEmptyCheck(leftChannelId: "voice-1", guildId: "guild-1")

        XCTAssertTrue(
            app.voiceConnectionStatus.isConnected,
            "one human left in the channel must keep the announcer connected"
        )
    }

    @MainActor
    func testUnresolvedBotIdentityStillLeavesAnEmptyChannel() async throws {
        let app = makeConnectedApp()
        // botUserId not yet resolved (cleared across a reconnect); the shared
        // bot set still identifies us.
        app.botUserId = nil
        app.knownBotUserIds = ["swiftbot-self"]
        app.activeVoice = [presence("swiftbot-self")]

        await app.handleUntilEmptyCheck(leftChannelId: "voice-1", guildId: "guild-1")

        XCTAssertFalse(app.voiceConnectionStatus.isConnected)
    }

    @MainActor
    func testIntroducesHumanWhoJoinsAnActiveAnnouncerChannel() async throws {
        let app = makeConnectedApp()
        let announcer = try XCTUnwrap(app.voiceAnnouncementService)
        await announcer.setPaused(true)

        await app.announceMemberVoiceJoin(
            userID: "max",
            displayName: "Max",
            channelID: "voice-1",
            guildID: "guild-1"
        )

        let pending = await announcer.pending
        XCTAssertEqual(pending.map(\.text), ["Max has joined."])
    }

    @MainActor
    func testAnnouncesHumanWhoLeavesAnActiveAnnouncerChannel() async throws {
        let app = makeConnectedApp()
        let announcer = try XCTUnwrap(app.voiceAnnouncementService)
        await announcer.setPaused(true)

        await app.announceMemberVoiceDeparture(
            userID: "gabe",
            displayName: "Gabe",
            channelID: "voice-1",
            guildID: "guild-1"
        )

        let pending = await announcer.pending
        XCTAssertEqual(pending.map(\.text), ["Gabe has left."])
    }

    @MainActor
    func testDoesNotAnnounceBotDeparture() async throws {
        let app = makeConnectedApp()
        app.knownBotUserIds = ["music-bot"]
        let announcer = try XCTUnwrap(app.voiceAnnouncementService)
        await announcer.setPaused(true)

        await app.announceMemberVoiceDeparture(
            userID: "music-bot",
            displayName: "Music Bot",
            channelID: "voice-1",
            guildID: "guild-1"
        )

        let pending = await announcer.pending
        XCTAssertTrue(pending.isEmpty)
    }

    @MainActor
    func testMemberReturningDuringGoodbyePreventsStaleEmptyDisconnect() async throws {
        let app = makeConnectedApp()
        let playback = FakeAnnouncementPlayback()
        await playback.setDelay(.milliseconds(200))
        let announcer = try VoiceAnnouncementService(
            playback: playback,
            renderOverride: { _, _ in makeRenderedBuffer() }
        )
        app.voiceAnnouncementServiceStorage = announcer
        app.activeVoice = [presence("swiftbot-self")]
        await announcer.enqueue("Gabe has left.")

        let emptyCheck = Task { @MainActor in
            await app.handleAnnouncerPresenceChange(channelId: "voice-1", guildId: "guild-1")
        }
        try await Task.sleep(for: .milliseconds(50))
        app.activeVoice = [presence("swiftbot-self"), presence("alice")]
        await emptyCheck.value

        XCTAssertTrue(app.voiceConnectionStatus.isConnected)
        XCTAssertNil(app.emptyChannelDisconnectTask)
    }

    @MainActor
    func testIgnoresMembersOfAnotherChannel() async throws {
        let app = makeConnectedApp()
        app.activeVoice = [presence("swiftbot-self"), presence("alice", channelId: "voice-2")]

        await app.handleUntilEmptyCheck(leftChannelId: "voice-1", guildId: "guild-1")

        XCTAssertFalse(
            app.voiceConnectionStatus.isConnected,
            "someone in a different channel must not hold the announcer in this one"
        )
    }

    @MainActor
    func testExternalDiscordDisconnectStartsOneControlledRecovery() async throws {
        let app = makeConnectedApp()
        app.status = .running

        let event = GatewayVoiceStateUpdateEvent(
            rawMap: ["channel_id": .null],
            guildID: "guild-1",
            userID: "swiftbot-self",
            channelID: nil
        )
        await app.observeSelfVoiceStateUpdate(event)

        XCTAssertTrue(app.voiceRecovery.inProgress)
        XCTAssertEqual(app.voiceRecovery.attemptsMade, 1)
        XCTAssertTrue(app.voiceRecoveryAwaitingExternalDisconnectClosure)
        XCTAssertEqual(
            app.voiceConnectionStatus,
            .recovering("Rejoining after voice drop…")
        )
        XCTAssertTrue(app.voiceLog.contains {
            $0.description.contains("Discord reported that SwiftBot was disconnected")
        })

        // Let the scheduled recovery exit through its ordinary offline guard;
        // do not let this unit test attempt a real Discord connection.
        app.status = .stopped
    }

    @MainActor
    func testDelayedSelfLeaveDuringRecoveryDoesNotResetRetryBudget() async throws {
        let app = makeConnectedApp()
        app.status = .running
        app.voiceRecovery = VoiceRecoveryBackoff(schedule: [.seconds(60), .seconds(60)])
        _ = app.voiceRecovery.beginAttempt()
        app.voiceConnectionStatus = .recovering("Rejoining after voice drop…")

        // This is the null-channel acknowledgement for the leave SwiftBot
        // sent as part of its own clean rejoin. It may arrive after the short
        // leave-ack wait has elapsed, when the recovery is already underway.
        let delayedLeave = GatewayVoiceStateUpdateEvent(
            rawMap: ["channel_id": .null],
            guildID: "guild-1",
            userID: "swiftbot-self",
            channelID: nil
        )
        await app.observeSelfVoiceStateUpdate(delayedLeave)

        XCTAssertTrue(app.voiceRecovery.inProgress)
        XCTAssertEqual(app.voiceRecovery.attemptsMade, 1)
        XCTAssertEqual(app.voiceConnectionStatus, .recovering("Rejoining after voice drop…"))
        XCTAssertTrue(app.voiceLog.contains {
            $0.description.contains("Ignored delayed self voice-disconnect acknowledgement")
        })
    }
}
