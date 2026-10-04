import Foundation

// MARK: - Presence archive
//
// Rewind's record of what members were doing while in voice, from Discord rich
// presence: games (with the map/mode/party changes inside a session),
// streaming, watching, competing and custom status. Nothing is written while a
// member is out of voice, and listening activity (Spotify) is left out on
// purpose. Kept beside the message archive so recordings, recaps and anything
// else in the app can ask "what was this person doing at 21:14?".

/// One stretch of rich-presence detail inside a segment. A game rewrites
/// `details`/`state` as the player moves between menus, maps and modes, so a
/// segment keeps every distinct value with the time it appeared.
struct PresenceDetailSpan: Codable, Hashable, Sendable {
    var at: Date
    var details: String?
    var state: String?
    var largeText: String?
    var smallText: String?
    var partyID: String?
    var partySize: Int?
    var partyMax: Int?

    enum CodingKeys: String, CodingKey {
        case at = "t", details = "d", state = "s", largeText = "lt", smallText = "st"
        case partyID = "pi", partySize = "ps", partyMax = "pm"
    }

    init(activity: GatewayPresenceActivity, at: Date) {
        self.at = at
        details = activity.details
        state = activity.state
        largeText = activity.largeText
        smallText = activity.smallText
        partyID = activity.partyID
        partySize = activity.partySize
        partyMax = activity.partyMax
    }

    /// Same detail, ignoring when it was seen.
    func matches(_ other: PresenceDetailSpan) -> Bool {
        details == other.details && state == other.state && largeText == other.largeText
            && smallText == other.smallText && partyID == other.partyID
            && partySize == other.partySize && partyMax == other.partyMax
    }

    var isEmpty: Bool {
        details == nil && state == nil && largeText == nil && smallText == nil
            && partyID == nil && partySize == nil && partyMax == nil
    }
}

/// One continuous activity for one member in one guild.
struct PresenceSegment: Codable, Hashable, Sendable {
    let guildID: String
    let userID: String
    /// Discord activity type: 0 playing, 1 streaming, 3 watching, 4 custom
    /// status, 5 competing.
    let type: Int
    let name: String
    var applicationID: String?
    var platform: String?
    var url: String?
    var emoji: String?
    var startedAt: Date
    var endedAt: Date?
    var spans: [PresenceDetailSpan] = []

    enum CodingKeys: String, CodingKey {
        case guildID = "g", userID = "u", type = "k", name = "n", applicationID = "a"
        case platform = "p", url = "l", emoji = "e", startedAt = "s", endedAt = "x", spans = "d"
    }

    var duration: TimeInterval {
        max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
    }

    func overlaps(_ start: Date, _ end: Date) -> Bool {
        startedAt < end && (endedAt ?? .distantFuture) > start
    }

    /// The detail in effect at `date`, if the activity reported any.
    func span(at date: Date) -> PresenceDetailSpan? {
        spans.last { $0.at <= date } ?? spans.first
    }
}

enum PresenceActivityType {
    static let playing = 0
    static let streaming = 1
    static let listening = 2
    static let watching = 3
    static let custom = 4
    static let competing = 5

    /// Everything but listening — Spotify is deliberately not archived.
    static func isArchived(_ type: Int) -> Bool { type != listening }
}

// MARK: - Server journal

/// One gateway dispatch kept verbatim. The journal holds the events no other
/// store models — edits, deletes, reactions, poll votes, member and role
/// changes, threads, scheduled events, voice state — so later features can
/// read them without SwiftBot having had to anticipate the question.
struct RewindJournalEntry: Codable, Sendable {
    let event: String
    let guildID: String
    let receivedAt: Date
    let payload: DiscordJSON?

    enum CodingKeys: String, CodingKey {
        case event = "e", guildID = "g", receivedAt = "t", payload = "d"
    }

    /// Synthetic event name for a member's online/idle/dnd/offline or device
    /// change. Presence updates themselves are archived as segments, not raw.
    static let statusEvent = "PRESENCE_STATUS"
}

enum RewindJournal {
    /// Dispatches never journaled: messages and presence have structured
    /// archives, typing is noise, and the rest are connection plumbing or bulk
    /// snapshots that would dwarf everything else.
    static let excludedEvents: Set<String> = [
        "MESSAGE_CREATE", "PRESENCE_UPDATE", "TYPING_START",
        "READY", "RESUMED", "GUILD_CREATE", "GUILD_MEMBERS_CHUNK",
        "VOICE_SERVER_UPDATE", "APPLICATION_COMMAND_PERMISSIONS_UPDATE"
    ]

    /// Payload keys whose value is message text, removed when the operator has
    /// turned off `retainMessageContent`.
    static let contentKeys: Set<String> = ["content", "embeds", "attachments"]
}

// MARK: - Live tracking

/// Turns presence updates into closed `PresenceSegment`s plus status changes.
///
/// Pure and synchronous, like `GamePresenceSessionTracker`, but archival rather
/// than announcing: no grace window and no minimum length, because the archive
/// keeps what Discord said and readers merge as they need.
struct PresenceArchiveTracker {
    struct Key: Hashable, Codable, Sendable {
        let guildID: String
        let userID: String
        let type: Int
        let name: String
    }

    struct Status: Codable, Hashable, Sendable {
        var status: String
        var clientStatus: [String: String]
    }

    struct Output {
        var closed: [PresenceSegment] = []
        var statusChange: RewindJournalEntry?
    }

    static let maxSpansPerSegment = 2_000

    private(set) var live: [Key: PresenceSegment] = [:]
    private var lastStatus: [String: Status] = [:]
    /// When each key's previous segment ended, so a session reported again after
    /// a restart (with its original start) never overlaps the part already
    /// written.
    private var lastEnded: [Key: Date] = [:]

    var liveSegments: [PresenceSegment] { Array(live.values) }

    /// `notBefore` clamps new segments to when recording began (the member's
    /// voice join), so a game started before joining isn't back-dated.
    mutating func apply(_ event: GatewayPresenceUpdateEvent, now: Date, notBefore: Date? = nil) -> Output {
        var output = Output()
        let statusKey = "\(event.guildID)/\(event.userID)"
        let status = Status(status: event.status, clientStatus: event.clientStatus)
        if lastStatus[statusKey] != status {
            lastStatus[statusKey] = status
            var devices: [String: DiscordJSON] = [:]
            for (device, value) in status.clientStatus { devices[device] = .string(value) }
            output.statusChange = RewindJournalEntry(
                event: RewindJournalEntry.statusEvent,
                guildID: event.guildID,
                receivedAt: now,
                payload: .object([
                    "user_id": .string(event.userID),
                    "status": .string(status.status),
                    "client_status": .object(devices)
                ])
            )
        }

        let current = event.isOffline ? [] : event.activities.filter { PresenceActivityType.isArchived($0.type) }
        var seen: Set<Key> = []
        for activity in current {
            let key = Key(guildID: event.guildID, userID: event.userID, type: activity.type, name: Self.normalize(activity.name))
            guard seen.insert(key).inserted else { continue }
            let span = PresenceDetailSpan(activity: activity, at: now)

            if var segment = live[key] {
                if !span.isEmpty, segment.spans.last.map({ !$0.matches(span) }) ?? true,
                   segment.spans.count < Self.maxSpansPerSegment {
                    segment.spans.append(span)
                }
                segment.platform = activity.platform ?? segment.platform
                segment.url = activity.url ?? segment.url
                segment.emoji = activity.emoji ?? segment.emoji
                live[key] = segment
                continue
            }

            var startedAt = now
            if let reported = activity.startedAt, reported <= now,
               now.timeIntervalSince(reported) < 7 * 24 * 60 * 60 {
                startedAt = reported
            }
            if let ended = lastEnded[key], ended > startedAt, ended <= now {
                startedAt = ended
            }
            if let notBefore, notBefore > startedAt, notBefore <= now {
                startedAt = notBefore
            }
            var spanAtStart = span
            spanAtStart.at = startedAt
            live[key] = PresenceSegment(
                guildID: event.guildID,
                userID: event.userID,
                type: activity.type,
                name: activity.name,
                applicationID: activity.applicationID,
                platform: activity.platform,
                url: activity.url,
                emoji: activity.emoji,
                startedAt: startedAt,
                endedAt: nil,
                spans: span.isEmpty ? [] : [spanAtStart]
            )
        }

        for (key, segment) in live where key.guildID == event.guildID && key.userID == event.userID && !seen.contains(key) {
            output.closed.append(close(key, segment, at: now))
        }
        return output
    }

    /// Stops recording one member — they left voice. Their status is forgotten
    /// too, so it is journaled again the next time they join.
    mutating func end(guildID: String, userID: String, at date: Date) -> [PresenceSegment] {
        lastStatus.removeValue(forKey: "\(guildID)/\(userID)")
        return live.filter { $0.key.guildID == guildID && $0.key.userID == userID }
            .map { close($0.key, $0.value, at: date) }
    }

    /// Ends every live segment, e.g. on shutdown.
    mutating func closeAll(at date: Date) -> [PresenceSegment] {
        lastStatus.removeAll()
        return live.map { close($0.key, $0.value, at: date) }
    }

    /// Restores segments checkpointed before a crash or quit, ended at the
    /// checkpoint time — the last moment the bot knew they were still going.
    mutating func recover(_ segments: [PresenceSegment], endedAt: Date) -> [PresenceSegment] {
        segments.map { segment in
            let key = Key(guildID: segment.guildID, userID: segment.userID, type: segment.type, name: Self.normalize(segment.name))
            var finished = segment
            finished.endedAt = max(segment.startedAt, endedAt)
            lastEnded[key] = finished.endedAt
            return finished
        }
    }

    private mutating func close(_ key: Key, _ segment: PresenceSegment, at date: Date) -> PresenceSegment {
        live.removeValue(forKey: key)
        var finished = segment
        finished.endedAt = max(segment.startedAt, date)
        lastEnded[key] = finished.endedAt
        return finished
    }

    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Message metadata

/// Everything about a message besides its text. Optional on `RewindMessage`, so
/// archives written before it existed decode unchanged.
struct RewindMessageMeta: Codable, Hashable, Sendable {
    struct Attachment: Codable, Hashable, Sendable {
        var id: String?
        var fileName: String
        var contentType: String?
        var size: Int?
        var width: Int?
        var height: Int?
        var durationSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case id = "i", fileName = "f", contentType = "c", size = "s", width = "w", height = "h"
            case durationSeconds = "d"
        }
    }

    var attachments: [Attachment]?
    var stickers: [String]?
    /// Embed URLs (link previews, GIFs) and their provider/title.
    var embeds: [String]?
    var replyToMessageID: String?
    var replyToUserID: String?
    var mentionUserIDs: [String]?
    var mentionRoleIDs: [String]?
    var mentionsEveryone: Bool?
    var threadID: String?
    var pollQuestion: String?
    /// Discord message type when it isn't a plain message (19 = reply etc.).
    var messageType: Int?
    var flags: Int?
    var webhookID: String?
    var forwardedFromMessageID: String?

    enum CodingKeys: String, CodingKey {
        case attachments = "a", stickers = "k", embeds = "e", replyToMessageID = "r", replyToUserID = "ru"
        case mentionUserIDs = "m", mentionRoleIDs = "mr", mentionsEveryone = "me", threadID = "th"
        case pollQuestion = "p", messageType = "y", flags = "f", webhookID = "w", forwardedFromMessageID = "fw"
    }

    var isEmpty: Bool { self == RewindMessageMeta() }

    /// Built from a raw message object — the gateway `MESSAGE_CREATE` payload
    /// and the REST history page share the shape, so live ingest and backfill
    /// agree.
    init?(raw: [String: DiscordJSON]) {
        func string(_ value: DiscordJSON?) -> String? {
            if case let .string(text)? = value, !text.isEmpty { return text }
            return nil
        }
        func int(_ value: DiscordJSON?) -> Int? {
            switch value {
            case let .int(number)?: return number
            case let .double(number)?: return Int(number)
            default: return nil
            }
        }
        func objects(_ key: String) -> [[String: DiscordJSON]] {
            guard case let .array(items)? = raw[key] else { return [] }
            return items.compactMap { if case let .object(map) = $0 { return map } else { return nil } }
        }

        let attachments = objects("attachments").compactMap { item -> Attachment? in
            guard let fileName = string(item["filename"]) else { return nil }
            var durationSeconds: Double?
            if case let .double(value)? = item["duration_secs"] { durationSeconds = value }
            return Attachment(
                id: string(item["id"]), fileName: fileName, contentType: string(item["content_type"]),
                size: int(item["size"]), width: int(item["width"]), height: int(item["height"]),
                durationSeconds: durationSeconds ?? int(item["duration_secs"]).map(Double.init)
            )
        }
        if !attachments.isEmpty { self.attachments = attachments }

        let stickers = objects("sticker_items").compactMap { string($0["name"]) }
        if !stickers.isEmpty { self.stickers = stickers }

        let embeds = objects("embeds").compactMap { embed -> String? in
            let parts = [string(embed["url"]), string(embed["title"])].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " — ")
        }
        if !embeds.isEmpty { self.embeds = embeds }

        if case let .object(reference)? = raw["message_reference"] {
            // type 1 is a forward; 0 (or absent) is a reply.
            if int(reference["type"]) == 1 {
                forwardedFromMessageID = string(reference["message_id"])
            } else {
                replyToMessageID = string(reference["message_id"])
            }
        }
        if case let .object(referenced)? = raw["referenced_message"],
           case let .object(author)? = referenced["author"] {
            replyToUserID = string(author["id"])
        }

        let mentions = objects("mentions").compactMap { string($0["id"]) }
        if !mentions.isEmpty { mentionUserIDs = mentions }
        if case let .array(roles)? = raw["mention_roles"] {
            let ids = roles.compactMap { string($0) }
            if !ids.isEmpty { mentionRoleIDs = ids }
        }
        if case .bool(true)? = raw["mention_everyone"] { mentionsEveryone = true }

        if case let .object(thread)? = raw["thread"] { threadID = string(thread["id"]) }
        if case let .object(poll)? = raw["poll"], case let .object(question)? = poll["question"] {
            pollQuestion = string(question["text"])
        }
        if let type = int(raw["type"]), type != 0 { messageType = type }
        if let flags = int(raw["flags"]), flags != 0 { self.flags = flags }
        webhookID = string(raw["webhook_id"])

        if isEmpty { return nil }
    }

    private init() {}
}
