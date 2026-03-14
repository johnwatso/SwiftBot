import Foundation

extension AppModel {
    func appendBugAutoFixConsole(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        let next = "[\(timestamp)] \(trimmed)\n"
        bugAutoFixConsoleText.append(next)
        if bugAutoFixConsoleText.count > 50_000 {
            bugAutoFixConsoleText = String(bugAutoFixConsoleText.suffix(50_000))
        }
    }

    func beginBugAutoFixSession(_ status: String) {
        bugAutoFixStatusText = status
        appendBugAutoFixConsole("=== \(status) ===")
    }

    func finishBugAutoFixSession(_ status: String) {
        bugAutoFixStatusText = status
        appendBugAutoFixConsole("=== \(status) ===")
    }

    func commandKey(name: String, surface: String) -> String {
        "\(surface.lowercased()):\(name.lowercased())"
    }

    func canonicalPrefixCommandName(_ name: String) -> String {
        switch name.lowercased() {
        case "imagine":
            return "image"
        case "worker":
            return "cluster"
        default:
            return name.lowercased()
        }
    }

    func isCommandEnabled(name: String, surface: String) -> Bool {
        let key = commandKey(name: name, surface: surface)
        return !settings.disabledCommandKeys.contains(key)
    }

    func setCommandEnabled(name: String, surface: String, enabled: Bool) {
        let key = commandKey(name: name, surface: surface)
        if enabled {
            settings.disabledCommandKeys.remove(key)
        } else {
            settings.disabledCommandKeys.insert(key)
        }
    }

    func executeCommand(
        _ commandText: String,
        username: String,
        channelId: String,
        raw: [String: DiscordJSON],
        bypassSystemToggles: Bool = false
    ) async -> Bool {
        await commandProcessor.executePrefixCommand(
            .init(
                commandText: commandText,
                username: username,
                channelId: channelId,
                raw: raw,
                bypassSystemToggles: bypassSystemToggles
            )
        )
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
        let hardCap = max(limit, settings.openAIImageMonthlyHardCap)
        let usageKey = imageUsageKey(userID: userId)
        let used = settings.openAIImageUsageByUserMonth[usageKey] ?? 0

        if limit > 0, used >= limit {
            return await send(
                channelId,
                "🧾 Monthly image limit reached (\(used)/\(limit)). Try again next month or increase the limit in settings."
            )
        }

        // Aggregate mesh-wide total usage for this month
        let currentMonthPrefix = usageKey.prefix(7) // "YYYY-MM"
        let totalMonthlyUsage = settings.openAIImageUsageByUserMonth
            .filter { $0.key.hasPrefix(currentMonthPrefix) }
            .reduce(0) { $0 + $1.value }

        if hardCap > 0, totalMonthlyUsage >= hardCap {
            return await send(
                channelId,
                "🛑 Mesh-wide hard cap for image generation reached (\(totalMonthlyUsage)/\(hardCap)). Please contact the administrator."
            )
        }

        let placeholderText = "🎨 Generating image for @\(username)…"
        let placeholderId = await sendMessageReturningID(channelId: channelId, content: placeholderText)

        guard let imageData = await aiService.generateOpenAIImage(prompt: cleanedPrompt, apiKey: apiKey, model: model) else {
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

        // SwiftMesh: broadcast updated usage to other nodes
        if settings.clusterMode == .leader {
            await pushImageUsageToAllNodes()
        }

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
    func buildFullHelpCatalog(prefix: String) -> CommandCatalog {
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

    func buildHelpCatalog(prefix: String) -> CommandCatalog {
        let full = buildFullHelpCatalog(prefix: prefix)
        let filtered = full.entries.filter { isCommandEnabled(name: $0.name, surface: "prefix") }
        return CommandCatalog(entries: filtered, configuredWikiSources: full.configuredWikiSources)
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

    var bugStatusEmojis: [String] {
        [BugStatus.new.emoji, BugStatus.workingOn.emoji, BugStatus.inProgress.emoji, BugStatus.blocked.emoji, BugStatus.resolved.emoji]
    }

    var bugStatusByEmoji: [String: BugStatus] {
        let raw: [String: BugStatus] = [
            BugStatus.new.emoji: .new,
            BugStatus.workingOn.emoji: .workingOn,
            BugStatus.inProgress.emoji: .inProgress,
            BugStatus.blocked.emoji: .blocked,
            BugStatus.resolved.emoji: .resolved
        ]
        var normalized = raw
        for (emoji, status) in raw {
            normalized[normalizedReactionEmojiName(emoji)] = status
        }
        return normalized
    }

    var featureStatusEmojiDescriptions: [(emoji: String, label: String)] {
        [
            ("💡", "New Request"),
            ("🧪", "Needs Review"),
            ("🗓️", "Planned"),
            ("🚧", "In Progress"),
            ("✅", "Implemented"),
            ("❌", "Declined")
        ]
    }

    var featureStatusByEmoji: [String: String] {
        let raw = Dictionary(uniqueKeysWithValues: featureStatusEmojiDescriptions.map { ($0.emoji, $0.label) })
        var normalized = raw
        for (emoji, label) in raw {
            normalized[normalizedReactionEmojiName(emoji)] = label
        }
        return normalized
    }

    func handleBugTrackCommand(raw: [String: DiscordJSON], username: String, responseChannelId: String) async {
        let serverName = commandServerName(from: raw)
        guard settings.bugTrackingEnabled else {
            return
        }

        guard let guildId = guildId(from: raw) else {
            let ok = await send(responseChannelId, "⚠️ Bug tracking only works in server channels.")
            await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
            return
        }

        guard await canRunDebugCommand(raw: raw) else {
            let ok = await send(responseChannelId, "⛔ `@swiftbot bug` is restricted to server owners or admins.")
            await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
            return
        }

        guard case let .object(messageReference)? = raw["message_reference"],
              case let .string(sourceMessageID)? = messageReference["message_id"] else {
            let ok = await send(responseChannelId, "⚠️ Reply to a message with `@swiftbot bug` to track it.")
            await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
            return
        }

        let sourceChannelID: String = {
            if case let .string(id)? = messageReference["channel_id"] { return id }
            return responseChannelId
        }()

        let sourceMessage: [String: DiscordJSON]? = {
            if case let .object(ref)? = raw["referenced_message"] {
                return ref
            }
            return nil
        }()
        let resolvedSourceMessage: [String: DiscordJSON]?
        if let sourceMessage {
            resolvedSourceMessage = sourceMessage
        } else {
            resolvedSourceMessage = await fetchMessage(channelId: sourceChannelID, messageId: sourceMessageID)
        }

        guard let sourceMessage = resolvedSourceMessage else {
            let ok = await send(responseChannelId, "❌ Couldn't load the referenced message.")
            await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
            return
        }

        guard let bugChannelID = bugTrackerChannelID(for: guildId) else {
            let ok = await send(responseChannelId, "❌ Couldn't find #swiftbot-dev in this server.")
            await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
            return
        }

        let reporterID: String = {
            guard case let .object(author)? = sourceMessage["author"],
                  case let .string(id)? = author["id"] else {
                return "unknown-user"
            }
            return id
        }()
        let sourceText: String = {
            if case let .string(text)? = sourceMessage["content"] { return text }
            return ""
        }()
        let cleanedSourceText = bugPreviewText(from: sourceText)
        let jumpLink = "https://discord.com/channels/\(guildId)/\(sourceChannelID)/\(sourceMessageID)"
        let bugMessage = """
        🐞 SwiftBot Bug
        Reporter: <@\(reporterID)>
        Channel: <#\(sourceChannelID)>
        Message:
        "\(cleanedSourceText)"
        Status: \(BugStatus.new.rawValue)
        Link: \(jumpLink)
        """

        guard let bugMessageID = await sendMessageReturningID(channelId: bugChannelID, content: bugMessage) else {
            let ok = await send(responseChannelId, "❌ Failed to create bug report in <#\(bugChannelID)>.")
            await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
            return
        }

        let creatorID = authorId(from: raw) ?? username
        bugEntriesByMessageID[bugMessageID] = BugEntry(
            bugMessageID: bugMessageID,
            sourceMessageID: sourceMessageID,
            channelID: sourceChannelID,
            guildID: guildId,
            reporterID: reporterID,
            createdBy: creatorID,
            status: .new,
            timestamp: Date()
        )

        let didPin = await retryBugOperation {
            await pinMessage(channelId: bugChannelID, messageId: bugMessageID)
        }
        let didSeedReactions = await seedBugStatusReactions(channelID: bugChannelID, messageID: bugMessageID)

        let threadTitle = bugThreadTitle(from: cleanedSourceText)
        _ = await createThreadFromMessage(channelId: bugChannelID, messageId: bugMessageID, name: threadTitle)
        await postBugThreadLegend(bugChannelID: bugChannelID, bugMessageID: bugMessageID)

        logs.append(
            "🐞 BugEntry created bugMessageID=\(bugMessageID) sourceMessageID=\(sourceMessageID) guildID=\(guildId) reporterID=\(reporterID) createdBy=\(creatorID) status=\(BugStatus.new.rawValue)"
        )

        var responseLines: [String] = ["✅ Bug tracked in <#\(bugChannelID)>."]
        if didPin {
            responseLines.append("📌 Pinned successfully.")
        } else {
            responseLines.append("⚠️ I couldn't pin the bug message. Please grant me `Manage Messages` in <#\(bugChannelID)> so I can pin/unpin bug reports.")
        }
        if !didSeedReactions {
            responseLines.append("⚠️ I couldn't add status reactions. Please grant me `Add Reactions` and `Read Message History` in <#\(bugChannelID)>.")
        }
        let ok = await send(responseChannelId, responseLines.joined(separator: "\n"))
        if !didPin {
            logs.append("⚠️ Bug pin failed for message \(bugMessageID) in channel \(bugChannelID). Likely missing `Manage Messages` permission.")
        }
        if !didSeedReactions {
            logs.append("⚠️ Bug reaction seed failed for message \(bugMessageID) in channel \(bugChannelID). Likely missing `Add Reactions` or `Read Message History` permission.")
        }
        await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
    }

    func handleLogABugSlash(raw: [String: DiscordJSON], username: String, channelId: String, errorText: String) async -> (ok: Bool, message: String) {
        guard settings.bugTrackingEnabled else {
            return (false, "Bug tracking is disabled in command settings.")
        }

        guard let guildId = guildId(from: raw) else {
            return (false, "`/logabug` only works in a server channel.")
        }

        guard await canRunDebugCommand(raw: raw) else {
            return (false, "`/logabug` is restricted to server owners or admins.")
        }

        guard let bugChannelID = bugTrackerChannelID(for: guildId) else {
            return (false, "Couldn't find #swiftbot-dev in this server.")
        }

        let reporterID = authorId(from: raw) ?? "unknown-user"
        let sourceMessageID = "manual-\(UUID().uuidString)"
        let cleanedSourceText = bugPreviewText(from: errorText)
        let bugMessage = """
        🐞 SwiftBot Bug
        Reporter: <@\(reporterID)>
        Channel: <#\(channelId)>
        Message:
        "\(cleanedSourceText)"
        Status: \(BugStatus.new.rawValue)
        Link: Manual log via /logabug
        """

        guard let bugMessageID = await sendMessageReturningID(channelId: bugChannelID, content: bugMessage) else {
            return (false, "Failed to create bug report in <#\(bugChannelID)>.")
        }

        bugEntriesByMessageID[bugMessageID] = BugEntry(
            bugMessageID: bugMessageID,
            sourceMessageID: sourceMessageID,
            channelID: channelId,
            guildID: guildId,
            reporterID: reporterID,
            createdBy: reporterID,
            status: .new,
            timestamp: Date()
        )

        let didPin = await retryBugOperation {
            await pinMessage(channelId: bugChannelID, messageId: bugMessageID)
        }
        let didSeedReactions = await seedBugStatusReactions(channelID: bugChannelID, messageID: bugMessageID)
        let threadTitle = bugThreadTitle(from: cleanedSourceText)
        _ = await createThreadFromMessage(channelId: bugChannelID, messageId: bugMessageID, name: threadTitle)
        await postBugThreadLegend(bugChannelID: bugChannelID, bugMessageID: bugMessageID)

        logs.append(
            "🐞 BugEntry created via /logabug bugMessageID=\(bugMessageID) guildID=\(guildId) reporterID=\(reporterID) status=\(BugStatus.new.rawValue)"
        )

        var lines: [String] = ["Created bug report in <#\(bugChannelID)>."]
        if didPin {
            lines.append("📌 Pinned successfully.")
        } else {
            lines.append("⚠️ I couldn't pin it. Please grant `Manage Messages` in <#\(bugChannelID)>.")
        }
        if !didSeedReactions {
            lines.append("⚠️ I couldn't add status reactions. Please grant `Add Reactions` and `Read Message History` in <#\(bugChannelID)>.")
        }
        return (true, lines.joined(separator: "\n"))
    }

    func handleFeatureRequestSlash(
        raw: [String: DiscordJSON],
        username: String,
        channelId: String,
        featureText: String,
        reasonText: String?
    ) async -> (ok: Bool, message: String) {
        guard let guildId = guildId(from: raw) else {
            return (false, "`/featurerequest` only works in a server channel.")
        }

        guard let targetChannelID = bugTrackerChannelID(for: guildId) else {
            return (false, "Couldn't find #swiftbot-dev in this server.")
        }

        let requesterID = authorId(from: raw) ?? "unknown-user"
        let cleaned = bugPreviewText(from: featureText)
        var message = """
        ✨ SwiftBot Feature Request
        Requester: <@\(requesterID)>
        Channel: <#\(channelId)>
        Feature:
        "\(cleaned)"
        Status: New Request
        """
        let cleanedReason = reasonText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanedReason.isEmpty {
            message += "\nReason:\n\"\(bugPreviewText(from: cleanedReason))\""
        }

        guard let requestMessageID = await sendMessageReturningID(channelId: targetChannelID, content: message) else {
            return (false, "Failed to post feature request in <#\(targetChannelID)>.")
        }

        let didPin = await retryBugOperation {
            await pinMessage(channelId: targetChannelID, messageId: requestMessageID)
        }
        let didSeedReactions = await seedFeatureRequestReactions(channelID: targetChannelID, messageID: requestMessageID)
        let threadTitle = "Feature: " + String(cleaned.prefix(51))
        _ = await createThreadFromMessage(channelId: targetChannelID, messageId: requestMessageID, name: threadTitle)
        await postFeatureThreadLegend(channelID: targetChannelID, messageID: requestMessageID)

        logs.append("✨ Feature request created messageID=\(requestMessageID) guildID=\(guildId) requester=\(requesterID) username=\(username)")
        if !didSeedReactions {
            logs.append("⚠️ Feature request reaction seed failed for message \(requestMessageID) in channel \(targetChannelID). Likely missing `Add Reactions` or `Read Message History` permission.")
        }
        var responseLines = ["Feature request posted in <#\(targetChannelID)>."]
        if didPin {
            responseLines.append("📌 Pinned successfully.")
        } else {
            responseLines.append("⚠️ I couldn't pin it. Please grant `Manage Messages` in that channel.")
        }
        if !didSeedReactions {
            responseLines.append("⚠️ I couldn't add status reactions. Please grant `Add Reactions` and `Read Message History` in that channel.")
        }
        return (true, responseLines.joined(separator: "\n"))
    }

    func handleBugReactionAdd(raw: [String: DiscordJSON]) async {
        guard settings.bugTrackingEnabled else { return }
        guard case let .string(messageID)? = raw["message_id"],
              case let .string(channelID)? = raw["channel_id"],
              case let .string(userID)? = raw["user_id"],
              case let .object(emoji)? = raw["emoji"],
              case let .string(emojiName)? = emoji["name"]
        else { return }

        if let botUserId, userID == botUserId {
            return
        }

        let normalizedEmoji = normalizedReactionEmojiName(emojiName)
        let bugStatus = bugStatusByEmoji[emojiName] ?? bugStatusByEmoji[normalizedEmoji]
        let featureStatus = featureStatusByEmoji[emojiName] ?? featureStatusByEmoji[normalizedEmoji]
        let autoFixTrigger = shouldTriggerBugAutoFix(forEmoji: emojiName) || shouldTriggerBugAutoFix(forEmoji: normalizedEmoji)
        let autoFixApprove = shouldApproveBugAutoFix(forEmoji: emojiName) || shouldApproveBugAutoFix(forEmoji: normalizedEmoji)
        let autoFixReject = shouldRejectBugAutoFix(forEmoji: emojiName) || shouldRejectBugAutoFix(forEmoji: normalizedEmoji)

        if autoFixApprove {
            await approvePendingBugAutoFix(raw: raw, messageID: messageID, channelID: channelID, userID: userID)
            return
        }

        if autoFixReject {
            await rejectPendingBugAutoFix(raw: raw, messageID: messageID, channelID: channelID, userID: userID)
            return
        }

        if autoFixTrigger {
            await handleBugAutoFixReaction(
                raw: raw,
                messageID: messageID,
                channelID: channelID,
                userID: userID
            )
            return
        }

        // Fast path: if we already track this bug message in memory, don't depend on
        // REST fetch permissions to process reaction changes.
        if let bugStatus, bugEntriesByMessageID[messageID] != nil {
            await handleBugStatusReaction(raw: raw, messageID: messageID, channelID: channelID, userID: userID, targetStatus: bugStatus)
            return
        }

        guard bugStatus != nil || featureStatus != nil else { return }

        guard let message = await fetchMessage(channelId: channelID, messageId: messageID),
              case let .string(content)? = message["content"] else {
            logs.append("⚠️ Reaction event received but message fetch failed (channel=\(channelID), message=\(messageID), emoji=\(emojiName)). Check `View Channel` and `Read Message History` permissions.")
            return
        }
        let isBugMessage = content.contains("🐞 SwiftBot Bug")
        let isFeatureMessage = content.contains("✨ SwiftBot Feature Request")

        if isBugMessage, let bugStatus {
            await handleBugStatusReaction(raw: raw, messageID: messageID, channelID: channelID, userID: userID, targetStatus: bugStatus)
            return
        }
        if isFeatureMessage, let featureStatus {
            await handleFeatureStatusReaction(messageID: messageID, channelID: channelID, userID: userID, statusLabel: featureStatus)
            return
        }

        logs.append("ℹ️ Reaction matched status emoji but target message is not a tracked bug/feature message (message=\(messageID), emoji=\(emojiName)).")
    }

    func shouldTriggerBugAutoFix(forEmoji emoji: String) -> Bool {
        guard settings.bugAutoFixEnabled else { return false }
        let trigger = normalizedReactionEmojiName(settings.bugAutoFixTriggerEmoji)
        guard !trigger.isEmpty else { return false }
        return normalizedReactionEmojiName(emoji) == trigger
    }

    func shouldApproveBugAutoFix(forEmoji emoji: String) -> Bool {
        guard settings.bugAutoFixEnabled else { return false }
        let trigger = normalizedReactionEmojiName(settings.bugAutoFixApproveEmoji)
        guard !trigger.isEmpty else { return false }
        return normalizedReactionEmojiName(emoji) == trigger
    }

    func shouldRejectBugAutoFix(forEmoji emoji: String) -> Bool {
        guard settings.bugAutoFixEnabled else { return false }
        let trigger = normalizedReactionEmojiName(settings.bugAutoFixRejectEmoji)
        guard !trigger.isEmpty else { return false }
        return normalizedReactionEmojiName(emoji) == trigger
    }

    func bugAutoFixUsernameAllowed(userID: String) async -> Bool {
        let allowed = settings.bugAutoFixAllowedUsernames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !allowed.isEmpty else { return true }

        let known = (knownUsersById[userID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !known.isEmpty, allowed.contains(known) {
            return true
        }

        let resolved = (await displayNameForUserID(userID)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !resolved.isEmpty && allowed.contains(resolved)
    }

    func handleBugAutoFixReaction(
        raw: [String: DiscordJSON],
        messageID: String,
        channelID: String,
        userID: String
    ) async {
        guard settings.bugAutoFixEnabled else { return }
        guard await bugAutoFixUsernameAllowed(userID: userID) else {
            _ = await send(channelID, "⛔ Auto-fix is restricted to configured usernames.")
            return
        }

        let guildID: String = {
            if case let .string(id)? = raw["guild_id"] { return id }
            return "unknown-guild"
        }()
        let updateChannelID = await ensureBugThreadChannelID(bugChannelID: channelID, bugMessageID: messageID) ?? channelID

        guard let bugMessage = await fetchMessage(channelId: channelID, messageId: messageID),
              case let .string(content)? = bugMessage["content"],
              content.contains("🐞 SwiftBot Bug")
        else { return }

        if pendingBugAutoFixStarts[messageID] != nil {
            _ = await send(updateChannelID, "⏳ Auto-fix is waiting for approval. React with \(settings.bugAutoFixApproveEmoji) to run, or \(settings.bugAutoFixRejectEmoji) to cancel.")
            return
        }

        if pendingBugAutoFixApprovals[messageID] != nil {
            _ = await send(updateChannelID, "⏳ Auto-fix proposal is waiting for approval. React with \(settings.bugAutoFixApproveEmoji) to commit+push, or \(settings.bugAutoFixRejectEmoji) to cancel.")
            return
        }

        guard !activeBugAutoFixMessageIDs.contains(messageID) else {
            _ = await send(updateChannelID, "⏳ Auto-fix is already running for this bug.")
            return
        }

        let repoPathRaw = settings.bugAutoFixRepoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceRepoPath = repoPathRaw.isEmpty ? FileManager.default.currentDirectoryPath : repoPathRaw

        let repoCheck = await runShellCommand("git rev-parse --is-inside-work-tree", workingDirectory: sourceRepoPath)
        let repoCheckOutput = repoCheck.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard repoCheck.exitCode == 0, repoCheckOutput.contains("true") else {
            finishBugAutoFixSession("Invalid repository path")
            _ = await send(
                updateChannelID,
                """
                ❌ Auto-fix repository path is not a git repository: `\(sourceRepoPath)`.
                Set **Settings → Bug Auto-Fix → Repository Path** to your SwiftBot repo root.
                """
            )
            return
        }

        let branch = settings.bugAutoFixGitBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "main"
            : settings.bugAutoFixGitBranch.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let release = await extractBugAutoFixReleaseInfo(channelID: updateChannelID) else {
            _ = await send(
                updateChannelID,
                """
                📝 Auto-fix needs a target release number before it can run.
                In this thread, add a comment like:
                `version=1.8.19 build=181900`
                Then react to the parent bug again with \(settings.bugAutoFixTriggerEmoji).
                """
            )
            return
        }

        guard let isolatedRepoPath = await createBugAutoFixWorkspaceClone(
            sourceRepoPath: sourceRepoPath,
            branch: branch,
            messageID: messageID
        ) else {
            _ = await send(updateChannelID, "❌ Failed to create isolated auto-fix workspace clone.")
            return
        }

        pendingBugAutoFixStarts[messageID] = BugAutoFixPendingStart(
            bugMessageID: messageID,
            channelID: channelID,
            guildID: guildID,
            sourceRepoPath: sourceRepoPath,
            isolatedRepoPath: isolatedRepoPath,
            branch: branch,
            updateChannelID: updateChannelID,
            version: release.version,
            build: release.build,
            requestedByUserID: userID
        )
        _ = await addReaction(channelId: channelID, messageId: messageID, emoji: settings.bugAutoFixApproveEmoji)
        _ = await addReaction(channelId: channelID, messageId: messageID, emoji: settings.bugAutoFixRejectEmoji)

        _ = await send(
            updateChannelID,
            """
            🧾 Auto-fix preflight ready for bug `\(messageID)`.
            Target release: `\(release.version) (\(release.build))`
            Workspace: `\(isolatedRepoPath)`
            No changes were made to the live repo.
            React on the parent bug with \(settings.bugAutoFixApproveEmoji) to start Codex, or \(settings.bugAutoFixRejectEmoji) to cancel.
            """
        )
    }

    func approvePendingBugAutoFix(raw: [String: DiscordJSON], messageID: String, channelID: String, userID: String) async {
        if let pendingStart = pendingBugAutoFixStarts[messageID] {
            guard await bugAutoFixUsernameAllowed(userID: userID) else {
                _ = await send(channelID, "⛔ Auto-fix approval is restricted to configured usernames.")
                return
            }
            pendingBugAutoFixStarts.removeValue(forKey: messageID)
            _ = await send(pendingStart.updateChannelID, "✅ Auto-fix run approved by <@\(userID)>. Starting Codex in isolated workspace…")
            await runPendingBugAutoFixStart(pendingStart)
            return
        }

        guard let pending = pendingBugAutoFixApprovals[messageID] else { return }
        guard await bugAutoFixUsernameAllowed(userID: userID) else {
            _ = await send(channelID, "⛔ Auto-fix approval is restricted to configured usernames.")
            return
        }
        pendingBugAutoFixApprovals.removeValue(forKey: messageID)
        _ = await send(pending.updateChannelID, "✅ Auto-fix approved by <@\(userID)>. Committing and pushing…")
        beginBugAutoFixSession("Approval received; committing and pushing")
        await executeApprovedBugAutoFixPush(
            messageID: pending.bugMessageID,
            updateChannelID: pending.updateChannelID,
            repoPath: pending.isolatedRepoPath,
            branch: pending.branch,
            version: pending.version,
            build: pending.build
        )
    }

    func rejectPendingBugAutoFix(raw: [String: DiscordJSON], messageID: String, channelID: String, userID: String) async {
        guard await bugAutoFixUsernameAllowed(userID: userID) else {
            _ = await send(channelID, "⛔ Auto-fix rejection is restricted to configured usernames.")
            return
        }

        if let pendingStart = pendingBugAutoFixStarts[messageID] {
            pendingBugAutoFixStarts.removeValue(forKey: messageID)
            _ = await runShellCommand("rm -rf \(shellQuote(pendingStart.isolatedRepoPath))", workingDirectory: FileManager.default.currentDirectoryPath)
            finishBugAutoFixSession("Preflight rejected by \(userID)")
            _ = await send(pendingStart.updateChannelID, "🛑 Auto-fix preflight cancelled by <@\(userID)> before any code changes.")
            return
        }

        guard pendingBugAutoFixApprovals[messageID] != nil else { return }
        let updateChannelID = pendingBugAutoFixApprovals[messageID]?.updateChannelID ?? channelID
        pendingBugAutoFixApprovals.removeValue(forKey: messageID)
        finishBugAutoFixSession("Proposal rejected by \(userID)")
        _ = await send(updateChannelID, "🛑 Auto-fix proposal rejected by <@\(userID)>. Isolated workspace changes were retained for manual review.")
    }

    func executeApprovedBugAutoFixPush(
        messageID: String,
        updateChannelID: String,
        repoPath: String,
        branch: String,
        version: String,
        build: String
    ) async {
        let shortId = String(messageID.prefix(8))
        let add = await runShellCommand("git add -A", workingDirectory: repoPath)
        guard add.exitCode == 0 else {
            finishBugAutoFixSession("Failed at git add")
            _ = await send(updateChannelID, "❌ Auto-fix completed, but `git add` failed.")
            return
        }

        let commit = await runShellCommand(
            "git commit -m \"fix: auto-fix bug \(shortId) v\(version) (\(build))\"",
            workingDirectory: repoPath
        )
        if commit.exitCode != 0 {
            let output = commit.combinedOutput.lowercased()
            if output.contains("nothing to commit") || output.contains("no changes added") {
                finishBugAutoFixSession("No committable changes")
                _ = await send(updateChannelID, "ℹ️ Auto-fix proposal had no committable changes.")
                return
            }
            finishBugAutoFixSession("Failed at git commit")
            _ = await send(updateChannelID, "❌ Auto-fix commit failed (exit \(commit.exitCode)).")
            return
        }

        let push = await runShellCommand("git push origin \(branch)", workingDirectory: repoPath)
        guard push.exitCode == 0 else {
            finishBugAutoFixSession("Failed at git push")
            _ = await send(updateChannelID, "❌ Auto-fix committed, but push to `origin/\(branch)` failed.")
            return
        }
        finishBugAutoFixSession("Pushed to \(branch)")
        _ = await send(updateChannelID, "🚀 Auto-fix committed and pushed to `\(branch)` with version `\(version)` build `\(build)`. CI/ShipHook build should start shortly.")
    }

    func applyVersionAndBuildNumber(repoPath: String, version: String, build: String) -> Bool {
        let pbxprojPath = URL(fileURLWithPath: repoPath)
            .appendingPathComponent("SwiftBot.xcodeproj")
            .appendingPathComponent("project.pbxproj")
        guard let content = try? String(contentsOf: pbxprojPath, encoding: .utf8) else { return false }

        guard
            let buildRegex = try? NSRegularExpression(pattern: #"CURRENT_PROJECT_VERSION = [^;]+;"#),
            let versionRegex = try? NSRegularExpression(pattern: #"MARKETING_VERSION = [^;]+;"#)
        else { return false }

        let ns = content as NSString
        let buildReplaced = buildRegex.stringByReplacingMatches(
            in: content,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "CURRENT_PROJECT_VERSION = \(build);"
        )
        let versionNs = buildReplaced as NSString
        let replaced = versionRegex.stringByReplacingMatches(
            in: buildReplaced,
            range: NSRange(location: 0, length: versionNs.length),
            withTemplate: "MARKETING_VERSION = \(version);"
        )

        do {
            try replaced.write(to: pbxprojPath, atomically: true, encoding: .utf8)
            logs.append("Auto-fix set MARKETING_VERSION=\(version), CURRENT_PROJECT_VERSION=\(build)")
            return true
        } catch {
            logs.append("Auto-fix version/build write failed: \(error.localizedDescription)")
            return false
        }
    }

    func runPendingBugAutoFixStart(_ pending: BugAutoFixPendingStart) async {
        guard !activeBugAutoFixMessageIDs.contains(pending.bugMessageID) else {
            _ = await send(pending.updateChannelID, "⏳ Auto-fix is already running for this bug.")
            return
        }
        activeBugAutoFixMessageIDs.insert(pending.bugMessageID)
        defer { activeBugAutoFixMessageIDs.remove(pending.bugMessageID) }

        let commandTemplate = settings.bugAutoFixCommandTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandTemplate.isEmpty else {
            _ = await send(pending.updateChannelID, "❌ Auto-fix command template is empty. Configure it in Settings → Bug Auto-Fix.")
            return
        }

        guard let bugMessage = await fetchMessage(channelId: pending.channelID, messageId: pending.bugMessageID),
              case let .string(content)? = bugMessage["content"],
              content.contains("🐞 SwiftBot Bug")
        else {
            _ = await send(pending.updateChannelID, "❌ Could not fetch the source bug report message.")
            return
        }

        beginBugAutoFixSession("Running Codex for bug \(pending.bugMessageID)")
        _ = await send(
            pending.updateChannelID,
            """
            🤖 Auto-fix triggered by <@\(pending.requestedByUserID)> — running Codex pipeline…
            Release target: `\(pending.version) (\(pending.build))`
            Workspace: `\(pending.isolatedRepoPath)`
            """
        )

        var lastForwardAt = Date.distantPast
        var bufferedForward = ""
        func flushForwardBuffer() {
            let trimmed = bufferedForward.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let sanitized = trimmed.replacingOccurrences(of: "```", with: "'''")
            let snippet = String(sanitized.suffix(1400))
            bufferedForward = ""
            lastForwardAt = Date()
            Task { _ = await send(pending.updateChannelID, "```text\n\(snippet)\n```") }
        }

        let prompt = """
        You are fixing a tracked SwiftBot bug.
        Source repository: \(pending.sourceRepoPath)
        Isolated workspace: \(pending.isolatedRepoPath)
        Bug message ID: \(pending.bugMessageID)
        Discord guild/channel: \(pending.guildID)/\(pending.channelID)
        Target release version/build: \(pending.version) (\(pending.build))

        Bug report content:
        \(content)

        Required:
        1) Implement a safe fix in the isolated workspace only.
        2) Keep changes minimal and targeted.
        3) Summarize what changed and why in concise bullets.
        """

        let contextURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftbot-bug-\(pending.bugMessageID).txt")
        do {
            try prompt.write(to: contextURL, atomically: true, encoding: .utf8)
        } catch {
            _ = await send(pending.updateChannelID, "❌ Failed to write bug context file: \(error.localizedDescription)")
            return
        }

        let codex = await runShellCommand(
            commandTemplate,
            workingDirectory: pending.isolatedRepoPath,
            environment: [
                "SWIFTBOT_BUG_PROMPT": prompt,
                "SWIFTBOT_BUG_CONTEXT_FILE": contextURL.path,
                "SWIFTBOT_REPO_PATH": pending.isolatedRepoPath,
                "SWIFTBOT_BUG_MESSAGE_ID": pending.bugMessageID,
                "SWIFTBOT_BUG_CHANNEL_ID": pending.channelID,
                "SWIFTBOT_BUG_GUILD_ID": pending.guildID,
                "SWIFTBOT_TARGET_VERSION": pending.version,
                "SWIFTBOT_TARGET_BUILD": pending.build
            ],
            outputSink: { chunk in
                bufferedForward.append(chunk)
                let now = Date()
                if bufferedForward.count > 1400 || now.timeIntervalSince(lastForwardAt) >= 4 {
                    flushForwardBuffer()
                }
            }
        )
        flushForwardBuffer()

        guard codex.exitCode == 0 else {
            let tail = codex.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = tail.isEmpty ? "No output." : String(tail.suffix(700))
            finishBugAutoFixSession("Codex failed (exit \(codex.exitCode))")
            _ = await send(pending.updateChannelID, "❌ Codex auto-fix failed (exit \(codex.exitCode)).\n```\(snippet)```")
            return
        }

        if !applyVersionAndBuildNumber(repoPath: pending.isolatedRepoPath, version: pending.version, build: pending.build) {
            _ = await send(
                pending.updateChannelID,
                "⚠️ Codex completed, but setting MARKETING_VERSION/CURRENT_PROJECT_VERSION failed in workspace."
            )
        }

        let status = await runShellCommand("git status --short", workingDirectory: pending.isolatedRepoPath)
        let diffStat = await runShellCommand("git diff --stat", workingDirectory: pending.isolatedRepoPath)
        let changedFilesRaw = await runShellCommand("git diff --name-only", workingDirectory: pending.isolatedRepoPath)
        let hasChanges = !status.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !hasChanges {
            finishBugAutoFixSession("No changes produced")
            _ = await send(pending.updateChannelID, "ℹ️ Auto-fix ran, but produced no git changes.")
            return
        }

        let compactStat = diffStat.combinedOutput
            .split(separator: "\n")
            .prefix(14)
            .joined(separator: "\n")
        let changedFiles = changedFilesRaw.combinedOutput
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let changedFilesSnippet: String = {
            guard !changedFiles.isEmpty else { return "(none listed)" }
            return changedFiles.prefix(10).map { "- \($0)" }.joined(separator: "\n")
        }()
        let codexWhy = codex.combinedOutput
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("$ ") && !$0.hasPrefix("exit ") }
            .suffix(8)
            .joined(separator: "\n")
        let whySnippet = codexWhy.isEmpty ? "Codex output did not include a concise summary." : codexWhy

        if settings.bugAutoFixPushEnabled && settings.bugAutoFixRequireApproval {
            pendingBugAutoFixApprovals[pending.bugMessageID] = BugAutoFixPendingApproval(
                bugMessageID: pending.bugMessageID,
                channelID: pending.channelID,
                guildID: pending.guildID,
                sourceRepoPath: pending.sourceRepoPath,
                isolatedRepoPath: pending.isolatedRepoPath,
                branch: pending.branch,
                updateChannelID: pending.updateChannelID,
                version: pending.version,
                build: pending.build
            )
            _ = await addReaction(channelId: pending.channelID, messageId: pending.bugMessageID, emoji: settings.bugAutoFixApproveEmoji)
            _ = await addReaction(channelId: pending.channelID, messageId: pending.bugMessageID, emoji: settings.bugAutoFixRejectEmoji)
            _ = await send(
                pending.updateChannelID,
                """
                🧠 Codex proposed changes for bug `\(pending.bugMessageID)`:
                **Target release:** `\(pending.version) (\(pending.build))`
                **Changed files:**
                ```text
                \(changedFilesSnippet)
                ```
                **Diff stat:**
                ```text
                \(compactStat.isEmpty ? "(no diff stat)" : compactStat)
                ```
                **Why / summary:**
                ```text
                \(String(whySnippet.suffix(1200)))
                ```
                React on the bug message with \(settings.bugAutoFixApproveEmoji) to commit+push, or \(settings.bugAutoFixRejectEmoji) to cancel.
                """
            )
            finishBugAutoFixSession("Waiting for push approval")
            return
        }

        if settings.bugAutoFixPushEnabled {
            await executeApprovedBugAutoFixPush(
                messageID: pending.bugMessageID,
                updateChannelID: pending.updateChannelID,
                repoPath: pending.isolatedRepoPath,
                branch: pending.branch,
                version: pending.version,
                build: pending.build
            )
        } else {
            finishBugAutoFixSession("Completed (isolated workspace only)")
            _ = await send(
                pending.updateChannelID,
                """
                ✅ Auto-fix completed in isolated workspace only (auto-push disabled).
                Release target: `\(pending.version) (\(pending.build))`
                Workspace: `\(pending.isolatedRepoPath)`
                """
            )
        }
    }

    func extractBugAutoFixReleaseInfo(channelID: String) async -> (version: String, build: String)? {
        let messages = await fetchRecentMessages(channelId: channelID, limit: 50)
        for message in messages {
            guard case let .string(content)? = message["content"] else { continue }
            if let parsed = parseBugAutoFixReleaseInfo(from: content) {
                return parsed
            }
        }
        return nil
    }

    func parseBugAutoFixReleaseInfo(from text: String) -> (version: String, build: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let ns = trimmed as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let versionRegex = try? NSRegularExpression(pattern: #"(?i)\bversion\s*[:=]\s*([0-9]+(?:\.[0-9]+){1,3})\b"#)
        let buildRegex = try? NSRegularExpression(pattern: #"(?i)\bbuild\s*[:=]\s*([0-9]{3,})\b"#)
        guard
            let versionMatch = versionRegex?.firstMatch(in: trimmed, range: fullRange),
            let buildMatch = buildRegex?.firstMatch(in: trimmed, range: fullRange),
            versionMatch.numberOfRanges >= 2,
            buildMatch.numberOfRanges >= 2
        else { return nil }

        let version = ns.substring(with: versionMatch.range(at: 1))
        let build = ns.substring(with: buildMatch.range(at: 1))
        return (version, build)
    }

    func createBugAutoFixWorkspaceClone(sourceRepoPath: String, branch: String, messageID: String) async -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftbot-autofix", isDirectory: true)
        let workspaceURL = root.appendingPathComponent(
            "\(messageID)-\(Int(Date().timeIntervalSince1970))",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            logs.append("Auto-fix workspace create failed: \(error.localizedDescription)")
            return nil
        }

        let command = "git clone --no-local --single-branch --branch \(shellQuote(branch)) \(shellQuote(sourceRepoPath)) \(shellQuote(workspaceURL.path))"
        let clone = await runShellCommand(command, workingDirectory: FileManager.default.currentDirectoryPath)
        guard clone.exitCode == 0 else {
            logs.append("Auto-fix clone failed: \(clone.combinedOutput)")
            return nil
        }
        return workspaceURL.path
    }

    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func runShellCommand(
        _ command: String,
        workingDirectory: String,
        environment: [String: String] = [:],
        outputSink: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> (exitCode: Int32, combinedOutput: String) {
        final class OutputBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()

            func append(_ chunk: Data) {
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }

            func snapshot() -> Data {
                lock.lock()
                let copy = data
                lock.unlock()
                return copy
            }
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

            var env = ProcessInfo.processInfo.environment
            environment.forEach { env[$0.key] = $0.value }
            process.environment = env

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            let captured = OutputBuffer()

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                captured.append(data)
                if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                    Task { @MainActor in
                        self?.appendBugAutoFixConsole(chunk)
                        outputSink?(chunk)
                    }
                }
            }

            appendBugAutoFixConsole("$ \(command)")
            outputSink?("$ \(command)\n")

            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if !data.isEmpty { captured.append(data) }
                let text = String(data: captured.snapshot(), encoding: .utf8) ?? ""
                Task { @MainActor [weak self] in
                    self?.appendBugAutoFixConsole("exit \(proc.terminationStatus)")
                    outputSink?("exit \(proc.terminationStatus)\n")
                }
                continuation.resume(returning: (proc.terminationStatus, text))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (127, error.localizedDescription))
            }
        }
    }

    func normalizedReactionEmojiName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{FE0F}", with: "")
    }

    func handleBugStatusReaction(
        raw: [String: DiscordJSON],
        messageID: String,
        channelID: String,
        userID: String,
        targetStatus: BugStatus
    ) async {

        let guildID: String? = {
            if case let .string(id)? = raw["guild_id"] { return id }
            return nil
        }()
        guard var entry = await loadOrCreateBugEntry(
            bugMessageID: messageID,
            channelID: channelID,
            guildID: guildID,
            fallbackCreatedBy: userID
        ) else { return }

        entry.status = targetStatus
        entry.timestamp = Date()
        bugEntriesByMessageID[messageID] = entry

        let reactionsReady = await seedBugStatusReactions(channelID: channelID, messageID: messageID)
        let contentUpdated = await updateBugMessageStatus(channelID: channelID, messageID: messageID, status: targetStatus)
        await postBugThreadStatusNote(
            bugChannelID: channelID,
            bugMessageID: messageID,
            actorUserID: userID,
            status: targetStatus
        )

        var statusOK = contentUpdated && reactionsReady
        if targetStatus == .resolved {
            let unpinned = await unpinMessage(channelId: channelID, messageId: messageID)
            if unpinned {
                _ = await send(channelID, "✅ Bug resolved — unpinned")
            }
            statusOK = statusOK && unpinned
        }

        let reactorName = await displayNameForUserID(userID)
        let serverName = connectedServers[entry.guildID] ?? "Server \(entry.guildID.suffix(4))"
        await appendBugCommandLog(
            user: reactorName,
            server: serverName,
            command: "@swiftbot bug status \(targetStatus.rawValue)",
            channel: channelID,
            ok: statusOK
        )
        logs.append("🐞 BugEntry updated bugMessageID=\(messageID) status=\(targetStatus.rawValue) by=\(userID)")
    }

    func handleFeatureStatusReaction(
        messageID: String,
        channelID: String,
        userID: String,
        statusLabel: String
    ) async {
        guard let message = await fetchMessage(channelId: channelID, messageId: messageID),
              case let .string(content)? = message["content"],
              content.contains("✨ SwiftBot Feature Request")
        else { return }

        let reactionsReady = await seedFeatureRequestReactions(channelID: channelID, messageID: messageID)
        let updatedContent = replacingBugStatusLine(in: content, status: statusLabel)
        let contentUpdated = await editMessage(channelId: channelID, messageId: messageID, content: updatedContent)

        var unpinOK = true
        if statusLabel == "Implemented" {
            let didUnpin = await unpinMessage(channelId: channelID, messageId: messageID)
            unpinOK = didUnpin
            if didUnpin {
                _ = await send(channelID, "✅ Feature request implemented — unpinned.")
            }
        }

        if let threadID = await ensureBugThreadChannelID(bugChannelID: channelID, bugMessageID: messageID) {
            _ = await send(threadID, "📝 <@\(userID)> marked this feature request as **\(statusLabel)**.")
        }

        let guildID: String = {
            if case let .string(id)? = message["guild_id"] { return id }
            return "unknown-guild"
        }()
        let reactorName = await displayNameForUserID(userID)
        let serverName = connectedServers[guildID] ?? "Server \(guildID.suffix(4))"
        await appendBugCommandLog(
            user: reactorName,
            server: serverName,
            command: "/featurerequest status \(statusLabel)",
            channel: channelID,
            ok: contentUpdated && reactionsReady && unpinOK
        )
        logs.append("✨ Feature request updated messageID=\(messageID) status=\(statusLabel) by=\(userID)")
    }

    func loadOrCreateBugEntry(
        bugMessageID: String,
        channelID: String,
        guildID: String?,
        fallbackCreatedBy: String
    ) async -> BugEntry? {
        if let existing = bugEntriesByMessageID[bugMessageID] {
            return existing
        }

        guard let message = await fetchMessage(channelId: channelID, messageId: bugMessageID),
              case let .string(content)? = message["content"],
              content.contains("🐞 SwiftBot Bug")
        else {
            return nil
        }

        let parsedSourceMessageID = parseBugSourceMessageID(from: content)
        let parsedReporterID = parseBugReporterID(from: content) ?? "unknown-user"
        let parsedStatus = parseBugStatus(from: content) ?? .new
        let resolvedGuildID: String = guildID
            ?? {
                if case let .string(id)? = message["guild_id"] { return id }
                return "unknown-guild"
            }()
        let sourceChannelID = parseBugSourceChannelID(from: content) ?? channelID

        let reconstructed = BugEntry(
            bugMessageID: bugMessageID,
            sourceMessageID: parsedSourceMessageID ?? bugMessageID,
            channelID: sourceChannelID,
            guildID: resolvedGuildID,
            reporterID: parsedReporterID,
            createdBy: fallbackCreatedBy,
            status: parsedStatus,
            timestamp: Date()
        )
        bugEntriesByMessageID[bugMessageID] = reconstructed
        return reconstructed
    }

    func appendBugCommandLog(user: String, server: String, command: String, channel: String, ok: Bool) async {
        let executionDetails = await commandExecutionDetails(for: "bug")
        commandLog.insert(CommandLogEntry(
            time: Date(),
            user: user,
            server: server,
            command: command,
            channel: channel,
            executionRoute: executionDetails.route,
            executionNode: executionDetails.node,
            ok: ok
        ), at: 0)
    }

    func bugTrackerChannelID(for guildID: String) -> String? {
        let channels = availableTextChannelsByServer[guildID] ?? []
        if let exact = channels.first(where: { $0.name.caseInsensitiveCompare("swiftbot-dev") == .orderedSame }) {
            return exact.id
        }
        return nil
    }

    func bugPreviewText(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "(no text content)"
        }
        let collapsed = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let reducedSpaces = collapsed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return reducedSpaces.count > 1200 ? String(reducedSpaces.prefix(1200)) + "..." : reducedSpaces
    }

    func bugThreadTitle(from preview: String) -> String {
        let base = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Bug: "
        guard !base.isEmpty else { return "\(prefix)Untitled" }
        let limit = max(1, 60 - prefix.count)
        return prefix + String(base.prefix(limit))
    }

    func seedBugStatusReactions(channelID: String, messageID: String) async -> Bool {
        var allSucceeded = true
        for emoji in bugStatusEmojis {
            let added = await retryBugOperation {
                await addReaction(channelId: channelID, messageId: messageID, emoji: emoji)
            }
            allSucceeded = allSucceeded && added
        }
        return allSucceeded
    }

    func retryBugOperation(maxAttempts: Int = 3, delayNanoseconds: UInt64 = 250_000_000, operation: () async -> Bool) async -> Bool {
        for attempt in 1...maxAttempts {
            if await operation() {
                return true
            }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        return false
    }

    func updateBugMessageStatus(channelID: String, messageID: String, status: BugStatus) async -> Bool {
        guard let message = await fetchMessage(channelId: channelID, messageId: messageID),
              case let .string(currentContent)? = message["content"] else {
            return false
        }
        let updated = replacingBugStatusLine(in: currentContent, status: status.rawValue)
        return await editMessage(channelId: channelID, messageId: messageID, content: updated)
    }

    func replacingBugStatusLine(in text: String, status: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var found = false
        let rewritten = lines.map { line -> String in
            if line.hasPrefix("Status:") {
                found = true
                return "Status: \(status)"
            }
            return line
        }
        if found {
            return rewritten.joined(separator: "\n")
        }
        return text + "\nStatus: \(status)"
    }

    func bugReportText(for raw: [String: DiscordJSON]) -> String {
        guard let guildID = guildId(from: raw) else {
            return "⚠️ `\(effectivePrefix())bugreport` only works in a server channel."
        }

        let statuses: [BugStatus] = [.new, .workingOn, .inProgress, .blocked, .resolved]
        let entries = bugEntriesByMessageID.values.filter { $0.guildID == guildID }
        let grouped = Dictionary(grouping: entries, by: \.status)

        var lines: [String] = ["🐞 SwiftBot Bug Report"]
        lines.append("Total: \(entries.count)")
        for status in statuses {
            lines.append("\(status.emoji) \(status.rawValue): \(grouped[status]?.count ?? 0)")
        }
        return lines.joined(separator: "\n")
    }

    func parseBugStatus(from content: String) -> BugStatus? {
        guard let statusLine = content
            .components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("Status:") })
        else { return nil }
        let raw = statusLine.replacingOccurrences(of: "Status:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return BugStatus(rawValue: raw)
    }

    func parseBugReporterID(from content: String) -> String? {
        guard let reporterLine = content
            .components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("Reporter:") })
        else { return nil }
        guard let start = reporterLine.range(of: "<@")?.upperBound,
              let end = reporterLine[start...].firstIndex(of: ">") else {
            return nil
        }
        let userID = String(reporterLine[start..<end])
        return userID.allSatisfy(\.isNumber) ? userID : nil
    }

    func parseBugSourceChannelID(from content: String) -> String? {
        guard let channelLine = content
            .components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("Channel:") })
        else { return nil }
        guard let start = channelLine.range(of: "<#")?.upperBound,
              let end = channelLine[start...].firstIndex(of: ">") else {
            return nil
        }
        let channelID = String(channelLine[start..<end])
        return channelID.allSatisfy(\.isNumber) ? channelID : nil
    }

    func parseBugSourceMessageID(from content: String) -> String? {
        guard let linkLine = content
            .components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("Link:") })
        else { return nil }
        let components = linkLine.split(separator: "/").map(String.init)
        guard let last = components.last, last.allSatisfy(\.isNumber) else { return nil }
        return last
    }

    func postBugThreadStatusNote(
        bugChannelID: String,
        bugMessageID: String,
        actorUserID: String,
        status: BugStatus
    ) async {
        let threadID = await ensureBugThreadChannelID(bugChannelID: bugChannelID, bugMessageID: bugMessageID)
        guard let threadID else { return }
        let note = "📝 <@\(actorUserID)> marked this issue as **\(status.rawValue)**."
        _ = await send(threadID, note)
    }

    func postBugThreadLegend(bugChannelID: String, bugMessageID: String) async {
        guard let threadID = await ensureBugThreadChannelID(bugChannelID: bugChannelID, bugMessageID: bugMessageID) else { return }
        let legend = """
        🧭 **Bug Status Reactions**
        🐞 New
        🔧 Working On
        🟡 In Progress
        ⛔ Blocked
        ✅ Resolved

        Add one of these reactions on the parent bug message to update status.
        """
        _ = await send(threadID, legend)
    }

    func seedFeatureRequestReactions(channelID: String, messageID: String) async -> Bool {
        var allSucceeded = true
        for item in featureStatusEmojiDescriptions {
            let added = await retryBugOperation {
                await addReaction(channelId: channelID, messageId: messageID, emoji: item.emoji)
            }
            allSucceeded = allSucceeded && added
        }
        return allSucceeded
    }

    func postFeatureThreadLegend(channelID: String, messageID: String) async {
        guard let threadID = await ensureBugThreadChannelID(bugChannelID: channelID, bugMessageID: messageID) else { return }
        var lines: [String] = ["🧭 **Feature Request Status Reactions**"]
        for item in featureStatusEmojiDescriptions {
            lines.append("\(item.emoji) \(item.label)")
        }
        lines.append("")
        lines.append("Add one of these reactions on the parent feature request message to show current status.")
        _ = await send(threadID, lines.joined(separator: "\n"))
    }

    func ensureBugThreadChannelID(bugChannelID: String, bugMessageID: String) async -> String? {
        if let message = await fetchMessage(channelId: bugChannelID, messageId: bugMessageID),
           case let .object(thread)? = message["thread"],
           case let .string(threadID)? = thread["id"],
           !threadID.isEmpty {
            return threadID
        }

        let threadCreated = await createThreadFromMessage(
            channelId: bugChannelID,
            messageId: bugMessageID,
            name: "Bug Thread"
        )
        guard threadCreated else { return nil }

        if let refreshed = await fetchMessage(channelId: bugChannelID, messageId: bugMessageID),
           case let .object(thread)? = refreshed["thread"],
           case let .string(threadID)? = thread["id"],
           !threadID.isEmpty {
            return threadID
        }
        return nil
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

        let roleIdsFromPayload: [String] = {
            guard case let .object(member)? = raw["member"],
                  case let .array(rolesArray)? = member["roles"] else {
                return []
            }
            return rolesArray.compactMap { roleValue in
                if case let .string(id) = roleValue { return id }
                return nil
            }
        }()
        if hasAdministratorPermissionRole(guildId: guildId, roleIds: roleIdsFromPayload) {
            return true
        }

        // Fallback for events that don't include `member` (e.g. some reaction payloads):
        // fetch member role IDs via REST and match against known admin role names.
        if let memberRoleIDs = await guildMemberRoleIDs(guildID: guildId, userID: userId) {
            let adminRoleIDs = Set(
                (availableRolesByServer[guildId] ?? [])
                    .filter { role in
                        let lowered = role.name.lowercased()
                        return lowered == "admin" || lowered == "administrator"
                    }
                    .map(\.id)
            )
            if memberRoleIDs.contains(where: { adminRoleIDs.contains($0) }) {
                return true
            }
            if hasAdministratorPermissionRole(guildId: guildId, roleIds: memberRoleIDs) {
                return true
            }
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
        guard let ownerId = await guildOwnerID(guildID: guildId) else { return false }
        return ownerId == userId
    }

    func guildOwnerID(guildID: String) async -> String? {
        let trimmedGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuildID.isEmpty else { return nil }

        if let cached = guildOwnerIdByGuild[trimmedGuildID], !cached.isEmpty {
            return cached
        }

        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        if let ownerID = await guildRESTClient.fetchGuildOwnerID(guildID: trimmedGuildID, token: token) {
            guildOwnerIdByGuild[trimmedGuildID] = ownerID
            return ownerID
        }
        return nil
    }

    func guildMemberRoleIDs(guildID: String, userID: String) async -> [String]? {
        let trimmedGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuildID.isEmpty, !trimmedUserID.isEmpty, !token.isEmpty else { return nil }

        return await guildRESTClient.fetchGuildMemberRoleIDs(
            guildID: trimmedGuildID,
            userID: trimmedUserID,
            token: token
        )
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

    func hasAdministratorPermissionRole(guildId: String, roleIds: [String]) -> Bool {
        let adminBit: UInt64 = 1 << 3
        let rolesById = Dictionary(uniqueKeysWithValues: (availableRolesByServer[guildId] ?? []).map { ($0.id, $0) })
        for roleId in roleIds {
            guard let role = rolesById[roleId],
                  let permissionsString = role.permissions,
                  let permissions = UInt64(permissionsString) else { continue }
            if (permissions & adminBit) != 0 {
                return true
            }
        }
        return false
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
        let connectedNodes = clusterNodes.filter { $0.status != .disconnected }
        let connectedNodeSummary = connectedNodes.prefix(3).map { node in
            let latency = node.latencyMs.map { "\(Int($0.rounded()))ms" } ?? "n/a"
            return "\(node.displayName) (\(node.role.rawValue), \(node.status.rawValue), \(latency))"
        }.joined(separator: "; ")
        let offloadedTasks = commandLog.reduce(into: 0) { count, entry in
            let route = entry.executionRoute.lowercased()
            if route == "worker" || route == "remote" { count += 1 }
        }

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
            "SwiftMesh Connected Nodes: \(connectedNodes.count)/\(clusterNodes.count)",
            "SwiftMesh Registered Workers: \(registeredWorkersDebugCount)",
            "SwiftMesh Worker Heartbeats: \(registeredWorkersDebugSummary)",
            "SwiftMesh Node Summary: \(connectedNodeSummary.isEmpty ? "none" : connectedNodeSummary)",
            "SwiftMesh Worker State: \(clusterSnapshot.workerStatusText)",
            "SwiftMesh Diagnostics: \(clusterSnapshot.diagnostics)",
            "SwiftMesh Last Job: \(clusterSnapshot.lastJobSummary) [\(clusterSnapshot.lastJobRoute.rawValue)]",
            "SwiftMesh Last Job Node: \(clusterSnapshot.lastJobNode)",
            "Offload AI Replies: \(settings.clusterOffloadAIReplies ? "on" : "off")",
            "Offload Wiki Lookups: \(settings.clusterOffloadWikiLookups ? "on" : "off")",
            "Tasks Offloaded: \(offloadedTasks)",
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
        let connectedNodes = clusterNodes.filter { $0.status != .disconnected }
        let connectedNodeSummary = connectedNodes.prefix(3).map { node in
            let latency = node.latencyMs.map { "\(Int($0.rounded()))ms" } ?? "n/a"
            return "\(node.displayName) (\(node.role.rawValue), \(node.status.rawValue), \(latency))"
        }.joined(separator: "\n")
        let offloadedTasks = commandLog.reduce(into: 0) { count, entry in
            let route = entry.executionRoute.lowercased()
            if route == "worker" || route == "remote" { count += 1 }
        }

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
            ],
            [
                "name": "SwiftMesh",
                "value": "Connected: `\(connectedNodes.count)/\(clusterNodes.count)`\nRegistered Workers: `\(registeredWorkersDebugCount)`\nWorker State: `\(clusterSnapshot.workerStatusText)`\nLast Job: `\(clusterSnapshot.lastJobSummary)`\nRoute: `\(clusterSnapshot.lastJobRoute.rawValue)`\nNode: `\(clusterSnapshot.lastJobNode)`",
                "inline": false
            ],
            [
                "name": "Offload",
                "value": "AI Replies: `\(settings.clusterOffloadAIReplies ? "On" : "Off")`\nWiki: `\(settings.clusterOffloadWikiLookups ? "On" : "Off")`\nTasks Offloaded: `\(offloadedTasks)`",
                "inline": true
            ],
            [
                "name": "Connected Nodes",
                "value": connectedNodeSummary.isEmpty ? "None" : connectedNodeSummary,
                "inline": false
            ],
            [
                "name": "Worker Heartbeats",
                "value": registeredWorkersDebugSummary,
                "inline": false
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
        var recent = await conversationStore.recentMessages(in: scope, limit: maxHistory)

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
        return await sendPayload(channelId: channelId, payload: payload, action: "sendMessage(embed)")
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

    func performWorkerConnectionTest(leaderAddress rawValue: String, leaderPort: Int? = nil) async -> WorkerConnectionTestOutcome {
        guard let baseURL = normalizedSwiftMeshBaseURL(from: rawValue, defaultPort: leaderPort),
              let host = baseURL.host else {
            return WorkerConnectionTestOutcome(
                message: "Invalid URL. Use `host` + `port` or `http(s)://host[:port]`. Input: \"\(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))\" (Port: \(leaderPort?.description ?? "-"))",
                isSuccess: false
            )
        }

        let port = baseURL.port ?? (baseURL.scheme?.lowercased() == "https" ? 443 : 80)
        let endpoint = "\(baseURL.scheme?.uppercased() ?? "HTTP") \(host):\(port)"
        switch testReachability(host: host, port: port) {
        case .hostUnreachable(let reason):
            return WorkerConnectionTestOutcome(
                message: """
                Resolve + Reachability ✗
                Target: \(endpoint)
                Reason: \(reason)
                """,
                isSuccess: false
            )
        case .reachable:
            break
        }

        guard let pingURL = URL(string: baseURL.absoluteString + "/cluster/ping") else {
            return WorkerConnectionTestOutcome(
                message: """
                Resolve + Reachability ✓
                HTTP /cluster/ping ✗
                Target: \(baseURL.absoluteString)/cluster/ping
                Reason: Invalid URL
                """,
                isSuccess: false
            )
        }

        var request = URLRequest(url: pingURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        await applyMeshAuthToConnectionTestRequest(&request, path: "/cluster/ping")

        do {
            let startedAt = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let latencyMs = max(1.0, Date().timeIntervalSince(startedAt) * 1000)

            guard let http = response as? HTTPURLResponse else {
                return WorkerConnectionTestOutcome(
                    message: """
                    Resolve + Reachability ✓
                    HTTP /cluster/ping ✗
                    Target: \(pingURL.absoluteString)
                    Reason: No HTTP response
                    """,
                    isSuccess: false
                )
            }
            if http.statusCode == 401 {
                let authMode = settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "none" : "HMAC"
                return WorkerConnectionTestOutcome(
                    message: """
                    Resolve + Reachability ✓
                    HTTP /cluster/ping ✗ (401 Unauthorized)
                    Target: \(pingURL.absoluteString)
                    Auth mode: \(authMode)
                    Reason: Shared secret mismatch or missing secret
                    """,
                    isSuccess: false
                )
            }
            guard (200..<300).contains(http.statusCode),
                  let payload = try? JSONDecoder().decode(SwiftMeshPingResponse.self, from: data),
                  payload.status.caseInsensitiveCompare("ok") == .orderedSame,
                  payload.role.caseInsensitiveCompare("leader") == .orderedSame else {
                let snippet = String(data: data, encoding: .utf8)?
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
                return WorkerConnectionTestOutcome(
                    message: """
                    Resolve + Reachability ✓
                    HTTP /cluster/ping ✗ (\(http.statusCode))
                    Target: \(pingURL.absoluteString)
                    Reason: Server reachable but not a SwiftBot leader
                    Response: \(String(snippet.prefix(180)))
                    """,
                    isSuccess: false
                )
            }

            let latencyValue = Int(latencyMs.rounded())
            return WorkerConnectionTestOutcome(
                message: """
                Resolve + Reachability ✓
                HTTP /cluster/ping ✓ (200)
                Role Validation ✓ (role=\(payload.role), node=\(payload.node))
                Latency: \(latencyValue) ms
                """,
                isSuccess: true,
                latencyMs: latencyMs,
                nodeName: payload.node
            )
        } catch let error as URLError {
            switch error.code {
            case .badURL, .unsupportedURL:
                return WorkerConnectionTestOutcome(message: "Invalid URL (\(error.code.rawValue)) for \(pingURL.absoluteString)", isSuccess: false)
            case .cannotFindHost, .dnsLookupFailed, .timedOut, .notConnectedToInternet:
                return WorkerConnectionTestOutcome(
                    message: "HTTP request to \(pingURL.absoluteString) failed (\(error.code.rawValue)): \(error.localizedDescription)",
                    isSuccess: false
                )
            case .cannotConnectToHost:
                let portLabel = baseURL.port ?? (baseURL.scheme?.lowercased() == "https" ? 443 : 80)
                return WorkerConnectionTestOutcome(
                    message: "Connection refused to \(host):\(portLabel) (\(error.code.rawValue)). Primary may be offline, firewalled, or bound to a different port.",
                    isSuccess: false
                )
            default:
                return WorkerConnectionTestOutcome(
                    message: "HTTP request failed (\(error.code.rawValue)) for \(pingURL.absoluteString): \(error.localizedDescription)",
                    isSuccess: false
                )
            }
        } catch {
            return WorkerConnectionTestOutcome(message: "Unexpected error for \(pingURL.absoluteString): \(error.localizedDescription)", isSuccess: false)
        }
    }

    private func applyMeshAuthToConnectionTestRequest(_ request: inout URLRequest, path: String) async {
        let secret = settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return }

        let nonce = UUID().uuidString
        let timestamp = Int(Date().timeIntervalSince1970)
        let body = request.httpBody ?? Data()
        let method = request.httpMethod ?? "GET"
        let signature = await cluster.meshSignature(method: method, nonce: nonce, timestamp: timestamp, path: path, body: body)
        request.setValue(nonce, forHTTPHeaderField: "X-Mesh-Nonce")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Mesh-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Mesh-Signature")
    }

    func normalizedSwiftMeshBaseURL(from rawValue: String, defaultPort: Int? = nil) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hadExplicitScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
        let candidate: String
        if hadExplicitScheme {
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
        // For host-only input (no scheme), require an explicit port (or use defaultPort)
        // to avoid silently probing the wrong endpoint and reporting timeouts.
        if !hadExplicitScheme, url.port == nil, defaultPort == nil {
            return nil
        }
        let resolvedPort = url.port ?? defaultPort ?? (scheme.lowercased() == "https" ? 443 : 80)

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = resolvedPort
        components.path = ""
        return components.url
    }

    func testReachability(host: String, port: Int) -> WorkerReachabilityResult {
        guard (1...Int(UInt16.max)).contains(port) else {
            return .hostUnreachable(reason: "Invalid port \(port)")
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

        if status == 0 {
            return .reachable
        }

        let reason = String(cString: gai_strerror(status))
        return .hostUnreachable(reason: "DNS/addr resolution failed for \(host):\(port) (\(status): \(reason))")
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
