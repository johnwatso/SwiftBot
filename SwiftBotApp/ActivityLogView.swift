import SwiftUI

/// Unified Activity Log — merges `commandLog` (Discord command audit) and
/// `logs.lines` (system log) into a single chronological stream. Modeled on
/// SwiftMiner's `EventLogView`: search bar + filter chips + dense rows with
/// leading icon, title, secondary metadata, and trailing time. Replaces the
/// former Command Log + Logs tabs.
struct ActivityLogView: View {
    @EnvironmentObject var app: AppModel
    @State private var searchText: String = ""
    @State private var selectedFilters: Set<ActivityFilter> = Set(ActivityFilter.allCases)
    @State private var showClearConfirm = false
    @State private var isFilterHelpPresented = false

    enum ActivityKind {
        case command
        case system
        case mesh
        case audit
    }

    enum ActivityLevel {
        case info, ok, warning, error
    }

    enum ActivityFilter: String, CaseIterable, Identifiable {
        case commands = "Commands"
        case gateway = "Gateway"
        case system = "System"
        case mesh = "Mesh"
        case audit = "Audit"
        case errors = "Errors"
        case warnings = "Warnings"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .commands: return "terminal"
            case .gateway: return "message.fill"
            case .system: return "doc.text"
            case .mesh: return "point.3.connected.trianglepath.dotted"
            case .audit: return "lock.shield"
            case .errors: return "xmark.octagon"
            case .warnings: return "exclamationmark.triangle"
            }
        }
        var color: Color {
            switch self {
            case .commands: return .blue
            case .gateway: return ActivityCategory.discordBlurple
            case .system: return .gray
            case .mesh: return .cyan
            case .audit: return .purple
            case .errors: return .red
            case .warnings: return .yellow
            }
        }
    }

    struct ActivityEntry: Identifiable {
        let id: String
        let time: Date
        let kind: ActivityKind
        let level: ActivityLevel
        let title: String
        let detail: String?
    }

    private var unifiedEntries: [ActivityEntry] {
        var entries: [ActivityEntry] = []

        for cmd in app.commandLog {
            let detailParts = [
                friendlyUserName(cmd.user),
                friendlyServerName(cmd.server),
                friendlyTextChannelName(cmd.channel, server: cmd.server),
                cmd.executionRoute
            ]
                .filter { !$0.isEmpty }
            let rawTitle = cmd.command.isEmpty ? "(empty command)" : cmd.command
            entries.append(
                ActivityEntry(
                    id: "cmd-\(cmd.id.uuidString)",
                    time: cmd.time,
                    kind: .command,
                    level: cmd.ok ? .ok : .error,
                    title: Self.stripMarkers(rawTitle),
                    detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")
                )
            )
        }

        for audit in app.auditLog {
            let level: ActivityLevel = {
                switch audit.level {
                case .ok: return .ok
                case .warning: return .warning
                case .error: return .error
                case .info: return .info
                }
            }()
            let titleParts = ["[\(audit.source.rawValue)]", audit.action]
            let detailParts = [audit.actor, audit.detail ?? ""].filter { !$0.isEmpty }
            entries.append(
                ActivityEntry(
                    id: "audit-\(audit.id.uuidString)",
                    time: audit.time,
                    kind: .audit,
                    level: level,
                    title: titleParts.joined(separator: " "),
                    detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")
                )
            )
        }

        for (idx, line) in app.logs.lines.enumerated() {
            let parsed = parseLogLine(line)
            let text = parsed.title.lowercased()
            let isMesh = text.contains("mesh") || text.contains("standby") || text.contains("primary")
                || text.contains("failover") || text.contains("cluster") || text.contains("replicat")
                || text.contains("reclaim") || text.contains("worker") || text.contains("leader")
            entries.append(
                ActivityEntry(
                    id: "log-\(idx)",
                    time: parsed.time,
                    kind: isMesh ? .mesh : .system,
                    level: parsed.level,
                    title: parsed.title,
                    detail: nil
                )
            )
        }

        return entries.sorted { $0.time > $1.time }
    }

    private var visibleEntries: [ActivityEntry] {
        unifiedEntries.filter { entry in
            guard matchesFilter(entry) else { return false }
            return matchesSearch(entry)
        }
    }

    private func matchesFilter(_ entry: ActivityEntry) -> Bool {
        guard !selectedFilters.isEmpty else { return false }
        switch entry.kind {
        case .command:
            if entry.level == .error && selectedFilters.contains(.errors) { return true }
            return selectedFilters.contains(.commands)
        case .mesh:
            if entry.level == .error && selectedFilters.contains(.errors) { return true }
            if entry.level == .warning && selectedFilters.contains(.warnings) { return true }
            return selectedFilters.contains(.mesh)
        case .audit:
            if entry.level == .error && selectedFilters.contains(.errors) { return true }
            if entry.level == .warning && selectedFilters.contains(.warnings) { return true }
            return selectedFilters.contains(.audit)
        case .system:
            // Gateway-categorized system rows route to the Gateway chip.
            let isGatewayRow = ActivityCategory.infer(from: entry) == .gateway
            let bucketChip: ActivityFilter = isGatewayRow ? .gateway : .system
            switch entry.level {
            case .error: return selectedFilters.contains(.errors) || selectedFilters.contains(bucketChip)
            case .warning: return selectedFilters.contains(.warnings) || selectedFilters.contains(bucketChip)
            case .info, .ok: return selectedFilters.contains(bucketChip)
            }
        }
    }

    private func matchesSearch(_ entry: ActivityEntry) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let hay = "\(entry.title) \(entry.detail ?? "")"
        return hay.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ViewSectionHeader(title: "Activity", symbol: "list.bullet.clipboard.fill")
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        visibleEntries.map(formatForCopy).joined(separator: "\n"),
                        forType: .string
                    )
                }
                .disabled(visibleEntries.isEmpty)
                Button("Clear") { showClearConfirm = true }
                    .disabled(app.commandLog.isEmpty && app.logs.lines.isEmpty && app.auditLog.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            controlsHeader
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 10)

            Divider().opacity(0.3)

            if visibleEntries.isEmpty {
                emptyState
            } else {
                entryList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert("Clear all activity?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) {
                app.logs.clear()
                app.commandLog.removeAll()
                app.auditLog.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Both commands and system log lines will be removed. This cannot be undone.")
        }
    }

    private var controlsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            filterChipsRow
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Search activity", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private var filterChipsRow: some View {
        HStack(spacing: 8) {
            ForEach(ActivityFilter.allCases) { option in
                let isSelected = selectedFilters.contains(option)
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        if isSelected { selectedFilters.remove(option) }
                        else { selectedFilters.insert(option) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.symbol)
                            .font(.caption.weight(.semibold))
                        Text(option.rawValue)
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Group {
                            if isSelected {
                                Capsule().fill(.thinMaterial.opacity(0.95))
                            } else {
                                Capsule().fill(Color.clear)
                            }
                        }
                    )
                    .overlay(
                        Capsule()
                            .stroke(isSelected ? Color.primary.opacity(0.20) : Color.secondary.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Toggle \(option.rawValue)")
            }
            filterHelpButton
            Spacer()
            Text("\(visibleEntries.count) of \(unifiedEntries.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var filterHelpButton: some View {
        Button {
            isFilterHelpPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help("Explain activity filters and icons")
        .popover(isPresented: $isFilterHelpPresented, arrowEdge: .top) {
            ActivityFilterHelpPopover()
        }
    }

    private var entryList: some View {
        // Entries are sorted newest-first. Anchoring the scroll to the top edge
        // keeps the most recent row visible when new entries arrive, instead of
        // letting the list bump down and hide the new row off-screen.
        List {
            Color.clear
                .frame(height: 10)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())

            ForEach(visibleEntries) { entry in
                ActivityRow(entry: entry)
                    .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                    .listRowSeparator(.visible, edges: .bottom)
                    .listRowSeparatorTint(.secondary.opacity(0.14))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .defaultScrollAnchor(.top)
        .fadingEdges(top: 16, bottom: 20)
    }

    private var emptyState: some View {
        HStack {
            Text(emptyStateMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var emptyStateMessage: String {
        if selectedFilters.isEmpty { return "Select at least one filter" }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No activity matches your search"
        }
        return "No activity yet"
    }

    private func formatForCopy(_ entry: ActivityEntry) -> String {
        let time = entry.time.formatted(date: .abbreviated, time: .standard)
        let kind = entry.kind == .command ? "CMD" : "SYS"
        let level = String(describing: entry.level).uppercased()
        let detail = entry.detail.map { " · \($0)" } ?? ""
        return "[\(time)] [\(kind)/\(level)] \(entry.title)\(detail)"
    }

    private func friendlyUserName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let userID = discordMentionID(from: trimmed, marker: "@"),
           let displayName = app.knownUsersById[userID],
           !displayName.isEmpty {
            return displayName
        }
        if let displayName = app.knownUsersById[trimmed], !displayName.isEmpty {
            return displayName
        }
        if looksLikeDiscordID(trimmed) {
            return "User \(trimmed.suffix(4))"
        }
        return trimmed
    }

    private func friendlyServerName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let serverName = app.connectedServers[trimmed], !serverName.isEmpty {
            return serverName
        }
        if looksLikeDiscordID(trimmed) {
            return "Server \(trimmed.suffix(4))"
        }
        return trimmed
    }

    private func friendlyTextChannelName(_ raw: String, server: String?) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("#") { return trimmed }

        let channelID = discordMentionID(from: trimmed, marker: "#") ?? trimmed
        if let serverID = resolvedServerID(from: server),
           let channel = app.availableTextChannelsByServer[serverID]?.first(where: { matchesChannel($0, value: channelID) }) {
            return "#\(channel.name)"
        }
        if let channel = app.availableTextChannelsByServer.values
            .flatMap({ $0 })
            .first(where: { matchesChannel($0, value: channelID) }) {
            return "#\(channel.name)"
        }

        let lower = trimmed.lowercased()
        if lower == "dm" || lower == "direct message" || trimmed == "-" {
            return trimmed
        }
        if looksLikeDiscordID(channelID) {
            return "Channel \(channelID.suffix(4))"
        }
        return "#\(trimmed)"
    }

    private func matchesChannel(_ channel: GuildTextChannel, value: String) -> Bool {
        channel.id == value || channel.name.localizedCaseInsensitiveCompare(value) == .orderedSame
    }

    private func resolvedServerID(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if app.connectedServers[trimmed] != nil { return trimmed }
        return app.connectedServers.first { _, name in
            name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }?.key
    }

    private func discordMentionID(from value: String, marker: Character) -> String? {
        guard value.first == "<", value.dropFirst().first == marker, value.last == ">" else { return nil }
        let body = value.dropFirst(2).dropLast()
        return String(body).trimmingCharacters(in: CharacterSet(charactersIn: "!&"))
    }

    private func looksLikeDiscordID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 15 && trimmed.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    /// Parses a `LogStore` line of the form `[<ISO8601>] <text>` back into a
    /// timestamp + title + severity. Falls back to current time and `.info` if
    /// the timestamp can't be recovered.
    private struct ParsedLogLine {
        let time: Date
        let title: String
        let level: ActivityLevel
    }

    private static let isoFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    private func parseLogLine(_ line: String) -> ParsedLogLine {
        var stripped = line
        var time = Date()

        if line.hasPrefix("["),
           let closeIdx = line.firstIndex(of: "]") {
            let stampStr = String(line[line.index(after: line.startIndex)..<closeIdx])
            if let parsedTime = Self.isoFormatter.date(from: stampStr) {
                time = parsedTime
            }
            let after = line.index(after: closeIdx)
            stripped = String(line[after...]).trimmingCharacters(in: .whitespaces)
        }

        // Detect severity from bracket prefixes *or* legacy emoji markers,
        // then strip them so the row's leading SF Symbol is the only visual.
        let level: ActivityLevel = {
            if stripped.hasPrefix("[ERR]") || stripped.contains("❌") { return .error }
            if stripped.hasPrefix("[WARN]") || stripped.contains("⚠️") { return .warning }
            if stripped.hasPrefix("[OK]") || stripped.contains("✅") { return .ok }
            return .info
        }()

        return ParsedLogLine(time: time, title: Self.stripMarkers(stripped), level: level)
    }

    /// Removes bracket severity prefixes and emoji glyphs from a log line so
    /// the row's leading SF Symbol is the only place severity is rendered.
    static func stripMarkers(_ s: String) -> String {
        var out = s
        // Strip bracket severity prefixes
        for prefix in ["[ERR]", "[WARN]", "[OK]", "[INFO]"] {
            if out.hasPrefix(prefix) {
                out.removeFirst(prefix.count)
                break
            }
        }
        // Strip emoji / pictographic glyphs
        out = out.replacingOccurrences(
            of: "\\p{Extended_Pictographic}",
            with: "",
            options: .regularExpression
        )
        // Drop variation selectors and ZWJ left behind by stripping emoji.
        out.removeAll { $0 == "\u{FE0F}" || $0 == "\u{200D}" }
        return out
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

enum ActivityDashboardSummary {
    @MainActor
    static func metrics(app: AppModel) -> [DashboardMetricDescriptor] {
        let commandCount = app.commandLog.count
        let systemCount = app.logs.lines.count
        let warningCount = app.logs.lines.filter { line in
            let text = line.lowercased()
            return text.contains("warning") || text.contains("warn") || text.contains("⚠")
        }.count
        let errorCount = app.commandLog.filter { !$0.ok }.count + app.logs.lines.filter { line in
            let text = line.lowercased()
            return text.contains("error") || text.contains("failed") || text.contains("❌")
        }.count
        let lastCommand = app.commandLog.first?.time

        return [
            DashboardMetricDescriptor(
                id: "activity",
                title: "Activity",
                value: "\(commandCount + systemCount)",
                subtitle: "\(commandCount) commands · \(systemCount) system",
                symbol: "list.bullet.clipboard.fill",
                color: .blue
            ),
            DashboardMetricDescriptor(
                id: "activity-errors",
                title: "Errors",
                value: "\(errorCount)",
                subtitle: errorCount == 0 ? "No errors" : "Needs review",
                symbol: "xmark.octagon.fill",
                color: errorCount == 0 ? .gray : .red
            ),
            DashboardMetricDescriptor(
                id: "activity-warnings",
                title: "Warnings",
                value: "\(warningCount)",
                subtitle: warningCount == 0 ? "No warnings" : "Review log",
                symbol: "exclamationmark.triangle.fill",
                color: warningCount == 0 ? .gray : .yellow
            ),
            DashboardMetricDescriptor(
                id: "activity-last-event",
                title: "Last Event",
                value: lastCommand.map { relativeText(since: $0) } ?? "-",
                subtitle: app.commandLog.first.map { $0.command } ?? "No command events",
                symbol: "clock.fill",
                color: .teal
            )
        ]
    }

    private static func relativeText(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

private struct ActivityRow: View {
    let entry: ActivityLogView.ActivityEntry

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(entry.time, style: .time)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, entry.detail == nil ? 1 : 2)
    }

    private var category: ActivityCategory {
        ActivityCategory.infer(from: entry)
    }

    private var symbol: String {
        // Errors and warnings always win over the category icon so they stay
        // scannable; otherwise the inferred topic icon is used.
        if entry.level == .error { return "xmark.octagon.fill" }
        if entry.level == .warning { return "exclamationmark.triangle.fill" }
        return category.symbol
    }

    private var color: Color {
        if entry.level == .error { return .red }
        if entry.level == .warning { return .yellow }
        return category.color
    }
}

/// Inferred topic of an activity row. Drives the per-row SF Symbol so the eye
/// can scan the log by activity type at a glance (gateway / voice / mesh /
/// patchy / etc.), in addition to the filter-level chips above.
enum ActivityCategory: String, CaseIterable {
    case command
    case gateway
    case voice
    case mesh
    case patchy
    case ai
    case wiki
    case swiftMiner
    case audit
    case system

    var symbol: String {
        switch self {
        case .command: return "terminal"
        case .gateway: return "message.fill"
        case .voice: return "person.3.sequence"
        case .mesh: return "point.3.connected.trianglepath.dotted"
        case .patchy: return "square.and.arrow.down.badge.checkmark"
        case .ai: return "sparkles"
        case .wiki: return "rectangle.and.text.magnifyingglass"
        case .swiftMiner: return "hammer.fill"
        case .audit: return "lock.shield"
        case .system: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        // Discord blurple (#5865F2) for both Discord-driven rows: command +
        // gateway. Matches the brand and visually groups them as "Discord".
        case .command, .gateway: return Self.discordBlurple
        case .voice: return .pink
        case .mesh: return .teal
        case .patchy: return .orange
        case .ai: return .purple
        case .wiki: return .brown
        case .swiftMiner: return .mint
        case .audit: return .purple
        case .system: return .secondary
        }
    }

    /// Discord's brand blurple. Pulled from the official press kit (#5865F2).
    static let discordBlurple: Color = Color(
        red: 88.0 / 255.0,
        green: 101.0 / 255.0,
        blue: 242.0 / 255.0
    )

    var displayName: String {
        switch self {
        case .command: return "Command"
        case .gateway: return "Discord gateway"
        case .voice: return "Voice"
        case .mesh: return "SwiftMesh"
        case .patchy: return "Patchy"
        case .ai: return "AI"
        case .wiki: return "Lookup"
        case .swiftMiner: return "SwiftMiner"
        case .audit: return "Audit"
        case .system: return "System"
        }
    }

    var description: String {
        switch self {
        case .command: return "A Discord slash- or prefix-command was executed."
        case .gateway: return "Discord gateway connection events: connect, reconnect, intent rejection, heartbeats."
        case .voice: return "Voice state changes — joins, leaves, channel moves, presence events."
        case .mesh: return "SwiftMesh failover, replication, leader election, follower state."
        case .patchy: return "Patchy update sources — GPU/Steam/GitHub release notifications."
        case .ai: return "AI bot replies, model selection, provider routing."
        case .wiki: return "Gaming stat lookups and Finals wiki queries."
        case .swiftMiner: return "SwiftMiner DM relays and pairing state."
        case .audit: return "Security and admin events — logins, config changes, moderation actions."
        case .system: return "Anything else — generic app log lines."
        }
    }

    static func infer(from entry: ActivityLogView.ActivityEntry) -> ActivityCategory {
        if entry.kind == .command { return .command }
        if entry.kind == .audit { return .audit }
        let text = ((entry.title) + " " + (entry.detail ?? "")).lowercased()

        // Order matters: pick the first hit. Specific topics before generic ones.
        if text.contains("swiftminer") || text.contains("swiftminer:") { return .swiftMiner }
        if text.contains("patchy") || text.contains("update available") || text.contains("driver") { return .patchy }
        if text.contains("mesh") || text.contains("standby") || text.contains("primary") || text.contains("failover")
            || text.contains("cluster") || text.contains("replicat") || text.contains("reclaim") { return .mesh }
        if text.contains("voice") || text.contains("vc ") || text.contains("voice state") { return .voice }
        if text.contains("gateway") || text.contains("discord") || text.contains("intent") || text.contains("heartbeat")
            || text.contains("connect") || text.contains("reconnect") { return .gateway }
        if text.contains("ai ") || text.contains(" ai") || text.contains("openai") || text.contains("ollama")
            || text.contains("model") || text.contains("apple intelligence") { return .ai }
        if text.contains("wiki") { return .wiki }
        return .system
    }
}

private struct ActivityFilterHelpPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Activity Filters & Icons")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Filters")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Toggle which event types appear in the log. Errors and warnings can also be filtered independently of their topic.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                filterRow(symbol: "terminal", color: .blue, title: "Commands",
                          description: "Discord slash- and prefix-commands executed by the bot.")
                filterRow(symbol: "message.fill", color: ActivityCategory.discordBlurple, title: "Gateway",
                          description: "Discord gateway events — connect, reconnect, intent rejection, heartbeats.")
                filterRow(symbol: "point.3.connected.trianglepath.dotted", color: .cyan, title: "Mesh",
                          description: "SwiftMesh cluster events — promotion, demotion, sync, handover.")
                filterRow(symbol: "lock.shield", color: .purple, title: "Audit",
                          description: "Security and admin events — logins, config changes, moderation actions.")
                filterRow(symbol: "doc.text", color: .gray, title: "System",
                          description: "Anything else — generic app log lines.")
                filterRow(symbol: "xmark.octagon.fill", color: .red, title: "Errors",
                          description: "Anything that failed, regardless of topic.")
                filterRow(symbol: "exclamationmark.triangle.fill", color: .yellow, title: "Warnings",
                          description: "Non-fatal warnings — rate-limit nudges, mesh health misses, etc.")
            }

            Divider()

            // Categories that are inferred from log content but don't have their
            // own filter chip — surfaced here so users can recognise the row icon.
            let unfilteredCategories: [ActivityCategory] = [.voice, .patchy, .ai, .wiki, .swiftMiner]

            VStack(alignment: .leading, spacing: 8) {
                Text("Row icons")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Rows under the System filter pick up these icons based on their content:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ForEach(unfilteredCategories, id: \.self) { cat in
                    filterRow(symbol: cat.symbol, color: cat.color, title: cat.displayName, description: cat.description)
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }

    private func filterRow(symbol: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
