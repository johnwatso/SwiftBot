import Foundation

extension AppModel {
    func parseVoiceChannels(from guildMap: [String: DiscordJSON]) -> [GuildVoiceChannel] {
        guard case let .array(channels)? = guildMap["channels"] else { return [] }

        var result: [GuildVoiceChannel] = []
        for channel in channels {
            guard case let .object(channelMap) = channel,
                  case let .string(channelId)? = channelMap["id"],
                  case let .string(channelName)? = channelMap["name"],
                  case let .int(type)? = channelMap["type"]
            else { continue }

            if type == 2 || type == 13 {
                result.append(GuildVoiceChannel(id: channelId, name: channelName))
            }
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func parseTextChannels(from guildMap: [String: DiscordJSON]) -> [GuildTextChannel] {
        guard case let .array(channels)? = guildMap["channels"] else { return [] }

        var result: [GuildTextChannel] = []
        for channel in channels {
            guard case let .object(channelMap) = channel,
                  case let .string(channelId)? = channelMap["id"],
                  case let .string(channelName)? = channelMap["name"],
                  case let .int(type)? = channelMap["type"]
            else { continue }

            if type == 0 || type == 5 {
                result.append(GuildTextChannel(id: channelId, name: channelName))
            }
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func parseRoles(from guildMap: [String: DiscordJSON]) -> [GuildRole] {
        guard case let .array(roles)? = guildMap["roles"] else { return [] }

        var result: [GuildRole] = []
        for role in roles {
            guard case let .object(roleMap) = role,
                  case let .string(roleId)? = roleMap["id"],
                  case let .string(roleName)? = roleMap["name"]
            else { continue }

            if roleName == "@everyone" { continue }
            result.append(GuildRole(id: roleId, name: roleName))
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func parseChannelTypes(from guildMap: [String: DiscordJSON]) -> [String: Int] {
        guard case let .array(channels)? = guildMap["channels"] else { return [:] }

        var result: [String: Int] = [:]
        for channel in channels {
            guard case let .object(channelMap) = channel,
                  case let .string(channelId)? = channelMap["id"],
                  case let .int(type)? = channelMap["type"]
            else { continue }
            result[channelId] = type
        }
        return result
    }
}
