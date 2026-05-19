import SwiftUI

// MARK: - Command Category

private enum CommandGroup: String, CaseIterable {
    case general = "General"
    case utilities = "Utilities & AI"
    case moderation = "Moderation"
    case infrastructure = "Infrastructure"
    case gaming = "Gaming"

    var color: Color {
        switch self {
        case .general: return .blue
        case .utilities: return .purple
        case .moderation: return .orange
        case .infrastructure: return .cyan
        case .gaming: return .green
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.2.fill"
        case .utilities: return "wand.and.stars"
        case .moderation: return "shield.lefthalf.filled"
        case .infrastructure: return "server.rack"
        case .gaming: return "gamecontroller.fill"
        }
    }
}

// MARK: - Visual Command

private struct VisualCommand: Identifiable {
    let id: String
    let name: String
    let usage: String
    let description: String
    let category: CommandGroup
    let surfaces: [String]
    let aliases: [String]
    let adminOnly: Bool
    let icon: String
}

// MARK: - Command Control Center

struct CommandsView: View {
    @EnvironmentObject var app: AppModel
    @State private var showSettingsUpdatedToast = false
    @State private var settingsToastTask: Task<Void, Never>?

    // MARK: - Visual Commands

    private var visualSlashCommands: [VisualCommand] {
        app.allSlashCommandDefinitions().compactMap { raw in
            guard let name = raw["name"] as? String else { return nil }
            let description = (raw["description"] as? String) ?? "No description"
            let options = (raw["options"] as? [[String: Any]]) ?? []
            let usageSuffix = options.compactMap { option in
                guard let optionName = option["name"] as? String else { return nil }
                let required = (option["required"] as? Bool) ?? false
                return required ? " \(optionName):<value>" : " [\(optionName):<value>]"
            }.joined()
            return VisualCommand(
                id: "slash-\(name)",
                name: name,
                usage: "/\(name)\(usageSuffix)",
                description: description,
                category: group(for: name),
                surfaces: ["Slash"],
                aliases: [],
                adminOnly: name == "debug",
                icon: icon(for: name)
            )
        }
    }

    private var allVisualCommands: [VisualCommand] {
        guard app.settings.commandsEnabled else { return [] }

        var commandsByName: [String: VisualCommand] = [:]
        if app.settings.slashCommandsEnabled {
            for command in visualSlashCommands {
                let key = command.name.lowercased()
                if var existing = commandsByName[key] {
                    let mergedSurfaces = Array(Set(existing.surfaces + command.surfaces))
                        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                    existing = VisualCommand(
                        id: existing.id,
                        name: existing.name,
                        usage: existing.usage,
                        description: existing.description,
                        category: existing.category,
                        surfaces: mergedSurfaces,
                        aliases: existing.aliases,
                        adminOnly: existing.adminOnly || command.adminOnly,
                        icon: existing.icon
                    )
                    commandsByName[key] = existing
                } else {
                    commandsByName[key] = command
                }
            }
        }
        commandsByName["bug-mention"] = VisualCommand(
            id: "mention-bug",
            name: "bug",
            usage: "@swiftbot bug (reply to a message)",
            description: "Creates a tracked bug report in #swiftbot-dev and manages status via reactions.",
            category: CommandGroup.moderation,
            surfaces: ["Mention"],
            aliases: [],
            adminOnly: true,
            icon: "ant.fill"
        )

        return commandsByName.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func commandEnabledBinding(for command: VisualCommand) -> Binding<Bool> {
        if command.id == "mention-bug" {
            return Binding(
                get: { app.settings.bugTrackingEnabled },
                set: {
                    app.settings.bugTrackingEnabled = $0
                    persistCommandSettings(syncSlash: false)
                }
            )
        }
        return Binding(
            get: {
                command.surfaces.allSatisfy { surface in
                    app.isCommandEnabled(name: command.name, surface: surface.lowercased())
                }
            },
            set: { enabled in
                for surface in command.surfaces {
                    app.setCommandEnabled(name: command.name, surface: surface.lowercased(), enabled: enabled)
                }
                persistCommandSettings(syncSlash: true)
            }
        )
    }

    private func persistCommandSettings(syncSlash: Bool) {
        app.persistSettingsQuietly()
        if syncSlash {
            Task { await app.registerSlashCommandsIfNeeded() }
        }
        settingsToastTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) {
            showSettingsUpdatedToast = true
        }
        settingsToastTask = Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) {
                    showSettingsUpdatedToast = false
                }
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. Command settings sync from Primary.")
            }
            metricRail
            masterControls
            commandCatalog
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .disabled(app.isFailoverManagedNode)
        .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        .overlay(alignment: .topTrailing) {
            if showSettingsUpdatedToast {
                Text("Settings updated")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    )
                    .padding(.trailing, 18)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: app.settings.commandsEnabled) { _, _ in
            persistCommandSettings(syncSlash: true)
        }
        .onChange(of: app.settings.slashCommandsEnabled) { _, _ in
            persistCommandSettings(syncSlash: true)
        }
        .onChange(of: app.settings.bugTrackingEnabled) { _, _ in
            persistCommandSettings(syncSlash: false)
        }
        .onChange(of: app.settings.disabledCommandKeys) { _, _ in
            persistCommandSettings(syncSlash: true)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ViewSectionHeader(title: "Commands", symbol: "terminal.fill")
            Spacer()
        }
    }

    // MARK: - Metric Rail

    private var metricRail: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
            spacing: 8
        ) {
            ForEach(CommandsDashboardSummary.metrics(app: app)) { metric in
                DashboardMetricCard(metric: metric)
            }
        }
    }

    // MARK: - Master Controls

    private var masterControls: some View {
        HStack(spacing: 12) {
            Toggle("Commands", isOn: $app.settings.commandsEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle("Slash", isOn: $app.settings.slashCommandsEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!app.settings.commandsEnabled)

            Spacer()
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

    // MARK: - Command Catalog

    private var commandCatalog: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if allVisualCommands.isEmpty {
                    emptyState
                } else {
                    ForEach(CommandGroup.allCases, id: \.self) { category in
                        let group = commandsInGroup(category, commands: allVisualCommands)
                        if !group.isEmpty {
                            CommandSection(
                                category: category,
                                commands: group,
                                commandEnabledBinding: commandEnabledBinding
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No commands available")
                .font(.subheadline.weight(.semibold))
            Text("Commands appear once the bot registers them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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

    // MARK: - Helpers

    private func commandsInGroup(_ group: CommandGroup, commands: [VisualCommand]) -> [VisualCommand] {
        commands.filter { $0.category == group }
    }

    private func group(for commandName: String) -> CommandGroup {
        switch commandName.lowercased() {
        case "help", "ping", "userinfo":
            return .general
        case "roll", "8ball", "poll", "image", "music", "playlist", "wiki":
            return .utilities
        case "debug", "bugreport", "logabug", "featurerequest", "ignorechannel", "setchannel", "notifystatus":
            return .moderation
        case "cluster", "miner", "weekly":
            return .infrastructure
        case "compare", "meta":
            return .gaming
        default:
            return .general
        }
    }

    private func icon(for commandName: String) -> String {
        switch commandName.lowercased() {
        case "help": return "questionmark.circle.fill"
        case "ping": return "antenna.radiowaves.left.and.right"
        case "roll": return "dice.fill"
        case "8ball": return "circle.hexagongrid.fill"
        case "poll": return "chart.bar.fill"
        case "userinfo": return "person.crop.circle.fill"
        case "cluster": return "network"
        case "debug": return "stethoscope"
        case "notifystatus": return "bell.badge.fill"
        case "setchannel": return "gearshape.fill"
        case "ignorechannel": return "speaker.slash.fill"
        case "weekly": return "calendar.badge.clock"
        case "bugreport": return "ant.fill"
        case "logabug": return "doc.text.badge.plus"
        case "featurerequest": return "lightbulb.fill"
        case "image": return "photo.fill"
        case "music": return "music.note"
        case "playlist": return "list.bullet"
        case "miner": return "hammer.fill"
        case "wiki": return "books.vertical.fill"
        case "compare": return "square.split.2x1"
        case "meta": return "crown.fill"
        default: return "command"
        }
    }
}

// MARK: - Command Section

private struct CommandSection: View {
    let category: CommandGroup
    let commands: [VisualCommand]
    let commandEnabledBinding: (VisualCommand) -> Binding<Bool>

    var body: some View {
        SwiftMeshSection(
            title: category.rawValue,
            symbol: category.icon
        ) {
            LazyVStack(spacing: 6) {
                ForEach(commands) { command in
                    CommandRow(
                        command: command,
                        isOn: commandEnabledBinding(command),
                        tint: category.color
                    )
                }
            }
        }
    }
}

// MARK: - Command Row

private struct CommandRow: View {
    let command: VisualCommand
    @Binding var isOn: Bool
    let tint: Color

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: command.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(command.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        ForEach(command.surfaces, id: \.self) { surface in
                            CommandBadge(
                                text: surface,
                                color: surface == "Slash" ? .orange : .secondary
                            )
                        }
                        if command.adminOnly {
                            CommandBadge(text: "Admin", color: .red)
                        }
                    }
                }

                Text(command.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !command.usage.isEmpty {
                    Text(command.usage)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassCard(
            cornerRadius: 12,
            tint: tint.opacity(isHovering ? 0.08 : 0.04),
            stroke: tint.opacity(isHovering ? 0.25 : 0.14)
        )
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.18)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Command Badge

private struct CommandBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(color.opacity(0.28), lineWidth: 1)
            )
    }
}

enum CommandsDashboardSummary {
    @MainActor
    static func metrics(app: AppModel) -> [DashboardMetricDescriptor] {
        let commands = visualCommands(app: app)
        let enabledCount = commands.filter { command in
            isEnabled(command: command, app: app)
        }.count
        let failedToday = app.commandLog.filter { Calendar.current.isDateInToday($0.time) && !$0.ok }.count
        let lastCommand = app.commandLog.first

        return [
            DashboardMetricDescriptor(
                id: "commandsRun",
                title: "Commands Run",
                value: "\(app.stats.commandsRun)",
                subtitle: "this session",
                symbol: "terminal.fill",
                detail: lastCommand.map { "Last \($0.command)" } ?? "No recent commands",
                color: .red
            ),
            DashboardMetricDescriptor(
                id: "commands",
                title: "Commands",
                value: "\(commands.count)",
                subtitle: "\(enabledCount) enabled",
                symbol: "terminal.fill",
                color: .secondary
            ),
            DashboardMetricDescriptor(
                id: "commands-failed-today",
                title: "Failed Today",
                value: "\(failedToday)",
                subtitle: failedToday == 0 ? "No failures" : "Needs review",
                symbol: "xmark.octagon.fill",
                color: failedToday == 0 ? .gray : .red
            ),
            DashboardMetricDescriptor(
                id: "commands-utilities",
                title: "Utilities",
                value: "\(commands.filter { $0.category == .utilities }.count)",
                subtitle: "AI & Tools",
                symbol: "wand.and.stars",
                color: .purple
            ),
            DashboardMetricDescriptor(
                id: "commands-moderation",
                title: "Moderation",
                value: "\(commands.filter { $0.category == .moderation }.count)",
                subtitle: "Admin",
                symbol: "shield.lefthalf.filled",
                color: .orange
            ),
            DashboardMetricDescriptor(
                id: "commands-infra",
                title: "Infra",
                value: "\(commands.filter { $0.category == .infrastructure }.count)",
                subtitle: "Cluster",
                symbol: "server.rack",
                color: .cyan
            )
        ]
    }

    @MainActor
    private static func visualCommands(app: AppModel) -> [VisualCommand] {
        guard app.settings.commandsEnabled else { return [] }

        var commandsByName: [String: VisualCommand] = [:]
        if app.settings.slashCommandsEnabled {
            for raw in app.allSlashCommandDefinitions() {
                guard let name = raw["name"] as? String else { continue }
                let description = (raw["description"] as? String) ?? "No description"
                let options = (raw["options"] as? [[String: Any]]) ?? []
                let usageSuffix = options.compactMap { option in
                    guard let optionName = option["name"] as? String else { return nil }
                    let required = (option["required"] as? Bool) ?? false
                    return required ? " \(optionName):<value>" : " [\(optionName):<value>]"
                }.joined()
                let command = VisualCommand(
                    id: "slash-\(name)",
                    name: name,
                    usage: "/\(name)\(usageSuffix)",
                    description: description,
                    category: group(for: name),
                    surfaces: ["Slash"],
                    aliases: [],
                    adminOnly: name == "debug",
                    icon: icon(for: name)
                )
                commandsByName[name.lowercased()] = command
            }
        }

        commandsByName["bug-mention"] = VisualCommand(
            id: "mention-bug",
            name: "bug",
            usage: "@swiftbot bug (reply to a message)",
            description: "Creates a tracked bug report in #swiftbot-dev and manages status via reactions.",
            category: .moderation,
            surfaces: ["Mention"],
            aliases: [],
            adminOnly: true,
            icon: "ant.fill"
        )

        return commandsByName.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    @MainActor
    private static func isEnabled(command: VisualCommand, app: AppModel) -> Bool {
        if command.id == "mention-bug" {
            return app.settings.bugTrackingEnabled
        }
        return command.surfaces.allSatisfy { surface in
            app.isCommandEnabled(name: command.name, surface: surface.lowercased())
        }
    }

    private static func group(for name: String) -> CommandGroup {
        switch name {
        case "help", "ping", "about":
            return .general
        case "ask", "wiki", "patchy", "sweep":
            return .utilities
        case "ban", "kick", "timeout", "mute", "purge":
            return .moderation
        case "mesh", "status", "debug":
            return .infrastructure
        default:
            return .gaming
        }
    }

    private static func icon(for name: String) -> String {
        switch name {
        case "help": return "questionmark.circle.fill"
        case "ping": return "dot.radiowaves.left.and.right"
        case "ask": return "sparkles"
        case "wiki": return "book.pages.fill"
        case "patchy": return "square.and.arrow.down.badge.checkmark.fill"
        case "sweep": return "rectangle.stack.fill.badge.minus"
        case "mesh": return "point.3.connected.trianglepath.dotted"
        case "debug": return "ladybug.fill"
        default: return "terminal.fill"
        }
    }
}
