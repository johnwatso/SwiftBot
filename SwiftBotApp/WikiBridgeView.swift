import SwiftUI

struct WikiBridgeView: View {
    @EnvironmentObject var app: AppModel

    @State private var editorDraft: WikiSourceDraft?
    @State private var editorMode: WikiBridgeEditorMode = .create

    private var sortedSources: [WikiSource] {
        app.settings.wikiBot.sources.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary {
                return lhs.isPrimary && !rhs.isPrimary
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var totalCommands: Int {
        app.settings.wikiBot.sources.reduce(0) { $0 + $1.commands.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. WikiBridge settings sync from Primary.")
            }

            if app.settings.wikiBot.isEnabled {
                metricRail
                masterControls
                sourcesList
            } else {
                disabledStateContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .disabled(app.isFailoverManagedNode)
        .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ViewSectionHeader(title: "WikiBridge", symbol: "book.pages.fill")
            Spacer()
        }
    }

    // MARK: - Metric Rail

    private var metricRail: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
            spacing: 8
        ) {
            ForEach(WikiBridgeDashboardSummary.metrics(app: app)) { metric in
                DashboardMetricCard(metric: metric)
            }
        }
    }

    // MARK: - Master Controls

    private var masterControls: some View {
        HStack(spacing: 12) {
            Toggle("WikiBridge", isOn: Binding(
                get: { app.settings.wikiBot.isEnabled },
                set: { newValue in
                    var updated = app.settings
                    updated.wikiBot.isEnabled = newValue
                    app.settings = updated
                    app.saveSettings()
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Spacer()

            Button {
                editorMode = .create
                editorDraft = WikiSourceDraft.makeNew()
            } label: {
                Label("Add Source", systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
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

    // MARK: - Sources List

    private var sourcesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if sortedSources.isEmpty {
                    emptySourcesState
                } else {
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
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptySourcesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "book.pages.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No wiki sources configured")
                .font(.subheadline.weight(.semibold))
            Text("Add a source to enable wiki lookups in Discord.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                editorMode = .create
                editorDraft = WikiSourceDraft.makeNew()
            } label: {
                Label("Add First Source", systemImage: "plus")
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

    // MARK: - Disabled State

    private var disabledStateContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "book.pages.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("WikiBridge is disabled")
                .font(.subheadline.weight(.semibold))
            Text("Enable WikiBridge to manage wiki sources and commands.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                var updated = app.settings
                updated.wikiBot.isEnabled = true
                app.settings = updated
                app.saveSettings()
            } label: {
                Label("Enable WikiBridge", systemImage: "checkmark.circle.fill")
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
}

// MARK: - Wiki Source Card

private struct WikiSourceCard: View {
    let source: WikiSource
    let onSetPrimary: () -> Void
    let onTest: () -> Void
    let onEdit: () -> Void
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var showDeleteConfirm = false

    private let tint: Color = .indigo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title row
            HStack(spacing: 8) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(source.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    if source.isPrimary {
                        WikiStatusPill(text: "Primary", color: .orange)
                    }
                    WikiStatusPill(
                        text: source.enabled ? "Enabled" : "Disabled",
                        color: source.enabled ? .green : .secondary
                    )
                }
            }

            // Detail rows
            VStack(alignment: .leading, spacing: 4) {
                DiagnosticsLine(
                    label: "Base URL",
                    value: source.baseURL,
                    tone: .primary
                )
                DiagnosticsLine(
                    label: "Commands",
                    value: "\(source.commands.count) \(source.commands.map(\.trigger).joined(separator: ", "))",
                    tone: .primary
                )
                DiagnosticsLine(
                    label: "Parsing Rules",
                    value: source.parsingRules.isEmpty ? "None" : "\(source.parsingRules.count) configured",
                    tone: .primary
                )
                DiagnosticsLine(
                    label: "Last Lookup",
                    value: lastLookupLabel,
                    tone: source.lastLookupAt == nil ? .secondary : .primary
                )
            }

            // Status line
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Text(source.lastStatus.isEmpty ? "Ready" : source.lastStatus)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(statusColor.opacity(0.06))
            )

            // Action buttons
            HStack(spacing: 6) {
                if !source.isPrimary {
                    WikiIconButton(symbol: "star.fill", color: .orange, help: "Set Primary") { onSetPrimary() }
                }
                WikiIconButton(symbol: "bolt.fill", color: .primary, help: "Test source") { onTest() }
                WikiIconButton(symbol: "pencil", color: .primary, help: "Edit source") { onEdit() }
                WikiIconButton(
                    symbol: source.enabled ? "pause.circle.fill" : "play.circle.fill",
                    color: source.enabled ? .orange : .green,
                    help: source.enabled ? "Disable" : "Enable"
                ) { onToggleEnabled() }
                WikiIconButton(symbol: "trash", color: .red, help: "Delete source") { showDeleteConfirm = true }
                    .alert("Delete Source?", isPresented: $showDeleteConfirm) {
                        Button("Delete", role: .destructive) { onDelete() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("\"\(source.name)\" and all its commands will be permanently deleted.")
                    }
                Spacer()
            }
        }
        .padding(10)
        .glassCard(
            cornerRadius: 14,
            tint: tint.opacity(isHovering ? 0.10 : 0.05),
            stroke: tint.opacity(isHovering ? 0.28 : 0.16)
        )
        .scaleEffect(isHovering ? 1.006 : 1)
        .shadow(color: tint.opacity(isHovering ? 0.06 : 0.03), radius: isHovering ? 8 : 4, y: isHovering ? 4 : 2)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.18)) {
                isHovering = hovering
            }
        }
    }

    private var lastLookupLabel: String {
        guard let date = source.lastLookupAt else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var statusColor: Color {
        let status = source.lastStatus.lowercased()
        if status.contains("error") || status.contains("failed") || status.contains("no result") {
            return .red
        }
        if status.contains("resolved") {
            return .green
        }
        if source.lastLookupAt == nil || status == "ready" || status == "never used" {
            return .secondary
        }
        return .green
    }

    private var statusIcon: String {
        switch statusColor {
        case .red: return "exclamationmark.circle.fill"
        case .green: return "checkmark.circle.fill"
        default: return "info.circle.fill"
        }
    }
}

// MARK: - Wiki Icon Button

private struct WikiIconButton: View {
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

// MARK: - Wiki Status Pill

private struct WikiStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.10), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Editor

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
            let trigger = Self.slashCommandTrigger(command.trigger)
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

    private static func slashCommandTrigger(_ raw: String) -> String {
        var normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let first = normalized.split(separator: " ").first {
            normalized = String(first)
        }
        while let first = normalized.first, first == "!" || first == "/" {
            normalized.removeFirst()
        }
        normalized = normalized
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "-" || character == "_" {
                    return character
                }
                return "-"
            }
            .reduce(into: "") { partial, character in
                if character == "-", partial.last == "-" { return }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return normalized.isEmpty ? "" : "/\(normalized)"
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
                .toggleStyle(.switch)
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
                            trigger: "/wiki",
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
                            TextField("/wiki", text: $command.trigger)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)

                            TextField("search", text: $command.endpoint)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 190)

                            Toggle("", isOn: $command.enabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
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
                .toggleStyle(.switch)
            Toggle("Use embeds", isOn: $draft.formatting.useEmbeds)
                .toggleStyle(.switch)
            Toggle("Compact mode", isOn: $draft.formatting.compactMode)
                .toggleStyle(.switch)
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
                .buttonStyle(GlassActionButtonStyle())
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

enum WikiBridgeDashboardSummary {
    @MainActor
    static func metrics(app: AppModel) -> [DashboardMetricDescriptor] {
        let sources = app.settings.wikiBot.sources
        let primary = app.settings.wikiBot.primarySource()
        let totalCommands = sources.reduce(0) { $0 + $1.commands.count }
        let enabledSources = sources.filter(\.enabled).count
        let enabledCommands = sources
            .filter(\.enabled)
            .reduce(0) { $0 + $1.commands.filter(\.enabled).count }

        return [
            DashboardMetricDescriptor(
                id: "wikibridge",
                title: "WikiBridge",
                value: app.settings.wikiBot.isEnabled ? "Enabled" : "Disabled",
                subtitle: "\(enabledSources) active sources",
                symbol: "book.pages.fill",
                detail: "\(enabledCommands) active commands",
                color: .mint
            ),
            DashboardMetricDescriptor(
                id: "wikibridge-sources",
                title: "Sources",
                value: "\(sources.count)",
                subtitle: "Configured",
                symbol: "square.stack.3d.up.fill",
                color: .indigo
            ),
            DashboardMetricDescriptor(
                id: "wikibridge-enabled",
                title: "Enabled",
                value: "\(enabledSources)",
                subtitle: "Active",
                symbol: "checkmark.circle.fill",
                color: .green
            ),
            DashboardMetricDescriptor(
                id: "wikibridge-commands",
                title: "Commands",
                value: "\(totalCommands)",
                subtitle: "Total",
                symbol: "command",
                color: .teal
            ),
            DashboardMetricDescriptor(
                id: "wikibridge-primary",
                title: "Primary",
                value: primary?.name ?? "-",
                subtitle: primary?.isPrimary == true ? "Active" : "Auto",
                symbol: "star.fill",
                color: .orange
            )
        ]
    }
}
