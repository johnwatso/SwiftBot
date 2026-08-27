import SwiftUI

struct GameTrackerView: View {
    @EnvironmentObject var app: AppModel
    @State private var editorPlayer: GameTrackedPlayer?
    @State private var pendingRemovalID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if app.isFailoverManagedNode {
                    PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. Game Tracker settings sync from Primary.")
                }

                statusRail

                if app.settings.gameTracking.enabled,
                   let issue = app.settings.gameTracking.configurationIssue(connections: app.settings.gameProviders) {
                    configurationBanner(issue)
                }

                trackedPlayersSection

                HStack(alignment: .top, spacing: 16) {
                    schedulePanel
                        .frame(width: 330)
                    recentActivityPanel
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .disabled(app.isFailoverManagedNode)
        .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        .task {
            await app.loadGameTrackingStateForDisplay()
        }
        .sheet(item: $editorPlayer) { player in
            GameTrackedPlayerEditor(
                initialPlayer: player,
                channelOptions: channelOptions,
                onCancel: { editorPlayer = nil },
                onSave: { updated in
                    app.upsertTrackedGamePlayer(updated)
                    editorPlayer = nil
                }
            )
        }
        .confirmationDialog(
            "Remove tracked player?",
            isPresented: Binding(
                get: { pendingRemovalID != nil },
                set: { if !$0 { pendingRemovalID = nil } }
            )
        ) {
            Button("Remove Player", role: .destructive) {
                if let pendingRemovalID {
                    app.removeTrackedGamePlayer(pendingRemovalID)
                }
                pendingRemovalID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemovalID = nil
            }
        } message: {
            Text("The saved baseline for this player will also be removed.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                ViewSectionHeader(title: "Game Tracker", symbol: "gamecontroller.fill")
                HStack(spacing: 6) {
                    Circle()
                        .fill(serviceColor)
                        .frame(width: 7, height: 7)
                    Text(app.gameTrackingStatusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    Task { await app.runGameTrackingCheck() }
                } label: {
                    if app.gameTrackingCheckInProgress {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 80)
                    } else {
                        Label("Check Now", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(GlassActionButtonStyle())
                .disabled(
                    !app.settings.gameTracking.isReady(connections: app.settings.gameProviders)
                        || app.status != .running
                        || app.gameTrackingCheckInProgress
                )

                Toggle("Enabled", isOn: serviceEnabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    private var statusRail: some View {
        LazyVGrid(columns: DashboardMetricGrid.columns, spacing: DashboardMetricGrid.spacing) {
            DashboardMetricCard(
                title: "Tracked Players",
                value: "\(app.settings.gameTracking.players.count)",
                subtitle: "\(activePlayerCount) enabled",
                symbol: "person.2.fill",
                color: .blue
            )
            DashboardMetricCard(
                title: "Game Providers",
                value: "\(configuredProviderCount)/\(GameProviderID.allCases.count)",
                subtitle: providerSubtitle,
                symbol: "point.3.connected.trianglepath.dotted",
                color: configuredProviderCount > 0 ? .green : .orange
            )
            DashboardMetricCard(
                title: "Last Check",
                value: shortTime(app.gameTrackingLastCheckAt),
                subtitle: shortDate(app.gameTrackingLastCheckAt),
                symbol: "checkmark.circle.fill",
                color: .green
            )
            DashboardMetricCard(
                title: "Next Check",
                value: shortTime(app.gameTrackingNextCheckAt),
                subtitle: nextCheckSubtitle,
                symbol: "clock.badge.checkmark.fill",
                color: .purple
            )
        }
    }

    private func configurationBanner(_ issue: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Game Tracker needs attention")
                    .font(.subheadline.weight(.semibold))
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if configuredProviderCount < GameProviderID.allCases.count {
                Text("Settings › Integrations")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .dashboardSurface(cornerRadius: 12, fillOpacity: 0.045, strokeOpacity: 0.09)
    }

    private var trackedPlayersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SettingsSectionHeader(
                    title: "Tracked Players",
                    systemImage: "person.text.rectangle.fill",
                    titleFont: .headline
                )
                Spacer()
                Button {
                    editorPlayer = GameTrackedPlayer()
                } label: {
                    Label("Add Player", systemImage: "plus")
                }
                .buttonStyle(GlassActionButtonStyle())
            }

            if app.settings.gameTracking.players.isEmpty {
                emptyPlayersView
            } else {
                ForEach(trackedGames) { game in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            Image(systemName: game.symbolName)
                                .foregroundStyle(.secondary)
                            Text(game.displayName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text("\(players(for: game).count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 360), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(players(for: game)) { player in
                                playerCard(player)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyPlayersView: some View {
        VStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("No players tracked yet")
                .font(.headline)
            Text("Add a game profile and SwiftBot will establish a silent ranked-score baseline on its first check.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button {
                editorPlayer = GameTrackedPlayer()
            } label: {
                Label("Add First Player", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .dashboardSurface()
    }

    private func playerCard(_ player: GameTrackedPlayer) -> some View {
        let baseline = app.gameTrackingBaselines[player.id]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.red.opacity(0.13))
                        .frame(width: 40, height: 40)
                    Image(systemName: player.game.symbolName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.resolvedDisplayName)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(player.game.displayName)
                        Text("·")
                        Text(player.provider.displayName)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { player.isEnabled },
                    set: { app.setTrackedGamePlayerEnabled(player.id, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

                Menu {
                    Button("Edit", systemImage: "pencil") {
                        editorPlayer = player
                    }
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        pendingRemovalID = player.id
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(baseline.map { $0.score.formatted() } ?? "—")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(baseline == nil ? "Awaiting baseline" : "Ranked Score")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(baseline?.rankName ?? "No rank tier")
                        .font(.subheadline.weight(.semibold))
                    Text(baselineSeasonText(baseline))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "number")
                Text(player.playerID)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "bubble.left.and.bubble.right.fill")
                Text(channelLabel(player.destinationChannelID))
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .dashboardSurface()
    }

    private var schedulePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionHeader(title: "Schedule", systemImage: "calendar.badge.clock", titleFont: .headline)

            HStack {
                Text("Daily Check")
                    .font(.subheadline)
                Spacer()
                Picker("Hour", selection: scheduleHourBinding) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hourLabel(hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }

            Divider()

            LabeledContent("Time Zone") {
                Text(app.settings.gameTracking.timeZoneIdentifier)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.caption)

            Text("A missed check catches up when SwiftBot next starts. First results and new seasons establish silent baselines.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            SettingsSectionHeader(title: "Play Sessions", systemImage: "gamecontroller", titleFont: .headline)

            Toggle("Announce play sessions", isOn: sessionTrackingBinding)
                .font(.subheadline)

            if app.settings.gameTracking.sessionTrackingEnabled {
                LabeledContent("Linked profiles") {
                    Text("\(app.settings.gameTracking.presenceLinkedPlayers.count)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                Text("Detected from Discord rich presence. A session must last at least \(app.settings.gameTracking.sessionMinimumDurationSeconds / 60) minutes, and ends \(app.settings.gameTracking.sessionAbsenceGraceSeconds / 60) minutes after the game disappears so client restarts do not post twice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if app.settings.gameTracking.presenceLinkedPlayers.isEmpty {
                    Label("Add a Discord User ID to a profile to enable this.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(14)
        .dashboardSurface()
    }

    private var recentActivityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(title: "Recent Activity", systemImage: "clock.arrow.circlepath", titleFont: .headline)

            if app.gameTrackingHistory.isEmpty {
                Text("Checks and Discord announcements will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else {
                ForEach(Array(app.gameTrackingHistory.prefix(5))) { entry in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: historySymbol(entry.kind))
                            .foregroundStyle(historyColor(entry.kind))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.title)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(entry.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    if entry.id != app.gameTrackingHistory.prefix(5).last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .dashboardSurface()
    }

    private var serviceEnabledBinding: Binding<Bool> {
        Binding(
            get: { app.settings.gameTracking.enabled },
            set: { enabled in
                app.settings.gameTracking.enabled = enabled
                app.gameTrackingSettingsDidChange()
            }
        )
    }

    private var sessionTrackingBinding: Binding<Bool> {
        Binding(
            get: { app.settings.gameTracking.sessionTrackingEnabled },
            set: { enabled in
                app.settings.gameTracking.sessionTrackingEnabled = enabled
                app.gameTrackingSettingsDidChange()
            }
        )
    }

    private var scheduleHourBinding: Binding<Int> {
        Binding(
            get: { app.settings.gameTracking.checkHour },
            set: { hour in
                app.settings.gameTracking.checkHour = hour
                app.gameTrackingSettingsDidChange()
            }
        )
    }

    private var serviceColor: Color {
        guard app.settings.gameTracking.enabled else { return .gray }
        return app.settings.gameTracking.configurationIssue(connections: app.settings.gameProviders) == nil ? .green : .orange
    }

    private var activePlayerCount: Int {
        app.settings.gameTracking.players.filter(\.isEnabled).count
    }

    private var configuredProviderCount: Int {
        GameProviderID.allCases.filter(isProviderConfigured).count
    }

    private var providerSubtitle: String {
        let ready = GameProviderID.allCases.filter(isProviderConfigured)
        guard !ready.isEmpty else { return "Connection required" }
        return "\(ready.map(\.displayName).sorted().formatted(.list(type: .and))) ready"
    }

    private var trackedGames: [GameID] {
        GameID.allCases.filter { !players(for: $0).isEmpty }
    }

    private func players(for game: GameID) -> [GameTrackedPlayer] {
        app.settings.gameTracking.players.filter { $0.game == game }
    }

    private func isProviderConfigured(_ provider: GameProviderID) -> Bool {
        guard let descriptor = GameProviderCatalog.descriptor(for: provider) else { return false }
        return app.settings.gameProviders[provider].configurationIssue(for: descriptor) == nil
    }

    private var nextCheckSubtitle: String {
        guard let date = app.gameTrackingNextCheckAt else { return "Enable tracking to schedule" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var channelOptions: [GameTrackerChannelOption] {
        app.availableTextChannelsByServer.flatMap { entry -> [GameTrackerChannelOption] in
            let (serverID, channels) = entry
            let serverName = app.connectedServers[serverID] ?? "Unknown Server"
            return channels.map {
                GameTrackerChannelOption(id: $0.id, label: "\(serverName) · #\($0.name)")
            }
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func channelLabel(_ channelID: String) -> String {
        channelOptions.first(where: { $0.id == channelID })?.label ?? "Channel unavailable"
    }

    private func baselineSeasonText(_ baseline: GameRankBaseline?) -> String {
        guard let baseline else { return "First check is silent" }
        return baseline.season.isEmpty ? "Season unavailable" : baseline.season.uppercased()
    }

    private func shortTime(_ date: Date?) -> String {
        date?.formatted(date: .omitted, time: .shortened) ?? "—"
    }

    private func shortDate(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .omitted) ?? "No completed checks"
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else { return "\(hour):00" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func historySymbol(_ kind: GameTrackingHistoryKind) -> String {
        switch kind {
        case .check: return "checkmark.circle.fill"
        case .announcement: return "paperplane.circle.fill"
        case .seasonReset: return "arrow.triangle.2.circlepath.circle.fill"
        case .sessionStarted: return "play.circle.fill"
        case .sessionEnded: return "stop.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func historyColor(_ kind: GameTrackingHistoryKind) -> Color {
        switch kind {
        case .check: return .green
        case .announcement: return .blue
        case .seasonReset: return .purple
        case .sessionStarted: return .teal
        case .sessionEnded: return .indigo
        case .error: return .orange
        }
    }
}

struct GameTrackerChannelOption: Identifiable, Hashable {
    let id: String
    let label: String
}

private struct GameTrackedPlayerEditor: View {
    @State private var player: GameTrackedPlayer
    let channelOptions: [GameTrackerChannelOption]
    let onCancel: () -> Void
    let onSave: (GameTrackedPlayer) -> Void

    init(
        initialPlayer: GameTrackedPlayer,
        channelOptions: [GameTrackerChannelOption],
        onCancel: @escaping () -> Void,
        onSave: @escaping (GameTrackedPlayer) -> Void
    ) {
        _player = State(initialValue: initialPlayer)
        self.channelOptions = channelOptions
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.playerID.isEmpty ? "Add Player" : "Edit Player")
                        .font(.title2.weight(.semibold))
                    Text("Choose a game profile and where ranked updates should be posted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("Profile") {
                    Picker("Game", selection: $player.game) {
                        ForEach(GameID.allCases) { game in
                            Label(game.displayName, systemImage: game.symbolName).tag(game)
                        }
                    }

                    Picker("Data Provider", selection: $player.provider) {
                        ForEach(availableProviders) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    TextField("Display Name", text: $player.displayName)
                    TextField("Provider Player ID", text: $player.playerID)
                }

                Section("Play Sessions") {
                    TextField("Discord User ID", text: $player.discordUserID)
                    Text("Optional. Links this profile to a Discord account so SwiftBot can detect play sessions from rich presence and post a summary when the session ends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Announcements") {
                    Picker("Discord Channel", selection: $player.destinationChannelID) {
                        Text("Select channel").tag("")
                        ForEach(channelOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    Toggle("Track this player", isOn: $player.isEnabled)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Player") {
                    onSave(player)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
        .onChange(of: player.game) { _, game in
            if !player.provider.supportedGames.contains(game) {
                player.provider = availableProviders.first ?? .finalsID
            }
        }
    }

    private var availableProviders: [GameProviderID] {
        GameProviderID.allCases.filter { $0.supportedGames.contains(player.game) }
    }

    private var isValid: Bool {
        !player.playerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !player.destinationChannelID.isEmpty
            && player.provider.supportedGames.contains(player.game)
    }
}
