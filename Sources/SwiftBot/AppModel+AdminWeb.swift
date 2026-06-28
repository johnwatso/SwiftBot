import Foundation
import SwiftUI
import AppKit
import AVFoundation
import Darwin

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
            runtimeState: clusterSnapshot.runtimeState.rawValue
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
            localAISystemPrompt: settings.localAISystemPrompt
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
        let enabledRuleCount = ruleStore.rules.filter(\.isEnabled).count
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

        return AdminWebAnalyticsPayload(
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
                bugTrackingEnabled: settings.bugTrackingEnabled,
                prefix: "/"
            ),
            appleIntelligence: .init(
                localAIDMReplyEnabled: settings.localAIDMReplyEnabled
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
        if let value = patch.slashCommandsEnabled { settings.slashCommandsEnabled = value }
        if let value = patch.bugTrackingEnabled { settings.bugTrackingEnabled = value }
        if let value = patch.localAIDMReplyEnabled { settings.localAIDMReplyEnabled = value }
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
            sourceKinds: PatchySourceKind.allCases.map(\.rawValue),
            targets: settings.patchy.sourceTargets,
            servers: servers,
            textChannelsByServer: textChannelsByServer,
            rolesByServer: rolesByServer,
            steamAppNames: settings.patchy.steamAppNames,
            isFailoverManagedNode: isFailoverManagedNode,
            botStatus: status.rawValue,
            debugLogs: Array(patchyDebugLogs.prefix(80))
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
        if let showDebug = patch.showDebug {
            settings.patchy.showDebug = showDebug
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

    func sendAdminWebPatchyTest(_ targetID: UUID) -> Bool {
        sendPatchyTest(targetID: targetID)
        return true
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
            )
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
            }()
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
                        runtimeState: nil
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
                        commands: .init(enabled: true, prefixEnabled: false, slashEnabled: true, bugTrackingEnabled: true, prefix: "/"),
                        appleIntelligence: .init(localAIDMReplyEnabled: false),
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
            analyticsProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebAnalyticsPayload.empty
                }
                return await model.adminWebAnalyticsSnapshot()
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
                        commands: .init(enabled: true, prefixEnabled: false, slashEnabled: true, bugTrackingEnabled: true, prefix: "/"),
                        appleIntelligence: .init(localAIDMReplyEnabled: false),
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
                        prefixCommandsEnabled: false,
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
                        installedVoices: []
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

                    let installedVoices = AVSpeechSynthesisVoice.speechVoices()
                        .sorted {
                            if $0.language != $1.language { return $0.language < $1.language }
                            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                        }
                        .map { voice -> AdminWebSimpleOption in
                            let quality: String
                            switch voice.quality {
                            case .premium: quality = "Premium"
                            case .enhanced: quality = "Enhanced"
                            default: quality = "Default"
                            }
                            return AdminWebSimpleOption(
                                id: voice.identifier,
                                name: "\(voice.name) — \(voice.language) (\(quality))"
                            )
                        }

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
                        installedVoices: installedVoices
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
            patchyProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebPatchyPayload(
                        monitoringEnabled: false,
                        showDebug: false,
                        isCycleRunning: false,
                        lastCycleAt: nil,
                        sourceKinds: PatchySourceKind.allCases.map(\.rawValue),
                        targets: [],
                        servers: [],
                        textChannelsByServer: [:],
                        rolesByServer: [:],
                        steamAppNames: [:],
                        isFailoverManagedNode: false,
                        botStatus: "stopped",
                        debugLogs: []
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
            pullPatchyTarget: { [weak self] targetID in
                guard let model = self else { return false }
                return await MainActor.run { model.pullAdminWebPatchyTarget(targetID) }
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
            mediaStreamProvider: { [weak self] token, rangeHeader, quality in
                guard let model = self else { return nil }
                return await model.adminWebMediaStreamResponse(token: token, rangeHeader: rangeHeader, quality: quality)
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
            sweepProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebSweepPayload(
                        globalPaused: false, state: "Idle", stateTone: "gray", nextRunDescription: "Unknown",
                        enabledPolicyCount: 0, totalPolicyCount: 0, messagesTodayCount: 0, suppressedTodayCount: 0, summariesThisWeekCount: 0,
                        policies: [], recentReports: [], suggestions: [], isScanningSuggestions: false, lastSuggestionScanAt: nil, scanProgressDone: 0, scanProgressTotal: 0
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
            generateSwiftMeshJoinCode: { [weak self] in
                guard let model = self else { return nil }
                // Only Primary nodes have a meaningful Join Code to share.
                let isLeader = await MainActor.run { model.settings.clusterMode == .leader }
                guard isLeader else { return nil }
                return await model.generateSwiftMeshJoinCode()
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
                    recentReports: s.recentReports,
                    suggestions: s.suggestions,
                    isScanningSuggestions: s.isScanningSuggestions,
                    lastSuggestionScanAt: s.lastSuggestionScanAt,
                    scanProgressDone: s.scanProgress.done,
                    scanProgressTotal: s.scanProgress.total
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
