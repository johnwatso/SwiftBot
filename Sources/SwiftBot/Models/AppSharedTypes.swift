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

/// One group of sidebar rows. A group without a title renders headerless.
struct SidebarItemGroup: Identifiable {
    let title: String?
    let items: [SidebarItem]

    var id: String { title ?? items.first?.rawValue ?? "" }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case discord = "Discord"
    case activity = "Activity"
    case recordings = "Recordings"
    case swiftMesh = "SwiftMesh"
    case webInterface = "Web Interface"
    case integrations = "Integrations"

    var id: String { rawValue }

    /// Outline glyphs. The sidebar fills the selected row's glyph, which is the
    /// form each page's header uses.
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .discord: return "bubble.left.and.bubble.right"
        case .activity: return "list.bullet.clipboard"
        case .recordings: return "video"
        case .swiftMesh: return "point.3.connected.trianglepath.dotted"
        case .webInterface: return "globe"
        case .integrations: return "puzzlepiece.extension"
        }
    }

    /// Host settings for this Mac that only the native app shows. The WebUI
    /// has no page for them by design (see the web secrets policy).
    static let nativeOnlyItems: Set<SidebarItem> = [.discord, .webInterface, .integrations]

    /// The order and grouping the dashboard sidebar renders.
    ///
    /// The sidebar is driven by this list rather than hand-written rows so a new
    /// `SidebarItem` cannot be added to the enum, given a detail view, and then
    /// silently never appear in the app. `SidebarLayoutTests` asserts every case
    /// is listed exactly once. Every destination is a direct row. Feature
    /// pages (rules, commands and the like) live only in the WebUI.
    ///
    /// The native app is the host console: the bot's status, its services'
    /// settings, and its log. One short, untitled group, as in SwiftMiner.
    static let sidebarSections: [SidebarItemGroup] = [
        SidebarItemGroup(title: nil, items: [.overview, .discord, .webInterface, .swiftMesh, .integrations, .recordings, .activity])
    ]
}

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

