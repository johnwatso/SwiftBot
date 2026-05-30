import Foundation
import OSLog

/// Watches a single text channel and enqueues each new message into a
/// `VoiceAnnouncementService` to be spoken aloud. Applies the formatting and
/// filtering rules:
/// - Format: "Author: text"
/// - Skip messages longer than 300 characters
/// - Skip pure link / attachment messages, but read the first embed title
///   when present.
actor TextChannelAnnouncer {
    private static let logger = Logger(subsystem: "com.swiftbot", category: "voice.announcer.text")
    private static let maxLength = 300

    private let announcer: VoiceAnnouncementService
    private var watchedChannelID: String?

    init(announcer: VoiceAnnouncementService) {
        self.announcer = announcer
    }

    func setWatchedChannel(_ channelID: String?) {
        watchedChannelID = channelID
    }

    var watchedChannel: String? { watchedChannelID }

    /// Hook to call from `GatewayEventDispatcher.onMessageCreate`. `channelNames`
    /// / `roleNames` (id → name) let `<#id>` / `<@&id>` resolve to real names.
    func handle(
        _ event: GatewayMessageCreateEvent,
        displayNameOverride: String? = nil,
        channelNames: [String: String] = [:],
        roleNames: [String: String] = [:]
    ) async {
        guard let watched = watchedChannelID, event.channelID == watched else { return }
        guard let spoken = formattedSpeech(
            for: event, displayNameOverride: displayNameOverride,
            channelNames: channelNames, roleNames: roleNames
        ) else { return }
        await announcer.enqueue(spoken)
    }

    // MARK: - Formatting

    private func formattedSpeech(
        for event: GatewayMessageCreateEvent,
        displayNameOverride: String?,
        channelNames: [String: String],
        roleNames: [String: String]
    ) -> String? {
        let body = readableBody(for: event, channelNames: channelNames, roleNames: roleNames)
        guard let body, !body.isEmpty else { return nil }
        guard body.count <= Self.maxLength else { return nil }
        let override = displayNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = if !override.isEmpty {
            override
        } else if !event.displayName.isEmpty {
            event.displayName
        } else {
            "Someone"
        }
        return "\(author): \(body)"
    }

    private func readableBody(
        for event: GatewayMessageCreateEvent,
        channelNames: [String: String],
        roleNames: [String: String]
    ) -> String? {
        // Convert raw Discord markup (mentions, custom emoji, timestamps) into
        // human-readable text so it's both spoken and logged cleanly.
        let humanized = DiscordService.humanizeContent(
            event.content,
            mentionNames: DiscordService.mentionNames(from: event.rawMap),
            channelNames: channelNames,
            roleNames: roleNames
        )
        let content = humanized.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the message has visible non-link text, prefer that.
        if !content.isEmpty {
            let stripped = stripURLs(content).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }

        // No usable text — try the first embed title (e.g. link previews).
        if case let .array(embeds)? = event.rawMap["embeds"],
           let first = embeds.first,
           case let .object(embedMap) = first,
           case let .string(title)? = embedMap["title"] {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                return trimmedTitle
            }
        }

        return nil
    }

    private func stripURLs(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let mutable = NSMutableString(string: text)
        let matches = detector.matches(in: text, options: [], range: range).reversed()
        for match in matches {
            mutable.replaceCharacters(in: match.range, with: "")
        }
        return (mutable as String)
    }
}
