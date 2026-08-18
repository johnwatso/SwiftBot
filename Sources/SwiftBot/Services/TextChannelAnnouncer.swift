import Foundation
import OSLog

/// Per-config message-content filters applied before a message is spoken.
/// Resolved from the active `AnnouncerVoiceChannelConfig` and passed into
/// `TextChannelAnnouncer.handle`.
struct AnnouncerReadOptions: Sendable {
    var ignoreLinks: Bool = true
    var summariseLong: Bool = false
    var keepShort: Bool = false
    var ignoreEmojiSpam: Bool = false
    /// Say a speaker's name once, then omit it for consecutive reads from that
    /// same person until another speaker takes over or the conversation goes
    /// quiet for the configured interval.
    var suppressRepeatedSpeakerNames: Bool = true
    var repeatedSpeakerNameTimeout: TimeInterval = 120
}

/// Watches a single text channel and enqueues each new message into a
/// `VoiceAnnouncementService` to be spoken aloud. Applies the formatting and
/// filtering rules:
/// - Format: "Author: text"
/// - Skip messages longer than `maxLength` (or trim them to a spoken cue when
///   the config opts into `summariseLong`)
/// - Optionally strip links, skip emoji spam, and keep announcements short
/// - Skip pure link / attachment messages, but read the first embed title
///   when present.
actor TextChannelAnnouncer {
    private static let logger = Logger(subsystem: "com.swiftbot", category: "voice.announcer.text")
    /// ~1000 characters is roughly a minute of continuous speech. Ordinary
    /// announcements read in full; only a pasted wall of text is trimmed, so
    /// one message can't hold the channel for several minutes.
    private static let maxLength = 1000
    private static let summaryCap = 1000
    /// `keepShort` is a deliberate opt-in to brief reads, so it keeps its own
    /// much tighter cap.
    private static let shortCap = 160
    /// Spoken so listeners can tell a trimmed read from a finished one — a
    /// bare ellipsis is silent, which is what made truncation sound like the
    /// announcer had cut out mid-sentence.
    private static let truncationCue = ", message continues"

    private let announcer: VoiceAnnouncementService
    private var watchedChannelIDs: Set<String> = []
    /// Surfaces why a watched-channel message was NOT read (length cap,
    /// emoji spam, link-only, …). Without this, a filtered message and a
    /// broken announcer look identical from the outside.
    private var onDebug: (@Sendable (String) async -> Void)?
    private var lastSpokenAuthorID: String?
    private var lastSpokenAuthorAt: Date?

    init(announcer: VoiceAnnouncementService) {
        self.announcer = announcer
    }

    func setOnDebug(_ handler: @escaping @Sendable (String) async -> Void) {
        onDebug = handler
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

    func resetSpeakerAttribution() {
        lastSpokenAuthorID = nil
        lastSpokenAuthorAt = nil
    }

    var watchedChannels: Set<String> { watchedChannelIDs }

    /// Hook to call from `GatewayEventDispatcher.onMessageCreate`. `channelNames`
    /// / `roleNames` (id → name) let `<#id>` / `<@&id>` resolve to real names.
    func handle(
        _ event: GatewayMessageCreateEvent,
        displayNameOverride: String? = nil,
        channelNames: [String: String] = [:],
        roleNames: [String: String] = [:],
        options: AnnouncerReadOptions = AnnouncerReadOptions(),
        now: Date = Date()
    ) async {
        guard watchedChannelIDs.contains(event.channelID) else { return }
        switch speechDecision(
            for: event, displayNameOverride: displayNameOverride,
            channelNames: channelNames, roleNames: roleNames, options: options
        ) {
        case let .speak(body, author, authorID):
            let spoken = formatAnnouncement(
                body: body,
                author: author,
                authorID: authorID,
                options: options,
                now: now
            )
            await announcer.enqueue(spoken)
        case .skip(let reason):
            let author = event.displayName.isEmpty ? "someone" : event.displayName
            await onDebug?("Announcer skipped a message from \(author): \(reason)")
        }
    }

    // MARK: - Formatting

    private enum SpeechDecision {
        case speak(body: String, author: String, authorID: String)
        case skip(reason: String)
    }

    private func speechDecision(
        for event: GatewayMessageCreateEvent,
        displayNameOverride: String?,
        channelNames: [String: String],
        roleNames: [String: String],
        options: AnnouncerReadOptions
    ) -> SpeechDecision {
        var body: String
        switch readableBody(
            for: event, channelNames: channelNames, roleNames: roleNames, options: options
        ) {
        case .body(let value):
            body = value
        case .skip(let reason):
            return .skip(reason: reason)
        }

        // Length policy: messages over `maxLength` are skipped unless the config
        // opts to shorten them; `keepShort` tightens the cap for everything.
        // Shortening is deterministic on purpose. An on-device Apple
        // Intelligence rewrite of a message this size measures at 5-8 s on
        // release hardware, which is far longer than the whole read should
        // take, so nothing in this path is allowed to await a model.
        if body.count > Self.maxLength {
            guard options.summariseLong else {
                return .skip(reason: "it is \(body.count) characters — over the \(Self.maxLength)-character reading cap. Enable \"Shorten long messages\" in the announcer configuration to read a shortened version.")
            }
            body = Self.truncateForSpeech(body, to: Self.summaryCap)
        }
        if options.keepShort, body.count > Self.shortCap {
            body = Self.truncateForSpeech(body, to: Self.shortCap)
        }

        let override = displayNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = if !override.isEmpty {
            override
        } else if !event.displayName.isEmpty {
            event.displayName
        } else {
            "Someone"
        }
        let authorID = event.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return .speak(body: body, author: author, authorID: authorID.isEmpty ? author : authorID)
    }

    private func formatAnnouncement(
        body: String,
        author: String,
        authorID: String,
        options: AnnouncerReadOptions,
        now: Date
    ) -> String {
        defer {
            lastSpokenAuthorID = authorID
            lastSpokenAuthorAt = now
        }
        guard options.suppressRepeatedSpeakerNames,
              lastSpokenAuthorID == authorID,
              let lastSpokenAuthorAt,
              now.timeIntervalSince(lastSpokenAuthorAt) < options.repeatedSpeakerNameTimeout else {
            return "\(author): \(body)"
        }
        return body
    }

    private enum BodyOutcome {
        case body(String)
        case skip(reason: String)
    }

    private func readableBody(
        for event: GatewayMessageCreateEvent,
        channelNames: [String: String],
        roleNames: [String: String],
        options: AnnouncerReadOptions
    ) -> BodyOutcome {
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
            return .skip(reason: "it is mostly emoji and the configuration skips emoji spam.")
        }

        // If the message has visible text, prefer that. URLs are stripped unless
        // the config opts to read links aloud.
        if !content.isEmpty {
            let text = options.ignoreLinks
                ? stripURLs(content).trimmingCharacters(in: .whitespacesAndNewlines)
                : content
            if !text.isEmpty {
                return .body(text)
            }
        }

        // No usable text — try the first embed title (e.g. link previews).
        if case let .array(embeds)? = event.rawMap["embeds"],
           let first = embeds.first,
           case let .object(embedMap) = first,
           case let .string(title)? = embedMap["title"] {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                return .body(trimmedTitle)
            }
        }

        return .skip(reason: "it has no readable text (links or attachments only).")
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

    /// Truncate at a word boundary, ending with a cue that is actually spoken.
    /// Trailing punctuation is dropped first so the cue doesn't read as
    /// "…people are around., message continues".
    private static func truncateForSpeech(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let slice = String(text.prefix(limit))
        var head = slice
        if let lastSpace = slice.lastIndex(of: " ") {
            let candidate = String(slice[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty { head = candidate }
        }
        head = head
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:-–—…"))
            .trimmingCharacters(in: .whitespaces)
        return head + truncationCue
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
