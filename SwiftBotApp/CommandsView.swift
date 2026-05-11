import SwiftUI

struct CommandsView: View {
    @EnvironmentObject var app: AppModel
    @State private var showSettingsUpdatedToast = false
    @State private var settingsToastTask: Task<Void, Never>?

    private struct VisualCommand: Identifiable {
        let id: String
        let name: String
        let usage: String
        let description: String
        let category: String
        let surfaces: [String]
        let aliases: [String]
        let adminOnly: Bool
    }

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
                category: "Slash",
                surfaces: ["Slash"],
                aliases: [],
                adminOnly: name == "debug"
            )
        }
    }

    private func commandEnabledBinding(for command: VisualCommand) -> Binding<Bool> {
        if command.id == "mention-bug" {
            return Binding(
                get: { app.settings.bugTrackingEnabled },
                set: { app.settings.bugTrackingEnabled = $0 }
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
            }
        )
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
                        adminOnly: existing.adminOnly || command.adminOnly
                    )
                    commandsByName[key] = existing
                } else {
                    commandsByName[key] = command
                }
            }
        }
        commandsByName["bug-mention"] = (
            VisualCommand(
                id: "mention-bug",
                name: "bug",
                usage: "@swiftbot bug (reply to a message)",
                description: "Creates a tracked bug report in #swiftbot-dev and manages status via reactions.",
                category: "Server",
                surfaces: ["Mention"],
                aliases: [],
                adminOnly: true
            )
        )

        return commandsByName.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewSectionHeader(title: "Commands", symbol: "terminal.fill")
            if app.isFailoverManagedNode {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                    Text("Read-only on Failover nodes. Command settings sync from Primary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Command System")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        compactToggleCard(
                            title: "All",
                            subtitle: "Master switch",
                            icon: "switch.2",
                            isOn: $app.settings.commandsEnabled
                        )
                        compactToggleCard(
                            title: "Slash",
                            subtitle: "Discord UI",
                            icon: "command",
                            isOn: $app.settings.slashCommandsEnabled,
                            disabled: !app.settings.commandsEnabled
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Command Catalog")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if allVisualCommands.isEmpty {
                        VStack {
                            Spacer(minLength: 0)
                            VStack(spacing: 6) {
                                Text("No Commands Available")
                                    .font(.headline)
                                Text("Commands will appear here once the bot registers them.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.center)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 13) {
                                ForEach(allVisualCommands) { command in
                                    HStack(alignment: .center, spacing: 16) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack(spacing: 8) {
                                                Text(command.name)
                                                    .font(.body.weight(.semibold))
                                                ForEach(command.surfaces, id: \.self) { surface in
                                                    CommandTag(text: surface, tint: surface == "Slash" ? .orange : .secondary)
                                                }
                                                if !command.surfaces.contains(where: { $0.caseInsensitiveCompare(command.category) == .orderedSame }) {
                                                    CommandTag(text: command.category, tint: .secondary)
                                                }
                                                if command.adminOnly {
                                                    CommandTag(text: "Admin", tint: .red)
                                                }
                                            }

                                            Text(command.usage)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)

                                            Text(command.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)

                                            if !command.aliases.isEmpty {
                                                Text("Aliases: " + command.aliases.joined(separator: ", "))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        Toggle("Enabled", isOn: commandEnabledBinding(for: command))
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                            .frame(maxHeight: .infinity, alignment: .center)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 14)
                                    .padding(.trailing, 22)
                                    .padding(.vertical, 10)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    @ViewBuilder
    private func compactToggleCard(
        title: String,
        subtitle: String,
        icon: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(disabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct CommandTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(.primary)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
    }
}

