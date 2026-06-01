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
            onGuildDelete: { _ in }
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
