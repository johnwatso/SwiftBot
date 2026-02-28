import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: SidebarItem = .overview
    @State private var showToken = false

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationTitle("Discord Bot")
        } detail: {
            switch selection {
            case .overview: OverviewView()
            case .voice: VoiceView()
            case .commands: CommandsView()
            case .logs: LogsView()
            case .settings: SettingsView(showToken: $showToken)
            }
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case voice = "Voice"
    case commands = "Commands"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "rectangle.3.group"
        case .voice: return "person.3.sequence"
        case .commands: return "terminal"
        case .logs: return "doc.plaintext"
        case .settings: return "gearshape"
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    StatusBadge(status: app.status, uptime: app.uptime?.text ?? "--")
                    Spacer()
                    if app.status == .stopped {
                        Button("Start Bot") { Task { await app.startBot() } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Stop Bot") { app.stopBot() }
                            .buttonStyle(.bordered)
                    }
                }

                HStack {
                    StatCard(title: "Commands Run", value: "\(app.stats.commandsRun)")
                    StatCard(title: "Voice Joins", value: "\(app.stats.voiceJoins)")
                    StatCard(title: "Voice Leaves", value: "\(app.stats.voiceLeaves)")
                    StatCard(title: "Errors", value: "\(app.stats.errors)")
                }

                Text("Live Activity")
                    .font(.headline)
                ForEach(app.events) { event in
                    Text("[\(event.timestamp.formatted(date: .omitted, time: .standard))] \(event.message)")
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Active Voice")
                    .font(.headline)
                FlowWrap(app.activeVoice) { member in
                    Text("\(member.username) • \(member.channelName)")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.thinMaterial)
                        .cornerRadius(10)
                }
            }
            .padding()
        }
    }
}

struct VoiceView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Active Voice Channels").font(.headline)
                List(app.activeVoice) { member in
                    Text("\(member.channelName)  •  \(member.username)")
                }
            }
            VStack(alignment: .leading) {
                Text("Voice Event Log").font(.headline)
                List(app.voiceLog) { entry in
                    Text("[\(entry.time.formatted(date: .omitted, time: .standard))] \(entry.description)")
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .padding()
    }
}

struct CommandsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Table(app.commandLog) {
            TableColumn("Time") { Text($0.time.formatted(date: .omitted, time: .standard)) }
            TableColumn("User") { Text($0.user) }
            TableColumn("Command") { Text($0.command) }
            TableColumn("Channel") { Text($0.channel) }
            TableColumn("Status") { entry in
                Text(entry.ok ? "OK" : "ERROR")
                    .foregroundStyle(entry.ok ? .green : .red)
            }
        }
        .padding()
    }
}

struct LogsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Clear") { app.logs.clear() }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.logs.fullLog(), forType: .string)
                }
                Toggle("Auto-scroll", isOn: $app.logs.autoScroll)
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(Array(app.logs.lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.contains("❌") ? .red : (line.contains("⚠️") ? .yellow : .green))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                }
                .onChange(of: app.logs.lines.count) { _, _ in
                    if app.logs.autoScroll, let last = app.logs.lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .padding()
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @Binding var showToken: Bool

    var body: some View {
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
            TextField("Command Prefix", text: $app.settings.prefix)
            Toggle("Auto Start", isOn: $app.settings.autoStart)
            Button("Save") { app.saveSettings() }
                .buttonStyle(.borderedProminent)
            Link("Discord Developer Portal", destination: URL(string: "https://discord.com/developers/applications")!)
        }
        .padding()
    }
}

struct StatusBadge: View {
    let status: BotStatus
    let uptime: String

    var body: some View {
        HStack {
            Circle().fill(status == .running ? .green : .gray).frame(width: 10, height: 10)
            Text("@bot • \(status.rawValue.capitalized) • Uptime: \(uptime)")
                .font(.headline)
        }
        .padding(8)
        .background(.thinMaterial)
        .cornerRadius(12)
    }
}

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold())
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .cornerRadius(12)
    }
}

struct FlowWrap<Data: RandomAccessCollection, Content: View>: View where Data.Element: Identifiable {
    let items: Data
    let content: (Data.Element) -> Content

    init(_ items: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
            ForEach(items) { item in
                content(item)
            }
        }
    }
}
