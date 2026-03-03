import SwiftUI

struct WikiBridgeView: View {
    @EnvironmentObject var app: AppModel

    @State private var editorDraft: WikiBridgeSourceDraft?
    @State private var editorMode: WikiBridgeEditorMode = .create

    private var effectivePrefix: String {
        let trimmed = app.settings.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "!" : trimmed
    }

    private var sortedSources: [WikiBridgeSourceTarget] {
        app.settings.wikiBot.sourceTargets.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("WikiBridge")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                overviewCard
                configurationCard
                sourcesCard
            }
            .padding(20)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $editorDraft) { draft in
            WikiBridgeSourceEditorSheet(
                draft: draft,
                mode: editorMode,
                onCancel: { editorDraft = nil },
                onSave: { updated in
                    if editorMode == .create {
                        app.addWikiBridgeSourceTarget(updated.toTarget())
                    } else {
                        app.updateWikiBridgeSourceTarget(updated.toTarget())
                    }
                    editorDraft = nil
                }
            )
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status")
                .font(.title3.weight(.semibold))

            let defaultSource = app.settings.wikiBot.defaultSource()
            InfoRow(label: "WikiBridge", value: app.settings.wikiBot.isEnabled ? "Enabled" : "Disabled")
            InfoRow(label: "Default Source", value: defaultSource?.name ?? "Not set")
            InfoRow(label: "Configured Sources", value: "\(app.settings.wikiBot.sourceTargets.count)")
            InfoRow(label: "Enabled Sources", value: "\(app.settings.wikiBot.sourceTargets.filter(\.isEnabled).count)")
            InfoRow(label: "\(effectivePrefix)finals", value: app.settings.wikiBot.allowFinalsCommand ? "Enabled" : "Disabled")
            InfoRow(label: "\(effectivePrefix)wiki", value: app.settings.wikiBot.allowWikiAlias ? "Enabled" : "Disabled")
            InfoRow(label: "\(effectivePrefix)weapon", value: app.settings.wikiBot.allowWeaponCommand ? "Enabled" : "Disabled")
            InfoRow(label: "Weapon Stats Formatting", value: app.settings.wikiBot.includeWeaponStats ? "Enabled" : "Disabled")
        }
        .padding(20)
        .glassCard(cornerRadius: 24, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configuration")
                .font(.title3.weight(.semibold))

            Toggle("Enable WikiBridge", isOn: $app.settings.wikiBot.isEnabled)
                .toggleStyle(.switch)

            Group {
                Toggle("Enable \(effectivePrefix)finals command", isOn: $app.settings.wikiBot.allowFinalsCommand)
                Toggle("Enable \(effectivePrefix)wiki alias", isOn: $app.settings.wikiBot.allowWikiAlias)
                Toggle("Enable \(effectivePrefix)weapon command", isOn: $app.settings.wikiBot.allowWeaponCommand)
                Toggle("Include weapon stat blocks in responses", isOn: $app.settings.wikiBot.includeWeaponStats)
            }
            .toggleStyle(.switch)
            .disabled(!app.settings.wikiBot.isEnabled)
            .opacity(app.settings.wikiBot.isEnabled ? 1.0 : 0.55)

            HStack {
                Spacer()
                Button("Save WikiBridge Settings") {
                    app.saveSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 24, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Wiki Sources")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    editorMode = .create
                    editorDraft = WikiBridgeSourceDraft.makeNew()
                } label: {
                    Label("Add Source", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if sortedSources.isEmpty {
                Text("No wiki sources configured.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(sortedSources) { target in
                        WikiBridgeSourceCard(
                            target: target,
                            isDefault: app.settings.wikiBot.defaultSourceID == target.id,
                            onSetDefault: {
                                app.setWikiBridgeDefaultSource(target.id)
                            },
                            onTest: {
                                app.testWikiBridgeSource(targetID: target.id)
                            },
                            onEdit: {
                                editorMode = .edit
                                editorDraft = WikiBridgeSourceDraft(target: target)
                            },
                            onToggleEnabled: {
                                app.toggleWikiBridgeSourceTargetEnabled(target.id)
                            },
                            onDelete: {
                                app.deleteWikiBridgeSourceTarget(target.id)
                            }
                        )
                    }
                }
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 24, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }
}

private struct WikiBridgeSourceCard: View {
    let target: WikiBridgeSourceTarget
    let isDefault: Bool
    let onSetDefault: () -> Void
    let onTest: () -> Void
    let onEdit: () -> Void
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(target.name)
                    .font(.headline)
                if isDefault {
                    Text("Default")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text(target.isEnabled ? "Enabled" : "Disabled")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        target.isEnabled
                            ? Color.green.opacity(0.18)
                            : Color.secondary.opacity(0.14),
                        in: Capsule()
                    )
                    .foregroundStyle(target.isEnabled ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                WikiBridgeSourceDetailRow(label: "Type", value: target.kind.rawValue)
                WikiBridgeSourceDetailRow(label: "Base URL", value: target.baseURL)
                WikiBridgeSourceDetailRow(label: "API Path", value: target.apiPath)
                WikiBridgeSourceDetailRow(label: "Last Lookup", value: timestamp(target.lastLookupAt))
            }
            .font(.subheadline)

            Text(target.lastStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                if !isDefault {
                    Button("Set Default", action: onSetDefault)
                        .buttonStyle(.bordered)
                }
                Button("Test", action: onTest)
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
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.45), lineWidth: 1)
        }
    }

    private func timestamp(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct WikiBridgeSourceDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

private enum WikiBridgeEditorMode {
    case create
    case edit
}

private struct WikiBridgeSourceDraft: Identifiable {
    var id: UUID
    var isEnabled: Bool
    var name: String
    var kind: WikiBridgeSourceKind
    var baseURL: String
    var apiPath: String
    var lastLookupAt: Date?
    var lastStatus: String

    init(target: WikiBridgeSourceTarget) {
        id = target.id
        isEnabled = target.isEnabled
        name = target.name
        kind = target.kind
        baseURL = target.baseURL
        apiPath = target.apiPath
        lastLookupAt = target.lastLookupAt
        lastStatus = target.lastStatus
    }

    static func makeNew() -> WikiBridgeSourceDraft {
        let target = WikiBridgeSourceTarget(
            id: UUID(),
            isEnabled: true,
            name: "New Wiki",
            kind: .mediaWiki,
            baseURL: "https://example.fandom.com",
            apiPath: "/api.php",
            lastLookupAt: nil,
            lastStatus: "Ready"
        )
        return WikiBridgeSourceDraft(target: target)
    }

    func toTarget() -> WikiBridgeSourceTarget {
        WikiBridgeSourceTarget(
            id: id,
            isEnabled: isEnabled,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiPath: apiPath.trimmingCharacters(in: .whitespacesAndNewlines),
            lastLookupAt: lastLookupAt,
            lastStatus: lastStatus
        )
    }
}

private struct WikiBridgeSourceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: WikiBridgeSourceDraft

    let mode: WikiBridgeEditorMode
    let onCancel: () -> Void
    let onSave: (WikiBridgeSourceDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .create ? "Add Wiki Source" : "Edit Wiki Source")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Display Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)

                Picker("Type", selection: $draft.kind) {
                    ForEach(WikiBridgeSourceKind.allCases) { sourceKind in
                        Text(sourceKind.rawValue).tag(sourceKind)
                    }
                }

                TextField("Base URL", text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)

                TextField("API Path", text: $draft.apiPath)
                    .textFieldStyle(.roundedBorder)

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
        .frame(minWidth: 500, minHeight: 430)
        .onChange(of: draft.kind) { _, newKind in
            if newKind == .finals {
                if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.name == "New Wiki" {
                    draft.name = "THE FINALS Wiki"
                }
                if draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.baseURL == "https://example.fandom.com" {
                    draft.baseURL = "https://www.thefinals.wiki"
                }
                if draft.apiPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft.apiPath = "/api.php"
                }
            }
        }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.apiPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
