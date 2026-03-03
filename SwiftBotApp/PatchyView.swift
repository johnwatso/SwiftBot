import SwiftUI

struct PatchyView: View {
    @EnvironmentObject var app: AppModel

    @State private var editorDraft: PatchyTargetDraft?
    @State private var editorMode: PatchyEditorMode = .create
    @State private var debugExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            monitoringControls
            sourceTargetList
            debugArea
        }
        .padding(16)
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

    private var header: some View {
        HStack(spacing: 12) {
            Text("Patchy")
                .font(.title2.weight(.semibold))

            Spacer()

            Button {
                editorMode = .create
                editorDraft = PatchyTargetDraft.makeNew(defaultServer: sortedServerIDs().first, app: app)
            } label: {
                Label("Add Target", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var monitoringControls: some View {
        HStack(spacing: 14) {
            Toggle("Start Monitoring", isOn: Binding(
                get: { app.settings.patchy.monitoringEnabled },
                set: { newValue in
                    app.settings.patchy.monitoringEnabled = newValue
                    app.saveSettings()
                }
            ))
            .toggleStyle(.switch)

            Toggle("Show Debug", isOn: Binding(
                get: { app.settings.patchy.showDebug },
                set: { newValue in
                    app.settings.patchy.showDebug = newValue
                    app.saveSettings()
                }
            ))
            .toggleStyle(.switch)

            Spacer()

            if let last = app.patchyLastCycleAt {
                Text("Last cycle: \(last.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if app.patchyIsCycleRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var sourceTargetList: some View {
        List {
            if app.settings.patchy.sourceTargets.isEmpty {
                Text("No SourceTargets configured.")
                    .foregroundStyle(.secondary)
            }

            ForEach(groupedTargets(), id: \.source) { group in
                Section {
                    ForEach(group.targets) { target in
                        PatchyTargetRow(
                            target: target,
                            sourceDisplayName: sourceDisplayName(for: target),
                            serverName: app.connectedServers[target.serverId] ?? "Not set",
                            channelName: channelName(for: target),
                            roleSummary: roleSummary(for: target),
                            onTestSend: { app.sendPatchyTest(targetID: target.id) },
                            onEdit: {
                                editorMode = .edit
                                editorDraft = PatchyTargetDraft(target: target)
                            },
                            onToggleEnabled: { app.togglePatchyTargetEnabled(target.id) },
                            onDelete: { app.deletePatchyTarget(target.id) }
                        )
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: sourceIcon(group.source))
                        Text(sourceLabel(group.source))
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var debugArea: some View {
        if app.settings.patchy.showDebug {
            GroupBox {
                DisclosureGroup("Debug / Optional Output", isExpanded: $debugExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("Run Check Now") {
                                app.runPatchyManualCheck()
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                        }

                        if app.patchyDebugLogs.isEmpty {
                            Text("No debug logs yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(app.patchyDebugLogs, id: \.self) { line in
                                        Text(line)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 140, maxHeight: 240)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

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

    private func sourceDisplayName(for target: PatchySourceTarget) -> String {
        guard target.source == .steam else { return target.source.rawValue }
        let appID = target.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty else { return "Steam" }
        if let name = app.settings.patchy.steamAppNames[appID], !name.isEmpty {
            return "Steam • \(name) (\(appID))"
        }
        return "Steam (\(appID))"
    }

    private func sourceIcon(_ source: PatchySourceKind) -> String {
        switch source {
        case .amd: return "a.circle.fill"
        case .nvidia: return "n.square.fill"
        case .intel: return "i.circle.fill"
        case .steam: return "gamecontroller.fill"
        }
    }

    private func channelName(for target: PatchySourceTarget) -> String {
        guard let channel = app.availableTextChannelsByServer[target.serverId]?.first(where: { $0.id == target.channelId }) else {
            return target.channelId.isEmpty ? "Not set" : target.channelId
        }
        return "#\(channel.name)"
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

private struct PatchySourceGroup {
    let source: PatchySourceKind
    let targets: [PatchySourceTarget]
}

private struct PatchyTargetRow: View {
    let target: PatchySourceTarget
    let sourceDisplayName: String
    let serverName: String
    let channelName: String
    let roleSummary: String
    let onTestSend: () -> Void
    let onEdit: () -> Void
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: sourceIcon(target.source))
                Text(sourceDisplayName)
                    .font(.headline)
                Spacer()
                Text(target.isEnabled ? "Enabled" : "Disabled")
                    .font(.caption)
                    .foregroundStyle(target.isEnabled ? .green : .secondary)
            }

            HStack {
                LabeledContent("Server", value: serverName)
                LabeledContent("Channel", value: channelName)
            }
            .font(.subheadline)

            LabeledContent("Mentions", value: roleSummary)
                .font(.subheadline)

            HStack {
                Text("Last check: \(timestamp(target.lastCheckedAt))")
                Spacer()
                Text("Last run: \(timestamp(target.lastRunAt))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(target.lastStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Button("Test Send", action: onTestSend)
                    .buttonStyle(.bordered)
                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
                Button(target.isEnabled ? "Disable" : "Enable", action: onToggleEnabled)
                    .buttonStyle(.bordered)
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func timestamp(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func sourceIcon(_ source: PatchySourceKind) -> String {
        switch source {
        case .amd: return "a.circle.fill"
        case .nvidia: return "n.square.fill"
        case .intel: return "i.circle.fill"
        case .steam: return "gamecontroller.fill"
        }
    }
}

private enum PatchyEditorMode {
    case create
    case edit
}

private struct PatchyTargetDraft: Identifiable {
    var id: UUID
    var isEnabled: Bool
    var source: PatchySourceKind
    var steamAppID: String
    var serverId: String
    var channelId: String
    var roleIDs: [String]

    init(
        id: UUID,
        isEnabled: Bool,
        source: PatchySourceKind,
        steamAppID: String,
        serverId: String,
        channelId: String,
        roleIDs: [String]
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.source = source
        self.steamAppID = steamAppID
        self.serverId = serverId
        self.channelId = channelId
        self.roleIDs = roleIDs
    }

    init(target: PatchySourceTarget) {
        id = target.id
        isEnabled = target.isEnabled
        source = target.source
        steamAppID = target.steamAppID
        serverId = target.serverId
        channelId = target.channelId
        roleIDs = target.roleIDs
    }

    @MainActor
    static func makeNew(defaultServer: String?, app: AppModel) -> PatchyTargetDraft {
        let server = defaultServer ?? ""
        let channel = app.availableTextChannelsByServer[server]?.first?.id ?? ""
        return PatchyTargetDraft(
            id: UUID(),
            isEnabled: true,
            source: .nvidia,
            steamAppID: "570",
            serverId: server,
            channelId: channel,
            roleIDs: []
        )
    }

    func toTarget() -> PatchySourceTarget {
        PatchySourceTarget(
            id: id,
            isEnabled: isEnabled,
            source: source,
            steamAppID: steamAppID,
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
