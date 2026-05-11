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

    enum ActivityKind {
        case command
        case system
    }

    enum ActivityLevel {
        case info, ok, warning, error
    }

    enum ActivityFilter: String, CaseIterable, Identifiable {
        case commands = "Commands"
        case system = "System"
        case errors = "Errors"
        case warnings = "Warnings"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .commands: return "terminal"
            case .system: return "doc.text"
            case .errors: return "xmark.octagon"
            case .warnings: return "exclamationmark.triangle"
            }
        }
        var color: Color {
            switch self {
            case .commands: return .blue
            case .system: return .gray
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
            let detailParts = [cmd.user, cmd.server, cmd.channel, cmd.executionRoute]
                .filter { !$0.isEmpty }
            entries.append(
                ActivityEntry(
                    id: "cmd-\(cmd.id.uuidString)",
                    time: cmd.time,
                    kind: .command,
                    level: cmd.ok ? .ok : .error,
                    title: cmd.command.isEmpty ? "(empty command)" : cmd.command,
                    detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")
                )
            )
        }

        for (idx, line) in app.logs.lines.enumerated() {
            let parsed = parseLogLine(line)
            entries.append(
                ActivityEntry(
                    id: "log-\(idx)",
                    time: parsed.time,
                    kind: .system,
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
        case .system:
            switch entry.level {
            case .error: return selectedFilters.contains(.errors) || selectedFilters.contains(.system)
            case .warning: return selectedFilters.contains(.warnings) || selectedFilters.contains(.system)
            case .info, .ok: return selectedFilters.contains(.system)
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
                    .disabled(app.commandLog.isEmpty && app.logs.lines.isEmpty)
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
            Spacer()
            Text("\(visibleEntries.count) of \(unifiedEntries.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var entryList: some View {
        List(visibleEntries) { entry in
            ActivityRow(entry: entry)
                .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                .listRowSeparator(.visible, edges: .bottom)
                .listRowSeparatorTint(.secondary.opacity(0.14))
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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

        let level: ActivityLevel = {
            if stripped.contains("❌") { return .error }
            if stripped.contains("⚠️") { return .warning }
            if stripped.contains("✅") { return .ok }
            return .info
        }()

        return ParsedLogLine(time: time, title: stripped, level: level)
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
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, entry.detail == nil ? 1 : 2)
    }

    private var symbol: String {
        switch entry.level {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .ok: return entry.kind == .command ? "terminal.fill" : "checkmark.circle.fill"
        case .info: return entry.kind == .command ? "terminal" : "circle.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .error: return .red
        case .warning: return .yellow
        case .ok: return entry.kind == .command ? .blue : .green
        case .info: return entry.kind == .command ? .blue : .gray
        }
    }
}
