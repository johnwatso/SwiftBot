import Foundation
import SwiftUI

// Shared utilities extracted from the legacy RuleEngineModels.swift.
// These are not rule-specific and remain in active use across the app.

@MainActor
protocol BotPlugin {
    var name: String { get }
    func register(on bus: EventBus) async
    func unregister(from bus: EventBus) async
}

@MainActor
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

@MainActor
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
            Task { @MainActor in
                self.voiceDurations[event.userId, default: 0] += max(0, event.durationSeconds)
            }
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

// A simple helper for interacting with the macOS Keychain.

// MARK: - Navigation Models

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case patchy = "Patchy"
    case welcomeFlow = "Welcome Flow"
    case automations = "Automations"
    case moderation = "Moderation"
    case commands = "Commands"
    case activity = "Activity"
    case wikiBridge = "Lookup"
    case aiBots = "AI Bots"
    case recordings = "Recordings"
    case analytics = "Analytics"
    case swiftMesh = "SwiftMesh"
    case sweep = "Sweep"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .patchy: return "square.and.arrow.down.badge.checkmark.fill"
        case .welcomeFlow: return "person.crop.circle.badge.plus"
        case .automations: return "bolt.badge.automatic.fill"
        case .moderation: return "shield.lefthalf.filled"
        case .commands: return "terminal.fill"
        case .activity: return "list.bullet.clipboard.fill"
        case .wikiBridge: return "rectangle.and.text.magnifyingglass"
        case .aiBots: return "sparkles.rectangle.stack.fill"
        case .recordings: return "video.fill"
        case .analytics: return "chart.line.uptrend.xyaxis"
        case .swiftMesh: return "point.3.filled.connected.trianglepath.dotted"
        case .sweep: return "rectangle.stack.fill.badge.minus"
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
