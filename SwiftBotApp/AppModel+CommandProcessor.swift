import Foundation

extension AppModel {
    func makeCommandProcessor() -> CommandProcessor {
        CommandProcessor(
            dependencies: .init(
                configuration: { [unowned self] in
                    .init(
                        commandsEnabled: self.settings.commandsEnabled,
                        prefixCommandsEnabled: self.settings.prefixCommandsEnabled,
                        slashCommandsEnabled: self.settings.slashCommandsEnabled,
                        wikiEnabled: self.settings.wikiBot.isEnabled,
                        prefix: self.effectivePrefix(),
                        helpSettings: self.settings.help
                    )
                },
                canonicalPrefixCommandName: { [unowned self] name in
                    self.canonicalPrefixCommandName(name)
                },
                isCommandEnabled: { [unowned self] name, surface in
                    self.isCommandEnabled(name: name, surface: surface)
                },
                buildHelpCatalog: { [unowned self] prefix in
                    self.buildHelpCatalog(prefix: prefix)
                },
                send: { [unowned self] channelId, message in
                    await self.send(channelId, message)
                },
                sendEmbed: { [unowned self] channelId, embed in
                    await self.sendEmbed(channelId, embed: embed)
                },
                generateHelpReply: { [unowned self] messages, systemPrompt in
                    await self.service.generateHelpReply(messages: messages, systemPrompt: systemPrompt)
                },
                rollDice: { [unowned self] notation in
                    self.rollDice(notation)
                },
                generateImageCommand: { [unowned self] prompt, userId, username, channelId in
                    await self.generateImageCommand(
                        prompt: prompt,
                        userId: userId,
                        username: username,
                        channelId: channelId
                    )
                },
                authorId: { [unowned self] raw in
                    self.authorId(from: raw)
                },
                clusterCommand: { [unowned self] action, channelId in
                    await self.clusterCommand(action: action, channelId: channelId)
                },
                setNotificationChannel: { [unowned self] raw, channelId in
                    await self.setNotificationChannel(for: raw, currentChannelId: channelId)
                },
                updateIgnoredChannels: { [unowned self] tokens, raw, channelId in
                    await self.updateIgnoredChannels(tokens: tokens, raw: raw, responseChannelId: channelId)
                },
                notifyStatus: { [unowned self] raw, channelId in
                    await self.notifyStatus(raw: raw, responseChannelId: channelId)
                },
                canRunDebugCommand: { [unowned self] raw in
                    await self.canRunDebugCommand(raw: raw)
                },
                refreshDebugSnapshot: { [unowned self] in
                    await self.pollClusterStatus()
                    self.clusterSnapshot = await self.cluster.currentSnapshot()
                },
                debugSummaryEmbed: { [unowned self] in
                    self.debugSummaryEmbed()
                },
                bugReportText: { [unowned self] raw in
                    self.bugReportText(for: raw)
                },
                weeklySummary: { [unowned self] in
                    self.weeklyPlugin?.snapshotSummary() ?? "No data yet."
                },
                fetchFinalsMeta: { [unowned self] in
                    await self.service.fetchFinalsMetaFromSkycoach()
                },
                resolveWikiCommand: { [unowned self] name in
                    self.resolveWikiCommand(named: name).map { ($0.source, $0.command) }
                },
                defaultWikiCommand: { [unowned self] in
                    for source in self.orderedEnabledWikiSources() {
                        if let first = source.commands.first(where: \.enabled) {
                            return (source: source, command: first)
                        }
                    }
                    return nil
                },
                performWikiLookup: { [unowned self] command, source, query, channelId in
                    await self.performWikiLookup(
                        command: command,
                        source: source,
                        query: query,
                        channelId: channelId
                    )
                },
                handleLogABugSlash: { [unowned self] raw, username, channelId, errorText in
                    await self.handleLogABugSlash(
                        raw: raw,
                        username: username,
                        channelId: channelId,
                        errorText: errorText
                    )
                },
                handleFeatureRequestSlash: { [unowned self] raw, username, channelId, featureText, reasonText in
                    await self.handleFeatureRequestSlash(
                        raw: raw,
                        username: username,
                        channelId: channelId,
                        featureText: featureText,
                        reasonText: reasonText
                    )
                },
                lookupFinalsWiki: { [unowned self] query in
                    await self.service.lookupFinalsWiki(query: query)
                }
            )
        )
    }
}
