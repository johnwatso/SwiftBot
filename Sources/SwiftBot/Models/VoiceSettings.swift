import Foundation
import SwiftUI

// MARK: - Announcer tint palette

/// Named accent colours for voice channel configurations.
/// Stored as a string so it survives Codable round-trips.
enum AnnouncerTint: String, CaseIterable, Codable, Hashable {
    case purple, blue, orange, teal, pink, green, indigo

    var color: Color {
        switch self {
        case .purple: return .purple
        case .blue:   return .blue
        case .orange: return .orange
        case .teal:   return .teal
        case .pink:   return .pink
        case .green:  return .green
        case .indigo: return .indigo
        }
    }
}

// MARK: - Connection mode

enum AnnouncerConnectionMode: String, CaseIterable, Codable, Hashable {
    case fixed      = "fixed"
    case untilEmpty = "untilEmpty"

    var displayName: String {
        switch self {
        case .fixed:      return "Fixed time"
        case .untilEmpty: return "Until last person leaves"
        }
    }
}

// MARK: - Per-channel configuration

struct AnnouncerVoiceChannelConfig: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var voiceChannelID: String              = ""
    var voiceChannelName: String            = "—"
    var symbol: String                      = "speaker.wave.2.bubble.fill"
    var tint: AnnouncerTint                 = .purple
    var autoJoin: Bool                      = false
    var introduceOnManualJoin: Bool         = false
    /// Join automatically when a member starts a Go Live stream in this channel.
    var autoJoinOnStream: Bool              = false
    /// Announce a short stream-specific intro when joining because of a stream.
    var introduceOnStreamJoin: Bool         = false
    /// Read the voice channel's own built-in text chat (Text-in-Voice) — this is
    /// the chat viewers see beside a Go Live stream.
    var readVoiceChannelChat: Bool          = true
    /// When true, messages posted by webhooks/integrations are skipped so only
    /// real server members are read aloud.
    var ignoreWebhooks: Bool                = false
    /// Skip messages authored by bots.
    var skipBots: Bool                      = false
    /// Strip URLs from the spoken text (on by default — reading URLs aloud is noise).
    var ignoreLinks: Bool                   = true
    /// Shorten (truncate) messages over the length cap instead of skipping them.
    var summariseLong: Bool                 = false
    /// Apply a tighter length cap so announcements stay brief.
    var keepShort: Bool                     = false
    /// Skip messages that are mostly emoji.
    var ignoreEmojiSpam: Bool               = false
    /// Per-rule TTS voice (AVSpeechSynthesisVoice identifier). Empty falls back
    /// to the global preferred voice, then the best available English voice.
    var preferredVoiceIdentifier: String    = ""
    var connectionMode: AnnouncerConnectionMode = .fixed
    var connectionMinutes: Int              = 20
    var textChannels: [String]              = []
    var enabled: Bool                       = true

    init(
        id: String,
        name: String,
        voiceChannelID: String = "",
        voiceChannelName: String = "—",
        symbol: String = "speaker.wave.2.bubble.fill",
        tint: AnnouncerTint = .purple,
        autoJoin: Bool = false,
        introduceOnManualJoin: Bool = false,
        autoJoinOnStream: Bool = false,
        introduceOnStreamJoin: Bool = false,
        readVoiceChannelChat: Bool = true,
        ignoreWebhooks: Bool = false,
        skipBots: Bool = false,
        ignoreLinks: Bool = true,
        summariseLong: Bool = false,
        keepShort: Bool = false,
        ignoreEmojiSpam: Bool = false,
        preferredVoiceIdentifier: String = "",
        connectionMode: AnnouncerConnectionMode = .fixed,
        connectionMinutes: Int = 20,
        textChannels: [String] = [],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.voiceChannelID = voiceChannelID
        self.voiceChannelName = voiceChannelName
        self.symbol = symbol
        self.tint = tint
        self.autoJoin = autoJoin
        self.introduceOnManualJoin = introduceOnManualJoin
        self.autoJoinOnStream = autoJoinOnStream
        self.introduceOnStreamJoin = introduceOnStreamJoin
        self.readVoiceChannelChat = readVoiceChannelChat
        self.ignoreWebhooks = ignoreWebhooks
        self.skipBots = skipBots
        self.ignoreLinks = ignoreLinks
        self.summariseLong = summariseLong
        self.keepShort = keepShort
        self.ignoreEmojiSpam = ignoreEmojiSpam
        self.preferredVoiceIdentifier = preferredVoiceIdentifier
        self.connectionMode = connectionMode
        self.connectionMinutes = connectionMinutes
        self.textChannels = textChannels
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case voiceChannelID
        case voiceChannelName
        case symbol
        case tint
        case autoJoin
        case introduceOnManualJoin
        case autoJoinOnStream
        case introduceOnStreamJoin
        case readVoiceChannelChat
        case ignoreWebhooks
        case skipBots
        case ignoreLinks
        case summariseLong
        case keepShort
        case ignoreEmojiSpam
        case preferredVoiceIdentifier
        case connectionMode
        case connectionMinutes
        case textChannels
        case enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        voiceChannelID = try container.decodeIfPresent(String.self, forKey: .voiceChannelID) ?? ""
        voiceChannelName = try container.decodeIfPresent(String.self, forKey: .voiceChannelName) ?? "—"
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "speaker.wave.2.bubble.fill"
        tint = try container.decodeIfPresent(AnnouncerTint.self, forKey: .tint) ?? .purple
        autoJoin = try container.decodeIfPresent(Bool.self, forKey: .autoJoin) ?? false
        introduceOnManualJoin = try container.decodeIfPresent(Bool.self, forKey: .introduceOnManualJoin) ?? false
        autoJoinOnStream = try container.decodeIfPresent(Bool.self, forKey: .autoJoinOnStream) ?? false
        introduceOnStreamJoin = try container.decodeIfPresent(Bool.self, forKey: .introduceOnStreamJoin) ?? false
        readVoiceChannelChat = try container.decodeIfPresent(Bool.self, forKey: .readVoiceChannelChat) ?? true
        ignoreWebhooks = try container.decodeIfPresent(Bool.self, forKey: .ignoreWebhooks) ?? false
        skipBots = try container.decodeIfPresent(Bool.self, forKey: .skipBots) ?? false
        ignoreLinks = try container.decodeIfPresent(Bool.self, forKey: .ignoreLinks) ?? true
        summariseLong = try container.decodeIfPresent(Bool.self, forKey: .summariseLong) ?? false
        keepShort = try container.decodeIfPresent(Bool.self, forKey: .keepShort) ?? false
        ignoreEmojiSpam = try container.decodeIfPresent(Bool.self, forKey: .ignoreEmojiSpam) ?? false
        preferredVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .preferredVoiceIdentifier) ?? ""
        connectionMode = try container.decodeIfPresent(AnnouncerConnectionMode.self, forKey: .connectionMode) ?? .fixed
        connectionMinutes = try container.decodeIfPresent(Int.self, forKey: .connectionMinutes) ?? 20
        textChannels = try container.decodeIfPresent([String].self, forKey: .textChannels) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

// MARK: - VoiceSettings

/// Persisted configuration for the Voice / Announcer tab.
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

    /// Per-voice-channel announcer configurations created in the Announcer tab.
    var announcerConfigs: [AnnouncerVoiceChannelConfig] = []
}
