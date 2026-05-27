import Foundation

// MARK: - Gateway Payload

struct GatewayPayload: Codable, Sendable {
    let op: Int
    let d: DiscordJSON?
    let s: Int?
    let t: String?
}

// MARK: - Discord JSON

enum DiscordJSON: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: DiscordJSON])
    case array([DiscordJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: DiscordJSON].self) {
            self = .object(value)
        } else if let value = try? container.decode([DiscordJSON].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                DiscordJSON.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - SwiftBot Event

enum SwiftBotEvent: Sendable {
    struct MessagePayload: Sendable {
        let guildId: String
        let userId: String
        let username: String
        let channelId: String
        let messageId: String
        let content: String
        let isDirectMessage: Bool
        let authorIsBot: Bool
    }

    struct MediaPayload: Sendable {
        let guildId: String
        let userId: String
        let username: String
        let fileName: String
        let relativePath: String?
        let sourceName: String?
        let nodeName: String
    }

    case join(guildId: String, userId: String, username: String, channelId: String)
    case leave(guildId: String, userId: String, username: String, channelId: String, durationSeconds: Int)
    case move(guildId: String, userId: String, username: String, channelId: String, fromChannelId: String, toChannelId: String, durationSeconds: Int)
    case message(MessagePayload)
    case memberJoin(guildId: String, userId: String, username: String, joinedAt: Date?)
    case memberLeave(guildId: String, userId: String, username: String)
    case mediaAdded(MediaPayload)

    enum Kind: Sendable {
        case join
        case leave
        case move
        case message
        case memberJoin
        case memberLeave
        case mediaAdded
    }

    var kind: Kind {
        switch self {
        case .join: return .join
        case .leave: return .leave
        case .move: return .move
        case .message: return .message
        case .memberJoin: return .memberJoin
        case .memberLeave: return .memberLeave
        case .mediaAdded: return .mediaAdded
        }
    }

    var guildId: String {
        switch self {
        case .join(let g, _, _, _): return g
        case .leave(let g, _, _, _, _): return g
        case .move(let g, _, _, _, _, _, _): return g
        case .message(let p): return p.guildId
        case .memberJoin(let g, _, _, _): return g
        case .memberLeave(let g, _, _): return g
        case .mediaAdded(let p): return p.guildId
        }
    }

    var userId: String {
        switch self {
        case .join(_, let u, _, _): return u
        case .leave(_, let u, _, _, _): return u
        case .move(_, let u, _, _, _, _, _): return u
        case .message(let p): return p.userId
        case .memberJoin(_, let u, _, _): return u
        case .memberLeave(_, let u, _): return u
        case .mediaAdded(let p): return p.userId
        }
    }

    var username: String {
        switch self {
        case .join(_, _, let name, _): return name
        case .leave(_, _, let name, _, _): return name
        case .move(_, _, let name, _, _, _, _): return name
        case .message(let p): return p.username
        case .memberJoin(_, _, let name, _): return name
        case .memberLeave(_, _, let name): return name
        case .mediaAdded(let p): return p.username
        }
    }

    var channelId: String {
        switch self {
        case .join(_, _, _, let c): return c
        case .leave(_, _, _, let c, _): return c
        case .move(_, _, _, let c, _, _, _): return c
        case .message(let p): return p.channelId
        case .memberJoin: return ""
        case .memberLeave: return ""
        case .mediaAdded: return ""
        }
    }

    var fromChannelId: String? {
        switch self {
        case .move(_, _, _, _, let from, _, _): return from
        case .leave(_, _, _, let from, _): return from
        default: return nil
        }
    }

    var toChannelId: String? {
        switch self {
        case .join(_, _, _, let to): return to
        case .move(_, _, _, _, _, let to, _): return to
        default: return nil
        }
    }

    var durationSeconds: Int? {
        switch self {
        case .leave(_, _, _, _, let d): return d
        case .move(_, _, _, _, _, _, let d): return d
        default: return nil
        }
    }

    var messageContent: String? {
        switch self {
        case .message(let p): return p.content
        case .mediaAdded(let p): return p.fileName
        default: return nil
        }
    }

    var messageId: String? {
        switch self {
        case .message(let p): return p.messageId
        default: return nil
        }
    }

    var mediaFileName: String? {
        switch self {
        case .mediaAdded(let p): return p.fileName
        default: return nil
        }
    }

    var mediaRelativePath: String? {
        switch self {
        case .mediaAdded(let p): return p.relativePath
        default: return nil
        }
    }

    var mediaSourceName: String? {
        switch self {
        case .mediaAdded(let p): return p.sourceName
        default: return nil
        }
    }

    var mediaNodeName: String? {
        switch self {
        case .mediaAdded(let p): return p.nodeName
        default: return nil
        }
    }

    var triggerMessageId: String? {
        switch self {
        case .message(let p): return p.messageId
        default: return nil
        }
    }

    var triggerChannelId: String? {
        switch self {
        case .message(let p): return p.channelId
        default: return nil
        }
    }

    var triggerGuildId: String {
        return guildId
    }

    var triggerUserId: String {
        return userId
    }

    var isDirectMessage: Bool {
        switch self {
        case .message(let p): return p.isDirectMessage
        default: return false
        }
    }

    var authorIsBot: Bool? {
        switch self {
        case .message(let p): return p.authorIsBot
        default: return nil
        }
    }

    var joinedAt: Date? {
        switch self {
        case .memberJoin(_, _, _, let date): return date
        default: return nil
        }
    }
}

// MARK: - Pipeline Context

/// Context maintained during a single rule execution pipeline
struct PipelineContext: CustomStringConvertible {
    var aiResponse: String?
    var aiSummary: String?
    var aiClassification: String?
    var aiEntities: String?
    var aiRewrite: String?
    var triggerGuildId: String?
    var triggerChannelId: String?
    var triggerMessageId: String?
    var targetChannelId: String?
    var targetServerId: String?
    var mentionUser: Bool = true
    var prependUserMention: Bool = false
    var replyToTriggerMessage: Bool = false
    var mentionRole: String?
    var isDirectMessage: Bool = false
    var sendToDM: Bool = false
    var eventHandled: Bool = false

    var description: String {
        let ai = aiResponse != nil ? "AI(\(aiResponse!.count) chars)" : "nil"
        let summary = aiSummary != nil ? "Summary(\(aiSummary!.count) chars)" : "nil"
        let target = targetChannelId ?? "default"
        let trigger = triggerChannelId ?? "none"
        return "[PipelineContext target: \(target), trigger: \(trigger), mentionUser: \(mentionUser), prepend: \(prependUserMention), reply: \(replyToTriggerMessage), role: \(mentionRole ?? "nil"), ai: \(ai), summary: \(summary), handled: \(eventHandled)]"
    }
}
