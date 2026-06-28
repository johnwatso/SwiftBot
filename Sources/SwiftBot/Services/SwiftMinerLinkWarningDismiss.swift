import Foundation

// MARK: - SwiftMiner "Needs Linking" Dismiss Parsing
//
// Pure, testable logic for recognising when a user replies to a
// "🔗 Link Twitch for {game}" DM with a dismiss intent ("ignore", "dismiss",
// etc.) and extracting which game to mute. The raw Discord payload extraction
// (reading the referenced message's embed title) lives in AppModel; this type
// only handles the text matching so it can be unit-tested in isolation.

enum SwiftMinerLinkWarningDismiss {

    /// Keywords (as the whole reply, or its first word) that mean "stop these".
    static let keywords: Set<String> = [
        "ignore", "dismiss", "stop", "mute", "unsubscribe", "unsub", "disable", "off"
    ]

    /// Marker inside the needs-linking embed title ("🔗 Link Twitch for {game}").
    /// Matched as a substring so a debug "[TEST] " prefix doesn't break it.
    static let titleMarker = "Link Twitch for "

    /// Whether the reply text expresses a dismiss intent.
    static func isDismissIntent(_ content: String) -> Bool {
        let normalized = content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return keywords.contains { normalized == $0 || normalized.hasPrefix($0 + " ") }
    }

    /// Extracts the game name from a needs-linking embed title, or nil if the
    /// title isn't one of ours.
    static func game(fromNeedsLinkingTitle title: String) -> String? {
        guard let range = title.range(of: titleMarker) else { return nil }
        let game = title[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return game.isEmpty ? nil : String(game)
    }

    /// Returns the game to dismiss when the reply is a dismiss intent against a
    /// needs-linking embed title; nil otherwise.
    static func gameToDismiss(replyContent: String, referencedEmbedTitle: String?) -> String? {
        guard isDismissIntent(replyContent), let title = referencedEmbedTitle else { return nil }
        return game(fromNeedsLinkingTitle: title)
    }
}
