import Foundation

enum VoicePresenceTransition {
    case ignored
    case unchanged
    case joined(next: VoiceMemberPresence)
    case moved(previous: VoiceMemberPresence, next: VoiceMemberPresence, startedAt: Date)
    case left(previous: VoiceMemberPresence, startedAt: Date)
}

actor VoicePresenceStore {
    private var activeVoice: [VoiceMemberPresence] = []
    private var joinTimes: [String: Date] = [:]

    func replaceAll(with members: [VoiceMemberPresence]) -> [VoiceMemberPresence] {
        activeVoice = members
        joinTimes = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.joinedAt) })
        return activeVoice
    }

    func clearAll() -> [VoiceMemberPresence] {
        activeVoice.removeAll()
        joinTimes.removeAll()
        return activeVoice
    }

    func clearGuild(_ guildID: String) -> [VoiceMemberPresence] {
        activeVoice.removeAll { $0.guildId == guildID }
        joinTimes = joinTimes.filter { !$0.key.hasPrefix("\(guildID)-") }
        return activeVoice
    }

    func syncGuildSnapshot(_ guildID: String, members: [VoiceMemberPresence]) -> [VoiceMemberPresence] {
        activeVoice.removeAll { $0.guildId == guildID }
        joinTimes = joinTimes.filter { !$0.key.hasPrefix("\(guildID)-") }
        activeVoice.append(contentsOf: members)
        for member in members {
            joinTimes[member.id] = member.joinedAt
        }
        return activeVoice
    }

    func applyVoiceStateUpdate(
        guildID: String,
        userID: String,
        displayName: String,
        channelID: String?,
        channelName: String,
        now: Date
    ) -> VoicePresenceTransition {
        let key = "\(guildID)-\(userID)"
        let previous = activeVoice.first { $0.userId == userID && $0.guildId == guildID }

        if let newChannel = channelID {
            if let previous, previous.channelId == newChannel {
                return .unchanged
            }

            let next = VoiceMemberPresence(
                id: key,
                userId: userID,
                username: displayName,
                guildId: guildID,
                channelId: newChannel,
                channelName: channelName,
                joinedAt: joinTimes[key] ?? now
            )

            if let previous {
                let startedAt = joinTimes[key] ?? previous.joinedAt
                activeVoice.removeAll { $0.id == previous.id }
                activeVoice.append(next)
                return .moved(previous: previous, next: next, startedAt: startedAt)
            }

            joinTimes[key] = now
            activeVoice.append(next)
            return .joined(next: next)
        }

        guard let previous else {
            return .ignored
        }

        let startedAt = joinTimes[key] ?? previous.joinedAt
        activeVoice.removeAll { $0.id == previous.id }
        joinTimes[key] = nil
        return .left(previous: previous, startedAt: startedAt)
    }

    func snapshot() -> [VoiceMemberPresence] {
        activeVoice
    }
}
