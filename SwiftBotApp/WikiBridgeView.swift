import SwiftUI

private let lookupSymbol = "rectangle.and.text.magnifyingglass"

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
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. Lookup settings sync from Primary.")
            }

            if app.settings.wikiBot.isEnabled {
                metricRail
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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                ViewSectionHeader(title: "Lookup", symbol: lookupSymbol)
                HStack(spacing: 6) {
                    Circle()
                        .fill(app.settings.wikiBot.isEnabled ? Color.green : Color.gray)
                        .frame(width: 7, height: 7)
                    Text("Gaming stat lookups and compare commands from configured sources.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Image(systemName: lookupSymbol)
                        .font(.caption.weight(.semibold))
                    Text(app.settings.wikiBot.isEnabled ? "LOOKUP ACTIVE" : "LOOKUP INACTIVE")
                        .font(.caption.weight(.bold))
                        .tracking(0.4)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(app.settings.wikiBot.isEnabled ? Color.green : Color.gray)
                )

                Button {
                    openCustomSourceSetup()
                } label: {
                    Label("Add Source", systemImage: "plus")
                }
                .buttonStyle(GlassActionButtonStyle())
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Metric Rail

    private var metricRail: some View {
        LazyVGrid(columns: DashboardMetricGrid.columns, spacing: DashboardMetricGrid.spacing) {
            ForEach(WikiBridgeDashboardSummary.metrics(app: app)) { metric in
                DashboardMetricCard(metric: metric)
            }
        }
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
            .padding(.bottom, 2)
            .padding(.top, 16)
        }
        .fadingEdges(top: 16, bottom: 20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptySourcesState: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: lookupSymbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Create your first gaming stat source")
                        .font(.headline)
                    Text("Start from THE FINALS or paste another game wiki. Lookup will fill the source name, commands, and stat defaults where it can.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                LookupStarterCard(
                    title: "THE FINALS",
                    subtitle: "Weapons, stat blocks, and compare-ready commands.",
                    symbol: "scope",
                    tint: .orange,
                    actionTitle: "Use Starter"
                ) {
                    openTheFinalsStarter()
                }

                LookupStarterCard(
                    title: "Custom Game Wiki",
                    subtitle: "Paste a MediaWiki or Fandom URL and preview one item.",
                    symbol: "link.badge.plus",
                    tint: .blue,
                    actionTitle: "Paste URL"
                ) {
                    openCustomSourceSetup()
                }
            }

            HStack(spacing: 12) {
                LookupSetupStep(index: 1, title: "Paste URL", detail: "Detects the host and source name.")
                LookupSetupStep(index: 2, title: "Pick preset", detail: "Search only or weapon stats.")
                LookupSetupStep(index: 3, title: "Preview item", detail: "Test one page before saving.")
            }
        }
        .padding(16)
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

    private func openCustomSourceSetup() {
        editorMode = .create
        editorDraft = WikiSourceDraft.makeNew()
    }

    private func openTheFinalsStarter() {
        editorMode = .create
        editorDraft = WikiSourceDraft.theFinalsStarter()
    }

    // MARK: - Disabled State

    private var disabledStateContent: some View {
        VStack(spacing: 8) {
            Image(systemName: lookupSymbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Lookup is disabled")
                .font(.subheadline.weight(.semibold))
            Text("Enable Lookup to manage gaming stat sources and commands.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                var updated = app.settings
                updated.wikiBot.isEnabled = true
                app.settings = updated
                app.saveSettings()
            } label: {
                Label("Enable Lookup", systemImage: "checkmark.circle.fill")
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

    @State private var showDeleteConfirm = false

    private let tint: Color = .indigo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title row
            HStack(spacing: 8) {
                Image(systemName: lookupSymbol)
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
        .dashboardSurface(
            cornerRadius: 14,
            fillOpacity: 0.035,
            strokeOpacity: 0.07,
            shadowOpacity: 0.015
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.02))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        )
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

private struct LookupStarterCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: action) {
                Label(actionTitle, systemImage: "arrow.right")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct LookupSetupStep: View {
    let index: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text("\(index)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.75)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LookupDetectionResult {
    enum Tone {
        case success
        case warning
    }

    let tone: Tone
    let title: String
    let message: String
    let nextStep: String

    static func success(title: String, message: String, nextStep: String) -> LookupDetectionResult {
        LookupDetectionResult(tone: .success, title: title, message: message, nextStep: nextStep)
    }

    static func warning(title: String, message: String, nextStep: String) -> LookupDetectionResult {
        LookupDetectionResult(tone: .warning, title: title, message: message, nextStep: nextStep)
    }
}

private struct LookupDetectionResultView: View {
    let result: LookupDetectionResult

    private var tint: Color {
        switch result.tone {
        case .success: return .green
        case .warning: return .orange
        }
    }

    private var symbol: String {
        switch result.tone {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(result.title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(result.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(result.nextStep)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.20), lineWidth: 1)
        )
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
    var searchScope: String
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
        searchScope = source.searchScope
        commands = source.commands
        formatting = source.formatting
        parsingRules = source.parsingRules
        lastLookupAt = source.lastLookupAt
        lastStatus = source.lastStatus
    }

    static func makeNew() -> WikiSourceDraft {
        WikiSourceDraft(source: WikiSource.genericTemplate())
    }

    static func theFinalsStarter() -> WikiSourceDraft {
        WikiSourceDraft(source: WikiSource.defaultFinals())
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

        var sanitizedFormatting = formatting
        sanitizedFormatting.useEmbeds = true
        sanitizedFormatting.hiddenEmbedFields = Set(
            sanitizedFormatting.hiddenEmbedFields
                .map(Self.normalizedEmbedFieldName)
                .filter { !$0.isEmpty }
        )

        return WikiSource(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiPath: normalizedAPIPath,
            searchScope: searchScope.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabled,
            isPrimary: isPrimary,
            commands: sanitizedCommands,
            formatting: sanitizedFormatting,
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

    static func normalizedEmbedFieldName(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }
}

private struct WikiSourceEditorSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: WikiSourceDraft
    @State private var testQuery: String = "akm"
    @State private var showAdvanced = false
    @State private var didAutoNameFromURL = false
    @State private var isDetectingSource = false
    @State private var detectionResult: LookupDetectionResult?
    @State private var isRunningTest = false
    @State private var testResult: FinalsWikiLookupResult?
    @State private var testError: String?
    @State private var embedPreviewRevision = UUID()

    let mode: WikiBridgeEditorMode
    let onCancel: () -> Void
    let onSave: (WikiSourceDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            editorHeader

            Form {
                quickSetupSection
                sourceSection
                presetSection
                testQuerySection
                advancedSection
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

    private var editorHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: lookupSymbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(mode == .create ? "Add Lookup Source" : "Edit Lookup Source")
                    .font(.title3.weight(.semibold))
                Text("Connect a game wiki, test one item, then save the commands SwiftBot should expose in Discord.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var quickSetupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "1.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paste a game wiki URL")
                            .font(.subheadline.weight(.semibold))
                        Text("Lookup assumes MediaWiki/Fandom-style sources first, which matches the current stats pipeline.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    TextField("https://www.thefinals.wiki", text: $draft.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: draft.baseURL) { _, newValue in
                            suggestSourceDetails(from: newValue)
                        }

                    Button {
                        Task { await autoDetectSource() }
                    } label: {
                        if isDetectingSource {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Auto Detect", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(GlassActionButtonStyle())
                    .disabled(isDetectingSource || draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let detectionResult {
                    LookupDetectionResultView(result: detectionResult)
                }

                HStack(spacing: 8) {
                    Button {
                        applyTheFinalsStarter()
                    } label: {
                        Label("Use THE FINALS", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        applyGamingStatsPreset()
                    } label: {
                        Label("Gaming Stats Defaults", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    if !sourceHostLabel.isEmpty {
                        Label(sourceHostLabel, systemImage: "network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Quick Setup")
        }
    }

    private var sourceSection: some View {
        Section {
            TextField("Display Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            TextField("API Path (optional; defaults to /api.php)", text: $draft.apiPath)
                .textFieldStyle(.roundedBorder)

            TextField("Search Scope (optional, e.g. Modern Warfare 2019)", text: $draft.searchScope)
                .textFieldStyle(.roundedBorder)

            Toggle("Enabled", isOn: $draft.enabled)
                .toggleStyle(.switch)
        } header: {
            Text("Game Wiki Source")
        }
    }

    private var presetSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Stat lookup commands", systemImage: "chart.bar.doc.horizontal")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(draft.commands.filter(\.enabled).count) enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(commandPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Button("Search + Weapon Stats") {
                        applyGamingStatsPreset()
                    }
                    .buttonStyle(.bordered)

                    Button("Search Only") {
                        applySearchOnlyPreset()
                    }
                    .buttonStyle(.bordered)
                }
            }
        } header: {
            Text("Command Preset")
        }
    }

    private var commandsSection: some View {
        Section {
            HStack {
                Button {
                    draft.commands.append(
                        WikiCommand(
                            id: UUID(),
                            trigger: "/game",
                            endpoint: "search",
                            description: "Search game stat pages",
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
                            TextField("/game", text: $command.trigger)
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
            Toggle("Compact mode", isOn: $draft.formatting.compactMode)
                .toggleStyle(.switch)
        } header: {
            Text("Formatting")
        } footer: {
            Text("Lookup replies are always sent as Discord embeds.")
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Try one real item from this game before saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if draft.formatting.includeStatBlocks {
                    Text("If the page has structured data, the preview will show detected fields before you save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
                    Text("Discord Embed Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LookupDiscordEmbedPreview(embed: app.wikiEmbed(source: draft.toSource(), result: testResult))
                        .id(embedPreviewRevision)
                }

                let fields = embedFieldOptions(for: testResult)
                if !fields.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Embed Fields")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Show All") {
                                var hiddenFields = draft.formatting.hiddenEmbedFields
                                hiddenFields.subtract(fields.map(\.key))
                                setHiddenEmbedFields(hiddenFields)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], alignment: .leading, spacing: 8) {
                            ForEach(fields, id: \.key) { field in
                                Toggle(isOn: embedFieldVisibilityBinding(for: field.key)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(field.name)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                        Text(field.value)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        } header: {
            Text("Preview")
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
                    commandsSection
                    formattingSection
                    parsingRulesSection
                }
                .padding(.top, 6)
            } label: {
                Label("Advanced command and parser settings", systemImage: "gearshape")
                    .font(.subheadline.weight(.semibold))
            }
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

    private func embedFieldOptions(for result: FinalsWikiLookupResult) -> [(key: String, name: String, value: String)] {
        var source = draft.toSource()
        source.formatting.hiddenEmbedFields = []
        let embed = app.wikiEmbed(source: source, result: result)
        guard let rawFields = embed["fields"] as? [[String: Any]] else { return [] }

        var seen: Set<String> = []
        return rawFields.compactMap { raw in
            guard let name = raw["name"] as? String,
                  let value = raw["value"] as? String else { return nil }
            let key = WikiSourceDraft.normalizedEmbedFieldName(name)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return (key: key, name: name, value: value)
        }
    }

    private func embedFieldVisibilityBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { !draft.formatting.hiddenEmbedFields.contains(key) },
            set: { isVisible in
                var hiddenFields = draft.formatting.hiddenEmbedFields
                if isVisible {
                    hiddenFields.remove(key)
                } else {
                    hiddenFields.insert(key)
                }
                setHiddenEmbedFields(hiddenFields)
            }
        )
    }

    private func setHiddenEmbedFields(_ fields: Set<String>) {
        var formatting = draft.formatting
        formatting.hiddenEmbedFields = fields
        draft.formatting = formatting
        embedPreviewRevision = UUID()
    }

    private var sourceHostLabel: String {
        normalizedBaseURLComponents()?.host ?? ""
    }

    private var commandPreview: String {
        let enabled = draft.commands
            .filter(\.enabled)
            .map(\.trigger)
            .joined(separator: ", ")
        return enabled.isEmpty ? "No commands enabled yet." : enabled
    }

    private func normalizeBaseURL() {
        let trimmed = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = String(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            draft.baseURL = normalized
        } else {
            draft.baseURL = "https://\(normalized)"
        }
    }

    private func normalizedBaseURLComponents() -> URLComponents? {
        let trimmed = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
            ? trimmed
            : "https://\(trimmed)"
        return URLComponents(string: normalized)
    }

    private func suggestSourceDetails(from rawURL: String, force: Bool = false) {
        guard let components = normalizedBaseURLComponents(),
              let host = components.host else { return }
        let suggestedName = suggestedSourceName(host: host)
        let currentName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if force || didAutoNameFromURL || currentName.isEmpty || currentName == "New Game Wiki" || currentName == "New Wiki" {
            draft.name = suggestedName
            didAutoNameFromURL = true
        }

        if force || draft.commands.isEmpty || draft.commands.allSatisfy({ ["/wiki", "/weapon"].contains($0.trigger) }) {
            applyGamingStatsPreset(commandSlug: suggestedCommandSlug(host: host, name: suggestedName))
        }
    }

    @MainActor
    private func autoDetectSource() async {
        normalizeBaseURL()
        guard let components = normalizedBaseURLComponents(),
              let host = components.host,
              let baseURL = components.url else {
            detectionResult = .warning(
                title: "Enter a valid wiki URL",
                message: "Lookup could not read that address. Paste the root of the game wiki, such as https://www.thefinals.wiki.",
                nextStep: "Fix the URL, then run Auto Detect again."
            )
            return
        }

        isDetectingSource = true
        detectionResult = nil
        defer { isDetectingSource = false }

        let localName = suggestedSourceName(host: host)
        let localSlug = suggestedCommandSlug(host: host, name: localName)
        suggestSourceDetails(from: draft.baseURL, force: true)

        if let siteInfo = await detectMediaWikiSiteInfo(baseURL: baseURL, apiPath: draft.apiPath) {
            draft.apiPath = siteInfo.apiPath
            let siteName = siteInfo.siteName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !siteName.isEmpty {
                draft.name = siteName.lowercased().contains("wiki") ? siteName : "\(siteName) Wiki"
            }
            applyGamingStatsPreset(commandSlug: suggestedCommandSlug(host: host, name: draft.name))
            detectionResult = .success(
                title: "Detected MediaWiki source",
                message: "Filled in \(draft.name), confirmed \(siteInfo.apiPath), enabled stat embeds, and generated \(commandPreview).",
                nextStep: "Enter a known item below, then run Preview to verify the first result and stat parsing."
            )
        } else {
            draft.name = localName
            applyGamingStatsPreset(commandSlug: localSlug)
            detectionResult = .warning(
                title: "Applied best-guess defaults",
                message: "Lookup could not confirm a MediaWiki API, but it filled the name, commands, stat blocks, and weapon parser defaults from the URL.",
                nextStep: "Run Preview with a known item. If it misses, open Advanced and adjust the API path or use Search Only."
            )
        }
    }

    private func detectMediaWikiSiteInfo(baseURL: URL, apiPath: String) async -> (siteName: String, apiPath: String)? {
        let candidatePaths = Array(Set([
            apiPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/api.php" : apiPath,
            "/api.php",
            "/w/api.php"
        ]))

        for path in candidatePaths {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { continue }
            components.path = path.hasPrefix("/") ? path : "/\(path)"
            components.queryItems = [
                URLQueryItem(name: "action", value: "query"),
                URLQueryItem(name: "meta", value: "siteinfo"),
                URLQueryItem(name: "siprop", value: "general"),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "origin", value: "*")
            ]
            guard let url = components.url else { continue }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 6
                request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let query = object["query"] as? [String: Any],
                      let general = query["general"] as? [String: Any] else { continue }
                let siteName = general["sitename"] as? String ?? general["wikiid"] as? String ?? ""
                return (siteName, path)
            } catch {
                continue
            }
        }

        return nil
    }

    private func suggestedSourceName(host: String) -> String {
        let lowerHost = host.lowercased()
        if lowerHost.contains("thefinals.wiki") {
            return "THE FINALS Wiki"
        }

        let usefulPart: String = {
            let parts = lowerHost.split(separator: ".").map(String.init)
            if let fandomIndex = parts.firstIndex(of: "fandom"), fandomIndex > 0 {
                return parts[fandomIndex - 1]
            }
            if parts.first == "www", parts.count > 1 {
                return parts[1]
            }
            return parts.first ?? host
        }()

        let title = usefulPart
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return title.isEmpty ? "Game Wiki" : "\(title) Wiki"
    }

    private func suggestedCommandSlug(host: String, name: String) -> String {
        if host.lowercased().contains("thefinals.wiki") {
            return "finals"
        }
        let base = name
            .replacingOccurrences(of: " Wiki", with: "")
            .replacingOccurrences(of: "THE ", with: "")
        let slug = base
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "lookup" : String(slug.prefix(32))
    }

    private func applyTheFinalsStarter() {
        draft.name = "THE FINALS Wiki"
        draft.baseURL = "https://www.thefinals.wiki"
        draft.apiPath = "/api.php"
        testQuery = "AKM"
        applyGamingStatsPreset(commandSlug: "finals")
        didAutoNameFromURL = true
    }

    private func applyGamingStatsPreset(commandSlug: String? = nil) {
        let slug = commandSlug ?? suggestedCommandSlug(
            host: normalizedBaseURLComponents()?.host ?? "",
            name: draft.name
        )
        draft.commands = [
            WikiCommand(trigger: "/\(slug)", endpoint: "search", description: "Search \(draft.name) stats", enabled: true)
        ]
        draft.formatting.includeStatBlocks = true
        draft.formatting.useEmbeds = true
        draft.formatting.compactMode = false
        if draft.parsingRules.isEmpty {
            draft.parsingRules = [WikiParsingRule(pageType: "weapon", templateName: "Weapon")]
        }
    }

    private func applySearchOnlyPreset() {
        let slug = suggestedCommandSlug(
            host: normalizedBaseURLComponents()?.host ?? "",
            name: draft.name
        )
        draft.commands = [
            WikiCommand(trigger: "/\(slug)", endpoint: "search", description: "Search \(draft.name)", enabled: true)
        ]
        draft.formatting.includeStatBlocks = false
        draft.formatting.useEmbeds = true
        draft.formatting.compactMode = true
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

private struct LookupDetectedStatsPreview: View {
    let stats: FinalsWeaponStats

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Detected Weapon Stats")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 6) {
                ForEach(rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .padding(.top, 4)
    }

    private var rows: [(label: String, value: String)] {
        let rawRows: [(label: String, value: String?)] = [
            ("Type", stats.type),
            ("Body", stats.bodyDamage),
            ("Head", stats.headshotDamage),
            ("RPM", stats.fireRate),
            ("Magazine", stats.magazineSize),
            ("Reload", [stats.shortReload, stats.longReload].compactMap { cleaned($0) }.joined(separator: " / "))
        ]
        return rawRows.compactMap { row in
            let cleanedValue = cleaned(row.value)
            return cleanedValue.isEmpty ? nil : (row.label, cleanedValue)
        }
    }

    private func cleaned(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct LookupDetectedFieldsPreview: View {
    let fields: [WikiResultField]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Detected Fields")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 6) {
                ForEach(Array(fields.prefix(12)), id: \.name) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.name)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(field.value)
                            .font(.caption)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            Text("These fields will appear in embeds and text replies when embeds are disabled.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}

private struct LookupDiscordEmbedPreview: View {
    let embed: [String: Any]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accentColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let title {
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(red: 0.20, green: 0.48, blue: 0.98))
                                .lineLimit(2)
                        }
                        if let description {
                            Text(description)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if let thumbnailURL {
                        AsyncImage(url: URL(string: thumbnailURL)) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            default:
                                Image(systemName: "photo")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }

                if !fields.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 10)], alignment: .leading, spacing: 8) {
                        ForEach(Array(fields.prefix(12).enumerated()), id: \.offset) { _, field in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(field.value)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(field.inline ? 2 : 4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if let footer {
                    Text(footer)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.top, 4)
    }

    private var title: String? {
        stringValue(embed["title"])
    }

    private var description: String? {
        stringValue(embed["description"])
    }

    private var thumbnailURL: String? {
        (embed["thumbnail"] as? [String: Any]).flatMap { stringValue($0["url"]) }
    }

    private var footer: String? {
        (embed["footer"] as? [String: Any]).flatMap { stringValue($0["text"]) }
    }

    private var fields: [(name: String, value: String, inline: Bool)] {
        guard let rawFields = embed["fields"] as? [[String: Any]] else { return [] }
        return rawFields.compactMap { raw in
            guard let name = stringValue(raw["name"]),
                  let value = stringValue(raw["value"]) else { return nil }
            return (name, value, raw["inline"] as? Bool ?? false)
        }
    }

    private var accentColor: Color {
        guard let value = embed["color"] as? Int else {
            return Color(red: 0.35, green: 0.51, blue: 0.97)
        }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
                title: "Lookup",
                value: app.settings.wikiBot.isEnabled ? "Enabled" : "Disabled",
                subtitle: "\(enabledSources) active sources",
                symbol: lookupSymbol,
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
