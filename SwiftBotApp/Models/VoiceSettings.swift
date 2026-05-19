import Foundation

/// Persisted configuration for the Voice tab.
/// Stored as the `voice` substruct on `BotSettings`.
struct VoiceSettings: Codable, Hashable {
    /// Discord guild ID of the server whose voice channel the bot will join.
    var guildID: String = ""

    /// Discord voice channel ID the bot will connect to.
    var voiceChannelID: String = ""

    /// Discord text channel ID the announcer will watch for messages to read.
    var watchedTextChannelID: String = ""

    /// `AVSpeechSynthesisVoice.identifier` of the preferred system voice.
    /// Empty means "best Premium English voice available."
    var preferredVoiceIdentifier: String = ""

    /// Whether the text-channel announcement source is enabled.
    var textChannelSourceEnabled: Bool = false

    /// Whether the service should auto-connect to the configured voice
    /// channel when the bot starts up.
    var autoConnect: Bool = false
}
