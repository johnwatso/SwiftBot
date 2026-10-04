import Foundation
import RecordingsKit
import SwiftUI
import AppKit
import AVFoundation
import Darwin

/// Web equivalents of the SF Symbol / SwiftUI tint the native personality
/// tiles use. Lucide icon names and `getTintHex()` keys.
private extension AppleIntelligencePersonality {
    var webIcon: String {
        switch self {
        case .casual: return "smile"
        case .helpful: return "life-buoy"
        case .playful: return "party-popper"
        }
    }

    var webTint: String {
        switch self {
        case .casual: return "green"
        case .helpful: return "blue"
        case .playful: return "pink"
        }
    }
}

func adminWebOAuthRedirectURL(baseURL rawBaseURL: String, redirectPath rawRedirectPath: String) -> String {
    var baseURL = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !baseURL.isEmpty else { return "" }

    if !baseURL.contains("://") {
        baseURL = "https://" + baseURL
    }

    let trimmedPath = rawRedirectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let path = trimmedPath.isEmpty
        ? "/auth/discord/callback"
        : (trimmedPath.hasPrefix("/") ? trimmedPath : "/" + trimmedPath)

    guard var components = URLComponents(string: baseURL) else {
        return baseURL + (baseURL.hasSuffix("/") ? String(path.dropFirst()) : path)
    }

    if !components.path.isEmpty && components.path != "/" {
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
    } else {
        components.path = path
    }

    return components.url?.absoluteString ?? (baseURL + (baseURL.hasSuffix("/") ? String(path.dropFirst()) : path))
}

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
            botUsername: resolvedBotUsername,
            botAvatarURL: botAvatarURL?.absoluteString,
            connectedServerCount: connectedServers.count,
            gatewayEventCount: gatewayEventCount,
            uptimeText: uptime?.text,
            webUIEnabled: settings.adminWebUI.enabled,
            webUIBaseURL: adminWebBaseURL(),
            clusterMode: settings.clusterMode.rawValue,
            runtimeState: clusterSnapshot.runtimeState.rawValue,
            isFailoverManagedNode: isFailoverManagedNode
        )
    }

    /// Creates a complete snapshot of current configuration for change detection in the UI.
    func createPreferencesSnapshot() -> AppPreferencesSnapshot {
        AppPreferencesSnapshot(
            token: settings.token,
            prefix: settings.prefix,
            autoStart: settings.autoStart,
            presenceMode: settings.presenceMode,
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
            mediaFastStartOptimizationEnabled: mediaLibrarySettings.fastStartOptimizationEnabled,
            mediaFastStartOutputPath: mediaLibrarySettings.fastStartOutputPath,
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
            localAISystemPrompt: settings.localAISystemPrompt,
            gameTracking: settings.gameTracking,
            gameProviders: settings.gameProviders
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
        let actionRuleCount = totalAutomationRuleCount
        let enabledActionRuleCount = enabledAutomationRuleCount
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
                title: "Lookup Status",
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
                title: "AI",
                value: appleIntelligenceOnline ? "Apple Intelligence online" : "Apple Intelligence offline",
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
                    joinedText: "Joined \(member.joinedAt.formatted(date: .omitted, time: .shortened))",
                    joinedAt: member.joinedAt
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
            ),
            health: adminWebOverviewHealth()
        )
    }

    /// SF Symbols used by OverviewHealthReport → the WebUI's lucide names.
    private static let adminWebHealthIcons: [String: String] = [
        "antenna.radiowaves.left.and.right": "radio-tower",
        "point.3.connected.trianglepath.dotted": "network",
        "arrow.triangle.2.circlepath": "refresh-cw",
        "memorychip": "memory-stick",
        "checkmark.icloud": "cloud",
        "waveform.path.ecg": "activity",
        "gauge.with.needle": "gauge",
        "checklist": "list-checks",
        "waveform": "audio-waveform",
        "terminal": "terminal",
        "info.circle": "info",
        "exclamationmark.triangle": "triangle-alert",
        "xmark.octagon": "octagon-x",
        "square.and.arrow.down.badge.checkmark": "download",
        "hammer": "hammer"
    ]

    private func adminWebOverviewHealth() -> AdminWebOverviewHealthPayload {
        let report = OverviewHealthReport(.init(
            status: status,
            settings: settings,
            events: events,
            commandLog: commandLog,
            rules: ruleStore.rules,
            enabledAutomationCount: automationStore.rules.filter(\.enabled).count,
            clusterNodes: clusterNodes,
            clusterSnapshot: clusterSnapshot,
            diagnostics: connectionDiagnostics,
            lastGatewayEventName: lastGatewayEventName,
            intentsAccepted: intentsAccepted,
            lastVoiceStateAt: lastVoiceStateAt,
            lastClusterStatusSuccessAt: lastClusterStatusSuccessAt,
            patchyLastCycleAt: patchyLastCycleAt,
            patchyIsCycleRunning: patchyIsCycleRunning,
            memoryText: OverviewHealthReport.memoryText(samples: [])
        ))
        let icon = { (symbol: String) in Self.adminWebHealthIcons[symbol] ?? "circle" }
        let severityName: (OverviewHealthReport.AttentionItem.Severity) -> String = {
            switch $0 {
            case .critical: return "critical"
            case .warning: return "warning"
            case .info: return "info"
            }
        }

        return AdminWebOverviewHealthPayload(
            state: report.overall.rawValue,
            title: report.overallTitle,
            tiles: report.tiles.map {
                .init(id: $0.id, title: $0.title, value: $0.value, detail: $0.detail, icon: icon($0.symbol), state: $0.state.rawValue)
            },
            attention: report.attention.map {
                .init(id: $0.id, title: $0.title, detail: $0.detail, severity: severityName($0.severity), label: $0.severity.label)
            },
            activity: report.activity.map {
                .init(id: $0.id, timestamp: $0.timestamp, title: $0.title, detail: $0.detail, icon: icon($0.symbol), tone: $0.tone.rawValue)
            }
        )
    }

    /// Read-only Rewind snapshot for the admin web UI. Deliberately excludes
    /// every collection toggle and any message text: the web surface reports
    /// what the archive holds, it does not turn archiving on or read the
    /// archive back out.
    func adminWebRewindSnapshot() async -> AdminWebRewindPayload {
        let stats = await rewindStore.archiveStats()
        let filterStopWords = settings.rewind.filterStopWords
        let currentYear = Calendar.current.component(.year, from: Date())

        var guilds: [AdminWebRewindGuildPayload] = []
        for (guildID, guildName) in connectedServers.sorted(by: { $0.value < $1.value }) {
            let years = await rewindStore.availableYears(guildID: guildID)
            let year = years.first ?? currentYear
            let summary = await rewindStore.yearSummary(
                guildID: guildID,
                year: year,
                filterStopWords: filterStopWords
            )
            guard !summary.isEmpty else { continue }

            guilds.append(
                AdminWebRewindGuildPayload(
                    id: guildID,
                    name: guildName,
                    years: years,
                    year: year,
                    totalMessages: summary.totalMessages,
                    totalWords: summary.totalWords,
                    activeDays: summary.activeDays,
                    busiestDay: summary.busiestDay?.day,
                    peakHour: summary.peakHour.map { hour in
                        let suffix = hour < 12 ? "am" : "pm"
                        let display = hour.isMultiple(of: 12) ? 12 : hour % 12
                        return "\(display)\(suffix)"
                    },
                    topUsers: summary.topUsers.prefix(5).map {
                        AdminWebRewindTermPayload(label: $0.userName, count: $0.count)
                    },
                    topWords: summary.topWords.prefix(8).map {
                        AdminWebRewindTermPayload(label: $0.term, count: $0.count)
                    },
                    topPhrases: summary.topBigrams.prefix(5).map {
                        AdminWebRewindTermPayload(label: $0.term, count: $0.count)
                    },
                    topEmoji: summary.topEmoji.prefix(8).map {
                        AdminWebRewindTermPayload(label: $0.term, count: $0.count)
                    }
                )
            )
        }

        return AdminWebRewindPayload(
            generatedAt: Date(),
            isEnabled: settings.rewind.isEnabled,
            retainsContent: settings.rewind.retainMessageContent,
            retentionDays: settings.rewind.retentionDays,
            messageCount: stats.messageCount,
            diskBytes: Int(stats.diskBytes),
            earliestDay: stats.earliestDay,
            latestDay: stats.latestDay,
            guilds: guilds
        )
    }

    func adminWebAnalyticsSnapshot() async -> AdminWebAnalyticsPayload {
        async let daily = voiceSessionStore.getVoiceActivityLast7Days()
        async let hourly = voiceSessionStore.getVoiceActivityByHour()
        async let users = voiceSessionStore.getTopVoiceUsers(limit: 5)
        async let totalTime = voiceSessionStore.getTotalVoiceTimeThisWeek()
        async let sessionCount = voiceSessionStore.getSessionCountThisWeek()

        let now = Date()
        let loadedDaily = await daily
        let loadedHourly = await hourly
        let loadedUsers = await users
        let loadedTotalSeconds = Int(await totalTime)
        let loadedSessionCount = await sessionCount
        let activeUsernames = Set(activeVoice.map(\.username))
        let commandsToday = commandLog.filter { Calendar.current.isDateInToday($0.time) }.count
        let failedCommandsToday = commandLog.filter { Calendar.current.isDateInToday($0.time) && !$0.ok }.count
        let enabledRuleCount = enabledAutomationRuleCount
        let automationFailures = events.filter {
            ($0.kind == .error || $0.kind == .warning)
                && $0.message.localizedCaseInsensitiveContains("automation")
        }.count
        let activeTaskCount = mediaExportJobs.filter { $0.status == .queued || $0.status == .running }.count
            + (patchyIsCycleRunning ? 1 : 0)
        let finishedExports = mediaExportJobs.filter { $0.status == .finished }.count
        let failedExports = mediaExportJobs.filter { $0.status == .failed }.count
        let activeExports = mediaExportJobs.filter { $0.status == .queued || $0.status == .running }.count
        let queueDepth = events.count
        let queueLoad = min(Double(queueDepth) / 20.0, 1.0)
        let healthState = adminWebAnalyticsHealthState(
            latencyMs: connectionDiagnostics.heartbeatLatencyMs,
            queueLoad: queueLoad,
            failedCommandsToday: failedCommandsToday,
            automationFailures: automationFailures
        )
        let peakHour = loadedHourly.max { $0.count < $1.count }.flatMap { $0.count >= 1 ? $0 : nil }
        let mostActiveDay = adminWebDeterministicMostActiveDay(from: loadedDaily)
        let averageSession = loadedSessionCount > 0 ? loadedTotalSeconds / loadedSessionCount : 0
        let averageWatchSeconds = mediaPlaybackStarts > 0 ? mediaPlaybackTotalSeconds / mediaPlaybackStarts : 0
        let exportSuccessRate = finishedExports + failedExports > 0
            ? Int((Double(finishedExports) / Double(finishedExports + failedExports)) * 100)
            : 100
        let successRate = stats.commandsRun > 0
            ? Double(max(0, stats.commandsRun - stats.errors)) / Double(stats.commandsRun)
            : 1

        let metrics = [
            AdminWebAnalyticsMetricPayload(
                id: "voice-sessions",
                title: "Voice Sessions",
                value: "\(loadedSessionCount)",
                detail: "\(activeVoice.count) currently active",
                trend: averageSession > 0 ? "Average \(adminWebFormatDuration(averageSession))" : "Waiting for completed sessions",
                tone: "usage"
            ),
            AdminWebAnalyticsMetricPayload(
                id: "voice-time",
                title: "Total Voice Time",
                value: adminWebFormatDuration(loadedTotalSeconds),
                detail: "Last 7 days",
                trend: averageSession > 0 ? "Average session \(adminWebFormatDuration(averageSession))" : "No completed sessions yet",
                tone: "usage"
            ),
            AdminWebAnalyticsMetricPayload(
                id: "most-active-day",
                title: "Most Active Day",
                value: mostActiveDay,
                detail: adminWebPeakDayDetail(from: loadedDaily),
                trend: peakHour.map { "Peak activity at \(adminWebHourLabel($0.hour))" } ?? "No hourly peak yet",
                tone: "automation"
            ),
            AdminWebAnalyticsMetricPayload(
                id: "top-user",
                title: "Top User",
                value: loadedUsers.first?.username ?? "-",
                detail: loadedUsers.first.map { "\(adminWebActivityShare(seconds: $0.seconds, total: loadedTotalSeconds))% of tracked voice time" } ?? "No voice leaders yet",
                trend: activeVoice.isEmpty ? "No live voice sessions" : "\(activeVoice.count) live voice users",
                tone: "healthy"
            ),
            AdminWebAnalyticsMetricPayload(
                id: "commands-today",
                title: "Commands Today",
                value: "\(commandsToday)",
                detail: "\(stats.commandsRun) lifetime",
                trend: "\(Int(successRate * 100))% command success",
                tone: failedCommandsToday > 0 ? "warning" : "usage"
            ),
            AdminWebAnalyticsMetricPayload(
                id: "active-automations",
                title: "Active Automations",
                value: "\(enabledRuleCount)",
                detail: patchyIsCycleRunning ? "Patchy running now" : "Rule engine ready",
                trend: automationFailures > 0 ? "\(automationFailures) automation warnings" : "Automation nominal",
                tone: automationFailures > 0 ? "warning" : "automation"
            ),
            AdminWebAnalyticsMetricPayload(
                id: "recordings-watched",
                title: "Videos Watched",
                value: "\(mediaPlaybackStarts)",
                detail: "\(mediaPlaybackUniqueItemCount) unique recordings opened",
                trend: averageWatchSeconds > 0
                    ? "Average watch \(adminWebFormatDuration(averageWatchSeconds))"
                    : "Waiting for playback telemetry",
                tone: "usage"
            ),
            AdminWebAnalyticsMetricPayload(
                id: "clips-exported",
                title: "Clips Exported",
                value: "\(finishedExports)",
                detail: activeExports > 0 ? "\(activeExports) exports in progress" : "No active exports",
                trend: failedExports > 0
                    ? "\(failedExports) failed · \(exportSuccessRate)% success"
                    : "\(exportSuccessRate)% success rate",
                tone: failedExports > 0 ? "warning" : "healthy"
            )
        ]

        let topUsers = loadedUsers.map { user in
            AdminWebAnalyticsTopUserPayload(
                id: user.username,
                username: user.username,
                initials: adminWebInitials(for: user.username),
                totalTime: adminWebFormatDuration(user.seconds),
                activityShare: adminWebActivityShare(seconds: user.seconds, total: loadedTotalSeconds),
                isActive: activeUsernames.contains(user.username)
            )
        }

        var payload = AdminWebAnalyticsPayload(
            generatedAt: now,
            peakActivityLabel: peakHour.map { "Peak activity at \(adminWebHourLabel($0.hour))" } ?? "Waiting for activity",
            metrics: metrics,
            dailyActivity: loadedDaily.map {
                AdminWebAnalyticsDayPayload(date: $0.date, label: $0.date.formatted(.dateTime.weekday(.abbreviated)), count: $0.count)
            },
            hourlyActivity: loadedHourly.map {
                AdminWebAnalyticsHourPayload(hour: $0.hour, label: adminWebHourLabel($0.hour), count: $0.count)
            },
            topUsers: topUsers,
            feed: adminWebAnalyticsFeed(healthState: healthState, now: now),
            health: AdminWebAnalyticsHealthPayload(
                state: healthState.state,
                detail: healthState.detail,
                websocketLatencyMs: connectionDiagnostics.heartbeatLatencyMs,
                reconnectCount: status == .reconnecting ? 1 : 0,
                activeTasks: activeTaskCount,
                eventQueueDepth: queueDepth,
                eventQueueLoad: queueLoad,
                memoryText: adminWebMemoryText()
            ),
            insights: adminWebAnalyticsInsights(
                dailyActivity: loadedDaily,
                healthState: healthState.state,
                automationFailures: automationFailures,
                commandsToday: commandsToday,
                watchedVideos: mediaPlaybackStarts,
                exportedClips: finishedExports
            )
        )
        payload.community = adminWebAnalyticsCommunity()
        return payload
    }

    private func adminWebAnalyticsHealthState(
        latencyMs: Int?,
        queueLoad: Double,
        failedCommandsToday: Int,
        automationFailures: Int
    ) -> (state: String, detail: String) {
        if status == .reconnecting {
            return ("recovering", "Gateway is reconnecting or stabilizing after disruption.")
        }
        if ConnectionDiagnostics.isGatewayHeartbeatCritical(latencyMs) || queueLoad >= 0.90 || failedCommandsToday >= 5 {
            return ("degraded", "Latency, queue, or failures indicate degraded operation.")
        }
        if ConnectionDiagnostics.isGatewayHeartbeatWarning(latencyMs)
            || queueLoad >= 0.70
            || automationFailures > 0
            || failedCommandsToday > 0 {
            return ("warning", "One operational signal is elevated and worth watching.")
        }
        return ("healthy", "Gateway, queue, and automation signals are nominal.")
    }

    private func adminWebAnalyticsFeed(
        healthState: (state: String, detail: String),
        now: Date
    ) -> [AdminWebAnalyticsFeedEntryPayload] {
        var output: [AdminWebAnalyticsFeedEntryPayload] = []

        output += events.prefix(8).map { event in
            AdminWebAnalyticsFeedEntryPayload(
                id: "event-\(event.id)",
                timestamp: event.timestamp,
                title: adminWebAnalyticsEventTitle(for: event.kind),
                detail: adminWebCleanEventMessage(event.message),
                category: adminWebAnalyticsEventCategory(for: event.kind),
                tone: adminWebAnalyticsEventTone(for: event.kind)
            )
        }

        output += commandLog.prefix(5).map { command in
            AdminWebAnalyticsFeedEntryPayload(
                id: "command-\(command.id)",
                timestamp: command.time,
                title: command.ok ? "Command executed" : "Command failed",
                detail: "\(command.user) ran \(command.command)",
                category: "command",
                tone: command.ok ? "usage" : "warning"
            )
        }

        output += voiceLog.prefix(4).map { voice in
            AdminWebAnalyticsFeedEntryPayload(
                id: "voice-\(voice.id)",
                timestamp: voice.time,
                title: "Voice activity",
                detail: adminWebCleanEventMessage(voice.description),
                category: "voice",
                tone: "usage"
            )
        }

        if let patchyLastCycleAt {
            output.append(AdminWebAnalyticsFeedEntryPayload(
                id: "patchy-\(patchyLastCycleAt.timeIntervalSince1970)",
                timestamp: patchyLastCycleAt,
                title: patchyIsCycleRunning ? "Automation running" : "Automation completed",
                detail: "Patchy update cycle processed",
                category: "automation",
                tone: "automation"
            ))
        }

        if healthState.state != "healthy" {
            output.append(AdminWebAnalyticsFeedEntryPayload(
                id: "health-\(healthState.state)-\(Int(now.timeIntervalSince1970 / 60))",
                timestamp: now,
                title: "\(healthState.state.capitalized) health state",
                detail: healthState.detail,
                category: "health",
                tone: healthState.state == "degraded" ? "danger" : "warning"
            ))
        }

        output.append(AdminWebAnalyticsFeedEntryPayload(
            id: "launch-\(launchedAt.timeIntervalSince1970)",
            timestamp: launchedAt,
            title: "Analytics pipeline initialized",
            detail: "SwiftBot runtime metrics are being aggregated",
            category: "system",
            tone: "healthy"
        ))

        return Array(output.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp > $1.timestamp
            }
            return $0.id < $1.id
        }.prefix(12))
    }

    private func adminWebAnalyticsInsights(
        dailyActivity: [(date: Date, count: Int)],
        healthState: String,
        automationFailures: Int,
        commandsToday: Int,
        watchedVideos: Int,
        exportedClips: Int
    ) -> [AdminWebAnalyticsInsightPayload] {
        var output: [AdminWebAnalyticsInsightPayload] = []
        let total = dailyActivity.reduce(0) { $0 + $1.count }
        let average = dailyActivity.isEmpty ? 0 : Double(total) / Double(dailyActivity.count)

        if let peak = dailyActivity.max(by: { $0.count < $1.count }), peak.count >= 1, average > 0 {
            let lift = Int(((Double(peak.count) - average) / max(average, 1)) * 100)
            output.append(AdminWebAnalyticsInsightPayload(
                title: "\(peak.date.formatted(.dateTime.weekday(.wide))) led activity",
                body: lift > 0 ? "\(lift)% above the 7-day average." : "Matched the current 7-day average.",
                tone: "usage"
            ))
        }

        output.append(AdminWebAnalyticsInsightPayload(
            title: healthState == "healthy" ? "System health is stable" : "Health state needs attention",
            body: healthState == "healthy"
                ? "Gateway, queue, and automation signals are nominal."
                : "Review latency, queue depth, and failed operations.",
            tone: healthState == "healthy" ? "healthy" : "warning"
        ))

        if automationFailures > 0 {
            output.append(AdminWebAnalyticsInsightPayload(
                title: "Automation warnings detected",
                body: "\(automationFailures) automation-related warning events are present.",
                tone: "warning"
            ))
        } else {
            output.append(AdminWebAnalyticsInsightPayload(
                title: "Automation pipeline is quiet",
                body: "No failed automation events are currently reported.",
                tone: "automation"
            ))
        }

        if commandsToday > 0 {
            output.append(AdminWebAnalyticsInsightPayload(
                title: "Command traffic is active",
                body: "\(commandsToday) commands have been processed today.",
                tone: "usage"
            ))
        }

        if watchedVideos > 0 || exportedClips > 0 {
            output.append(AdminWebAnalyticsInsightPayload(
                title: "Recording activity is flowing",
                body: "\(watchedVideos) playback sessions and \(exportedClips) completed exports have been observed in this runtime.",
                tone: "usage"
            ))
        }

        return output
    }

    private func adminWebDeterministicMostActiveDay(from dailyActivity: [(date: Date, count: Int)]) -> String {
        let activeDays = dailyActivity
            .filter { $0.count >= 1 }
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0.date < $1.date
            }
        return activeDays.first?.date.formatted(.dateTime.weekday(.wide)) ?? "-"
    }

    private func adminWebPeakDayDetail(from dailyActivity: [(date: Date, count: Int)]) -> String {
        guard let peak = dailyActivity.max(by: { $0.count < $1.count }), peak.count >= 1 else {
            return "No completed sessions this week"
        }
        return "\(peak.count) sessions on \(peak.date.formatted(.dateTime.weekday(.wide)))"
    }

    private func adminWebAnalyticsEventTitle(for kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .voiceJoin: return "Voice session started"
        case .voiceLeave: return "Voice session ended"
        case .voiceMove: return "Voice channel changed"
        case .command: return "Command executed"
        case .info: return "System event"
        case .warning: return "Operational warning"
        case .error: return "Operational error"
        }
    }

    private func adminWebAnalyticsEventCategory(for kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .voiceJoin, .voiceLeave, .voiceMove: return "voice"
        case .command: return "command"
        case .warning, .error: return "health"
        case .info: return "system"
        }
    }

    private func adminWebAnalyticsEventTone(for kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .warning: return "warning"
        case .error: return "danger"
        case .command, .voiceJoin, .voiceLeave, .voiceMove: return "usage"
        case .info: return "healthy"
        }
    }

    private func adminWebCleanEventMessage(_ message: String) -> String {
        ["🟢 ", "🔴 ", "🔀 ", "✅ ", "⚠️ ", "❌ "].reduce(message) { cleaned, marker in
            cleaned.replacingOccurrences(of: marker, with: "")
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func adminWebActivityShare(seconds: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(seconds) / Double(total) * 100).rounded())
    }

    private func adminWebInitials(for username: String) -> String {
        let pieces = username.split(separator: " ").prefix(2)
        let letters = pieces.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private func adminWebHourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case let hourBeforeNoon where hourBeforeNoon < 12: return "\(hourBeforeNoon)a"
        default: return "\(hour - 12)p"
        }
    }

    private func adminWebFormatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    private func adminWebMemoryText() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(info.resident_size), countStyle: .memory)
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
                prefixEnabled: false,
                slashEnabled: settings.slashCommandsEnabled,
                bugTrackingEnabled: false,
                prefix: "/"
            ),
            appleIntelligence: .init(
                localAIDMReplyEnabled: settings.localAIDMReplyEnabled,
                useAIInGuildChannels: settings.behavior.useAIInGuildChannels,
                allowDMs: settings.behavior.allowDMs,
                localAISystemPrompt: settings.localAISystemPrompt
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
                leaderPort: settings.clusterLeaderPort,
                listenPort: settings.clusterListenPort,
                workerOffloadEnabled: settings.clusterWorkerOffloadEnabled,
                offloadAIReplies: settings.clusterOffloadAIReplies,
                offloadWikiLookups: settings.clusterOffloadWikiLookups,
                autoReclaimAfterHours: settings.clusterAutoReclaimAfterHours
            ),
            general: .init(
                autoStart: settings.autoStart,
                webUIEnabled: settings.adminWebUI.enabled,
                webUIBaseURL: adminWebBaseURL(),
                // resolvedClientID is only filled by onboarding or the native
                // invite button; the bot's user ID is its application ID, so
                // fall back to it once connected (same as resolveClientID does).
                inviteURL: (resolvedClientID ?? botUserId).flatMap {
                    service.generateInviteURL(
                        clientId: $0,
                        includeSlashCommands: settings.commandsEnabled && settings.slashCommandsEnabled
                    )
                },
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                hostName: settings.clusterNodeName,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                macModel: MacHardwareInfo.summary
            ),
            userTimezones: .init(
                mappings: settings.userTimezones,
                members: discordMemberOptions.map { .init(id: $0.id, name: $0.displayName, username: $0.username) }
            ),
            swiftMiner: .init(enabled: settings.swiftMiner.enabled, paired: settings.swiftMiner.isPaired)
        )
    }

    func applyAdminWebConfigPatch(_ patch: AdminWebConfigPatch) -> Bool {
        if let value = patch.commandsEnabled { settings.commandsEnabled = value }
        if let value = patch.slashCommandsEnabled { settings.slashCommandsEnabled = value }
        if let value = patch.localAIDMReplyEnabled { settings.localAIDMReplyEnabled = value }
        if let value = patch.useAIInGuildChannels { settings.behavior.useAIInGuildChannels = value }
        if let value = patch.allowDMs { settings.behavior.allowDMs = value }
        if let value = patch.aiActivityAnswersEnabled { settings.aiActivityAnswersEnabled = value }
        if let value = patch.localAISystemPrompt {
            settings.localAISystemPrompt = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = patch.wikiBridgeEnabled { settings.wikiBot.isEnabled = value }
        if let value = patch.patchyMonitoringEnabled { settings.patchy.monitoringEnabled = value }
        if let value = patch.clusterMode,
           let mode = ClusterMode(rawValue: value) {
            settings.clusterMode = mode
        }
        if let value = patch.clusterNodeName { settings.clusterNodeName = value }
        if let value = patch.clusterLeaderAddress { settings.clusterLeaderAddress = value }
        if let value = patch.clusterLeaderPort { settings.clusterLeaderPort = max(1, value) }
        if let value = patch.clusterListenPort { settings.clusterListenPort = max(1, value) }
        if let value = patch.clusterWorkerOffloadEnabled { settings.clusterWorkerOffloadEnabled = value }
        if let value = patch.clusterOffloadAIReplies { settings.clusterOffloadAIReplies = value }
        if let value = patch.clusterOffloadWikiLookups { settings.clusterOffloadWikiLookups = value }
        if let value = patch.clusterAutoReclaimAfterHours {
            settings.clusterAutoReclaimAfterHours = min(72, max(0, value))
        }
        if let value = patch.autoStart { settings.autoStart = value }
        if let value = patch.userTimezones {
            settings.userTimezones = Dictionary(uniqueKeysWithValues: value.compactMap { userID, timezone in
                let trimmedID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedTimezone = timezone.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedID.isEmpty, !trimmedTimezone.isEmpty,
                      TimeZone(identifier: trimmedTimezone) != nil else { return nil }
                return (trimmedID, trimmedTimezone)
            })
        }
        if let value = patch.swiftMinerEnabled, settings.swiftMiner.isPaired {
            settings.swiftMiner.enabled = value
        }
        let includesMusicLinkWatchEdit = patch.musicLinkWatchEnabled != nil || patch.musicLinkWatchChannelIDs != nil
        if let value = patch.musicLinkWatchEnabled { settings.musicLinkWatch.isEnabled = value }
        if let values = patch.musicLinkWatchChannelIDs {
            settings.musicLinkWatch.channelIDs = Array(
                Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            ).sorted()
        }
        if includesMusicLinkWatchEdit, forwardsConfigEditsToPrimary {
            forwardConfigMutationToPrimary(
                .replaceMusicLinkWatch(settings.musicLinkWatch),
                revertOnFailure: true
            )
            return true
        }
        saveSettings()
        return true
    }

    /// Everything on the Analytics page that follows the period switch.
    func adminWebAnalyticsPeriod(_ period: AnalyticsPeriod, includeMessageText: Bool) async -> AdminWebAnalyticsPeriodPayload {
        typealias Ranked = AdminWebAnalyticsPeriodPayload.Ranked
        let now = Date()
        let buckets = period.buckets(now: now)
        let window = period.window(now: now)
        let previous = period.previousWindow(now: now)

        async let voiceReport = voiceSessionStore.report(period: period, now: now)
        async let community = communityStatsStore.summary(buckets: buckets, in: window)
        async let ranks = communityStatsStore.rankHistory(since: window.start)
        let rewindOn = settings.rewind.isEnabled
        let messages: RewindPeriodSummary? = rewindOn
            ? await rewindStore.periodSummary(buckets: buckets, window: window, previous: previous)
            : nil
        let voice = await voiceReport
        let stats = await community
        let rankHistory = await ranks

        let feed = ActivityFeed(app: self)
        func ranked(_ counts: [String: Int], name: (String) -> String = { $0 }, limit: Int = 5) -> [Ranked] {
            var merged: [String: Int] = [:]
            for (key, count) in counts {
                let title = name(key)
                guard !title.isEmpty else { continue }
                merged[title, default: 0] += count
            }
            return merged.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(limit).map { Ranked(title: $0.key, count: $0.value) }
        }
        let channelName: (String) -> String = { key in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? feed.friendlyTextChannelName(parts[1], server: parts[0]) : feed.friendlyTextChannelName(key, server: nil)
        }
        let inVoiceNow = Set(activeVoice.map(\.userId))

        // Clips per game from this Mac's library only, so a refresh never
        // waits on other mesh nodes.
        let library = await localMediaLibrarySnapshot()
        let clips = Dictionary(grouping: library.items.filter { window.contains($0.modifiedAt) }, by: { mediaGameName(for: $0.fileName) })
            .mapValues(\.count)

        return AdminWebAnalyticsPeriodPayload(
            period: period.rawValue,
            label: period.label,
            buckets: buckets.enumerated().map { index, bucket in
                let voiceBucket = voice.buckets.indices.contains(index) ? voice.buckets[index] : nil
                return .init(
                    label: bucket.label,
                    start: bucket.start,
                    voiceSessions: voiceBucket?.sessions ?? 0,
                    voiceMinutes: (voiceBucket?.seconds ?? 0) / 60,
                    commands: stats.commandsPerBucket[index],
                    messages: messages?.bucketCounts[index] ?? 0,
                    joins: stats.joinsPerBucket[index],
                    leaves: stats.leavesPerBucket[index]
                )
            },
            hourlyVoice: voice.hourly,
            hourlyMessages: messages?.hourly ?? Array(repeating: 0, count: 24),
            totals: .init(
                voiceSessions: voice.sessionCount,
                voiceSeconds: voice.totalSeconds,
                averageSessionSeconds: voice.sessionCount > 0 ? voice.totalSeconds / voice.sessionCount : 0,
                commands: stats.commandCount,
                failedCommands: stats.failedCommands,
                messages: messages?.totalMessages ?? 0,
                joins: stats.joins,
                leaves: stats.leaves,
                previousVoiceSessions: voice.previousSessionCount,
                previousVoiceSeconds: voice.previousTotalSeconds,
                previousMessages: messages?.previousMessages ?? 0
            ),
            topVoiceUsers: voice.topUsers.map { .init(name: $0.username, seconds: $0.seconds, sessions: $0.sessions, inVoiceNow: inVoiceNow.contains($0.userId)) },
            voiceChannels: voice.channels.map { Ranked(title: $0.name, count: $0.seconds / 60) },
            topCommands: ranked(stats.commands),
            topCommandUsers: ranked(stats.users, name: feed.friendlyUserName),
            topPosters: (messages?.topUsers ?? []).map { Ranked(title: knownUsersById[$0.userID] ?? $0.userName, count: $0.count) },
            messageChannels: (messages?.topChannels ?? []).map { Ranked(title: feed.friendlyTextChannelName($0.term, server: nil), count: $0.count) },
            topWords: includeMessageText ? (messages?.topWords ?? []).map { Ranked(title: $0.term, count: $0.count) } : nil,
            topEmoji: includeMessageText ? (messages?.topEmoji ?? []).map { Ranked(title: $0.term, count: $0.count) } : nil,
            streak: voice.currentStreak.map { .init(name: $0.username, days: $0.days) },
            rankSeries: rankHistory.values
                .sorted { $0.displayName < $1.displayName }
                .map { .init(name: $0.displayName, game: $0.game, points: $0.points.map { .init(date: $0.date, score: $0.score, rankName: $0.rankName) }) },
            clipsByGame: ranked(clips),
            messagesAvailable: rewindOn && (messages?.hasArchive ?? false),
            rewindEnabled: rewindOn,
            featureUses: stats.featureUses
        )
    }

    /// Same rankings as the native Analytics view (command log for commands,
    /// people and channels; voice log for voice channels).
    func adminWebAnalyticsCommunity() -> AdminWebAnalyticsCommunityPayload {
        let feed = ActivityFeed(app: self)
        func ranked(_ values: [String], limit: Int = 5) -> [AdminWebAnalyticsCommunityPayload.Ranked] {
            Dictionary(grouping: values.filter { !$0.isEmpty }, by: { $0 })
                .map { .init(title: $0.key, count: $0.value.count) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.title < $1.title }
                .prefix(limit)
                .map { $0 }
        }
        let commandName: (String) -> String = { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
        }
        let voiceChannels = voiceLog.compactMap { entry -> String? in
            for marker in [" joined ", " left "] {
                if let range = entry.description.range(of: marker) {
                    return String(entry.description[range.upperBound...]).components(separatedBy: " — ").first
                }
            }
            return nil
        }
        return AdminWebAnalyticsCommunityPayload(
            inVoice: activeVoice
                .sorted { $0.joinedAt < $1.joinedAt }
                .map { .init(username: $0.username, channelName: $0.channelName, since: $0.joinedAt) },
            topCommands: ranked(commandLog.map { commandName($0.command) }),
            topCommandUsers: ranked(commandLog.map { feed.friendlyUserName($0.user) }),
            topChannels: ranked(commandLog.map { feed.friendlyTextChannelName($0.channel, server: $0.server) }),
            topVoiceChannels: ranked(voiceChannels)
        )
    }

    func adminWebActivitySnapshot(limit: Int) -> AdminWebActivityPayload {
        let all = ActivityFeed(app: self).entries()
        let entries = all.prefix(limit).map { entry in
            AdminWebActivityPayload.Entry(
                id: entry.id,
                time: entry.time,
                kind: String(describing: entry.kind),
                level: String(describing: entry.level),
                category: ActivityCategory.infer(from: entry).rawValue,
                title: entry.title,
                detail: entry.detail
            )
        }
        return AdminWebActivityPayload(entries: Array(entries), totalCount: all.count)
    }

    func adminWebAccessSnapshot() -> AdminWebAccessPayload {
        let web = settings.adminWebUI
        var payload = AdminWebAccessPayload(
            restrictToListedUsers: web.restrictAccessToSpecificUsers,
            allowedUserIDs: web.normalizedAllowedUserIDs,
            members: discordMemberOptions.map { .init(id: $0.id, name: $0.displayName, username: $0.username) },
            localFallbackEnabled: web.localAuthEnabled
                && !web.localAuthUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !web.localAuthPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        payload.memberAccessEnabled = web.memberAccessEnabled
        return payload
    }

    /// Turning it off signs current members out (see AdminWebServer.configure).
    func applyAdminWebMemberAccess(_ enabled: Bool) async -> Bool {
        guard !isFailoverManagedNode else { return false }
        settings.adminWebUI.memberAccessEnabled = enabled
        saveSettings()
        await configureAdminWebServer()
        return true
    }

    /// Guards already ran in AdminWebServer; this saves and pushes the new
    /// list to the running server, which signs out anyone no longer listed.
    /// Access is per node, so a failover-managed node still refuses edits.
    func applyAdminWebAccessUpdate(_ update: AdminWebAccessUpdate) async -> Bool {
        guard !isFailoverManagedNode else { return false }
        settings.adminWebUI.restrictAccessToSpecificUsers = update.restrictToListedUsers
        settings.adminWebUI.allowedUserIDs = update.normalizedIDs
        saveSettings()
        await configureAdminWebServer()
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
                category: SlashCommandGroup.forCommand(name).rawValue,
                surface: "slash",
                aliases: [],
                adminOnly: name == "debug"
            )
        }
        let commands = slashCommands

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
            prefixCommandsEnabled: false,
            slashCommandsEnabled: settings.slashCommandsEnabled,
            items: items,
            musicLinkWatch: adminWebMusicLinkWatchSnapshot()
        )
    }

    private func adminWebMusicLinkWatchSnapshot() -> AdminWebMusicLinkWatchPayload {
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
        return AdminWebMusicLinkWatchPayload(
            isEnabled: settings.musicLinkWatch.isEnabled,
            channelIDs: settings.musicLinkWatch.channelIDs,
            servers: servers,
            textChannelsByServer: textChannelsByServer
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
            isCycleRunning: patchyIsCycleRunning,
            lastCycleAt: patchyLastCycleAt,
            sourceKinds: PatchySourceKind.allCases.map(\.rawValue),
            targets: settings.patchy.sourceTargets,
            servers: servers,
            textChannelsByServer: textChannelsByServer,
            rolesByServer: rolesByServer,
            steamAppNames: settings.patchy.steamAppNames,
            isFailoverManagedNode: isFailoverManagedNode,
            botStatus: status.rawValue
        )
    }

    /// Mirrors `AppleIntelligenceView` so the WebUI "AI Bots" page shows the
    /// same status, personality presets, reply rules, memory and capabilities
    /// as the native surface.
    func adminWebAIBotsSnapshot() -> AdminWebAIBotsPayload {
        let dmReplies = settings.localAIDMReplyEnabled
        let guildReplies = settings.behavior.useAIInGuildChannels
        let allowDMs = settings.behavior.allowDMs
        let selected = AppleIntelligencePersonality.matching(prompt: settings.localAISystemPrompt)

        let replyScope: String
        if dmReplies && guildReplies {
            replyScope = allowDMs ? "Mentions + DMs" : "Mentions + trusted DMs"
        } else if dmReplies {
            replyScope = "DMs Enabled"
        } else if guildReplies {
            replyScope = "Mentions Only"
        } else {
            replyScope = "Paused"
        }

        let repliesActive = dmReplies || guildReplies
        let summariesActive = settings.patchy.sourceTargets.contains {
            $0.isEnabled && $0.summarizeWithAppleIntelligence
        }
        let moderationActive = automationStore.rules.contains { $0.category == .moderation && $0.enabled }
        let threadActive = memoryViewModel.totalMessages > 0
        let online = appleIntelligenceOnline
        func status(_ isActive: Bool) -> String {
            if isActive { return "active" }
            return online ? "ready" : "off"
        }


        return AdminWebAIBotsPayload(
            online: online,
            modelName: online ? appleIntelligenceModelName : nil,
            replyScope: replyScope,
            dmRepliesEnabled: dmReplies,
            guildMentionRepliesEnabled: guildReplies,
            allowDMs: allowDMs,
            systemPrompt: settings.localAISystemPrompt,
            selectedPersonalityID: selected?.rawValue ?? "custom",
            isCustomPrompt: selected == nil,
            defaultPrompt: BotSettings.defaultAISystemPrompt,
            activityAnswersEnabled: settings.aiActivityAnswersEnabled,
            isFailoverManagedNode: isFailoverManagedNode,
            personalities: AppleIntelligencePersonality.allCases.map { personality in
                AdminWebAIBotsPayload.Personality(
                    id: personality.rawValue,
                    title: personality.title,
                    summary: personality.summaryValue,
                    description: personality.description,
                    preview: personality.preview,
                    prompt: personality.prompt,
                    icon: personality.webIcon,
                    tint: personality.webTint,
                    isSelected: personality == selected
                )
            },
            capabilities: [
                AdminWebAIBotsPayload.Capability(
                    id: "replies",
                    title: "Replies",
                    description: "Answers DMs and mentions using the selected personality.",
                    icon: "message-square",
                    tint: "blue",
                    status: status(repliesActive)
                ),
                AdminWebAIBotsPayload.Capability(
                    id: "summaries",
                    title: "Summaries",
                    description: "Creates concise on-device summaries for long updates.",
                    icon: "file-search",
                    tint: "indigo",
                    status: status(summariesActive)
                ),
                AdminWebAIBotsPayload.Capability(
                    id: "moderation",
                    title: "Moderation Assist",
                    description: "Supports moderation rules that use generated context.",
                    icon: "shield-check",
                    tint: "orange",
                    status: status(moderationActive)
                ),
                AdminWebAIBotsPayload.Capability(
                    id: "threadCatchUp",
                    title: "Thread Catch-up",
                    description: "Uses remembered context to make replies less repetitive.",
                    icon: "history",
                    tint: "green",
                    status: status(threadActive)
                )
            ],
            memory: AdminWebAIBotsPayload.Memory(
                totalMessages: memoryViewModel.totalMessages,
                conversations: memoryViewModel.summaries.map { summary in
                    AdminWebAIBotsPayload.Conversation(
                        id: summary.id,
                        scopeID: summary.scope.id,
                        scopeType: summary.scope.type.rawValue,
                        title: memoryViewModel.displayName(for: summary),
                        messageCount: summary.messageCount
                    )
                }
            )
        )
    }

    /// One reply for the Settings "Try it" box, using the instructions being
    /// edited. Nothing is saved and conversation memory isn't touched.
    func tryAdminWebAIReply(_ request: AdminWebAITryRequest) async -> String? {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = Message(
            channelID: "admin-web-try",
            userID: request.askerID ?? "admin-web",
            username: "Admin",
            content: request.message.trimmingCharacters(in: .whitespacesAndNewlines),
            role: .user
        )
        // Same activity facts a real reply would get, across every server.
        let facts = await aiActivityContext(question: message.content, askerID: request.askerID, guildID: nil)
        let instructions = prompt.isEmpty ? settings.localAISystemPrompt : prompt
        return await aiService.generateHelpReply(
            messages: [message],
            systemPrompt: facts.isEmpty ? instructions : instructions + "\n\n" + facts
        )
    }

    func clearAdminWebAIMemory(_ patch: AdminWebAIMemoryClearPatch) async -> Bool {
        let store = memoryViewModel.store
        let scopeID = patch.scopeID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if scopeID.isEmpty {
            await store.clearAll()
        } else {
            guard let rawType = patch.scopeType,
                  let type = MemoryScopeType(rawValue: rawType) else { return false }
            await store.clear(scope: MemoryScope(id: scopeID, type: type))
        }
        await memoryViewModel.reloadSummaries()
        return true
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
        saveSettings()
        return true
    }

    func createAdminWebPatchyTarget() -> PatchySourceTarget? {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let serverID = serverIDs.first ?? ""
        let textChannelID = availableTextChannelsByServer[serverID]?.first?.id ?? ""

        // 'Add once' logic for drivers: pick the first driver source not already configured.
        let existingSources = Set(settings.patchy.sourceTargets.map(\.source))
        let driverOptions: [PatchySourceKind] = [.nvidia, .amd, .intel]
        let source = driverOptions.first(where: { !existingSources.contains($0) }) ?? .steam

        let target = PatchySourceTarget(
            id: UUID(),
            isEnabled: true,
            source: source,
            steamAppID: source == .steam ? PatchyDefaults.steamAppID : "",
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

    func sendAdminWebPatchyTest(_ targetID: UUID) async -> PatchyTestOutcome {
        await runPatchyTest(targetID: targetID)
    }

    func pullAdminWebPatchyTarget(_ targetID: UUID) -> Bool {
        pullPatchyUpdate(targetID: targetID)
        return true
    }

    func runAdminWebPatchyCheckNow() -> Bool {
        runPatchyManualCheck()
        return true
    }

    // MARK: - Admin Web: Automations snapshot

    func adminWebAutomationsSnapshot(category: Automations.Category) -> AdminWebAutomationsPayload {
        // Make sure the store has been loaded at least once.
        if !automationStore.isLoaded { automationStore.load() }

        let rules = automationStore.rules.filter { $0.category == category }
        let enabledCount = rules.filter(\.enabled).count
        let triggerKinds = Set(rules.map(\.trigger.kind)).count

        // Server context — same shape automationServerContext() returns,
        // converted into the wire format.
        let ctx = automationServerContext()
        let webCtx = AdminWebAutomationServerContext(
            guildName: ctx.guildName,
            guildId: ctx.guildId,
            textChannels: ctx.textChannels.map { AdminWebSimpleOption(id: $0.id, name: $0.name) },
            voiceChannels: ctx.voiceChannels.map { AdminWebSimpleOption(id: $0.id, name: $0.name) },
            roles: ctx.roles.map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
        )

        let templates = AutomationTemplate.catalog(for: category).map { tpl in
            AdminWebAutomationTemplate(
                id: tpl.id,
                title: tpl.title,
                subtitle: tpl.subtitle,
                symbol: tpl.symbol,
                tint: Self.tintRawValue(tpl.tint),
                rule: tpl.rule
            )
        }

        return AdminWebAutomationsPayload(
            category: category.rawValue,
            rules: rules,
            templates: templates,
            serverContext: webCtx,
            metrics: AdminWebAutomationMetrics(
                total: rules.count,
                enabled: enabledCount,
                triggerKinds: triggerKinds
            )
        )
    }

    private static func tintRawValue(_ tint: AutomationTemplate.TemplateTint) -> String {
        switch tint {
        case .blue:    return "blue"
        case .green:   return "green"
        case .purple:  return "purple"
        case .orange:  return "orange"
        case .red:     return "red"
        case .indigo:  return "indigo"
        }
    }

    func adminWebWelcomeFlowSnapshot() -> AdminWebWelcomeFlowPayload {
        let ctx = automationServerContext()
        let webCtx = AdminWebAutomationServerContext(
            guildName: ctx.guildName,
            guildId: ctx.guildId,
            textChannels: ctx.textChannels.map { AdminWebSimpleOption(id: $0.id, name: $0.name) },
            voiceChannels: ctx.voiceChannels.map { AdminWebSimpleOption(id: $0.id, name: $0.name) },
            roles: ctx.roles.map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
        )
        let flow = settings.welcomeFlow
        let safetyEnabled = flow.skipBots || flow.minAccountAgeDays > 0
        let activeRules = [
            flow.publicWelcomeEnabled,
            flow.dmWelcomeEnabled,
            !flow.activeNextStepRules.isEmpty,
            safetyEnabled,
            flow.goodbyeEnabled
        ].filter { $0 }.count

        return AdminWebWelcomeFlowPayload(
            settings: flow,
            serverContext: webCtx,
            metrics: AdminWebWelcomeFlowMetrics(
                activeRules: activeRules,
                inviteRules: flow.nextStepRules.count,
                safetyEnabled: safetyEnabled
            ),
            invites: (ctx.guildId.flatMap { welcomeFlowInvitesByServer[$0] } ?? []).map {
                AdminWebWelcomeInvite(code: $0.code, channelName: $0.channelName, uses: $0.uses)
            }
        )
    }

    func updateAdminWebWelcomeFlow(_ flow: WelcomeFlowSettings) -> Bool {
        settings.welcomeFlow = flow
        saveSettings()
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
    func adminWebOAuthBaseURL() -> String {
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

    func adminWebDiscordRedirectURL() -> String {
        adminWebOAuthRedirectURL(
            baseURL: adminWebOAuthBaseURL(),
            redirectPath: normalizedAdminRedirectPath(settings.adminWebUI.redirectPath)
        )
    }

    func configureAdminWebServer() async {
        guard !Self.isRunningUnderXCTest else {
            await adminWebServer.stop()
            adminWebResolvedBaseURL = ""
            adminWebPublicAccessStatus = AdminWebPublicAccessRuntimeStatus()
            return
        }

        let httpsConfiguration = usesLocalRuntime ? await resolveAdminWebHTTPSConfiguration() : nil
        // Cloudflare Internet Access terminates TLS at the edge and forwards to
        // SwiftBot's loopback-only HTTP origin. In that mode, HTTPS is still
        // required for public traffic, but the local listener must be allowed
        // to start without its own certificate.
        let requireLocalHTTPS = settings.adminWebUI.requireHTTPS
            && !settings.adminWebUI.internetAccessEnabled
        let config = AdminWebServer.Configuration(
            enabled: usesLocalRuntime && settings.adminWebUI.enabled,
            bindHost: settings.adminWebUI.bindHost,
            port: settings.adminWebUI.port,
            publicBaseURL: adminWebOAuthBaseURL(),
            https: httpsConfiguration,
            requireHTTPS: requireLocalHTTPS,
            discordOAuth: settings.adminWebUI.discordOAuth,
            localAuthEnabled: settings.adminWebUI.localAuthEnabled,
            localAuthUsername: settings.adminWebUI.localAuthUsername,
            localAuthPassword: settings.adminWebUI.localAuthPassword,
            redirectPath: normalizedAdminRedirectPath(settings.adminWebUI.redirectPath),
            allowedUserIDs: settings.adminWebUI.restrictAccessToSpecificUsers
                ? settings.adminWebUI.normalizedAllowedUserIDs
                : [],
            devFeaturesEnabled: {
                #if DEBUG
                return true
                #else
                return false
                #endif
            }(),
            memberAccessEnabled: settings.adminWebUI.memberAccessEnabled
        )

        let runtimeState = await adminWebServer.configure(
            config: config,
            statusProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebStatusPayload(
                        botStatus: "stopped",
                        botUsername: "SwiftBot",
                        botAvatarURL: nil,
                        connectedServerCount: 0,
                        gatewayEventCount: 0,
                        uptimeText: nil,
                        webUIEnabled: false,
                        webUIBaseURL: "",
                        clusterMode: nil,
                        runtimeState: nil,
                        isFailoverManagedNode: false
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
            updateRemoteRule: { _ in
                // Remote rule sync is offline pending a port to AutomationStore.
                return false
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
                        commands: .init(enabled: true, prefixEnabled: false, slashEnabled: true, bugTrackingEnabled: false, prefix: "/"),
                        appleIntelligence: .init(localAIDMReplyEnabled: false, useAIInGuildChannels: false, allowDMs: false, localAISystemPrompt: ""),
                        wikiBridge: .init(enabled: false, enabledSources: 0, totalSources: 0),
                        patchy: .init(monitoringEnabled: false, enabledTargets: 0, totalTargets: 0),
                        swiftMesh: .init(mode: ClusterMode.standalone.rawValue, nodeName: "SwiftBot", leaderAddress: "", leaderPort: 38787, listenPort: 38787, workerOffloadEnabled: false, offloadAIReplies: false, offloadWikiLookups: false, autoReclaimAfterHours: 0),
                        general: .init(autoStart: false, webUIEnabled: false, webUIBaseURL: ""),
                        userTimezones: .init(mappings: [:]),
                        swiftMiner: .init(enabled: false, paired: false)
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
            analyticsProvider: { [weak self] period, includeMessageText in
                guard let model = self else {
                    return AdminWebAnalyticsPayload.empty
                }
                var payload = await model.adminWebAnalyticsSnapshot()
                payload.period = await model.adminWebAnalyticsPeriod(period, includeMessageText: includeMessageText)
                return payload
            },
            rewindProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebRewindPayload.empty
                }
                return await model.adminWebRewindSnapshot()
            },
            connectedGuildIDsProvider: { [weak self] in
                guard let model = self else { return [] }
                return await MainActor.run { Set(model.connectedServers.keys) }
            },
            currentPrefixProvider: {
                "/"
            },
            updatePrefix: { prefix in
                _ = prefix
                return false
            },
            configProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebConfigPayload(
                        commands: .init(enabled: true, prefixEnabled: false, slashEnabled: true, bugTrackingEnabled: false, prefix: "/"),
                        appleIntelligence: .init(localAIDMReplyEnabled: false, useAIInGuildChannels: false, allowDMs: false, localAISystemPrompt: ""),
                        wikiBridge: .init(enabled: false, enabledSources: 0, totalSources: 0),
                        patchy: .init(monitoringEnabled: false, enabledTargets: 0, totalTargets: 0),
                        swiftMesh: .init(mode: ClusterMode.standalone.rawValue, nodeName: "SwiftBot", leaderAddress: "", leaderPort: 38787, listenPort: 38787, workerOffloadEnabled: false, offloadAIReplies: true, offloadWikiLookups: true, autoReclaimAfterHours: 0),
                        general: .init(autoStart: false, webUIEnabled: false, webUIBaseURL: ""),
                        userTimezones: .init(mappings: [:]),
                        swiftMiner: .init(enabled: false, paired: false)
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
                        prefixCommandsEnabled: false,
                        slashCommandsEnabled: true,
                        items: [],
                        musicLinkWatch: AdminWebMusicLinkWatchPayload(
                            isEnabled: false,
                            channelIDs: [],
                            servers: [],
                            textChannelsByServer: [:]
                        )
                    )
                }
                return await MainActor.run { model.adminWebCommandCatalogSnapshot() }
            },
            updateCommandEnabled: { [weak self] name, surface, enabled in
                guard let model = self else { return false }
                return await MainActor.run { model.updateAdminWebCommandEnabled(name: name, surface: surface, enabled: enabled) }
            },
            automationsProvider: { [weak self] category in
                guard let model = self else {
                    return AdminWebAutomationsPayload(
                        category: category.rawValue,
                        rules: [],
                        templates: [],
                        serverContext: AdminWebAutomationServerContext(guildName: nil, guildId: nil, textChannels: [], voiceChannels: [], roles: []),
                        metrics: AdminWebAutomationMetrics(total: 0, enabled: 0, triggerKinds: 0)
                    )
                }
                return await MainActor.run { model.adminWebAutomationsSnapshot(category: category) }
            },
            upsertAutomation: { [weak self] rule in
                guard let model = self else { return false }
                return await MainActor.run {
                    model.applyAutomationUpsert(rule)
                    return true
                }
            },
            deleteAutomation: { [weak self] id in
                guard let model = self else { return false }
                return await MainActor.run {
                    model.applyAutomationRemove(id: id)
                    return true
                }
            },
            toggleAutomation: { [weak self] id in
                guard let model = self else { return false }
                return await MainActor.run {
                    model.applyAutomationToggle(id: id)
                    return true
                }
            },
            draftAutomation: { [weak self] prompt, category in
                guard let model = self else {
                    return AdminWebAutomationDraftPayload(
                        rule: nil,
                        error: "Automations drafting is unavailable.",
                        unavailableReason: nil
                    )
                }
                let task = await MainActor.run {
                    Task { @MainActor in
                        do {
                            var rule = try await model.automationDrafter.draft(
                                prompt: prompt,
                                context: model.automationServerContext()
                            )
                            rule.category = category
                            return AdminWebAutomationDraftPayload(rule: rule, error: nil, unavailableReason: nil)
                        } catch {
                            return AdminWebAutomationDraftPayload(
                                rule: nil,
                                error: error.localizedDescription,
                                unavailableReason: model.automationDrafter.unavailabilityReason
                            )
                        }
                    }
                }
                return await task.value
            },
            welcomeFlowProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebWelcomeFlowPayload(
                        settings: WelcomeFlowSettings(),
                        serverContext: AdminWebAutomationServerContext(guildName: nil, guildId: nil, textChannels: [], voiceChannels: [], roles: []),
                        metrics: AdminWebWelcomeFlowMetrics(activeRules: 0, inviteRules: 0, safetyEnabled: false)
                    )
                }
                return await MainActor.run { model.adminWebWelcomeFlowSnapshot() }
            },
            updateWelcomeFlow: { [weak self] flow in
                guard let model = self else { return false }
                return await MainActor.run { model.updateAdminWebWelcomeFlow(flow) }
            },
            announcerProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebAnnouncerPayload(
                        configs: [],
                        servers: [],
                        textChannelsByServer: [:],
                        voiceChannelsByServer: [:],
                        guildID: "",
                        voiceChannelID: "",
                        watchedTextChannelID: "",
                        preferredVoiceIdentifier: "",
                        textChannelSourceEnabled: false,
                        autoConnect: false,
                        installedVoices: [],
                        liveState: AdminWebAnnouncerLiveState(
                            isConnected: false,
                            connectionLabel: "Disconnected",
                            phaseLabel: VoiceAnnouncerPhase.idle.displayLabel,
                            listening: "Not listening",
                            monitoredFeeds: "No feeds configured",
                            queueDepth: 0,
                            queueLabel: "No queued announcements",
                            manualHold: nil,
                            recovery: nil
                        )
                    )
                }
                return await MainActor.run {
                    let serverIDs = model.connectedServers.keys.sorted {
                        (model.connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(model.connectedServers[$1] ?? $1) == .orderedAscending
                    }
                    let servers = serverIDs.map { AdminWebSimpleOption(id: $0, name: model.connectedServers[$0] ?? $0) }
                    let textChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
                        let channels = (model.availableTextChannelsByServer[serverID] ?? [])
                            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                            .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
                        return (serverID, channels)
                    })
                    let voiceChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
                        let channels = (model.availableVoiceChannelsByServer[serverID] ?? [])
                            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                            .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
                        return (serverID, channels)
                    })

                    let installedVoices = VoiceTTSSource.selectableVoiceOptions()
                        .map { AdminWebSimpleOption(id: $0.identifier, name: $0.label) }

                    return AdminWebAnnouncerPayload(
                        configs: model.settings.voice.announcerConfigs,
                        servers: servers,
                        textChannelsByServer: textChannelsByServer,
                        voiceChannelsByServer: voiceChannelsByServer,
                        guildID: model.settings.voice.guildID,
                        voiceChannelID: model.settings.voice.voiceChannelID,
                        watchedTextChannelID: model.settings.voice.watchedTextChannelID,
                        preferredVoiceIdentifier: model.settings.voice.preferredVoiceIdentifier,
                        textChannelSourceEnabled: model.settings.voice.textChannelSourceEnabled,
                        autoConnect: model.settings.voice.autoConnect,
                        installedVoices: installedVoices,
                        liveState: model.adminWebAnnouncerLiveState()
                    )
                }
            },
            upsertAnnouncerConfig: { [weak self] config in
                guard let model = self else { return false }
                return await MainActor.run {
                    var current = model.settings.voice.announcerConfigs
                    if let index = current.firstIndex(where: { $0.id == config.id }) {
                        current[index] = config
                    } else {
                        current.append(config)
                    }
                    model.settings.voice.announcerConfigs = current
                    model.saveSettings()
                    return true
                }
            },
            deleteAnnouncerConfig: { [weak self] id in
                guard let model = self else { return false }
                return await MainActor.run {
                    var current = model.settings.voice.announcerConfigs
                    current.removeAll { $0.id == id }
                    model.settings.voice.announcerConfigs = current
                    model.saveSettings()
                    return true
                }
            },
            toggleAnnouncerConfig: { [weak self] id, enabled in
                guard let model = self else { return false }
                return await MainActor.run {
                    var current = model.settings.voice.announcerConfigs
                    if let index = current.firstIndex(where: { $0.id == id }) {
                        current[index].enabled = enabled
                        model.settings.voice.announcerConfigs = current
                        model.saveSettings()
                        return true
                    }
                    return false
                }
            },
            updateAnnouncerSettings: { [weak self] patch in
                guard let model = self else { return false }
                await MainActor.run {
                    if let guildID = patch.guildID {
                        model.settings.voice.guildID = guildID
                    }
                    if let voiceChannelID = patch.voiceChannelID {
                        model.settings.voice.voiceChannelID = voiceChannelID
                    }
                    if let watchedTextChannelID = patch.watchedTextChannelID {
                        model.settings.voice.watchedTextChannelID = watchedTextChannelID
                    }
                    if let preferredVoiceIdentifier = patch.preferredVoiceIdentifier {
                        model.settings.voice.preferredVoiceIdentifier = preferredVoiceIdentifier
                    }
                    if let textChannelSourceEnabled = patch.textChannelSourceEnabled {
                        model.settings.voice.textChannelSourceEnabled = textChannelSourceEnabled
                    }
                    if let autoConnect = patch.autoConnect {
                        model.settings.voice.autoConnect = autoConnect
                    }
                    model.saveSettings()
                }

                let watcher = await MainActor.run { model.textChannelAnnouncer }
                if let watcher, let watchedTextChannelID = patch.watchedTextChannelID {
                    var channelIDs = watchedTextChannelID.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    let voiceChannelID = await MainActor.run { model.settings.voice.voiceChannelID }
                    if !voiceChannelID.isEmpty {
                        channelIDs.append(voiceChannelID)
                    }
                    await watcher.setWatchedChannels(channelIDs)
                }
                return true
            },
            disconnectAnnouncer: { [weak self] in
                guard let model = self else { return false }
                return await model.adminWebDisconnectAnnouncer()
            },
            patchyProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebPatchyPayload(
                        monitoringEnabled: false,
                        isCycleRunning: false,
                        lastCycleAt: nil,
                        sourceKinds: PatchySourceKind.allCases.map(\.rawValue),
                        targets: [],
                        servers: [],
                        textChannelsByServer: [:],
                        rolesByServer: [:],
                        steamAppNames: [:],
                        isFailoverManagedNode: false,
                        botStatus: "stopped"
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
                guard let model = self else { return PatchyTestOutcome(ok: false, message: "SwiftBot is shutting down.") }
                return await model.sendAdminWebPatchyTest(targetID)
            },
            pullPatchyTarget: { [weak self] targetID in
                guard let model = self else { return false }
                return await MainActor.run { model.pullAdminWebPatchyTarget(targetID) }
            },
            runPatchyCheckNow: { [weak self] in
                guard let model = self else { return false }
                return await MainActor.run { model.runAdminWebPatchyCheckNow() }
            },
            aiBotsProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebAIBotsPayload(
                        online: false,
                        replyScope: "Paused",
                        dmRepliesEnabled: false,
                        guildMentionRepliesEnabled: false,
                        allowDMs: false,
                        systemPrompt: "",
                        selectedPersonalityID: AppleIntelligencePersonality.casual.rawValue,
                        isFailoverManagedNode: false,
                        personalities: [],
                        capabilities: [],
                        memory: .init(totalMessages: 0, conversations: [])
                    )
                }
                return await MainActor.run { model.adminWebAIBotsSnapshot() }
            },
            clearAIMemory: { [weak self] patch in
                guard let model = self else { return false }
                return await model.clearAdminWebAIMemory(patch)
            },
            tryAIReply: { [weak self] request in
                guard let model = self else { return nil }
                return await model.tryAdminWebAIReply(request)
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
            mediaStreamProvider: { [weak self] token, rangeHeader, quality in
                guard let model = self else { return nil }
                return await model.adminWebMediaStreamResponse(token: token, rangeHeader: rangeHeader, quality: quality)
            },
            mediaHLSPlaylistProvider: { [weak self] token, accessToken in
                guard let model = self else { return nil }
                return await model.adminWebMediaHLSPlaylistResponse(token: token, accessToken: accessToken)
            },
            mediaHLSSegmentProvider: { [weak self] token, segment, accessToken in
                guard let model = self else { return nil }
                return await model.adminWebMediaHLSSegmentResponse(token: token, segment: segment, accessToken: accessToken)
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
            mediaPlaybackRecorder: { [weak self] patch in
                guard let model = self else { return false }
                return await model.adminWebRecordMediaPlayback(patch)
            },
            mediaClipExportStarter: { [weak self] request in
                guard let model = self else { return MediaExportJobResponse(job: nil, error: "Unavailable") }
                return await model.adminWebStartMediaClipExport(request: request)
            },
            mediaMultiViewExportStarter: { [weak self] request in
                guard let model = self else { return MediaExportJobResponse(job: nil, error: "Unavailable") }
                return await model.adminWebStartMediaMultiViewExport(request: request)
            },
            gameTrackerProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebGameTrackerPayload(
                        enabled: false, dailyCheckEnabled: false, sessionTrackingEnabled: false,
                        statusText: "Unavailable", statusTone: "gray",
                        configurationIssue: nil, checkInProgress: false, scheduleDescription: "Daily",
                        lastCheckAt: nil, nextCheckAt: nil, enabledPlayerCount: 0, totalPlayerCount: 0,
                        players: [], history: [], isPollingRuntime: false
                    )
                }
                return await MainActor.run { model.adminWebGameTrackerSnapshot() }
            },
            gameTrackerCheckRunner: { [weak self] in
                guard let model = self else { return false }
                await model.runGameTrackingCheck(trigger: "Web")
                return true
            },
            gameTrackerUpdater: { [weak self] update in
                guard let model = self else { return false }
                return await MainActor.run { model.applyAdminWebGameTrackerUpdate(update) }
            },
            gameTrackerStylePreviewer: { [weak self] style in
                guard let model = self else {
                    return AdminWebGameTrackerStylePreview(rankUpdate: "{}", session: "{}")
                }
                return await MainActor.run { model.gameTrackerStylePreview(style: style) }
            },
            mediaGameArtworkProvider: { gameName in
                await RecordingGameArtworkResponder.response(for: gameName)
            },
            accessProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebAccessPayload(restrictToListedUsers: false, allowedUserIDs: [], members: [], localFallbackEnabled: false)
                }
                return await MainActor.run { model.adminWebAccessSnapshot() }
            },
            activityProvider: { [weak self] limit in
                guard let model = self else { return AdminWebActivityPayload(entries: [], totalCount: 0) }
                return await MainActor.run { model.adminWebActivitySnapshot(limit: limit) }
            },
            rewindHandler: { [weak self] request in
                guard let model = self else { return .failure("rewind_unavailable") }
                return await model.adminWebRewind(request)
            },
            accessUpdater: { [weak self] update in
                guard let model = self else { return false }
                return await model.applyAdminWebAccessUpdate(update)
            },
            memberAccessUpdater: { [weak self] enabled in
                guard let model = self else { return false }
                return await model.applyAdminWebMemberAccess(enabled)
            },
            sweepProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebSweepPayload(
                        globalPaused: false, state: "Idle", stateTone: "gray", nextRunDescription: "Unknown",
                        enabledPolicyCount: 0, totalPolicyCount: 0, messagesTodayCount: 0, suppressedTodayCount: 0, summariesThisWeekCount: 0,
                        policies: [], recentReports: [], suggestions: [], isScanningSuggestions: false, lastSuggestionScanAt: nil, scanProgressDone: 0, scanProgressTotal: 0,
                        servers: [], textChannelsByServer: [:]
                    )
                }
                return await MainActor.run { model.adminWebSweepSnapshot() }
            },
            setSweepGlobalPaused: { [weak self] paused in
                guard let model = self else { return false }
                await MainActor.run { model.sweepService.globalPaused = paused }
                return true
            },
            updateSweepPolicy: { [weak self] policy in
                guard let model = self else { return false }
                await MainActor.run { model.sweepService.upsert(policy) }
                return true
            },
            createSweepPolicy: { [weak self] patch in
                guard let model = self else { return nil }
                return await MainActor.run {
                    guard let guildName = model.connectedServers[patch.guildID],
                          let channel = model.availableTextChannelsByServer[patch.guildID]?.first(where: { $0.id == patch.channelID }),
                          let kind = SweepStrategyKind(rawValue: patch.strategyKind) else { return nil }
                    let schedule: SweepSchedule = patch.scheduleMinutes > 0
                        ? .interval(minutes: min(43_200, max(1, patch.scheduleMinutes)))
                        : .manual
                    let policy = SweepPolicy(
                        name: patch.name.trimmingCharacters(in: .whitespacesAndNewlines),
                        guildID: patch.guildID,
                        guildName: guildName,
                        channelID: channel.id,
                        channelName: channel.name,
                        strategies: [SweepStrategy(
                            kind: kind,
                            ageHours: min(8_760, max(0, patch.ageHours)),
                            keepCount: min(1_000, max(0, patch.keepCount)),
                            fromBotsOnly: patch.fromBotsOnly
                        )],
                        schedule: schedule,
                        safety: SweepSafetyRails(
                            maxMessagesPerRun: min(1_000, max(1, patch.maxMessagesPerRun)),
                            minMessageAgeMinutes: min(43_200, max(0, patch.minMessageAgeMinutes)),
                            protectPinned: patch.protectPinned,
                            protectReacted: patch.protectReacted
                        )
                    )
                    model.sweepService.upsert(policy)
                    return policy
                }
            },
            deleteSweepPolicy: { [weak self] policyID in
                guard let model = self else { return false }
                await MainActor.run { model.sweepService.delete(policyID: policyID) }
                return true
            },
            setSweepPolicyEnabled: { [weak self] policyID, enabled in
                guard let model = self else { return false }
                await MainActor.run { model.sweepService.setEnabled(enabled, for: policyID) }
                return true
            },
            runSweepPolicy: { [weak self] policyID in
                guard let model = self else { return false }
                _ = await model.sweepService.run(policyID: policyID, manual: true)
                return true
            },
            previewSweepPolicy: { [weak self] policyID in
                guard let model = self, let report = await model.sweepService.preview(policyID: policyID) else { return nil }
                return AdminWebSweepRunReportPayload(report: report)
            },
            previewSweepDraft: { [weak self] policy in
                guard let model = self, let report = await model.sweepService.previewDraft(policy) else { return nil }
                return AdminWebSweepRunReportPayload(report: report)
            },
            scanSweepSuggestions: { [weak self] in
                guard let model = self else { return false }
                await model.scanAllSweepSuggestions()
                return true
            },
            applySweepSuggestion: { [weak self] suggestionID in
                guard let model = self else { return false }
                await MainActor.run { model.applySweepSuggestion(id: suggestionID) }
                return true
            },
            dismissSweepSuggestion: { [weak self] suggestionID in
                guard let model = self else { return false }
                await MainActor.run { model.dismissSweepSuggestion(id: suggestionID) }
                return true
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
            swiftMeshProvider: { [weak self] in
                guard let model = self else { return nil }
                return await model.adminWebSwiftMeshSnapshot()
            },
            memberReplayProvider: { [weak self] userID, guildIDs, guildID, period in
                guard let model = self else { return nil }
                return await model.memberReplay(userID: userID, allowedGuildIDs: guildIDs, guildID: guildID, periodKey: period)
            },
            memberClipsProvider: { [weak self] userID, query in
                guard let model = self else { return nil }
                return await model.memberClips(userID: userID, query: query)
            },
            memberMayPlay: { [weak self] userID, token in
                guard let model = self else { return false }
                return await model.memberMayPlay(userID: userID, token: token)
            },
            mediaPlaybackChoiceProvider: { [weak self] token in
                guard let model = self else { return nil }
                return await model.mediaPlaybackChoice(token: token)
            },
            operatorsProvider: { [weak self] in
                guard let model = self else { return nil }
                return await MainActor.run { model.adminWebOperatorsSnapshot() }
            },
            updateOperators: { [weak self] patch in
                guard let model = self else { return false }
                return await MainActor.run { model.applyAdminWebOperatorsPatch(patch) }
            },
            sendOperatorTest: { [weak self] in
                guard let model = self else { return "unavailable" }
                return await model.sendOperatorTestAlert()
            },
            setMediaSourceOwner: { [weak self] sourceID, userID in
                guard let model = self else { return false }
                return await MainActor.run { model.setRecordingSourceOwner(sourceKey: sourceID, userID: userID) }
            },
            runSwiftMeshAction: { [weak self] action in
                guard let model = self else { return "unavailable" }
                return await model.runAdminWebSwiftMeshAction(action)
            },
            swiftMinerWebhookHandler: { [weak self] headers, body in
                guard let model = self else {
                    return ("503 Service Unavailable", Data("{\"error\":\"app_unavailable\"}".utf8))
                }
                return await model.handleSwiftMinerWebhook(headers: headers, body: body)
            },
            swiftMinerTunnelHostnameHandler: { [weak self] headers, body in
                guard let model = self else {
                    return ("503 Service Unavailable", Data("{\"error\":\"app_unavailable\"}".utf8))
                }
                return await model.handleCompanionTunnelHostnameRequest(headers: headers, body: body)
            },
            swiftMinerTunnelInfoProvider: { [weak self] in
                guard let model = self else {
                    return ("503 Service Unavailable", Data("{\"error\":\"app_unavailable\"}".utf8))
                }
                return await MainActor.run { model.companionTunnelInfoResponse() }
            },
            companionSSOConfigProvider: { [weak self] in
                guard let model = self else { return (hostnames: [], secret: "") }
                return await MainActor.run {
                    (
                        hostnames: model.settings.adminWebUI.additionalTunnelHostnames.map(\.hostname),
                        secret: model.settings.swiftMiner.webhookSecret
                    )
                }
            },
            discordUsersProvider: { [weak self] in
                guard let model = self else { return [] }
                return await model.swiftMinerDiscordUsers()
            },
            swiftMinerTestDMSender: { [weak self] request, discordUserId in
                guard let model = self else { return false }
                return await model.sendSwiftMinerDM(request: request, discordUserId: discordUserId)
            },
            swiftMinerPairedProvider: { [weak self] in
                guard let model = self else { return false }
                return await MainActor.run {
                    let sm = model.settings.swiftMiner
                    return sm.enabled
                        && !sm.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !sm.webhookSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            },
            log: { [weak self] message in
                guard let model = self else { return }
                await MainActor.run { model.logs.append(message) }
            }
        )
        await adminWebServer.setHostOperations(
            run: { [weak self] operation in
                guard let model = self else { return "SwiftBot is shutting down." }
                return await model.runAdminWebHostOperation(operation)
            },
            permissions: { [weak self] in
                guard let model = self else {
                    return AdminWebBotPermissionsPayload(botUsername: nil, error: "SwiftBot is shutting down.", guilds: [], checkedAt: Date())
                }
                return await model.adminWebBotPermissions()
            },
            updates: { [weak self] in
                guard let model = self else { return nil }
                return await model.adminWebUpdatesSnapshot()
            }
        )
        await adminWebServer.setGameProviderCredentialUpdater { [weak self] providerRaw, token in
            guard let model = self, let providerID = GameProviderID(rawValue: providerRaw) else {
                return GameProviderCredentialResult.unsupported.rawValue
            }
            return await model.setGameProviderCredential(token, for: providerID).rawValue
        }
        await adminWebServer.setAuditLogger { [weak self] source, actor, action, detail, level in
            guard let model = self else { return }
            let parsedSource: AuditLogEntry.Source = {
                switch source {
                case "Web Auth": return .webAuth
                case "Web Config": return .webConfig
                case "Moderation": return .moderation
                default: return .bot
                }
            }()
            let parsedLevel: AuditLogEntry.Level = {
                switch level {
                case "ok": return .ok
                case "warning": return .warning
                case "error": return .error
                default: return .info
                }
            }()
            model.recordAudit(
                source: parsedSource,
                actor: actor,
                action: action,
                detail: detail,
                level: parsedLevel
            )
        }
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

        let trimmedToken = CloudflareDNSProvider.normalizedAPIToken(from: settings.adminWebUI.cloudflareAPIToken)
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

    func dismissDNSConflict(for hostname: String) {
        let cleaned = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return }
        if !settings.adminWebUI.dismissedDNSConflictHostnames.contains(cleaned) {
            settings.adminWebUI.dismissedDNSConflictHostnames.append(cleaned)
            saveSettings()
        }
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

        let trimmedToken = CloudflareDNSProvider.normalizedAPIToken(from: settings.adminWebUI.cloudflareAPIToken)
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
        Task(priority: .background) {
            let tokenIsValid = await dnsProvider.verifyAPIToken()
            if tokenIsValid {
                self.logs.append("✅ Cloudflare API verified (background)")
                await MainActor.run {
                    progress(.cloudflareAccessVerified)
                }
            } else {
                self.logs.append("⚠️ Cloudflare API verification failed (token may be invalid or timed out)")
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
            try await tunnelClient.configureTunnel(
                tunnel,
                hostname: hostname,
                originURL: originURL,
                additionalRules: additionalTunnelIngressRules()
            )
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

        let isDismissed = settings.adminWebUI.dismissedDNSConflictHostnames.contains(hostname.lowercased())
        let dnsResult = try await dnsProvider.configureTunnelDNSRoute(
            hostname: hostname,
            tunnelTarget: tunnelTarget,
            zoneID: zone.id,
            force: forceReplaceDNS || isDismissed
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

        // Re-apply DNS for companion-app hostnames (e.g. SwiftMiner) so a setup
        // re-run repairs their records too. Non-fatal: a failure here must not
        // break SwiftBot's own public access.
        for extra in settings.adminWebUI.additionalTunnelHostnames {
            do {
                _ = try await dnsProvider.configureTunnelDNSRoute(
                    hostname: extra.hostname,
                    tunnelTarget: tunnelTarget,
                    zoneID: zone.id,
                    force: false
                )
                logs.append("DNS route ensured for companion hostname \(extra.hostname) (\(extra.label))")
            } catch {
                logs.append("⚠️ Could not ensure DNS for companion hostname \(extra.hostname): \(error.localizedDescription)")
            }
        }

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

    // MARK: - Companion-App Tunnel Hostnames (e.g. SwiftMiner)

    /// Ingress rules for hostnames companion apps registered on the tunnel.
    /// Passed to every `configureTunnel` call so SwiftBot's own reconfiguration
    /// never wipes them (the Cloudflare PUT replaces the whole ingress array).
    func additionalTunnelIngressRules() -> [(hostname: String, service: String)] {
        settings.adminWebUI.additionalTunnelHostnames.map { ($0.hostname, $0.service) }
    }

    enum CompanionTunnelHostnameError: LocalizedError {
        case tunnelNotConfigured
        case invalidHostname
        case invalidService
        case conflictsWithSwiftBotHostname

        var errorDescription: String? {
            switch self {
            case .tunnelNotConfigured:
                return "SwiftBot's Internet Access (Cloudflare tunnel) is not set up yet."
            case .invalidHostname:
                return "Hostname must be a bare domain name like swiftminer.example.com."
            case .invalidService:
                return "Service must be a local http URL like http://localhost:8080."
            case .conflictsWithSwiftBotHostname:
                return "That hostname is already used by SwiftBot itself."
            }
        }
    }

    /// Registers (or updates) a companion app's hostname on SwiftBot's existing
    /// Cloudflare tunnel: persists it, merges it into tunnel ingress, and
    /// ensures the DNS CNAME. Idempotent. Returns the public URL.
    func registerCompanionTunnelHostname(hostname rawHostname: String, service rawService: String, label: String) async throws -> String {
        let hostname = rawHostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let service = rawService.trimmingCharacters(in: .whitespacesAndNewlines)

        // Hostname: bare DNS name, no scheme/path/port.
        guard !hostname.isEmpty,
              !hostname.contains("/"), !hostname.contains(":"),
              hostname.contains("."),
              hostname.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else {
            throw CompanionTunnelHostnameError.invalidHostname
        }
        guard hostname != effectiveAdminWebHostname().lowercased() else {
            throw CompanionTunnelHostnameError.conflictsWithSwiftBotHostname
        }
        // Service: strictly a loopback http origin — the tunnel must only ever
        // route into this machine.
        guard let serviceURL = URL(string: service),
              serviceURL.scheme?.lowercased() == "http",
              let serviceHost = serviceURL.host?.lowercased(),
              serviceHost == "localhost" || serviceHost == "127.0.0.1",
              serviceURL.path.isEmpty || serviceURL.path == "/" else {
            throw CompanionTunnelHostnameError.invalidService
        }

        let apiToken = CloudflareDNSProvider.normalizedAPIToken(from: settings.adminWebUI.cloudflareAPIToken)
        let tunnelID = settings.adminWebUI.publicAccessTunnelID
        let accountID = settings.adminWebUI.publicAccessTunnelAccountID
        guard settings.adminWebUI.internetAccessEnabled,
              !apiToken.isEmpty, !tunnelID.isEmpty, !accountID.isEmpty else {
            throw CompanionTunnelHostnameError.tunnelNotConfigured
        }

        // Upsert into settings first so every later reconfiguration includes it.
        var entries = settings.adminWebUI.additionalTunnelHostnames
        if let index = entries.firstIndex(where: { $0.hostname.lowercased() == hostname }) {
            entries[index].service = service
            entries[index].label = label
        } else {
            entries.append(AdditionalTunnelHostname(hostname: hostname, service: service, label: label))
        }
        settings.adminWebUI.additionalTunnelHostnames = entries
        saveSettings()

        let tunnel = CloudflareTunnelClient.TunnelSummary(
            accountID: accountID,
            id: tunnelID,
            name: settings.adminWebUI.publicAccessTunnelName,
            token: settings.adminWebUI.publicAccessTunnelToken
        )
        let tunnelClient = CloudflareTunnelClient(apiToken: apiToken)
        let dnsProvider = CloudflareDNSProvider(apiToken: apiToken)

        let swiftBotHostname = effectiveAdminWebHostname()
        let originURL = "http://localhost:\(settings.adminWebUI.port)"
        do {
            try await tunnelClient.configureTunnel(
                tunnel,
                hostname: swiftBotHostname,
                originURL: originURL,
                additionalRules: additionalTunnelIngressRules()
            )
        } catch {
            logs.append("⚠️ Companion ingress update failed for \(hostname): \(error)")
            throw CompanionTunnelStepError(step: "updating tunnel ingress", underlying: error)
        }
        logs.append("Tunnel ingress updated with \(label) hostname \(hostname) → \(service)")

        do {
            guard let zone = try await dnsProvider.findZone(for: hostname) else {
                throw CloudflareDNSProvider.Error.zoneNotFound(hostname)
            }
            let tunnelTarget = CloudflareTunnelClient.tunnelTargetHostname(for: tunnelID)
            _ = try await dnsProvider.configureTunnelDNSRoute(
                hostname: hostname,
                tunnelTarget: tunnelTarget,
                zoneID: zone.id,
                force: false
            )
        } catch {
            logs.append("⚠️ Companion DNS step failed for \(hostname): \(error)")
            throw CompanionTunnelStepError(step: "creating the DNS record", underlying: error)
        }
        logs.append("DNS route ensured for \(hostname)")

        return "https://\(hostname)"
    }

    /// Wraps a Cloudflare error with which step failed, so the companion app
    /// never shows a bare Foundation decode message like
    /// "The data couldn't be read because it is missing."
    struct CompanionTunnelStepError: LocalizedError {
        let step: String
        let underlying: Swift.Error

        var errorDescription: String? {
            "Cloudflare request failed while \(step): \(underlying.localizedDescription)"
        }
    }

    /// HTTP entry point for `GET /v1/tunnel/info`. Read-only, unauthenticated
    /// (like /health): exposes only the public domain — which the tunnel URL
    /// itself already reveals — and whether the tunnel is ready for companions.
    func companionTunnelInfoResponse() -> (status: String, body: Data) {
        let ui = settings.adminWebUI
        let hostname = effectiveAdminWebHostname().lowercased()

        // Prefer the selected Cloudflare zone; otherwise derive the apex from
        // the hostname by dropping its first label (swiftbot.example.com → example.com).
        var domain = ui.selectedZoneName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if domain.isEmpty {
            let labels = hostname.split(separator: ".")
            if labels.count >= 2 { domain = labels.dropFirst().joined(separator: ".") }
        }

        let apiToken = CloudflareDNSProvider.normalizedAPIToken(from: ui.cloudflareAPIToken)
        let ready = ui.internetAccessEnabled && !ui.publicAccessTunnelID.isEmpty && !apiToken.isEmpty

        let object: [String: Any] = [
            "internetAccessEnabled": ready,
            "domain": domain,
            "swiftBotHostname": hostname
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return ("200 OK", data)
    }

    /// HTTP entry point for `POST /v1/tunnel/hostnames`. Authenticates with the
    /// SwiftMiner pairing HMAC and **fails closed**: no shared secret, no access.
    /// (The general webhook validator is deliberately fail-open for unpaired
    /// installs; a Cloudflare-mutating endpoint must not be.)
    func handleCompanionTunnelHostnameRequest(headers: [String: String], body: Data) async -> (status: String, body: Data) {
        func json(_ object: [String: Any], _ status: String) -> (String, Data) {
            ((try? JSONSerialization.data(withJSONObject: object)).map { (status, $0) }) ?? (status, Data())
        }

        let secret = settings.swiftMiner.webhookSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, validateSwiftMinerSignature(headers: headers, body: body) else {
            return json(["error": "unauthorized", "message": "Missing or invalid SwiftMiner signature."], "401 Unauthorized")
        }

        struct Payload: Decodable {
            let hostname: String
            let service: String
            let label: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body) else {
            return json(["error": "invalid_payload", "message": "Body must include hostname and service."], "400 Bad Request")
        }

        do {
            let publicURL = try await registerCompanionTunnelHostname(
                hostname: payload.hostname,
                service: payload.service,
                label: payload.label ?? "Companion"
            )
            return json(["ok": true, "publicURL": publicURL], "200 OK")
        } catch let error as CompanionTunnelHostnameError {
            let code: String
            switch error {
            case .tunnelNotConfigured: code = "tunnel_not_configured"
            case .invalidHostname: code = "invalid_hostname"
            case .invalidService: code = "invalid_service"
            case .conflictsWithSwiftBotHostname: code = "hostname_conflict"
            }
            return json(["error": code, "message": error.localizedDescription], "409 Conflict")
        } catch {
            return json(["error": "cloudflare_error", "message": error.localizedDescription], "502 Bad Gateway")
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

        // First verify the token is valid by checking Cloudflare token status.
        try await dnsProvider.verifyAPITokenDetailed()

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

        let trimmedToken = CloudflareDNSProvider.normalizedAPIToken(from: settings.adminWebUI.cloudflareAPIToken)
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
        Task(priority: .background) {
            let tokenIsValid = await dnsProvider.verifyAPIToken()
            if tokenIsValid {
                self.logs.append("✅ Cloudflare API verified (background)")
                await MainActor.run {
                    progress(.cloudflareAccessVerified)
                }
            } else {
                self.logs.append("⚠️ Cloudflare API verification failed (token may be invalid or timed out)")
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
            try await tunnelClient.configureTunnel(
                tunnel,
                hostname: hostname,
                originURL: "http://localhost:\(settings.adminWebUI.port)",
                additionalRules: additionalTunnelIngressRules()
            )
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

        let isDismissed = settings.adminWebUI.dismissedDNSConflictHostnames.contains(hostname.lowercased())
        let dnsResult = try await dnsProvider.configureTunnelDNSRoute(
            hostname: hostname,
            tunnelTarget: tunnelTarget,
            zoneID: zone.id,
            force: forceReplaceDNS || isDismissed
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
                tunnelToken: tunnelToken,
                healthCheckEnabled: settings.adminWebUI.tunnelHealthCheckEnabled
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

            // MARK: - Sweep

            @MainActor
            private func adminWebSweepSnapshot() -> AdminWebSweepPayload {
                let s = sweepService
                let serverIDs = connectedServers.keys.sorted {
                    (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
                }
                return AdminWebSweepPayload(
                    globalPaused: s.globalPaused,
                    state: s.state.displayName,
                    stateTone: s.state.tone.description,
                    nextRunDescription: s.nextRunDescription,
                    enabledPolicyCount: s.enabledPolicyCount,
                    totalPolicyCount: s.policies.count,
                    messagesTodayCount: s.messagesTodayCount,
                    suppressedTodayCount: s.suppressedTodayCount,
                    summariesThisWeekCount: s.summariesThisWeekCount,
                    policies: s.policies,
                    recentReports: s.recentReports.map(\.webTrimmed),
                    suggestions: s.suggestions.map { suggestion in
                        var trimmed = suggestion
                        trimmed.projection = suggestion.projection?.webTrimmed
                        return trimmed
                    },
                    isScanningSuggestions: s.isScanningSuggestions,
                    lastSuggestionScanAt: s.lastSuggestionScanAt,
                    scanProgressDone: s.scanProgress.done,
                    scanProgressTotal: s.scanProgress.total,
                    servers: serverIDs.map { AdminWebSimpleOption(id: $0, name: connectedServers[$0] ?? $0) },
                    textChannelsByServer: Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
                        (serverID, (availableTextChannelsByServer[serverID] ?? [])
                            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                            .map { AdminWebSimpleOption(id: $0.id, name: $0.name) })
                    }),
                    voiceChannelsByServer: Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
                        (serverID, (availableVoiceChannelsByServer[serverID] ?? [])
                            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                            .map { AdminWebSimpleOption(id: $0.id, name: $0.name) })
                    })
                )
            }

            @MainActor
            func scanAllSweepSuggestions() async {
                var targets: [SweepService.SweepScanTarget] = []
                for (guildID, channels) in self.availableTextChannelsByServer {
                    let guildName = self.connectedServers[guildID] ?? "Server"
                    for channel in channels {
                        targets.append(.init(guildID: guildID, guildName: guildName, channel: channel))
                    }
                }
                await sweepService.scanForSuggestions(targets: targets)
            }

            @MainActor
            func applySweepSuggestion(id: UUID) {
                guard let suggestion = sweepService.suggestions.first(where: { $0.id == id }) else { return }
                sweepService.applySuggestion(suggestion)
            }

            @MainActor
            func dismissSweepSuggestion(id: UUID) {
                guard let suggestion = sweepService.suggestions.first(where: { $0.id == id }) else { return }
                sweepService.dismissSuggestion(suggestion)
            }
            }

// MARK: - Announcer live state

extension AppModel {
    /// Mirrors the native Announcer tab's "Current State" panel for the WebUI.
    /// Kept in sync with `VoiceView`'s equivalent computed properties.
    @MainActor
    func adminWebAnnouncerLiveState() -> AdminWebAnnouncerLiveState {
        let configs = settings.voice.announcerConfigs
        let activeConfig: AnnouncerVoiceChannelConfig? = {
            if !settings.voice.voiceChannelID.isEmpty,
               let match = configs.first(where: { $0.voiceChannelID == settings.voice.voiceChannelID }) {
                return match
            }
            return configs.first(where: \.enabled) ?? configs.first
        }()

        let channelName: String = {
            if let config = activeConfig,
               !config.voiceChannelName.isEmpty,
               config.voiceChannelName != "—" {
                return config.voiceChannelName
            }
            return "None"
        }()

        let isConnected = voiceConnectionStatus.isConnected
        let listening: String = {
            guard isConnected else { return "Not listening" }
            return channelName == "None" ? "Connected" : "Listening in \(channelName)"
        }()

        let monitoredFeeds: String = {
            guard let config = activeConfig else { return "No feeds configured" }
            var labels = config.textChannels.map { "#\($0)" }
            if config.readVoiceChannelChat {
                let name = config.voiceChannelName == "—" ? "voice chat" : config.voiceChannelName
                labels.insert("#\(name)", at: 0)
            }
            if labels.isEmpty { return "No feeds" }
            if labels.count <= 3 { return labels.joined(separator: ", ") }
            return "\(labels.prefix(2).joined(separator: ", ")) +\(labels.count - 2) more"
        }()

        let depth = announcerHealth.queueDepth
        let queueLabel = depth == 0
            ? "No queued announcements"
            : "\(depth) announcement\(depth == 1 ? "" : "s") waiting"

        return AdminWebAnnouncerLiveState(
            isConnected: isConnected,
            connectionLabel: voiceConnectionStatus.displayLabel,
            phaseLabel: announcerHealth.phase.displayLabel,
            listening: listening,
            monitoredFeeds: monitoredFeeds,
            queueDepth: depth,
            queueLabel: queueLabel,
            manualHold: announcerManualHoldStatusText,
            recovery: announcerRecoveryCircuitBreakerStatusText
        )
    }
}

// MARK: - Announcer disconnect

extension AppModel {
    /// Web equivalent of `/announce disconnect`: arms the same one-hour manual
    /// hold before leaving, so automatic joins and recovery don't immediately
    /// undo an operator's explicit disconnect.
    @MainActor
    func adminWebDisconnectAnnouncer() async -> Bool {
        guard voiceConnectionStatus.isConnected else { return false }

        let guildID = settings.voice.guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelID = settings.voice.voiceChannelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guildID.isEmpty, !channelID.isEmpty else { return false }

        setManualAnnouncerHold(guildID: guildID, channelID: channelID, source: "the admin web UI")
        await disconnectVoice()
        return true
    }
}

// MARK: - Game Tracker admin web surface

extension AppModel {
    @MainActor
    func adminWebGameTrackerSnapshot() -> AdminWebGameTrackerPayload {
        let tracking = settings.gameTracking
        let issue = tracking.configurationIssue(connections: settings.gameProviders)
        let mode = runtimeClusterMode
        let isPollingRuntime = mode == .standalone || mode == .leader

        var channelNames: [String: String] = [:]
        for channels in availableTextChannelsByServer.values {
            for channel in channels { channelNames[channel.id] = channel.name }
        }

        let players = tracking.players.map { player -> AdminWebGameTrackerPlayerPayload in
            let baseline = gameTrackingBaselines[player.id]
            let descriptor = GameProviderCatalog.descriptor(for: player.provider)
            return AdminWebGameTrackerPlayerPayload(
                id: player.id.uuidString,
                game: player.game.rawValue,
                gameDisplayName: player.game.displayName,
                provider: player.provider.rawValue,
                providerDisplayName: player.provider.displayName,
                playerID: player.playerID,
                displayName: player.resolvedDisplayName,
                destinationChannelID: player.destinationChannelID,
                destinationChannelName: channelNames[player.destinationChannelID]
                    ?? player.destinationChannelID,
                isEnabled: player.isEnabled,
                supportsRankedScore: descriptor?.capabilities.contains(.rankedScore) ?? false,
                season: baseline?.season,
                // Baselines from before tier names were resolved say "Gold".
                rankName: baseline.flatMap { b in
                    player.game.rankTier(index: b.metrics[.rankTier].map { Int($0) }, score: b.score, league: b.rankName)?.name
                } ?? baseline?.rankName,
                score: baseline?.score,
                baselineRecordedAt: baseline?.recordedAt,
                rankUnavailable: gameTrackingRankUnavailable[player.id],
                discordUserID: player.discordUserID
            )
        }

        // Same option list the native editor builds (server · #channel).
        let channels = availableTextChannelsByServer.flatMap { serverID, channels in
            channels.map { AdminWebSimpleOption(id: $0.id, name: "\(connectedServers[serverID] ?? "Unknown Server") · #\($0.name)") }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let catalog = AdminWebGameTrackerCatalog(
            games: GameID.allCases.map { .init(id: $0.rawValue, displayName: $0.displayName, symbolName: $0.symbolName) },
            providers: GameProviderID.allCases.map { provider in
                let descriptor = GameProviderCatalog.descriptor(for: provider)
                let supported = descriptor?.supportedMetrics ?? []
                return .init(
                    id: provider.rawValue,
                    displayName: provider.displayName,
                    supportedGames: provider.supportedGames.map(\.rawValue).sorted(),
                    metrics: GameMetricID.allCases.filter { supported.contains($0) }.map {
                        .init(id: $0.rawValue, displayName: $0.displayName, canTrigger: $0.canTriggerAnnouncement)
                    },
                    isConfigured: descriptor.map { settings.gameProviders[provider].configurationIssue(for: $0) == nil } ?? false,
                    credentialLabel: descriptor?.auth.credentialLabel ?? "API Key",
                    hasCredential: settings.gameProviders[provider].hasCredential,
                    credentialHint: settings.gameProviders[provider].credentialHint,
                    credentialUpdatedAt: settings.gameProviders[provider].credentialUpdatedAt,
                    issue: descriptor.flatMap { settings.gameProviders[provider].issue(for: $0)?.message(for: $0) }
                )
            }
        )

        let tone: String
        if !tracking.enabled {
            tone = "gray"
        } else if issue != nil {
            tone = "amber"
        } else if !isPollingRuntime {
            tone = "amber"
        } else {
            tone = "green"
        }

        return AdminWebGameTrackerPayload(
            enabled: tracking.enabled,
            dailyCheckEnabled: tracking.dailyCheckEnabled,
            sessionTrackingEnabled: tracking.sessionTrackingEnabled,
            statusText: gameTrackingStatusText,
            statusTone: tone,
            configurationIssue: issue,
            checkInProgress: gameTrackingCheckInProgress,
            scheduleDescription: gameTrackingScheduleDescription(),
            lastCheckAt: gameTrackingLastCheckAt,
            nextCheckAt: gameTrackingNextCheckAt,
            enabledPlayerCount: tracking.enabledPlayers.count,
            totalPlayerCount: tracking.players.count,
            players: players,
            history: gameTrackingHistory,
            isPollingRuntime: isPollingRuntime,
            checkHour: tracking.checkHour,
            timeZoneIdentifier: tracking.timeZoneIdentifier,
            linkedPlayerCount: tracking.presenceLinkedPlayers.count,
            sessionMinimumMinutes: tracking.sessionMinimumDurationSeconds / 60,
            sessionGraceMinutes: tracking.sessionAbsenceGraceSeconds / 60,
            isFailoverManagedNode: isFailoverManagedNode,
            catalog: catalog,
            channels: channels,
            members: discordMemberOptions.map { .init(id: $0.id, name: $0.displayName, username: $0.username) },
            announcementStyle: tracking.announcementStyle,
            stylePreview: gameTrackerStylePreview(style: tracking.announcementStyle)
        )
    }

    /// The player the style preview and test posts are built around: one
    /// with a recorded rank if possible, so the sample shows their real tier.
    private func gameTrackerSamplePlayer(id: UUID? = nil) -> GameTrackedPlayer? {
        let players = settings.gameTracking.players
        if let id { return players.first { $0.id == id } }
        return players.first { $0.isEnabled && gameTrackingBaselines[$0.id] != nil }
            ?? players.first(where: \.isEnabled)
            ?? players.first
    }

    /// A believable rank-up and session for `player`, from their last
    /// baseline when there is one. Only used for previews and test posts.
    private func gameTrackerSamples(
        for player: GameTrackedPlayer?
    ) -> (change: GameRankChange, session: GameAnnouncementRenderer.SessionContext) {
        let game = player?.game ?? .theFinals
        let provider = player?.provider ?? .finalsID
        let baseline = player.flatMap { gameTrackingBaselines[$0.id] }
        let name = player?.resolvedDisplayName ?? "Player"

        let score = (baseline?.score).flatMap { $0 > 0 ? $0 : nil } ?? 28_160
        let previousScore = max(0, score - 340)
        let currentTier = game.rankTier(index: nil, score: score, league: nil)
        let previousTier = game.rankTier(index: nil, score: previousScore, league: nil)
        let position = baseline?.metrics[.leaderboardPosition] ?? 56_866

        var current = GameMetricSet([.rankedScore: Double(score), .leaderboardPosition: position])
        var previous = GameMetricSet([.rankedScore: Double(previousScore), .leaderboardPosition: position + 1_204])
        if let currentTier, let previousTier {
            current[.rankTier] = Double(currentTier.ladderPosition)
            previous[.rankTier] = Double(previousTier.ladderPosition)
        }
        var movements = [GameMetricChange(metric: .rankedScore, previous: Double(previousScore), current: Double(score))]
        if let currentTier, let previousTier, currentTier.ladderPosition != previousTier.ladderPosition {
            movements.append(GameMetricChange(
                metric: .rankTier,
                previous: Double(previousTier.ladderPosition),
                current: Double(currentTier.ladderPosition)
            ))
        }
        // Only what the provider really reports on a rank check, so the
        // preview never promises a stat the post won't have.
        var context = baseline?.metrics ?? GameMetricSet()
        context[.leaderboardPosition] = position

        let change = GameRankChange(
            targetID: player?.id ?? UUID(),
            game: game,
            provider: provider,
            destinationChannelID: player?.destinationChannelID ?? "",
            playerID: player?.playerID ?? "player#0001",
            displayName: name,
            season: baseline?.season ?? "s11",
            rankName: currentTier?.name,
            previousScore: previousScore,
            currentScore: score,
            metricChanges: movements,
            contextMetrics: context,
            previousRankName: previousTier?.name,
            previousMetrics: previous,
            currentMetrics: current,
            discordUserID: player?.discordUserID ?? ""
        )

        let end = Date()
        var totals = GameSessionSummaryBuilder.Totals()
        totals.matches = 6
        totals.rankedMatches = 4
        totals.wins = 2
        totals.kills = 38
        totals.deaths = 21
        totals.damage = 21_430
        let session = GameAnnouncementRenderer.SessionContext(
            session: GameSession(
                userID: player?.discordUserID ?? "",
                guildID: "",
                gameName: game.displayName,
                startedAt: end.addingTimeInterval(-5_040),
                endedAt: end
            ),
            displayName: name,
            game: game,
            providerName: provider.displayName,
            totals: totals,
            rankName: currentTier?.name,
            score: score,
            rankIndex: currentTier?.ladderPosition,
            discordUserID: player?.discordUserID ?? ""
        )
        return (change, session)
    }

    func gameTrackerStylePreview(style: GameAnnouncementStyle) -> AdminWebGameTrackerStylePreview {
        let samples = gameTrackerSamples(for: gameTrackerSamplePlayer())
        let rank = GameAnnouncementRenderer.rankUpdateMessages(
            changes: [samples.change], checkedAt: Date(), style: style
        ).first?.payload ?? [:]
        let session = GameAnnouncementRenderer.sessionMessage(samples.session, style: style)
        func json(_ payload: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        }
        return AdminWebGameTrackerStylePreview(rankUpdate: json(rank), session: json(session))
    }

    /// Posts the preview samples to a player's real channel so the operator
    /// can see them in Discord. Marked "Test post" in the footer.
    func sendGameTrackerTestAnnouncement(playerID: UUID?, style draft: GameAnnouncementStyle? = nil) async -> Bool {
        guard let player = gameTrackerSamplePlayer(id: playerID),
              !player.destinationChannelID.isEmpty else { return false }
        // The editor tests its unsaved draft, so what's posted matches the preview.
        var style = draft ?? settings.gameTracking.announcementStyle
        style.normalize()
        let samples = gameTrackerSamples(for: player)
        var ok = true
        for message in GameAnnouncementRenderer.rankUpdateMessages(
            changes: [samples.change], checkedAt: Date(), style: style, isTest: true
        ) {
            ok = await sendPayload(channelId: player.destinationChannelID, payload: message.payload, action: "gameTrackerRankUpdate") && ok
        }
        ok = await sendPayload(
            channelId: player.destinationChannelID,
            payload: GameAnnouncementRenderer.sessionMessage(samples.session, style: style, isTest: true),
            action: "gameTrackerSessionSummary"
        ) && ok
        logs.append(ok
            ? "[OK] Game Tracker test announcement sent for \(player.resolvedDisplayName)."
            : "[ERR] Game Tracker test announcement failed for \(player.resolvedDisplayName).")
        return ok
    }

    /// Applies one WebUI Game Tracker edit through the same methods the
    /// native view uses, so saving, monitoring and baselines behave alike.
    func applyAdminWebGameTrackerUpdate(_ update: AdminWebGameTrackerUpdate) -> Bool {
        // Failover nodes receive Game Tracker settings from the primary.
        guard !isFailoverManagedNode else { return false }
        switch update.action {
        case .upsertPlayer:
            guard let input = update.player,
                  let game = GameID(rawValue: input.game),
                  let provider = GameProviderID(rawValue: input.provider) else { return false }
            var player = input.id.flatMap(UUID.init(uuidString:))
                .flatMap { id in settings.gameTracking.players.first { $0.id == id } }
                ?? GameTrackedPlayer()
            player.game = game
            player.provider = provider
            player.playerID = input.playerID.trimmingCharacters(in: .whitespacesAndNewlines)
            player.displayName = input.displayName
            player.destinationChannelID = input.destinationChannelID
            player.isEnabled = input.isEnabled
            player.discordUserID = input.discordUserID.trimmingCharacters(in: .whitespacesAndNewlines)
            upsertTrackedGamePlayer(player)
        case .deletePlayer:
            guard let id = update.playerID.flatMap(UUID.init(uuidString:)) else { return false }
            removeTrackedGamePlayer(id)
        case .setPlayerEnabled:
            guard let id = update.playerID.flatMap(UUID.init(uuidString:)),
                  settings.gameTracking.players.contains(where: { $0.id == id }) else { return false }
            setTrackedGamePlayerEnabled(id, enabled: update.enabled ?? true)
        case .updateSettings:
            if let enabled = update.dailyCheckEnabled { settings.gameTracking.dailyCheckEnabled = enabled }
            if let enabled = update.sessionTrackingEnabled { settings.gameTracking.sessionTrackingEnabled = enabled }
            if let hour = update.checkHour { settings.gameTracking.checkHour = hour }
            gameTrackingSettingsDidChange()
        case .updateStyle:
            guard var style = update.style else { return false }
            style.normalize()
            settings.gameTracking.announcementStyle = style
            gameTrackingSettingsDidChange()
        case .sendTest:
            guard gameTrackerSamplePlayer(id: update.playerID.flatMap(UUID.init(uuidString:)))?
                .destinationChannelID.isEmpty == false else { return false }
            let id = update.playerID.flatMap(UUID.init(uuidString:))
            let draft = update.style
            Task { await self.sendGameTrackerTestAnnouncement(playerID: id, style: draft) }
        }
        return true
    }

    @MainActor
    func gameTrackingScheduleDescription() -> String {
        var components = DateComponents()
        components.hour = settings.gameTracking.checkHour
        components.minute = settings.gameTracking.checkMinute
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let zone = TimeZone(identifier: settings.gameTracking.timeZoneIdentifier) ?? .current
        formatter.timeZone = zone
        let calendar = Calendar.current
        guard let date = calendar.date(from: components) else { return "Daily" }
        return "Daily at \(formatter.string(from: date)) (\(zone.identifier))"
    }
}

// MARK: - Host operations (admin web)

extension AppModel {
    /// Runs one Web UI request to act on the host. nil means done; a string is
    /// the reason it couldn't be, shown to the person as-is.
    func runAdminWebHostOperation(_ operation: AdminWebHostOperation) async -> String? {
        switch operation {
        case .startBot, .restartBot:
            if isRemoteLaunchMode { return "This Mac is in Remote Control mode, so it doesn’t run a bot." }
            if settings.clusterMode == .worker { return "Worker mode is temporarily unavailable. Choose Standalone or Primary in the SwiftBot app on the Mac." }
            if normalizedDiscordToken(from: settings.token).isEmpty { return "No bot token is set. Add it in the SwiftBot app on the Mac." }
            if case .startBot = operation, status != .stopped { return "The bot is already running." }
            if case .restartBot = operation { await stopBot() }
            // Connecting can take a while; the page follows along through status.
            Task { await self.startBot() }
            return nil
        case .stopBot:
            guard status != .stopped else { return "The bot is already stopped." }
            await stopBot()
            return nil
        case .announcerTest:
            guard voiceConnectionStatus.isConnected else { return "The announcer isn’t in a voice channel. Reconnect it first." }
            await speakAnnouncement("This is a test announcement from SwiftBot.")
            return nil
        case .announcerReconnect:
            guard status == .running else { return "The bot is offline. Start it first." }
            guard settings.voice.announcerConfigs.contains(where: { $0.enabled && !$0.voiceChannelID.isEmpty }) else {
                return "Turn on a voice channel first."
            }
            // Leaving and rejoining waits on Discord, so don't hold the request.
            Task { await self.reconnectAnnouncerVoiceFromUI() }
            return nil
        case .welcomeTest:
            guard settings.welcomeFlow.hasPublicWelcome else { return "Turn on the public greeting and choose its channel first." }
            return await sendWelcomeFlowTestMessage() ? nil : "Couldn’t send the test. Check the channel and SwiftBot’s permissions there."
        case .refreshWelcomeInvites:
            guard let guildID = automationServerContext().guildId, !guildID.isEmpty else { return "SwiftBot isn’t connected to a server yet." }
            return await refreshWelcomeFlowInvites(guildID: guildID) ? nil : "Couldn’t read the server’s invites. SwiftBot needs the Manage Server permission."
        case .sweepTestMVP(let policy):
            do {
                try await sweepService.sendTestWeeklyMVP(for: policy)
                return nil
            } catch {
                return error.localizedDescription
            }
        case .checkForUpdates, .installUpdate, .setAutomaticUpdateChecks, .setUnattendedUpdates:
            return runAdminWebUpdateOperation(operation)
        }
    }

    private func runAdminWebUpdateOperation(_ operation: AdminWebHostOperation) -> String? {
        guard let updater = appUpdater, updater.canCheckForUpdates else {
            return "Software updates aren’t set up in this build."
        }
        switch operation {
        case .checkForUpdates:
            updater.checkForUpdatesInBackground()
        case .installUpdate:
            guard updater.isReadyToInstall else { return "No update is downloaded yet." }
            // Give the response a moment to reach the browser before the relaunch.
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                updater.installPendingUpdate()
            }
        case .setAutomaticUpdateChecks(let enabled):
            updater.setAutomaticallyChecksForUpdates(enabled)
        case .setUnattendedUpdates(let enabled):
            guard !enabled || updater.automaticallyChecksForUpdates else { return "Turn on automatic checks first." }
            updater.setAutomaticallyDownloadsUpdates(enabled)
        default:
            break
        }
        return nil
    }

    func adminWebUpdatesSnapshot() -> AdminWebUpdatesPayload? {
        guard let updater = appUpdater else { return nil }
        let info = Bundle.main.infoDictionary
        return AdminWebUpdatesPayload(
            configured: updater.canCheckForUpdates,
            version: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "",
            channel: updater.selectedChannel.rawValue,
            automaticChecks: updater.automaticallyChecksForUpdates,
            unattended: updater.automaticallyDownloadsUpdates,
            isChecking: updater.isChecking,
            lastCheckedAt: updater.lastCheckedAt,
            availableVersion: updater.availableVersion,
            availableBuild: updater.availableBuild,
            releaseNotesURL: updater.availableReleaseNotesURL?.absoluteString,
            readyToInstall: updater.isReadyToInstall,
            lastError: updater.lastErrorMessage
        )
    }

    /// The same check as the native Bot Permissions sheet, for the Web UI.
    func adminWebBotPermissions() async -> AdminWebBotPermissionsPayload {
        let token = normalizedDiscordToken(from: settings.token)
        guard !token.isEmpty else {
            return AdminWebBotPermissionsPayload(botUsername: nil, error: "No bot token is set. Add it in the SwiftBot app on the Mac.", guilds: [], checkedAt: Date())
        }
        do {
            let identity = try await BotPermissionsProbe.identity(token: token)
            let guilds = try await BotPermissionsProbe.guilds(token: token).sorted { lhs, rhs in
                let lhsScore = lhs.missingEssential.count * 100 + lhs.missingRecommended.count
                let rhsScore = rhs.missingEssential.count * 100 + rhs.missingRecommended.count
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            var rows: [AdminWebBotPermissionsPayload.Guild] = []
            for guild in guilds {
                let coverage = try? await BotPermissionsProbe.channelCoverage(token: token, guildID: guild.id)
                let flags = { (severity: DiscordPermissionFlag.Severity) in
                    DiscordPermissionCatalog.all
                        .filter { $0.severity == severity && !guild.has($0) }
                        .map { AdminWebBotPermissionsPayload.Flag(name: $0.name, detail: $0.detail) }
                }
                let botID = identity?.id ?? ""
                rows.append(AdminWebBotPermissionsPayload.Guild(
                    id: guild.id,
                    name: guild.name,
                    isOwner: guild.isOwner,
                    hasAdministrator: guild.hasAdministrator,
                    missingEssential: flags(.essential),
                    missingRecommended: flags(.recommended),
                    missingOptional: flags(.optional),
                    visibleTextChannels: coverage?.visibleTextChannels,
                    reinviteURL: BotPermissionsProbe.reinviteURL(botID: botID, guildID: guild.id)?.absoluteString,
                    adminReinviteURL: BotPermissionsProbe.reinviteURL(botID: botID, guildID: guild.id, permissions: DiscordPermissionCatalog.administrator)?.absoluteString
                ))
            }
            return AdminWebBotPermissionsPayload(botUsername: identity?.username, error: nil, guilds: rows, checkedAt: Date())
        } catch let error as NSError {
            let message: String
            switch error.code {
            case 401: message = "Discord rejected the bot token (401). Re-check it in the SwiftBot app on the Mac."
            case 429: message = "Discord is rate-limiting SwiftBot (429). Try again in a few seconds."
            default: message = error.localizedDescription
            }
            return AdminWebBotPermissionsPayload(botUsername: nil, error: message, guilds: [], checkedAt: Date())
        }
    }
}

extension SweepRunReport {
    /// The WebUI previews a run from `groups`; `actions` lists every message
    /// (with its text) and made /api/sweep over 1 MB, so it's only sent for
    /// older reports that predate groups.
    var webTrimmed: SweepRunReport {
        guard groups != nil else { return self }
        return SweepRunReport(
            id: id, policyID: policyID, policyName: policyName, startedAt: startedAt,
            durationMS: durationMS, scanned: scanned, matched: matched, executed: executed,
            suppressed: suppressed, dryRun: dryRun, actions: [], error: error,
            summary: summary, groups: groups
        )
    }

    /// Counts and authors only: no message previews, examples or digest.
    var withoutMessageText: SweepRunReport {
        SweepRunReport(
            id: id, policyID: policyID, policyName: policyName, startedAt: startedAt,
            durationMS: durationMS, scanned: scanned, matched: matched, executed: executed,
            suppressed: suppressed, dryRun: dryRun, actions: [], error: error,
            summary: nil,
            groups: (groups ?? SweepActionGroup.summarise(actions)).map { group in
                var redacted = group
                redacted.examples = []
                return redacted
            }
        )
    }
}
