import Foundation

extension AppModel {
    func executeCommand(_ commandText: String, username: String, channelId: String, raw: [String: DiscordJSON]) async -> Bool {
        let tokens = commandText.split(separator: " ").map(String.init)
        guard let command = tokens.first?.lowercased() else { return false }

        let prefix = effectivePrefix()

        switch command {
        case "help":
            let catalog = buildHelpCatalog(prefix: prefix)
            let renderer = HelpRenderer(prefix: prefix, helpSettings: settings.help)
            let targetCommand = tokens.dropFirst().first?.lowercased()

            // `!help <command>` — send detailed text reply (with examples).
            if let target = targetCommand {
                if let entry = catalog.entry(for: target) {
                    return await send(channelId, renderer.detail(for: entry))
                } else {
                    return await send(channelId, "❓ Unknown command `\(prefix)\(target)`. Type `\(prefix)help` for a full list.")
                }
            }

            // `!help` — send embed overview.
            // Smart/Hybrid: attempt AI-generated intro for embed description; embed fields are always catalog-sourced.
            var aiIntro: String? = nil
            if settings.help.mode != .classic {
                let msg = Message(
                    channelID: channelId,
                    userID: "help-request",
                    username: "user",
                    content: "Write a short intro for a SwiftBot help embed.",
                    role: .user
                )
                aiIntro = await service.generateHelpReply(messages: [msg], systemPrompt: renderer.aiIntroPrompt(catalog: catalog))
            }

            let embed = renderer.embedOverview(catalog: catalog, aiDescription: aiIntro)
            return await sendEmbed(channelId, embed: embed)
        case "ping":
            return await send(channelId, "🏓 Pong! Gateway latency is currently live via heartbeat ACK.")
        case "roll":
            guard tokens.count >= 2, let output = rollDice(tokens[1]) else { return await unknown(channelId) }
            return await send(channelId, output)
        case "8ball":
            let responses = ["Yes.", "No.", "It is certain.", "Ask again later.", "Very doubtful."]
            return await send(channelId, "🎱 \(responses.randomElement()!)")
        case "poll":
            return await send(channelId, "📊 Poll created! Add reactions to vote.")
        case "image", "imagine":
            let prompt = tokens.dropFirst().joined(separator: " ")
            let userId = authorId(from: raw) ?? "unknown-user"
            return await generateImageCommand(
                prompt: prompt,
                userId: userId,
                username: username,
                channelId: channelId
            )
        case "userinfo":
            return await send(channelId, "👤 User: \(username)")
        case "cluster", "worker":
            let action = tokens.dropFirst().first?.lowercased() ?? "status"
            return await clusterCommand(action: action, channelId: channelId)
        case "setchannel":
            return await setNotificationChannel(for: raw, currentChannelId: channelId)
        case "ignorechannel":
            return await updateIgnoredChannels(tokens: tokens, raw: raw, responseChannelId: channelId)
        case "notifystatus":
            return await notifyStatus(raw: raw, responseChannelId: channelId)
        case "debug":
            guard await canRunDebugCommand(raw: raw) else {
                return await send(channelId, "⛔ `\(effectivePrefix())debug` is restricted to server owners or admins.")
            }
            return await sendEmbed(channelId, embed: debugSummaryEmbed())
        case "weekly":
            let report = weeklyPlugin?.snapshotSummary() ?? "No data yet."
            return await send(channelId, report)
        case "meta":
            if let result = await service.fetchFinalsMetaFromSkycoach() {
                return await send(channelId, result)
            }
            return await send(channelId, "Couldn't fetch meta data right now. Source: https://skycoach.gg/blog/the-finals/articles/the-finals-best-builds")
        default:
            if let resolvedWikiCommand = resolveWikiCommand(named: command) {
                guard settings.wikiBot.isEnabled else {
                    return await send(channelId, "📘 WikiBridge is disabled. Enable it from the WikiBridge page.")
                }
                let query = tokens.dropFirst().joined(separator: " ")
                return await performWikiLookup(
                    command: resolvedWikiCommand.command,
                    source: resolvedWikiCommand.source,
                    query: query,
                    channelId: channelId
                )
            }
            _ = await unknown(channelId)
            return false
        }
    }

    func unknown(_ channelId: String) async -> Bool {
        await send(channelId, "❓ I don't know that command! Type \(effectivePrefix())help to see all available commands.")
    }

    func generateImageCommand(
        prompt: String,
        userId: String,
        username: String,
        channelId: String
    ) async -> Bool {
        let cleanedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPrompt.isEmpty else {
            return await send(channelId, "🎨 Usage: \(effectivePrefix())image <prompt>")
        }

        guard settings.openAIImageGenerationEnabled else {
            return await send(channelId, "🛑 Image generation is disabled in AI settings.")
        }

        guard settings.openAIEnabled else {
            return await send(channelId, "🛑 OpenAI provider is disabled in AI settings.")
        }

        let apiKey = settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            return await send(channelId, "⚠️ OpenAI API key is not configured. Set it in AI Bots settings.")
        }

        let model = settings.openAIImageModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "gpt-image-1"
            : settings.openAIImageModel.trimmingCharacters(in: .whitespacesAndNewlines)

        let limit = max(0, settings.openAIImageMonthlyLimitPerUser)
        let usageKey = imageUsageKey(userID: userId)
        let used = settings.openAIImageUsageByUserMonth[usageKey] ?? 0
        if limit > 0, used >= limit {
            return await send(
                channelId,
                "🧾 Monthly image limit reached (\(used)/\(limit)). Try again next month or increase the limit in settings."
            )
        }

        let placeholderText = "🎨 Generating image for @\(username)…"
        let placeholderId = await sendMessageReturningID(channelId: channelId, content: placeholderText)

        guard let imageData = await service.generateOpenAIImage(prompt: cleanedPrompt, apiKey: apiKey, model: model) else {
            if let placeholderId {
                _ = await editMessage(channelId: channelId, messageId: placeholderId, content: "❌ Image generation failed. Please try a different prompt.")
            } else {
                _ = await send(channelId, "❌ Image generation failed. Please try a different prompt.")
            }
            return false
        }

        pruneOldImageUsageMonths()
        settings.openAIImageUsageByUserMonth[usageKey] = used + 1
        _ = await persistSettings()

        let summary = "✅ Generated with `\(model)` • \(used + 1)/\(limit > 0 ? limit : (used + 1)) this month"
        let filename = "swiftbot-image-\(Int(Date().timeIntervalSince1970)).png"

        if let placeholderId,
           await editMessageWithImage(
                channelId: channelId,
                messageId: placeholderId,
                content: summary,
                imageData: imageData,
                filename: filename
           ) {
            return true
        }

        return await sendMessageWithImage(
            channelId: channelId,
            content: summary,
            imageData: imageData,
            filename: filename
        )
    }

    func imageUsageKey(userID: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return "\(formatter.string(from: now)):\(userID)"
    }

    func pruneOldImageUsageMonths(now: Date = Date()) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        let currentMonth = formatter.string(from: now)
        settings.openAIImageUsageByUserMonth = settings.openAIImageUsageByUserMonth.filter { key, _ in
            key.hasPrefix("\(currentMonth):")
        }
    }

    struct ResolvedWikiCommand {
        let source: WikiSource
        let command: WikiCommand
    }

    func resolveWikiCommand(named commandName: String) -> ResolvedWikiCommand? {
        let normalizedName = normalizedWikiCommandTrigger(commandName)
        guard !normalizedName.isEmpty else { return nil }

        for source in orderedEnabledWikiSources() {
            for command in source.commands where command.enabled {
                if normalizedWikiCommandTrigger(command.trigger) == normalizedName {
                    return ResolvedWikiCommand(source: source, command: command)
                }
            }
        }

        return nil
    }

    func wikiCommandHelpList(prefix: String) -> String {
        var seen: Set<String> = []
        var display: [String] = []

        for source in orderedEnabledWikiSources() {
            for command in source.commands where command.enabled {
                let normalized = normalizedWikiCommandTrigger(command.trigger)
                guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
                display.append("\(prefix)\(normalized)")
            }
        }

        return display.joined(separator: ", ")
    }

    /// Builds the full CommandCatalog including all enabled WikiBridge commands.
    func buildHelpCatalog(prefix: String) -> CommandCatalog {
        var wikiCmds: [WikiCommandInfo] = []
        for source in orderedEnabledWikiSources() {
            for command in source.commands where command.enabled {
                let key = normalizedWikiCommandTrigger(command.trigger)
                guard !key.isEmpty else { continue }
                wikiCmds.append(WikiCommandInfo(trigger: key, sourceName: source.name, description: command.description))
            }
        }
        return CommandCatalog.build(prefix: prefix, wikiCommands: wikiCmds)
    }

    /// Ensures custom intro/footer are always applied to AI help output.
    /// Deterministic help rendering already includes this shell.

    func orderedEnabledWikiSources() -> [WikiSource] {
        let enabledSources = settings.wikiBot.sources.filter(\.enabled)
        return enabledSources.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary {
                return lhs.isPrimary && !rhs.isPrimary
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func normalizedWikiCommandTrigger(_ trigger: String) -> String {
        var trimmed = trigger
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if trimmed.isEmpty { return "" }

        if let first = trimmed.split(separator: " ").first {
            trimmed = String(first)
        }

        let prefix = effectivePrefix().lowercased()
        if !prefix.isEmpty, trimmed.hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count))
        }
        while let first = trimmed.first, first == "!" || first == "/" {
            trimmed.removeFirst()
        }
        return trimmed
    }

    func setNotificationChannel(for raw: [String: DiscordJSON], currentChannelId: String) async -> Bool {
        guard let guildId = guildId(from: raw) else {
            return await send(currentChannelId, "⚠️ This command only works in a server channel.")
        }

        var guildSettings = settings.guildSettings[guildId] ?? GuildSettings()
        guildSettings.notificationChannelId = currentChannelId
        settings.guildSettings[guildId] = guildSettings

        let saved = await persistSettings()
        let message = saved ? "✅ Voice notifications will be posted in this channel." : "❌ Failed to save notification channel settings."
        return await send(currentChannelId, message)
    }

    func updateIgnoredChannels(tokens: [String], raw: [String: DiscordJSON], responseChannelId: String) async -> Bool {
        guard let guildId = guildId(from: raw) else {
            return await send(responseChannelId, "⚠️ This command only works in a server channel.")
        }

        var guildSettings = settings.guildSettings[guildId] ?? GuildSettings()

        guard tokens.count >= 2 else {
            return await send(responseChannelId, "Usage: \(effectivePrefix())ignorechannel #channel | \(effectivePrefix())ignorechannel list | \(effectivePrefix())ignorechannel remove #channel")
        }

        let action = tokens[1].lowercased()
        if action == "list" {
            let list = guildSettings.ignoredVoiceChannelIds.sorted().map { "<#\($0)>" }.joined(separator: ", ")
            let message = list.isEmpty ? "ℹ️ No ignored voice channels configured." : "ℹ️ Ignored voice channels: \(list)"
            return await send(responseChannelId, message)
        }

        guard tokens.count >= 3, let targetChannelId = parseChannelId(tokens[2]) else {
            return await send(responseChannelId, "⚠️ Provide a channel mention like #general.")
        }

        if action == "remove" {
            guildSettings.ignoredVoiceChannelIds.remove(targetChannelId)
            settings.guildSettings[guildId] = guildSettings
            let saved = await persistSettings()
            let message = saved ? "✅ Removed <#\(targetChannelId)> from ignored voice channels." : "❌ Failed to save ignore list."
            return await send(responseChannelId, message)
        }

        guildSettings.ignoredVoiceChannelIds.insert(targetChannelId)
        settings.guildSettings[guildId] = guildSettings
        let saved = await persistSettings()
        let message = saved ? "✅ Added <#\(targetChannelId)> to ignored voice channels." : "❌ Failed to save ignore list."
        return await send(responseChannelId, message)
    }

    func notifyStatus(raw: [String: DiscordJSON], responseChannelId: String) async -> Bool {
        guard let guildId = guildId(from: raw) else {
            return await send(responseChannelId, "⚠️ This command only works in a server channel.")
        }

        let guildSettings = settings.guildSettings[guildId] ?? GuildSettings()
        let notification = guildSettings.notificationChannelId.map { "<#\($0)>" } ?? "Not set"
        let monitored = guildSettings.monitoredVoiceChannelIds.sorted().map { "<#\($0)>" }.joined(separator: ", ")
        let monitoredText = monitored.isEmpty ? "All" : monitored
        let ignored = guildSettings.ignoredVoiceChannelIds.sorted().map { "<#\($0)>" }.joined(separator: ", ")
        let ignoredText = ignored.isEmpty ? "None" : ignored

        return await send(
            responseChannelId,
            "ℹ️ Notification channel: \(notification)\nMonitored voice channels: \(monitoredText)\nIgnored voice channels: \(ignoredText)\nJoin: \(guildSettings.notifyOnJoin ? "on" : "off"), Leave: \(guildSettings.notifyOnLeave ? "on" : "off"), Move: \(guildSettings.notifyOnMove ? "on" : "off")"
        )
    }

    func canRunDebugCommand(raw: [String: DiscordJSON]) async -> Bool {
        guard let guildId = guildId(from: raw) else { return false }
        guard let userId = authorId(from: raw) else { return false }

        if await isGuildOwner(userId: userId, guildId: guildId) {
            return true
        }

        if hasAdministratorPermission(raw: raw) {
            return true
        }

        if hasAdminRoleName(raw: raw, guildId: guildId) {
            return true
        }

        return false
    }

    func authorId(from raw: [String: DiscordJSON]) -> String? {
        guard case let .object(author)? = raw["author"],
              case let .string(userId)? = author["id"] else {
            return nil
        }
        return userId
    }

    func isGuildOwner(userId: String, guildId: String) async -> Bool {
        guard let ownerId = await service.guildOwnerID(guildID: guildId) else { return false }
        return ownerId == userId
    }

    func hasAdministratorPermission(raw: [String: DiscordJSON]) -> Bool {
        guard case let .object(member)? = raw["member"],
              case let .string(permissionsString)? = member["permissions"] else {
            return false
        }
        // Discord ADMINISTRATOR permission bit.
        let adminBit: UInt64 = 1 << 3
        if let permissions = UInt64(permissionsString) {
            return (permissions & adminBit) != 0
        }
        return false
    }

    func hasAdminRoleName(raw: [String: DiscordJSON], guildId: String) -> Bool {
        guard case let .object(member)? = raw["member"],
              case let .array(rolesArray)? = member["roles"] else {
            return false
        }

        let roleIds = rolesArray.compactMap { roleValue -> String? in
            if case let .string(id) = roleValue { return id }
            return nil
        }
        guard !roleIds.isEmpty else { return false }

        let roles = availableRolesByServer[guildId] ?? []
        let adminRoleIDs = Set(
            roles
                .filter { role in
                    let lowered = role.name.lowercased()
                    return lowered == "admin" || lowered == "administrator"
                }
                .map(\.id)
        )
        return roleIds.contains(where: { adminRoleIDs.contains($0) })
    }

    func debugSummaryText() -> String {
        let bundle = Bundle.main
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let statusText: String = {
            if settings.clusterMode == .worker {
                return primaryServiceStatusText
            }
            return status.rawValue.capitalized
        }()

        let uptimeText = uptime?.text ?? "--"
        let aiProvider = settings.preferredAIProvider.rawValue
        let wikiEnabled = settings.wikiBot.isEnabled ? "on" : "off"
        let patchyEnabled = settings.patchy.monitoringEnabled ? "on" : "off"
        let activeRules = ruleStore.rules.filter(\.isEnabled).count

        return [
            "🛠️ **SwiftBot Debug**",
            "Version: \(version) (\(build))",
            "Host: \(hostName)",
            "OS: \(osVersion)",
            "Mode: \(settings.clusterMode.displayName)",
            "Node: \(settings.clusterNodeName)",
            "Listen Port: \(settings.clusterListenPort)",
            "Status: \(statusText)",
            "Uptime: \(uptimeText)",
            "Servers: \(connectedServers.count)",
            "Active Voice: \(activeVoice.count)",
            "Commands Run: \(stats.commandsRun)",
            "Errors: \(stats.errors)",
            "AI Provider: \(aiProvider)",
            "WikiBridge: \(wikiEnabled)",
            "Patchy Monitoring: \(patchyEnabled)",
            "Action Rules: \(activeRules)/\(ruleStore.rules.count)",
            "Beta Build: \(isBetaBuild ? "yes" : "no")"
        ].joined(separator: "\n")
    }

    func debugSummaryEmbed() -> [String: Any] {
        let bundle = Bundle.main
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let statusText: String = {
            if settings.clusterMode == .worker {
                return primaryServiceStatusText
            }
            return status.rawValue.capitalized
        }()

        let uptimeText = uptime?.text ?? "--"
        let aiProvider = settings.preferredAIProvider.rawValue
        let wikiEnabled = settings.wikiBot.isEnabled ? "On" : "Off"
        let patchyEnabled = settings.patchy.monitoringEnabled ? "On" : "Off"
        let activeRules = ruleStore.rules.filter(\.isEnabled).count

        let fields: [[String: Any]] = [
            [
                "name": "Build",
                "value": "Version: `\(version)`\nBuild: `\(build)`\nBeta: `\(isBetaBuild ? "yes" : "no")`",
                "inline": true
            ],
            [
                "name": "Host",
                "value": "Mac: `\(hostName)`\nOS: `\(osVersion)`",
                "inline": true
            ],
            [
                "name": "Node",
                "value": "Mode: `\(settings.clusterMode.displayName)`\nNode: `\(settings.clusterNodeName)`\nPort: `\(settings.clusterListenPort)`",
                "inline": true
            ],
            [
                "name": "Runtime",
                "value": "Status: `\(statusText)`\nUptime: `\(uptimeText)`\nServers: `\(connectedServers.count)`\nVoice: `\(activeVoice.count)`",
                "inline": true
            ],
            [
                "name": "Features",
                "value": "AI: `\(aiProvider)`\nWikiBridge: `\(wikiEnabled)`\nPatchy: `\(patchyEnabled)`\nRules: `\(activeRules)/\(ruleStore.rules.count)`",
                "inline": true
            ],
            [
                "name": "Counters",
                "value": "Commands: `\(stats.commandsRun)`\nErrors: `\(stats.errors)`",
                "inline": true
            ]
        ]

        return [
            "title": "SwiftBot Debug",
            "description": "Privileged diagnostics for this running instance.",
            "color": 5_793_266,
            "fields": fields,
            "footer": ["text": "Requested at \(Date().formatted(date: .abbreviated, time: .standard))"]
        ]
    }

    func persistSettings() async -> Bool {
        do {
            try await store.save(settings)
            return true
        } catch {
            stats.errors += 1
            logs.append("❌ Failed saving settings: \(error.localizedDescription)")
            return false
        }
    }

    func guildId(from raw: [String: DiscordJSON]) -> String? {
        guard case let .string(guildId)? = raw["guild_id"] else { return nil }
        return guildId
    }

    func parseChannelId(_ token: String) -> String? {
        if token.hasPrefix("<#") && token.hasSuffix(">") {
            return String(token.dropFirst(2).dropLast())
        }
        return token.allSatisfy(\.isNumber) ? token : nil
    }

    func isMentioningBot(_ raw: [String: DiscordJSON]) -> Bool {
        guard let botUserId else { return false }
        guard case let .array(mentions)? = raw["mentions"] else { return false }

        for mention in mentions {
            guard case let .object(user) = mention,
                  case let .string(id)? = user["id"] else { continue }
            if id == botUserId {
                return true
            }
        }

        return false
    }

    func contentWithoutBotMention(_ content: String) -> String {
        guard let botUserId else {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let patterns = [
            "<@\(botUserId)>",
            "<@!\(botUserId)>"
        ]

        let stripped = patterns.reduce(content) { partial, pattern in
            partial.replacingOccurrences(of: pattern, with: " ")
        }

        return stripped
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolvedChannelType(from map: [String: DiscordJSON], channelID: String) async -> Int? {
        if case let .int(type)? = map["channel_type"] {
            return type
        }
        return await discordCache.channelType(for: channelID)
    }

    func upsertDiscordCacheFromMessage(
        map: [String: DiscordJSON],
        guildID: String?,
        channelID: String,
        channelType: Int?,
        userID: String,
        fallbackUsername: String
    ) async {
        if let guildID {
            let guildName: String?
            if case let .string(name)? = map["guild_name"] {
                guildName = name
            } else {
                guildName = nil
            }
            await discordCache.upsertGuild(id: guildID, name: guildName)
        }

        if let channelType {
            await discordCache.setChannelType(channelID: channelID, type: channelType)
        }

        if let guildID,
           case let .string(name)? = map["channel_name"] {
            let resolvedType = channelType ?? 0
            await discordCache.upsertChannel(
                guildID: guildID,
                channelID: channelID,
                name: name,
                type: resolvedType
            )
        }

        let preferredName: String = {
            if case let .object(member)? = map["member"],
               case let .string(nick)? = member["nick"],
               !nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nick
            }
            if case let .object(author)? = map["author"] {
                if case let .string(globalName)? = author["global_name"],
                   !globalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return globalName
                }
                if case let .string(username)? = author["username"],
                   !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return username
                }
            }
            return fallbackUsername
        }()

        await discordCache.upsertUser(id: userID, preferredName: preferredName)
        await syncPublishedDiscordCacheFromService()
        scheduleDiscordCacheSave()
    }

    func displayNameForUserID(_ userID: String) async -> String {
        if let name = await discordCache.userName(for: userID), !name.isEmpty {
            return name
        }
        if userID == "system" {
            return "System"
        }
        return "User \(userID.suffix(4))"
    }

    func aiMessagesForScope(
        scope: MemoryScope,
        currentUserID: String,
        currentContent: String
    ) async -> (messages: [Message], wikiContext: String) {
        let maxHistory = 8
        var recent = await conversationStore.recentMessages(for: scope, limit: maxHistory)
        
        if !currentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recent.append(
                MemoryRecord(
                    id: UUID().uuidString,
                    scope: scope,
                    userID: currentUserID,
                    content: currentContent,
                    timestamp: Date(),
                    role: .user
                )
            )
        }

        var conversationalMessages: [Message] = []
        conversationalMessages.reserveCapacity(recent.count)
        for record in recent {
            let resolvedUsername = await displayNameForUserID(record.userID)
            conversationalMessages.append(
                Message(
                    id: record.id,
                    channelID: record.scope.id,
                    userID: record.userID,
                    username: resolvedUsername,
                    content: record.content,
                    timestamp: record.timestamp,
                    role: record.role
                )
            )
        }

        let wikiContextEntries = await wikiContextCache.contextEntries(for: currentContent, limit: 3)
        let wikiContext = renderWikiContext(entries: wikiContextEntries)
        let aiMemoryContext = renderAIMemoryContext(for: currentContent, history: conversationalMessages, limit: 4)
        let combinedContext = [wikiContext, aiMemoryContext]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        
        return (conversationalMessages, combinedContext)
    }

    func renderWikiContext(entries: [WikiContextEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        var lines: [String] = ["Known Wiki Context (cached):"]
        for entry in entries {
            let summary = summarizedWikiExtract(entry.extract, limit: 220)
            if summary.isEmpty {
                lines.append("- [\(entry.sourceName)] \(entry.title): \(entry.url)")
            } else {
                lines.append("- [\(entry.sourceName)] \(entry.title): \(summary) (\(entry.url))")
            }
        }
        return lines.joined(separator: "\n")
    }

    func extractAIMemoryInstruction(from text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let lowered = cleaned.lowercased()

        let explicitTriggers = [
            "for future reference",
            "remember this",
            "please remember",
            "remember for later"
        ]

        if let trigger = explicitTriggers.first(where: { lowered.contains($0) }),
           let range = lowered.range(of: trigger) {
            let suffix = cleaned[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if suffix.count >= 8 {
                return String(suffix)
            }
        }

        // Implicit memory signal:
        // if the message includes a URL and wording that suggests "save this source", capture it.
        let urls = extractURLs(from: cleaned)
        guard !urls.isEmpty else { return nil }

        let implicitHints = [
            "worth checking",
            "good site",
            "for information",
            "for updates",
            "use this",
            "source for",
            "meta"
        ]
        guard implicitHints.contains(where: { lowered.contains($0) }) else { return nil }
        return cleaned
    }

    func rememberAIMemory(
        text: String,
        userId: String,
        username: String,
        channelId: String
    ) async -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return await send(channelId, "🧠 I didn't catch anything to remember.")
        }

        if settings.aiMemoryNotes.contains(where: { $0.text.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            return await send(channelId, "🧠 Already saved in memory.")
        }

        let urls = extractURLs(from: cleaned)
        var finalNoteText = cleaned
        var ingestedSource = false
        if let firstURL = urls.first,
           let ingested = await ingestMemorySource(from: firstURL) {
            finalNoteText = """
            \(cleaned)

            Ingested Source:
            \(ingested)
            """
            ingestedSource = true
        }

        settings.aiMemoryNotes.append(
            AIMemoryNote(
                createdByUserID: userId,
                createdByUsername: username,
                text: finalNoteText
            )
        )
        if settings.aiMemoryNotes.count > 200 {
            settings.aiMemoryNotes = Array(settings.aiMemoryNotes.suffix(200))
        }
        _ = await persistSettings()
        logs.append("🧠 Added AI memory note from \(username)")
        if ingestedSource {
            return await send(channelId, "🧠 Saved and ingested that source into memory for future replies.")
        }
        return await send(channelId, "🧠 Saved for future replies.")
    }

    func renderAIMemoryContext(for currentContent: String, history: [Message], limit: Int) -> String {
        guard !settings.aiMemoryNotes.isEmpty else { return "" }

        let historyTail = history.suffix(6).map(\.content).joined(separator: " ")
        let query = "\(currentContent) \(historyTail)"
        let queryTokens = normalizedTokens(from: query)
        guard !queryTokens.isEmpty else { return "" }

        let scored: [(note: AIMemoryNote, score: Int)] = settings.aiMemoryNotes.compactMap { note in
            let noteTokens = normalizedTokens(from: note.text)
            guard !noteTokens.isEmpty else { return nil }
            let overlap = noteTokens.intersection(queryTokens)
            guard !overlap.isEmpty else { return nil }
            return (note, overlap.count)
        }

        let topNotes = scored
            .sorted {
                if $0.score == $1.score { return $0.note.createdAt > $1.note.createdAt }
                return $0.score > $1.score
            }
            .prefix(limit)
            .map(\.note)

        guard !topNotes.isEmpty else { return "" }

        var lines: [String] = [
            "Persistent Team Memory (relevant):",
            "When the user asks for sources/citations, cite relevant URLs from these notes.",
            "Do not just redirect users back to links they already provided. Synthesize an answer from remembered source details first."
        ]
        for note in topNotes {
            lines.append("- \(note.text)")
        }
        return lines.joined(separator: "\n")
    }

    func normalizedTokens(from text: String) -> Set<String> {
        let lowered = text.lowercased()
        let parts = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let filtered = parts.filter { token in
            token.count >= 3 && !aiMemoryStopwords.contains(token)
        }
        return Set(filtered)
    }

    func extractURLs(from text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let nsText = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { $0.url?.absoluteString }
    }

    func ingestMemorySource(from urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let html = String(data: data, encoding: .utf8) else { return nil }

            let title = firstRegexCapture(in: html, pattern: #"<title[^>]*>(.*?)</title>"#)?
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Unknown title"

            let metaDescription = firstRegexCapture(
                in: html,
                pattern: #"<meta[^>]*name=["']description["'][^>]*content=["'](.*?)["'][^>]*>"#
            )?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

            let paragraphMatches = regexMatches(in: html, pattern: #"<p\b[^>]*>(.*?)</p>"#)
            let paragraphs = paragraphMatches
                .map(stripHTML)
                .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 60 }
            let paragraphSummary = paragraphs.prefix(2).joined(separator: " ")

            let contentSummary = [metaDescription, paragraphSummary]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            let truncated = String(contentSummary.prefix(700))
            if truncated.isEmpty { return nil }

            return "Title: \(title)\nURL: \(urlString)\nSummary: \(truncated)"
        } catch {
            return nil
        }
    }

    func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else {
            return nil
        }
        let captureRange = match.range(at: 1)
        guard captureRange.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: captureRange)
    }

    func regexMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let captureRange = match.range(at: 1)
            guard captureRange.location != NSNotFound else { return nil }
            return (text as NSString).substring(with: captureRange)
        }
    }

    func stripHTML(_ html: String) -> String {
        let withoutScripts = html.replacingOccurrences(
            of: #"<script[\s\S]*?</script>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        let withoutStyles = withoutScripts.replacingOccurrences(
            of: #"<style[\s\S]*?</style>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        return withoutStyles.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    func appendAssistantMessage(scope: MemoryScope, content: String) async {
        let assistantID = botUserId ?? "swiftbot"
        await discordCache.upsertUser(id: assistantID, preferredName: botUsername)
        await conversationStore.append(
            scope: scope,
            userID: assistantID,
            content: content,
            role: .assistant
        )
    }

    func performWikiLookup(
        command: WikiCommand,
        source: WikiSource,
        query: String,
        channelId: String
    ) async -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trigger = normalizedWikiCommandTrigger(command.trigger)
        let usageTrigger = trigger.isEmpty ? command.trigger : "\(effectivePrefix())\(trigger)"
        guard !trimmedQuery.isEmpty else {
            return await send(
                channelId,
                "📘 Usage: \(usageTrigger) <query> (optional source selector: <wiki-command> <source>::<query>)"
            )
        }

        guard let resolved = resolveWikiSourceAndQuery(defaultSource: source, query: trimmedQuery) else {
            return await send(channelId, "⚠️ No WikiBridge sources are enabled. Add or enable a source in WikiBridge settings.")
        }

        let resolvedSource = resolved.source
        let sourceQuery = resolved.query
        guard !sourceQuery.isEmpty else {
            return await send(channelId, "📘 Provide a query after the source selector. Example: \(usageTrigger) \(resolvedSource.name)::AKM")
        }

        guard let result = await cluster.lookupWiki(query: sourceQuery, source: resolvedSource) else {
            updateWikiBridgeSourceRuntimeState(id: resolvedSource.id) { entry in
                entry.lastLookupAt = Date()
                entry.lastStatus = "No match for \"\(sourceQuery)\""
            }
            persistSettingsQuietly()
            return await send(channelId, "❌ I couldn't find a relevant page on \(resolvedSource.name) for \"\(sourceQuery)\".")
        }

        updateWikiBridgeSourceRuntimeState(id: resolvedSource.id) { entry in
            entry.lastLookupAt = Date()
            entry.lastStatus = "Resolved: \(result.title)"
        }
        persistSettingsQuietly()
        await wikiContextCache.store(sourceName: resolvedSource.name, query: sourceQuery, result: result)

        let body = formattedWikiResponse(source: resolvedSource, result: result)
        if resolvedSource.formatting.useEmbeds {
            let embedSent = await sendWikiEmbed(channelId: channelId, source: resolvedSource, result: result)
            if embedSent {
                return true
            }
        }

        return await send(channelId, body)
    }

    func resolveWikiSourceAndQuery(defaultSource: WikiSource, query: String) -> (source: WikiSource, query: String)? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabledSources = settings.wikiBot.sources.filter(\.enabled)
        guard !enabledSources.isEmpty else { return nil }

        if let explicit = parseExplicitWikiSource(in: trimmedQuery, from: enabledSources) {
            return explicit
        }

        if enabledSources.contains(where: { $0.id == defaultSource.id }) {
            return (defaultSource, trimmedQuery)
        }

        if let primarySource = enabledSources.first(where: { $0.isPrimary }) {
            return (primarySource, trimmedQuery)
        }

        return (enabledSources[0], trimmedQuery)
    }

    func parseExplicitWikiSource(
        in query: String,
        from enabledSources: [WikiSource]
    ) -> (source: WikiSource, query: String)? {
        guard let marker = query.range(of: "::") else { return nil }
        let rawSource = query[..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let remainingQuery = query[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawSource.isEmpty else { return nil }

        let lookupKey = normalizedWikiSourceKey(rawSource)
        guard !lookupKey.isEmpty else { return nil }

        for source in enabledSources {
            let nameKey = normalizedWikiSourceKey(source.name)
            if lookupKey == nameKey || nameKey.hasPrefix(lookupKey) {
                return (source, remainingQuery)
            }

            if let host = URL(string: source.baseURL)?.host {
                let hostKey = normalizedWikiSourceKey(host)
                if lookupKey == hostKey || hostKey.hasPrefix(lookupKey) {
                    return (source, remainingQuery)
                }
            }
        }

        return nil
    }

    func normalizedWikiSourceKey(_ raw: String) -> String {
        raw
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    func formattedWikiResponse(source: WikiSource, result: FinalsWikiLookupResult) -> String {
        let formatting = source.formatting
        if formatting.includeStatBlocks, let weaponStats = result.weaponStats {
            return formattedWeaponStats(
                result: result,
                sourceName: source.name,
                stats: weaponStats,
                compact: formatting.compactMode
            )
        }

        let summary = summarizedWikiExtract(
            result.extract,
            limit: formatting.compactMode ? 220 : 420
        )
        if summary.isEmpty {
            return "📘 **\(result.title)**\nSource: \(source.name)\n\(result.url)"
        }
        if formatting.compactMode {
            return "📘 **\(result.title)** • \(source.name)\n\(summary)\n\(result.url)"
        }
        return "📘 **\(result.title)**\nSource: \(source.name)\n\(summary)\n\(result.url)"
    }

    func sendWikiEmbed(channelId: String, source: WikiSource, result: FinalsWikiLookupResult) async -> Bool {
        let summary = summarizedWikiExtract(
            result.extract,
            limit: source.formatting.compactMode ? 220 : 420
        )

        var embed: [String: Any] = [
            "title": result.title,
            "url": result.url,
            "footer": ["text": source.name]
        ]
        if !summary.isEmpty {
            embed["description"] = summary
        }

        if source.formatting.includeStatBlocks, let stats = result.weaponStats {
            var fields: [[String: Any]] = []
            func appendField(_ name: String, _ value: String?) {
                guard let value, !value.isEmpty else { return }
                fields.append([
                    "name": name,
                    "value": value,
                    "inline": true
                ])
            }
            appendField("Type", stats.type)
            appendField("Body Damage", stats.bodyDamage)
            appendField("Head Damage", stats.headshotDamage)
            appendField("Fire Rate", stats.fireRate)
            appendField("Dropoff Start", stats.dropoffStart)
            appendField("Dropoff End", stats.dropoffEnd)
            appendField("Minimum Damage", stats.minimumDamage)
            appendField("Magazine", stats.magazineSize)
            appendField("Short Reload", stats.shortReload)
            appendField("Long Reload", stats.longReload)
            if !fields.isEmpty {
                embed["fields"] = Array(fields.prefix(25))
            }
        }

        let payload: [String: Any] = [
            "embeds": [embed]
        ]
        do {
            _ = try await service.sendMessage(channelId: channelId, payload: payload, token: settings.token)
            return true
        } catch {
            return false
        }
    }

    func formattedWeaponStats(
        result: FinalsWikiLookupResult,
        sourceName: String,
        stats: FinalsWeaponStats,
        compact: Bool
    ) -> String {
        var lines: [String] = []

        if let type = stats.type, !type.isEmpty {
            lines.append("📘 **\(result.title)** • \(type)")
        } else {
            lines.append("📘 **\(result.title)**")
        }
        if compact {
            lines[0] += " • \(sourceName)"
        } else {
            lines.append("Source: \(sourceName)")
        }

        let damageLine = [
            stats.bodyDamage.map { "Body \($0)" },
            stats.headshotDamage.map { "Head \($0)" }
        ].compactMap { $0 }.joined(separator: " • ")
        if !damageLine.isEmpty {
            lines.append(compact ? "DMG \(damageLine)" : "Damage: \(damageLine)")
        }

        if let fireRate = stats.fireRate, !fireRate.isEmpty {
            lines.append(compact ? "RPM \(fireRate)" : "Fire Rate: \(fireRate)")
        }

        let falloffLine = [
            stats.dropoffStart.map { "Start \($0)" },
            stats.dropoffEnd.map { "End \($0)" },
            stats.minimumDamage.map { "Min \($0)" }
        ].compactMap { $0 }.joined(separator: " • ")
        if !falloffLine.isEmpty {
            lines.append(compact ? "Falloff \(falloffLine)" : "Falloff: \(falloffLine)")
        }

        if let magazineSize = stats.magazineSize, !magazineSize.isEmpty {
            lines.append(compact ? "Mag \(magazineSize)" : "Magazine: \(magazineSize)")
        }

        let reloadLine = [
            stats.shortReload.map { "Short \($0)" },
            stats.longReload.map { "Long \($0)" }
        ].compactMap { $0 }.joined(separator: " • ")
        if !reloadLine.isEmpty {
            lines.append(compact ? "Reload \(reloadLine)" : "Reload: \(reloadLine)")
        }

        lines.append(result.url)
        return lines.joined(separator: "\n")
    }

    func summarizedWikiExtract(_ extract: String, limit: Int = 420) -> String {
        let cleaned = extract
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count > limit else { return cleaned }

        let cutoffIndex = cleaned.index(cleaned.startIndex, offsetBy: limit)
        let prefix = String(cleaned[..<cutoffIndex])
        if let sentenceEnd = prefix.lastIndex(where: { ".!?".contains($0) }) {
            return String(prefix[...sentenceEnd])
        }

        return prefix + "..."
    }

    func logSwiftMeshStatus(_ snapshot: ClusterSnapshot, context: String) {
        let leader = snapshot.leaderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaderValue = leader.isEmpty ? "-" : leader
        logs.append(
            "SwiftMesh [\(context)] mode=\(snapshot.mode.rawValue) server=\(snapshot.serverStatusText) worker=\(snapshot.workerStatusText) leader=\(leaderValue)"
        )
    }

    func performWorkerConnectionTest(leaderAddress rawValue: String) async -> WorkerConnectionTestOutcome {
        guard let baseURL = normalizedSwiftMeshBaseURL(from: rawValue),
              let host = baseURL.host else {
            return WorkerConnectionTestOutcome(message: "Invalid URL", isSuccess: false)
        }

        let port = baseURL.port ?? (baseURL.scheme?.lowercased() == "https" ? 443 : 80)
        switch testReachability(host: host, port: port) {
        case .hostUnreachable:
            return WorkerConnectionTestOutcome(message: "Host unreachable", isSuccess: false)
        case .reachable:
            break
        }

        guard let pingURL = URL(string: baseURL.absoluteString + "/cluster/ping") else {
            return WorkerConnectionTestOutcome(message: "Invalid URL", isSuccess: false)
        }

        var request = URLRequest(url: pingURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        let startedAt = Date()

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let payload = try? JSONDecoder().decode(SwiftMeshPingResponse.self, from: data),
                  payload.status.caseInsensitiveCompare("ok") == .orderedSame,
                  payload.role.caseInsensitiveCompare("leader") == .orderedSame else {
                return WorkerConnectionTestOutcome(message: "Server reachable but not SwiftBot", isSuccess: false)
            }

            let latencyMs = max(1, Int((Date().timeIntervalSince(startedAt) * 1000).rounded()))
            return WorkerConnectionTestOutcome(
                message: "Successful connection with latency: \(latencyMs) ms",
                isSuccess: true
            )
        } catch let error as URLError {
            switch error.code {
            case .badURL, .unsupportedURL:
                return WorkerConnectionTestOutcome(message: "Invalid URL", isSuccess: false)
            case .cannotFindHost, .dnsLookupFailed, .timedOut, .notConnectedToInternet:
                return WorkerConnectionTestOutcome(message: "Host unreachable", isSuccess: false)
            case .cannotConnectToHost:
                let portLabel = baseURL.port ?? (baseURL.scheme?.lowercased() == "https" ? 443 : 80)
                return WorkerConnectionTestOutcome(
                    message: "Connection refused on port \(portLabel) (Primary may be offline or settings not saved)",
                    isSuccess: false
                )
            default:
                return WorkerConnectionTestOutcome(message: "Host unreachable", isSuccess: false)
            }
        } catch {
            return WorkerConnectionTestOutcome(message: "Host unreachable", isSuccess: false)
        }
    }

    func normalizedSwiftMeshBaseURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            candidate = trimmed
        } else {
            candidate = "http://\(trimmed)"
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme,
              let host = url.host,
              !scheme.isEmpty,
              !host.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = ""
        return components.url
    }

    func testReachability(host: String, port: Int) -> WorkerReachabilityResult {
        guard (1...Int(UInt16.max)).contains(port) else {
            return .hostUnreachable
        }

        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = String(port).withCString { portCString in
            host.withCString { hostCString in
                getaddrinfo(hostCString, portCString, &hints, &resultPointer)
            }
        }

        if let resultPointer {
            freeaddrinfo(resultPointer)
        }

        return status == 0 ? .reachable : .hostUnreachable
    }

    func clusterCommand(action: String, channelId: String) async -> Bool {
        let normalized = ["test", "refresh", "check", "remote", "probe"].contains(action) ? action : "status"
        let snapshot = await clusterSnapshotForCommand(action: normalized)
        let leaderAddress = snapshot.leaderAddress.isEmpty ? "-" : snapshot.leaderAddress

        let message = """
        🧭 **Cluster \(normalized.capitalized)**
        Mode: \(snapshot.mode.rawValue)
        Node: \(snapshot.nodeName)
        Server: \(snapshot.serverStatusText)
        Worker: \(snapshot.workerStatusText)
        Leader Address: \(leaderAddress)
        Last Job: \(snapshot.lastJobSummary) [\(snapshot.lastJobRoute.rawValue)]
        Last Job Node: \(snapshot.lastJobNode)
        Diagnostics: \(snapshot.diagnostics)
        """

        return await send(channelId, message)
    }

    func clusterSnapshotForCommand(action: String) async -> ClusterSnapshot {
        switch action {
        case "test", "refresh", "check":
            return await refreshClusterStatusNow()
        case "remote", "probe":
            _ = await cluster.probeWorker()
            let snapshot = await cluster.currentSnapshot()
            clusterSnapshot = snapshot
            return snapshot
        default:
            return clusterSnapshot
        }
    }

    func commandExecutionDetails(for commandName: String) async -> (route: String, node: String) {
        let leaderNode = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines)

        let normalized = normalizedWikiCommandTrigger(commandName)
        let isWikiCommand = resolveWikiCommand(named: normalized) != nil

        if commandName == "cluster" || commandName == "worker" || isWikiCommand {
            let snapshot = await cluster.currentSnapshot()
            return (snapshot.lastJobRoute.rawValue.capitalized, snapshot.lastJobNode)
        }

        return ("Primary", leaderNode)
    }

    func rollDice(_ descriptor: String) -> String? {
        let parts = descriptor.lowercased().split(separator: "d")
        guard parts.count == 2,
              let n = Int(parts[0]),
              let sides = Int(parts[1]),
              (1...30).contains(n), (2...1000).contains(sides) else { return nil }

        var rolls: [Int] = []
        for _ in 0..<n { rolls.append(Int.random(in: 1...sides)) }
        return "🎲 Rolled \(descriptor): [\(rolls.map(String.init).joined(separator: ", "))] total=\(rolls.reduce(0, +))"
    }

}
