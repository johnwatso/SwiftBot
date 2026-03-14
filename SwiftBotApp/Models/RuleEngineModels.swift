import Foundation
import Combine
import SwiftUI

@MainActor
final class RuleStore: ObservableObject {
    @Published var rules: [Rule] = []
    @Published var selectedRuleID: UUID?
    @Published var lastSavedAt: Date?
    @Published var isLoading: Bool = false

    private let store = RuleConfigStore()
    private var autoSaveTask: Task<Void, Never>?
    var onPersisted: (@Sendable () async -> Void)?

    init() {
        Task {
            isLoading = true
            let loaded = await store.load()
            rules = loaded ?? []
            selectedRuleID = nil
            isLoading = false
        }
    }

    func addNewRule(serverId: String = "", channelId: String = "") {
        var rule = Rule.empty()
        rule.triggerServerId = serverId
        // New rules start empty - users add blocks via Block Library
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
            await onPersisted?()
        }
    }

    func reloadFromDisk() async {
        isLoading = true
        let loaded = await store.load()
        rules = loaded ?? []
        if let selected = selectedRuleID,
           !rules.contains(where: { $0.id == selected }) {
            selectedRuleID = nil
        }
        isLoading = false
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
            selectedRuleID = nil
            return
        }

        if rules.contains(where: { $0.id == previousSelection }) {
            selectedRuleID = previousSelection
        } else {
            selectedRuleID = nil
        }
    }
}

final class RuleEngine {
    private var cancellable: AnyCancellable?
    private var _activeRules: [Rule] = []
    private let lock = NSLock()

    private var activeRules: [Rule] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _activeRules
        }
        set {
            lock.lock()
            _activeRules = newValue
            lock.unlock()
        }
    }

    init(store: RuleStore) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activeRules = store.rules.filter(\.isEnabled)
            self.cancellable = store.$rules.sink { [weak self] rules in
                self?.activeRules = rules.filter(\.isEnabled)
            }
        }
    }

    func evaluateRules(event: VoiceRuleEvent) -> [Rule] {
        activeRules
            .filter { rule in matchesTrigger(rule: rule, event: event) && matchesConditions(rule: rule, event: event) }
    }

    private func matchesTrigger(rule: Rule, event: VoiceRuleEvent) -> Bool {
        guard let trigger = rule.trigger else { return false }
        switch (trigger, event.kind) {
        case (.userJoinedVoice, .join),
             (.userLeftVoice, .leave),
             (.userMovedVoice, .move),
             (.messageCreated, .message),
             (.memberJoined, .memberJoin),
             (.mediaAdded, .mediaAdded):
            return true
        default:
            return false
        }
    }

    private func matchesConditions(rule: Rule, event: VoiceRuleEvent) -> Bool {
        for condition in rule.conditions {
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
            // Voice channel conditions don't apply to member join/leave events — always pass.
            if event.kind == .memberJoin || event.kind == .memberLeave { return true }
            return value.isEmpty || event.channelId == value || event.fromChannelId == value || event.toChannelId == value
        case .usernameContains:
            guard !value.isEmpty else { return true }
            return event.username.localizedCaseInsensitiveContains(value)
        case .minimumDuration:
            // Duration conditions don't apply to member join events — always pass.
            if event.kind == .memberJoin || event.kind == .memberLeave { return true }
            guard let minimum = Int(value), minimum > 0 else { return true }
            guard let durationSeconds = event.durationSeconds else { return false }
            return durationSeconds >= (minimum * 60)
        case .channelIs:
            // Channel conditions don't apply to voice events — always pass for now
            return value.isEmpty || event.channelId == value
        case .channelCategory:
            // Channel category matching logic: typically we'd need channel metadata
            // For now, treat as placeholder that always passes if not configured
            return true
        case .userHasRole:
            // Role conditions not yet implemented for voice events — always pass
            return true
        case .userJoinedRecently:
            guard let minutes = Int(value), minutes > 0 else { return true }
            guard let joinedAt = event.joinedAt else { return false }
            return Date().timeIntervalSince(joinedAt) <= Double(minutes * 60)
        case .messageContains:
            guard !value.isEmpty, let content = event.messageContent else { return true }
            return content.localizedCaseInsensitiveContains(value)
        case .messageStartsWith:
            guard !value.isEmpty, let content = event.messageContent else { return true }
            return content.lowercased().hasPrefix(value.lowercased())
        case .messageRegex:
            guard !value.isEmpty, let content = event.messageContent else { return true }
            // Basic regex matching - returns true on invalid regex to avoid breaking rules
            guard let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { return true }
            let range = NSRange(content.startIndex..., in: content)
            return regex.firstMatch(in: content, options: [], range: range) != nil
        case .isDirectMessage:
            return event.isDirectMessage
        case .isFromBot:
            return event.authorIsBot ?? false
        case .isFromUser:
            // Filter out bot messages if value is empty or "true"
            return !(event.authorIsBot ?? false)
        case .channelType:
            // Channel type matching - placeholder for now
            // Would need channel type metadata from Discord
            return true
        }
    }
}

protocol BotPlugin {
    var name: String { get }
    func register(on bus: EventBus) async
    func unregister(from bus: EventBus) async
}

final class PluginManager {
    private var plugins: [BotPlugin] = []
    private let bus: EventBus

    init(bus: EventBus) { self.bus = bus }

    func add(_ plugin: BotPlugin) async {
        plugins.append(plugin)
        await plugin.register(on: bus)
    }

    func removeAll() async {
        for p in plugins { await p.unregister(from: bus) }
        plugins.removeAll()
    }
}

final class WeeklySummaryPlugin: BotPlugin {
    let name = "WeeklySummary"

    private var tokens: [SubscriptionToken] = []
    private var voiceDurations: [String: Int] = [:] // userId -> accumulated seconds

    init() {}

    func register(on bus: EventBus) async {
        let joinToken = await bus.subscribe(VoiceJoined.self) { _ in
            // No-op for accumulation; could log here if needed
        }
        tokens.append(joinToken)

        let leftToken = await bus.subscribe(VoiceLeft.self) { [weak self] event in
            guard let self = self else { return }
            self.voiceDurations[event.userId, default: 0] += max(0, event.durationSeconds)
        }
        tokens.append(leftToken)
    }

    func unregister(from bus: EventBus) async {
        for token in tokens {
            await bus.unsubscribe(token)
        }
        tokens.removeAll()
    }

    func snapshotSummary() -> String {
        let sortedUsers = voiceDurations.sorted { $0.value > $1.value }
        guard !sortedUsers.isEmpty else {
            return "No voice activity recorded yet."
        }

        let summaryLines = sortedUsers.prefix(5).map { userId, seconds in
            let minutes = seconds / 60
            return "\(userId): \(minutes) minute\(minutes == 1 ? "" : "s")"
        }

        return "Weekly Voice Summary:\n" + summaryLines.joined(separator: "\n")
    }
}

/// Single owner for AI prompt composition — tone prompt, context enrichment, and message shaping.
/// Both AppModel and DiscordService should go through this to ensure consistent prompt structure.
enum PromptComposer {
    static let defaultTonePrompt =
        "You are a friendly, casual Discord bot. Keep replies short and conversational — " +
        "1 to 3 sentences max unless asked for detail. Use contractions naturally. " +
        "Don't restate what the user said. Don't open every reply the same way. " +
        "Match the energy of the conversation."

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .medium
        return f
    }()

    /// Builds the fully-enriched system prompt string.
    static func buildSystemPrompt(
        base: String,
        serverName: String?,
        channelName: String?,
        wikiContext: String?
    ) -> String {
        var prompt = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultTonePrompt
            : base.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wiki = wikiContext, !wiki.isEmpty {
            prompt += "\n\n\(wiki)"
        }
        if let server = serverName, !server.isEmpty {
            prompt += "\nServer: \(server)"
        }
        if let channel = channelName, !channel.isEmpty {
            prompt += "\nChannel: \(channel)"
        }
        prompt += "\nCurrent Time: \(timeFormatter.string(from: Date()))"
        return prompt
    }

    /// Prepends a system message and filters empty/system-role messages from history.
    static func buildMessages(systemPrompt: String, history: [Message]) -> [Message] {
        let clean = history.filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.role != .system
        }
        let systemMessage = Message(
            channelID: "system",
            userID: "system",
            username: "System",
            content: systemPrompt,
            role: .system
        )
        return [systemMessage] + clean
    }
}

/// A simple helper for interacting with the macOS Keychain.

// MARK: - Navigation Models

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case patchy = "Patchy"
    case voice = "Actions"
    case commands = "Commands"
    case commandLog = "Command Log"
    case wikiBridge = "WikiBridge"
    case logs = "Logs"
    case aiBots = "AI Bots"
    case diagnostics = "Diagnostics"
    case swiftMesh = "SwiftMesh"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .patchy: return "hammer.fill"
        case .voice: return "bolt.circle"
        case .commands: return "terminal.fill"
        case .commandLog: return "list.bullet.clipboard.fill"
        case .wikiBridge: return "book.pages.fill"
        case .logs: return "list.bullet.clipboard.fill"
        case .aiBots: return "sparkles.rectangle.stack.fill"
        case .diagnostics: return "waveform.path.ecg"
        case .swiftMesh: return "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: - Automation Models

// MARK: - Context Variables

/// Variables available in rule templates based on trigger context
enum ContextVariable: String, CaseIterable, Codable, Hashable {
    case user = "{user}"
    case userId = "{user.id}"
    case username = "{user.name}"
    case userNickname = "{user.nickname}"
    case userMention = "{user.mention}"
    case message = "{message}"
    case messageId = "{message.id}"
    case channel = "{channel}"
    case channelId = "{channel.id}"
    case channelName = "{channel.name}"
    case guild = "{guild}"
    case guildId = "{guild.id}"
    case guildName = "{guild.name}"
    case voiceChannel = "{voice.channel}"
    case voiceChannelId = "{voice.channel.id}"
    case reaction = "{reaction}"
    case reactionEmoji = "{reaction.emoji}"
    case duration = "{duration}"
    case memberCount = "{memberCount}"
    case aiResponse = "{ai.response}"
    case aiSummary = "{ai.summary}"
    case aiClassification = "{ai.classification}"
    case aiEntities = "{ai.entities}"
    case aiRewrite = "{ai.rewrite}"
    case mediaFile = "{media.file}"
    case mediaPath = "{media.path}"
    case mediaSource = "{media.source}"
    case mediaNode = "{media.node}"

    var displayName: String {
        switch self {
        case .user: return "User"
        case .userId: return "User ID"
        case .username: return "Username"
        case .userNickname: return "Nickname"
        case .userMention: return "@Mention"
        case .message: return "Message Content"
        case .messageId: return "Message ID"
        case .channel: return "Channel"
        case .channelId: return "Channel ID"
        case .channelName: return "Channel Name"
        case .guild: return "Server"
        case .guildId: return "Server ID"
        case .guildName: return "Server Name"
        case .voiceChannel: return "Voice Channel"
        case .voiceChannelId: return "Voice Channel ID"
        case .reaction: return "Reaction"
        case .reactionEmoji: return "Emoji"
        case .duration: return "Duration"
        case .memberCount: return "Member Count"
        case .aiResponse: return "AI Response"
        case .aiSummary: return "AI Summary"
        case .aiClassification: return "AI Classification"
        case .aiEntities: return "AI Entities"
        case .aiRewrite: return "AI Rewrite"
        case .mediaFile: return "Media File"
        case .mediaPath: return "Media Path"
        case .mediaSource: return "Media Source"
        case .mediaNode: return "Media Node"
        }
    }

    var category: String {
        switch self {
        case .user, .userId, .username, .userNickname, .userMention:
            return "User"
        case .message, .messageId:
            return "Message"
        case .channel, .channelId, .channelName:
            return "Channel"
        case .guild, .guildId, .guildName:
            return "Server"
        case .voiceChannel, .voiceChannelId:
            return "Voice"
        case .reaction, .reactionEmoji:
            return "Reaction"
        case .duration, .memberCount:
            return "Other"
        case .aiResponse, .aiSummary, .aiClassification, .aiEntities, .aiRewrite:
            return "AI"
        case .mediaFile, .mediaPath, .mediaSource, .mediaNode:
            return "Media"
        }
    }
}

extension Set where Element == ContextVariable {
    /// Returns a user-friendly description of the required context (Task 1)
    var friendlyRequirement: String {
        if self.isEmpty { return "" }

        // Priority based on trigger types
        if self.contains(where: { $0.category == "Message" || $0.category == "Reaction" }) {
            return "a message trigger"
        }
        if self.contains(where: { $0.category == "Channel" || $0.category == "Voice" }) {
            return "a channel event"
        }
        if self.contains(where: { $0.category == "User" }) {
            return "a user trigger"
        }

        return "additional context"
    }
}

// MARK: - Discord Permissions

/// Discord permission flags for validation
enum DiscordPermission: String, CaseIterable, Codable, Hashable {
    case createInstantInvite = "CREATE_INSTANT_INVITE"
    case kickMembers = "KICK_MEMBERS"
    case banMembers = "BAN_MEMBERS"
    case administrator = "ADMINISTRATOR"
    case manageChannels = "MANAGE_CHANNELS"
    case manageGuild = "MANAGE_GUILD"
    case addReactions = "ADD_REACTIONS"
    case viewAuditLog = "VIEW_AUDIT_LOG"
    case prioritySpeaker = "PRIORITY_SPEAKER"
    case stream = "STREAM"
    case viewChannel = "VIEW_CHANNEL"
    case sendMessages = "SEND_MESSAGES"
    case sendTTSMessages = "SEND_TTS_MESSAGES"
    case manageMessages = "MANAGE_MESSAGES"
    case embedLinks = "EMBED_LINKS"
    case attachFiles = "ATTACH_FILES"
    case readMessageHistory = "READ_MESSAGE_HISTORY"
    case mentionEveryone = "MENTION_EVERYONE"
    case useExternalEmojis = "USE_EXTERNAL_EMOJIS"
    case connect = "CONNECT"
    case speak = "SPEAK"
    case muteMembers = "MUTE_MEMBERS"
    case deafenMembers = "DEAFEN_MEMBERS"
    case moveMembers = "MOVE_MEMBERS"
    case useVAD = "USE_VAD"
    case changeNickname = "CHANGE_NICKNAME"
    case manageNicknames = "MANAGE_NICKNAMES"
    case manageRoles = "MANAGE_ROLES"
    case manageWebhooks = "MANAGE_WEBHOOKS"
    case manageEmojis = "MANAGE_EMOJIS_AND_STICKERS"
    case useApplicationCommands = "USE_APPLICATION_COMMANDS"
    case requestToSpeak = "REQUEST_TO_SPEAK"
    case manageEvents = "MANAGE_EVENTS"
    case manageThreads = "MANAGE_THREADS"
    case createPublicThreads = "CREATE_PUBLIC_THREADS"
    case createPrivateThreads = "CREATE_PRIVATE_THREADS"
    case useExternalStickers = "USE_EXTERNAL_STICKERS"
    case sendMessagesInThreads = "SEND_MESSAGES_IN_THREADS"
    case useEmbeddedActivities = "USE_EMBEDDED_ACTIVITIES"
    case moderateMembers = "MODERATE_MEMBERS"

    var displayName: String {
        switch self {
        case .createInstantInvite: return "Create Invite"
        case .kickMembers: return "Kick Members"
        case .banMembers: return "Ban Members"
        case .administrator: return "Administrator"
        case .manageChannels: return "Manage Channels"
        case .manageGuild: return "Manage Server"
        case .addReactions: return "Add Reactions"
        case .viewAuditLog: return "View Audit Log"
        case .prioritySpeaker: return "Priority Speaker"
        case .stream: return "Video/Stream"
        case .viewChannel: return "View Channel"
        case .sendMessages: return "Send Messages"
        case .sendTTSMessages: return "Send TTS"
        case .manageMessages: return "Manage Messages"
        case .embedLinks: return "Embed Links"
        case .attachFiles: return "Attach Files"
        case .readMessageHistory: return "Read History"
        case .mentionEveryone: return "Mention @everyone"
        case .useExternalEmojis: return "Use External Emojis"
        case .connect: return "Connect"
        case .speak: return "Speak"
        case .muteMembers: return "Mute Members"
        case .deafenMembers: return "Deafen Members"
        case .moveMembers: return "Move Members"
        case .useVAD: return "Use Voice Activity"
        case .changeNickname: return "Change Nickname"
        case .manageNicknames: return "Manage Nicknames"
        case .manageRoles: return "Manage Roles"
        case .manageWebhooks: return "Manage Webhooks"
        case .manageEmojis: return "Manage Emojis"
        case .useApplicationCommands: return "Use Commands"
        case .requestToSpeak: return "Request to Speak"
        case .manageEvents: return "Manage Events"
        case .manageThreads: return "Manage Threads"
        case .createPublicThreads: return "Create Public Threads"
        case .createPrivateThreads: return "Create Private Threads"
        case .useExternalStickers: return "Use External Stickers"
        case .sendMessagesInThreads: return "Send in Threads"
        case .useEmbeddedActivities: return "Use Activities"
        case .moderateMembers: return "Timeout Members"
        }
    }

    var bitValue: UInt64 {
        switch self {
        case .createInstantInvite: return 1 << 0
        case .kickMembers: return 1 << 1
        case .banMembers: return 1 << 2
        case .administrator: return 1 << 3
        case .manageChannels: return 1 << 4
        case .manageGuild: return 1 << 5
        case .addReactions: return 1 << 6
        case .viewAuditLog: return 1 << 7
        case .prioritySpeaker: return 1 << 8
        case .stream: return 1 << 9
        case .viewChannel: return 1 << 10
        case .sendMessages: return 1 << 11
        case .sendTTSMessages: return 1 << 12
        case .manageMessages: return 1 << 13
        case .embedLinks: return 1 << 14
        case .attachFiles: return 1 << 15
        case .readMessageHistory: return 1 << 16
        case .mentionEveryone: return 1 << 17
        case .useExternalEmojis: return 1 << 18
        case .connect: return 1 << 20
        case .speak: return 1 << 21
        case .muteMembers: return 1 << 22
        case .deafenMembers: return 1 << 23
        case .moveMembers: return 1 << 24
        case .useVAD: return 1 << 25
        case .changeNickname: return 1 << 26
        case .manageNicknames: return 1 << 27
        case .manageRoles: return 1 << 28
        case .manageWebhooks: return 1 << 29
        case .manageEmojis: return 1 << 30
        case .useApplicationCommands: return 1 << 31
        case .requestToSpeak: return 1 << 32
        case .manageEvents: return 1 << 33
        case .manageThreads: return 1 << 34
        case .createPublicThreads: return 1 << 35
        case .createPrivateThreads: return 1 << 36
        case .useExternalStickers: return 1 << 37
        case .sendMessagesInThreads: return 1 << 38
        case .useEmbeddedActivities: return 1 << 39
        case .moderateMembers: return 1 << 40
        }
    }
}

// MARK: - Trigger Types

enum TriggerType: String, CaseIterable, Identifiable, Codable {
    case userJoinedVoice = "Voice Joined"
    case userLeftVoice = "Voice Left"
    case userMovedVoice = "Voice Moved"
    case messageCreated = "Message Created"
    case memberJoined = "Member Joined"
    case memberLeft = "Member Left"
    case reactionAdded = "Reaction Added"
    case slashCommand = "Slash Command"
    case mediaAdded = "New Media Added"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let match = TriggerType(rawValue: raw) {
            self = match
        } else if raw == "Message Contains" {
            self = .messageCreated
        } else if raw == "User Joins Voice" {
            self = .userJoinedVoice
        } else if raw == "User Leaves Voice" {
            self = .userLeftVoice
        } else if raw == "User Moves Voice" {
            self = .userMovedVoice
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid TriggerType: \(raw)")
        }
    }

    var symbol: String {
        switch self {
        case .userJoinedVoice: return "person.crop.circle.badge.plus"
        case .userLeftVoice: return "person.crop.circle.badge.xmark"
        case .userMovedVoice: return "arrow.left.arrow.right.circle"
        case .messageCreated: return "text.bubble"
        case .memberJoined: return "person.badge.plus"
        case .memberLeft: return "person.badge.minus"
        case .reactionAdded: return "face.smiling"
        case .slashCommand: return "slash.circle"
        case .mediaAdded: return "video"
        }
    }

    var defaultMessage: String {
        switch self {
        case .userJoinedVoice: return "🔊 <@{userId}> connected to <#{channelId}>"
        case .userLeftVoice: return "🔌 <@{userId}> disconnected from <#{channelId}> (Online for {duration})"
        case .userMovedVoice: return "🔀 <@{userId}> moved from <#{fromChannelId}> to <#{toChannelId}>"
        case .messageCreated: return "nm you?"
        case .memberJoined: return "👋 Welcome to {server}, {username}! You're member #{memberCount}."
        case .memberLeft: return "👋 {username} left the server."
        case .reactionAdded: return "👍 Reaction added!"
        case .slashCommand: return "Command received!"
        case .mediaAdded: return "🎬 New media detected: {media.file}"
        }
    }

    var defaultRuleName: String {
        switch self {
        case .userJoinedVoice: return "Join Action"
        case .userLeftVoice: return "Leave Action"
        case .userMovedVoice: return "Move Action"
        case .messageCreated: return "Message Reply"
        case .memberJoined: return "Member Join Welcome"
        case .memberLeft: return "Member Leave Log"
        case .reactionAdded: return "Reaction Handler"
        case .slashCommand: return "Command Handler"
        case .mediaAdded: return "Media Added"
        }
    }

    /// Variables provided by this trigger type
    var providedVariables: Set<ContextVariable> {
        switch self {
        case .userJoinedVoice, .userLeftVoice, .userMovedVoice:
            return [.user, .userId, .username, .userMention, .voiceChannel, .voiceChannelId, .guild, .guildId, .guildName, .duration]
        case .messageCreated:
            return [.user, .userId, .username, .userMention, .message, .messageId, .channel, .channelId, .channelName, .guild, .guildId, .guildName]
        case .memberJoined, .memberLeft:
            return [.user, .userId, .username, .userMention, .guild, .guildId, .guildName, .memberCount]
        case .reactionAdded:
            return [.user, .userId, .username, .userMention, .message, .messageId, .channel, .channelId, .reaction, .reactionEmoji, .guild, .guildId]
        case .slashCommand:
            return [.user, .userId, .username, .userMention, .channel, .channelId, .guild, .guildId, .guildName]
        case .mediaAdded:
            return [.mediaFile, .mediaPath, .mediaSource, .mediaNode]
        }
    }

    static var allDefaultMessages: Set<String> {
        var messages = Set(allCases.map(\.defaultMessage))
        // Include legacy defaults so trigger changes still auto-populate
        messages.insert("🔊 <@{userId}> connected to <#{channelId}>")
        messages.insert("🔌 <@{userId}> disconnected from <#{channelId}>")
        messages.insert("🔀 <@{userId}> moved from <#{fromChannelId}> to <#{toChannelId}>")
        return messages
    }
}

enum ConditionType: String, CaseIterable, Identifiable, Codable {
    case server = "Server Is"
    case voiceChannel = "Voice Channel Is"
    case usernameContains = "Username Contains"
    case minimumDuration = "Duration In Channel"
    case channelIs = "Channel Is"
    case channelCategory = "Channel Category Is"
    case userHasRole = "User Has Role"
    case userJoinedRecently = "User Joined Recently"
    case messageContains = "Message Contains"
    case messageStartsWith = "Message Starts With"
    case messageRegex = "Message Matches Regex"
    case isDirectMessage = "Message Is DM"
    case isFromBot = "Message Is From Bot"
    case isFromUser = "Message Is From User"
    case channelType = "Channel Type Is"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .server: return "building.2"
        case .voiceChannel: return "waveform"
        case .usernameContains: return "text.magnifyingglass"
        case .minimumDuration: return "timer"
        case .channelIs: return "number"
        case .channelCategory: return "folder"
        case .userHasRole: return "person.crop.circle.badge.checkmark"
        case .userJoinedRecently: return "clock.arrow.circlepath"
        case .messageContains: return "text.quote"
        case .messageStartsWith: return "text.alignleft"
        case .messageRegex: return "asterisk.circle"
        case .isDirectMessage: return "envelope.badge.shield.half.filled"
        case .isFromBot: return "bot"
        case .isFromUser: return "person"
        case .channelType: return "number.square"
        }
    }

    /// Variables required to evaluate this condition
    var requiredVariables: Set<ContextVariable> {
        switch self {
        case .server:
            return [.guild, .guildId]
        case .voiceChannel:
            return [.voiceChannel, .voiceChannelId]
        case .usernameContains:
            return [.user, .username]
        case .minimumDuration:
            return [.duration]
        case .channelIs, .channelCategory:
            return [.channel, .channelId]
        case .userHasRole, .userJoinedRecently:
            return [.user, .userId]
        case .messageContains, .messageStartsWith, .messageRegex:
            return [.message]
        case .isDirectMessage, .isFromBot, .isFromUser:
            return [.message, .channel]
        case .channelType:
            return [.channel, .channelId]
        }
    }
}

enum ActionType: String, CaseIterable, Identifiable, Codable {
    case sendMessage = "Send Message"
    case addLogEntry = "Add Log Entry"
    case setStatus = "Set Bot Status"
    case sendDM = "Send DM"
    case deleteMessage = "Delete Message"
    case addReaction = "Add Reaction"
    case addRole = "Add Role"
    case removeRole = "Remove Role"
    case timeoutMember = "Timeout Member"
    case kickMember = "Kick Member"
    case moveMember = "Move Member"
    case createChannel = "Create Channel"
    case webhook = "Send Webhook"
    case delay = "Delay"
    case setVariable = "Set Variable"
    case randomChoice = "Random"

    // New Modifier Types
    case replyToTrigger = "Reply To Trigger Message"
    case mentionUser = "Mention User"
    case mentionRole = "Mention Role"
    case disableMention = "Disable User Mentions"
    case sendToChannel = "Send To Channel"
    case sendToDM = "Send To DM"

    // AI Types
    case generateAIResponse = "Generate AI Response"
    case summariseMessage = "Summarise Message"
    case classifyMessage = "Classify Message"
    case extractEntities = "Extract Entities"
    case rewriteMessage = "Rewrite Message"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .sendMessage: return "paperplane.fill"
        case .addLogEntry: return "list.bullet.clipboard"
        case .setStatus: return "dot.radiowaves.left.and.right"
        case .sendDM: return "envelope.fill"
        case .deleteMessage: return "trash.fill"
        case .addReaction: return "face.smiling"
        case .addRole: return "person.crop.circle.badge.plus"
        case .removeRole: return "person.crop.circle.badge.minus"
        case .timeoutMember: return "clock.badge.exclamationmark"
        case .kickMember: return "door.left.hand.open"
        case .moveMember: return "arrow.right.circle"
        case .createChannel: return "plus.rectangle"
        case .webhook: return "link"
        case .delay: return "clock.arrow.circlepath"
        case .setVariable: return "character.textbox"
        case .randomChoice: return "shuffle"
        case .replyToTrigger: return "arrowshape.turn.up.left.fill"
        case .mentionUser: return "at"
        case .mentionRole: return "at.badge.plus"
        case .disableMention: return "at.badge.minus"
        case .sendToChannel: return "number.circle.fill"
        case .sendToDM: return "envelope.fill"
        case .generateAIResponse: return "sparkles"
        case .summariseMessage: return "text.alignleft"
        case .classifyMessage: return "tag.fill"
        case .extractEntities: return "list.bullet.clipboard"
        case .rewriteMessage: return "pencil"
        }
    }

    /// Variables required by this action type
    var requiredVariables: Set<ContextVariable> {
        switch self {
        case .sendMessage, .sendDM, .setStatus, .addLogEntry, .delay, .setVariable, .randomChoice, .createChannel, .webhook:
            return []
        case .deleteMessage, .addReaction, .replyToTrigger:
            return [.message, .messageId]

        case .addRole, .removeRole, .timeoutMember, .kickMember, .moveMember, .mentionUser, .disableMention, .sendToDM:
            return [.user, .userId]
        case .sendToChannel:
            return [.channel]
        case .generateAIResponse, .mentionRole, .summariseMessage, .classifyMessage, .extractEntities, .rewriteMessage:
            return []
        }
    }

    /// Variables provided/output by this action type
    var outputVariables: Set<ContextVariable> {
        switch self {
        case .generateAIResponse:
            return [.aiResponse]
        case .summariseMessage:
            return [.aiSummary]
        case .classifyMessage:
            return [.aiClassification]
        case .extractEntities:
            return [.aiEntities]
        case .rewriteMessage:
            return [.aiRewrite]
        case .sendMessage, .sendDM, .deleteMessage, .addReaction, .addRole,
             .removeRole, .timeoutMember, .kickMember, .moveMember, .createChannel, .webhook,
             .setStatus, .addLogEntry, .delay, .setVariable, .randomChoice, .replyToTrigger,
             .mentionUser, .mentionRole, .disableMention, .sendToChannel, .sendToDM:
            return []
        }
    }

    /// Discord permissions required for this action
    var requiredPermissions: Set<DiscordPermission> {
        switch self {
        case .sendMessage, .sendDM, .addLogEntry, .setStatus, .delay, .setVariable, .randomChoice, .generateAIResponse, .replyToTrigger, .mentionUser, .mentionRole, .disableMention, .sendToChannel, .sendToDM, .summariseMessage, .classifyMessage, .extractEntities, .rewriteMessage:
            return []
        case .deleteMessage:
            return [.manageMessages]
        case .addReaction:
            return [.addReactions]
        case .addRole, .removeRole:
            return [.manageRoles]
        case .timeoutMember:
            return [.moderateMembers]
        case .kickMember:
            return [.kickMembers]
        case .moveMember:
            return [.moveMembers]
        case .createChannel:
            return [.manageChannels]
        case .webhook:
            return [.manageWebhooks]
        }
    }

    /// Category for block library organization
    var category: BlockCategory {
        switch self {
        case .replyToTrigger, .disableMention, .sendToChannel, .sendToDM, .mentionUser, .mentionRole:
            return .messaging
        case .sendMessage, .sendDM, .addReaction, .deleteMessage, .createChannel, .webhook,
             .addLogEntry, .setStatus, .delay, .setVariable, .randomChoice:
            return .actions
        case .generateAIResponse, .summariseMessage, .classifyMessage, .extractEntities, .rewriteMessage:
            return .ai
        case .addRole, .removeRole, .timeoutMember, .kickMember, .moveMember:
            return .moderation
        }
    }
}

/// Block categories for library organization (Task 5)
enum BlockCategory: String, CaseIterable, Identifiable {
    case triggers = "Triggers"
    case filters = "Filters"
    case ai = "AI Blocks"
    case messaging = "Message"
    case actions = "Actions"
    case moderation = "Moderation"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .triggers: return "bolt.fill"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .ai: return "sparkles"
        case .messaging: return "text.bubble.fill"
        case .actions: return "paperplane.fill"
        case .moderation: return "shield.fill"
        }
    }
}

extension ConditionType {
    /// Returns true if this condition is compatible with the given trigger (Task 4)
    func isCompatible(with trigger: TriggerType?) -> Bool {
        guard let trigger = trigger else { return true } // No trigger means everything is potentially visible
        return self.requiredVariables.isSubset(of: trigger.providedVariables)
    }
}

extension ActionType {
    /// Returns true if this action is compatible with the given trigger (Task 4)
    func isCompatible(with trigger: TriggerType?) -> Bool {
        guard let trigger = trigger else { return true }
        return self.requiredVariables.isSubset(of: trigger.providedVariables)
    }
}
struct Condition: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: ConditionType
    var value: String = ""
    var secondaryValue: String = ""
}

struct RuleAction: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: ActionType = .sendMessage
    var serverId: String = ""
    var channelId: String = ""
    var mentionUser: Bool = true
    var replyToTriggerMessage: Bool = false
    var replyWithAI: Bool = false
    var message: String = "🔊 <@{userId}> connected to <#{channelId}>"
    var statusText: String = "Voice notifier active"

    // New fields for extended action types
    var dmContent: String = ""              // For sendDM
    var emoji: String = "👍"                // For addReaction
    var roleId: String = ""                 // For addRole/removeRole
    var timeoutDuration: Int = 3600         // For timeoutMember (seconds)
    var kickReason: String = ""             // For kickMember
    var targetVoiceChannelId: String = ""   // For moveMember
    var newChannelName: String = ""         // For createChannel
    var webhookURL: String = ""             // For webhook
    var webhookContent: String = ""         // For webhook
    var delaySeconds: Int = 5               // For delay
    var variableName: String = ""           // For setVariable
    var variableValue: String = ""          // For setVariable
    var randomOptions: [String] = []        // For randomChoice
    var deleteDelaySeconds: Int = 0         // For deleteMessage (delayed delete)

    // AI Processing block fields
    var categories: String = ""              // For classifyMessage (comma-separated categories)
    var entityTypes: String = ""             // For extractEntities (comma-separated entity types)
    var rewriteStyle: String = ""            // For rewriteMessage (style description)

    // Unified Send Message content source (replaces replyWithAI, etc.)
    var contentSource: ContentSource = .custom

    // Message destination mode (per UX spec: replyToTrigger, sameChannel, specificChannel)
    var destinationMode: MessageDestination?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case serverId
        case channelId
        case mentionUser
        case replyToTriggerMessage
        case replyWithAI
        case message
        case statusText
        // New fields
        case dmContent
        case emoji
        case roleId
        case timeoutDuration
        case kickReason
        case targetVoiceChannelId
        case newChannelName
        case webhookURL
        case webhookContent
        case delaySeconds
        case variableName
        case variableValue
        case randomOptions
        case deleteDelaySeconds
        case categories
        case entityTypes
        case rewriteStyle
        case contentSource
        case destinationMode
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try container.decodeIfPresent(ActionType.self, forKey: .type) ?? .sendMessage
        serverId = try container.decodeIfPresent(String.self, forKey: .serverId) ?? ""
        channelId = try container.decodeIfPresent(String.self, forKey: .channelId) ?? ""
        mentionUser = try container.decodeIfPresent(Bool.self, forKey: .mentionUser) ?? true
        replyToTriggerMessage = try container.decodeIfPresent(Bool.self, forKey: .replyToTriggerMessage) ?? false
        replyWithAI = try container.decodeIfPresent(Bool.self, forKey: .replyWithAI) ?? false
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? "🔊 <@{userId}> connected to <#{channelId}>"
        statusText = try container.decodeIfPresent(String.self, forKey: .statusText) ?? "Voice notifier active"
        // New fields with defaults
        dmContent = try container.decodeIfPresent(String.self, forKey: .dmContent) ?? ""
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "👍"
        roleId = try container.decodeIfPresent(String.self, forKey: .roleId) ?? ""
        timeoutDuration = try container.decodeIfPresent(Int.self, forKey: .timeoutDuration) ?? 3600
        kickReason = try container.decodeIfPresent(String.self, forKey: .kickReason) ?? ""
        targetVoiceChannelId = try container.decodeIfPresent(String.self, forKey: .targetVoiceChannelId) ?? ""
        newChannelName = try container.decodeIfPresent(String.self, forKey: .newChannelName) ?? ""
        webhookURL = try container.decodeIfPresent(String.self, forKey: .webhookURL) ?? ""
        webhookContent = try container.decodeIfPresent(String.self, forKey: .webhookContent) ?? ""
        delaySeconds = try container.decodeIfPresent(Int.self, forKey: .delaySeconds) ?? 5
        variableName = try container.decodeIfPresent(String.self, forKey: .variableName) ?? ""
        variableValue = try container.decodeIfPresent(String.self, forKey: .variableValue) ?? ""
        randomOptions = try container.decodeIfPresent([String].self, forKey: .randomOptions) ?? []
        deleteDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .deleteDelaySeconds) ?? 0
        categories = try container.decodeIfPresent(String.self, forKey: .categories) ?? ""
        entityTypes = try container.decodeIfPresent(String.self, forKey: .entityTypes) ?? ""
        rewriteStyle = try container.decodeIfPresent(String.self, forKey: .rewriteStyle) ?? ""

        // Decode contentSource with legacy migration
        let decodedContentSource = try container.decodeIfPresent(ContentSource.self, forKey: .contentSource)
        let decodedReplyWithAI = try container.decodeIfPresent(Bool.self, forKey: .replyWithAI) ?? false

        // Migration: replyWithAI true -> contentSource = aiResponse
        if decodedContentSource == nil && decodedReplyWithAI && type == .sendMessage {
            contentSource = .aiResponse
        } else {
            contentSource = decodedContentSource ?? .custom
        }

        // Decode destinationMode with legacy migration
        let decodedDestinationMode = try container.decodeIfPresent(MessageDestination.self, forKey: .destinationMode)
        let decodedReplyToTrigger = try container.decodeIfPresent(Bool.self, forKey: .replyToTriggerMessage) ?? false
        let hasExplicitChannel = !(try container.decodeIfPresent(String.self, forKey: .channelId) ?? "").isEmpty

        // Migration logic per UX spec:
        // - Existing destinationMode -> keep it
        // - Legacy replyToTriggerMessage=true -> replyToTrigger
        // - Explicit serverId/channelId -> specificChannel
        // - Message trigger + no explicit IDs -> sameChannel (handled in UI defaults)
        // - Non-message trigger + no IDs -> specificChannel (conservative default)
        if let existingMode = decodedDestinationMode {
            destinationMode = existingMode
        } else if decodedReplyToTrigger {
            destinationMode = .replyToTrigger
        } else if hasExplicitChannel {
            destinationMode = .specificChannel
        } else {
            // Default: nil means conservative behavior (will be set by UI based on trigger type)
            destinationMode = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let legacyReplyToTrigger = type == .sendMessage ? (destinationMode == .replyToTrigger) : replyToTriggerMessage
        let legacyReplyWithAI = type == .sendMessage ? (contentSource == .aiResponse) : replyWithAI
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(channelId, forKey: .channelId)
        try container.encode(mentionUser, forKey: .mentionUser)
        try container.encode(legacyReplyToTrigger, forKey: .replyToTriggerMessage)
        try container.encode(legacyReplyWithAI, forKey: .replyWithAI)
        try container.encode(message, forKey: .message)
        try container.encode(statusText, forKey: .statusText)
        // New fields
        try container.encode(dmContent, forKey: .dmContent)
        try container.encode(emoji, forKey: .emoji)
        try container.encode(roleId, forKey: .roleId)
        try container.encode(timeoutDuration, forKey: .timeoutDuration)
        try container.encode(kickReason, forKey: .kickReason)
        try container.encode(targetVoiceChannelId, forKey: .targetVoiceChannelId)
        try container.encode(newChannelName, forKey: .newChannelName)
        try container.encode(webhookURL, forKey: .webhookURL)
        try container.encode(webhookContent, forKey: .webhookContent)
        try container.encode(delaySeconds, forKey: .delaySeconds)
        try container.encode(variableName, forKey: .variableName)
        try container.encode(variableValue, forKey: .variableValue)
        try container.encode(randomOptions, forKey: .randomOptions)
        try container.encode(deleteDelaySeconds, forKey: .deleteDelaySeconds)
        try container.encode(categories, forKey: .categories)
        try container.encode(entityTypes, forKey: .entityTypes)
        try container.encode(rewriteStyle, forKey: .rewriteStyle)
        try container.encode(contentSource, forKey: .contentSource)
        try container.encode(destinationMode, forKey: .destinationMode)
    }
}

/// Content source options for Send Message action
enum ContentSource: String, Codable, CaseIterable {
    case custom = "custom"
    case aiResponse = "ai.response"
    case aiSummary = "ai.summary"
    case aiClassification = "ai.classification"
    case aiEntities = "ai.entities"
    case aiRewrite = "ai.rewrite"

    var displayName: String {
        switch self {
        case .custom: return "Custom Message"
        case .aiResponse: return "AI Response"
        case .aiSummary: return "AI Summary"
        case .aiClassification: return "AI Classification"
        case .aiEntities: return "AI Entities"
        case .aiRewrite: return "AI Rewrite"
        }
    }
}

/// Destination mode for Send Message action
enum MessageDestination: String, Codable, CaseIterable {
    case replyToTrigger = "replyToTrigger"
    case sameChannel = "sameChannel"
    case specificChannel = "specificChannel"

    var displayName: String {
        switch self {
        case .replyToTrigger: return "Reply to Trigger"
        case .sameChannel: return "Same Channel"
        case .specificChannel: return "Specific Channel"
        }
    }
}

extension MessageDestination {
    static func defaultMode(for trigger: TriggerType?) -> MessageDestination {
        switch trigger {
        case .messageCreated, .reactionAdded:
            return .replyToTrigger
        case .slashCommand:
            return .sameChannel
        case .userJoinedVoice, .userLeftVoice, .userMovedVoice, .memberJoined, .memberLeft, .mediaAdded, .none:
            return .specificChannel
        }
    }

    static func defaultMode(for event: VoiceRuleEvent, context: PipelineContext) -> MessageDestination {
        if context.triggerMessageId != nil || event.triggerMessageId != nil {
            return .replyToTrigger
        }
        if context.triggerChannelId != nil || event.triggerChannelId != nil {
            return .sameChannel
        }
        return .specificChannel
    }
}

typealias Action = RuleAction

struct Rule: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = "New Action"
    var trigger: TriggerType?
    var conditions: [Condition] = []
    var modifiers: [RuleAction] = []
    var actions: [RuleAction] = []
    var aiBlocks: [RuleAction] = []
    var isEnabled: Bool = true

    // Legacy trigger properties - preserved for JSON compatibility, migrated to conditions on load
    var triggerServerId: String = ""
    var triggerVoiceChannelId: String = ""
    var triggerMessageContains: String = ""
    var replyToDMs: Bool = false
    var includeStageChannels: Bool = true

    /// UI state indicating trigger selection is in progress (Validation suspended)
    var isEditingTrigger: Bool = false

    /// Memberwise initializer (explicit due to custom Codable conformance)
    init(
        id: UUID = UUID(),
        name: String = "New Action",
        trigger: TriggerType? = nil,
        conditions: [Condition] = [],
        modifiers: [RuleAction] = [],
        actions: [RuleAction] = [],
        isEnabled: Bool = true,
        triggerServerId: String = "",
        triggerVoiceChannelId: String = "",
        triggerMessageContains: String = "",
        replyToDMs: Bool = false,
        includeStageChannels: Bool = true,
        isEditingTrigger: Bool = false
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.conditions = conditions
        self.modifiers = modifiers
        self.actions = actions
        self.isEnabled = isEnabled
        self.triggerServerId = triggerServerId
        self.triggerVoiceChannelId = triggerVoiceChannelId
        self.triggerMessageContains = triggerMessageContains
        self.replyToDMs = replyToDMs
        self.includeStageChannels = includeStageChannels
        self.isEditingTrigger = isEditingTrigger
    }

    var isEmptyRule: Bool {
        trigger == nil && conditions.isEmpty && actions.isEmpty && modifiers.isEmpty
    }

    static func empty() -> Rule {
        Rule(trigger: nil, conditions: [], modifiers: [], actions: [])
    }

    // MARK: - Codable Migration

    /// Coding keys for Rule
    enum CodingKeys: String, CodingKey {
        case id, name, trigger, conditions, modifiers, actions, aiBlocks, isEnabled
        case triggerServerId, triggerVoiceChannelId, triggerMessageContains, replyToDMs, includeStageChannels
    }

    /// Custom decoder that migrates legacy properties and separates AI blocks from actions
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        trigger = try container.decodeIfPresent(TriggerType.self, forKey: .trigger)
        conditions = try container.decode([Condition].self, forKey: .conditions)
        modifiers = try container.decode([RuleAction].self, forKey: .modifiers)
        actions = try container.decode([RuleAction].self, forKey: .actions)
        aiBlocks = try container.decodeIfPresent([RuleAction].self, forKey: .aiBlocks) ?? []
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)

        // Legacy properties - keep for backwards compatibility but migrate to conditions
        triggerServerId = try container.decodeIfPresent(String.self, forKey: .triggerServerId) ?? ""
        triggerVoiceChannelId = try container.decodeIfPresent(String.self, forKey: .triggerVoiceChannelId) ?? ""
        triggerMessageContains = try container.decodeIfPresent(String.self, forKey: .triggerMessageContains) ?? ""
        replyToDMs = try container.decodeIfPresent(Bool.self, forKey: .replyToDMs) ?? false
        includeStageChannels = try container.decodeIfPresent(Bool.self, forKey: .includeStageChannels) ?? true

        // Migration: Convert legacy trigger properties to filter conditions
        // Only add if not already present to avoid duplicates on repeated saves
        var migratedConditions: [Condition] = []

        // Migrate triggerServerId -> Condition.server
        if !triggerServerId.isEmpty && !conditions.contains(where: { $0.type == .server }) {
            migratedConditions.append(Condition(type: .server, value: triggerServerId))
        }

        // Migrate triggerVoiceChannelId -> Condition.voiceChannel
        if !triggerVoiceChannelId.isEmpty && !conditions.contains(where: { $0.type == .voiceChannel }) {
            migratedConditions.append(Condition(type: .voiceChannel, value: triggerVoiceChannelId))
        }

        // Migrate triggerMessageContains -> Condition.messageContains
        if !triggerMessageContains.isEmpty && triggerMessageContains != "up to?" && !conditions.contains(where: { $0.type == .messageContains }) {
            migratedConditions.append(Condition(type: .messageContains, value: triggerMessageContains))
        }

        // Append migrated conditions to existing conditions
        if !migratedConditions.isEmpty {
            conditions.append(contentsOf: migratedConditions)
        }

        // Migration: Move AI blocks from actions to aiBlocks for backwards compatibility
        let aiBlockTypes: [ActionType] = [.generateAIResponse, .summariseMessage, .classifyMessage, .extractEntities, .rewriteMessage]
        let (aiBlocksFromActions, remainingActions) = actions.reduce(into: ([RuleAction](), [RuleAction]())) { result, action in
            if aiBlockTypes.contains(action.type) {
                result.0.append(action)
            } else {
                result.1.append(action)
            }
        }
        if !aiBlocksFromActions.isEmpty {
            aiBlocks.append(contentsOf: aiBlocksFromActions)
            actions = remainingActions
        }

        actions = actions.map { action in
            guard action.type == .sendMessage, action.destinationMode == nil else { return action }
            var updated = action
            if action.replyToTriggerMessage {
                updated.destinationMode = .replyToTrigger
            } else if !action.channelId.isEmpty || !action.serverId.isEmpty {
                updated.destinationMode = .specificChannel
            } else {
                updated.destinationMode = MessageDestination.defaultMode(for: trigger)
            }
            return updated
        }
    }

    /// Provides the full pipeline of blocks for the rule engine in execution order:
    /// AI Processing → Message Modifiers → Actions
    var processedActions: [RuleAction] {
        var pipeline: [RuleAction] = []

        // 1. AI Processing blocks first
        pipeline.append(contentsOf: aiBlocks)

        // 2. Message Modifiers
        pipeline.append(contentsOf: modifiers)

        // 3. Actions (excluding AI blocks and extracting embedded modifiers)
        for action in actions {
            var actionWithModifiers = action

            // Legacy: replyWithAI toggle creates an AI block
            if action.type == .sendMessage && action.replyWithAI && action.contentSource == .custom {
                var aiBlock = RuleAction()
                aiBlock.type = .generateAIResponse
                // Insert AI block at the beginning (before modifiers)
                pipeline.insert(aiBlock, at: aiBlocks.count)
                actionWithModifiers.replyWithAI = false
            }

            // Extract reply-to-trigger as a modifier
            if action.type == .sendMessage && action.replyToTriggerMessage && action.destinationMode == nil {
                var replyBlock = RuleAction()
                replyBlock.type = .replyToTrigger
                pipeline.append(replyBlock)
                actionWithModifiers.replyToTriggerMessage = false
            }

            // Extract mention disable as a modifier
            if !action.mentionUser { // Default was true in legacy
                var disableMentionBlock = RuleAction()
                disableMentionBlock.type = .disableMention
                pipeline.append(disableMentionBlock)
                actionWithModifiers.mentionUser = true // Reset so we don't repeat
            }

            pipeline.append(actionWithModifiers)
        }

        return pipeline
    }

    var triggerSummary: String {
        guard let trigger = trigger else { return "No trigger set" }
        switch trigger {
        case .userJoinedVoice: return "When someone joins voice"
        case .userLeftVoice: return "When someone leaves voice"
        case .userMovedVoice: return "When someone moves voice"
        case .messageCreated: return "When a message is received"
        case .memberJoined: return "When a member joins the server"
        case .memberLeft: return "When a member leaves the server"
        case .reactionAdded: return "When a reaction is added"
        case .slashCommand: return "When a slash command is used"
        case .mediaAdded: return "When new media is detected"
        }
    }

    /// Returns any blocks that are incompatible with the current trigger
    var incompatibleBlocks: [UUID] {
        guard let trigger = trigger else { return [] }
        let available = trigger.providedVariables
        var ids: [UUID] = []

        for condition in conditions {
            if !condition.type.requiredVariables.isSubset(of: available) {
                ids.append(condition.id)
            }
        }
        for modifier in modifiers {
            if !modifier.type.requiredVariables.isSubset(of: available) {
                ids.append(modifier.id)
            }
        }
        for action in actions {
            if !action.type.requiredVariables.isSubset(of: available) {
                ids.append(action.id)
            }
        }
        return ids
    }

    var validationIssues: [ValidationIssue] {
        guard let trigger = trigger, !isEditingTrigger else {
            return []
        }

        var issues: [ValidationIssue] = []
        let availableVariables = trigger.providedVariables

        // Check conditions for variable availability
        for condition in conditions {
            let requiredVars = condition.type.requiredVariables
            let missingVars = requiredVars.subtracting(availableVariables)
            if !missingVars.isEmpty {
                issues.append(.init(
                    severity: .warning, // Task 1: Use warning style
                    message: "Requires \(requiredVars.friendlyRequirement)", // Task 1: User-friendly wording
                    blockType: .condition,
                    blockId: condition.id
                ))
            }
        }

        // Check modifiers for variable availability and permissions
        for modifier in modifiers {
            let requiredVars = modifier.type.requiredVariables
            let missingVars = requiredVars.subtracting(availableVariables)
            if !missingVars.isEmpty {
                issues.append(.init(
                    severity: .warning, // Task 1: Use warning style
                    message: "Requires \(requiredVars.friendlyRequirement)", // Task 1: User-friendly wording
                    blockType: .modifier,
                    blockId: modifier.id
                ))
            }

            let requiredPerms = modifier.type.requiredPermissions
            if !requiredPerms.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    message: "Requires permissions: \(requiredPerms.map(\.displayName).joined(separator: ", "))",
                    blockType: .modifier,
                    blockId: modifier.id
                ))
            }
        }

        // Check actions for variable availability and permissions
        for action in actions {
            let requiredVars = action.type.requiredVariables
            let missingVars = requiredVars.subtracting(availableVariables)
            if !missingVars.isEmpty {
                issues.append(.init(
                    severity: .warning, // Task 1: Use warning style
                    message: "Requires \(requiredVars.friendlyRequirement)", // Task 1: User-friendly wording
                    blockType: .action,
                    blockId: action.id
                ))
            }

            // Task 5: Prevent empty Send Message actions
            if action.type == .sendMessage,
               action.contentSource == .custom,
               action.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "Message content is required for 'Send Message' actions.",
                    blockType: .action,
                    blockId: action.id
                ))
            }

            if action.type == .sendMessage,
               (action.destinationMode ?? MessageDestination.defaultMode(for: trigger)) == .specificChannel,
               action.channelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "Select a channel when destination is set to 'Specific Channel'.",
                    blockType: .action,
                    blockId: action.id
                ))
            }

            // Check permissions (warnings, not errors - bot may have permissions)
            let requiredPerms = action.type.requiredPermissions
            if !requiredPerms.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    message: "Requires permissions: \(requiredPerms.map(\.displayName).joined(separator: ", "))",
                    blockType: .action,
                    blockId: action.id
                ))
            }
            }

            // Rule must contain at least one Action
            if actions.isEmpty {
            issues.append(.init(
                severity: .warning,
                message: "This rule has no actions and will not produce any output. Add an Action such as “Send Message”.",
                blockType: .rule,
                blockId: id
            ))
            }

            return issues
    }

    /// Checks if rule has any blocking errors
    var hasBlockingErrors: Bool {
        validationIssues.contains { $0.severity == .error }
    }

    /// Returns just the errors (not warnings)
    var validationErrors: [ValidationIssue] {
        validationIssues.filter { $0.severity == .error }
    }

    /// Returns just the warnings
    var validationWarnings: [ValidationIssue] {
        validationIssues.filter { $0.severity == .warning }
    }
}

/// Represents a validation issue with a rule
struct ValidationIssue: Identifiable, Hashable {
    let id = UUID()
    let severity: ValidationSeverity
    let message: String
    let blockType: BlockType
    let blockId: UUID

    enum ValidationSeverity: String, Codable, CaseIterable {
        case warning = "Warning"
        case error = "Error"

        var icon: String {
            switch self {
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }

        var color: String {
            switch self {
            case .warning: return "orange"
            case .error: return "red"
            }
        }
    }

    enum BlockType: String, Codable, CaseIterable {
        case rule = "Rule"
        case trigger = "Trigger"
        case condition = "Filter"
        case modifier = "Modifier"
        case action = "Action"
    }
}
