import Foundation

@MainActor
extension AppModel {
    func replaceVoicePresence(_ members: [VoiceMemberPresence]) async {
        activeVoice = await voicePresenceStore.replaceAll(with: members)
    }

    func clearVoicePresence() async {
        activeVoice = await voicePresenceStore.clearAll()
    }

    func clearVoicePresence(guildID: String) async {
        activeVoice = await voicePresenceStore.clearGuild(guildID)
    }
}
