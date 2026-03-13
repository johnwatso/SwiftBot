import Foundation

struct GatewayBotIdentity: Sendable {
    let id: String?
    let username: String?
    let discriminator: String?
    let avatarHash: String?
}

struct GatewayReadyGuild: Sendable {
    let id: String
    let name: String?
}

struct GatewayReadyEvent: Sendable {
    let identity: GatewayBotIdentity?
    let guilds: [GatewayReadyGuild]
}

struct GatewayGuildCreateEvent {
    let guildID: String
    let guildName: String?
    let memberCount: Int?
    let rawMap: [String: DiscordJSON]
}

struct GatewayChannelCreateEvent: Sendable {
    let channelID: String
    let guildID: String?
    let type: Int
    let name: String
}

struct GatewayGuildDeleteEvent: Sendable {
    let guildID: String
}

struct GatewayInteractionCreateEvent {
    let interactionID: String
    let interactionToken: String
    let commandName: String
    let data: [String: DiscordJSON]
    let rawMap: [String: DiscordJSON]
}

struct GatewayMemberJoinEvent: Sendable {
    let guildID: String
    let userID: String
    let rawUsername: String
    let joinedAt: Date?
}

struct GatewayMemberLeaveEvent: Sendable {
    let guildID: String
    let userID: String
    let username: String
}

actor GatewayEventDispatcher {
    typealias EventRecorder = (String) async -> Void
    typealias PayloadHandler = (DiscordJSON?) async -> Void
    typealias ReadyHandler = (GatewayReadyEvent, Bool) async -> Void
    typealias GuildCreateHandler = (GatewayGuildCreateEvent) async -> Void
    typealias ChannelCreateHandler = (GatewayChannelCreateEvent) async -> Void
    typealias GuildDeleteHandler = (GatewayGuildDeleteEvent) async -> Void
    typealias InteractionCreateHandler = (GatewayInteractionCreateEvent) async -> Void
    typealias MemberJoinHandler = (GatewayMemberJoinEvent) async -> Void
    typealias MemberLeaveHandler = (GatewayMemberLeaveEvent) async -> Void

    private let onEventReceived: EventRecorder
    private let onMessageCreate: PayloadHandler
    private let onMessageReactionAdd: PayloadHandler
    private let onInteractionCreate: InteractionCreateHandler
    private let onVoiceStateUpdate: PayloadHandler
    private let onReady: ReadyHandler
    private let onGuildCreate: GuildCreateHandler
    private let onChannelCreate: ChannelCreateHandler
    private let onMemberJoin: MemberJoinHandler
    private let onMemberLeave: MemberLeaveHandler
    private let onGuildDelete: GuildDeleteHandler

    init(
        onEventReceived: @escaping EventRecorder,
        onMessageCreate: @escaping PayloadHandler,
        onMessageReactionAdd: @escaping PayloadHandler,
        onInteractionCreate: @escaping InteractionCreateHandler,
        onVoiceStateUpdate: @escaping PayloadHandler,
        onReady: @escaping ReadyHandler,
        onGuildCreate: @escaping GuildCreateHandler,
        onChannelCreate: @escaping ChannelCreateHandler,
        onMemberJoin: @escaping MemberJoinHandler,
        onMemberLeave: @escaping MemberLeaveHandler,
        onGuildDelete: @escaping GuildDeleteHandler
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
            guard let interactionCreateEvent = parseInteractionCreateEvent(from: payload.d) else { return }
            await onInteractionCreate(interactionCreateEvent)
        case "VOICE_STATE_UPDATE":
            await onVoiceStateUpdate(payload.d)
        case "READY":
            guard let readyEvent = parseReadyEvent(from: payload.d) else { return }
            await onReady(readyEvent, shouldProcessPrimaryGatewayActions)
        case "GUILD_CREATE":
            guard let guildCreateEvent = parseGuildCreateEvent(from: payload.d) else { return }
            await onGuildCreate(guildCreateEvent)
        case "CHANNEL_CREATE":
            guard let channelCreateEvent = parseChannelCreateEvent(from: payload.d) else { return }
            await onChannelCreate(channelCreateEvent)
        case "GUILD_MEMBER_ADD":
            guard shouldProcessPrimaryGatewayActions else { return }
            guard let memberJoinEvent = parseMemberJoinEvent(from: payload.d) else { return }
            await onMemberJoin(memberJoinEvent)
        case "GUILD_MEMBER_REMOVE":
            guard shouldProcessPrimaryGatewayActions else { return }
            guard let memberLeaveEvent = parseMemberLeaveEvent(from: payload.d) else { return }
            await onMemberLeave(memberLeaveEvent)
        case "GUILD_DELETE":
            guard let guildDeleteEvent = parseGuildDeleteEvent(from: payload.d) else { return }
            await onGuildDelete(guildDeleteEvent)
        default:
            break
        }
    }

    private func parseReadyEvent(from raw: DiscordJSON?) -> GatewayReadyEvent? {
        guard case let .object(map)? = raw,
              case let .array(guilds)? = map["guilds"] else { return nil }

        let identity: GatewayBotIdentity?
        if case let .object(user)? = map["user"] {
            let discriminator: String?
            if case let .string(value)? = user["discriminator"] {
                discriminator = value == "0" ? nil : value
            } else {
                discriminator = nil
            }

            identity = GatewayBotIdentity(
                id: stringValue(for: "id", in: user),
                username: stringValue(for: "username", in: user),
                discriminator: discriminator,
                avatarHash: stringValue(for: "avatar", in: user)
            )
        } else {
            identity = nil
        }

        let readyGuilds = guilds.compactMap { guild -> GatewayReadyGuild? in
            guard case let .object(guildMap) = guild,
                  let guildID = stringValue(for: "id", in: guildMap) else {
                return nil
            }
            return GatewayReadyGuild(id: guildID, name: stringValue(for: "name", in: guildMap))
        }

        return GatewayReadyEvent(identity: identity, guilds: readyGuilds)
    }

    private func parseGuildCreateEvent(from raw: DiscordJSON?) -> GatewayGuildCreateEvent? {
        guard case let .object(map)? = raw,
              let guildID = stringValue(for: "id", in: map) else { return nil }

        let memberCount: Int?
        if case let .int(count)? = map["member_count"] {
            memberCount = count
        } else {
            memberCount = nil
        }

        return GatewayGuildCreateEvent(
            guildID: guildID,
            guildName: stringValue(for: "name", in: map),
            memberCount: memberCount,
            rawMap: map
        )
    }

    private func parseChannelCreateEvent(from raw: DiscordJSON?) -> GatewayChannelCreateEvent? {
        guard case let .object(map)? = raw,
              let channelID = stringValue(for: "id", in: map),
              case let .int(type)? = map["type"] else { return nil }

        let defaultName: String
        switch type {
        case 1:
            defaultName = "Direct Message"
        case 3:
            defaultName = "Group DM"
        default:
            defaultName = "Channel"
        }

        return GatewayChannelCreateEvent(
            channelID: channelID,
            guildID: stringValue(for: "guild_id", in: map),
            type: type,
            name: stringValue(for: "name", in: map) ?? defaultName
        )
    }

    private func parseGuildDeleteEvent(from raw: DiscordJSON?) -> GatewayGuildDeleteEvent? {
        guard case let .object(map)? = raw,
              let guildID = stringValue(for: "id", in: map) else { return nil }
        return GatewayGuildDeleteEvent(guildID: guildID)
    }

    private func parseInteractionCreateEvent(from raw: DiscordJSON?) -> GatewayInteractionCreateEvent? {
        guard case let .object(map)? = raw,
              let interactionID = stringValue(for: "id", in: map),
              let interactionToken = stringValue(for: "token", in: map),
              case let .int(kind)? = map["type"], kind == 2,
              case let .object(data)? = map["data"],
              let commandName = stringValue(for: "name", in: data) else {
            return nil
        }

        return GatewayInteractionCreateEvent(
            interactionID: interactionID,
            interactionToken: interactionToken,
            commandName: commandName,
            data: data,
            rawMap: map
        )
    }

    private func parseMemberJoinEvent(from raw: DiscordJSON?) -> GatewayMemberJoinEvent? {
        guard case let .object(map)? = raw,
              case let .object(user)? = map["user"],
              let userID = stringValue(for: "id", in: user),
              let guildID = stringValue(for: "guild_id", in: map) else {
            return nil
        }

        let rawUsername = stringValue(for: "global_name", in: user)
            ?? stringValue(for: "username", in: user)
            ?? "Unknown"

        let joinedAt: Date?
        if let dateStr = stringValue(for: "joined_at", in: map) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            joinedAt = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr)
        } else {
            joinedAt = nil
        }

        return GatewayMemberJoinEvent(
            guildID: guildID,
            userID: userID,
            rawUsername: rawUsername,
            joinedAt: joinedAt
        )
    }

    private func parseMemberLeaveEvent(from raw: DiscordJSON?) -> GatewayMemberLeaveEvent? {
        guard case let .object(map)? = raw,
              case let .object(user)? = map["user"],
              let userID = stringValue(for: "id", in: user),
              let guildID = stringValue(for: "guild_id", in: map) else {
            return nil
        }

        let username = stringValue(for: "global_name", in: user)
            ?? stringValue(for: "username", in: user)
            ?? "Unknown"

        return GatewayMemberLeaveEvent(
            guildID: guildID,
            userID: userID,
            username: username
        )
    }

    private func stringValue(for key: String, in map: [String: DiscordJSON]) -> String? {
        if case let .string(value)? = map[key] {
            return value
        }
        return nil
    }
}
