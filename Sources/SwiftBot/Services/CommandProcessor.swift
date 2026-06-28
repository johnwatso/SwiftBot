import Foundation

@MainActor
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
        var authorId: ([String: DiscordJSON]) -> String?
        var clusterCommand: (String, String) async -> Bool
        var setNotificationChannel: ([String: DiscordJSON], String) async -> Bool
        var updateIgnoredChannels: ([String], [String: DiscordJSON], String) async -> Bool
        var notifyStatus: ([String: DiscordJSON], String) async -> Bool
        var canRunDebugCommand: ([String: DiscordJSON]) async -> Bool
        var refreshDebugSnapshot: () async -> Void
        var debugSummaryEmbed: () -> [String: Any]
        var weeklySummary: () -> String
        var fetchFinalsMeta: () async -> String?
        var resolveWikiCommand: (String) -> ResolvedWikiCommand?
        var defaultWikiCommand: () -> ResolvedWikiCommand?
        var performWikiLookup: (WikiCommand, WikiSource, String, String) async -> Bool
        var lookupFinalsWiki: (String) async -> FinalsWikiLookupResult?
        var runMusicLookup: (String?, String?, String?, String, String) async -> (ok: Bool, message: String)
        var pickMusicLookup: (Int, String, String) async -> (ok: Bool, message: String)
        var swiftMinerCommand: (String, String, String) async -> (ok: Bool, message: String)
        var swiftMinerSlashCommand: (String, String?, String, String) async -> (ok: Bool, message: String, embed: [String: Any]?)
        var fetchSteamAppInfo: (String) async -> (ok: Bool, embed: [String: Any]?)
        var sweepCommand: (String) async -> (ok: Bool, message: String)
        var announceCommand: (String, [String: DiscordJSON]) async -> (ok: Bool, message: String)
        var randomTeamsCommand: (Int, Int?, [String: DiscordJSON]) async -> (ok: Bool, message: String)
        var lookupUserTimeZone: (String) -> String?
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
            return await dependencies.send(context.channelId, "🏓 Pong! Gateway heartbeat is currently live via ACK.")
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
        case "music":
            if tokens.count >= 2, ["help", "-h", "--help"].contains(tokens[1].lowercased()) {
                return await dependencies.send(context.channelId, HelpRenderer.detailedMusicGuide(prefix: config.prefix))
            }
            let userId = dependencies.authorId(context.raw) ?? "unknown-user"
            if tokens.count >= 3, tokens[1].lowercased() == "pick", let selection = Int(tokens[2]) {
                let result = await dependencies.pickMusicLookup(selection, userId, context.channelId)
                return await dependencies.send(context.channelId, result.message)
            }

            let argumentText = tokens.dropFirst().joined(separator: " ")
            let parsed = Self.parseMusicInput(argumentText)
            let result = await dependencies.runMusicLookup(
                parsed.query,
                parsed.title,
                parsed.artist,
                userId,
                context.channelId
            )
            return await dependencies.send(context.channelId, result.message)
        case "miner", "swiftminer":
            let action = tokens.dropFirst().first ?? "status"
            let userId = dependencies.authorId(context.raw) ?? "unknown-user"
            if action.lowercased() == "prioritise" || action.lowercased() == "prioritize" {
                let game = tokens.dropFirst(2).joined(separator: " ")
                let result = await dependencies.swiftMinerSlashCommand(action, game, userId, context.channelId)
                if let embed = result.embed {
                    return await dependencies.sendEmbed(context.channelId, embed)
                }
                return await dependencies.send(context.channelId, result.message)
            }
            let result = await dependencies.swiftMinerCommand(action, userId, context.channelId)
            return await dependencies.send(context.channelId, result.message)
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
        case "weekly":
            return await dependencies.send(context.channelId, dependencies.weeklySummary())
        case "randomteams":
            let parsed = Self.parseRandomTeamsArguments(Array(tokens.dropFirst()))
            if let message = parsed.error {
                return await dependencies.send(context.channelId, message)
            }
            if let request = parsed.request {
                let result = await dependencies.randomTeamsCommand(request.teamCount, request.maxSize, context.raw)
                return await dependencies.send(context.channelId, result.message)
            }
            return await dependencies.send(context.channelId, "Usage: `/randomteams 2 max size 3`.")
        case "meta":
            if let result = await dependencies.fetchFinalsMeta() {
                return await dependencies.send(context.channelId, result)
            }
            return await dependencies.send(
                context.channelId,
                "Couldn't fetch meta data right now. Source: https://skycoach.gg/blog/the-finals/articles/the-finals-best-builds"
            )
        case "timestamp", "ts":
            let input = tokens.dropFirst().joined(separator: " ")
            let userID = dependencies.authorId(context.raw)
            let savedTZ = userID.flatMap { dependencies.lookupUserTimeZone($0) }
            return await dependencies.send(
                context.channelId,
                Self.timestampReply(for: input, savedTimeZoneID: savedTZ)
            )
        default:
            if let resolvedWikiCommand = dependencies.resolveWikiCommand(command) {
                guard config.wikiEnabled else {
                    return await dependencies.send(
                        context.channelId,
                        "📘 Lookup is disabled. Enable it from the Lookup page."
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
        case "sweep":
            let action = Self.slashOptionString(named: "action", in: data) ?? "status"
            let result = await dependencies.sweepCommand(action)
            return embed(title: "Sweep", description: result.message, color: result.ok ? 3_062_954 : 15_790_767)
        case "announce":
            let action = Self.slashOptionString(named: "action", in: data) ?? "join"
            guard action == "join" || action == "rejoin" else {
                return embed(title: "Announcer", description: "Usage: `/announce join` or `/announce rejoin`.", color: 15_790_767)
            }
            let result = await dependencies.announceCommand(action, context.rawLikeMessage)
            return embed(title: "Announcer", description: result.message, color: result.ok ? 3_062_954 : 15_790_767)
        case "weekly":
            return embed(title: "Weekly Summary", description: dependencies.weeklySummary())
        case "randomteams":
            let teamCount = Self.slashOptionInt(named: "teams", in: data) ?? 0
            let maxSize = Self.slashOptionInt(named: "max_size", in: data)
            let result = await dependencies.randomTeamsCommand(teamCount, maxSize, context.rawLikeMessage)
            return embed(title: "Random Teams", description: result.message, color: result.ok ? 3_062_954 : 15_790_767)
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
        case "music":
            let userId = dependencies.authorId(context.rawLikeMessage) ?? "unknown-user"
            if let query = Self.slashOptionString(named: "query", in: data)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
               ["help", "-h", "--help"].contains(query) {
                return embed(title: "Music + Playlist Help", description: HelpRenderer.detailedMusicGuide(prefix: config.prefix))
            }
            let pick = Self.slashOptionInt(named: "pick", in: data)
            if let pick {
                let result = await dependencies.pickMusicLookup(pick, userId, context.channelId)
                return embed(title: "Music Lookup", description: result.message, color: result.ok ? 3_062_954 : 15_790_767)
            }

            let query = Self.slashOptionString(named: "query", in: data)
            let title = Self.slashOptionString(named: "title", in: data)
            let artist = Self.slashOptionString(named: "artist", in: data)
            let result = await dependencies.runMusicLookup(query, title, artist, userId, context.channelId)
            return embed(title: "Music Lookup", description: result.message, color: result.ok ? 3_062_954 : 15_790_767)
        case "miner":
            let action = Self.slashOptionString(named: "action", in: data) ?? "status"
            let game = Self.slashOptionString(named: "game", in: data)
            let userId = dependencies.authorId(context.rawLikeMessage) ?? "unknown-user"
            if action.lowercased() == "prioritise" || action.lowercased() == "prioritize" {
                let result = await dependencies.swiftMinerSlashCommand(action, game, userId, context.channelId)
                if let embed = result.embed {
                    return (content: nil, embeds: [embed])
                }
                return embed(title: "SwiftMiner", description: result.message, color: result.ok ? 3_062_954 : 15_790_767)
            }
            let result = await dependencies.swiftMinerCommand(action, userId, context.channelId)
            return embed(title: "SwiftMiner", description: result.message, color: result.ok ? 3_062_954 : 15_790_767)
        case "steam":
            let query = Self.slashOptionString(named: "action", in: data) ?? ""
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return embed(title: "Steam", description: "Usage: `/steam action:<game name>`", color: 15_790_767)
            }
            let result = await dependencies.fetchSteamAppInfo(query)
            if let embed = result.embed {
                return (content: nil, embeds: [embed])
            }
            return embed(title: "Steam", description: "Could not find info for \"\(query)\".", color: 15_790_767)
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
        case "timestamp":
            let input = Self.slashOptionString(named: "when", in: data) ?? ""
            let userID = dependencies.authorId(context.rawLikeMessage)
            let savedTZ = userID.flatMap { dependencies.lookupUserTimeZone($0) }
            let resolvedTZ = savedTZ.flatMap { TimeZone(identifier: $0) } ?? .current
            switch DiscordTimestampParser.parse(input, timeZone: resolvedTZ) {
            case .failure(let error):
                return embed(title: "Timestamp", description: "❌ \(error.description)", color: 15_790_767)
            case .success(let parsed):
                let defaultCode = DiscordTimestampFormatter.code(for: parsed.date, style: .longDateTime)
                let relativeCode = DiscordTimestampFormatter.code(for: parsed.date, style: .relative)
                let allFormats = DiscordTimestampFormatter.allFormats(for: parsed.date)
                let table = allFormats.map { entry in
                    "**\(entry.style.label)** — \(entry.code) → `\(entry.code)`"
                }.joined(separator: "\n")
                let tzNote: String
                if savedTZ != nil {
                    tzNote = "🕓 Interpreted in your saved zone: `\(resolvedTZ.identifier)`."
                } else {
                    tzNote = "⚠️ No saved timezone — used server zone `\(resolvedTZ.identifier)`. Ask the operator to set yours in SwiftBot."
                }
                let description = """
                Parsed as **\(parsed.summary)**
                \(tzNote)

                Preview: \(defaultCode) (\(relativeCode))

                ```
                \(defaultCode)
                ```

                \(table)
                """
                return embed(title: "Discord Timestamp", description: description)
            }
        default:
            if let resolved = dependencies.resolveWikiCommand(command) {
                let query = Self.slashOptionString(named: "query", in: data) ?? ""
                guard config.wikiEnabled else {
                    return embed(title: "Lookup", description: "Lookup is disabled.", color: 15_790_767)
                }
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return embed(title: "Lookup", description: "Usage: `/\(command) query:<text>`", color: 15_790_767)
                }
                let ok = await dependencies.performWikiLookup(resolved.command, resolved.source, query, context.channelId)
                return statusEmbed(title: "Lookup", ok: ok)
            }
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

    private static func slashOptionInt(named name: String, in data: [String: DiscordJSON]) -> Int? {
        guard case let .array(options)? = data["options"] else { return nil }
        for option in options {
            guard case let .object(map) = option,
                  case let .string(optionName)? = map["name"],
                  optionName == name else { continue }
            if case let .int(value)? = map["value"] {
                return value
            }
            if case let .string(value)? = map["value"], let parsed = Int(value) {
                return parsed
            }
        }
        return nil
    }

    private struct RandomTeamsRequest {
        let teamCount: Int
        let maxSize: Int?
    }

    private static func parseRandomTeamsArguments(_ tokens: [String]) -> (request: RandomTeamsRequest?, error: String?) {
        guard let teamToken = tokens.first, let teamCount = Int(teamToken) else {
            return (nil, "Usage: `/randomteams teams:<count> max_size:<size>` or `/randomteams 2 max size 3`.")
        }

        var maxSize: Int?
        var index = 1
        while index < tokens.count {
            let token = tokens[index].lowercased()
            if token == "max" {
                if index + 2 < tokens.count,
                   tokens[index + 1].lowercased() == "size",
                   let parsed = Int(tokens[index + 2]) {
                    maxSize = parsed
                    index += 3
                    continue
                }
                if index + 1 < tokens.count, let parsed = Int(tokens[index + 1]) {
                    maxSize = parsed
                    index += 2
                    continue
                }
            } else if (token == "maxsize" || token == "max_size"),
                      index + 1 < tokens.count,
                      let parsed = Int(tokens[index + 1]) {
                maxSize = parsed
                index += 2
                continue
            }
            index += 1
        }

        return (RandomTeamsRequest(teamCount: teamCount, maxSize: maxSize), nil)
    }

    static func timestampReply(for input: String, savedTimeZoneID: String?) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "🕰️ Usage: `!timestamp <when>` — e.g. `6pm`, `6pm friday`, `6:15 friday the 13th`, `in 2 hours`."
        }
        let resolvedTZ = savedTimeZoneID.flatMap { TimeZone(identifier: $0) } ?? .current
        switch DiscordTimestampParser.parse(trimmed, timeZone: resolvedTZ) {
        case .failure(let error):
            return "❌ \(error.description)"
        case .success(let parsed):
            let defaultCode = DiscordTimestampFormatter.code(for: parsed.date, style: .longDateTime)
            let relativeCode = DiscordTimestampFormatter.code(for: parsed.date, style: .relative)
            let zoneNote = savedTimeZoneID == nil
                ? "⚠️ Server zone `\(resolvedTZ.identifier)` — ask the operator to save yours."
                : "🕓 Zone: `\(resolvedTZ.identifier)`"
            return """
            🕰️ **\(parsed.summary)**
            \(zoneNote)
            Preview: \(defaultCode) (\(relativeCode))
            Copy: `\(defaultCode)`
            """
        }
    }

    private static func parseMusicInput(_ raw: String) -> (query: String?, title: String?, artist: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (nil, nil, nil)
        }

        let title = captureRegex(
            pattern: #"(?i)\btitle\s*[:=]\s*(.+?)(?=\s+artist\s*[:=]|$)"#,
            in: trimmed
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = captureRegex(
            pattern: #"(?i)\bartist\s*[:=]\s*(.+?)(?=\s+title\s*[:=]|$)"#,
            in: trimmed
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        if (title?.isEmpty == false) || (artist?.isEmpty == false) {
            return (
                nil,
                (title?.isEmpty == false ? title : nil),
                (artist?.isEmpty == false ? artist : nil)
            )
        }

        return (trimmed, nil, nil)
    }

    private static func captureRegex(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        let capture = match.range(at: 1)
        guard capture.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: capture)
    }
}
