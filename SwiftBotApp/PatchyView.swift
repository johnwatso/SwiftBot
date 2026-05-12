import SwiftUI

struct PatchyView: View {
    @EnvironmentObject var app: AppModel

    @State private var editorDraft: PatchyTargetDraft?
    @State private var editorMode: PatchyEditorMode = .create

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. Patchy settings sync from Primary.")
            }
            statusRail
            monitoringControlsSection
            sourceTargetList
            activityFeed
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .disabled(app.isFailoverManagedNode)
        .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        .sheet(item: $editorDraft) { draft in
            PatchyTargetEditorSheet(
                draft: draft,
                mode: editorMode,
                connectedServers: app.connectedServers,
                channelsByServer: app.availableTextChannelsByServer,
                rolesByServer: app.availableRolesByServer,
                onCancel: { editorDraft = nil },
                onSave: { updated in
                    if editorMode == .create {
                        app.addPatchyTarget(updated.toTarget())
                    } else {
                        app.updatePatchyTarget(updated.toTarget())
                    }
                    editorDraft = nil
                }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ViewSectionHeader(title: "Patchy", symbol: "hammer.fill")
            Spacer()
            Button {
                editorMode = .create
                editorDraft = PatchyTargetDraft.makeNew(defaultServer: sortedServerIDs().first, app: app)
            } label: {
                Label("Add Target", systemImage: "plus")
            }
            .buttonStyle(GlassActionButtonStyle())
        }
    }

    // MARK: - Status Rail

    private var statusRail: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
            spacing: 8
        ) {
            DashboardMetricCard(
                title: "Sources",
                value: "\(Set(app.settings.patchy.sourceTargets.map(\.source)).count)",
                subtitle: sourceBreakdownSubtitle,
                symbol: "square.stack.3d.up.fill",
                color: .orange
            )
            DashboardMetricCard(
                title: "Active",
                value: "\(app.settings.patchy.sourceTargets.filter(\.isEnabled).count)",
                subtitle: "Monitoring",
                symbol: "checkmark.circle.fill",
                color: .green
            )
            DashboardMetricCard(
                title: "Targets",
                value: "\(app.settings.patchy.sourceTargets.count)",
                subtitle: "Configured",
                symbol: "hammer.fill",
                color: .secondary
            )
            DashboardMetricCard(
                title: "Last Cycle",
                value: lastCycleValue,
                subtitle: lastCycleSubtitle,
                symbol: "clock.arrow.circlepath",
                color: .gray
            )
        }
    }

    private var sourceBreakdownSubtitle: String {
        let counts = Dictionary(grouping: app.settings.patchy.sourceTargets) { $0.source }
            .mapValues { $0.count }
        let parts = PatchySourceKind.allCases.compactMap { kind -> String? in
            guard let count = counts[kind], count > 0 else { return nil }
            return "\(sourceLabel(kind)) \(count)"
        }
        return parts.isEmpty ? "No sources" : parts.joined(separator: "  ")
    }

    private var lastCycleValue: String {
        guard let last = app.patchyLastCycleAt else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: last, relativeTo: Date())
    }

    private var lastCycleSubtitle: String {
        if app.patchyIsCycleRunning {
            return "Running now…"
        }
        guard app.patchyLastCycleAt != nil else { return "Never" }
        return "Idle"
    }

    // MARK: - Monitoring Controls Section

    private var monitoringControlsSection: some View {
        HStack(spacing: 12) {
            Toggle("Monitoring", isOn: Binding(
                get: { app.settings.patchy.monitoringEnabled },
                set: { newValue in
                    app.settings.patchy.monitoringEnabled = newValue
                    app.saveSettings()
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle("Debug", isOn: Binding(
                get: { app.settings.patchy.showDebug },
                set: { newValue in
                    app.settings.patchy.showDebug = newValue
                    app.saveSettings()
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Spacer()

            HStack(spacing: 6) {
                if app.patchyIsCycleRunning {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Running…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let last = app.patchyLastCycleAt {
                    Text(last, style: .relative)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                app.runPatchyManualCheck()
            } label: {
                Label("Run Now", systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(app.patchyIsCycleRunning)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Source Target List

    private var sourceTargetList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if app.settings.patchy.sourceTargets.isEmpty {
                    emptyTargetsState
                }

                ForEach(groupedTargets(), id: \.source) { group in
                    SwiftMeshSection(
                        title: sourceLabel(group.source),
                        symbol: sourceIcon(group.source)
                    ) {
                        LazyVStack(spacing: 8) {
                            ForEach(group.targets) { target in
                                PatchTargetCard(
                                    target: target,
                                    sourceDisplayName: sourceDisplayName(for: target),
                                    serverName: serverName(for: target),
                                    channelName: channelName(for: target),
                                    roleSummary: roleSummary(for: target),
                                    sourceColor: sourceColor(target.source),
                                    onTestSend: { app.sendPatchyTest(targetID: target.id) },
                                    onPull: { app.pullPatchyUpdate(targetID: target.id) },
                                    onEdit: {
                                        editorMode = .edit
                                        editorDraft = PatchyTargetDraft(target: target)
                                    },
                                    onToggleEnabled: { app.togglePatchyTargetEnabled(target.id) },
                                    onDelete: { app.deletePatchyTarget(target.id) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyTargetsState: some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No targets configured")
                .font(.subheadline.weight(.semibold))
            Text("Monitor release updates from Steam, GitHub, and GPU vendors.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                editorMode = .create
                editorDraft = PatchyTargetDraft.makeNew(defaultServer: sortedServerIDs().first, app: app)
            } label: {
                Label("Add First Target", systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Activity Feed

    private var activityFeed: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }

            if app.patchyDebugLogs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("No activity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(app.patchyDebugLogs.prefix(60).enumerated()), id: \.offset) { index, line in
                        patchyActivityRow(line)
                        if index < min(app.patchyDebugLogs.count, 60) - 1 {
                            Divider()
                                .opacity(0.18)
                                .padding(.leading, 28)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 280, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func patchyActivityRow(_ line: String) -> some View {
        let parsed = PatchyLogParser.parse(line)
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: parsed.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(parsed.color)
                .frame(width: 18, height: 18)
                .background(parsed.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(parsed.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                if !parsed.detail.isEmpty {
                    Text(parsed.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func groupedTargets() -> [PatchySourceGroup] {
        let grouped = Dictionary(grouping: app.settings.patchy.sourceTargets) { $0.source }
        return grouped
            .map { PatchySourceGroup(source: $0.key, targets: $0.value.sorted { $0.channelId < $1.channelId }) }
            .sorted { sourceLabel($0.source) < sourceLabel($1.source) }
    }

    private func sortedServerIDs() -> [String] {
        app.connectedServers.keys.sorted {
            (app.connectedServers[$0] ?? "").localizedCaseInsensitiveCompare(app.connectedServers[$1] ?? "") == .orderedAscending
        }
    }

    private func sourceLabel(_ source: PatchySourceKind) -> String {
        source.rawValue
    }

    private func sourceColor(_ source: PatchySourceKind) -> Color {
        switch source {
        case .nvidia: return .green
        case .amd: return .red
        case .intel: return .blue
        case .steam: return .indigo
        case .github: return .orange
        }
    }

    private func sourceDisplayName(for target: PatchySourceTarget) -> String {
        switch target.source {
        case .steam:
            let appID = target.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appID.isEmpty else { return "Steam" }
            if let name = app.settings.patchy.steamAppNames[appID], !name.isEmpty {
                return "Steam • \(name) (\(appID))"
            }
            return "Steam (\(appID))"
        case .github:
            let repo = target.githubRepo.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = target.githubWatchAllCommits
                ? "commits\(target.githubBranch.isEmpty ? "" : " · \(target.githubBranch)")"
                : "releases"
            return repo.isEmpty ? "GitHub" : "GitHub • \(repo) (\(suffix))"
        default:
            return target.source.rawValue
        }
    }

    private func sourceIcon(_ source: PatchySourceKind) -> String {
        switch source {
        case .amd: return "a.circle.fill"
        case .nvidia: return "n.square.fill"
        case .intel: return "i.circle.fill"
        case .steam: return "gamecontroller.fill"
        case .github: return "chevron.left.forwardslash.chevron.right"
        }
    }

    private func serverName(for target: PatchySourceTarget) -> String {
        let trimmed = target.serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Not set" }
        if let name = app.connectedServers[trimmed], !name.isEmpty {
            return name
        }
        return "Server \(trimmed.suffix(4))"
    }

    private func channelName(for target: PatchySourceTarget) -> String {
        let channelID = target.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty else { return "Not set" }
        if let channel = app.availableTextChannelsByServer[target.serverId]?.first(where: { $0.id == channelID }) {
            return "#\(channel.name)"
        }
        if let channel = app.availableTextChannelsByServer.values.joined().first(where: { $0.id == channelID }) {
            return "#\(channel.name)"
        }
        return "Channel \(channelID.suffix(4))"
    }

    private func roleSummary(for target: PatchySourceTarget) -> String {
        let roles = app.availableRolesByServer[target.serverId] ?? []
        let names = roles
            .filter { target.roleIDs.contains($0.id) }
            .map(\.name)
        if names.isEmpty {
            return "No mentions"
        }
        return names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " +\(names.count - 2)" : "")
    }
}

// MARK: - Patchy Log Parser

private enum PatchyLogParser {
    struct ParsedLine {
        let title: String
        let detail: String
        let symbol: String
        let color: Color
    }

    static func parse(_ line: String) -> ParsedLine {
        let lower = line.lowercased()
        let (symbol, color): (String, Color) = {
            if lower.contains("error") || lower.contains("failed") || lower.contains("❌") || lower.contains("[err]") {
                return ("xmark.circle.fill", .red)
            }
            if lower.contains("warning") || lower.contains("cannot") || lower.contains("not found") || lower.contains("permissions") || lower.contains("[warn]") {
                return ("exclamationmark.triangle.fill", .yellow)
            }
            if lower.contains("success") || lower.contains("sent") || lower.contains("ready") || lower.contains("succeeded") || lower.contains("✅") || lower.contains("[ok]") {
                return ("checkmark.circle.fill", .green)
            }
            return ("info.circle.fill", .secondary)
        }()

        // Strip common prefixes
        var cleaned = line
            .replacingOccurrences(of: #"\[(OK|WARN|ERR|INFO)\]\s*"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\p{Extended_Pictographic}", with: "", options: .regularExpression)
        cleaned.removeAll { $0 == "\u{FE0F}" || $0 == "\u{200D}" }
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)

        // Split title / detail at first sentence boundary or colon
        let title: String
        let detail: String
        if let colonRange = cleaned.range(of: ": "), cleaned.distance(from: cleaned.startIndex, to: colonRange.lowerBound) < 60 {
            title = String(cleaned[..<colonRange.lowerBound])
            detail = String(cleaned[colonRange.upperBound...])
        } else if cleaned.count > 80 {
            let idx = cleaned.index(cleaned.startIndex, offsetBy: 60)
            title = String(cleaned[..<idx]) + "…"
            detail = cleaned
        } else {
            title = cleaned
            detail = ""
        }

        return ParsedLine(title: title, detail: detail, symbol: symbol, color: color)
    }
}

// MARK: - Source Group

private struct PatchySourceGroup {
    let source: PatchySourceKind
    let targets: [PatchySourceTarget]
}

// MARK: - Target Card

private struct PatchTargetCard: View {
    let target: PatchySourceTarget
    let sourceDisplayName: String
    let serverName: String
    let channelName: String
    let roleSummary: String
    let sourceColor: Color
    let onTestSend: () -> Void
    let onPull: () -> Void
    let onEdit: () -> Void
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title row
            HStack(spacing: 8) {
                Image(systemName: sourceIcon(target.source))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(sourceColor)
                    .frame(width: 22, height: 22)
                    .background(sourceColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(sourceDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                PatchyStatusPill(isEnabled: target.isEnabled)
            }

            // Detail rows
            VStack(alignment: .leading, spacing: 4) {
                DiagnosticsLine(label: "Server", value: serverName, tone: .primary)
                DiagnosticsLine(label: "Channel", value: channelName, tone: .primary)
                DiagnosticsLine(label: "Mentions", value: roleSummary, tone: .primary)
                DiagnosticsLine(
                    label: "Last Run",
                    value: timestamp(target.lastRunAt),
                    tone: target.lastRunAt == nil ? .secondary : .primary
                )
            }

            // Status line
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if target.lastStatus != "Ready"
                    && target.lastStatus != "Never checked"
                    && !target.lastStatus.contains("succeeded")
                    && !target.lastStatus.contains("successfully")
                    && !target.lastStatus.contains("Unchanged")
                    && !target.lastStatus.contains("unchanged")
                {
                    Image(systemName: isWarning(target.lastStatus) ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(isWarning(target.lastStatus) ? .yellow : .red)
                        .font(.caption)
                }
                Text(target.lastStatus)
                    .font(.caption)
                    .foregroundStyle(statusColor(target.lastStatus))
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(statusColor(target.lastStatus).opacity(0.06))
            )

            // Action buttons
            HStack(spacing: 6) {
                PatchyIconButton(symbol: "paperplane.fill", color: .primary, help: "Test send") { onTestSend() }
                PatchyIconButton(symbol: "arrow.down.circle.fill", color: .primary, help: "Pull update") { onPull() }
                PatchyIconButton(symbol: "pencil", color: .primary, help: "Edit target") { onEdit() }
                PatchyIconButton(
                    symbol: target.isEnabled ? "pause.circle.fill" : "play.circle.fill",
                    color: target.isEnabled ? .orange : .green,
                    help: target.isEnabled ? "Disable" : "Enable"
                ) { onToggleEnabled() }
                PatchyIconButton(symbol: "trash", color: .red, help: "Delete target") { showDeleteConfirm = true }
                    .alert("Delete Target?", isPresented: $showDeleteConfirm) {
                        Button("Delete", role: .destructive) { onDelete() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("\"\(sourceDisplayName)\" will be permanently deleted.")
                    }
                Spacer()
            }
        }
        .padding(10)
        .glassCard(
            cornerRadius: 14,
            tint: sourceColor.opacity(isHovering ? 0.12 : 0.06),
            stroke: sourceColor.opacity(isHovering ? 0.30 : 0.18)
        )
        .scaleEffect(isHovering ? 1.006 : 1)
        .shadow(color: sourceColor.opacity(isHovering ? 0.08 : 0.03), radius: isHovering ? 8 : 4, y: isHovering ? 4 : 2)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.18)) {
                isHovering = hovering
            }
        }
    }

    private func timestamp(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func isWarning(_ status: String) -> Bool {
        status.contains("permissions") || status.contains("cannot view") || status.contains("not found")
    }

    private func statusColor(_ status: String) -> Color {
        if status == "Ready" || status.contains("succeeded") || status.contains("sent") || status.contains("Sent") { return .green }
        if status == "Never checked" || status.contains("Unchanged") || status.contains("unchanged") { return .secondary }
        if isWarning(status) { return .yellow }
        return .red
    }

    private func sourceIcon(_ source: PatchySourceKind) -> String {
        switch source {
        case .amd: return "a.circle.fill"
        case .nvidia: return "n.square.fill"
        case .intel: return "i.circle.fill"
        case .steam: return "gamecontroller.fill"
        case .github: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - Patchy Icon Button

private struct PatchyIconButton: View {
    let symbol: String
    let color: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Patchy Status Pill

private struct PatchyStatusPill: View {
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isEnabled ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(isEnabled ? "Enabled" : "Disabled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isEnabled ? .green : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            (isEnabled ? Color.green : Color.secondary).opacity(0.12),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder((isEnabled ? Color.green : Color.secondary).opacity(0.30), lineWidth: 1)
        )
    }
}

// MARK: - Editor

private enum PatchyEditorMode {
    case create
    case edit
}

private struct PatchyTargetDraft: Identifiable {
    var id: UUID
    var isEnabled: Bool
    var source: PatchySourceKind
    var steamAppID: String
    var githubRepo: String
    var githubBranch: String
    var githubWatchAllCommits: Bool
    var serverId: String
    var channelId: String
    var roleIDs: [String]

    init(target: PatchySourceTarget) {
        id = target.id
        isEnabled = target.isEnabled
        source = target.source
        steamAppID = target.steamAppID
        githubRepo = target.githubRepo
        githubBranch = target.githubBranch
        githubWatchAllCommits = target.githubWatchAllCommits
        serverId = target.serverId
        channelId = target.channelId
        roleIDs = target.roleIDs
    }

    @MainActor
    static func makeNew(defaultServer: String?, app: AppModel) -> PatchyTargetDraft {
        let server = defaultServer ?? ""
        let channel = app.availableTextChannelsByServer[server]?.first?.id ?? ""
        return PatchyTargetDraft(target: PatchySourceTarget(
            serverId: server,
            channelId: channel
        ))
    }

    func toTarget() -> PatchySourceTarget {
        PatchySourceTarget(
            id: id,
            isEnabled: isEnabled,
            source: source,
            steamAppID: steamAppID,
            githubRepo: githubRepo,
            githubBranch: githubBranch,
            githubWatchAllCommits: githubWatchAllCommits,
            serverId: serverId,
            channelId: channelId,
            roleIDs: roleIDs
        )
    }
}

private struct PatchyTargetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: PatchyTargetDraft

    let mode: PatchyEditorMode
    let connectedServers: [String: String]
    let channelsByServer: [String: [GuildTextChannel]]
    let rolesByServer: [String: [GuildRole]]
    let onCancel: () -> Void
    let onSave: (PatchyTargetDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .create ? "Add SourceTarget" : "Edit SourceTarget")
                .font(.title3.weight(.semibold))

            Form {
                Picker("Source", selection: $draft.source) {
                    ForEach(PatchySourceKind.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }

                if draft.source == .steam {
                    TextField("Steam App ID", text: $draft.steamAppID)
                        .textFieldStyle(.roundedBorder)
                }

                if draft.source == .github {
                    TextField("Repo (owner/repo)", text: $draft.githubRepo)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Watch all commits", isOn: $draft.githubWatchAllCommits)
                        .toggleStyle(.switch)
                    if draft.githubWatchAllCommits {
                        TextField("Branch (blank = default)", text: $draft.githubBranch)
                            .textFieldStyle(.roundedBorder)
                        Text("Posts every new commit on this branch. Can be chatty on active repos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Posts when a new release/tag is published.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Server", selection: $draft.serverId) {
                    Text("Select server").tag("")
                    ForEach(sortedServerIDs(), id: \.self) { serverId in
                        Text(connectedServers[serverId] ?? serverId).tag(serverId)
                    }
                }

                Picker("Channel", selection: $draft.channelId) {
                    Text("Select channel").tag("")
                    ForEach(channelsByServer[draft.serverId] ?? [], id: \.id) { channel in
                        Text("#\(channel.name)").tag(channel.id)
                    }
                }

                PatchyRoleMultiSelect(selectedRoleIDs: $draft.roleIDs, roles: rolesByServer[draft.serverId] ?? [])

                Toggle("Enabled", isOn: $draft.isEnabled)
                    .toggleStyle(.switch)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 480, minHeight: 460)
        .onChange(of: draft.serverId) { _, newValue in
            let channels = channelsByServer[newValue] ?? []
            if !channels.contains(where: { $0.id == draft.channelId }) {
                draft.channelId = channels.first?.id ?? ""
            }
            let roleIDs = Set((rolesByServer[newValue] ?? []).map(\.id))
            draft.roleIDs = draft.roleIDs.filter { roleIDs.contains($0) }
        }
    }

    private var isValid: Bool {
        if draft.source == .steam && draft.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if draft.source == .github {
            let trimmed = draft.githubRepo.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return false }
            let parts = trimmed
                .replacingOccurrences(of: "https://github.com/", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(separator: "/", omittingEmptySubsequences: true)
            if parts.count < 2 { return false }
        }
        return !draft.serverId.isEmpty && !draft.channelId.isEmpty
    }

    private func sortedServerIDs() -> [String] {
        connectedServers.keys.sorted {
            (connectedServers[$0] ?? "").localizedCaseInsensitiveCompare(connectedServers[$1] ?? "") == .orderedAscending
        }
    }
}

private struct PatchyRoleMultiSelect: View {
    @Binding var selectedRoleIDs: [String]
    let roles: [GuildRole]

    var body: some View {
        Menu {
            if roles.isEmpty {
                Text("No roles available")
            } else {
                ForEach(roles, id: \.id) { role in
                    Button {
                        toggle(role.id)
                    } label: {
                        if selectedRoleIDs.contains(role.id) {
                            Label(role.name, systemImage: "checkmark")
                        } else {
                            Text(role.name)
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text("Mentions")
                Spacer()
                Text(summary)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        if selectedRoleIDs.isEmpty {
            return "None"
        }
        return "\(selectedRoleIDs.count) selected"
    }

    private func toggle(_ roleID: String) {
        if let idx = selectedRoleIDs.firstIndex(of: roleID) {
            selectedRoleIDs.remove(at: idx)
        } else {
            selectedRoleIDs.append(roleID)
        }
    }
}
