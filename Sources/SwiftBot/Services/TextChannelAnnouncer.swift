import Foundation
import OSLog

/// Per-config message-content filters applied before a message is spoken.
/// Resolved from the active `AnnouncerVoiceChannelConfig` and passed into
/// `TextChannelAnnouncer.handle`.
struct AnnouncerReadOptions: Sendable {
    var ignoreLinks: Bool = true
    var summariseLong: Bool = false
    var keepShort: Bool = false
    var smartShortenWithAppleIntelligence: Bool = false
    var smartShortener: (@Sendable (String) async -> String?)? = nil
    var ignoreEmojiSpam: Bool = false
}

private enum SmartShortenResultState: Sendable {
    case pending
    case complete(String?)
}

private actor SmartShortenResult {
    private var current: SmartShortenResultState = .pending

    func complete(_ value: String?) {
        if case .pending = current {
            current = .complete(value)
        }
    }

    func state() -> SmartShortenResultState {
        current
    }
}

/// Watches a single text channel and enqueues each new message into a
/// `VoiceAnnouncementService` to be spoken aloud. Applies the formatting and
/// filtering rules:
/// - Format: "Author: text"
/// - Skip messages longer than 300 characters (or shorten them when the config
///   opts into `summariseLong`)
/// - Optionally strip links, skip emoji spam, and keep announcements short
/// - Skip pure link / attachment messages, but read the first embed title
///   when present.
actor TextChannelAnnouncer {
    private static let logger = Logger(subsystem: "com.swiftbot", category: "voice.announcer.text")
    private static let maxLength = 300
    private static let shortCap = 160
    private static let summaryCap = 220

    private let announcer: VoiceAnnouncementService
    private var watchedChannelIDs: Set<String> = []

    init(announcer: VoiceAnnouncementService) {
        self.announcer = announcer
    }

    func setWatchedChannel(_ channelID: String?) {
        if let channelID {
            watchedChannelIDs = [channelID]
        } else {
            watchedChannelIDs = []
        }
    }

    func setWatchedChannels(_ channelIDs: [String]) {
        watchedChannelIDs = Set(channelIDs)
    }

    var watchedChannels: Set<String> { watchedChannelIDs }

    /// Hook to call from `GatewayEventDispatcher.onMessageCreate`. `channelNames`
    /// / `roleNames` (id → name) let `<#id>` / `<@&id>` resolve to real names.
    func handle(
        _ event: GatewayMessageCreateEvent,
        displayNameOverride: String? = nil,
        channelNames: [String: String] = [:],
        roleNames: [String: String] = [:],
        options: AnnouncerReadOptions = AnnouncerReadOptions()
    ) async {
        guard watchedChannelIDs.contains(event.channelID) else { return }
        guard let spoken = await formattedSpeech(
            for: event, displayNameOverride: displayNameOverride,
            channelNames: channelNames, roleNames: roleNames, options: options
        ) else { return }
        await announcer.enqueue(spoken)
    }

    // MARK: - Formatting

    private func formattedSpeech(
        for event: GatewayMessageCreateEvent,
        displayNameOverride: String?,
        channelNames: [String: String],
        roleNames: [String: String],
        options: AnnouncerReadOptions
    ) async -> String? {
        guard var body = readableBody(
            for: event, channelNames: channelNames, roleNames: roleNames, options: options
        ) else { return nil }

        // Length policy: messages over `maxLength` are skipped unless the config
        // opts to shorten them; `keepShort` tightens the cap for everything. When
        // smart shortening is enabled, Apple Intelligence gets a short chance to
        // rewrite the message before the deterministic fallback caps apply.
        if shouldSmartShorten(body, options: options),
           let smartShortener = options.smartShortener,
           let shortened = await Self.smartShorten(body, using: smartShortener),
           shortened.count < body.count {
            body = shortened
        }
        if body.count > Self.maxLength {
            guard options.summariseLong else { return nil }
            body = Self.truncate(body, to: Self.summaryCap)
        }
        if options.keepShort, body.count > Self.shortCap {
            body = Self.truncate(body, to: Self.shortCap)
        }

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

    private func shouldSmartShorten(_ body: String, options: AnnouncerReadOptions) -> Bool {
        guard options.smartShortenWithAppleIntelligence else { return false }
        if options.keepShort, body.count > Self.shortCap { return true }
        return body.count > Self.maxLength
    }

    private func readableBody(
        for event: GatewayMessageCreateEvent,
        channelNames: [String: String],
        roleNames: [String: String],
        options: AnnouncerReadOptions
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

        // Skip emoji-dominated spam when the config asks for it.
        if options.ignoreEmojiSpam, Self.isEmojiSpam(content) {
            return nil
        }

        // If the message has visible text, prefer that. URLs are stripped unless
        // the config opts to read links aloud.
        if !content.isEmpty {
            let text = options.ignoreLinks
                ? stripURLs(content).trimmingCharacters(in: .whitespacesAndNewlines)
                : content
            if !text.isEmpty {
                return text
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

    /// Truncate at a word boundary and append an ellipsis.
    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let slice = String(text.prefix(limit))
        if let lastSpace = slice.lastIndex(of: " ") {
            let head = String(slice[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head + "…" }
        }
        return slice.trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func smartShorten(
        _ text: String,
        using shortener: @escaping @Sendable (String) async -> String?
    ) async -> String? {
        let result = SmartShortenResult()
        let task = Task {
            await result.complete(await shortener(text))
        }
        defer { task.cancel() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(900))
        while clock.now < deadline {
            switch await result.state() {
            case .pending:
                try? await Task.sleep(for: .milliseconds(25))
            case let .complete(raw):
                return cleanSmartShortenResult(raw, original: text)
            }
        }
        return nil
    }

    private static func cleanSmartShortenResult(_ raw: String?, original text: String) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count < text.count else { return nil }
        return truncate(cleaned, to: shortCap)
    }

    /// Heuristic: treat a message as emoji spam when it carries many
    /// default-presentation unicode emoji. Conservative threshold to avoid
    /// false positives on the odd reaction emoji.
    private static func isEmojiSpam(_ text: String) -> Bool {
        let emojiCount = text.filter { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
        }.count
        return emojiCount >= 8
    }
}
