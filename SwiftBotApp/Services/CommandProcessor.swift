import Foundation

final class CommandProcessor {
    typealias ResolvedWikiCommand = (source: WikiSource, command: WikiCommand)

    struct RuntimeConfiguration {
        var commandsEnabled: Bool
        var prefixCommandsEnabled: Bool
        var slashCommandsEnabled: Bool
        var wikiEnabled: Bool
        var prefix: String
        var helpSettings: HelpSettings
    }

    struct PrefixContext {
        var commandText: String
        var username: String
        var channelId: String
        var raw: [String: DiscordJSON]
        var bypassSystemToggles: Bool
    }

    struct SlashContext {
        var channelId: String
        var username: String
        var rawLikeMessage: [String: DiscordJSON]
    }

    typealias SlashResponsePayload = (content: String?, embeds: [[String: Any]]?)

    struct Dependencies {
        var configuration: () -> RuntimeConfiguration
        var canonicalPrefixCommandName: (String) -> String
        var isCommandEnabled: (String, String) -> Bool
        var buildHelpCatalog: (String) -> CommandCatalog
        var send: (String, String) async -> Bool
        var sendEmbed: (String, [String: Any]) async -> Bool
        var generateHelpReply: ([Message], String) async -> String?
        var rollDice: (String) -> String?
        var generateImageCommand: (String, String, String, String) async -> Bool
        var authorId: ([String: DiscordJSON]) -> String?
        var clusterCommand: (String, String) async -> Bool
        var setNotificationChannel: ([String: DiscordJSON], String) async -> Bool
        var updateIgnoredChannels: ([String], [String: DiscordJSON], String) async -> Bool
        var notifyStatus: ([String: DiscordJSON], String) async -> Bool
        var canRunDebugCommand: ([String: DiscordJSON]) async -> Bool
        var refreshDebugSnapshot: () async -> Void
        var debugSummaryEmbed: () -> [String: Any]
        var bugReportText: ([String: DiscordJSON]) -> String
        var weeklySummary: () -> String
        var fetchFinalsMeta: () async -> String?
        var resolveWikiCommand: (String) -> ResolvedWikiCommand?
        var defaultWikiCommand: () -> ResolvedWikiCommand?
        var performWikiLookup: (WikiCommand, WikiSource, String, String) async -> Bool
        var handleLogABugSlash: ([String: DiscordJSON], String, String, String) async -> (ok: Bool, message: String)
        var handleFeatureRequestSlash: ([String: DiscordJSON], String, String, String, String?) async -> (ok: Bool, message: String)
        var lookupFinalsWiki: (String) async -> FinalsWikiLookupResult?
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func executePrefixCommand(_ context: PrefixContext) async -> Bool {
        let tokens = context.commandText.split(separator: " ").map(String.init)
        guard let command = tokens.first?.lowercased() else { return false }

        let config = dependencies.configuration()
        if !context.bypassSystemToggles {
            guard config.commandsEnabled else {
                return await dependencies.send(context.channelId, "⛔ Commands are disabled in command settings.")
            }
            guard config.prefixCommandsEnabled else {
                return await dependencies.send(context.channelId, "⛔ Prefix commands are disabled in command settings.")
            }
        }

        let canonicalCommand = dependencies.canonicalPrefixCommandName(command)
        guard dependencies.isCommandEnabled(canonicalCommand, "prefix") else {
            return await dependencies.send(
                context.channelId,
                "⛔ `\(config.prefix)\(canonicalCommand)` is disabled in command settings."
            )
        }

        switch command {
        case "help":
            let catalog = dependencies.buildHelpCatalog(config.prefix)
            let renderer = HelpRenderer(prefix: config.prefix, helpSettings: config.helpSettings)
            let targetCommand = tokens.dropFirst().first?.lowercased()

            if let target = targetCommand {
                if let entry = catalog.entry(for: target) {
                    return await dependencies.send(context.channelId, renderer.detail(for: entry))
                } else {
                    return await dependencies.send(
                        context.channelId,
                        "❓ Unknown command `\(config.prefix)\(target)`. Type `\(config.prefix)help` for a full list."
                    )
                }
            }

            var aiIntro: String?
            if config.helpSettings.mode != .classic {
                let message = Message(
                    channelID: context.channelId,
                    userID: "help-request",
                    username: "user",
                    content: "Write a short intro for a SwiftBot help embed.",
                    role: .user
                )
                aiIntro = await dependencies.generateHelpReply([message], renderer.aiIntroPrompt(catalog: catalog))
            }

            let embed = renderer.embedOverview(catalog: catalog, aiDescription: aiIntro)
            return await dependencies.sendEmbed(context.channelId, embed)
        case "ping":
            return await dependencies.send(context.channelId, "🏓 Pong! Gateway latency is currently live via heartbeat ACK.")
        case "roll":
            guard tokens.count >= 2, let output = dependencies.rollDice(tokens[1]) else {
                return await unknown(channelId: context.channelId, prefix: config.prefix)
            }
            return await dependencies.send(context.channelId, output)
        case "8ball":
            let responses = ["Yes.", "No.", "It is certain.", "Ask again later.", "Very doubtful."]
            return await dependencies.send(context.channelId, "🎱 \(responses.randomElement()!)")
        case "poll":
            return await dependencies.send(context.channelId, "📊 Poll created! Add reactions to vote.")
        case "image", "imagine":
            let prompt = tokens.dropFirst().joined(separator: " ")
            let userId = dependencies.authorId(context.raw) ?? "unknown-user"
            return await dependencies.generateImageCommand(prompt, userId, context.username, context.channelId)
        case "userinfo":
            return await dependencies.send(context.channelId, "👤 User: \(context.username)")
        case "cluster", "worker":
            let action = tokens.dropFirst().first?.lowercased() ?? "status"
            return await dependencies.clusterCommand(action, context.channelId)
        case "setchannel":
            return await dependencies.setNotificationChannel(context.raw, context.channelId)
        case "ignorechannel":
            return await dependencies.updateIgnoredChannels(tokens, context.raw, context.channelId)
        case "notifystatus":
            return await dependencies.notifyStatus(context.raw, context.channelId)
        case "debug":
            guard await dependencies.canRunDebugCommand(context.raw) else {
                return await dependencies.send(
                    context.channelId,
                    "⛔ `\(config.prefix)debug` is restricted to server owners or admins."
                )
            }
            await dependencies.refreshDebugSnapshot()
            return await dependencies.sendEmbed(context.channelId, dependencies.debugSummaryEmbed())
        case "bugreport":
            return await dependencies.send(context.channelId, dependencies.bugReportText(context.raw))
        case "weekly":
            return await dependencies.send(context.channelId, dependencies.weeklySummary())
        case "meta":
            if let result = await dependencies.fetchFinalsMeta() {
                return await dependencies.send(context.channelId, result)
            }
            return await dependencies.send(
                context.channelId,
                "Couldn't fetch meta data right now. Source: https://skycoach.gg/blog/the-finals/articles/the-finals-best-builds"
            )
        default:
            if let resolvedWikiCommand = dependencies.resolveWikiCommand(command) {
                guard config.wikiEnabled else {
                    return await dependencies.send(
                        context.channelId,
                        "📘 WikiBridge is disabled. Enable it from the WikiBridge page."
                    )
                }
                let query = tokens.dropFirst().joined(separator: " ")
                return await dependencies.performWikiLookup(
                    resolvedWikiCommand.command,
                    resolvedWikiCommand.source,
                    query,
                    context.channelId
                )
            }
            _ = await unknown(channelId: context.channelId, prefix: config.prefix)
            return false
        }
    }

    func executeSlashCommand(command: String, data: [String: DiscordJSON], context: SlashContext) async -> SlashResponsePayload {
        func embed(title: String, description: String, color: Int = 5_793_266) -> SlashResponsePayload {
            (
                content: nil,
                embeds: [[
                    "title": title,
                    "description": description,
                    "color": color
                ]]
            )
        }

        func statusEmbed(title: String, ok: Bool) -> SlashResponsePayload {
            embed(title: title, description: ok ? "✅ Completed." : "❌ Failed.", color: ok ? 3_062_954 : 15_790_767)
        }

        let config = dependencies.configuration()

        guard config.commandsEnabled else {
            return embed(title: "Commands Disabled", description: "Commands are turned off in SwiftBot settings.", color: 15_790_767)
        }

        guard config.slashCommandsEnabled else {
            return embed(title: "Slash Commands Disabled", description: "Slash commands are turned off in SwiftBot settings.", color: 15_790_767)
        }

        guard dependencies.isCommandEnabled(command, "slash") else {
            return embed(title: "Slash Command Disabled", description: "`/\(command)` is disabled in command settings.", color: 15_790_767)
        }

        switch command {
        case "help":
            let commandName = Self.slashOptionString(named: "command", in: data)
            let prefixCommand = commandName.map { "help \($0)" } ?? "help"
            _ = await executePrefixCommand(
                .init(
                    commandText: prefixCommand,
                    username: context.username,
                    channelId: context.channelId,
                    raw: context.rawLikeMessage,
                    bypassSystemToggles: true
                )
            )
            return embed(title: "Help", description: "📘 Posted help details in this channel.")
        case "ping":
            return embed(title: "Ping", description: "🏓 Pong!")
        case "roll":
            let notation = Self.slashOptionString(named: "notation", in: data) ?? "1d6"
            if let result = dependencies.rollDice(notation) {
                return embed(title: "Dice Roll", description: result)
            }
            return embed(title: "Dice Roll", description: "Invalid roll notation. Try `2d6`.", color: 15_790_767)
        case "8ball":
            let responses = ["Yes.", "No.", "It is certain.", "Ask again later.", "Very doubtful."]
            return embed(title: "Magic 8-Ball", description: "🎱 \(responses.randomElement() ?? "Ask again later.")")
        case "poll":
            let question = Self.slashOptionString(named: "question", in: data) ?? "New poll"
            return embed(title: "Poll", description: "📊 \(question)")
        case "userinfo":
            return embed(title: "User Info", description: "👤 \(context.username)")
        case "cluster":
            let action = Self.slashOptionString(named: "action", in: data) ?? "status"
            let ok = await dependencies.clusterCommand(action, context.channelId)
            return statusEmbed(title: "Cluster", ok: ok)
        case "weekly":
            return embed(title: "Weekly Summary", description: dependencies.weeklySummary())
        case "bugreport":
            return embed(title: "Bug Report", description: dependencies.bugReportText(context.rawLikeMessage))
        case "logabug":
            let errorText = Self.slashOptionString(named: "error", in: data)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !errorText.isEmpty else {
                return embed(title: "Log a Bug", description: "Usage: `/logabug error:<what happened>`", color: 15_790_767)
            }
            let result = await dependencies.handleLogABugSlash(context.rawLikeMessage, context.username, context.channelId, errorText)
            return embed(title: "Log a Bug", description: result.message, color: result.ok ? 3_062_954 : 15_790_767)
        case "featurerequest":
            let featureText = Self.slashOptionString(named: "feature", in: data)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reasonText = Self.slashOptionString(named: "reason", in: data)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !featureText.isEmpty else {
                return embed(title: "Feature Request", description: "Usage: `/featurerequest feature:<feature> [reason:<why>]`", color: 15_790_767)
            }
            let result = await dependencies.handleFeatureRequestSlash(
                context.rawLikeMessage,
                context.username,
                context.channelId,
                featureText,
                reasonText
            )
            return embed(title: "Feature Request", description: result.message, color: result.ok ? 3_062_954 : 15_790_767)
        case "debug":
            guard await dependencies.canRunDebugCommand(context.rawLikeMessage) else {
                return embed(title: "Debug", description: "⛔ Restricted to server owners or admins.", color: 15_790_767)
            }
            await dependencies.refreshDebugSnapshot()
            return (content: nil, embeds: [dependencies.debugSummaryEmbed()])
        case "setchannel":
            if await dependencies.setNotificationChannel(context.rawLikeMessage, context.channelId) {
                return embed(title: "Notifications", description: "✅ Notification channel set.")
            }
            return embed(title: "Notifications", description: "❌ Failed setting notification channel.", color: 15_790_767)
        case "ignorechannel":
            let action = Self.slashOptionString(named: "action", in: data) ?? "list"
            if action == "list" {
                let ok = await dependencies.updateIgnoredChannels(["ignorechannel", "list"], context.rawLikeMessage, context.channelId)
                return statusEmbed(title: "Ignored Channels", ok: ok)
            }
            let channelID = Self.slashOptionChannelID(named: "channel", in: data) ?? ""
            if channelID.isEmpty {
                return embed(title: "Ignored Channels", description: "Provide a channel for add/remove.", color: 15_790_767)
            }
            let token = action == "remove" ? "remove" : "add"
            let ok = await dependencies.updateIgnoredChannels(["ignorechannel", token, channelID], context.rawLikeMessage, context.channelId)
            return statusEmbed(title: "Ignored Channels", ok: ok)
        case "notifystatus":
            let ok = await dependencies.notifyStatus(context.rawLikeMessage, context.channelId)
            return statusEmbed(title: "Notification Status", ok: ok)
        case "image":
            let prompt = Self.slashOptionString(named: "prompt", in: data) ?? ""
            let userId = dependencies.authorId(context.rawLikeMessage) ?? "unknown-user"
            let ok = await dependencies.generateImageCommand(prompt, userId, context.username, context.channelId)
            return statusEmbed(title: "Image Generation", ok: ok)
        case "wiki":
            let query = Self.slashOptionString(named: "query", in: data) ?? ""
            guard config.wikiEnabled else {
                return embed(title: "WikiBridge", description: "WikiBridge is disabled.", color: 15_790_767)
            }
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return embed(title: "WikiBridge", description: "Usage: `/wiki query:<text>`", color: 15_790_767)
            }
            guard let resolved = dependencies.resolveWikiCommand("wiki") ?? dependencies.defaultWikiCommand() else {
                return embed(title: "WikiBridge", description: "No enabled wiki source/command found.", color: 15_790_767)
            }
            let ok = await dependencies.performWikiLookup(resolved.command, resolved.source, query, context.channelId)
            return statusEmbed(title: "WikiBridge Lookup", ok: ok)
        case "compare":
            let left = Self.slashOptionString(named: "weapon_a", in: data)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let right = Self.slashOptionString(named: "weapon_b", in: data)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !left.isEmpty, !right.isEmpty else {
                return embed(title: "Weapon Compare", description: "Usage: `/compare weapon_a:<weapon> weapon_b:<weapon>`", color: 15_790_767)
            }

            guard let leftResult = await dependencies.lookupFinalsWiki(left),
                  let leftStats = leftResult.weaponStats else {
                return embed(title: "Weapon Compare", description: "Couldn’t find weapon stats for `\(left)`.", color: 15_790_767)
            }
            guard let rightResult = await dependencies.lookupFinalsWiki(right),
                  let rightStats = rightResult.weaponStats else {
                return embed(title: "Weapon Compare", description: "Couldn’t find weapon stats for `\(right)`.", color: 15_790_767)
            }

            func value(_ stat: String?) -> String {
                let trimmed = stat?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? "N/A" : trimmed
            }

            let fields: [[String: Any]] = [
                [
                    "name": leftResult.title,
                    "value": """
                    Type: \(value(leftStats.type))
                    Body: \(value(leftStats.bodyDamage))
                    Head: \(value(leftStats.headshotDamage))
                    RPM: \(value(leftStats.fireRate))
                    Magazine: \(value(leftStats.magazineSize))
                    Reload: \(value(leftStats.shortReload)) / \(value(leftStats.longReload))
                    """,
                    "inline": true
                ],
                [
                    "name": rightResult.title,
                    "value": """
                    Type: \(value(rightStats.type))
                    Body: \(value(rightStats.bodyDamage))
                    Head: \(value(rightStats.headshotDamage))
                    RPM: \(value(rightStats.fireRate))
                    Magazine: \(value(rightStats.magazineSize))
                    Reload: \(value(rightStats.shortReload)) / \(value(rightStats.longReload))
                    """,
                    "inline": true
                ]
            ]
            return (
                content: nil,
                embeds: [[
                    "title": "THE FINALS Weapon Compare",
                    "description": "\(leftResult.title) vs \(rightResult.title)",
                    "color": 5_793_266,
                    "fields": fields
                ]]
            )
        case "meta":
            if let result = await dependencies.fetchFinalsMeta() {
                return embed(title: "THE FINALS Meta", description: result)
            }
            return embed(
                title: "THE FINALS Meta",
                description: "Couldn't fetch meta data right now.\nSource: https://skycoach.gg/blog/the-finals/articles/the-finals-best-builds",
                color: 15_790_767
            )
        default:
            return embed(title: "Slash Command", description: "Unknown slash command.", color: 15_790_767)
        }
    }

    private func unknown(channelId: String, prefix: String) async -> Bool {
        await dependencies.send(channelId, "❓ I don't know that command! Type \(prefix)help to see all available commands.")
    }

    private static func slashOptionString(named name: String, in data: [String: DiscordJSON]) -> String? {
        guard case let .array(options)? = data["options"] else { return nil }
        for option in options {
            guard case let .object(map) = option,
                  case let .string(optionName)? = map["name"],
                  optionName == name else { continue }
            if case let .string(value)? = map["value"] {
                return value
            }
        }
        return nil
    }

    private static func slashOptionChannelID(named name: String, in data: [String: DiscordJSON]) -> String? {
        slashOptionString(named: name, in: data)
    }
}
