import XCTest
@testable import SwiftBot

final class GatewayEventDispatcherTests: XCTestCase {
    func testMessageCreateParsesMemberRoleIDs() async {
        let capture = MessageCreateCapture()
        let dispatcher = GatewayEventDispatcher(
            onEventReceived: { _ in },
            onMessageCreate: { event in await capture.set(event) },
            onMessageReactionAdd: { _ in },
            onInteractionCreate: { _ in },
            onVoiceStateUpdate: { _ in },
            onVoiceServerUpdate: { _ in },
            onReady: { _, _ in },
            onGuildCreate: { _ in },
            onChannelCreate: { _ in },
            onMemberJoin: { _ in },
            onMemberLeave: { _ in },
            onGuildDelete: { _ in },
            onPresenceUpdate: { _ in }
        )
        let payload = GatewayPayload(
            op: 0,
            d: .object([
                "id": .string("message-1"),
                "content": .string("hello"),
                "channel_id": .string("channel-1"),
                "guild_id": .string("guild-1"),
                "author": .object([
                    "id": .string("user-1"),
                    "username": .string("alice")
                ]),
                "member": .object([
                    "roles": .array([
                        .string("role-admin"),
                        .string("role-helper")
                    ])
                ])
            ]),
            s: 1,
            t: "MESSAGE_CREATE"
        )

        await dispatcher.dispatch(payload, shouldProcessPrimaryGatewayActions: true)

        let event = await capture.event
        XCTAssertEqual(event?.memberRoleIDs, ["role-admin", "role-helper"])
    }
}

private actor MessageCreateCapture {
    private(set) var event: GatewayMessageCreateEvent?

    func set(_ event: GatewayMessageCreateEvent) {
        self.event = event
    }
}

private actor PresenceCapture {
    private(set) var event: GatewayPresenceUpdateEvent?
    func set(_ value: GatewayPresenceUpdateEvent) { event = value }
}

extension GatewayEventDispatcherTests {
    func testPresenceUpdateParsesPlayingActivityAndStartTimestamp() async throws {
        let capture = PresenceCapture()
        let dispatcher = GatewayEventDispatcher(
            onEventReceived: { _ in },
            onMessageCreate: { _ in },
            onMessageReactionAdd: { _ in },
            onInteractionCreate: { _ in },
            onVoiceStateUpdate: { _ in },
            onVoiceServerUpdate: { _ in },
            onReady: { _, _ in },
            onGuildCreate: { _ in },
            onChannelCreate: { _ in },
            onMemberJoin: { _ in },
            onMemberLeave: { _ in },
            onGuildDelete: { _ in },
            onPresenceUpdate: { event in await capture.set(event) }
        )

        let payload = GatewayPayload(
            op: 0,
            d: .object([
                "guild_id": .string("guild-1"),
                "status": .string("online"),
                "user": .object(["id": .string("user-1")]),
                "activities": .array([
                    .object([
                        "name": .string("Spotify"),
                        "type": .int(2)
                    ]),
                    .object([
                        "name": .string("THE FINALS"),
                        "type": .int(0),
                        "application_id": .string("app-1"),
                        "timestamps": .object(["start": .int(1_800_000_000_000)])
                    ])
                ])
            ]),
            s: nil,
            t: "PRESENCE_UPDATE"
        )

        await dispatcher.dispatch(payload, shouldProcessPrimaryGatewayActions: true)

        let captured = await capture.event
        let event = try XCTUnwrap(captured)
        XCTAssertEqual(event.userID, "user-1")
        XCTAssertEqual(event.guildID, "guild-1")
        XCTAssertEqual(event.activities.count, 2)

        // Only "Playing" (type 0) counts as a game session.
        XCTAssertEqual(event.playingActivities.map(\.name), ["THE FINALS"])
        XCTAssertEqual(
            event.playingActivities.first?.startedAt,
            Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func testOfflinePresenceReportsNoPlayingActivities() async throws {
        let capture = PresenceCapture()
        let dispatcher = GatewayEventDispatcher(
            onEventReceived: { _ in },
            onMessageCreate: { _ in },
            onMessageReactionAdd: { _ in },
            onInteractionCreate: { _ in },
            onVoiceStateUpdate: { _ in },
            onVoiceServerUpdate: { _ in },
            onReady: { _, _ in },
            onGuildCreate: { _ in },
            onChannelCreate: { _ in },
            onMemberJoin: { _ in },
            onMemberLeave: { _ in },
            onGuildDelete: { _ in },
            onPresenceUpdate: { event in await capture.set(event) }
        )

        let payload = GatewayPayload(
            op: 0,
            d: .object([
                "guild_id": .string("guild-1"),
                "status": .string("offline"),
                "user": .object(["id": .string("user-1")]),
                "activities": .array([
                    .object(["name": .string("THE FINALS"), "type": .int(0)])
                ])
            ]),
            s: nil,
            t: "PRESENCE_UPDATE"
        )

        await dispatcher.dispatch(payload, shouldProcessPrimaryGatewayActions: true)

        let captured = await capture.event
        let event = try XCTUnwrap(captured)
        XCTAssertTrue(event.isOffline)
        XCTAssertTrue(event.playingActivities.isEmpty)
    }
}

private actor InteractionCreateCapture {
    private(set) var event: GatewayInteractionCreateEvent?
    func set(_ value: GatewayInteractionCreateEvent) { event = value }
}

extension GatewayEventDispatcherTests {
    func testModalSubmitInteractionIsDispatchedWithoutCommandName() async throws {
        let capture = InteractionCreateCapture()
        let dispatcher = GatewayEventDispatcher(
            onEventReceived: { _ in },
            onMessageCreate: { _ in },
            onMessageReactionAdd: { _ in },
            onInteractionCreate: { event in await capture.set(event) },
            onVoiceStateUpdate: { _ in },
            onVoiceServerUpdate: { _ in },
            onReady: { _, _ in },
            onGuildCreate: { _ in },
            onChannelCreate: { _ in },
            onMemberJoin: { _ in },
            onMemberLeave: { _ in },
            onGuildDelete: { _ in },
            onPresenceUpdate: { _ in }
        )

        let payload = GatewayPayload(
            op: 0,
            d: .object([
                "id": .string("interaction-1"),
                "token": .string("token-1"),
                "type": .int(5),
                "channel_id": .string("channel-1"),
                "user": .object(["id": .string("user-1"), "username": .string("alice")]),
                "data": .object([
                    "custom_id": .string(SwiftMinerDMEmbedBuilders.editGamesModalCustomID),
                    "components": .array([
                        .object([
                            "type": .int(1),
                            "components": .array([
                                .object([
                                    "type": .int(4),
                                    "custom_id": .string(SwiftMinerDMEmbedBuilders.editGamesInputID),
                                    "value": .string("THE FINALS\nRust")
                                ])
                            ])
                        ])
                    ])
                ])
            ]),
            s: 1,
            t: "INTERACTION_CREATE"
        )

        await dispatcher.dispatch(payload, shouldProcessPrimaryGatewayActions: true)

        let captured = await capture.event
        let event = try XCTUnwrap(captured)
        XCTAssertEqual(event.interactionType, 5)
        XCTAssertNil(event.commandName)
        XCTAssertEqual(event.data["custom_id"], .string(SwiftMinerDMEmbedBuilders.editGamesModalCustomID))
    }
}
