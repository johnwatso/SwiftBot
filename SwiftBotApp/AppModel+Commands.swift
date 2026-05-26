import Foundation

extension AppModel {


    func commandKey(name: String, surface: String) -> String {
        "\(surface.lowercased()):\(name.lowercased())"
    }

    func canonicalPrefixCommandName(_ name: String) -> String {
        switch name.lowercased() {
        case "imagine":
            return "image"
        case "worker":
            return "cluster"
        case "ts":
            return "timestamp"
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

    func runMusicLookup(
        query: String?,
        title: String?,
        artist: String?,
        userID: String,
        channelID: String
    ) async -> (ok: Bool, message: String) {
        pruneExpiredMusicSelections()

        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let effectiveQuery: String = {
            if !trimmedQuery.isEmpty {
                return trimmedQuery
            }
            return [trimmedTitle, trimmedArtist]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }()

        guard !effectiveQuery.isEmpty else {
            return (false, "🎵 Usage: `/music query:<query>` or `/music title:<title> artist:<artist>`.")
        }

        let results = await musicLookupService.searchTracks(query: effectiveQuery, limit: 5)
        guard !results.isEmpty else {
            return (
                false,
                "🎵 No matches found for `\(effectiveQuery)`. Try a different query or provide both title and artist."
            )
        }

        pendingMusicSelectionsByUserID[userID] = PendingMusicSelection(
            query: effectiveQuery,
            channelID: channelID,
            createdAt: Date(),
            results: results
        )

        var lines: [String] = ["🎵 Matches for `\(effectiveQuery)`:"]
        for (index, item) in results.enumerated() {
            let albumPart = item.album.map { " · \($0)" } ?? ""
            lines.append("\(index + 1). \(item.title) — \(item.artist)\(albumPart)")
        }
        lines.append("")
        lines.append("Pick one with `/music pick:<number>`.")

        return (true, lines.joined(separator: "\n"))
    }

    func pickMusicLookup(
        selectionIndex: Int,
        userID: String,
        channelID: String
    ) async -> (ok: Bool, message: String) {
        pruneExpiredMusicSelections()

        guard selectionIndex > 0 else {
            return (false, "🎵 Pick must be a positive number. Example: `/music pick:2`.")
        }
        guard let selection = pendingMusicSelectionsByUserID[userID] else {
            return (false, "🎵 No active music search. Run `/music query:<query>` first.")
        }
        guard selection.channelID == channelID else {
            return (
                false,
                "🎵 Please pick in the same channel as the search, or run a fresh `/music` query here."
            )
        }

        let index = selectionIndex - 1
        guard selection.results.indices.contains(index) else {
            return (false, "🎵 Pick out of range. Choose 1...\(selection.results.count).")
        }

        let match = selection.results[index]
        let combinedSearch = "\(match.title) \(match.artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        let appleLink = match.appleMusicURL?.absoluteString ?? buildITunesSearchURL(query: combinedSearch)
        let spotifyLink = buildSpotifySearchURL(query: combinedSearch)
        let youtubeMusicLink = buildYouTubeMusicSearchURL(query: combinedSearch)
        let youtubeLink = buildYouTubeSearchURL(query: combinedSearch)

        let message = """
        🎧 \(match.title) — \(match.artist)
        Apple Music: <\(appleLink)>
        Spotify: <\(spotifyLink)>
        YouTube Music: <\(youtubeMusicLink)>
        YouTube: <\(youtubeLink)>
        """
        return (true, message)
    }

    func pruneExpiredMusicSelections(now: Date = Date()) {
        pendingMusicSelectionsByUserID = pendingMusicSelectionsByUserID.filter { _, selection in
            now.timeIntervalSince(selection.createdAt) < 15 * 60
        }
        musicInteractionSessionsByID = musicInteractionSessionsByID.filter { _, session in
            now.timeIntervalSince(session.createdAt) < 15 * 60
        }
    }

    func buildSpotifySearchURL(query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        return "https://open.spotify.com/search/\(encoded)"
    }

    func buildYouTubeMusicSearchURL(query: String) -> String {
        var components = URLComponents(string: "https://music.youtube.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url?.absoluteString ?? "https://music.youtube.com/"
    }

    func buildYouTubeSearchURL(query: String) -> String {
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return components?.url?.absoluteString ?? "https://www.youtube.com/"
    }

    func buildITunesSearchURL(query: String) -> String {
        var components = URLComponents(string: "https://music.apple.com/us/search")
        components?.queryItems = [URLQueryItem(name: "term", value: query)]
        return components?.url?.absoluteString ?? "https://music.apple.com/"
    }

    func generateImageCommand(
        prompt: String,
        userId: String,
        username: String,
        channelId: String
    ) async -> Bool {
        let cleanedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPrompt.isEmpty else {
            return await send(channelId, "🎨 Usage: `/image prompt:<prompt>`")
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

    /// Builds the full CommandCatalog including all enabled Lookup commands.
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
            return await send(responseChannelId, "Usage: `/ignorechannel action:list` or `/ignorechannel action:add channel:<channel>`.")
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
            "Lookup: \(wikiEnabled)",
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
                "value": "AI: `\(aiProvider)`\nLookup: `\(wikiEnabled)`\nPatchy: `\(patchyEnabled)`\nRules: `\(activeRules)/\(ruleStore.rules.count)`",
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

        let authorUsername: String? = {
            if case let .object(author)? = map["author"],
               case let .string(username)? = author["username"],
               !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return username
            }
            return nil
        }()

        let preferredName: String? = {
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
                    return nil
                }
            }
            return fallbackUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : fallbackUsername
        }()

        await discordCache.upsertUser(id: userID, preferredName: preferredName, username: authorUsername)

        // Flag bots and webhooks so the admin user picker can exclude non-human authors.
        var isNonHuman = false
        if map["webhook_id"] != nil {
            isNonHuman = true
        }
        if case let .object(author)? = map["author"], author["bot"] == .bool(true) {
            isNonHuman = true
        }
        if isNonHuman {
            await discordCache.markBot(id: userID)
        } else if guildID != nil {
            // Author is a real user posting in a guild we're connected to → trusted member.
            await discordCache.markGuildMember(id: userID)
        }

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
        await discordCache.markBot(id: assistantID)
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
        let usageTrigger = trigger.isEmpty ? command.trigger : "/\(trigger)"
        guard !trimmedQuery.isEmpty else {
            return await send(
                channelId,
                "📘 Usage: \(usageTrigger) <query> (optional source selector: <wiki-command> <source>::<query>)"
            )
        }

        guard let resolved = resolveWikiSourceAndQuery(defaultSource: source, query: trimmedQuery) else {
            return await send(channelId, "⚠️ No Lookup sources are enabled. Add or enable a source in Lookup settings.")
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

        let embedSent = await sendWikiEmbed(channelId: channelId, source: resolvedSource, result: result)
        if embedSent {
            return true
        }

        let body = formattedWikiResponse(source: resolvedSource, result: result)
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
        let fieldLines = result.fields
            .filter { wikiShouldShowEmbedField($0.name, source: source) }
            .prefix(8)
            .map { "**\($0.name):** \($0.value)" }
        if !fieldLines.isEmpty {
            let summaryBlock = summary.isEmpty ? "" : "\(summary)\n"
            return "📘 **\(result.title)**\nSource: \(source.name)\n\(summaryBlock)\(fieldLines.joined(separator: "\n"))\n\(result.url)"
        }
        if summary.isEmpty {
            return "📘 **\(result.title)**\nSource: \(source.name)\n\(result.url)"
        }
        if formatting.compactMode {
            return "📘 **\(result.title)** • \(source.name)\n\(summary)\n\(result.url)"
        }
        return "📘 **\(result.title)**\nSource: \(source.name)\n\(summary)\n\(result.url)"
    }

    func sendWikiEmbed(channelId: String, source: WikiSource, result: FinalsWikiLookupResult) async -> Bool {
        let embed = wikiEmbed(source: source, result: result)
        let payload: [String: Any] = [
            "embeds": [embed]
        ]
        return await sendPayload(channelId: channelId, payload: payload, action: "sendMessage(embed)")
    }

    func wikiEmbed(source: WikiSource, result: FinalsWikiLookupResult) -> [String: Any] {
        if source.formatting.includeStatBlocks, let stats = result.weaponStats {
            return weaponStatsEmbed(source: source, result: result, stats: stats)
        }

        let summary = summarizedWikiExtract(
            result.extract,
            limit: source.formatting.compactMode ? 220 : 420
        )

        var embed: [String: Any] = [
            "title": result.title,
            "url": result.url,
            "footer": ["text": wikiEmbedFooterText(source: source)]
        ]
        if !summary.isEmpty {
            embed["description"] = summary
        }
        if let imageURL = result.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !imageURL.isEmpty {
            embed["thumbnail"] = ["url": imageURL]
        }

        var fields = result.fields.prefix(18).compactMap { field -> [String: Any]? in
            guard wikiShouldShowEmbedField(field.name, source: source) else { return nil }
            return [
                "name": field.name,
                "value": field.value,
                "inline": field.inline
            ]
        }
        if source.formatting.includeStatBlocks, let stats = result.weaponStats {
            func appendField(_ name: String, _ value: String?) {
                guard let value, !value.isEmpty else { return }
                guard wikiShouldShowEmbedField(name, source: source) else { return }
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
        }
        if !fields.isEmpty {
            embed["fields"] = Array(fields.prefix(25))
        }

        return embed
    }

    func sendWeaponStatsEmbed(
        channelId: String,
        source: WikiSource,
        result: FinalsWikiLookupResult,
        stats: FinalsWeaponStats
    ) async -> Bool {
        let embed = weaponStatsEmbed(source: source, result: result, stats: stats)
        let payload: [String: Any] = [
            "embeds": [embed]
        ]
        return await sendPayload(channelId: channelId, payload: payload, action: "sendMessage(weapon-stats)")
    }

    func weaponStatsEmbed(
        source: WikiSource,
        result: FinalsWikiLookupResult,
        stats: FinalsWeaponStats
    ) -> [String: Any] {
        var embed: [String: Any] = [
            "title": wikiWeaponTitle(result: result, stats: stats),
            "url": result.url,
            "color": 0x1B2838,
            "footer": ["text": wikiEmbedFooterText(source: source)]
        ]

        if let imageURL = result.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !imageURL.isEmpty {
            embed["thumbnail"] = ["url": imageURL]
        }

        var fields: [[String: Any]] = []

        func appendInline(_ name: String, _ value: String?) {
            guard let value = wikiDisplayValue(value) else { return }
            guard wikiShouldShowEmbedField(name, source: source) else { return }
            fields.append([
                "name": name,
                "value": value,
                "inline": true
            ])
        }

        appendInline("Damage", stats.bodyDamage)
        appendInline("Headshot", stats.headshotDamage)
        appendInline("Firerate", stats.fireRate)
        appendInline("Dropoff Start", stats.dropoffStart)
        appendInline("Dropoff End", stats.dropoffEnd)
        appendInline("Minimum Damage", stats.minimumDamage)
        appendInline("Magazine Size", stats.magazineSize)
        appendInline("Short Reload", stats.shortReload)
        appendInline("Long Reload", stats.longReload)

        fields.append([
            "name": "Notes",
            "value": wikiDisplayValue(stats.notes) ?? wikiFieldValue(result.fields, labels: ["Notes", "Note"]) ?? "-",
            "inline": false
        ])

        if !fields.isEmpty {
            embed["fields"] = Array(fields.prefix(25))
        }

        return embed
    }

    func wikiShouldShowEmbedField(_ name: String, source: WikiSource) -> Bool {
        let normalized = normalizedWikiEmbedFieldName(name)
        guard !normalized.isEmpty else { return false }
        return !source.formatting.hiddenEmbedFields.contains(normalized)
    }

    func normalizedWikiEmbedFieldName(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }

    private func wikiEmbedFooterText(source: WikiSource) -> String {
        let scope = source.searchScope.trimmingCharacters(in: .whitespacesAndNewlines)
        return scope.isEmpty ? source.name : "\(source.name) • \(scope)"
    }

    func formattedWeaponStats(
        result: FinalsWikiLookupResult,
        sourceName: String,
        stats: FinalsWeaponStats,
        compact: Bool
    ) -> String {
        var lines: [String] = []
        let title = wikiWeaponTitle(result: result, stats: stats)

        if let type = stats.type, !type.isEmpty {
            lines.append("📘 **\(title)** • \(type)")
        } else {
            lines.append("📘 **\(title)**")
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
            lines.append(compact ? "Firerate \(fireRate)" : "Firerate: \(fireRate)")
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
            lines.append(compact ? "Mag \(magazineSize)" : "Magazine Size: \(magazineSize)")
        }

        let reloadLine = [
            stats.shortReload.map { "Short \($0)" },
            stats.longReload.map { "Long \($0)" }
        ].compactMap { $0 }.joined(separator: " • ")
        if !reloadLine.isEmpty {
            lines.append(compact ? "Reload \(reloadLine)" : "Reload: \(reloadLine)")
        }

        if let notes = wikiDisplayValue(stats.notes), notes != "-" {
            lines.append("Notes: \(notes)")
        }

        lines.append(result.url)
        return lines.joined(separator: "\n")
    }

    func wikiWeaponTitle(result: FinalsWikiLookupResult, stats: FinalsWeaponStats) -> String {
        let version = wikiDisplayValue(stats.version)
            ?? wikiFieldValue(result.fields, labels: ["Version", "Patch", "Game Version", "Updated"])
        guard let version, !result.title.contains(version) else {
            return result.title
        }
        return "\(result.title) - \(version)"
    }

    func wikiFieldValue(_ fields: [WikiResultField], labels: [String]) -> String? {
        let normalizedLabels = Set(labels.map(normalizedWikiSourceKey))
        return fields.first { field in
            normalizedLabels.contains(normalizedWikiSourceKey(field.name))
        }.flatMap { wikiDisplayValue($0.value) }
    }

    func wikiDisplayValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
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
        request.timeoutInterval = 12
        await applyMeshAuthToConnectionTestRequest(&request, path: "/cluster/ping")

        // Hard total-time cap: URLSession.shared's per-request timeoutInterval
        // doesn't strictly bound DNS resolve + TCP connect, so a misrouted
        // host (e.g. VPN sending traffic to a black hole) can take 60+ seconds
        // to give up. Race the request against an explicit sleep so the UI
        // never blocks longer than `Self.connectionTestTimeoutSeconds`.
        do {
            let startedAt = Date()
            let (data, response) = try await Self.runWithTimeout(
                seconds: Self.connectionTestTimeoutSeconds
            ) {
                try await URLSession.shared.data(for: request)
            }
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
        } catch is ConnectionTestTimeoutError {
            return WorkerConnectionTestOutcome(
                message: "Connection test timed out after \(Int(Self.connectionTestTimeoutSeconds))s to \(pingURL.absoluteString). The host may be unreachable (e.g. VPN routing it to a black hole) or the Primary is not responding.",
                isSuccess: false
            )
        } catch {
            return WorkerConnectionTestOutcome(message: "Unexpected error for \(pingURL.absoluteString): \(error.localizedDescription)", isSuccess: false)
        }
    }

    /// Hard upper bound on the entire connection test (DNS resolve + TCP
    /// connect + TLS + HTTP). Keeps the onboarding "Testing connection…"
    /// indicator from hanging when a misrouted host (e.g. VPN sinkhole)
    /// silently swallows packets.
    private static let connectionTestTimeoutSeconds: TimeInterval = 12

    private struct ConnectionTestTimeoutError: Error {}

    /// Races `work` against an explicit sleep. If `work` finishes first, its
    /// value is returned. If the sleep wins, throws `ConnectionTestTimeoutError`
    /// and cancels the in-flight task.
    private static func runWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        @_inheritActorContext _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await work()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ConnectionTestTimeoutError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ConnectionTestTimeoutError()
            }
            return first
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

    func fetchSteamAppInfo(query: String) async -> (ok: Bool, embed: [String: Any]?) {
        let service = SteamService()
        do {
            let info = try await service.fetchAppInfo(query: query)
            
            var description = info.shortDescription
            if let playerCount = info.playerCount {
                let formattedCount = formatPlayerCount(playerCount)
                description = "👥 **\(formattedCount) players online**\n\n" + description
            }
            
            var fields: [[String: Any]] = []
            if let price = info.price {
                fields.append([
                    "name": "Price",
                    "value": price,
                    "inline": true
                ])
            }
            
            fields.append([
                "name": "Links",
                "value": "[Store Page](\(info.storeURL)) · [SteamDB](https://steamdb.info/app/\(info.appID)/)",
                "inline": true
            ])

            let embed: [String: Any] = [
                "title": info.name,
                "description": description,
                "url": info.storeURL,
                "color": 0x1B2838,
                "image": ["url": info.headerImageURL],
                "fields": fields,
                "footer": ["text": "Data from Steam Web API"]
            ]
            
            return (true, embed)
        } catch {
            return (false, nil)
        }
    }

    private func formatPlayerCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        } else {
            return "\(count)"
        }
    }

}
