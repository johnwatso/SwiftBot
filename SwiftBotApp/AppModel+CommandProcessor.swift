import Foundation

extension AppModel {
    func makeCommandProcessor() -> CommandProcessor {
        CommandProcessor(
            dependencies: .init(
                configuration: { [weak self] in
                    guard let self else {
                        return .init(
                            commandsEnabled: false,
                            prefixCommandsEnabled: false,
                            slashCommandsEnabled: false,
                            wikiEnabled: false,
                            prefix: "/",
                            helpSettings: .init()
                        )
                    }
                    return .init(
                        commandsEnabled: self.settings.commandsEnabled,
                        prefixCommandsEnabled: false,
                        slashCommandsEnabled: self.settings.slashCommandsEnabled,
                        wikiEnabled: self.settings.wikiBot.isEnabled,
                        prefix: "/",
                        helpSettings: self.settings.help
                    )
                },
                canonicalPrefixCommandName: { [weak self] name in
                    self?.canonicalPrefixCommandName(name) ?? name
                },
                isCommandEnabled: { [weak self] name, surface in
                    self?.isCommandEnabled(name: name, surface: surface) ?? false
                },
                buildHelpCatalog: { [weak self] prefix in
                    self?.buildHelpCatalog(prefix: prefix) ?? CommandCatalog(entries: [])
                },
                send: { [weak self] channelId, message in
                    guard let self else { return false }
                    return await self.send(channelId, message)
                },
                sendEmbed: { [weak self] channelId, embed in
                    guard let self else { return false }
                    return await self.sendEmbed(channelId, embed: embed)
                },
                generateHelpReply: { [weak self] messages, systemPrompt in
                    guard let self else { return nil }
                    return await self.aiService.generateHelpReply(messages: messages, systemPrompt: systemPrompt)
                },
                rollDice: { [weak self] notation in
                    self?.rollDice(notation) ?? ""
                },
                generateImageCommand: { [weak self] prompt, userId, username, channelId in
                    guard let self else { return false }
                    return await self.generateImageCommand(
                        prompt: prompt,
                        userId: userId,
                        username: username,
                        channelId: channelId
                    )
                },
                authorId: { [weak self] raw in
                    self?.authorId(from: raw) ?? ""
                },
                clusterCommand: { [weak self] action, channelId in
                    guard let self else { return false }
                    return await self.clusterCommand(action: action, channelId: channelId)
                },
                setNotificationChannel: { [weak self] raw, channelId in
                    guard let self else { return false }
                    return await self.setNotificationChannel(for: raw, currentChannelId: channelId)
                },
                updateIgnoredChannels: { [weak self] tokens, raw, channelId in
                    guard let self else { return false }
                    return await self.updateIgnoredChannels(tokens: tokens, raw: raw, responseChannelId: channelId)
                },
                notifyStatus: { [weak self] raw, channelId in
                    guard let self else { return false }
                    return await self.notifyStatus(raw: raw, responseChannelId: channelId)
                },
                canRunDebugCommand: { [weak self] raw in
                    await self?.canRunDebugCommand(raw: raw) ?? false
                },
                refreshDebugSnapshot: { [weak self] in
                    guard let self else { return }
                    await self.pollClusterStatus()
                    self.clusterSnapshot = await self.cluster.currentSnapshot()
                },
                debugSummaryEmbed: { [weak self] in
                    self?.debugSummaryEmbed() ?? .init()
                },
                bugReportText: { [weak self] raw in
                    self?.bugReportText(for: raw) ?? ""
                },
                weeklySummary: { [weak self] in
                    self?.weeklyPlugin?.snapshotSummary() ?? "No data yet."
                },
                fetchFinalsMeta: { [weak self] in
                    guard let self else { return nil }
                    return await self.wikiLookupService.fetchFinalsMetaFromSkycoach()
                },
                resolveWikiCommand: { [weak self] name in
                    self?.resolveWikiCommand(named: name).map { ($0.source, $0.command) }
                },
                defaultWikiCommand: { [weak self] in
                    guard let self else { return nil }
                    for source in self.orderedEnabledWikiSources() {
                        if let first = source.commands.first(where: \.enabled) {
                            return (source: source, command: first)
                        }
                    }
                    return nil
                },
                performWikiLookup: { [weak self] command, source, query, channelId in
                    guard let self else { return false }
                    return await self.performWikiLookup(
                        command: command,
                        source: source,
                        query: query,
                        channelId: channelId
                    )
                },
                handleLogABugSlash: { [weak self] raw, username, channelId, errorText in
                    guard let self else { return (ok: false, message: "Bug report failed: app unavailable.") }
                    return await self.handleLogABugSlash(
                        raw: raw,
                        username: username,
                        channelId: channelId,
                        errorText: errorText
                    )
                },
                handleFeatureRequestSlash: { [weak self] raw, username, channelId, featureText, reasonText in
                    guard let self else { return (ok: false, message: "Feature request failed: app unavailable.") }
                    return await self.handleFeatureRequestSlash(
                        raw: raw,
                        username: username,
                        channelId: channelId,
                        featureText: featureText,
                        reasonText: reasonText
                    )
                },
                lookupFinalsWiki: { [weak self] query in
                    guard let self else { return nil }
                    return await self.wikiLookupService.lookupFinalsWiki(query: query)
                },
                runMusicLookup: { [weak self] query, title, artist, userID, channelID in
                    guard let self else {
                        return (ok: false, message: "Music lookup is unavailable right now.")
                    }
                    return await self.runMusicLookup(
                        query: query,
                        title: title,
                        artist: artist,
                        userID: userID,
                        channelID: channelID
                    )
                },
                pickMusicLookup: { [weak self] selection, userID, channelID in
                    guard let self else {
                        return (ok: false, message: "Music lookup is unavailable right now.")
                    }
                    return await self.pickMusicLookup(
                        selectionIndex: selection,
                        userID: userID,
                        channelID: channelID
                    )
                },
                swiftMinerCommand: { [weak self] action, userID, channelID in
                    guard let self else {
                        return (ok: false, message: "SwiftMiner integration is unavailable right now.")
                    }
                    return await self.swiftMinerCommand(action: action, userId: userID, channelId: channelID)
                },
                fetchSteamAppInfo: { [weak self] query in
                    guard let self else { return (ok: false, embed: nil) }
                    return await self.fetchSteamAppInfo(query: query)
                },
                sweepCommand: { [weak self] action in
                    guard let self else { return (ok: false, message: "Sweep is unavailable.") }
                    return await self.handleSweepSlash(action: action)
                },
                lookupUserTimeZone: { [weak self] userID in
                    guard let self else { return nil }
                    let value = self.settings.userTimezones[userID]?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return (value?.isEmpty == false) ? value : nil
                }
            )
        )
    }

    func handleSweepSlash(action: String) async -> (ok: Bool, message: String) {
        let sweep = self.sweepService
        let normalised = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalised {
        case "pause":
            sweep.globalPaused = true
            return (true, "Sweep paused. Scheduled runs will not fire until resumed.")
        case "resume":
            sweep.globalPaused = false
            return (true, "Sweep resumed.")
        case "preview":
            guard let first = sweep.policies.first(where: { $0.isEnabled }) else {
                return (false, "No enabled Sweep rules to preview.")
            }
            if let report = await sweep.preview(policyID: first.id) {
                let matched = report.matched
                let summary = report.summary.map { "\n\n\($0)" } ?? ""
                return (true, "Preview · \(first.name): \(report.scanned) scanned, \(matched) would be tidied.\(summary)")
            }
            return (false, "Preview failed for \(first.name).")
        case "run", "":
            let enabled = sweep.policies.filter(\.isEnabled)
            guard !enabled.isEmpty else { return (false, "No enabled Sweep rules.") }
            var total = 0
            for policy in enabled {
                if let report = await sweep.run(policyID: policy.id, manual: true) {
                    total += report.executed
                }
            }
            return (true, "Ran \(enabled.count) rule(s) · \(total) message(s) tidied.")
        case "status":
            let enabled = sweep.enabledPolicyCount
            let total = sweep.policies.count
            let paused = sweep.globalPaused ? " (paused)" : ""
            return (true, "Sweep · \(enabled)/\(total) rules enabled · next \(sweep.nextRunDescription)\(paused)")
        default:
            return (false, "Unknown action ‘\(action)’. Try run · preview · pause · resume · status.")
        }
    }
}
