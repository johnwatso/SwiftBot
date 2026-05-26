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
    var connectionMode: AnnouncerConnectionMode = .fixed
    var connectionMinutes: Int              = 20
    var textChannels: [String]              = []
    var enabled: Bool                       = true
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
