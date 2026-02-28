import Combine
import Foundation

struct GuildSettings: Codable, Hashable {
    var notificationChannelId: String?
    var ignoredVoiceChannelIds: Set<String> = []
    var monitoredVoiceChannelIds: Set<String> = []
    var notifyOnJoin: Bool = true
    var notifyOnLeave: Bool = true
    var notifyOnMove: Bool = true
    var joinNotificationTemplate: String = "🔊 <@{userId}> connected to <#{channelId}>"
    var leaveNotificationTemplate: String = "🔌 <@{userId}> disconnected from <#{channelId}>"
    var moveNotificationTemplate: String = "🔁 <@{userId}> switched voice channels: <#{fromChannelId}> → <#{toChannelId}>"
}

struct BotSettings: Codable, Hashable {
    var token: String = ""
    var prefix: String = "!"
    var autoStart: Bool = false
    var guildSettings: [String: GuildSettings] = [:]
}

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
    enum Kind: String {
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

struct CommandLogEntry: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let user: String
    let server: String
    let command: String
    let channel: String
    let ok: Bool
}

struct VoiceMemberPresence: Identifiable, Hashable {
    let id: String
    let userId: String
    let username: String
    let guildId: String
    let channelId: String
    let channelName: String
    let joinedAt: Date
}

struct VoiceEventLogEntry: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let description: String
}

struct GuildVoiceChannel: Identifiable, Hashable {
    let id: String
    let name: String
}

struct GuildTextChannel: Identifiable, Hashable {
    let id: String
    let name: String
}

struct UptimeInfo {
    let startedAt: Date

    var text: String {
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%02dh %02dm %02ds", h, m, s) }
        return String(format: "%02dm %02ds", m, s)
    }
}

struct GatewayPayload: Codable {
    let op: Int
    let d: DiscordJSON?
    let s: Int?
    let t: String?
}

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

struct VoiceRuleEvent {
    enum Kind {
        case join
        case leave
        case move
    }

    let kind: Kind
    let guildId: String
    let userId: String
    let username: String
    let channelId: String
    let fromChannelId: String?
    let toChannelId: String?
    let durationSeconds: Int?
}

@MainActor
final class RuleStore: ObservableObject {
    @Published var rules: [Rule] = []
    @Published var selectedRuleID: UUID?
    @Published var lastSavedAt: Date?

    private let store = RuleConfigStore()
    private var autoSaveTask: Task<Void, Never>?

    init() {
        Task {
            let loaded = await store.load()
            if let loaded, !loaded.isEmpty {
                rules = loaded
            } else {
                rules = [Rule(name: "Join Notification")]
            }
            selectedRuleID = rules.first?.id
        }
    }

    func addNewRule() {
        let rule = Rule(name: "New Notification")
        rules.append(rule)
        selectedRuleID = rule.id
        scheduleAutoSave()
    }

    func deleteRules(at offsets: IndexSet, undoManager: UndoManager?) {
        let sortedOffsets = offsets.sorted()
        guard !sortedOffsets.isEmpty else { return }
        let removed = sortedOffsets.map { ($0, rules[$0]) }
        let previousSelection = selectedRuleID

        for index in sortedOffsets.reversed() {
            rules.remove(at: index)
        }
        reseatSelection(previousSelection: previousSelection)
        scheduleAutoSave()

        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreRules(removed, previousSelection: previousSelection, undoManager: undoManager)
        }
    }

    func deleteRule(id: UUID, undoManager: UndoManager?) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        deleteRules(at: IndexSet(integer: idx), undoManager: undoManager)
    }

    func save() {
        let snapshot = rules
        Task {
            try? await store.save(snapshot)
            lastSavedAt = Date()
        }
    }

    func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func restoreRules(_ removed: [(Int, Rule)], previousSelection: UUID?, undoManager: UndoManager?) {
        for (index, rule) in removed.sorted(by: { $0.0 < $1.0 }) {
            let insertIndex = min(index, rules.count)
            rules.insert(rule, at: insertIndex)
        }
        selectedRuleID = previousSelection ?? removed.first?.1.id
        scheduleAutoSave()

        undoManager?.registerUndo(withTarget: self) { target in
            let offsets = IndexSet(removed.map(\.0))
            target.deleteRules(at: offsets, undoManager: undoManager)
        }
    }

    private func reseatSelection(previousSelection: UUID?) {
        guard let previousSelection else {
            selectedRuleID = rules.first?.id
            return
        }

        if rules.contains(where: { $0.id == previousSelection }) {
            selectedRuleID = previousSelection
        } else {
            selectedRuleID = rules.first?.id
        }
    }
}

@MainActor
final class RuleEngine {
    private var cancellable: AnyCancellable?
    private var activeRules: [Rule] = []

    init(store: RuleStore) {
        cancellable = store.$rules.sink { [weak self] rules in
            self?.activeRules = rules.filter(\.isEnabled)
        }
    }

    func evaluate(event: VoiceRuleEvent) -> [Action] {
        activeRules
            .filter { rule in matchesTrigger(rule: rule, event: event) && matchesConditions(rule: rule, event: event) }
            .flatMap(\.actions)
    }

    private func matchesTrigger(rule: Rule, event: VoiceRuleEvent) -> Bool {
        switch (rule.trigger, event.kind) {
        case (.userJoinedVoice, .join): return true
        case (.userLeftVoice, .leave): return true
        case (.userMovedVoice, .move): return true
        default: return false
        }
    }

    private func matchesConditions(rule: Rule, event: VoiceRuleEvent) -> Bool {
        for condition in rule.conditions where condition.enabled {
            if !matches(condition: condition, event: event) { return false }
        }
        return true
    }

    private func matches(condition: Condition, event: VoiceRuleEvent) -> Bool {
        let value = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch condition.type {
        case .server:
            return value.isEmpty || event.guildId == value
        case .voiceChannel:
            return value.isEmpty || event.channelId == value || event.fromChannelId == value || event.toChannelId == value
        case .usernameContains:
            guard !value.isEmpty else { return true }
            return event.username.localizedCaseInsensitiveContains(value)
        case .minimumDuration:
            guard let minimum = Int(value), minimum > 0 else { return true }
            guard let durationSeconds = event.durationSeconds else { return false }
            return durationSeconds >= (minimum * 60)
        }
    }
}
