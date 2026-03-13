import Foundation

actor GatewayEventDispatcher {
    typealias EventRecorder = (String) async -> Void
    typealias PayloadHandler = (DiscordJSON?) async -> Void
    typealias ReadyHandler = (DiscordJSON?, Bool) async -> Void

    private let onEventReceived: EventRecorder
    private let onMessageCreate: PayloadHandler
    private let onMessageReactionAdd: PayloadHandler
    private let onInteractionCreate: PayloadHandler
    private let onVoiceStateUpdate: PayloadHandler
    private let onReady: ReadyHandler
    private let onGuildCreate: PayloadHandler
    private let onChannelCreate: PayloadHandler
    private let onMemberJoin: PayloadHandler
    private let onMemberLeave: PayloadHandler
    private let onGuildDelete: PayloadHandler

    init(
        onEventReceived: @escaping EventRecorder,
        onMessageCreate: @escaping PayloadHandler,
        onMessageReactionAdd: @escaping PayloadHandler,
        onInteractionCreate: @escaping PayloadHandler,
        onVoiceStateUpdate: @escaping PayloadHandler,
        onReady: @escaping ReadyHandler,
        onGuildCreate: @escaping PayloadHandler,
        onChannelCreate: @escaping PayloadHandler,
        onMemberJoin: @escaping PayloadHandler,
        onMemberLeave: @escaping PayloadHandler,
        onGuildDelete: @escaping PayloadHandler
    ) {
        self.onEventReceived = onEventReceived
        self.onMessageCreate = onMessageCreate
        self.onMessageReactionAdd = onMessageReactionAdd
        self.onInteractionCreate = onInteractionCreate
        self.onVoiceStateUpdate = onVoiceStateUpdate
        self.onReady = onReady
        self.onGuildCreate = onGuildCreate
        self.onChannelCreate = onChannelCreate
        self.onMemberJoin = onMemberJoin
        self.onMemberLeave = onMemberLeave
        self.onGuildDelete = onGuildDelete
    }

    func dispatch(_ payload: GatewayPayload, shouldProcessPrimaryGatewayActions: Bool) async {
        guard payload.op == 0, let eventName = payload.t else { return }

        await onEventReceived(eventName)

        switch eventName {
        case "MESSAGE_CREATE":
            guard shouldProcessPrimaryGatewayActions else { return }
            await onMessageCreate(payload.d)
        case "MESSAGE_REACTION_ADD":
            guard shouldProcessPrimaryGatewayActions else { return }
            await onMessageReactionAdd(payload.d)
        case "INTERACTION_CREATE":
            guard shouldProcessPrimaryGatewayActions else { return }
            await onInteractionCreate(payload.d)
        case "VOICE_STATE_UPDATE":
            await onVoiceStateUpdate(payload.d)
        case "READY":
            await onReady(payload.d, shouldProcessPrimaryGatewayActions)
        case "GUILD_CREATE":
            await onGuildCreate(payload.d)
        case "CHANNEL_CREATE":
            await onChannelCreate(payload.d)
        case "GUILD_MEMBER_ADD":
            guard shouldProcessPrimaryGatewayActions else { return }
            await onMemberJoin(payload.d)
        case "GUILD_MEMBER_REMOVE":
            guard shouldProcessPrimaryGatewayActions else { return }
            await onMemberLeave(payload.d)
        case "GUILD_DELETE":
            await onGuildDelete(payload.d)
        default:
            break
        }
    }
}
