import Darwin
import Foundation

/// Operational health for the Overview: the status tiles, attention items, and
/// live activity feed. Shared by the native Overview and the admin WebUI so the
/// two always agree on what is healthy and what needs attention. Platform-
/// neutral on purpose — SwiftUI colors live in OverviewView's extensions.
struct OverviewHealthReport {
    enum State: String {
        case healthy
        case warning
        case critical
        case neutral
    }

    struct StatusTile: Identifiable {
        let id: String
        let title: String
        let value: String
        let detail: String
        let symbol: String
        let state: State
    }

    struct AttentionItem: Identifiable {
        enum Severity: Int {
            case critical = 3
            case warning = 2
            case info = 1

            var label: String {
                switch self {
                case .critical: return "Action"
                case .warning: return "Review"
                case .info: return "Note"
                }
            }

            var symbol: String {
                switch self {
                case .critical: return "exclamationmark.octagon.fill"
                case .warning: return "exclamationmark.triangle.fill"
                case .info: return "info.circle.fill"
                }
            }
        }

        let id: String
        let title: String
        let detail: String
        let severity: Severity
    }

    struct ActivityItem: Identifiable {
        /// Drives the item's color on each platform.
        enum Tone: String {
            case join, leave, move, command, commandFailed, info, warning, error, patchy
        }

        let id: String
        let timestamp: Date
        let title: String
        let detail: String
        let symbol: String
        let tone: Tone
    }

    struct Inputs {
        var status: BotStatus
        var settings: BotSettings
        var events: [ActivityEvent]
        var commandLog: [CommandLogEntry]
        /// Enabled Automations and Moderation rules.
        var enabledAutomationCount: Int
        var clusterNodes: [ClusterNodeStatus]
        var clusterSnapshot: ClusterSnapshot
        var diagnostics: ConnectionDiagnostics
        var lastGatewayEventName: String
        var intentsAccepted: Bool?
        var lastVoiceStateAt: Date?
        var lastClusterStatusSuccessAt: Date?
        var patchyLastCycleAt: Date?
        var patchyIsCycleRunning: Bool
        var memoryText: String
        var now = Date()
    }

    let overall: State
    let tiles: [StatusTile]
    let attention: [AttentionItem]
    let activity: [ActivityItem]

    var overallTitle: String {
        switch overall {
        case .healthy: return "Nominal"
        case .warning: return "Needs Review"
        case .critical: return "Action Required"
        case .neutral: return "Offline"
        }
    }

    init(_ inputs: Inputs) {
        let derived = Derived(inputs)
        overall = derived.overall
        tiles = derived.tiles
        attention = derived.attention
        activity = derived.activity
    }

    // MARK: - Memory

    static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    /// Average of `samples` (or the current footprint when empty), as "123 MB".
    static func memoryText(samples: [UInt64]) -> String {
        let source = samples.isEmpty ? [residentMemoryBytes()] : samples
        let valid = source.filter { $0 > 0 }
        guard !valid.isEmpty else { return "--" }
        let avg = valid.reduce(UInt64(0), +) / UInt64(valid.count)
        let megabytes = Int((Double(avg) / 1_048_576).rounded())
        return "\(megabytes) MB"
    }

    static func relativeText(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

// MARK: - Derivation

private struct Derived {
    typealias State = OverviewHealthReport.State
    typealias StatusTile = OverviewHealthReport.StatusTile
    typealias AttentionItem = OverviewHealthReport.AttentionItem
    typealias ActivityItem = OverviewHealthReport.ActivityItem

    let input: OverviewHealthReport.Inputs

    init(_ input: OverviewHealthReport.Inputs) {
        self.input = input
    }

    private var status: BotStatus { input.status }
    private var settings: BotSettings { input.settings }
    private var diagnostics: ConnectionDiagnostics { input.diagnostics }

    private var patchyEnabledTargetCount: Int {
        settings.patchy.sourceTargets.filter(\.isEnabled).count
    }

    private var enabledActionRuleCount: Int {
        input.enabledAutomationCount
    }

    private var failedCommandsToday: Int {
        input.commandLog.filter { Calendar.current.isDateInToday($0.time) && !$0.ok }.count
    }

    private var eventThroughputPerMinute: Double {
        let cutoff = input.now.addingTimeInterval(-300)
        return Double(input.events.filter { $0.timestamp >= cutoff }.count) / 5.0
    }

    private var lastOperationalSyncDate: Date? {
        [input.lastVoiceStateAt, input.lastClusterStatusSuccessAt, input.patchyLastCycleAt]
            .compactMap { $0 }
            .max()
    }

    var overall: State {
        if status == .reconnecting
            || ConnectionDiagnostics.isUnrecoverableGatewayCloseCode(diagnostics.lastGatewayCloseCode)
            || failedCommandsToday >= 5 {
            return .critical
        }
        if status == .connecting
            || failedCommandsToday > 0
            || ConnectionDiagnostics.isGatewayHeartbeatWarning(diagnostics.heartbeatLatencyMs) {
            return .warning
        }
        if status == .running || settings.clusterMode == .worker {
            return .healthy
        }
        return .neutral
    }

    // MARK: Status tiles

    private var discordConnectivityLabel: String {
        switch diagnostics.restHealth {
        case .ok: return "REST OK"
        case .error(let code, _): return code == 0 ? "Unavailable" : "HTTP \(code)"
        case .unknown:
            if status == .running { return "Gateway OK" }
            return "Unknown"
        }
    }

    private var discordConnectivityDetail: String {
        switch diagnostics.restHealth {
        case .ok:
            return diagnostics.rateLimitRemaining.map { "\($0) REST requests remaining" } ?? "REST probe succeeded"
        case .error(_, let message):
            return message
        case .unknown:
            return diagnostics.lastTestMessage.isEmpty ? "REST probe not run" : diagnostics.lastTestMessage
        }
    }

    private var discordConnectivityState: State {
        switch diagnostics.restHealth {
        case .ok: return .healthy
        case .error: return .critical
        case .unknown: return status == .running ? .healthy : .neutral
        }
    }

    var tiles: [StatusTile] {
        let latency = diagnostics.heartbeatLatencyMs

        return [
            StatusTile(
                id: "gateway-latency",
                title: "Gateway Heartbeat",
                value: latency.map { "\($0) ms" } ?? "--",
                detail: GatewayEventPresentation.statusDetail(for: input.lastGatewayEventName),
                symbol: "antenna.radiowaves.left.and.right",
                state: latency.map {
                    ConnectionDiagnostics.isGatewayHeartbeatWarning($0) ? .warning : .healthy
                } ?? (status == .running ? .warning : .neutral)
            ),
            StatusTile(
                id: "cluster-role",
                title: "Cluster Role",
                value: settings.clusterMode.displayName,
                detail: settings.clusterNodeName.isEmpty ? input.clusterSnapshot.nodeName : settings.clusterNodeName,
                symbol: "point.3.connected.trianglepath.dotted",
                state: input.clusterNodes.contains(where: { $0.status == .disconnected }) ? .warning : .healthy
            ),
            StatusTile(
                id: "last-sync",
                title: "Last Sync",
                value: lastOperationalSyncDate.map { OverviewHealthReport.relativeText(since: $0, now: input.now) } ?? "--",
                detail: input.lastVoiceStateAt == nil ? "No voice state yet" : "Voice state observed",
                symbol: "arrow.triangle.2.circlepath",
                state: lastOperationalSyncDate == nil ? .neutral : .healthy
            ),
            StatusTile(
                id: "memory",
                title: "Memory",
                value: input.memoryText,
                detail: "Average resident footprint",
                symbol: "memorychip",
                state: .neutral
            ),
            StatusTile(
                id: "discord",
                title: "Discord Connectivity",
                value: discordConnectivityLabel,
                detail: discordConnectivityDetail,
                symbol: "checkmark.icloud",
                state: discordConnectivityState
            ),
            StatusTile(
                id: "throughput",
                title: "Event Throughput",
                value: String(format: "%.1f/min", eventThroughputPerMinute),
                detail: "\(input.events.count) retained runtime events",
                symbol: "waveform.path.ecg",
                state: .healthy
            ),
            StatusTile(
                id: "rate-limit",
                title: "Rate Limit",
                value: diagnostics.rateLimitRemaining.map { "\($0) rem." } ?? "--",
                detail: diagnostics.rateLimitRemaining == nil
                    ? "No REST traffic yet"
                    : "Per-route headroom",
                symbol: "gauge.with.needle",
                state: {
                    guard let rem = diagnostics.rateLimitRemaining else { return .neutral }
                    if rem == 0 { return .critical }
                    if rem < 5 { return .warning }
                    return .healthy
                }()
            ),
            StatusTile(
                id: "intents",
                title: "Intents",
                value: {
                    if diagnostics.lastGatewayCloseCode == 4014 { return "Rejected" }
                    return input.intentsAccepted.map { $0 ? "Accepted" : "Unknown" } ?? "--"
                }(),
                detail: diagnostics.lastGatewayCloseCode == 4014
                    ? "Enable privileged intents in Discord portal"
                    : "Gateway intent negotiation",
                symbol: "checklist",
                state: {
                    if diagnostics.lastGatewayCloseCode == 4014 { return .critical }
                    if input.intentsAccepted == true { return .healthy }
                    return .neutral
                }()
            )
        ]
    }

    // MARK: Live activity

    private func activityTitle(for kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .voiceJoin: return "User Joined Voice"
        case .voiceLeave: return "User Left Voice"
        case .voiceMove: return "Voice Channel Move"
        case .command: return "Command Executed"
        case .info: return "Runtime Event"
        case .warning: return "Runtime Warning"
        case .error: return "Runtime Error"
        }
    }

    private func activitySymbol(for kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .voiceJoin, .voiceLeave, .voiceMove: return "waveform"
        case .command: return "terminal"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func activityTone(for kind: ActivityEvent.Kind) -> ActivityItem.Tone {
        switch kind {
        case .voiceJoin: return .join
        case .voiceLeave: return .leave
        case .voiceMove: return .move
        case .command: return .command
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }

    private func cleanedActivityMessage(_ message: String) -> String {
        ["🟢 ", "🔴 ", "🔀 ", "✅ ", "⚠️ ", "❌ "].reduce(message) { cleaned, marker in
            cleaned.replacingOccurrences(of: marker, with: "")
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var activity: [ActivityItem] {
        var items = input.events.prefix(8).map { event in
            ActivityItem(
                id: "event-\(event.id)",
                timestamp: event.timestamp,
                title: activityTitle(for: event.kind),
                detail: cleanedActivityMessage(event.message),
                symbol: activitySymbol(for: event.kind),
                tone: activityTone(for: event.kind)
            )
        }

        items += input.commandLog.prefix(4).map { command in
            ActivityItem(
                id: "command-\(command.id)",
                timestamp: command.time,
                title: command.ok ? "Command Executed" : "Command Failed",
                detail: "\(command.user) ran \(command.command)",
                symbol: "terminal",
                tone: command.ok ? .command : .commandFailed
            )
        }

        if input.patchyIsCycleRunning {
            items.append(ActivityItem(
                id: "patchy-running",
                timestamp: input.now,
                title: "Patchy Running",
                detail: "Update monitoring cycle is active",
                symbol: "square.and.arrow.down.badge.checkmark",
                tone: .patchy
            ))
        } else if let lastCycle = input.patchyLastCycleAt {
            items.append(ActivityItem(
                id: "patchy-\(lastCycle.timeIntervalSince1970)",
                timestamp: lastCycle,
                title: "Patchy Checked",
                detail: "\(patchyEnabledTargetCount) targets monitored",
                symbol: "hammer",
                tone: .patchy
            ))
        }

        return Array(items.sorted { $0.timestamp > $1.timestamp }.prefix(10))
    }

    // MARK: Attention

    var attention: [AttentionItem] {
        var items: [AttentionItem] = []

        if status != .running && settings.clusterMode != .worker {
            items.append(AttentionItem(
                id: "gateway-status",
                title: "Gateway is \(status.rawValue.capitalized)",
                detail: "Live Discord operations are limited until the gateway is running.",
                severity: status == .reconnecting ? .critical : .warning
            ))
        }

        if let closeCode = diagnostics.lastGatewayCloseCode {
            let needsAction = ConnectionDiagnostics.isUnrecoverableGatewayCloseCode(closeCode)
            items.append(AttentionItem(
                id: "gateway-close",
                title: needsAction ? "Discord rejected the gateway connection" : "Discord gateway closed",
                detail: "Close code \(closeCode). \(ConnectionDiagnostics.gatewayCloseRemedy(for: closeCode))",
                severity: needsAction ? .critical : .warning
            ))
        }

        if let latency = diagnostics.heartbeatLatencyMs,
           ConnectionDiagnostics.isGatewayHeartbeatWarning(latency) {
            items.append(AttentionItem(
                id: "latency",
                title: "Gateway heartbeat elevated",
                detail: "\(latency) ms median heartbeat ACK is above the normal operating band.",
                severity: ConnectionDiagnostics.isGatewayHeartbeatCritical(latency) ? .critical : .warning
            ))
        }

        // Only flag a quiet feed if the gateway is healthy AND the silence is unusually long.
        // A quiet bot is not a broken bot — most servers have idle stretches.
        if status == .running,
           diagnostics.heartbeatLatencyMs != nil,
           let newestEventAt = input.events.first?.timestamp {
            let lag = input.now.timeIntervalSince(newestEventAt)
            if lag >= 14_400 { // 4 hours
                let hours = Int(lag / 3600)
                items.append(AttentionItem(
                    id: "event-flow-quiet",
                    title: "Runtime feed quiet",
                    detail: "No runtime events in the last \(hours) hour\(hours == 1 ? "" : "s"). The gateway is connected, so Discord activity may simply be low. Restart the bot if you expect events.",
                    severity: .info
                ))
            }
        }

        if settings.clusterMode == .worker || settings.clusterMode == .standby {
            let workerState = input.clusterSnapshot.workerState
            if workerState == .failed || workerState == .degraded {
                let target = settings.clusterLeaderAddress.isEmpty
                    ? "the configured primary"
                    : settings.clusterLeaderAddress
                items.append(AttentionItem(
                    id: "cluster-leader",
                    title: "Cluster primary unreachable",
                    detail: "Cannot reach \(target): \(input.clusterSnapshot.workerStatusText)",
                    severity: workerState == .failed ? .critical : .warning
                ))
            }
        }

        if failedCommandsToday > 0 {
            items.append(AttentionItem(
                id: "failed-commands",
                title: "Command failures today",
                detail: "\(failedCommandsToday) command\(failedCommandsToday == 1 ? "" : "s") failed and may need review.",
                severity: failedCommandsToday >= 5 ? .critical : .warning
            ))
        }

        if enabledActionRuleCount == 0 {
            items.append(AttentionItem(
                id: "rules",
                title: "No active workflows",
                detail: "Rules are configured, but none are currently enabled for automation.",
                severity: .info
            ))
        }

        if settings.patchy.monitoringEnabled && patchyEnabledTargetCount == 0 {
            items.append(AttentionItem(
                id: "patchy-targets",
                title: "Patchy has no enabled targets",
                detail: "Monitoring is on, but there are no delivery targets to check.",
                severity: .warning
            ))
        }

        let degradedNodes = input.clusterNodes.filter { $0.status == .degraded || $0.status == .disconnected }
        if settings.clusterMode != .standalone && !degradedNodes.isEmpty {
            items.append(AttentionItem(
                id: "cluster-nodes",
                title: "SwiftMesh node health",
                detail: "\(degradedNodes.count) cluster node\(degradedNodes.count == 1 ? "" : "s") need attention.",
                severity: degradedNodes.contains(where: { $0.status == .disconnected }) ? .critical : .warning
            ))
        }

        return items.sorted {
            if $0.severity.rawValue != $1.severity.rawValue {
                return $0.severity.rawValue > $1.severity.rawValue
            }
            return $0.title < $1.title
        }
    }
}
