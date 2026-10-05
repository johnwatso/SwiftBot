import SwiftUI

// MARK: - Command Category

/// Groups the WebUI command catalog.
enum SlashCommandGroup: String, CaseIterable {
    case general = "General"
    case utilities = "Utilities & AI"
    case moderation = "Moderation"
    case infrastructure = "Infrastructure"
    case gaming = "Gaming"

    var color: Color {
        switch self {
        case .general: return .blue
        case .utilities: return .purple
        case .moderation: return .orange
        case .infrastructure: return .cyan
        case .gaming: return .green
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.2.fill"
        case .utilities: return "wand.and.stars"
        case .moderation: return "shield.lefthalf.filled"
        case .infrastructure: return "server.rack"
        case .gaming: return "gamecontroller.fill"
        }
    }

    /// Wiki lookups and anything new land in Utilities until mapped here.
    static func forCommand(_ name: String) -> SlashCommandGroup {
        switch name.lowercased() {
        case "help", "ping", "userinfo", "weekly":
            return .general
        case "debug", "ignorechannel", "setchannel", "notifystatus", "sweep":
            return .moderation
        case "cluster", "miner":
            return .infrastructure
        case "compare", "meta", "steam":
            return .gaming
        default:
            return .utilities
        }
    }

    static func symbol(forCommand name: String) -> String {
        switch name.lowercased() {
        case "help": return "questionmark.circle.fill"
        case "ping": return "antenna.radiowaves.left.and.right"
        case "roll": return "dice.fill"
        case "8ball": return "circle.hexagongrid.fill"
        case "poll": return "chart.bar.fill"
        case "userinfo": return "person.crop.circle.fill"
        case "cluster": return "network"
        case "debug": return "stethoscope"
        case "notifystatus": return "bell.badge.fill"
        case "setchannel": return "gearshape.fill"
        case "ignorechannel": return "speaker.slash.fill"
        case "weekly": return "calendar.badge.clock"
        case "image": return "photo.fill"
        case "music": return "music.note"
        case "playlist": return "list.bullet"
        case "miner": return "hammer.fill"
        case "compare": return "square.split.2x1"
        case "meta": return "crown.fill"
        case "steam": return "gamecontroller.fill"
        case "timestamp": return "clock.fill"
        case "announce": return "speaker.wave.2.bubble.fill"
        case "randomteams": return "person.3.sequence.fill"
        case "rewind": return "clock.arrow.circlepath"
        case "replay": return "play.rectangle.on.rectangle"
        case "sweep": return "rectangle.stack.fill.badge.minus"
        default: return "rectangle.and.text.magnifyingglass"
        }
    }
}

// MARK: - Visual Command

// MARK: - Command Control Center

// MARK: - Command Section

// MARK: - Command Row

// MARK: - Command Badge

