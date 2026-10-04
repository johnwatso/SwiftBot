import Foundation

// MARK: - Rewind presence archive and server journal
//
// Rewind keeps as much of the server as the gateway hands SwiftBot: members'
// rich presence while they are in voice (Spotify aside) and every server event
// no other store models. It follows Rewind's master switch and channel filter,
// and covers everyone in the server — there is no per-member opt-in.

extension AppModel {

    /// Hands one presence update to the archive, which records it only if the
    /// member is in voice. Called for every member, ahead of Game Tracker's own
    /// linked-player filter.
    func recordRewindPresence(_ event: GatewayPresenceUpdateEvent) {
        guard settings.rewind.isEnabled else { return }
        let store = rewindActivityStore
        let now = Date()
        Task.detached(priority: .utility) {
            await store.record(presence: event, now: now)
        }
    }

    /// Journals one raw gateway dispatch.
    func recordRewindGatewayEvent(name: String, payload: DiscordJSON?) {
        let settings = self.settings.rewind
        guard settings.isEnabled, case let .object(map)? = payload else { return }

        // GUILD_CREATE isn't journaled (it is the whole guild), but its
        // `presences` and `voice_states` say what everyone was doing, and who
        // was in voice, when the bot connected.
        if name == "GUILD_CREATE" {
            seedRewindPresences(from: map)
            return
        }
        if name == "VOICE_STATE_UPDATE",
           case let .string(guildID)? = map["guild_id"],
           case let .string(userID)? = map["user_id"] {
            let channelID: String? = { if case let .string(id)? = map["channel_id"] { return id } else { return nil } }()
            let store = rewindActivityStore
            let now = Date()
            Task.detached(priority: .utility) {
                await store.voiceStateChanged(guildID: guildID, userID: userID, channelID: channelID, now: now)
            }
        }
        guard !RewindJournal.excludedEvents.contains(name) else { return }

        let guildID: String
        if case let .string(value)? = map["guild_id"] {
            guildID = value
        } else if name == "GUILD_UPDATE", case let .string(value)? = map["id"] {
            guildID = value
        } else {
            return // DMs and global events
        }

        if let channelID = Self.rewindChannelID(in: map, event: name), !settings.collects(channelID: channelID) {
            return
        }
        if name == "MESSAGE_UPDATE", case let .object(author)? = map["author"] {
            var isBot = false
            if case .bool(true)? = author["bot"] { isBot = true }
            if case .string? = map["webhook_id"] { isBot = true }
            let authorID: String = { if case let .string(id)? = author["id"] { return id } else { return "" } }()
            guard settings.collects(userID: authorID, isBot: isBot) else { return }
        }

        var payloadMap = map
        if !settings.retainMessageContent {
            for key in RewindJournal.contentKeys { payloadMap.removeValue(forKey: key) }
        }

        let entry = RewindJournalEntry(event: name, guildID: guildID, receivedAt: Date(), payload: .object(payloadMap))
        let store = rewindActivityStore
        Task.detached(priority: .utility) {
            await store.record(entry)
        }
    }

    private func seedRewindPresences(from guild: [String: DiscordJSON]) {
        guard case let .string(guildID)? = guild["id"] else { return }
        var events: [GatewayPresenceUpdateEvent] = []
        if case let .array(presences)? = guild["presences"] {
            events = presences.compactMap { entry in
                guard case let .object(map) = entry else { return nil }
                return GatewayEventDispatcher.parsePresence(map, guildID: guildID)
            }
        }
        var voiceUserIDs: Set<String> = []
        if case let .array(states)? = guild["voice_states"] {
            for case let .object(state) in states {
                if case let .string(userID)? = state["user_id"], case .string? = state["channel_id"] {
                    voiceUserIDs.insert(userID)
                }
            }
        }
        let store = rewindActivityStore
        let now = Date()
        Task.detached(priority: .utility) {
            await store.seedGuild(guildID: guildID, presences: events, voiceUserIDs: voiceUserIDs, now: now)
        }
    }

    /// The channel an event belongs to, for the ignored-channels filter. A
    /// thread is filtered by its parent as well as by itself.
    private static func rewindChannelID(in map: [String: DiscordJSON], event: String) -> String? {
        if event.hasPrefix("CHANNEL_") || event.hasPrefix("THREAD_") {
            if case let .string(parent)? = map["parent_id"] { return parent }
            if case let .string(id)? = map["id"] { return id }
        }
        if case let .string(id)? = map["channel_id"] { return id }
        return nil
    }

    // MARK: Lifecycle

    func startRewindActivityIfNeeded() {
        guard settings.rewind.isEnabled else { return }
        let store = rewindActivityStore
        Task.detached(priority: .utility) {
            await store.start()
        }
    }

    func stopRewindActivity() async {
        await rewindActivityStore.stop()
    }
}
