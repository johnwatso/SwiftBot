import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: SidebarItem = .overview
    @State private var showToken = false

    var body: some View {
        NavigationSplitView {
            DashboardSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 280)
        } detail: {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color.accentColor.opacity(0.10),
                        Color(nsColor: .windowBackgroundColor)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                switch selection {
                case .overview: OverviewView()
                case .voice: VoiceView()
                case .commands: CommandsView()
                case .logs: LogsView()
                case .settings: SettingsView(showToken: $showToken)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct DashboardSidebar: View {
    @EnvironmentObject var app: AppModel
    @Binding var selection: SidebarItem

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 56, height: 56)
                    Image(systemName: "cpu.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }

                VStack(spacing: 2) {
                    Text("OnlineBot")
                        .font(.headline)
                    Text("Native Assistant")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            List(selection: $selection) {
                Section("Main") {
                    SidebarRow(item: .overview, selection: $selection)
                    SidebarRow(item: .voice, selection: $selection, count: app.activeVoice.count)
                    SidebarRow(item: .commands, selection: $selection)
                    SidebarRow(item: .logs, selection: $selection)
                }

                Section("Config") {
                    SidebarRow(item: .settings, selection: $selection)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Group {
                if app.status == .stopped {
                    Button {
                        Task { await app.startBot() }
                    } label: {
                        Label("Start Bot", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        app.stopBot()
                    } label: {
                        Label("Stop Bot", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .controlSize(.large)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}

struct SidebarRow: View {
    let item: SidebarItem
    @Binding var selection: SidebarItem
    var count: Int?

    var body: some View {
        Button {
            selection = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .frame(width: 16)
                Text(item.rawValue)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.20), in: Capsule())
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tag(item)
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case voice = "Voice Activity"
    case commands = "Commands"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .voice: return "person.3.sequence.fill"
        case .commands: return "terminal.fill"
        case .logs: return "list.bullet.clipboard.fill"
        case .settings: return "gearshape.2.fill"
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject var app: AppModel

    private var recentVoice: [VoiceEventLogEntry] {
        Array(app.voiceLog.prefix(5))
    }

    private var recentCommands: [CommandLogEntry] {
        Array(app.commandLog.prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Overview")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                    }

                    Spacer()
                }

                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 180), spacing: 12)
                ], spacing: 12) {
                    DashboardMetricCard(
                        title: "Status",
                        value: app.status.rawValue.capitalized,
                        subtitle: app.uptime?.text ?? "--",
                        color: .green
                    )
                    DashboardMetricCard(
                        title: "Servers",
                        value: "\(app.connectedServers.count)",
                        subtitle: "servers connected",
                        color: .blue
                    )
                    DashboardMetricCard(
                        title: "In Voice",
                        value: "\(app.activeVoice.count)",
                        subtitle: "users right now",
                        color: .orange
                    )
                    DashboardMetricCard(
                        title: "Commands Run",
                        value: "\(app.stats.commandsRun)",
                        subtitle: "this session",
                        color: .red
                    )
                }

                HStack(spacing: 12) {
                    DashboardPanel(title: "Recent Voice Events", actionTitle: "View") {
                        if recentVoice.isEmpty {
                            PlaceholderPanelLine(text: "No voice events yet")
                        } else {
                            ForEach(recentVoice) { entry in
                                PanelLine(
                                    title: entry.description,
                                    subtitle: entry.time.formatted(date: .omitted, time: .standard),
                                    tone: .green
                                )
                            }
                        }
                    }

                    DashboardPanel(title: "Recent Commands", actionTitle: "View") {
                        if recentCommands.isEmpty {
                            PlaceholderPanelLine(text: "No commands yet")
                        } else {
                            ForEach(recentCommands) { entry in
                                PanelLine(
                                    title: "\(entry.user) @ \(entry.server) • \(entry.command)",
                                    subtitle: entry.time.formatted(date: .omitted, time: .standard),
                                    tone: entry.ok ? .accentColor : .red
                                )
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    DashboardPanel(title: "Currently In Voice") {
                        if app.activeVoice.isEmpty {
                            PlaceholderPanelLine(text: "No one is in voice right now")
                        } else {
                            ForEach(app.activeVoice) { member in
                                PanelLine(
                                    title: "\(member.username) in \(member.channelName)",
                                    subtitle: member.joinedAt.formatted(date: .omitted, time: .shortened),
                                    tone: .indigo
                                )
                            }
                        }
                    }

                    DashboardPanel(title: "Bot Info") {
                        InfoRow(label: "Uptime", value: app.uptime?.text ?? "--")
                        InfoRow(label: "Prefix", value: app.settings.prefix)
                        InfoRow(label: "Errors", value: "\(app.stats.errors)")
                        InfoRow(label: "State", value: app.status.rawValue.capitalized)
                    }
                }
            }
            .padding(20)
        }
    }
}

struct VoiceView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Voice Activity")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                HStack(spacing: 12) {
                    DashboardPanel(title: "Active Voice Channels") {
                        if app.activeVoice.isEmpty {
                            PlaceholderPanelLine(text: "No active members")
                        } else {
                            ForEach(app.activeVoice) { member in
                                PanelLine(
                                    title: "\(member.channelName) • \(member.username)",
                                    subtitle: member.joinedAt.formatted(date: .omitted, time: .shortened),
                                    tone: .blue
                                )
                            }
                        }
                    }

                    DashboardPanel(title: "Voice Event Log") {
                        if app.voiceLog.isEmpty {
                            PlaceholderPanelLine(text: "No voice events logged")
                        } else {
                            ForEach(Array(app.voiceLog.prefix(15))) { entry in
                                PanelLine(
                                    title: entry.description,
                                    subtitle: entry.time.formatted(date: .omitted, time: .standard),
                                    tone: .secondary
                                )
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct CommandsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commands")
                .font(.system(size: 30, weight: .bold, design: .rounded))

            Table(app.commandLog) {
                TableColumn("Time") { Text($0.time.formatted(date: .omitted, time: .standard)) }
                TableColumn("User") { Text($0.user) }
                TableColumn("Server") { Text($0.server) }
                TableColumn("Command") { Text($0.command) }
                TableColumn("Channel") { Text($0.channel) }
                TableColumn("Status") { entry in
                    Text(entry.ok ? "OK" : "ERROR")
                        .foregroundStyle(entry.ok ? .green : .red)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
        .padding(20)
    }
}

struct LogsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Logs")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Spacer()
                Button("Clear") { app.logs.clear() }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.logs.fullLog(), forType: .string)
                }
                Toggle("Auto-scroll", isOn: $app.logs.autoScroll)
                    .toggleStyle(.switch)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(app.logs.lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.contains("❌") ? .red : (line.contains("⚠️") ? .yellow : .green))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(12)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .onChange(of: app.logs.lines.count) { _ in
                    if app.logs.autoScroll, let last = app.logs.lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .padding(20)
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @Binding var showToken: Bool
    @State private var prefixDraft = "!"
    @State private var notificationChannelDrafts: [String: String] = [:]
    @State private var ignoredChannelDrafts: [String: String] = [:]

    private let allowedPrefixes = ["$", "#", "!", "?", "%"]

    private var editableServerIds: [String] {
        let ids = Set(app.connectedServers.keys).union(app.settings.guildSettings.keys)
        return ids.sorted { lhs, rhs in
            serverName(for: lhs).localizedCaseInsensitiveCompare(serverName(for: rhs)) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.system(size: 30, weight: .bold, design: .rounded))

            Form {
                HStack {
                    Group {
                        if showToken {
                            TextField("Bot Token", text: $app.settings.token)
                        } else {
                            SecureField("Bot Token", text: $app.settings.token)
                        }
                    }
                    Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                }

                Picker("Command Prefix", selection: $prefixDraft) {
                    ForEach(allowedPrefixes, id: \.self) { prefix in
                        Text(prefix).tag(prefix)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Auto Start", isOn: $app.settings.autoStart)

                Section("Server Notifications") {
                    if editableServerIds.isEmpty {
                        Text("Connect the bot to a server to configure voice notifications here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(editableServerIds, id: \.self) { serverId in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(serverName(for: serverId)) (\(serverId))")
                                    .font(.subheadline.weight(.semibold))

                                TextField(
                                    "Notification Channel ID",
                                    text: Binding(
                                        get: { notificationChannelDrafts[serverId, default: ""] },
                                        set: { notificationChannelDrafts[serverId] = $0 }
                                    )
                                )

                                TextField(
                                    "Ignored Voice Channel IDs (comma separated)",
                                    text: Binding(
                                        get: { ignoredChannelDrafts[serverId, default: ""] },
                                        set: { ignoredChannelDrafts[serverId] = $0 }
                                    )
                                )
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Button("Save") {
                    app.settings.prefix = prefixDraft
                    applyServerDraftsToSettings()
                    app.saveSettings()
                    prefixDraft = app.settings.prefix
                }
                .buttonStyle(.borderedProminent)

                Link("Discord Developer Portal", destination: URL(string: "https://discord.com/developers/applications")!)
            }
            .onAppear {
                prefixDraft = allowedPrefixes.contains(app.settings.prefix) ? app.settings.prefix : "!"
                refreshServerDrafts()
            }
            .onChange(of: app.settings.prefix) { newValue in
                prefixDraft = allowedPrefixes.contains(newValue) ? newValue : "!"
            }
            .onChange(of: app.connectedServers.count) { _ in
                refreshServerDrafts()
            }
            .onChange(of: app.settings.guildSettings.count) { _ in
                refreshServerDrafts()
            }
            .formStyle(.grouped)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
    }

    private func serverName(for serverId: String) -> String {
        app.connectedServers[serverId] ?? "Server \(serverId.suffix(4))"
    }

    private func refreshServerDrafts() {
        for serverId in editableServerIds {
            let guildSettings = app.settings.guildSettings[serverId] ?? GuildSettings()
            notificationChannelDrafts[serverId] = guildSettings.notificationChannelId ?? ""
            ignoredChannelDrafts[serverId] = guildSettings.ignoredVoiceChannelIds.sorted().joined(separator: ",")
        }
    }

    private func applyServerDraftsToSettings() {
        for serverId in editableServerIds {
            var guildSettings = app.settings.guildSettings[serverId] ?? GuildSettings()

            let notification = notificationChannelDrafts[serverId, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            guildSettings.notificationChannelId = notification.isEmpty ? nil : notification

            let ignoredRaw = ignoredChannelDrafts[serverId, default: ""]
            let ignoredIds = ignoredRaw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap(parseChannelId)
            guildSettings.ignoredVoiceChannelIds = Set(ignoredIds)

            app.settings.guildSettings[serverId] = guildSettings
        }
    }

    private func parseChannelId(_ text: String) -> String? {
        if text.hasPrefix("<#") && text.hasSuffix(">") {
            return String(text.dropFirst(2).dropLast())
        }
        return text.allSatisfy(\.isNumber) ? text : nil
    }
}

struct StatusPill: View {
    let status: BotStatus

    private var color: Color {
        switch status {
        case .running: return .green
        case .connecting: return .orange
        case .reconnecting: return .yellow
        case .stopped: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(status.rawValue.capitalized)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        )
    }
}

struct DashboardMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(color.opacity(0.85), lineWidth: 1.5)
        )
    }
}

struct DashboardPanel<Content: View>: View {
    let title: String
    var actionTitle: String?
    @ViewBuilder let content: Content

    init(title: String, actionTitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.actionTitle = actionTitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let actionTitle {
                    Button(actionTitle) {}
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

struct PanelLine: View {
    let title: String
    let subtitle: String
    let tone: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct PlaceholderPanelLine: View {
    let text: String

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .padding(.vertical, 4)
    }
}
