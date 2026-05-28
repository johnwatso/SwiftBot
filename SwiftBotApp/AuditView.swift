import SwiftUI

struct AuditView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var vm = AuditViewModel()
    @State private var hasAutoScanned = false

    private var servers: [(id: String, name: String)] {
        app.connectedServers
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedServer: (id: String, name: String)? {
        if let id = vm.selectedServerID { return servers.first { $0.id == id } }
        return servers.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)

            summaryRail
                .padding(.horizontal, 16)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if vm.selectedServerID == nil { vm.selectedServerID = servers.first?.id }
            if !hasAutoScanned, let server = selectedServer {
                hasAutoScanned = true
                triggerScan(server)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                ViewSectionHeader(title: "Audit", symbol: "checklist.checked")
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if servers.count > 1 {
                Picker("", selection: Binding(
                    get: { selectedServer?.id ?? "" },
                    set: { newID in
                        vm.selectedServerID = newID
                        if let server = servers.first(where: { $0.id == newID }) { triggerScan(server) }
                    }
                )) {
                    ForEach(servers, id: \.id) { server in
                        Text(server.name).tag(server.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            Button {
                if let server = selectedServer { triggerScan(server) }
            } label: {
                if vm.scanState == .scanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Scanning…")
                    }
                } else {
                    Label("Scan", systemImage: "sparkle.magnifyingglass")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(vm.scanState == .scanning || selectedServer == nil)
        }
    }

    private var statusColor: Color {
        switch vm.scanState {
        case .idle: return .secondary
        case .scanning: return .yellow
        case .completed: return vm.riskCount > 0 ? .orange : .green
        case .failed: return .red
        }
    }

    private var statusSubtitle: String {
        switch vm.scanState {
        case .idle:
            return selectedServer.map { "Ready to scan \($0.name)" } ?? "No server connected"
        case .scanning:
            return "Analyzing roles and recent activity…"
        case .completed(let date):
            let count = vm.visibleFindings.count
            let summary = count == 0 ? "No issues found" : "\(count) finding\(count == 1 ? "" : "s")"
            return "\(summary) · scanned \(date.formatted(date: .omitted, time: .shortened))"
        case .failed(let message):
            return message
        }
    }

    // MARK: - Summary rail

    private var summaryRail: some View {
        LazyVGrid(columns: DashboardMetricGrid.columns, spacing: DashboardMetricGrid.spacing) {
            DashboardMetricCard(title: "Risks", value: "\(vm.riskCount)",
                                subtitle: vm.riskCount == 0 ? "Nothing urgent" : "Warning or higher",
                                symbol: "exclamationmark.shield", color: vm.riskCount > 0 ? .orange : .green)
            DashboardMetricCard(title: "Duplicate Roles", value: "\(vm.duplicateCount)",
                                subtitle: "Possible merges", symbol: "square.on.square", color: .blue)
            DashboardMetricCard(title: "Unused Roles", value: "\(vm.unusedCount)",
                                subtitle: "Cleanup candidates", symbol: "person.crop.circle.badge.questionmark", color: .teal)
            DashboardMetricCard(title: "Recent Changes", value: "\(vm.recentChangeCount)",
                                subtitle: "From the audit log", symbol: "clock.arrow.circlepath", color: .indigo)
            DashboardMetricCard(title: "Elevated Permissions", value: "\(vm.elevatedCount)",
                                subtitle: "Roles to review", symbol: "bolt.shield", color: .purple)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        HSplitView {
            feed
                .frame(minWidth: 380, idealWidth: 520)
            FindingInspector(finding: vm.selectedFinding, vm: vm)
                .frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var feed: some View {
        if vm.visibleFindings.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(vm.groupedByCategory, id: \.category) { group in
                        SwiftMeshSection(title: group.category.title, symbol: group.category.symbol) {
                            VStack(spacing: 8) {
                                ForEach(group.findings) { finding in
                                    FindingCard(
                                        finding: finding,
                                        vm: vm,
                                        isSelected: vm.selectedFindingID == finding.id,
                                        onSelect: { vm.selectedFindingID = finding.id },
                                        guildID: selectedServer?.id ?? ""
                                    )
                                }
                            }
                        }
                    }

                    if vm.ignoredCount > 0 {
                        Toggle(isOn: $vm.showIgnored) {
                            Text("Show ignored (\(vm.ignoredCount))")
                                .font(.caption)
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .buttonBorderShape(.capsule)
                    }
                }
                .padding(.vertical, 4)
            }
            .fadingEdges(top: 12, bottom: 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: vm.scanState == .scanning ? "sparkle.magnifyingglass" : "checkmark.seal")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(emptyStateText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dashboardSurface()
    }

    private var emptyStateText: String {
        switch vm.scanState {
        case .scanning: return "Scanning the server…"
        case .completed: return "No issues found. This server's roles look healthy."
        case .failed(let message): return message
        case .idle: return "Press Scan to analyze this server's roles."
        }
    }

    private func triggerScan(_ server: (id: String, name: String)) {
        Task {
            await vm.scan(
                token: app.settings.token,
                session: app.discordRESTSession,
                guildID: server.id,
                guildName: server.name
            )
        }
    }
}

// MARK: - Finding card

private struct FindingCard: View {
    let finding: Finding
    @ObservedObject var vm: AuditViewModel
    let isSelected: Bool
    let onSelect: () -> Void
    let guildID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AuditStyle.color(for: finding.severity))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)

                Image(systemName: AuditStyle.symbol(for: finding.severity))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AuditStyle.color(for: finding.severity))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(finding.title)
                        .font(.subheadline.weight(.semibold))
                    Text(finding.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if !finding.evidence.isEmpty {
                ContextStrip(events: Array(finding.evidence.prefix(3)))
                    .padding(.leading, 33)
            }

            HStack(spacing: 6) {
                Spacer()
                ForEach(finding.actions, id: \.self) { action in
                    actionButton(action)
                }
            }
            .padding(.leading, 33)
        }
        .padding(10)
        .dashboardSurface(
            cornerRadius: 10,
            fillOpacity: isSelected ? 0.08 : 0.02,
            strokeOpacity: isSelected ? 0.16 : 0.06,
            shadowOpacity: 0.02
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    @ViewBuilder
    private func actionButton(_ action: FindingAction) -> some View {
        switch action {
        case .ignore:
            SettingsInlineAction(
                vm.isIgnored(finding) ? "Unignore" : "Ignore",
                systemImage: action.symbol
            ) {
                if vm.isIgnored(finding) {
                    vm.unignore(finding, guildID: guildID)
                } else {
                    vm.ignore(finding, guildID: guildID)
                }
            }
        case .review, .compare:
            SettingsInlineAction(action.title, systemImage: action.symbol) { onSelect() }
        case .merge, .revert, .archive:
            // Declared for forward-compatibility; not wired in the MVP.
            EmptyView()
        }
    }
}

// MARK: - Context strip (audit-log evidence)

private struct ContextStrip: View {
    let events: [DiscordAuditEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(events) { event in
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(AuditEventPhrasing.summary(event))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Inspector

private struct FindingInspector: View {
    let finding: Finding?
    @ObservedObject var vm: AuditViewModel

    var body: some View {
        Group {
            if let finding {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(finding)
                        detailBody(finding)
                        if !finding.evidence.isEmpty {
                            evidenceTimeline(finding)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fadingEdges(top: 12, bottom: 16)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Select a finding to see details")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .dashboardSurface()
    }

    private func header(_ finding: Finding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: AuditStyle.symbol(for: finding.severity))
                    .foregroundStyle(AuditStyle.color(for: finding.severity))
                Text(finding.title)
                    .font(.headline)
            }
            Text(finding.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func detailBody(_ finding: Finding) -> some View {
        switch finding.detail {
        case let .duplicate(primary, others):
            RoleComparisonView(roles: [primary] + others)
        case let .permissionRisk(role, flaggedBits):
            PermissionRiskDetail(role: role, flaggedBits: flaggedBits)
        case .generic:
            EmptyView()
        }
    }

    private func evidenceTimeline(_ finding: Finding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Activity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(finding.evidence) { event in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    Text(AuditEventPhrasing.summary(event))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Role comparison

private struct RoleComparisonView: View {
    let roles: [AuditRole]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comparison")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(roles) { role in
                HStack(spacing: 8) {
                    RoleSwatch(colorRGB: role.colorRGB)
                    Text(role.name)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let count = role.memberCount {
                        Text("\(count) members")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("pos \(role.position)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
            }
        }
    }
}

// MARK: - Permission risk detail

private struct PermissionRiskDetail: View {
    let role: AuditRole
    let flaggedBits: [UInt64]
    @State private var expanded = false

    private var flaggedNames: [String] {
        if role.hasAdministrator { return ["Administrator"] }
        return flaggedBits.compactMap { mask in
            DiscordPermissionCatalog.all.first { $0.mask == mask }?.name
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(flaggedNames, id: \.self) { name in
                HStack(spacing: 6) {
                    Image(systemName: "bolt.shield")
                        .font(.caption)
                        .foregroundStyle(.purple)
                    Text(name)
                        .font(.subheadline.weight(.medium))
                }
            }

            HStack(spacing: 8) {
                if role.mentionable {
                    SettingsStatusBadge("Mentionable", systemImage: "at", tint: .orange)
                }
                if role.hoist {
                    SettingsStatusBadge("Hoisted", systemImage: "arrow.up", tint: .secondary)
                }
            }

            DisclosureGroup(isExpanded: $expanded) {
                Text(String(format: "Raw bitfield: 0x%llX", role.permissions))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                Text("Show raw permissions")
                    .font(.caption)
            }
        }
    }
}

// MARK: - Shared style helpers

private struct RoleSwatch: View {
    let colorRGB: Int

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1))
    }

    private var color: Color {
        guard colorRGB != 0 else { return .secondary }
        return Color(
            red: Double((colorRGB >> 16) & 0xFF) / 255,
            green: Double((colorRGB >> 8) & 0xFF) / 255,
            blue: Double(colorRGB & 0xFF) / 255
        )
    }
}

enum AuditStyle {
    static func color(for severity: Severity) -> Color {
        switch severity {
        case .info: return .secondary
        case .notice: return .yellow
        case .warning: return .orange
        case .critical: return .red
        }
    }

    static func symbol(for severity: Severity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .notice: return "lightbulb"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon"
        }
    }
}

// MARK: - Audit-log phrasing

enum AuditEventPhrasing {
    static func summary(_ event: DiscordAuditEvent) -> String {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        var parts = [action(event)]
        parts.append(relative.localizedString(for: event.createdAt, relativeTo: Date()))
        if let actor = event.actorName, !actor.isEmpty {
            parts.append("by \(actor)")
        }
        return parts.joined(separator: " · ")
    }

    private static func action(_ event: DiscordAuditEvent) -> String {
        switch event.actionType {
        case .roleCreate: return "Role created"
        case .roleDelete: return "Role deleted"
        case .memberRoleUpdate: return "Role assignment changed"
        case .roleUpdate:
            if event.changes.contains(where: { $0.key == "permissions" }) {
                if let change = event.changes.first(where: { $0.key == "permissions" }),
                   adminEnabled(change) {
                    return "Administrator enabled"
                }
                return "Permissions modified"
            }
            if event.changes.contains(where: { $0.key == "color" }) { return "Colour changed" }
            if event.changes.contains(where: { $0.key == "name" }) { return "Renamed" }
            if event.changes.contains(where: { $0.key == "mentionable" }) { return "Mentionable toggled" }
            return "Role updated"
        case .other: return "Changed"
        }
    }

    private static func adminEnabled(_ change: AuditChange) -> Bool {
        let admin = DiscordPermissionCatalog.administrator
        let old = UInt64(change.oldValue ?? "0") ?? 0
        let new = UInt64(change.newValue ?? "0") ?? 0
        return (old & admin == 0) && (new & admin != 0)
    }
}
