import Foundation

struct DiscordCacheSnapshot: Codable, Hashable {
    var updatedAt = Date()
    var connectedServers: [String: String] = [:]
    var availableVoiceChannelsByServer: [String: [GuildVoiceChannel]] = [:]
    var availableTextChannelsByServer: [String: [GuildTextChannel]] = [:]
    var availableRolesByServer: [String: [GuildRole]] = [:]
    var usernamesById: [String: String] = [:]
    var channelTypesById: [String: Int] = [:]

    private enum CodingKeys: String, CodingKey {
        case updatedAt
        case connectedServers
        case availableVoiceChannelsByServer
        case availableTextChannelsByServer
        case availableRolesByServer
        case usernamesById
        case channelTypesById
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        connectedServers = try container.decodeIfPresent([String: String].self, forKey: .connectedServers) ?? [:]
        availableVoiceChannelsByServer = try container.decodeIfPresent([String: [GuildVoiceChannel]].self, forKey: .availableVoiceChannelsByServer) ?? [:]
        availableTextChannelsByServer = try container.decodeIfPresent([String: [GuildTextChannel]].self, forKey: .availableTextChannelsByServer) ?? [:]
        availableRolesByServer = try container.decodeIfPresent([String: [GuildRole]].self, forKey: .availableRolesByServer) ?? [:]
        usernamesById = try container.decodeIfPresent([String: String].self, forKey: .usernamesById) ?? [:]
        channelTypesById = try container.decodeIfPresent([String: Int].self, forKey: .channelTypesById) ?? [:]
    }
}

actor DiscordCache {
    private var snapshot: DiscordCacheSnapshot
    private var updateContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(snapshot: DiscordCacheSnapshot = DiscordCacheSnapshot()) {
        self.snapshot = snapshot
    }

    var updates: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            updateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeUpdateContinuation(id) }
            }
        }
    }

    func replace(with snapshot: DiscordCacheSnapshot) {
        self.snapshot = snapshot
        emitUpdate()
    }

    func currentSnapshot() -> DiscordCacheSnapshot {
        var copy = snapshot
        copy.updatedAt = Date()
        return copy
    }

    func guildName(for guildID: String) -> String? {
        snapshot.connectedServers[guildID]
    }

    func userName(for userID: String) -> String? {
        snapshot.usernamesById[userID]
    }

    func channelName(for channelID: String) -> String? {
        for channels in snapshot.availableTextChannelsByServer.values {
            if let channel = channels.first(where: { $0.id == channelID }) {
                return channel.name
            }
        }
        for channels in snapshot.availableVoiceChannelsByServer.values {
            if let channel = channels.first(where: { $0.id == channelID }) {
                return channel.name
            }
        }
        return nil
    }

    func channelType(for channelID: String) -> Int? {
        snapshot.channelTypesById[channelID]
    }

    func setChannelType(channelID: String, type: Int) {
        snapshot.channelTypesById[channelID] = type
        emitUpdate()
    }

    func mergeChannelTypes(_ channelTypes: [String: Int]) {
        guard !channelTypes.isEmpty else { return }
        var didChange = false
        for (channelID, type) in channelTypes {
            if snapshot.channelTypesById[channelID] != type {
                snapshot.channelTypesById[channelID] = type
                didChange = true
            }
        }
        if didChange {
            emitUpdate()
        }
    }

    func allGuildNames() -> [String: String] {
        snapshot.connectedServers
    }

    func voiceChannelsByGuild() -> [String: [GuildVoiceChannel]] {
        snapshot.availableVoiceChannelsByServer
    }

    func textChannelsByGuild() -> [String: [GuildTextChannel]] {
        snapshot.availableTextChannelsByServer
    }

    func rolesByGuild() -> [String: [GuildRole]] {
        snapshot.availableRolesByServer
    }

    func allUserNames() -> [String: String] {
        snapshot.usernamesById
    }

    func upsertGuild(id guildID: String, name: String?) {
        let fallback = "Server \(guildID.suffix(4))"
        let candidate = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !candidate.isEmpty {
            if snapshot.connectedServers[guildID] != candidate {
                snapshot.connectedServers[guildID] = candidate
                emitUpdate()
            }
            return
        }

        // Preserve any known guild name when only an ID is available.
        if snapshot.connectedServers[guildID] == nil {
            snapshot.connectedServers[guildID] = fallback
            emitUpdate()
        }
    }

    func removeGuild(id guildID: String) {
        let textChannels = snapshot.availableTextChannelsByServer[guildID] ?? []
        let voiceChannels = snapshot.availableVoiceChannelsByServer[guildID] ?? []
        for channel in textChannels {
            snapshot.channelTypesById[channel.id] = nil
        }
        for channel in voiceChannels {
            snapshot.channelTypesById[channel.id] = nil
        }
        snapshot.connectedServers[guildID] = nil
        snapshot.availableVoiceChannelsByServer[guildID] = nil
        snapshot.availableTextChannelsByServer[guildID] = nil
        snapshot.availableRolesByServer[guildID] = nil
        emitUpdate()
    }

    func setGuildVoiceChannels(guildID: String, channels: [GuildVoiceChannel]) {
        let oldChannels = snapshot.availableVoiceChannelsByServer[guildID] ?? []
        for channel in oldChannels {
            snapshot.channelTypesById[channel.id] = nil
        }
        snapshot.availableVoiceChannelsByServer[guildID] = channels
        for channel in channels {
            snapshot.channelTypesById[channel.id] = 2
        }
        emitUpdate()
    }

    func setGuildTextChannels(guildID: String, channels: [GuildTextChannel]) {
        let oldChannels = snapshot.availableTextChannelsByServer[guildID] ?? []
        for channel in oldChannels {
            snapshot.channelTypesById[channel.id] = nil
        }
        snapshot.availableTextChannelsByServer[guildID] = channels
        for channel in channels {
            snapshot.channelTypesById[channel.id] = 0
        }
        emitUpdate()
    }

    func setGuildRoles(guildID: String, roles: [GuildRole]) {
        snapshot.availableRolesByServer[guildID] = roles
        emitUpdate()
    }

    func upsertChannel(guildID: String?, channelID: String, name: String, type: Int) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        snapshot.channelTypesById[channelID] = type

        if type == 1 || type == 3 {
            emitUpdate()
            return
        }
        guard let guildID else {
            emitUpdate()
            return
        }

        if type == 0 || type == 5 {
            var channels = snapshot.availableTextChannelsByServer[guildID] ?? []
            if let index = channels.firstIndex(where: { $0.id == channelID }) {
                channels[index] = GuildTextChannel(id: channelID, name: cleaned)
            } else {
                channels.append(GuildTextChannel(id: channelID, name: cleaned))
            }
            channels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            snapshot.availableTextChannelsByServer[guildID] = channels
            emitUpdate()
            return
        }

        if type == 2 || type == 13 {
            var channels = snapshot.availableVoiceChannelsByServer[guildID] ?? []
            if let index = channels.firstIndex(where: { $0.id == channelID }) {
                channels[index] = GuildVoiceChannel(id: channelID, name: cleaned)
            } else {
                channels.append(GuildVoiceChannel(id: channelID, name: cleaned))
            }
            channels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            snapshot.availableVoiceChannelsByServer[guildID] = channels
            emitUpdate()
        }
    }

    func upsertUser(id userID: String, preferredName: String?) {
        let cleaned = (preferredName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if snapshot.usernamesById[userID] == cleaned { return }
        snapshot.usernamesById[userID] = cleaned
        emitUpdate()
    }

    private func emitUpdate() {
        for continuation in updateContinuations.values {
            continuation.yield(())
        }
    }

    private func removeUpdateContinuation(_ id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }
}
