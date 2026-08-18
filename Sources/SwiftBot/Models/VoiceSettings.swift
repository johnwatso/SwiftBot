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

/// A user-requested quiet period for one Announcer voice channel. This lives
/// in settings so an app restart cannot accidentally undo an explicit
/// `/announce disconnect` request.
struct AnnouncerManualHold: Codable, Hashable, Sendable {
    var guildID: String
    var voiceChannelID: String
    var expiresAt: Date

    func isActive(now: Date = Date()) -> Bool {
        now < expiresAt
    }

    func remainingSeconds(now: Date = Date()) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
    }
}

// MARK: - Attribution style

/// How a spoken message credits its author.
enum AnnouncerAttributionStyle: String, CaseIterable, Codable, Hashable {
    /// "John: message" — the colon renders as a short spoken pause.
    case name = "name"
    /// "John says message" — matches the phrasing of Discord's built-in TTS.
    case nameSays = "nameSays"
    /// Message only, no author.
    case off = "off"

    var displayName: String {
        switch self {
        case .name: return "Name"
        case .nameSays: return "Name says"
        case .off: return "Off"
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
    /// Use on-device Apple Intelligence to rewrite long/noisy messages into a
    /// short spoken sentence when available, falling back to deterministic caps.
    var smartShortenWithAppleIntelligence: Bool = false
    /// Skip messages that are mostly emoji.
    var ignoreEmojiSpam: Bool               = false
    /// Avoid repeating one person's name for every read in a solo stretch.
    /// The name returns after another person speaks or two minutes of quiet.
    var suppressRepeatedSpeakerNames: Bool  = true
    /// Per-rule TTS voice (AVSpeechSynthesisVoice identifier). Empty falls back
    /// to the global preferred voice, then the best available English voice.
    var preferredVoiceIdentifier: String    = ""
    var connectionMode: AnnouncerConnectionMode = .fixed
    var connectionMinutes: Int              = 20
    /// When using Until last person leaves, wait briefly for a member to come
    /// back before leaving. Reads are paused during this quiet grace period.
    var emptyChannelGraceSeconds: Int       = 30
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
        smartShortenWithAppleIntelligence: Bool = false,
        ignoreEmojiSpam: Bool = false,
        suppressRepeatedSpeakerNames: Bool = true,
        preferredVoiceIdentifier: String = "",
        connectionMode: AnnouncerConnectionMode = .fixed,
        connectionMinutes: Int = 20,
        emptyChannelGraceSeconds: Int = 30,
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
        self.smartShortenWithAppleIntelligence = smartShortenWithAppleIntelligence
        self.ignoreEmojiSpam = ignoreEmojiSpam
        self.suppressRepeatedSpeakerNames = suppressRepeatedSpeakerNames
        self.preferredVoiceIdentifier = preferredVoiceIdentifier
        self.connectionMode = connectionMode
        self.connectionMinutes = connectionMinutes
        self.emptyChannelGraceSeconds = emptyChannelGraceSeconds
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
        case smartShortenWithAppleIntelligence
        case ignoreEmojiSpam
        case suppressRepeatedSpeakerNames
        case preferredVoiceIdentifier
        case connectionMode
        case connectionMinutes
        case emptyChannelGraceSeconds
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
        smartShortenWithAppleIntelligence = try container.decodeIfPresent(Bool.self, forKey: .smartShortenWithAppleIntelligence) ?? false
        ignoreEmojiSpam = try container.decodeIfPresent(Bool.self, forKey: .ignoreEmojiSpam) ?? false
        suppressRepeatedSpeakerNames = try container.decodeIfPresent(Bool.self, forKey: .suppressRepeatedSpeakerNames) ?? true
        preferredVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .preferredVoiceIdentifier) ?? ""
        connectionMode = try container.decodeIfPresent(AnnouncerConnectionMode.self, forKey: .connectionMode) ?? .fixed
        connectionMinutes = try container.decodeIfPresent(Int.self, forKey: .connectionMinutes) ?? 20
        emptyChannelGraceSeconds = try container.decodeIfPresent(Int.self, forKey: .emptyChannelGraceSeconds) ?? 30
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
    /// Empty means "best automatic English voice" (Ryan Piper, any Piper, Premium, then Enhanced).
    var preferredVoiceIdentifier: String = ""

    /// Whether the text-channel announcement source is enabled.
    var textChannelSourceEnabled: Bool = false

    /// Whether the service should auto-connect to the configured voice
    /// channel when the bot starts up.
    var autoConnect: Bool = false

    /// Per-voice-channel announcer configurations created in the Announcer tab.
    var announcerConfigs: [AnnouncerVoiceChannelConfig] = []

    /// Suppresses automatic joins and recovery for one explicitly disconnected
    /// Announcer until the time expires or a user manually joins/rejoins it.
    var manualAnnouncerHold: AnnouncerManualHold?

    init() {}

    enum CodingKeys: String, CodingKey {
        case guildID
        case voiceChannelID
        case watchedTextChannelID
        case preferredVoiceIdentifier
        case textChannelSourceEnabled
        case autoConnect
        case announcerConfigs
        case manualAnnouncerHold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try container.decodeIfPresent(String.self, forKey: .guildID) ?? ""
        voiceChannelID = try container.decodeIfPresent(String.self, forKey: .voiceChannelID) ?? ""
        watchedTextChannelID = try container.decodeIfPresent(String.self, forKey: .watchedTextChannelID) ?? ""
        preferredVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .preferredVoiceIdentifier) ?? ""
        textChannelSourceEnabled = try container.decodeIfPresent(Bool.self, forKey: .textChannelSourceEnabled) ?? false
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
        announcerConfigs = try container.decodeIfPresent([AnnouncerVoiceChannelConfig].self, forKey: .announcerConfigs) ?? []
        manualAnnouncerHold = try container.decodeIfPresent(AnnouncerManualHold.self, forKey: .manualAnnouncerHold)
    }
}
