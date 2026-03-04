import SwiftUI

struct WikiBridgeView: View {
    @EnvironmentObject var app: AppModel

    @State private var editorDraft: WikiSourceDraft?
    @State private var editorMode: WikiBridgeEditorMode = .create

    private enum WikiSettingKey {
        static let enabled = "wikibridge.enabled"
    }

    private var sortedSources: [WikiSource] {
        app.settings.wikiBot.sources.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary {
                return lhs.isPrimary && !rhs.isPrimary
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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
            WikiSourceEditorSheet(
                draft: draft,
                mode: editorMode,
                onCancel: { editorDraft = nil },
                onSave: { updated in
                    if editorMode == .create {
                        app.addWikiBridgeSourceTarget(updated.toSource())
                    } else {
                        app.updateWikiBridgeSourceTarget(updated.toSource())
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

            let primarySource = app.settings.wikiBot.primarySource()
            InfoRow(label: "WikiBridge", value: app.settings.wikiBot.isEnabled ? "Enabled" : "Disabled")
            InfoRow(label: "Primary Source", value: primarySource?.name ?? "Not set")
            InfoRow(label: "Configured Sources", value: "\(app.settings.wikiBot.sources.count)")
            InfoRow(label: "Enabled Sources", value: "\(app.settings.wikiBot.sources.filter(\.enabled).count)")
        }
        .padding(20)
        .glassCard(cornerRadius: 24, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configuration")
                .font(.title3.weight(.semibold))

            SettingsView(sections: wikiSettingsSections, values: wikiSettingsValues)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 94, maxHeight: 140)

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

    private var wikiSettingsSections: [SettingSection] {
        [
            SettingSection(
                title: "WikiBridge",
                settings: [
                    Setting(
                        key: WikiSettingKey.enabled,
                        title: "Enable WikiBridge",
                        description: "Allow wiki command routing and source resolution.",
                        type: .toggle
                    )
                ]
            )
        ]
    }

    private var wikiSettingsValues: Binding<[String: SettingValue]> {
        Binding(
            get: {
                [
                    WikiSettingKey.enabled: .toggle(app.settings.wikiBot.isEnabled)
                ]
            },
            set: { updated in
                if let enabled = updated[WikiSettingKey.enabled]?.boolValue {
                    app.settings.wikiBot.isEnabled = enabled
                }
            }
        )
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Wiki Sources")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    editorMode = .create
                    editorDraft = WikiSourceDraft.makeNew()
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
                    ForEach(sortedSources) { source in
                        WikiSourceCard(
                            source: source,
                            onSetPrimary: {
                                app.setWikiBridgePrimarySource(source.id)
                            },
                            onTest: {
                                app.testWikiBridgeSource(targetID: source.id)
                            },
                            onEdit: {
                                editorMode = .edit
                                editorDraft = WikiSourceDraft(source: source)
                            },
                            onToggleEnabled: {
                                app.toggleWikiBridgeSourceTargetEnabled(source.id)
                            },
                            onDelete: {
                                app.deleteWikiBridgeSourceTarget(source.id)
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

private struct WikiSourceCard: View {
    let source: WikiSource
    let onSetPrimary: () -> Void
    let onTest: () -> Void
    let onEdit: () -> Void
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(source.name)
                .font(.headline)

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Commands: \(source.commands.count)")
                .font(.subheadline)
            Text("Parsing Rules: \(source.parsingRules.count)")
                .font(.subheadline)
            Text("Last Lookup: \(lastLookupLabel)")
                .font(.subheadline)

            HStack(spacing: 8) {
                if !source.isPrimary {
                    Button("Set Primary", action: onSetPrimary)
                        .buttonStyle(.bordered)
                }
                Button("Test", action: onTest)
                    .buttonStyle(.bordered)
                Button("Edit Source", action: onEdit)
                    .buttonStyle(.bordered)
                Button(source.enabled ? "Disable" : "Enable", action: onToggleEnabled)
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

    private var statusText: String {
        let enabledLabel = source.enabled ? "Enabled" : "Disabled"
        return source.isPrimary ? "Primary • \(enabledLabel)" : enabledLabel
    }

    private var lastLookupLabel: String {
        let status = source.lastStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.hasPrefix("Resolved:") {
            return status.replacingOccurrences(of: "Resolved:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if status.hasPrefix("No match for \"") {
            if let start = status.firstIndex(of: "\""),
               let end = status[start...].dropFirst().firstIndex(of: "\"") {
                return String(status[status.index(after: start)..<end])
            }
        }
        if status == "Ready" || status == "Never used" || status.isEmpty {
            return "Never"
        }
        return status
    }
}

private enum WikiBridgeEditorMode {
    case create
    case edit
}

private struct WikiSourceDraft: Identifiable {
    var id: UUID
    var enabled: Bool
    var isPrimary: Bool
    var name: String
    var baseURL: String
    var apiPath: String
    var commands: [WikiCommand]
    var formatting: WikiFormatting
    var parsingRules: [WikiParsingRule]
    var lastLookupAt: Date?
    var lastStatus: String

    init(source: WikiSource) {
        id = source.id
        enabled = source.enabled
        isPrimary = source.isPrimary
        name = source.name
        baseURL = source.baseURL
        apiPath = source.apiPath
        commands = source.commands
        formatting = source.formatting
        parsingRules = source.parsingRules
        lastLookupAt = source.lastLookupAt
        lastStatus = source.lastStatus
    }

    static func makeNew() -> WikiSourceDraft {
        WikiSourceDraft(source: WikiSource.genericTemplate())
    }

    func toSource() -> WikiSource {
        let sanitizedCommands = commands.compactMap { command -> WikiCommand? in
            let trigger = command.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { return nil }
            var updated = command
            updated.trigger = trigger
            let endpoint = command.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.endpoint = endpoint.isEmpty ? "search" : endpoint
            updated.description = command.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return updated
        }

        let sanitizedRules = parsingRules.compactMap { rule -> WikiParsingRule? in
            let pageType = rule.pageType.trimmingCharacters(in: .whitespacesAndNewlines)
            let templateName = rule.templateName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pageType.isEmpty || !templateName.isEmpty else { return nil }
            var updated = rule
            updated.pageType = pageType
            updated.templateName = templateName
            return updated
        }

        let normalizedAPIPath: String = {
            let trimmed = apiPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "/api.php" : trimmed
        }()

        return WikiSource(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiPath: normalizedAPIPath,
            enabled: enabled,
            isPrimary: isPrimary,
            commands: sanitizedCommands,
            formatting: formatting,
            parsingRules: sanitizedRules,
            lastLookupAt: lastLookupAt,
            lastStatus: lastStatus
        )
    }
}

private struct WikiSourceEditorSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: WikiSourceDraft
    @State private var testQuery: String = "akm"
    @State private var isRunningTest = false
    @State private var testResult: FinalsWikiLookupResult?
    @State private var testError: String?

    let mode: WikiBridgeEditorMode
    let onCancel: () -> Void
    let onSave: (WikiSourceDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .create ? "Add Wiki Source" : "Edit Source")
                .font(.title3.weight(.semibold))

            Form {
                sourceSection
                commandsSection
                formattingSection
                parsingRulesSection
                testQuerySection
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
        .frame(minWidth: 820, minHeight: 700)
    }

    private var sourceSection: some View {
        Section {
            TextField("Display Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            TextField("Base URL", text: $draft.baseURL)
                .textFieldStyle(.roundedBorder)

            TextField("API Path (optional; defaults to /api.php)", text: $draft.apiPath)
                .textFieldStyle(.roundedBorder)

            Toggle("Enabled", isOn: $draft.enabled)
        } header: {
            Text("Source")
        }
    }

    private var commandsSection: some View {
        Section {
            HStack {
                Button {
                    draft.commands.append(
                        WikiCommand(
                            id: UUID(),
                            trigger: "!wiki",
                            endpoint: "search",
                            description: "Search wiki pages",
                            enabled: true
                        )
                    )
                } label: {
                    Label("Add Command", systemImage: "plus")
                }
                Spacer()
            }

            if draft.commands.isEmpty {
                Text("No commands configured.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("Trigger")
                        .font(.caption.weight(.semibold))
                        .frame(width: 140, alignment: .leading)
                    Text("Endpoint")
                        .font(.caption.weight(.semibold))
                        .frame(width: 190, alignment: .leading)
                    Text("Enabled")
                        .font(.caption.weight(.semibold))
                        .frame(width: 70, alignment: .center)
                    Spacer()
                }

                ForEach($draft.commands) { $command in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("!wiki", text: $command.trigger)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)

                            TextField("search", text: $command.endpoint)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 190)

                            Toggle("", isOn: $command.enabled)
                                .labelsHidden()
                                .frame(width: 70)

                            Button(role: .destructive) {
                                removeCommand(command.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)

                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Text("Description")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .leading)
                            TextField("Lookup weapon stats", text: $command.description)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Commands")
        }
    }

    private var formattingSection: some View {
        Section {
            Toggle("Include stat blocks", isOn: $draft.formatting.includeStatBlocks)
            Toggle("Use embeds", isOn: $draft.formatting.useEmbeds)
            Toggle("Compact mode", isOn: $draft.formatting.compactMode)
        } header: {
            Text("Formatting")
        }
    }

    private var parsingRulesSection: some View {
        Section {
            HStack {
                Button {
                    draft.parsingRules.append(
                        WikiParsingRule(
                            id: UUID(),
                            pageType: "pageType",
                            templateName: "TemplateName"
                        )
                    )
                } label: {
                    Label("Add Parsing Rule", systemImage: "plus")
                }
                Spacer()
            }

            if draft.parsingRules.isEmpty {
                Text("No parsing rules configured.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("Page Type")
                        .font(.caption.weight(.semibold))
                        .frame(width: 180, alignment: .leading)
                    Text("Template")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                }

                ForEach($draft.parsingRules) { $rule in
                    HStack(spacing: 8) {
                        TextField("weapon", text: $rule.pageType)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)

                        TextField("Weapon", text: $rule.templateName)
                            .textFieldStyle(.roundedBorder)

                        Button(role: .destructive) {
                            removeParsingRule(rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("Parsing Rules")
        }
    }

    private var testQuerySection: some View {
        Section {
            HStack(spacing: 10) {
                TextField("akm", text: $testQuery)
                    .textFieldStyle(.roundedBorder)

                Button("Run Test") {
                    runTestQuery()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunningTest || draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if isRunningTest {
                ProgressView("Testing source...")
            }

            if let testError, !testError.isEmpty {
                Text(testError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let testResult {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Top Result")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(testResult.title)
                        .font(.headline)
                    if !summaryPreview(testResult.extract).isEmpty {
                        Text(summaryPreview(testResult.extract))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(testResult.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } header: {
            Text("Test Query")
        }
    }

    private func runTestQuery() {
        let trimmedQuery = testQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            testError = "Enter a test query first."
            testResult = nil
            return
        }

        let source = draft.toSource()
        isRunningTest = true
        testError = nil
        testResult = nil

        Task {
            let result = await app.runWikiBridgeSourceTestQuery(source: source, query: trimmedQuery)
            await MainActor.run {
                isRunningTest = false
                if let result {
                    testResult = result
                } else {
                    testError = "No results found for \"\(trimmedQuery)\"."
                }
            }
        }
    }

    private func summaryPreview(_ text: String, limit: Int = 260) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        let idx = cleaned.index(cleaned.startIndex, offsetBy: limit)
        return String(cleaned[..<idx]) + "..."
    }

    private func removeCommand(_ id: UUID) {
        draft.commands.removeAll { $0.id == id }
    }

    private func removeParsingRule(_ id: UUID) {
        draft.parsingRules.removeAll { $0.id == id }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
