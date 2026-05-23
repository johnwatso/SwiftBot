import Foundation

enum BotStatus: String {
    case stopped
    case connecting
    case running
    case reconnecting
}

struct StatCounter {
    var commandsRun = 0
    var voiceJoins = 0
    var voiceLeaves = 0
    var errors = 0
}

struct ActivityEvent: Identifiable, Hashable, Codable {
    enum Kind: String, Codable {
        case voiceJoin
        case voiceLeave
        case voiceMove
        case command
        case info
        case warning
        case error
    }

    let id: UUID
    let timestamp: Date
    let kind: Kind
    let message: String

    init(id: UUID = UUID(), timestamp: Date, kind: Kind, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
    }
}

/// A durable security/admin event for the unified Activity Log.
/// Source can be the Admin Web UI (auth, config changes) or the bot itself
/// (moderation actions). Held in memory with a rolling cap on AppModel.
struct AuditLogEntry: Identifiable, Hashable, Codable {
    enum Level: String, Codable, Hashable {
        case info
        case ok
        case warning
        case error
    }

    enum Source: String, Codable, Hashable {
        case webAuth = "Web Auth"
        case webConfig = "Web Config"
        case moderation = "Moderation"
        case bot = "Bot"
    }

    let id: UUID
    let time: Date
    let source: Source
    let actor: String
    let action: String
    let detail: String?
    let level: Level

    init(
        id: UUID = UUID(),
        time: Date = Date(),
        source: Source,
        actor: String,
        action: String,
        detail: String? = nil,
        level: Level = .info
    ) {
        self.id = id
        self.time = time
        self.source = source
        self.actor = actor
        self.action = action
        self.detail = detail
        self.level = level
    }
}

struct CommandLogEntry: Identifiable, Hashable, Codable {
    let id: UUID
    let time: Date
    let user: String
    let server: String
    let command: String
    let channel: String
    let executionRoute: String
    let executionNode: String
    let ok: Bool

    init(
        id: UUID = UUID(),
        time: Date,
        user: String,
        server: String,
        command: String,
        channel: String,
        executionRoute: String,
        executionNode: String,
        ok: Bool
    ) {
        self.id = id
        self.time = time
        self.user = user
        self.server = server
        self.command = command
        self.channel = channel
        self.executionRoute = executionRoute
        self.executionNode = executionNode
        self.ok = ok
    }
}

enum BugStatus: String, Codable, Hashable {
    case new = "New"
    case workingOn = "Working On"
    case inProgress = "In Progress"
    case blocked = "Blocked"
    case resolved = "Resolved"

    var emoji: String {
        switch self {
        case .new:
            return "🐞"
        case .workingOn:
            return "🔧"
        case .inProgress:
            return "🟡"
        case .blocked:
            return "⛔"
        case .resolved:
            return "✅"
        }
    }
}

struct BugEntry: Hashable, Codable {
    let bugMessageID: String
    let sourceMessageID: String
    let channelID: String
    let guildID: String
    let reporterID: String
    let createdBy: String
    var status: BugStatus
    var timestamp: Date
}

struct BugAutoFixPendingStart: Hashable, Codable {
    let bugMessageID: String
    let channelID: String
    let guildID: String
    let sourceRepoPath: String
    let isolatedRepoPath: String
    let branch: String
    let updateChannelID: String
    let version: String
    let build: String
    let requestedByUserID: String
}

struct BugAutoFixPendingApproval: Hashable, Codable {
    let bugMessageID: String
    let channelID: String
    let guildID: String
    let sourceRepoPath: String
    let isolatedRepoPath: String
    let branch: String
    let updateChannelID: String
    let version: String
    let build: String
}

struct VoiceMemberPresence: Identifiable, Hashable, Codable {
    let id: String
    let userId: String
    let username: String
    let guildId: String
    let channelId: String
    let channelName: String
    let joinedAt: Date
}

struct VoiceEventLogEntry: Identifiable, Hashable, Codable {
    let id: UUID
    let time: Date
    let description: String

    init(id: UUID = UUID(), time: Date, description: String) {
        self.id = id
        self.time = time
        self.description = description
    }
}

struct FinalsWikiLookupResult: Codable, Hashable {
    let title: String
    let extract: String
    let url: String
    let imageURL: String?
    let pageType: String?
    let fields: [WikiResultField]
    let weaponStats: FinalsWeaponStats?

    init(
        title: String,
        extract: String,
        url: String,
        imageURL: String? = nil,
        pageType: String? = nil,
        fields: [WikiResultField] = [],
        weaponStats: FinalsWeaponStats? = nil
    ) {
        self.title = title
        self.extract = extract
        self.url = url
        self.imageURL = imageURL
        self.pageType = pageType
        self.fields = fields
        self.weaponStats = weaponStats
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case extract
        case url
        case imageURL
        case pageType
        case fields
        case weaponStats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        extract = try container.decodeIfPresent(String.self, forKey: .extract) ?? ""
        url = try container.decode(String.self, forKey: .url)
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL)
        pageType = try container.decodeIfPresent(String.self, forKey: .pageType)
        fields = try container.decodeIfPresent([WikiResultField].self, forKey: .fields) ?? []
        weaponStats = try container.decodeIfPresent(FinalsWeaponStats.self, forKey: .weaponStats)
    }
}

struct WikiResultField: Codable, Hashable {
    let name: String
    let value: String
    let inline: Bool

    init(name: String, value: String, inline: Bool = true) {
        self.name = name
        self.value = value
        self.inline = inline
    }
}

struct FinalsWeaponStats: Codable, Hashable {
    let type: String?
    let bodyDamage: String?
    let headshotDamage: String?
    let fireRate: String?
    let dropoffStart: String?
    let dropoffEnd: String?
    let minimumDamage: String?
    let magazineSize: String?
    let shortReload: String?
    let longReload: String?
    let version: String?
    let notes: String?

    init(
        type: String?,
        bodyDamage: String?,
        headshotDamage: String?,
        fireRate: String?,
        dropoffStart: String?,
        dropoffEnd: String?,
        minimumDamage: String?,
        magazineSize: String?,
        shortReload: String?,
        longReload: String?,
        version: String? = nil,
        notes: String? = nil
    ) {
        self.type = type
        self.bodyDamage = bodyDamage
        self.headshotDamage = headshotDamage
        self.fireRate = fireRate
        self.dropoffStart = dropoffStart
        self.dropoffEnd = dropoffEnd
        self.minimumDamage = minimumDamage
        self.magazineSize = magazineSize
        self.shortReload = shortReload
        self.longReload = longReload
        self.version = version
        self.notes = notes
    }
}

struct GuildVoiceChannel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
}

struct GuildTextChannel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
}

struct GuildRole: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let permissions: String?
}
