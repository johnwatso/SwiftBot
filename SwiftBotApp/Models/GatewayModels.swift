import Foundation

// MARK: - Gateway Payload

struct GatewayPayload: Codable {
    let op: Int
    let d: DiscordJSON?
    let s: Int?
    let t: String?
}

// MARK: - Discord JSON

enum DiscordJSON: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: DiscordJSON])
    case array([DiscordJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode([String: DiscordJSON].self) { self = .object(value) }
        else if let value = try? container.decode([DiscordJSON].self) { self = .array(value) }
        else { throw DecodingError.typeMismatch(DiscordJSON.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type")) }
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

// MARK: - Voice Rule Event

struct VoiceRuleEvent {
    enum Kind {
        case join
        case leave
        case move
        case message
        case memberJoin
        case memberLeave
        case mediaAdded
    }

    let kind: Kind
    let guildId: String
    let userId: String
    let username: String
    let channelId: String
    let fromChannelId: String?
    let toChannelId: String?
    let durationSeconds: Int?
    let messageContent: String?
    let messageId: String?
    let mediaFileName: String?
    let mediaRelativePath: String?
    let mediaSourceName: String?
    let mediaNodeName: String?
    let triggerMessageId: String?
    let triggerChannelId: String?
    let triggerGuildId: String
    let triggerUserId: String
    let isDirectMessage: Bool
    let authorIsBot: Bool?
    let joinedAt: Date?
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
