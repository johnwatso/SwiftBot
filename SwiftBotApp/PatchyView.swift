import SwiftUI
import AppKit

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
            operationsConsole
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
            ViewSectionHeader(title: "Patchy", symbol: "square.and.arrow.down.badge.checkmark")
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
                value: "\(monitoredSourceCount)",
                subtitle: sourceBreakdownSubtitle,
                symbol: "square.stack.3d.up.fill",
                color: patchyMetricAmber
            )
            DashboardMetricCard(
                title: "Categories",
                value: "\(categoryModules.count)",
                subtitle: categoryBreakdownSubtitle,
                symbol: "rectangle.3.group.fill",
                color: patchyMetricBlue
            )
            DashboardMetricCard(
                title: "Active",
                value: "\(activeMonitoredSourceCount)",
                subtitle: "Monitored sources",
                symbol: "waveform.path.ecg",
                color: patchyMetricMint
            )
            DashboardMetricCard(
                title: "Failed",
                value: "\(failedMonitoredSourceCount)",
                subtitle: lastCycleSubtitle,
                symbol: "exclamationmark.triangle.fill",
                color: failedMonitoredSourceCount == 0 ? .gray : Color.red.opacity(0.68)
            )
        }
    }

    private var monitoredSourceCount: Int {
        Set(app.settings.patchy.sourceTargets.map(sourceIdentityKey)).count
    }

    private var activeMonitoredSourceCount: Int {
        Set(app.settings.patchy.sourceTargets.filter(\.isEnabled).map(sourceIdentityKey)).count
    }

    private var failedMonitoredSourceCount: Int {
        Set(app.settings.patchy.sourceTargets.filter { isFailureStatus($0.lastStatus) }.map(sourceIdentityKey)).count
    }

    private var sourceBreakdownSubtitle: String {
        let counts = Dictionary(grouping: app.settings.patchy.sourceTargets) { category(for: $0.source) }
            .mapValues { Set($0.map(sourceIdentityKey)).count }
        let parts = PatchyMonitoringCategory.allCases.compactMap { category -> String? in
            guard let count = counts[category], count > 0 else { return nil }
            return "\(category.shortTitle) \(count)"
        }
        return parts.isEmpty ? "No sources" : parts.joined(separator: "  ")
    }

    private var categoryBreakdownSubtitle: String {
        let enabledCategories = categoryModules.filter { module in
            module.targets.contains(where: \.isEnabled)
        }.count
        guard !categoryModules.isEmpty else { return "No groups" }
        return "\(enabledCategories) active · \(categoryModules.count) configured"
    }

    private var patchyMetricAmber: Color {
        Color.orange.opacity(0.72)
    }

    private var patchyMetricMint: Color {
        Color.mint.opacity(0.70)
    }

    private var patchyMetricBlue: Color {
        Color.blue.opacity(0.66)
    }

    private var lastCycleSubtitle: String {
        if app.patchyIsCycleRunning {
            return "Running now…"
        }
        guard let last = app.patchyLastCycleAt else { return "No failed sources" }
        return "Last cycle \(relativeTimestamp(last))"
    }

    // MARK: - Monitoring Controls Section

    private var monitoringControlsSection: some View {
        HStack(spacing: 8) {
            PatchyControlPill(
                title: "Monitoring",
                detail: app.settings.patchy.monitoringEnabled ? "Active" : "Paused",
                symbol: app.settings.patchy.monitoringEnabled ? "record.circle.fill" : "circle",
                color: app.settings.patchy.monitoringEnabled ? .green : .secondary,
                isActive: app.settings.patchy.monitoringEnabled
            ) {
                app.settings.patchy.monitoringEnabled.toggle()
                app.saveSettings()
            }

            PatchyControlPill(
                title: "Debug",
                detail: app.settings.patchy.showDebug ? "Enabled" : "Disabled",
                symbol: app.settings.patchy.showDebug ? "ladybug.fill" : "ladybug",
                color: app.settings.patchy.showDebug ? .indigo : .secondary,
                isActive: app.settings.patchy.showDebug
            ) {
                app.settings.patchy.showDebug.toggle()
                app.saveSettings()
            }

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
            .controlSize(.mini)
            .disabled(app.patchyIsCycleRunning)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var operationsConsole: some View {
        HStack(alignment: .top, spacing: 12) {
            sourceTargetList
                .frame(minWidth: 440)

            activityFeed
                .frame(width: 330)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Source Target List

    private var sourceTargetList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if app.settings.patchy.sourceTargets.isEmpty {
                    emptyTargetsState
                }

                ForEach(categoryModules) { module in
                    PatchyCategorySection(
                        module: module,
                        categoryStatus: categoryStatus(for: module.targets)
                    ) {
                        LazyVStack(spacing: 8) {
                            ForEach(module.targets) { target in
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
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(min(app.patchyDebugLogs.count, 60)) events")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
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
                        patchyActivityRow(line, index: index)
                        if index < min(app.patchyDebugLogs.count, 60) - 1 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.055))
                                .frame(height: 1)
                                .padding(.leading, 58)
                        }
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func patchyActivityRow(_ line: String, index: Int) -> some View {
        let parsed = PatchyLogParser.parse(line)
        return HStack(alignment: .center, spacing: 8) {
            Text(parsed.time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(index == 0 ? Color.primary.opacity(0.72) : Color.secondary)
                .frame(width: 42, alignment: .trailing)

            Image(systemName: parsed.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(parsed.color)
                .frame(width: 16, height: 16)
                .background(parsed.color.opacity(0.10), in: Circle())
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
        .padding(.vertical, 3)
    }

    // MARK: - Helpers

    private var categoryModules: [PatchyCategoryModule] {
        let grouped = Dictionary(grouping: app.settings.patchy.sourceTargets) { category(for: $0.source) }
        return grouped
            .map { category, targets in
                PatchyCategoryModule(
                    category: category,
                    targets: targets.sorted {
                        providerDisplayName(for: $0).localizedCaseInsensitiveCompare(providerDisplayName(for: $1)) == .orderedAscending
                    }
                )
            }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }

    private func sortedServerIDs() -> [String] {
        app.connectedServers.keys.sorted {
            (app.connectedServers[$0] ?? "").localizedCaseInsensitiveCompare(app.connectedServers[$1] ?? "") == .orderedAscending
        }
    }

    private func sourceLabel(_ source: PatchySourceKind) -> String {
        source.rawValue
    }

    private func category(for source: PatchySourceKind) -> PatchyMonitoringCategory {
        switch source {
        case .nvidia, .amd, .intel:
            return .drivers
        case .github:
            return .github
        case .steam:
            return .gamingPlatforms
        }
    }

    private func sourceColor(_ source: PatchySourceKind) -> Color {
        switch source {
        case .nvidia: return .green
        case .amd: return .red
        case .intel: return .blue
        case .steam: return .indigo
        case .github: return .indigo
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
                ? "commits · \(githubBranchLabel(for: target))"
                : "releases"
            return repo.isEmpty ? "GitHub" : "GitHub • \(repo) (\(suffix))"
        default:
            return target.source.rawValue
        }
    }

    private func providerDisplayName(for target: PatchySourceTarget) -> String {
        switch target.source {
        case .steam:
            let appID = target.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name = app.settings.patchy.steamAppNames[appID], !name.isEmpty {
                return name
            }
            return appID.isEmpty ? "Steam" : "Steam \(appID)"
        case .github:
            let repo = target.githubRepo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !repo.isEmpty else { return "Repository" }
            return repo.split(separator: "/").last.map(String.init) ?? repo
        default:
            return target.source.rawValue.replacingOccurrences(of: " Arc", with: "")
        }
    }

    private func sourceIdentityKey(for target: PatchySourceTarget) -> String {
        switch target.source {
        case .github:
            let repo = target.githubRepo.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let branch = target.githubBranch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return "github:\(repo):\(target.githubWatchAllCommits):\(target.githubBranchMode.rawValue):\(branch)"
        case .steam:
            return "steam:\(target.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines))"
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

    private func githubBranchLabel(for target: PatchySourceTarget) -> String {
        switch target.githubBranchMode {
        case .main:
            return "Main"
        case .specific:
            let branch = target.githubBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            return branch.isEmpty ? "Main" : branch
        case .all:
            return "All branches"
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

    private func notificationSummary(for targets: [PatchySourceTarget]) -> String {
        let channels = targets.map(channelName(for:))
        let uniqueChannels = Array(NSOrderedSet(array: channels)).compactMap { $0 as? String }
        if uniqueChannels.isEmpty { return "Not set" }
        if uniqueChannels.count == 1 { return uniqueChannels[0] }
        return "\(uniqueChannels[0]) +\(uniqueChannels.count - 1)"
    }

    private func lastCheckSummary(for targets: [PatchySourceTarget]) -> String {
        let dates = targets.compactMap(\.lastCheckedAt)
        guard let latest = dates.max() else { return "Never" }
        return relativeTimestamp(latest)
    }

    private func categoryStatus(for targets: [PatchySourceTarget]) -> PatchyCategoryStatus {
        if targets.contains(where: { isFailureStatus($0.lastStatus) }) {
            return .failed
        }
        if targets.contains(where: \.isEnabled) {
            return .enabled
        }
        return .disabled
    }

    private func preferredEditableTarget(in targets: [PatchySourceTarget]) -> PatchySourceTarget? {
        targets.first(where: \.isEnabled) ?? targets.first
    }

    private func isFailureStatus(_ status: String) -> Bool {
        if status == "Ready" || status == "Never checked" { return false }
        if status.contains("succeeded") || status.contains("successfully") || status.contains("sent") || status.contains("Sent") { return false }
        if status.contains("Unchanged") || status.contains("unchanged") { return false }
        return status.contains("failed")
            || status.contains("error")
            || status.contains("not found")
            || status.contains("cannot")
            || status.contains("permissions")
    }

    private func relativeTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Patchy Log Parser

private enum PatchyLogParser {
    struct ParsedLine {
        let time: String
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

        let extractedTime = extractTime(from: line)

        // Strip common prefixes
        var cleaned = line
            .replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
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

        return ParsedLine(time: extractedTime, title: title, detail: detail, symbol: symbol, color: color)
    }

    private static func extractTime(from line: String) -> String {
        guard let closing = line.firstIndex(of: "]"), line.first == "[" else { return "--:--" }
        let raw = String(line[line.index(after: line.startIndex)..<closing])
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: raw) else { return "--:--" }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        return timeFormatter.string(from: date)
    }
}

// MARK: - Compact Controls

private struct PatchyControlPill: View {
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(color.opacity(isActive ? 0.12 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(color.opacity(isActive ? 0.28 : 0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Monitoring Categories

private enum PatchyMonitoringCategory: CaseIterable {
    case drivers
    case github
    case gamingPlatforms
    case softwareReleases

    var title: String {
        switch self {
        case .drivers: return "Drivers Monitoring"
        case .github: return "GitHub Monitoring"
        case .gamingPlatforms: return "Gaming Platforms"
        case .softwareReleases: return "Software Releases"
        }
    }

    var shortTitle: String {
        switch self {
        case .drivers: return "Drivers"
        case .github: return "GitHub"
        case .gamingPlatforms: return "Gaming"
        case .softwareReleases: return "Software"
        }
    }

    var symbol: String {
        switch self {
        case .drivers: return "cpu.fill"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .gamingPlatforms: return "gamecontroller.fill"
        case .softwareReleases: return "shippingbox.fill"
        }
    }

    var color: Color {
        switch self {
        case .drivers: return Color.blue.opacity(0.70)
        case .github: return Color.indigo.opacity(0.70)
        case .gamingPlatforms: return Color.purple.opacity(0.64)
        case .softwareReleases: return Color.mint.opacity(0.64)
        }
    }

    var sortOrder: Int {
        switch self {
        case .drivers: return 0
        case .github: return 1
        case .gamingPlatforms: return 2
        case .softwareReleases: return 3
        }
    }
}

private struct PatchyCategoryModule: Identifiable {
    var id: PatchyMonitoringCategory { category }
    let category: PatchyMonitoringCategory
    let targets: [PatchySourceTarget]
}

private enum PatchyCategoryStatus {
    case enabled
    case disabled
    case failed

    var title: String {
        switch self {
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        case .failed: return "Attention"
        }
    }

    var color: Color {
        switch self {
        case .enabled: return .green
        case .disabled: return .secondary
        case .failed: return .red
        }
    }
}

private struct PatchyCategorySection<Content: View>: View {
    let module: PatchyCategoryModule
    let categoryStatus: PatchyCategoryStatus
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: module.category.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(module.category.color)
                    .frame(width: 22, height: 22)
                    .background(module.category.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(module.category.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text("\(module.targets.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(module.category.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(module.category.color.opacity(0.10), in: Capsule())

                Spacer(minLength: 8)

                PatchyCategoryStatusPill(status: categoryStatus)
            }

            content
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.026))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(module.category.color.opacity(0.14), lineWidth: 1)
        )
    }
}

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
    private let statusSidebarWidth: CGFloat = 232

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 10) {
                        sourceBadge

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Text(sourceDisplayName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                PatchyStatusPill(isEnabled: target.isEnabled)
                            }
                            Text(sourceSubtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    metadataBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                statusSidebar
                    .frame(minWidth: 200, idealWidth: statusSidebarWidth, maxWidth: 260, alignment: .leading)
                    .layoutPriority(1)
            }

            HStack(spacing: 6) {
                PatchyActionButton(title: "Test", symbol: "flask", color: .primary, action: onTestSend)
                PatchyActionButton(title: "Run", symbol: "icloud.and.arrow.down", color: .primary, action: onPull)
                PatchyActionButton(title: "Edit", symbol: "pencil", color: .primary, action: onEdit)
                PatchyActionButton(
                    title: target.isEnabled ? "Disable" : "Enable",
                    symbol: target.isEnabled ? "power" : "play.fill",
                    color: target.isEnabled ? .red : .green,
                    action: onToggleEnabled
                )
                PatchyActionButton(title: "Delete", symbol: "trash", color: .red) {
                    showDeleteConfirm = true
                }
                .alert("Delete Target?", isPresented: $showDeleteConfirm) {
                    Button("Delete", role: .destructive) { onDelete() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("\"\(sourceDisplayName)\" will be permanently deleted.")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(11)
        .glassCard(
            cornerRadius: 14,
            tint: sourceColor.opacity(isHovering ? 0.11 : 0.045),
            stroke: sourceColor.opacity(isHovering ? 0.34 : 0.18)
        )
        .scaleEffect(isHovering ? 1.006 : 1)
        .shadow(color: sourceColor.opacity(isHovering ? 0.08 : 0.03), radius: isHovering ? 8 : 4, y: isHovering ? 4 : 2)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.18)) {
                isHovering = hovering
            }
        }
    }

    private var sourceBadge: some View {
        Image(systemName: sourceIcon(target.source))
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(sourceColor)
            .frame(width: 34, height: 34)
            .background(
                LinearGradient(
                    colors: [sourceColor.opacity(0.22), sourceColor.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(sourceColor.opacity(0.22), lineWidth: 1)
            )
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            PatchyMetadataLine(label: "Server", value: serverName)
            PatchyMetadataLine(label: "Channel", value: channelName)
            PatchyMetadataLine(label: "Mentions", value: roleSummary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var statusSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol(target.lastStatus))
                        .font(.subheadline.weight(.semibold))
                    Text(statusTitle(target.lastStatus))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(statusColor(target.lastStatus))

                Text(statusDetail(target.lastStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 4) {
                PatchyStatusMetadataRow(label: "Last Check", value: relativeTimestamp(target.lastCheckedAt))
                PatchyStatusMetadataRow(label: "Last Run", value: relativeTimestamp(target.lastRunAt))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor(target.lastStatus).opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(statusColor(target.lastStatus).opacity(0.16), lineWidth: 1)
        )
    }

    private var sourceSubtitle: String {
        switch target.source {
        case .github:
            return target.githubWatchAllCommits ? "Commit activity" : "Release monitoring"
        case .steam:
            return "Platform updates"
        default:
            return "Driver monitoring"
        }
    }

    private func relativeTimestamp(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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

    private func statusSymbol(_ status: String) -> String {
        if status == "Ready" || status.contains("succeeded") || status.contains("sent") || status.contains("Sent") {
            return "checkmark.circle.fill"
        }
        if status == "Never checked" || status.contains("Unchanged") || status.contains("unchanged") {
            return "checkmark.circle"
        }
        return isWarning(status) ? "exclamationmark.triangle.fill" : "xmark.circle.fill"
    }

    private func statusTitle(_ status: String) -> String {
        if status.contains("GitHub") && status.contains("changed") { return "New Release" }
        if status == "Ready" { return "Ready" }
        if status.contains("succeeded") || status.contains("sent") || status.contains("Sent") { return "Delivered" }
        if status.contains("Unchanged") || status.contains("unchanged") { return "No updates" }
        if status == "Never checked" { return "Pending" }
        if isWarning(status) { return "Attention" }
        return "Failed"
    }

    private func statusDetail(_ status: String) -> String {
        if status == "Never checked" { return "Awaiting first sync" }
        if status.contains("GitHub") && status.contains("commits") { return "Commit activity" }
        if status.contains("GitHub") { return "Release notes available" }
        if status.contains("Unchanged") || status.contains("unchanged") { return "Last sync clean" }
        return status
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
        .background((isEnabled ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder((isEnabled ? Color.green : Color.secondary).opacity(0.30), lineWidth: 1)
        )
    }
}

private struct PatchyCategoryStatusPill: View {
    let status: PatchyCategoryStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
            Text(status.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.10), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(status.color.opacity(0.24), lineWidth: 1)
        )
    }
}

private struct PatchyMetadataLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
    }
}

private struct PatchyStatusMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            Text("·")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

private struct PatchyActionButton: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.085), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
    var githubBranchMode: PatchyGitHubBranchMode
    var pollingIntervalMinutes: Int
    var embedColorHex: String
    var serverId: String
    var channelId: String
    var roleIDs: [String]
    var lastCheckedAt: Date?
    var lastRunAt: Date?
    var lastStatus: String

    init(target: PatchySourceTarget) {
        id = target.id
        isEnabled = target.isEnabled
        source = target.source
        steamAppID = target.steamAppID
        githubRepo = target.githubRepo
        githubBranch = target.githubBranch
        githubWatchAllCommits = target.githubWatchAllCommits
        githubBranchMode = target.githubBranchMode
        pollingIntervalMinutes = target.pollingIntervalMinutes
        embedColorHex = target.embedColorHex
        serverId = target.serverId
        channelId = target.channelId
        roleIDs = target.roleIDs
        lastCheckedAt = target.lastCheckedAt
        lastRunAt = target.lastRunAt
        lastStatus = target.lastStatus
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
            githubBranchMode: githubBranchMode,
            pollingIntervalMinutes: pollingIntervalMinutes,
            embedColorHex: PatchyEmbedAccent.resolvedHex(embedColorHex, for: source),
            serverId: serverId,
            channelId: channelId,
            roleIDs: roleIDs,
            lastCheckedAt: lastCheckedAt,
            lastRunAt: lastRunAt,
            lastStatus: lastStatus
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
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: mode == .create ? "plus.circle.fill" : "slider.horizontal.3")
                    .font(.title2.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color(nsColor: accentNSColor))
                    .frame(width: 32, height: 32)
                    .background(Color(nsColor: accentNSColor).opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode == .create ? "Add Target" : "Edit Target")
                        .font(.title3.weight(.semibold))
                    Text(editorSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().opacity(0.45)

            ScrollView {
                VStack(spacing: 18) {
                    PatchyEditorSection(title: "General", systemImage: "scope") {
                        PatchyEditorRow(title: "Source") {
                            Picker("Source", selection: $draft.source) {
                                ForEach(PatchySourceKind.allCases) { source in
                                    Text(source.rawValue).tag(source)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        PatchyEditorRow(title: "Enabled", detail: "Start monitoring this target as soon as it is saved.") {
                            Toggle("", isOn: $draft.isEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }

                    sourceSettingsSection

                    PatchyEditorSection(title: "Discord Delivery", systemImage: "paperplane") {
                        PatchyEditorRow(title: "Server") {
                            Picker("Server", selection: $draft.serverId) {
                                Text("Select server").tag("")
                                ForEach(sortedServerIDs(), id: \.self) { serverId in
                                    Text(connectedServers[serverId] ?? serverId).tag(serverId)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        PatchyEditorRow(title: "Channel") {
                            Picker("Channel", selection: $draft.channelId) {
                                Text("Select channel").tag("")
                                ForEach(channelsByServer[draft.serverId] ?? [], id: \.id) { channel in
                                    Text("#\(channel.name)").tag(channel.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        PatchyRoleMultiSelect(selectedRoleIDs: $draft.roleIDs, roles: rolesByServer[draft.serverId] ?? [])
                    }

                    PatchyEditorSection(title: "Notification Appearance", systemImage: "paintpalette") {
                        PatchyEditorRow(title: "Embed Accent", detail: "Used as the Discord embed color for this target.") {
                            PatchyAccentChipPicker(selectedHex: $draft.embedColorHex)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }

            Divider().opacity(0.45)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    onSave(draft)
                    dismiss()
                } label: {
                    Text("Save Target")
                        .frame(minWidth: 82)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 560, minHeight: 610)
        .background(.ultraThinMaterial)
        .onAppear {
            if draft.embedColorHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.embedColorHex = PatchyEmbedAccent.defaultHex(for: draft.source)
            }
        }
        .onChange(of: draft.source) { oldValue, newValue in
            let oldDefault = PatchyEmbedAccent.defaultHex(for: oldValue)
            if draft.embedColorHex.isEmpty || draft.embedColorHex == oldDefault {
                draft.embedColorHex = PatchyEmbedAccent.defaultHex(for: newValue)
            }
            if newValue == .github {
                if mode == .create {
                    draft.githubWatchAllCommits = true
                }
                if draft.pollingIntervalMinutes == PatchyEmbedAccent.defaultPollingIntervalMinutes(for: oldValue) {
                    draft.pollingIntervalMinutes = PatchyEmbedAccent.defaultPollingIntervalMinutes(for: .github)
                }
            } else if draft.pollingIntervalMinutes == PatchyEmbedAccent.defaultPollingIntervalMinutes(for: .github) {
                draft.pollingIntervalMinutes = PatchyEmbedAccent.defaultPollingIntervalMinutes(for: newValue)
            }
        }
        .onChange(of: draft.serverId) { _, newValue in
            let channels = channelsByServer[newValue] ?? []
            if !channels.contains(where: { $0.id == draft.channelId }) {
                draft.channelId = channels.first?.id ?? ""
            }
            let roleIDs = Set((rolesByServer[newValue] ?? []).map(\.id))
            draft.roleIDs = draft.roleIDs.filter { roleIDs.contains($0) }
        }
    }

    @ViewBuilder
    private var sourceSettingsSection: some View {
        switch draft.source {
        case .steam:
            PatchyEditorSection(title: "Steam Settings", systemImage: "gamecontroller") {
                PatchyEditorRow(title: "App ID", detail: "Steam app identifier used for platform update checks.") {
                    TextField("570", text: $draft.steamAppID)
                        .textFieldStyle(.roundedBorder)
                }
            }
        case .github:
            PatchyEditorSection(title: "GitHub Settings", systemImage: "chevron.left.forwardslash.chevron.right") {
                PatchyEditorRow(title: "Repository", detail: "Use owner/repo, for example apple/swift.") {
                    TextField("owner/repo", text: $draft.githubRepo)
                        .textFieldStyle(.roundedBorder)
                }

                PatchyEditorRow(title: "Watch Commits", detail: "Primary Patchy mode. Posts when new commits appear.") {
                    Toggle("", isOn: $draft.githubWatchAllCommits)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if draft.githubWatchAllCommits {
                    PatchyEditorRow(title: "Branch Monitoring", detail: "Choose the branch scope Patchy should watch.") {
                        Picker("Branch Monitoring", selection: $draft.githubBranchMode) {
                            Text("Main").tag(PatchyGitHubBranchMode.main)
                            Text("Specific Branch").tag(PatchyGitHubBranchMode.specific)
                            Text("All Branches").tag(PatchyGitHubBranchMode.all)
                        }
                        .labelsHidden()
                        .pickerStyle(.radioGroup)
                    }

                    if draft.githubBranchMode == .specific {
                        PatchyEditorRow(title: "Branch", detail: "Enter the exact branch name to monitor.") {
                            TextField("main", text: $draft.githubBranch)
                                .textFieldStyle(.roundedBorder)
                        }
                    } else if draft.githubBranchMode == .all {
                        Text("All Branches checks recent branch heads and reports the branch that actually received the commit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("Release mode posts when GitHub publishes a new release or tag for this repository.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                PatchyEditorRow(title: "Polling", detail: "GitHub-safe cadence; 5 minutes is the default.") {
                    Stepper("\(draft.pollingIntervalMinutes) min", value: $draft.pollingIntervalMinutes, in: 5...1440, step: 5)
                        .font(.callout.monospacedDigit())
                }
            }
        default:
            PatchyEditorSection(title: "\(draft.source.rawValue) Settings", systemImage: "cpu") {
                Text("Patchy will monitor this provider using the built-in update source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var editorSubtitle: String {
        switch draft.source {
        case .github:
            return "Configure repository monitoring and Discord delivery."
        case .steam:
            return "Configure Steam update monitoring and Discord delivery."
        default:
            return "Configure provider monitoring and Discord delivery."
        }
    }

    private var accentNSColor: NSColor {
        nsColor(from: PatchyEmbedAccent.resolvedHex(draft.embedColorHex, for: draft.source))
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
            if draft.githubWatchAllCommits,
               draft.githubBranchMode == .specific,
               draft.githubBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        return !draft.serverId.isEmpty && !draft.channelId.isEmpty
    }

    private func sortedServerIDs() -> [String] {
        connectedServers.keys.sorted {
            (connectedServers[$0] ?? "").localizedCaseInsensitiveCompare(connectedServers[$1] ?? "") == .orderedAscending
        }
    }

    private func nsColor(from hex: String) -> NSColor {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard raw.count == 6,
              let value = Int(raw, radix: 16)
        else {
            return NSColor.systemIndigo
        }

        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

}

private struct PatchyEditorSection<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.045), lineWidth: 1)
            )
        }
    }
}

private struct PatchyEditorRow<Content: View>: View {
    let title: String
    var detail: String?
    let content: Content

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 150, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

private struct PatchyAccentChipPicker: View {
    @Binding var selectedHex: String

    private let choices: [PatchyAccentChoice] = [
        PatchyAccentChoice(name: "Green", hex: "#5FAD64"),
        PatchyAccentChoice(name: "Blue", hex: "#5B9BC8"),
        PatchyAccentChoice(name: "Purple", hex: "#746FAE"),
        PatchyAccentChoice(name: "Orange", hex: "#D58A2A"),
        PatchyAccentChoice(name: "Cyan", hex: "#36AEBF"),
        PatchyAccentChoice(name: "Red", hex: "#C95757"),
        PatchyAccentChoice(name: "Gray", hex: "#8E96A3")
    ]

    var body: some View {
        HStack(spacing: 13) {
            ForEach(choices) { choice in
                Button {
                    selectedHex = choice.hex
                } label: {
                    Circle()
                        .fill(choice.color)
                        .frame(width: 22, height: 22)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(isSelected(choice) ? 0.75 : 0), lineWidth: 2)
                                .padding(3)
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    isSelected(choice) ? choice.color.opacity(0.55) : Color.primary.opacity(0.08),
                                    lineWidth: isSelected(choice) ? 4 : 1
                                )
                                .frame(width: 30, height: 30)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(choice.name)
            }
        }
        .padding(.vertical, 4)
        .onAppear(perform: normalizeSelection)
        .onChange(of: selectedHex) { _, _ in
            normalizeSelection()
        }
    }

    private func isSelected(_ choice: PatchyAccentChoice) -> Bool {
        selectedHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == choice.hex
    }

    private func normalizeSelection() {
        let current = selectedHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !choices.contains(where: { $0.hex == current }) {
            selectedHex = choices[2].hex
        }
    }
}

private struct PatchyAccentChoice: Identifiable {
    let name: String
    let hex: String

    var id: String { hex }

    var color: Color {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard raw.count == 6, let value = Int(raw, radix: 16) else {
            return .secondary
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private struct PatchyRoleMultiSelect: View {
    @Binding var selectedRoleIDs: [String]
    let roles: [GuildRole]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mention Role")
                    .font(.callout.weight(.medium))
                Text("Users with selected roles will be mentioned in notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 150, alignment: .leading)

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
                HStack(spacing: 6) {
                    if selectedRoles.isEmpty {
                        Text("No mentions")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedRoles.prefix(3), id: \.id) { role in
                            PatchyRoleToken(name: role.name) {
                                remove(role.id)
                            }
                        }
                        if selectedRoles.count > 3 {
                            Text("+\(selectedRoles.count - 3)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minHeight: 30)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var selectedRoles: [GuildRole] {
        let selected = Set(selectedRoleIDs)
        return roles.filter { selected.contains($0.id) }
    }

    private func toggle(_ roleID: String) {
        if let idx = selectedRoleIDs.firstIndex(of: roleID) {
            selectedRoleIDs.remove(at: idx)
        } else {
            selectedRoleIDs.append(roleID)
        }
    }

    private func remove(_ roleID: String) {
        selectedRoleIDs.removeAll { $0 == roleID }
    }
}

private struct PatchyRoleToken: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 4) {
                Text("@\(name)")
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary.opacity(0.82))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.075), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove @\(name)")
    }
}
