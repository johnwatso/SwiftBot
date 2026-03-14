import Foundation
import SwiftUI
import AppKit

extension AppModel {

    // MARK: - Admin Web Server

    func normalizedAdminRedirectPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/auth/discord/callback" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    func adminWebStatusSnapshot() -> AdminWebStatusPayload {
        AdminWebStatusPayload(
            botStatus: status.rawValue,
            botUsername: botUsername,
            connectedServerCount: connectedServers.count,
            gatewayEventCount: gatewayEventCount,
            uptimeText: uptime?.text,
            webUIEnabled: settings.adminWebUI.enabled,
            webUIBaseURL: adminWebBaseURL()
        )
    }

    /// Creates a complete snapshot of current configuration for change detection in the UI.
    func createPreferencesSnapshot() -> AppPreferencesSnapshot {
        AppPreferencesSnapshot(
            token: settings.token,
            prefix: settings.prefix,
            autoStart: settings.autoStart,
            clusterMode: settings.clusterMode,
            clusterNodeName: settings.clusterNodeName,
            clusterLeaderAddress: settings.clusterLeaderAddress,
            clusterLeaderPort: settings.clusterLeaderPort,
            clusterListenPort: settings.clusterListenPort,
            clusterSharedSecret: settings.clusterSharedSecret,
            clusterWorkerOffloadEnabled: settings.clusterWorkerOffloadEnabled,
            clusterOffloadAIReplies: settings.clusterOffloadAIReplies,
            clusterOffloadWikiLookups: settings.clusterOffloadWikiLookups,
            mediaSourcesJSON: mediaSourcesSnapshotJSON(),
            adminWebEnabled: settings.adminWebUI.enabled,
            adminWebHost: settings.adminWebUI.bindHost,
            adminWebPort: settings.adminWebUI.port,
            adminWebBaseURL: settings.adminWebUI.publicBaseURL,
            adminWebHTTPSEnabled: settings.adminWebUI.httpsEnabled,
            adminWebCertificateMode: settings.adminWebUI.certificateMode,
            adminWebHostname: settings.adminWebUI.hostname,
            adminWebCloudflareToken: settings.adminWebUI.cloudflareAPIToken,
            adminWebPublicAccessEnabled: settings.adminWebUI.publicAccessEnabled,
            adminWebImportedCertificateFile: settings.adminWebUI.importedCertificateFile,
            adminWebImportedPrivateKeyFile: settings.adminWebUI.importedPrivateKeyFile,
            adminWebImportedCertificateChainFile: settings.adminWebUI.importedCertificateChainFile,
            adminLocalAuthEnabled: settings.adminWebUI.localAuthEnabled,
            adminLocalAuthUsername: settings.adminWebUI.localAuthUsername,
            adminLocalAuthPassword: settings.adminWebUI.localAuthPassword,
            adminRestrictSpecificUsers: settings.adminWebUI.restrictAccessToSpecificUsers,
            adminDiscordClientID: settings.adminWebUI.discordClientID,
            adminDiscordClientSecret: settings.adminWebUI.discordClientSecret,
            adminAllowedUserIDs: settings.adminWebUI.allowedUserIDs.joined(separator: ", "),
            adminRedirectPath: settings.adminWebUI.redirectPath,
            localAIDMReplyEnabled: settings.localAIDMReplyEnabled,
            useAIInGuildChannels: settings.behavior.useAIInGuildChannels,
            allowDMs: settings.behavior.allowDMs,
            preferredAIProvider: settings.preferredAIProvider,
            ollamaBaseURL: settings.ollamaBaseURL,
            ollamaModel: settings.localAIModel,
            ollamaEnabled: settings.ollamaEnabled,
            openAIEnabled: settings.openAIEnabled,
            openAIAPIKey: settings.openAIAPIKey,
            openAIModel: settings.openAIModel,
            openAIImageGenerationEnabled: settings.openAIImageGenerationEnabled,
            openAIImageModel: settings.openAIImageModel,
            openAIImageMonthlyLimitPerUser: settings.openAIImageMonthlyLimitPerUser,
            localAISystemPrompt: settings.localAISystemPrompt,
            devFeaturesEnabled: settings.devFeaturesEnabled,
            bugAutoFixEnabled: settings.bugAutoFixEnabled,
            bugAutoFixTriggerEmoji: settings.bugAutoFixTriggerEmoji,
            bugAutoFixCommandTemplate: settings.bugAutoFixCommandTemplate,
            bugAutoFixRepoPath: settings.bugAutoFixRepoPath,
            bugAutoFixGitBranch: settings.bugAutoFixGitBranch,
            bugAutoFixVersionBumpEnabled: settings.bugAutoFixVersionBumpEnabled,
            bugAutoFixPushEnabled: settings.bugAutoFixPushEnabled,
            bugAutoFixRequireApproval: settings.bugAutoFixRequireApproval,
            bugAutoFixApproveEmoji: settings.bugAutoFixApproveEmoji,
            bugAutoFixRejectEmoji: settings.bugAutoFixRejectEmoji,
            bugAutoFixAllowedUsernames: settings.bugAutoFixAllowedUsernames.joined(separator: ", ")
        )
    }

    private func mediaSourcesSnapshotJSON() -> String {
        guard let data = try? JSONEncoder().encode(mediaLibrarySettings.sources),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    func adminWebOverviewSnapshot() -> AdminWebOverviewPayload {
        let enabledWikiSourceCount = settings.wikiBot.sources.filter(\.enabled).count
        let patchyTargetCount = settings.patchy.sourceTargets.count
        let patchyEnabledTargetCount = settings.patchy.sourceTargets.filter(\.isEnabled).count
        let actionRuleCount = ruleStore.rules.count
        let enabledActionRuleCount = ruleStore.rules.filter(\.isEnabled).count
        let aiProviderSummary = settings.preferredAIProvider.rawValue
        let clusterLeader = clusterNodes.first(where: { $0.role == .leader })?.hostname
            ?? clusterNodes.first?.hostname
            ?? "Unavailable"
        let connectedNodes = clusterNodes.filter { $0.status != .disconnected }.count

        let metrics: [AdminWebMetricPayload] = [
            AdminWebMetricPayload(
                title: "Bot Status",
                value: status.rawValue.capitalized,
                subtitle: uptime?.text ?? "--"
            ),
            AdminWebMetricPayload(
                title: "Servers Connected",
                value: "\(connectedServers.count)",
                subtitle: settings.clusterMode == .standalone ? "Standalone" : settings.clusterMode.displayName
            ),
            AdminWebMetricPayload(
                title: "Users In Voice",
                value: "\(activeVoice.count)",
                subtitle: "users right now"
            ),
            AdminWebMetricPayload(
                title: "Commands Run",
                value: "\(stats.commandsRun)",
                subtitle: "this session"
            ),
            AdminWebMetricPayload(
                title: "New Recordings",
                value: "\(recentMediaCount24h)",
                subtitle: "last 24 hours"
            ),
            AdminWebMetricPayload(
                title: "WikiBridge Status",
                value: settings.wikiBot.isEnabled ? "Enabled" : "Disabled",
                subtitle: "\(enabledWikiSourceCount) sources"
            ),
            AdminWebMetricPayload(
                title: "Patchy Monitoring",
                value: settings.patchy.monitoringEnabled ? "Monitoring On" : "Monitoring Off",
                subtitle: "\(patchyEnabledTargetCount)/\(patchyTargetCount) targets"
            ),
            AdminWebMetricPayload(
                title: "Active Actions",
                value: "\(enabledActionRuleCount)",
                subtitle: "\(actionRuleCount) total rules"
            ),
            AdminWebMetricPayload(
                title: "AI Bots",
                value: aiProviderSummary,
                subtitle: settings.localAIDMReplyEnabled ? "DM replies enabled" : "DM replies disabled"
            )
        ]

        let recentVoice = Array(voiceLog.prefix(5)).map {
            AdminWebRecentVoicePayload(
                description: $0.description,
                timeText: $0.time.formatted(date: .omitted, time: .standard)
            )
        }

        let recentCommands = Array(commandLog.prefix(5)).map {
            AdminWebRecentCommandPayload(
                title: "\($0.user) @ \($0.server) • \($0.command)",
                timeText: $0.time.formatted(date: .omitted, time: .standard),
                ok: $0.ok
            )
        }

        let activeVoiceUsers = activeVoice
            .sorted { lhs, rhs in
                if lhs.guildId != rhs.guildId { return lhs.guildId < rhs.guildId }
                if lhs.channelName != rhs.channelName { return lhs.channelName.localizedCaseInsensitiveCompare(rhs.channelName) == .orderedAscending }
                return lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
            }
            .map { member in
                AdminWebActiveVoicePayload(
                    userId: member.userId,
                    username: member.username,
                    channelName: member.channelName,
                    serverName: connectedServers[member.guildId] ?? member.guildId,
                    joinedText: "Joined \(member.joinedAt.formatted(date: .omitted, time: .shortened))"
                )
            }

        let webClusterNodes = clusterNodes.map { node in
            AdminWebClusterNodePayload(
                id: node.id,
                displayName: node.displayName,
                role: node.role.rawValue,
                status: node.status.rawValue,
                hostname: node.hostname,
                hardwareModel: node.hardwareModel,
                jobsActive: node.jobsActive,
                latencyMs: node.latencyMs
            )
        }

        return AdminWebOverviewPayload(
            metrics: metrics,
            cluster: AdminWebClusterPayload(
                connectedNodes: connectedNodes,
                leader: clusterLeader,
                mode: clusterSnapshot.mode.rawValue
            ),
            clusterNodes: webClusterNodes,
            activeVoice: activeVoiceUsers,
            recentVoice: recentVoice,
            recentCommands: recentCommands,
            botInfo: AdminWebBotInfoPayload(
                uptime: uptime?.text ?? "--",
                errors: stats.errors,
                state: status.rawValue.capitalized,
                cluster: settings.clusterMode != .standalone ? clusterSnapshot.mode.rawValue : nil
            )
        )
    }

    func remoteStatusSnapshot() -> RemoteStatusPayload {
        let leaderName = clusterNodes.first(where: { $0.role == .leader })?.displayName
            ?? clusterNodes.first?.displayName
            ?? (settings.clusterMode == .standalone ? "Standalone" : "Unavailable")

        return RemoteStatusPayload(
            botStatus: status.rawValue,
            botUsername: botUsername,
            connectedServerCount: connectedServers.count,
            gatewayEventCount: gatewayEventCount,
            uptimeText: uptime?.text,
            webUIBaseURL: adminWebBaseURL(),
            clusterMode: settings.clusterMode.rawValue,
            nodeRole: clusterSnapshot.mode.rawValue,
            leaderName: leaderName,
            generatedAt: Date()
        )
    }

    func remoteRulesSnapshot() -> RemoteRulesPayload {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let servers = serverIDs.map { AdminWebSimpleOption(id: $0, name: connectedServers[$0] ?? $0) }
        let textChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableTextChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })
        let voiceChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableVoiceChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })

        return RemoteRulesPayload(
            rules: ruleStore.rules,
            servers: servers,
            textChannelsByServer: textChannelsByServer,
            voiceChannelsByServer: voiceChannelsByServer,
            fetchedAt: Date()
        )
    }

    func remoteEventsSnapshot() -> RemoteEventsPayload {
        let recentActivity = Array(events.suffix(40).reversed()).map { event in
            RemoteActivityEventPayload(
                id: event.id,
                timestamp: event.timestamp,
                kind: event.kind.rawValue,
                message: event.message
            )
        }

        return RemoteEventsPayload(
            activity: recentActivity,
            logs: Array(logs.lines.suffix(120).reversed()),
            fetchedAt: Date()
        )
    }

    func adminWebBaseURL() -> String {
        if adminWebPublicAccessStatus.isEnabled, !adminWebPublicAccessStatus.publicURL.isEmpty {
            return adminWebPublicAccessStatus.publicURL
        }
        if !adminWebResolvedBaseURL.isEmpty {
            return adminWebResolvedBaseURL
        }
        return desiredAdminWebBaseURL(preferHTTPS: settings.adminWebUI.httpsEnabled)
    }

    private func desiredAdminWebBaseURL(preferHTTPS: Bool) -> String {
        let explicit = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return explicit
        }

        let automaticHTTPSHost = settings.adminWebUI.normalizedHostname
        let importedHTTPS = settings.adminWebUI.certificateMode == .importCertificate
        let usesHTTPS = preferHTTPS && (importedHTTPS || !automaticHTTPSHost.isEmpty)
        let host = usesHTTPS && !automaticHTTPSHost.isEmpty ? automaticHTTPSHost : settings.adminWebUI.bindHost
        let scheme = usesHTTPS ? "https" : "http"
        let isDefaultPort = (usesHTTPS && settings.adminWebUI.port == 443) || (!usesHTTPS && settings.adminWebUI.port == 80)
        if isDefaultPort {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(settings.adminWebUI.port)"
    }

    func adminWebLaunchURL() -> URL? {
        if adminWebPublicAccessStatus.isEnabled,
           let publicURL = URL(string: adminWebPublicAccessStatus.publicURL) {
            return publicURL
        }

        let explicit = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return URL(string: explicit)
        }

        return URL(string: desiredAdminWebBaseURL(preferHTTPS: settings.adminWebUI.httpsEnabled))
    }

    @discardableResult
    func launchAdminWebUI() -> Bool {
        guard let url = adminWebLaunchURL() else {
            logs.append("⚠️ Admin Web UI URL is invalid.")
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    func adminWebConfigSnapshot() -> AdminWebConfigPayload {
        AdminWebConfigPayload(
            commands: .init(
                enabled: settings.commandsEnabled,
                prefixEnabled: settings.prefixCommandsEnabled,
                slashEnabled: settings.slashCommandsEnabled,
                bugTrackingEnabled: settings.bugTrackingEnabled,
                prefix: settings.prefix
            ),
            aiBots: .init(
                localAIDMReplyEnabled: settings.localAIDMReplyEnabled,
                preferredProvider: settings.preferredAIProvider.rawValue,
                openAIEnabled: settings.openAIEnabled,
                openAIModel: settings.openAIModel,
                openAIImageGenerationEnabled: settings.openAIImageGenerationEnabled,
                openAIImageMonthlyLimitPerUser: settings.openAIImageMonthlyLimitPerUser
            ),
            wikiBridge: .init(
                enabled: settings.wikiBot.isEnabled,
                enabledSources: settings.wikiBot.sources.filter(\.enabled).count,
                totalSources: settings.wikiBot.sources.count
            ),
            patchy: .init(
                monitoringEnabled: settings.patchy.monitoringEnabled,
                enabledTargets: settings.patchy.sourceTargets.filter(\.isEnabled).count,
                totalTargets: settings.patchy.sourceTargets.count
            ),
            swiftMesh: .init(
                mode: settings.clusterMode.rawValue,
                nodeName: settings.clusterNodeName,
                leaderAddress: settings.clusterLeaderAddress,
                listenPort: settings.clusterListenPort,
                offloadAIReplies: settings.clusterOffloadAIReplies,
                offloadWikiLookups: settings.clusterOffloadWikiLookups
            ),
            general: .init(
                autoStart: settings.autoStart,
                webUIEnabled: settings.adminWebUI.enabled,
                webUIBaseURL: adminWebBaseURL()
            )
        )
    }

    func applyAdminWebConfigPatch(_ patch: AdminWebConfigPatch) -> Bool {
        if let value = patch.commandsEnabled { settings.commandsEnabled = value }
        if let value = patch.prefixCommandsEnabled { settings.prefixCommandsEnabled = value }
        if let value = patch.slashCommandsEnabled { settings.slashCommandsEnabled = value }
        if let value = patch.bugTrackingEnabled { settings.bugTrackingEnabled = value }
        if let value = patch.prefix { settings.prefix = value }
        if let value = patch.localAIDMReplyEnabled { settings.localAIDMReplyEnabled = value }
        if let value = patch.preferredAIProvider,
           let provider = AIProviderPreference(rawValue: value) {
            settings.preferredAIProvider = provider
        }
        if let value = patch.openAIEnabled { settings.openAIEnabled = value }
        if let value = patch.openAIModel { settings.openAIModel = value }
        if let value = patch.openAIImageGenerationEnabled { settings.openAIImageGenerationEnabled = value }
        if let value = patch.openAIImageMonthlyLimitPerUser { settings.openAIImageMonthlyLimitPerUser = max(0, value) }
        if let value = patch.wikiBridgeEnabled { settings.wikiBot.isEnabled = value }
        if let value = patch.patchyMonitoringEnabled { settings.patchy.monitoringEnabled = value }
        if let value = patch.clusterMode,
           let mode = ClusterMode(rawValue: value) {
            settings.clusterMode = mode
        }
        if let value = patch.clusterNodeName { settings.clusterNodeName = value }
        if let value = patch.clusterLeaderAddress { settings.clusterLeaderAddress = value }
        if let value = patch.clusterListenPort { settings.clusterListenPort = max(1, value) }
        if let value = patch.clusterOffloadAIReplies { settings.clusterOffloadAIReplies = value }
        if let value = patch.clusterOffloadWikiLookups { settings.clusterOffloadWikiLookups = value }
        if let value = patch.autoStart { settings.autoStart = value }
        saveSettings()
        return true
    }

    func adminWebCommandCatalogSnapshot() -> AdminWebCommandCatalogPayload {
        struct VisualCommand {
            let id: String
            let name: String
            let usage: String
            let description: String
            let category: String
            let surface: String
            let aliases: [String]
            let adminOnly: Bool
        }

        let prefixCatalog = buildFullHelpCatalog(prefix: effectivePrefix())
        let prefixCommands = prefixCatalog.entries.map { entry in
            VisualCommand(
                id: "prefix-\(entry.name)",
                name: entry.name,
                usage: entry.usage,
                description: entry.description,
                category: entry.category.rawValue,
                surface: "prefix",
                aliases: entry.aliases,
                adminOnly: entry.isAdminOnly
            )
        }
        let slashCommands = allSlashCommandDefinitions().compactMap { raw -> VisualCommand? in
            guard let name = raw["name"] as? String else { return nil }
            let description = (raw["description"] as? String) ?? "No description"
            let options = (raw["options"] as? [[String: Any]]) ?? []
            let usageSuffix = options.compactMap { option in
                guard let optionName = option["name"] as? String else { return nil }
                let required = (option["required"] as? Bool) ?? false
                return required ? " \(optionName):<value>" : " [\(optionName):<value>]"
            }.joined()
            return VisualCommand(
                id: "slash-\(name)",
                name: name,
                usage: "/\(name)\(usageSuffix)",
                description: description,
                category: "Slash",
                surface: "slash",
                aliases: [],
                adminOnly: name == "debug"
            )
        }

        var commands = prefixCommands + slashCommands
        commands.append(
            VisualCommand(
                id: "mention-bug",
                name: "bug",
                usage: "@swiftbot bug (reply to a message)",
                description: "Creates a tracked bug report in #swiftbot-dev and manages status via reactions.",
                category: "Server",
                surface: "mention",
                aliases: [],
                adminOnly: true
            )
        )

        let items = commands.sorted { lhs, rhs in
            if lhs.surface != rhs.surface {
                return lhs.surface < rhs.surface
            }
            if lhs.category != rhs.category {
                return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        .map { command in
            AdminWebCommandCatalogItem(
                id: command.id,
                name: command.name,
                usage: command.usage,
                description: command.description,
                category: command.category,
                surface: command.surface.capitalized,
                aliases: command.aliases,
                adminOnly: command.adminOnly,
                enabled: isCommandEnabled(name: command.name, surface: command.surface)
            )
        }

        return AdminWebCommandCatalogPayload(
            commandsEnabled: settings.commandsEnabled,
            prefixCommandsEnabled: settings.prefixCommandsEnabled,
            slashCommandsEnabled: settings.slashCommandsEnabled,
            items: items
        )
    }

    func updateAdminWebCommandEnabled(name: String, surface: String, enabled: Bool) -> Bool {
        setCommandEnabled(name: name, surface: surface, enabled: enabled)
        saveSettings()
        if surface.lowercased() == "slash" {
            Task { await registerSlashCommandsIfNeeded() }
        }
        return true
    }

    func adminWebActionsSnapshot() -> AdminWebActionsPayload {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let servers = serverIDs.map { AdminWebSimpleOption(id: $0, name: connectedServers[$0] ?? $0) }

        let textChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableTextChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })
        let voiceChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableVoiceChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })

        return AdminWebActionsPayload(
            rules: ruleStore.rules,
            servers: servers,
            textChannelsByServer: textChannelsByServer,
            voiceChannelsByServer: voiceChannelsByServer,
            builderMetadata: AdminWebBuilderMetadata.generateFromNativeModels(),
            conditionTypes: ConditionType.allCases.map(\.rawValue),
            actionTypes: ActionType.allCases.map(\.rawValue)
        )
    }

    func adminWebPatchySnapshot() -> AdminWebPatchyPayload {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let servers = serverIDs.map { AdminWebSimpleOption(id: $0, name: connectedServers[$0] ?? $0) }
        let textChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableTextChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })
        let rolesByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let roles = (availableRolesByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, roles)
        })

        return AdminWebPatchyPayload(
            monitoringEnabled: settings.patchy.monitoringEnabled,
            showDebug: settings.patchy.showDebug,
            isCycleRunning: patchyIsCycleRunning,
            lastCycleAt: patchyLastCycleAt,
            debugLogs: Array(patchyDebugLogs.prefix(80)),
            sourceKinds: PatchySourceKind.allCases.map(\.rawValue),
            targets: settings.patchy.sourceTargets,
            servers: servers,
            textChannelsByServer: textChannelsByServer,
            rolesByServer: rolesByServer,
            steamAppNames: settings.patchy.steamAppNames
        )
    }

    func adminWebWikiBridgeSnapshot() -> AdminWebWikiBridgePayload {
        AdminWebWikiBridgePayload(
            enabled: settings.wikiBot.isEnabled,
            sources: settings.wikiBot.sources.sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary && !rhs.isPrimary }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        )
    }

    func updateAdminWebWikiBridgeState(_ patch: AdminWebWikiBridgeStatePatch) -> Bool {
        if let enabled = patch.enabled {
            settings.wikiBot.isEnabled = enabled
        }
        settings.wikiBot.normalizeSources()
        saveSettings()
        return true
    }

    func createAdminWebWikiSource() -> WikiSource? {
        let source = WikiSource.genericTemplate()
        addWikiBridgeSourceTarget(source)
        return source
    }

    func upsertAdminWebWikiSource(_ source: WikiSource) -> Bool {
        if settings.wikiBot.sources.contains(where: { $0.id == source.id }) {
            updateWikiBridgeSourceTarget(source)
        } else {
            addWikiBridgeSourceTarget(source)
        }
        return true
    }

    func setAdminWebWikiSourceEnabled(_ sourceID: UUID, enabled: Bool) -> Bool {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == sourceID }) else { return false }
        settings.wikiBot.sources[idx].enabled = enabled
        settings.wikiBot.normalizeSources()
        saveSettings()
        return true
    }

    func setAdminWebWikiSourcePrimary(_ sourceID: UUID) -> Bool {
        guard settings.wikiBot.sources.contains(where: { $0.id == sourceID }) else { return false }
        setWikiBridgePrimarySource(sourceID)
        return true
    }

    func testAdminWebWikiSource(_ sourceID: UUID) -> Bool {
        testWikiBridgeSource(targetID: sourceID)
        return true
    }

    func deleteAdminWebWikiSource(_ sourceID: UUID) -> Bool {
        deleteWikiBridgeSourceTarget(sourceID)
        return true
    }

    func updateAdminWebPatchyState(_ patch: AdminWebPatchyStatePatch) -> Bool {
        if let value = patch.monitoringEnabled {
            settings.patchy.monitoringEnabled = value
        }
        if let value = patch.showDebug {
            settings.patchy.showDebug = value
        }
        saveSettings()
        return true
    }

    func createAdminWebPatchyTarget() -> PatchySourceTarget? {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let serverID = serverIDs.first ?? ""
        let textChannelID = availableTextChannelsByServer[serverID]?.first?.id ?? ""
        let target = PatchySourceTarget(
            id: UUID(),
            isEnabled: true,
            source: .nvidia,
            steamAppID: "570",
            serverId: serverID,
            channelId: textChannelID,
            roleIDs: [],
            lastCheckedAt: nil,
            lastRunAt: nil,
            lastStatus: "Never checked"
        )
        addPatchyTarget(target)
        return target
    }

    func upsertAdminWebPatchyTarget(_ target: PatchySourceTarget) -> Bool {
        if settings.patchy.sourceTargets.contains(where: { $0.id == target.id }) {
            updatePatchyTarget(target)
        } else {
            addPatchyTarget(target)
        }
        return true
    }

    func deleteAdminWebPatchyTarget(_ targetID: UUID) -> Bool {
        deletePatchyTarget(targetID)
        return true
    }

    func setAdminWebPatchyTargetEnabled(_ targetID: UUID, enabled: Bool) -> Bool {
        setPatchyTargetEnabled(targetID, enabled: enabled)
        return true
    }

    func sendAdminWebPatchyTest(_ targetID: UUID) -> Bool {
        sendPatchyTest(targetID: targetID)
        return true
    }

    func runAdminWebPatchyCheckNow() -> Bool {
        runPatchyManualCheck()
        return true
    }

    func createAdminWebActionRule() -> Rule? {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let serverID = serverIDs.first ?? ""
        let textChannelID = availableTextChannelsByServer[serverID]?.first?.id ?? ""
        ruleStore.addNewRule(serverId: serverID, channelId: textChannelID)
        return ruleStore.rules.last
    }

    func upsertAdminWebActionRule(_ rule: Rule) -> Bool {
        if let index = ruleStore.rules.firstIndex(where: { $0.id == rule.id }) {
            ruleStore.rules[index] = rule
        } else {
            ruleStore.rules.append(rule)
        }
        ruleStore.scheduleAutoSave()
        return true
    }

    func deleteAdminWebActionRule(_ ruleID: UUID) -> Bool {
        let before = ruleStore.rules.count
        ruleStore.rules.removeAll { $0.id == ruleID }
        if before == ruleStore.rules.count {
            return false
        }
        if ruleStore.selectedRuleID == ruleID {
            ruleStore.selectedRuleID = ruleStore.rules.first?.id
        }
        ruleStore.scheduleAutoSave()
        return true
    }

    func updatePrefixFromAdmin(_ prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        settings.prefix = trimmed
        saveSettings()
        return true
    }

    /// Returns the base URL that OAuth redirect URIs must be built from.
    ///
    /// Priority:
    /// 1. Explicit `publicBaseURL` override (user-configured) — always wins.
    /// 2. Internet Access enabled + hostname configured → `https://<hostname>` (Cloudflare tunnel path).
    /// 3. Dev mode (Internet Access off) → `http://localhost:<port>` — uses `localhost` rather
    ///    than the bind address (127.0.0.1) so redirect URIs match Discord developer portal
    ///    registrations, which typically list localhost not the loopback IP.
    private func oauthPublicBaseURL() -> String {
        let explicit = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return explicit.contains("://") ? explicit : "https://" + explicit
        }

        let hostname = settings.adminWebUI.normalizedHostname
        if settings.adminWebUI.internetAccessEnabled, !hostname.isEmpty {
            return "https://\(hostname)"
        }

        // Dev mode: always use localhost (not bindHost / 127.0.0.1) so the redirect URI
        // matches standard Discord developer portal registrations.
        return "http://localhost:\(settings.adminWebUI.port)"
    }

    func configureAdminWebServer() async {
        let httpsConfiguration = usesLocalRuntime ? await resolveAdminWebHTTPSConfiguration() : nil
        let config = AdminWebServer.Configuration(
            enabled: usesLocalRuntime && settings.adminWebUI.enabled,
            bindHost: settings.adminWebUI.bindHost,
            port: settings.adminWebUI.port,
            publicBaseURL: oauthPublicBaseURL(),
            https: httpsConfiguration,
            discordOAuth: settings.adminWebUI.discordOAuth,
            localAuthEnabled: settings.adminWebUI.localAuthEnabled,
            localAuthUsername: settings.adminWebUI.localAuthUsername,
            localAuthPassword: settings.adminWebUI.localAuthPassword,
            redirectPath: normalizedAdminRedirectPath(settings.adminWebUI.redirectPath),
            allowedUserIDs: settings.adminWebUI.restrictAccessToSpecificUsers
                ? settings.adminWebUI.normalizedAllowedUserIDs
                : [],
            remoteAccessToken: settings.remoteAccessToken,
            devFeaturesEnabled: settings.devFeaturesEnabled
        )

        let runtimeState = await adminWebServer.configure(
            config: config,
            statusProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebStatusPayload(
                        botStatus: "stopped",
                        botUsername: "SwiftBot",
                        connectedServerCount: 0,
                        gatewayEventCount: 0,
                        uptimeText: nil,
                        webUIEnabled: false,
                        webUIBaseURL: ""
                    )
                }
                return await MainActor.run { model.adminWebStatusSnapshot() }
            },
            remoteStatusProvider: { [weak self] in
                guard let model = self else {
                    return RemoteStatusPayload(
                        botStatus: "stopped",
                        botUsername: "SwiftBot",
                        connectedServerCount: 0,
                        gatewayEventCount: 0,
                        uptimeText: nil,
                        webUIBaseURL: "",
                        clusterMode: ClusterMode.standalone.rawValue,
                        nodeRole: ClusterMode.standalone.rawValue,
                        leaderName: "Unavailable",
                        generatedAt: Date()
                    )
                }
                return await MainActor.run { model.remoteStatusSnapshot() }
            },
            remoteRulesProvider: { [weak self] in
                guard let model = self else {
                    return RemoteRulesPayload(
                        rules: [],
                        servers: [],
                        textChannelsByServer: [:],
                        voiceChannelsByServer: [:],
                        fetchedAt: Date()
                    )
                }
                return await MainActor.run { model.remoteRulesSnapshot() }
            },
            updateRemoteRule: { [weak self] rule in
                guard let model = self else { return false }
                return await MainActor.run { model.upsertAdminWebActionRule(rule) }
            },
            remoteEventsProvider: { [weak self] in
                guard let model = self else {
                    return RemoteEventsPayload(activity: [], logs: [], fetchedAt: Date())
                }
                return await MainActor.run { model.remoteEventsSnapshot() }
            },
            remoteSettingsProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebConfigPayload(
                        commands: .init(enabled: true, prefixEnabled: true, slashEnabled: true, bugTrackingEnabled: true, prefix: "/"),
                        aiBots: .init(localAIDMReplyEnabled: false, preferredProvider: AIProviderPreference.apple.rawValue, openAIEnabled: false, openAIModel: "", openAIImageGenerationEnabled: false, openAIImageMonthlyLimitPerUser: 0),
                        wikiBridge: .init(enabled: false, enabledSources: 0, totalSources: 0),
                        patchy: .init(monitoringEnabled: false, enabledTargets: 0, totalTargets: 0),
                        swiftMesh: .init(mode: ClusterMode.standalone.rawValue, nodeName: "SwiftBot", leaderAddress: "", listenPort: 38787, offloadAIReplies: false, offloadWikiLookups: false),
                        general: .init(autoStart: false, webUIEnabled: false, webUIBaseURL: "")
                    )
                }
                return await MainActor.run { model.adminWebConfigSnapshot() }
            },
            updateRemoteSettings: { [weak self] patch in
                guard let model = self else { return false }
                return await MainActor.run { model.applyAdminWebConfigPatch(patch) }
            },
            overviewProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebOverviewPayload(
                        metrics: [],
                        cluster: AdminWebClusterPayload(connectedNodes: 0, leader: "Unavailable", mode: "standalone"),
                        clusterNodes: [],
                        activeVoice: [],
                        recentVoice: [],
                        recentCommands: [],
                        botInfo: AdminWebBotInfoPayload(uptime: "--", errors: 0, state: "Stopped", cluster: nil)
                    )
                }
                return await MainActor.run { model.adminWebOverviewSnapshot() }
            },
            connectedGuildIDsProvider: { [weak self] in
                guard let model = self else { return [] }
                return await MainActor.run { Set(model.connectedServers.keys) }
            },
            currentPrefixProvider: { [weak self] in
                guard let model = self else { return "/" }
                return await MainActor.run { model.settings.prefix }
            },
            updatePrefix: { [weak self] prefix in
                guard let model = self else { return false }
                return await MainActor.run { model.updatePrefixFromAdmin(prefix) }
            },
            configProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebConfigPayload(
                        commands: .init(enabled: true, prefixEnabled: true, slashEnabled: true, bugTrackingEnabled: true, prefix: "/"),
                        aiBots: .init(localAIDMReplyEnabled: false, preferredProvider: AIProviderPreference.apple.rawValue, openAIEnabled: false, openAIModel: "", openAIImageGenerationEnabled: false, openAIImageMonthlyLimitPerUser: 0),
                        wikiBridge: .init(enabled: false, enabledSources: 0, totalSources: 0),
                        patchy: .init(monitoringEnabled: false, enabledTargets: 0, totalTargets: 0),
                        swiftMesh: .init(mode: ClusterMode.standalone.rawValue, nodeName: "SwiftBot", leaderAddress: "", listenPort: 38787, offloadAIReplies: true, offloadWikiLookups: true),
                        general: .init(autoStart: false, webUIEnabled: false, webUIBaseURL: "")
                    )
                }
                return await MainActor.run { model.adminWebConfigSnapshot() }
            },
            updateConfig: { [weak self] patch in
                guard let model = self else { return false }
                return await MainActor.run { model.applyAdminWebConfigPatch(patch) }
            },
            commandCatalogProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebCommandCatalogPayload(
                        commandsEnabled: true,
                        prefixCommandsEnabled: true,
                        slashCommandsEnabled: true,
                        items: []
                    )
                }
                return await MainActor.run { model.adminWebCommandCatalogSnapshot() }
            },
            updateCommandEnabled: { [weak self] name, surface, enabled in
                guard let model = self else { return false }
                return await MainActor.run { model.updateAdminWebCommandEnabled(name: name, surface: surface, enabled: enabled) }
            },
            actionsProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebActionsPayload(
                        rules: [],
                        servers: [],
                        textChannelsByServer: [:],
                        voiceChannelsByServer: [:],
                        builderMetadata: AdminWebBuilderMetadata.generateFromNativeModels(),
                        conditionTypes: ConditionType.allCases.map(\.rawValue),
                        actionTypes: ActionType.allCases.map(\.rawValue)
                    )
                }
                return await MainActor.run { model.adminWebActionsSnapshot() }
            },
            createActionRule: { [weak self] in
                guard let model = self else { return nil }
                return await MainActor.run { model.createAdminWebActionRule() }
            },
            updateActionRule: { [weak self] rule in
                guard let model = self else { return false }
                return await MainActor.run { model.upsertAdminWebActionRule(rule) }
            },
            deleteActionRule: { [weak self] ruleID in
                guard let model = self else { return false }
                return await MainActor.run { model.deleteAdminWebActionRule(ruleID) }
            },
            patchyProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebPatchyPayload(
                        monitoringEnabled: false,
                        showDebug: false,
                        isCycleRunning: false,
                        lastCycleAt: nil,
                        debugLogs: [],
                        sourceKinds: PatchySourceKind.allCases.map(\.rawValue),
                        targets: [],
                        servers: [],
                        textChannelsByServer: [:],
                        rolesByServer: [:],
                        steamAppNames: [:]
                    )
                }
                return await MainActor.run { model.adminWebPatchySnapshot() }
            },
            updatePatchyState: { [weak self] patch in
                guard let model = self else { return false }
                return await MainActor.run { model.updateAdminWebPatchyState(patch) }
            },
            createPatchyTarget: { [weak self] in
                guard let model = self else { return nil }
                return await MainActor.run { model.createAdminWebPatchyTarget() }
            },
            updatePatchyTarget: { [weak self] target in
                guard let model = self else { return false }
                return await MainActor.run { model.upsertAdminWebPatchyTarget(target) }
            },
            setPatchyTargetEnabled: { [weak self] targetID, enabled in
                guard let model = self else { return false }
                return await MainActor.run { model.setAdminWebPatchyTargetEnabled(targetID, enabled: enabled) }
            },
            deletePatchyTarget: { [weak self] targetID in
                guard let model = self else { return false }
                return await MainActor.run { model.deleteAdminWebPatchyTarget(targetID) }
            },
            sendPatchyTestTarget: { [weak self] targetID in
                guard let model = self else { return false }
                return await MainActor.run { model.sendAdminWebPatchyTest(targetID) }
            },
            runPatchyCheckNow: { [weak self] in
                guard let model = self else { return false }
                return await MainActor.run { model.runAdminWebPatchyCheckNow() }
            },
            wikiBridgeProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebWikiBridgePayload(enabled: false, sources: [])
                }
                return await MainActor.run { model.adminWebWikiBridgeSnapshot() }
            },
            updateWikiBridgeState: { [weak self] patch in
                guard let model = self else { return false }
                return await MainActor.run { model.updateAdminWebWikiBridgeState(patch) }
            },
            createWikiSource: { [weak self] in
                guard let model = self else { return nil }
                return await MainActor.run { model.createAdminWebWikiSource() }
            },
            updateWikiSource: { [weak self] source in
                guard let model = self else { return false }
                return await MainActor.run { model.upsertAdminWebWikiSource(source) }
            },
            setWikiSourceEnabled: { [weak self] sourceID, enabled in
                guard let model = self else { return false }
                return await MainActor.run { model.setAdminWebWikiSourceEnabled(sourceID, enabled: enabled) }
            },
            setWikiSourcePrimary: { [weak self] sourceID in
                guard let model = self else { return false }
                return await MainActor.run { model.setAdminWebWikiSourcePrimary(sourceID) }
            },
            testWikiSource: { [weak self] sourceID in
                guard let model = self else { return false }
                return await MainActor.run { model.testAdminWebWikiSource(sourceID) }
            },
            deleteWikiSource: { [weak self] sourceID in
                guard let model = self else { return false }
                return await MainActor.run { model.deleteAdminWebWikiSource(sourceID) }
            },
            mediaLibraryProvider: { [weak self] query in
                guard let model = self else {
                    return AdminWebMediaLibraryPayload(
                        generatedAt: Date(),
                        sources: [],
                        items: [],
                        games: [],
                        selectedSourceID: nil,
                        selectedDateRange: "all",
                        selectedGame: nil,
                        page: 1,
                        pageSize: 24,
                        totalItems: 0,
                        totalPages: 1
                    )
                }
                return await model.adminWebMediaLibrarySnapshot(query: query)
            },
            mediaStreamProvider: { [weak self] token, rangeHeader in
                guard let model = self else { return nil }
                return await model.adminWebMediaStreamResponse(token: token, rangeHeader: rangeHeader)
            },
            mediaThumbnailProvider: { [weak self] token in
                guard let model = self else { return nil }
                return await model.adminWebMediaThumbnailResponse(token: token)
            },
            mediaFrameProvider: { [weak self] token, seconds in
                guard let model = self else { return nil }
                return await model.adminWebMediaFrameResponse(token: token, atSeconds: seconds)
            },
            mediaExportStatusProvider: { [weak self] in
                guard let model = self else { return MediaExportStatus(installed: false, version: nil, path: nil) }
                return await model.adminWebMediaExportStatus()
            },
            mediaExportJobsProvider: { [weak self] in
                guard let model = self else { return MediaExportJobsPayload(jobs: []) }
                return await model.adminWebMediaExportJobs()
            },
            mediaClipExportStarter: { [weak self] request in
                guard let model = self else { return MediaExportJobResponse(job: nil, error: "Unavailable") }
                return await model.adminWebStartMediaClipExport(request: request)
            },
            mediaMultiViewExportStarter: { [weak self] request in
                guard let model = self else { return MediaExportJobResponse(job: nil, error: "Unavailable") }
                return await model.adminWebStartMediaMultiViewExport(request: request)
            },
            startBot: { [weak self] in
                guard let model = self else { return false }
                await model.startBot()
                return true
            },
            stopBot: { [weak self] in
                guard let model = self else { return false }
                await model.stopBot()
                return true
            },
            refreshSwiftMesh: { [weak self] in
                guard let model = self else { return false }
                _ = await MainActor.run { model.refreshClusterStatus() }
                return true
            },
            log: { [weak self] message in
                guard let model = self else { return }
                await MainActor.run { model.logs.append(message) }
            }
        )
        adminWebResolvedBaseURL = runtimeState.publicBaseURL
        updateAdminWebCertificateRenewalTask()
        await updateAdminWebPublicAccessRuntime()
    }

    private func resolveAdminWebHTTPSConfiguration() async -> AdminWebServer.Configuration.HTTPSConfiguration? {
        guard settings.adminWebUI.enabled, settings.adminWebUI.httpsEnabled else {
            return nil
        }

        do {
            switch settings.adminWebUI.certificateMode {
            case .automatic:
                let domain = settings.adminWebUI.normalizedHostname
                guard !domain.isEmpty else {
                    logs.append("⚠️ Admin Web UI HTTPS is enabled, but no hostname is configured. Falling back to HTTP.")
                    return nil
                }

                let logStore = logs
                let certificate = try await certificateManager.ensureCertificate(
                    for: domain,
                    cloudflareAPIToken: settings.adminWebUI.cloudflareAPIToken
                ) { message in
                    logStore.append(message)
                }

                return AdminWebServer.Configuration.HTTPSConfiguration(
                    certificatePath: certificate.certificateURL.path,
                    privateKeyPath: certificate.privateKeyURL.path,
                    hostOverride: domain,
                    reloadToken: domain
                )
            case .importCertificate:
                let imported = try await certificateManager.prepareImportedCertificate(
                    certificateFilePath: settings.adminWebUI.importedCertificateFile,
                    privateKeyFilePath: settings.adminWebUI.importedPrivateKeyFile,
                    certificateChainFilePath: settings.adminWebUI.importedCertificateChainFile
                )

                logs.append("📥 Using imported TLS certificate for the Admin Web UI.")
                return AdminWebServer.Configuration.HTTPSConfiguration(
                    certificatePath: imported.certificateURL.path,
                    privateKeyPath: imported.privateKeyURL.path,
                    hostOverride: nil,
                    reloadToken: imported.reloadToken
                )
            }
        } catch {
            logs.append("⚠️ Admin Web UI HTTPS unavailable: \(error.localizedDescription). Falling back to HTTP.")
            return nil
        }
    }

    func validateAdminWebAutomaticHTTPSConfiguration() async -> CertificateManager.AutomaticHTTPSValidation {
        await certificateManager.validateAutomaticHTTPSConfiguration(
            for: settings.adminWebUI.normalizedHostname,
            cloudflareAPIToken: settings.adminWebUI.cloudflareAPIToken
        )
    }

    func createAdminWebAutomaticHTTPSDNSRecord() async throws -> CertificateManager.DNSRecordCreation {
        let creation = try await certificateManager.createAutomaticHTTPSDNSRecord(
            for: settings.adminWebUI.normalizedHostname,
            cloudflareAPIToken: settings.adminWebUI.cloudflareAPIToken,
            publicBaseURL: settings.adminWebUI.publicBaseURL,
            bindHost: settings.adminWebUI.bindHost
        )

        logs.append("🌐 Created Cloudflare \(creation.type) record \(creation.name) -> \(creation.content) in \(creation.zoneName).")
        return creation
    }

    func startAdminWebAutomaticHTTPSProvisioning(
        progress: @escaping @MainActor @Sendable (AdminWebAutomaticHTTPSSetupEvent) -> Void
    ) async throws -> String {
        let normalizedDomain = settings.adminWebUI.normalizedHostname
        guard !normalizedDomain.isEmpty else {
            throw CertificateManager.Error.missingHostname
        }

        let trimmedToken = settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw CertificateManager.Error.missingCloudflareToken
        }

        settings.adminWebUI.hostname = normalizedDomain
        settings.adminWebUI.cloudflareAPIToken = trimmedToken
        settings.adminWebUI.publicBaseURL = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.enabled = true

        let logStore = logs
        let result = try await certificateManager.setupAutomaticHTTPS(
            for: normalizedDomain,
            cloudflareAPIToken: trimmedToken,
            progress: progress
        ) { message in
            logStore.append(message)
        }

        progress(.enablingHTTPSListener)
        await configureAdminWebServer()

        if settings.adminWebUI.enabled,
           !adminWebResolvedBaseURL.lowercased().hasPrefix("https://") {
            throw AdminWebHTTPSProvisioningError.tlsActivationFailed
        }
        progress(.httpsListenerEnabled(url: adminWebResolvedBaseURL))

        try await store.save(settings)
        try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
        logs.append("✅ Settings saved")

        if result.alreadyConfigured || !result.certificate.wasRenewed {
            logs.append("🔒 Admin Web UI HTTPS already configured.")
            return "HTTPS already configured"
        }

        logs.append("🔒 Admin Web UI HTTPS enabled.")
        return "HTTPS enabled"
    }

    func userFacingAdminWebHTTPSSetupMessage(for error: Error) -> String {
        switch error {
        case let error as CertificateManager.Error:
            return error.errorDescription ?? genericAdminWebHTTPSSetupFailureMessage
        case let error as CloudflareDNSProvider.Error:
            switch error {
            case .identicalRecordAlreadyExists:
                return "DNS challenge record verified. Existing DNS record will be reused for certificate provisioning."
            default:
                return error.errorDescription ?? genericAdminWebHTTPSSetupFailureMessage
            }
        case let error as ACMEClient.Error:
            switch error {
            case .invalidResponse,
                 .missingReplayNonce,
                 .missingAccountLocation,
                 .missingAuthorizations:
                return genericAdminWebHTTPSSetupFailureMessage
            case .dnsChallengeUnavailable,
                 .dnsPropagationTimedOut:
                return error.errorDescription ?? genericAdminWebHTTPSSetupFailureMessage
            case .orderFailed(let message),
                 .challengeFailed(let message):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.localizedCaseInsensitiveContains("data couldn")
                else {
                    return genericAdminWebHTTPSSetupFailureMessage
                }
                return trimmed
            }
        case let error as LocalizedError:
            let message = error.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? genericAdminWebHTTPSSetupFailureMessage : message
        default:
            return genericAdminWebHTTPSSetupFailureMessage
        }
    }

    func adminWebPublicAccessURL() -> URL? {
        if !adminWebPublicAccessStatus.publicURL.isEmpty {
            return URL(string: adminWebPublicAccessStatus.publicURL)
        }

        let hostname = effectiveAdminWebHostname()
        guard !hostname.isEmpty else { return nil }
        return URL(string: "https://\(hostname)")
    }

    func startAdminWebPublicAccessSetup(
        progress: @escaping @MainActor @Sendable (AdminWebPublicAccessSetupEvent) -> Void,
        forceReplaceDNS: Bool = false
    ) async throws -> String {
        logs.append("=== Public Access Setup Started ===")
        
        let hostname = effectiveAdminWebHostname()
        logs.append("Hostname: \(hostname)")
        guard !hostname.isEmpty else {
            logs.append("❌ Missing hostname")
            throw AdminWebPublicAccessError.missingHostname
        }

        let trimmedToken = settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            logs.append("❌ Missing Cloudflare API token")
            throw CertificateManager.Error.missingCloudflareToken
        }
        logs.append("✅ API token present")

        settings.adminWebUI.hostname = hostname
        settings.adminWebUI.cloudflareAPIToken = trimmedToken
        settings.adminWebUI.enabled = true

        logs.append("Proceeding to Cloudflare tunnel detection...")
        let dnsProvider = CloudflareDNSProvider(apiToken: trimmedToken)
        let tunnelClient = CloudflareTunnelClient(apiToken: trimmedToken)

        // Verify token in background (non-blocking, warning-level logging only)
        progress(.verifyingCloudflareAccess)
        Task.detached(priority: .background) {
            let tokenIsValid = await dnsProvider.verifyAPIToken()
            if tokenIsValid {
                await self.logs.append("✅ Cloudflare API verified (background)")
                await MainActor.run {
                    progress(.cloudflareAccessVerified)
                }
            } else {
                await self.logs.append("⚠️ Cloudflare API verification failed (token may be invalid or timed out)")
            }
        }

        // Continue without waiting for verification result
        logs.append("Cloudflare tunnel detection proceeding (verification in background)...")

        progress(.detectingCloudflareZone(domain: hostname))
        guard let zone = try await dnsProvider.findZone(for: hostname) else {
            throw CloudflareDNSProvider.Error.zoneNotFound(hostname)
        }
        logs.append("Cloudflare zone detected")
        progress(.cloudflareZoneDetected(zone: zone.name))

        guard let originURL = adminWebPublicAccessOriginURL() else {
            throw AdminWebPublicAccessError.invalidOriginURL
        }

        progress(.creatingTunnel(hostname: hostname))
        let (tunnel, alreadyExists) = try await tunnelClient.createTunnel(hostname: hostname, zone: zone)
        if alreadyExists {
            logs.append("Cloudflare tunnel detected")
            logs.append("Using existing tunnel: \(tunnel.name)")
            progress(.tunnelDetected(name: tunnel.name))
        } else {
            progress(.tunnelCreated(name: tunnel.name))
        }

        logs.append("Configuring tunnel ingress...")
        do {
            try await tunnelClient.configureTunnel(tunnel, hostname: hostname, originURL: originURL)
            logs.append("Tunnel ingress configured")
        } catch let tunnelError as CloudflareTunnelClient.Error {
            logs.append("Tunnel configuration error: \(tunnelError.localizedDescription)")
            if alreadyExists && isTunnelConfigurationAuthError(tunnelError) {
                logs.append("⚠️ Tunnel configuration skipped (existing tunnel may already be configured)")
            } else {
                throw tunnelError
            }
        }

        logs.append("Configuring Cloudflare DNS route...")
        logs.append("Tunnel: \(tunnel.name)")
        logs.append("Hostname: \(hostname)")
        progress(.creatingTunnelDNSRecord(hostname: hostname))
        let tunnelTarget = CloudflareTunnelClient.tunnelTargetHostname(for: tunnel.id)
        logs.append("Tunnel target: \(tunnelTarget)")

        let dnsResult = try await dnsProvider.configureTunnelDNSRoute(
            hostname: hostname,
            tunnelTarget: tunnelTarget,
            zoneID: zone.id,
            force: forceReplaceDNS
        )

        switch dnsResult {
        case .created:
            logs.append("DNS route created for \(hostname)")
        case .alreadyConfigured:
            logs.append("DNS route already configured for \(hostname)")
        case .replaced(let previousType):
            logs.append("Replaced existing \(previousType) record with Cloudflare Tunnel route for \(hostname)")
        }
        progress(.tunnelDNSRecordCreated(hostname: hostname))

        progress(.storingTunnelCredentials)
        settings.adminWebUI.internetAccessEnabled = true
        settings.adminWebUI.hostname = hostname
        settings.adminWebUI.publicAccessTunnelID = tunnel.id
        settings.adminWebUI.publicAccessTunnelName = tunnel.name
        settings.adminWebUI.publicAccessTunnelAccountID = tunnel.accountID
        settings.adminWebUI.publicAccessTunnelToken = tunnel.token

        try await store.save(settings)
        try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
        logs.append("✅ Settings saved")

        progress(.startingTunnelProcess)
        await configureAdminWebServer()

        if adminWebPublicAccessStatus.state == .error {
            throw AdminWebPublicAccessError.tunnelStartupFailed(adminWebPublicAccessStatus.detail)
        }

        let publicURL = "https://\(hostname)"
        logs.append("Public access available at \(publicURL)")
        progress(.publicAccessEnabled(url: publicURL))
        return "Public access enabled"
    }

    /// Stops the Cloudflare tunnel and disables Internet Access at runtime,
    /// but keeps all configuration (token, zone, hostname, tunnel credentials)
    /// so the user can re-enable without re-running setup.
    func stopInternetAccess() async {
        settings.adminWebUI.internetAccessEnabled = false
        await configureAdminWebServer()
        do {
            try await store.save(settings)
            try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
        } catch {
            logs.append("❌ Failed saving settings: \(error.localizedDescription)")
        }
    }

    /// Performs a destructive reset of Internet Access:
    /// deletes the DNS record and Cloudflare Tunnel, then clears all stored
    /// configuration (token, zone, hostname, tunnel credentials).
    func resetInternetAccess() async {
        let hostname = effectiveAdminWebHostname()
        let tunnelID = settings.adminWebUI.publicAccessTunnelID
        let accountID = settings.adminWebUI.publicAccessTunnelAccountID
        let apiToken = settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)

        // Stop the tunnel first
        settings.adminWebUI.internetAccessEnabled = false
        settings.adminWebUI.publicAccessTunnelID = ""
        settings.adminWebUI.publicAccessTunnelName = ""
        settings.adminWebUI.publicAccessTunnelAccountID = ""
        settings.adminWebUI.publicAccessTunnelToken = ""
        await configureAdminWebServer()

        // Clean up the Cloudflare-side resources
        if !apiToken.isEmpty, !tunnelID.isEmpty, !accountID.isEmpty, !hostname.isEmpty {
            let dnsProvider = CloudflareDNSProvider(apiToken: apiToken)
            let tunnelClient = CloudflareTunnelClient(apiToken: apiToken)
            do {
                if let zone = try await dnsProvider.findZone(for: hostname),
                   let record = try await dnsProvider.findDNSRecord(
                        zoneID: zone.id,
                        hostname: hostname,
                        allowedTypes: ["CNAME"],
                        expectedContent: CloudflareTunnelClient.tunnelTargetHostname(for: tunnelID)
                   ) {
                    try? await dnsProvider.deleteDNSRecord(record)
                }
                try? await tunnelClient.deleteTunnel(accountID: accountID, tunnelID: tunnelID)
            } catch {
                logs.append("⚠️ Internet Access reset cleanup warning: \(error.localizedDescription)")
            }
        }

        // Clear all configuration to return to initial state
        settings.adminWebUI.cloudflareAPIToken = ""
        settings.adminWebUI.selectedZoneID = ""
        settings.adminWebUI.selectedZoneName = ""
        settings.adminWebUI.subdomain = ""
        settings.adminWebUI.hostname = ""

        do {
            try await store.save(settings)
            try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
            logs.append("✅ Internet Access reset complete")
        } catch {
            logs.append("❌ Failed saving settings: \(error.localizedDescription)")
        }
    }

    @available(*, deprecated, renamed: "resetInternetAccess")
    func disableAdminWebPublicAccess() async {
        await resetInternetAccess()
    }

    // MARK: - Unified Internet Access Setup

    /// Verifies the Cloudflare API token and returns available zones.
    /// - Parameter token: The Cloudflare API token to verify
    /// - Returns: Array of zones available to this token
    func verifyCloudflareTokenAndListZones(token: String) async throws -> [CloudflareDNSProvider.ZoneSummary] {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw CertificateManager.Error.missingCloudflareToken
        }
        
        let dnsProvider = CloudflareDNSProvider(apiToken: trimmedToken)
        
        // First verify the token is valid by checking user info
        let isValid = await dnsProvider.verifyAPIToken()
        guard isValid else {
            throw CertificateManager.Error.inactiveCloudflareToken
        }
        
        // Then list all available zones
        return try await dnsProvider.listZones()
    }

    func startInternetAccessSetup(
        progress: @escaping @MainActor @Sendable (InternetAccessSetupEvent) -> Void,
        forceReplaceDNS: Bool = false
    ) async throws -> String {
        logs.append("=== Internet Access Setup Started ===")
        
        let hostname = effectiveAdminWebHostname()
        logs.append("Hostname: \(hostname)")
        guard !hostname.isEmpty else {
            logs.append("❌ Missing hostname")
            throw AdminWebPublicAccessError.missingHostname
        }

        let trimmedToken = settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            logs.append("❌ Missing Cloudflare API token")
            throw CertificateManager.Error.missingCloudflareToken
        }
        logs.append("✅ API token present")

        settings.adminWebUI.hostname = hostname
        settings.adminWebUI.cloudflareAPIToken = trimmedToken
        settings.adminWebUI.enabled = true

        let dnsProvider = CloudflareDNSProvider(apiToken: trimmedToken)
        let tunnelClient = CloudflareTunnelClient(apiToken: trimmedToken)

        // Step 1: Verify Cloudflare API (non-blocking, background task)
        progress(.verifyingCloudflareAccess)
        Task.detached(priority: .background) {
            let tokenIsValid = await dnsProvider.verifyAPIToken()
            if tokenIsValid {
                await self.logs.append("✅ Cloudflare API verified (background)")
                await MainActor.run {
                    progress(.cloudflareAccessVerified)
                }
            } else {
                await self.logs.append("⚠️ Cloudflare API verification failed (token may be invalid or timed out)")
            }
        }

        // Continue without waiting for verification result
        logs.append("Cloudflare tunnel detection proceeding (verification in background)...")

        // Step 2: Detect Cloudflare zone
        progress(.detectingCloudflareZone(domain: hostname))
        guard let zone = try await dnsProvider.findZone(for: hostname) else {
            throw CloudflareDNSProvider.Error.zoneNotFound(hostname)
        }
        logs.append("Cloudflare zone detected: \(zone.name)")
        progress(.cloudflareZoneDetected(zone: zone.name))

        // Step 3: Detect or create tunnel
        progress(.creatingTunnel(hostname: hostname))
        let (tunnel, alreadyExists) = try await tunnelClient.createTunnel(hostname: hostname, zone: zone)
        if alreadyExists {
            logs.append("Cloudflare tunnel detected")
            logs.append("Using existing tunnel: \(tunnel.name)")
            progress(.tunnelDetected(name: tunnel.name))
        } else {
            logs.append("Created tunnel: \(tunnel.name)")
            progress(.tunnelCreated(name: tunnel.name))
        }

        // Configure tunnel ingress
        logs.append("Configuring tunnel ingress...")
        do {
            try await tunnelClient.configureTunnel(tunnel, hostname: hostname, originURL: "http://localhost:\(settings.adminWebUI.port)")
            logs.append("Tunnel ingress configured")
        } catch let tunnelError as CloudflareTunnelClient.Error {
            logs.append("Tunnel configuration error: \(tunnelError.localizedDescription)")
            if alreadyExists && isTunnelConfigurationAuthError(tunnelError) {
                logs.append("⚠️ Tunnel configuration skipped (existing tunnel may already be configured)")
            } else {
                throw tunnelError
            }
        }

        // Step 4: Configure DNS route
        progress(.creatingTunnelDNSRecord(hostname: hostname))
        let tunnelTarget = CloudflareTunnelClient.tunnelTargetHostname(for: tunnel.id)
        logs.append("Tunnel target: \(tunnelTarget)")

        let dnsResult = try await dnsProvider.configureTunnelDNSRoute(
            hostname: hostname,
            tunnelTarget: tunnelTarget,
            zoneID: zone.id,
            force: forceReplaceDNS
        )

        switch dnsResult {
        case .created:
            logs.append("DNS route created for \(hostname)")
        case .alreadyConfigured:
            logs.append("DNS route already configured for \(hostname)")
        case .replaced(let previousType):
            logs.append("Replaced existing \(previousType) record with Cloudflare Tunnel route for \(hostname)")
        }
        progress(.tunnelDNSRecordCreated(hostname: hostname))

        // Step 5: Issue HTTPS certificate (handled automatically by Cloudflare)
        progress(.issuingHTTPSCertificate(hostname: hostname))
        logs.append("HTTPS certificate provisioned by Cloudflare")
        progress(.httpsCertificateIssued(hostname: hostname))

        // Step 6: Save tunnel credentials and start Cloudflare Tunnel
        progress(.startingCloudflareTunnel)
        settings.adminWebUI.internetAccessEnabled = true
        settings.adminWebUI.publicAccessTunnelID = tunnel.id
        settings.adminWebUI.publicAccessTunnelName = tunnel.name
        settings.adminWebUI.publicAccessTunnelAccountID = tunnel.accountID
        settings.adminWebUI.publicAccessTunnelToken = tunnel.token

        try await store.save(settings)
        try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
        logs.append("✅ Tunnel credentials saved")

        // Start the tunnel (local HTTP server is already running via configureAdminWebServer)
        await configureAdminWebServer()

        if adminWebPublicAccessStatus.state == .error {
            throw AdminWebPublicAccessError.tunnelStartupFailed(adminWebPublicAccessStatus.detail)
        }
        logs.append("Cloudflare tunnel started")
        progress(.cloudflareTunnelStarted)

        // Step 6: Internet Access enabled
        let publicURL = "https://\(hostname)"
        logs.append("Internet Access enabled at \(publicURL)")
        progress(.internetAccessEnabled(url: publicURL))
        return "Internet Access enabled"
    }

    private func isTunnelConfigurationAuthError(_ error: CloudflareTunnelClient.Error) -> Bool {
        guard case .apiFailed(let message) = error else { return false }
        return message.localizedCaseInsensitiveContains("auth")
            || message.localizedCaseInsensitiveContains("permission")
            || message.localizedCaseInsensitiveContains("forbidden")
            || message.localizedCaseInsensitiveContains("10000")
    }

    func userFacingAdminWebPublicAccessMessage(for error: Error) -> String {
        switch error {
        case let error as AdminWebPublicAccessError:
            return error.errorDescription ?? genericAdminWebPublicAccessFailureMessage
        case let error as CertificateManager.Error:
            return error.errorDescription ?? genericAdminWebPublicAccessFailureMessage
        case let error as CloudflareDNSProvider.Error:
            return error.errorDescription ?? genericAdminWebPublicAccessFailureMessage
        case let error as CloudflareTunnelClient.Error:
            let message = error.errorDescription ?? genericAdminWebPublicAccessFailureMessage
            if message.localizedCaseInsensitiveContains("authentication") || 
               message.localizedCaseInsensitiveContains("access denied") ||
               message.localizedCaseInsensitiveContains("permission") {
                return "Cloudflare authentication failed. Ensure your API token has 'Cloudflare Tunnel: Edit' permissions."
            }
            return message
        case let error as TunnelManager.Error:
            return error.errorDescription ?? genericAdminWebPublicAccessFailureMessage
        case let error as LocalizedError:
            let message = error.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? genericAdminWebPublicAccessFailureMessage : message
        default:
            return genericAdminWebPublicAccessFailureMessage
        }
    }

    private func updateAdminWebPublicAccessRuntime() async {
        let logger: @MainActor @Sendable (String) -> Void = { [weak self] message in
            self?.logs.append(message)
        }
        let statusHandler: @MainActor @Sendable (AdminWebPublicAccessRuntimeStatus) -> Void = { [weak self] status in
            self?.adminWebPublicAccessStatus = status
        }

        guard settings.adminWebUI.enabled,
              settings.adminWebUI.publicAccessEnabled
        else {
            await tunnelProvider.configure(nil, logger: logger, statusHandler: statusHandler)
            return
        }

        let hostname = effectiveAdminWebHostname()
        let tunnelToken = settings.adminWebUI.publicAccessTunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let tunnelID = settings.adminWebUI.publicAccessTunnelID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !hostname.isEmpty, !tunnelToken.isEmpty, !tunnelID.isEmpty,
              let originURL = adminWebPublicAccessOriginURL() else {
            await tunnelProvider.configure(nil, logger: logger, statusHandler: statusHandler)
            adminWebPublicAccessStatus = AdminWebPublicAccessRuntimeStatus(
                state: .error,
                publicURL: hostname.isEmpty ? "" : "https://\(hostname)",
                detail: "Public Access is enabled but the stored tunnel configuration is incomplete."
            )
            return
        }

        await tunnelProvider.configure(
            .init(
                hostname: hostname,
                publicURL: "https://\(hostname)",
                originURL: originURL,
                tunnelToken: tunnelToken
            ),
            logger: logger,
            statusHandler: statusHandler
        )
    }

    private func effectiveAdminWebHostname() -> String {
        let explicit = settings.adminWebUI.normalizedHostname
        if !explicit.isEmpty {
            return explicit
        }
        return settings.adminWebUI.normalizedHostname
    }

    private func adminWebPublicAccessOriginURL() -> String? {
        let trimmedHost = settings.adminWebUI.bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = trimmedHost.lowercased()

        let originHost: String
        switch normalizedHost {
        case "", "0.0.0.0", "::", "[::]", "localhost":
            originHost = "127.0.0.1"
        default:
            originHost = trimmedHost
        }

        guard !originHost.isEmpty else {
            return nil
        }

        if originHost.contains(":") && !originHost.hasPrefix("[") {
            return "http://[\(originHost)]:\(settings.adminWebUI.port)"
        }

        return "http://\(originHost):\(settings.adminWebUI.port)"
    }

    private func updateAdminWebCertificateRenewalTask() {
        let configuration = AdminWebCertificateRenewalConfiguration(
            enabled: settings.adminWebUI.enabled
                && settings.adminWebUI.httpsEnabled
                && settings.adminWebUI.certificateMode == .automatic,
            domain: settings.adminWebUI.normalizedHostname,
            cloudflareToken: settings.adminWebUI.cloudflareAPIToken
        )

        if adminWebCertificateRenewalConfiguration == configuration, adminWebCertificateRenewalTask != nil {
            return
        }

        adminWebCertificateRenewalTask?.cancel()
        adminWebCertificateRenewalTask = nil
        adminWebCertificateRenewalConfiguration = configuration

        guard configuration.enabled, !configuration.domain.isEmpty else {
            return
        }

        adminWebCertificateRenewalTask = Task { [weak self] in
            guard let self else { return }
            await self.runAdminWebCertificateRenewalLoop(configuration)
        }
    }

    private func runAdminWebCertificateRenewalLoop(_ configuration: AdminWebCertificateRenewalConfiguration) async {
        while !Task.isCancelled {
            do {
                let logStore = logs
                let certificate = try await certificateManager.ensureCertificate(
                    for: configuration.domain,
                    cloudflareAPIToken: configuration.cloudflareToken
                ) { message in
                    logStore.append(message)
                }

                if certificate.wasRenewed {
                    let runtimeState = await adminWebServer.restartListener()
                    await MainActor.run {
                        self.adminWebResolvedBaseURL = runtimeState.publicBaseURL
                        self.logs.append("♻️ Reloaded Admin Web UI TLS listener with the renewed certificate.")
                    }
                }
            } catch {
                await MainActor.run {
                    self.logs.append("⚠️ Admin Web UI certificate renewal check failed: \(error.localizedDescription)")
                }
            }

            do {
                try await Task.sleep(nanoseconds: 12 * 60 * 60 * 1_000_000_000)
            } catch {
                break
            }
        }
    }

}
