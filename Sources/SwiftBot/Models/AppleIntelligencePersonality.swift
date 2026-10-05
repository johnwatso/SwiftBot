import SwiftUI

/// Starting points for the reply instructions. Each sounds clearly
/// different: Casual chats, Helpful works through problems, Playful banters.
/// Anything else is a custom prompt.
enum AppleIntelligencePersonality: String, CaseIterable, Identifiable {
    case casual
    case helpful
    case playful

    var id: String { rawValue }

    var title: String {
        switch self {
        case .casual: return "Casual"
        case .helpful: return "Helpful"
        case .playful: return "Playful"
        }
    }

    var summaryValue: String {
        switch self {
        case .casual: return "Short and chatty"
        case .helpful: return "Step by step"
        case .playful: return "Banter and emoji"
        }
    }

    var symbol: String {
        switch self {
        case .casual: return "face.smiling.fill"
        case .helpful: return "lifepreserver.fill"
        case .playful: return "party.popper.fill"
        }
    }

    var tint: Color {
        switch self {
        case .casual: return .green
        case .helpful: return .blue
        case .playful: return .pink
        }
    }

    var description: String {
        switch self {
        case .casual:
            return "Hangs out like another member of the server. The default."
        case .helpful:
            return "Answers questions properly, with numbered steps when there are some."
        case .playful:
            return "Quick wit and light teasing, but still helps when someone needs it."
        }
    }

    var preview: String {
        switch self {
        case .casual:
            return "Ha, yeah, the patch nerfed it. Try the shotgun instead."
        case .helpful:
            return "Two things to check: 1) SwiftBot can see the channel, 2) the command is on."
        case .playful:
            return "Bold of you to ask me that after going 2–14 last night 💀"
        }
    }

    var prompt: String {
        switch self {
        case .casual:
            return BotSettings.defaultAISystemPrompt
        case .helpful:
            return "You are a helpful Discord bot for answering questions and solving problems. " +
                "Give clear, accurate answers. When there are steps, number them and keep each one short. " +
                "If something important is missing, ask one short question instead of guessing. " +
                "Skip small talk and don't pad replies."
        case .playful:
            return "You are a playful Discord bot with a quick wit. Banter with people, tease them lightly " +
                "when it fits, and use the occasional emoji. Keep replies short and punchy, 1 to 2 sentences. " +
                "Never be mean, rude or offensive, and still give a real answer when someone actually needs help."
        }
    }

    /// The preset these instructions are, or nil for a custom prompt.
    static func matching(prompt: String) -> AppleIntelligencePersonality? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
    }
}

