import Foundation

struct VoiceRulePresenceSeed {
    let userID: String
    let channelID: String
}

enum VoiceRuleStateTransition {
    case ignored
    case joined(channelID: String)
    case moved(fromChannelID: String, toChannelID: String, durationSeconds: Int)
    case left(channelID: String, durationSeconds: Int)
}

struct VoiceRuleStateStore {
    private var channelByMemberKey: [String: String] = [:]
    private var joinTimeByMemberKey: [String: Date] = [:]

    mutating func clearAll() {
        channelByMemberKey.removeAll()
        joinTimeByMemberKey.removeAll()
    }

    mutating func seedSnapshot(guildID: String, members: [VoiceRulePresenceSeed], seededAt: Date) {
        for member in members {
            let key = "\(guildID)-\(member.userID)"
            channelByMemberKey[key] = member.channelID
            joinTimeByMemberKey[key] = seededAt
        }
    }

    mutating func applyEvent(
        guildID: String,
        userID: String,
        channelID: String?,
        at now: Date
    ) -> VoiceRuleStateTransition {
        let memberKey = "\(guildID)-\(userID)"
        let previousChannel = channelByMemberKey[memberKey]

        if let newChannel = channelID, previousChannel == nil {
            channelByMemberKey[memberKey] = newChannel
            joinTimeByMemberKey[memberKey] = now
            return .joined(channelID: newChannel)
        }

        if let newChannel = channelID, let previousChannel, previousChannel != newChannel {
            let joinedAt = joinTimeByMemberKey[memberKey] ?? now
            let durationSeconds = Int(now.timeIntervalSince(joinedAt))
            channelByMemberKey[memberKey] = newChannel
            joinTimeByMemberKey[memberKey] = now
            return .moved(fromChannelID: previousChannel, toChannelID: newChannel, durationSeconds: durationSeconds)
        }

        if channelID == nil, let previousChannel {
            let joinedAt = joinTimeByMemberKey[memberKey] ?? now
            let durationSeconds = Int(now.timeIntervalSince(joinedAt))
            channelByMemberKey[memberKey] = nil
            joinTimeByMemberKey[memberKey] = nil
            return .left(channelID: previousChannel, durationSeconds: durationSeconds)
        }

        return .ignored
    }
}
