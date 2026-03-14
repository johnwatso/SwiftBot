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

struct ActivityEvent: Identifiable, Hashable {
    enum Kind: String, Codable {
        case voiceJoin
        case voiceLeave
        case voiceMove
        case command
        case info
        case warning
        case error
    }

    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let message: String
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
    let weaponStats: FinalsWeaponStats?
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
