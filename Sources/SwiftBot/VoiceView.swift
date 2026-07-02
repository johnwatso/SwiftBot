import AVFoundation
import SwiftUI

struct VoiceView: View {
    @EnvironmentObject var app: AppModel

    @State private var selectedVoiceIdentifier: String = ""
    @State private var showingVoiceDownloadHelp: Bool = false
    @State private var vcConfigs: [AnnouncerVoiceChannelConfig] = []
    @State private var vcBehaviours: [String: AnnouncerBehaviourState] = [:]
    @State private var editingVCConfigIndex: Int?
    @State private var applyingSettingsSnapshot: Bool = false
    @State private var voiceConfigCommitTask: Task<Void, Never>?
    @State private var cachedVoiceOptions: [PickerOption] = [PickerOption(id: "", label: "Recommended: Piper / Premium (auto)")]
    @State private var autoVoiceDisplayName: String = "Auto"

    private let metricColumns = [
        GridItem(.flexible(minimum: 180), spacing: 16),
        GridItem(.flexible(minimum: 180), spacing: 16),
        GridItem(.flexible(minimum: 180), spacing: 16),
        GridItem(.flexible(minimum: 180), spacing: 16)
    ]
    private let voicePanelMinHeight: CGFloat = 176
    private let statePanelMinHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            contentContainer {
                header
            }
            .padding(.top, 12)

            if app.forwardsConfigEditsToPrimary {
                contentContainer {
                    PreferencesSyncsToPrimaryBanner(text: "Editing as Failover — changes are pushed to the Primary and sync back.")
                }
            } else if app.isFailoverManagedNode {
                contentContainer {
                    PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. Announcer settings sync from Primary.")
                }
            }

            ScrollView {
                contentContainer {
                    VStack(alignment: .leading, spacing: 16) {
                        metricTileRow
                        voiceChannelConfigurationsSection
                        announcerDetailGrid
                    }
                }
                .padding(.bottom, 16)
                .padding(.top, 16)
            }
            .fadingEdges(top: 16, bottom: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(app.isFailoverManagedNode && !app.forwardsConfigEditsToPrimary)
        .opacity(app.isFailoverManagedNode && !app.forwardsConfigEditsToPrimary ? 0.62 : 1)
        .meshConfigMutationErrorAlert()
        .onAppear {
            syncFromSettings()
            refreshVoiceOptions()
        }
        .onDisappear { flushVoiceConfigCommit() }
        .onChange(of: app.settings.voice) { _, _ in
            if editingVCConfigIndex == nil, voiceConfigCommitTask == nil {
                syncFromSettings()
            } else {
                selectedVoiceIdentifier = app.settings.voice.preferredVoiceIdentifier
            }
        }
        .onChange(of: vcConfigs) { _, newValue in
            guard !applyingSettingsSnapshot else { return }
            scheduleVoiceConfigCommit(newValue)
        }
        .sheet(isPresented: Binding(
            get: { editingVCConfigIndex != nil },
            set: {
                if !$0 {
                    flushVoiceConfigCommit()
                    editingVCConfigIndex = nil
                }
            }
        )) {
            if let index = editingVCConfigIndex {
                AnnouncerConfigSheet(config: $vcConfigs[index], state: behaviourBinding(for: vcConfigs[index].id))
                    .environmentObject(app)
            }
        }
    }

    private var announcerDetailGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                globalVoiceSettingsSection
                announcementPreviewSection
            }

            HStack(alignment: .top, spacing: 16) {
                currentStateSection
                recentActivitySection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func contentContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                ViewSectionHeader(title: "Announcer", symbol: "speaker.wave.2.bubble.fill")
                Text("Context-aware spoken Discord feeds")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            connectionStatusControl
        }
    }

    private var statusColor: Color {
        switch app.voiceConnectionStatus {
        case .connected: return .green
        case .connecting, .recovering, .disconnecting: return .yellow
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var connectionStatusLabel: String {
        switch app.voiceConnectionStatus {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .recovering: return "Recovering"
        case .disconnecting: return "Disconnecting"
        case .idle, .failed: return "Disconnected"
        }
    }

    private var connectionStatusControl: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(connectionStatusLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .help(connectionDetailText)

            Button {
                Task {
                    if app.voiceConnectionStatus.isConnected {
                        await app.disconnectVoice()
                    } else {
                        await app.reconnectAnnouncerVoiceFromUI()
                    }
                }
            } label: {
                Label(
                    app.voiceConnectionStatus.isConnected ? "Disconnect" : "Reconnect",
                    systemImage: app.voiceConnectionStatus.isConnected ? "phone.down.fill" : "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(connectionActionDisabled)
            .help(connectionDetailText)

            Menu {
                Button {
                    Task { await app.reconnectAnnouncerVoiceFromUI() }
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await app.disconnectVoice() }
                } label: {
                    Label("Disconnect", systemImage: "phone.down.fill")
                }
                .disabled(app.voiceConnectionStatus == .idle)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .help("More connection actions")
        }
    }

    private var connectionActionDisabled: Bool {
        if app.voiceConnectionStatus.isConnected { return false }
        return app.status != .running || activeAnnouncerConfig == nil
    }

    private var connectionDetailText: String {
        if app.voiceConnectionStatus.isConnected {
            return liveSessionText
        }
        if app.status != .running {
            return "Start the bot before reconnecting Announcer."
        }
        if activeAnnouncerConfig == nil && vcConfigs.first(where: \.enabled) == nil {
            return "Add an enabled voice channel configuration to start listening."
        }
        return "Ready to reconnect to the configured voice channel."
    }

    private var liveSessionText: String {
        let channel = textChannelDisplayName(for: app.settings.voice.watchedTextChannelID).ifEmpty("general")
        let guild = app.connectedServers[app.settings.voice.guildID] ?? "AO"
        return "Reading #\(channel) in \(guild)"
    }

    // MARK: - Metrics

    private var metricTileRow: some View {
        LazyVGrid(columns: metricColumns, spacing: 16) {
            DashboardMetricCard(
                title: "Active Sessions",
                value: app.voiceConnectionStatus.canQueueAnnouncements ? "1" : "0",
                subtitle: app.voiceConnectionStatus.canQueueAnnouncements ? liveSessionText : "Ready for /announce",
                symbol: "waveform.badge.mic",
                color: statusColor
            )
            DashboardMetricCard(
                title: "Configured Voice Channels",
                value: "\(enabledConfigCount)",
                subtitle: vcConfigs.count == enabledConfigCount ? "Feeds ready for /announce join" : "\(vcConfigs.count) total configurations",
                symbol: "speaker.wave.2.bubble.fill",
                color: .purple
            )
            DashboardMetricCard(
                title: "Announcements Today",
                value: "\(app.messagesSpokenToday)",
                subtitle: app.messagesSpokenToday == 0 ? "No reads yet today" : "Announcements + previews",
                symbol: "text.bubble.fill",
                color: .blue
            )
            DashboardMetricCard(
                title: "Current Voice Channel",
                value: currentVoiceChannelMetricValue,
                subtitle: currentVoiceChannelMetricSubtitle,
                symbol: "megaphone.fill",
                color: .pink
            )
        }
    }

    // MARK: - Voice channel configurations

    private var voiceChannelConfigurationsSection: some View {
        AutomationsSection(title: "Voice Channel Configurations", symbol: "speaker.wave.2.bubble.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text("SwiftBot detects your current voice channel and loads that channel's configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if vcConfigs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No voice channel configurations yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button { addVoiceChannel() } label: {
                            Label("Add Voice Channel", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(spacing: 4) {
                        ForEach(vcConfigs) { config in
                            voiceChannelConfigCard(config)
                        }
                    }
                    Button { addVoiceChannel() } label: {
                        Label("Add Voice Channel", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func voiceChannelConfigCard(_ config: AnnouncerVoiceChannelConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(config.enabled ? config.tint.color : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: config.symbol)
                            .font(.subheadline.weight(.semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(config.tint.color)

                        Text(config.name)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)

                        if memberCount(for: config) > 0 {
                            Label("\(memberCount(for: config)) members", systemImage: "person.2.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Feeds")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            AnnouncerChipFlow(spacing: 6, rowSpacing: 5) {
                                ForEach(feedLabels(for: config).prefix(4), id: \.self) { feed in
                                    channelChip(feed, color: config.tint.color)
                                }
                                if feedLabels(for: config).count > 4 {
                                    countChip("+\(feedLabels(for: config).count - 4)")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Behaviour")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            AnnouncerChipFlow(spacing: 8, rowSpacing: 5) {
                                ForEach(behaviourFlags(for: config).prefix(5), id: \.self) { flag in
                                    behaviourChip(flag)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    Text("Status")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    configStatusBadge(config)
                }

                Toggle("", isOn: Binding(
                    get: { config.enabled },
                    set: { newValue in
                        if let i = vcConfigs.firstIndex(where: { $0.id == config.id }) {
                            vcConfigs[i].enabled = newValue
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.top, 18)

                Divider()
                    .frame(height: 38)
                    .padding(.top, 8)

                HStack(spacing: 8) {
                    Button {
                        app.speakLocallyPreview(previewText(for: config))
                    } label: {
                        Label("Preview", systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button { openConfig(for: config) } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Menu {
                        Button {
                            app.speakLocallyPreview(previewText(for: config))
                        } label: {
                            Label("Preview Announcement", systemImage: "play.circle")
                        }
                        Button { openConfig(for: config) } label: {
                            Label("Edit Configuration", systemImage: "pencil")
                        }
                        Divider()
                        Button(config.enabled ? "Disable" : "Enable") {
                            if let i = vcConfigs.firstIndex(where: { $0.id == config.id }) {
                                vcConfigs[i].enabled.toggle()
                            }
                        }
                        Button("Remove", role: .destructive) {
                            vcConfigs.removeAll { $0.id == config.id }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .controlSize(.small)
                }
                .padding(.top, 12)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Announcement voice

    private var globalVoiceSettingsSection: some View {
        AutomationsSection(title: "Announcement Voice", symbol: "speaker.wave.3.fill", minHeight: voicePanelMinHeight) {
            VStack(alignment: .leading, spacing: 12) {
                voiceSettingsPanel

                Text("Automatically selects the best available voice. Ryan Piper is used when available, otherwise SwiftBot chooses the best installed English voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer(minLength: 0)
                    Button {
                        app.speakLocallyPreview("SwiftBot will read Discord messages using \(preferredVoiceDisplayName).")
                    } label: {
                        Label("Hear Voice", systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var announcementPreviewSection: some View {
        AutomationsSection(title: "Announcement Preview", symbol: "play.fill", minHeight: voicePanelMinHeight) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.purple.opacity(0.14))
                        VoiceWaveformMark(color: .purple)
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(announcementPreviewText)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Preview uses the selected announcement voice.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.025))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                HStack {
                    Button {
                        Task { await app.speakAnnouncement(announcementPreviewText) }
                    } label: {
                        Label("Test Announcement", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!app.voiceConnectionStatus.isConnected)

                    Spacer()

                    Button {
                        app.speakLocallyPreview(announcementPreviewText)
                    } label: {
                        Label("Listen", systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var currentStateSection: some View {
        AutomationsSection(title: "Current State", symbol: "circle.fill", minHeight: statePanelMinHeight) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.voiceConnectionStatus.isConnected ? "Connected" : "Disconnected")
                            .font(.headline.weight(.semibold))
                        Text(app.announcerHealth.phase.displayLabel)
                            .font(.caption)
                            .foregroundStyle(announcerHealthColor)
                    }
                    Spacer()
                }

                VStack(spacing: 8) {
                    currentStateRow(symbol: "speaker.wave.2.fill", label: "Listening", value: listeningStateText)
                    currentStateRow(symbol: "text.bubble.fill", label: "Monitored feeds", value: monitoredFeedsText)
                    currentStateRow(symbol: "tray.full.fill", label: "Next announcement", value: queueStateText)
                }

                HStack {
                    Button {
                        app.speakLocallyPreview(queueStateText)
                    } label: {
                        Label("Preview Queue", systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(app.announcerHealth.queueDepth == 0)

                    Spacer()

                    queueSummaryBadge
                }
            }
        }
    }

    private func currentStateRow(symbol: String, label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var queueSummaryBadge: some View {
        Text(app.announcerHealth.queueDepth == 0 ? "Queue clear" : "\(app.announcerHealth.queueDepth) queued")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(app.announcerHealth.queueDepth == 0 ? Color.secondary : Color.purple)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(app.announcerHealth.queueDepth == 0 ? Color.primary.opacity(0.05) : Color.purple.opacity(0.12))
            )
    }

    private var announcerHealthColor: Color {
        switch app.announcerHealth.phase {
        case .idle: return .secondary
        case .queued, .rendering, .sending: return .blue
        case .paused, .recovering: return .yellow
        case .failed: return .red
        }
    }

    private var recentActivitySection: some View {
        AutomationsSection(title: "Recent Activity", symbol: "text.bubble", minHeight: statePanelMinHeight) {
            VStack(alignment: .leading, spacing: 8) {
                if app.voiceLog.isEmpty {
                    PlaceholderPanelLine(text: "Spoken announcements and voice connection events will appear here.")
                } else {
                    ForEach(Array(app.voiceLog.prefix(8))) { entry in
                        recentActivityRow(entry)
                    }
                }
            }
        }
    }

    private func recentActivityRow(_ entry: VoiceEventLogEntry) -> some View {
        let kind = activityKind(for: entry.description)
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: kind.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(kind.color)
                .frame(width: 16)
            Text(entry.time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .leading)
            Text(kind.label)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(kind.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(kind.color.opacity(0.10), in: Capsule())
            Text(humanReadableLog(entry.description))
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func humanReadableLog(_ raw: String) -> String {
        let lower = raw.lowercased()
        if raw.hasPrefix("JOIN ") {
            return raw.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if raw.hasPrefix("LEAVE ") {
            return raw.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if lower.contains("queued discord speech") {
            return "Announcement queued"
        }
        if lower.contains("finished discord speech") {
            return "Announcement spoken"
        }
        if lower.contains("manual announcer voice reconnect") {
            return "Reconnect requested"
        }
        if lower.contains("voice websocket pipeline starting") {
            return "Voice connection starting"
        }
        if lower.contains("voice connection lost") {
            return "Voice connection needs recovery"
        }
        if lower.contains("disconnect") || lower.contains("left") {
            return "Left voice channel"
        }
        if lower.contains("connect") {
            return "Voice connection updated"
        }
        return "Voice status updated"
    }

    private func activityKind(for raw: String) -> AnnouncerActivityKind {
        let lower = raw.lowercased()
        if raw.hasPrefix("JOIN ") || lower.contains(" joined ") {
            return AnnouncerActivityKind(label: "JOIN", symbol: "person.fill.badge.plus", color: .green)
        }
        if raw.hasPrefix("LEAVE ") || lower.contains("disconnect") || lower.contains(" left ") {
            return AnnouncerActivityKind(label: "LEAVE", symbol: "person.fill.badge.minus", color: .red)
        }
        if lower.contains("speech") || lower.contains("announcement") || lower.contains("queued") {
            return AnnouncerActivityKind(label: "ANNOUNCEMENT", symbol: "speaker.wave.2.fill", color: .purple)
        }
        return AnnouncerActivityKind(label: "STATUS", symbol: "circle.dashed", color: .secondary)
    }

    private var enabledConfigCount: Int {
        vcConfigs.filter(\.enabled).count
    }

    private var activeAnnouncerConfig: AnnouncerVoiceChannelConfig? {
        if !app.settings.voice.voiceChannelID.isEmpty,
           let match = vcConfigs.first(where: { $0.voiceChannelID == app.settings.voice.voiceChannelID }) {
            return match
        }
        return vcConfigs.first(where: \.enabled) ?? vcConfigs.first
    }

    private var currentVoiceChannelMetricValue: String {
        if let config = activeAnnouncerConfig,
           !config.voiceChannelName.isEmpty,
           config.voiceChannelName != "—" {
            return config.voiceChannelName
        }
        let fallback = voiceChannelDisplayName(for: app.settings.voice.voiceChannelID)
        return fallback.isEmpty ? "None" : fallback
    }

    private var currentVoiceChannelMetricSubtitle: String {
        if app.voiceConnectionStatus.isConnected {
            return "Connected · \(memberCount(for: activeAnnouncerConfig)) members"
        }
        if activeAnnouncerConfig == nil {
            return "No voice channel selected"
        }
        return "Ready to connect"
    }

    private func memberCount(for config: AnnouncerVoiceChannelConfig?) -> Int {
        guard let config else { return 0 }
        return app.activeVoice.filter { $0.channelId == config.voiceChannelID }.count
    }

    private func feedLabels(for config: AnnouncerVoiceChannelConfig) -> [String] {
        var labels = config.textChannels.map { "#\($0)" }
        if config.readVoiceChannelChat {
            let name = config.voiceChannelName == "—" ? "voice chat" : config.voiceChannelName
            labels.insert("#\(name)", at: 0)
        }
        return labels.isEmpty ? ["No feeds"] : labels
    }

    private func behaviourFlags(for config: AnnouncerVoiceChannelConfig) -> [String] {
        var flags: [String] = []
        if config.autoJoin { flags.append("Auto join") }
        if config.autoJoinOnStream { flags.append("Stream join") }
        if config.introduceOnManualJoin || config.introduceOnStreamJoin { flags.append("Intro message") }
        switch config.connectionMode {
        case .fixed: flags.append("\(config.connectionMinutes) min")
        case .untilEmpty: flags.append("Until empty")
        }
        if config.keepShort { flags.append("Keep short") }
        if config.smartShortenWithAppleIntelligence { flags.append("AI shorten") }
        if config.ignoreLinks { flags.append("No links") }
        if config.skipBots { flags.append("Skip bots") }
        return flags.isEmpty ? ["Manual"] : flags
    }

    private func configStatusBadge(_ config: AnnouncerVoiceChannelConfig) -> some View {
        let isActive = app.voiceConnectionStatus.isConnected && app.settings.voice.voiceChannelID == config.voiceChannelID
        let label = isActive ? "Listening" : (config.enabled ? "Enabled" : "Disabled")
        let color: Color = isActive || config.enabled ? .green : .secondary
        return Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func channelChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func countChip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func behaviourChip(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: behaviourSymbol(for: text))
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }

    private func behaviourSymbol(for text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("stream") { return "video.fill" }
        if lower.contains("intro") { return "text.bubble.fill" }
        if lower.contains("empty") || lower.contains("min") { return "timer" }
        if lower.contains("short") { return "text.line.first.and.arrowtriangle.forward" }
        if lower.contains("link") { return "link" }
        return "checkmark.circle"
    }

    private var announcementPreviewText: String {
        previewText(for: activeAnnouncerConfig)
    }

    private func previewText(for config: AnnouncerVoiceChannelConfig?) -> String {
        guard let config else {
            return "John: Announcer is ready to read Discord updates aloud."
        }
        if config.autoJoinOnStream {
            return "John has started streaming The Finals. Come join the action!"
        }
        let feed = feedLabels(for: config).first ?? "#general"
        return "John: The latest update from \(feed) is ready."
    }

    private var listeningStateText: String {
        guard app.voiceConnectionStatus.isConnected else { return "Not listening" }
        return currentVoiceChannelMetricValue == "None" ? "Connected" : "Listening in \(currentVoiceChannelMetricValue)"
    }

    private var monitoredFeedsText: String {
        guard let config = activeAnnouncerConfig else { return "No feeds configured" }
        let labels = feedLabels(for: config)
        if labels.count <= 3 { return labels.joined(separator: ", ") }
        return "\(labels.prefix(2).joined(separator: ", ")) +\(labels.count - 2) more"
    }

    private var queueStateText: String {
        let depth = app.announcerHealth.queueDepth
        if depth == 0 { return "No queued announcements" }
        return "\(depth) announcement\(depth == 1 ? "" : "s") waiting"
    }

    private func behaviourSummary(for config: AnnouncerVoiceChannelConfig) -> String {
        var parts: [String] = []
        if config.autoJoin { parts.append("auto-join") }
        if config.autoJoinOnStream { parts.append("stream-join") }
        if config.introduceOnManualJoin { parts.append("intro") }
        switch config.connectionMode {
        case .fixed:      parts.append("\(config.connectionMinutes) min")
        case .untilEmpty: parts.append("until empty")
        }
        if config.summariseLong { parts.append("summarises") }
        if config.smartShortenWithAppleIntelligence { parts.append("AI shortens") }
        if config.ignoreLinks { parts.append("no links") }
        return parts.prefix(3).joined(separator: " · ")
    }

    private let vcTintCycle: [AnnouncerTint] = AnnouncerTint.allCases

    private func addVoiceChannel() {
        let tint = vcTintCycle[vcConfigs.count % vcTintCycle.count]
        let config = AnnouncerVoiceChannelConfig(
            id: UUID().uuidString,
            name: "New Voice Channel",
            tint: tint
        )
        vcConfigs.append(config)
        editingVCConfigIndex = vcConfigs.count - 1
    }

    private func openConfig(for config: AnnouncerVoiceChannelConfig) {
        if let index = vcConfigs.firstIndex(where: { $0.id == config.id }) {
            editingVCConfigIndex = index
        }
    }

    private func behaviourBinding(for id: String) -> Binding<AnnouncerBehaviourState> {
        Binding(
            get: { self.vcBehaviours[id] ?? AnnouncerBehaviourState() },
            set: { self.vcBehaviours[id] = $0 }
        )
    }

    // MARK: - Voice settings

    private var voiceSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                pickerField(label: "Voice", symbol: "speaker.wave.3.fill", selection: $selectedVoiceIdentifier, options: voiceOptions) { newValue in
                    Task { await app.setPreferredAnnouncerVoice(newValue) }
                }

                Button {
                    showingVoiceDownloadHelp = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Where to download SwiftBot voices")
                .popover(isPresented: $showingVoiceDownloadHelp, arrowEdge: .bottom) {
                    voiceDownloadHelpPopover
                }
            }
        }
    }

    private var voiceDownloadHelpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.circle.fill")
                    .foregroundStyle(.blue)
                Text("Download SwiftBot Voices")
                    .font(.headline)
            }

            Text("Open System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Text("For the best Announcer voice, install Piper - Neural TTS and download Ryan. Any installed Piper voice is preferred automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("If no Piper voice is available, SwiftBot falls back to the best Premium or Enhanced English voice installed in macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    // MARK: - Helpers

    private func syncFromSettings() {
        selectedVoiceIdentifier = app.settings.voice.preferredVoiceIdentifier
        // Only pull configs in from settings if our local state is stale
        // (avoids overwriting edits in progress when settings change for unrelated reasons)
        if vcConfigs != app.settings.voice.announcerConfigs {
            applyingSettingsSnapshot = true
            vcConfigs = app.settings.voice.announcerConfigs
            Task { @MainActor in
                await Task.yield()
                applyingSettingsSnapshot = false
            }
        }
    }

    private func scheduleVoiceConfigCommit(_ configs: [AnnouncerVoiceChannelConfig]) {
        voiceConfigCommitTask?.cancel()
        voiceConfigCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            voiceConfigCommitTask = nil
            app.commitAnnouncerConfigsFromEditor(configs)
        }
    }

    private func flushVoiceConfigCommit() {
        voiceConfigCommitTask?.cancel()
        voiceConfigCommitTask = nil
        guard !applyingSettingsSnapshot else { return }
        app.commitAnnouncerConfigsFromEditor(vcConfigs)
    }

    private var voiceOptions: [PickerOption] {
        cachedVoiceOptions
    }

    private func refreshVoiceOptions() {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        autoVoiceDisplayName = VoiceTTSSource.preferredEnglishVoice(from: englishVoices)?.name ?? "Auto"

        var options = [PickerOption(id: "", label: "Recommended: \(autoVoiceDisplayName) (auto)")]
        let piper = sortedVoices(englishVoices.filter(VoiceTTSSource.isPiperVoice))
        let premium = sortedVoices(englishVoices.filter { $0.quality == .premium && !VoiceTTSSource.isPiperVoice($0) })
        let enhanced = sortedVoices(englishVoices.filter { $0.quality == .enhanced && !VoiceTTSSource.isPiperVoice($0) })

        for v in piper {
            options.append(PickerOption(id: v.identifier, label: "\(v.name) (Piper · \(v.language))"))
        }
        for v in premium {
            options.append(PickerOption(id: v.identifier, label: "\(v.name) (Premium · \(v.language))"))
        }
        for v in enhanced {
            options.append(PickerOption(id: v.identifier, label: "\(v.name) (Enhanced · \(v.language))"))
        }
        cachedVoiceOptions = options
    }

    private func sortedVoices(_ voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        voices.sorted { lhs, rhs in
            let lhsIsRyan = VoiceTTSSource.isRyanPiperVoice(lhs)
            let rhsIsRyan = VoiceTTSSource.isRyanPiperVoice(rhs)
            if lhsIsRyan != rhsIsRyan { return lhsIsRyan }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    private func displayName(from option: PickerOption) -> String {
        option.label.components(separatedBy: " (").first ?? option.label
    }

    private var preferredVoiceDisplayName: String {
        let identifier = app.settings.voice.preferredVoiceIdentifier
        if identifier.isEmpty {
            return autoVoiceDisplayName
        }
        if let option = cachedVoiceOptions.first(where: { $0.id == identifier }) {
            return displayName(from: option)
        }
        return AVSpeechSynthesisVoice(identifier: identifier)?.name ?? "Auto"
    }

    private func voiceChannelDisplayName(for id: String) -> String {
        guard !id.isEmpty else { return "" }
        for channels in app.availableVoiceChannelsByServer.values {
            if let match = channels.first(where: { $0.id == id }) { return match.name }
        }
        return ""
    }

    private func textChannelDisplayName(for id: String) -> String {
        guard !id.isEmpty else { return "" }
        let ids = id.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var names: [String] = []
        for singleID in ids {
            var found = false
            for channels in app.availableTextChannelsByServer.values {
                if let match = channels.first(where: { $0.id == singleID }) {
                    names.append(match.name)
                    found = true
                    break
                }
            }
            if !found {
                names.append(singleID)
            }
        }
        return names.joined(separator: ", #")
    }

    private func pickerField(
        label: String,
        symbol: String? = nil,
        selection: Binding<String>,
        options: [PickerOption],
        onChange: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.caption2.weight(.semibold))
                }
                Text(label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
            }
            .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(options) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: selection.wrappedValue) { _, newValue in
                onChange(newValue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - AnnouncerConfigSheet

private struct AnnouncerConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppModel

    @Binding var config: AnnouncerVoiceChannelConfig
    @Binding var state: AnnouncerBehaviourState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    voiceChannelSection
                    connectionSection
                    readsFromSection
                    behaviourSection
                    testingSection
                    advancedSection
                }
                .padding(20)
            }
            .fadingEdges(top: 16, bottom: 20)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 660)
    }

    // MARK: Header

    private var sheetHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: config.symbol)
                .font(.title2.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(config.tint.color)
                .frame(width: 44, height: 44)
                .background(Circle().fill(config.tint.color.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.title3.weight(.semibold))
                Text("Voice Channel • \(config.voiceChannelName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.bar)
    }

    // MARK: Voice Channel

    private var voiceChannelSection: some View {
        AutomationsSection(title: "Voice Channel", symbol: "speaker.wave.2.fill") {
            VStack(alignment: .leading, spacing: 6) {
                let options = allVoiceChannelOptions
                if options.isEmpty {
                    Text("No voice channels found. Connect the bot to Discord first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Voice Channel", selection: Binding(
                        get: { config.voiceChannelID },
                        set: { newID in
                            if let match = options.first(where: { $0.id == newID }) {
                                config.voiceChannelID = newID
                                config.voiceChannelName = match.label
                                if config.name == "New Voice Channel" || config.name.isEmpty {
                                    config.name = match.label
                                }
                            } else {
                                config.voiceChannelID = ""
                                config.voiceChannelName = "—"
                            }
                        }
                    )) {
                        Text("— Pick a voice channel —").tag("")
                        ForEach(options) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        AutomationsSection(title: "Connection", symbol: "bolt.fill") {
            VStack(alignment: .leading, spacing: 12) {

                // Auto-join
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $config.autoJoin) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Auto-join when someone enters")
                                .font(.subheadline)
                            Text("SwiftBot joins \(config.voiceChannelName == "—" ? "this channel" : config.voiceChannelName) automatically whenever a member enters.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $config.introduceOnManualJoin) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Introduce on /announce join")
                                .font(.subheadline)
                            Text("SwiftBot says a short intro when someone starts this announcer manually.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }

                // Auto-join on stream
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $config.autoJoinOnStream) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Auto-join when someone goes live")
                                .font(.subheadline)
                            Text("SwiftBot joins \(config.voiceChannelName == "—" ? "this channel" : config.voiceChannelName) automatically when a member starts a Go Live stream there.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    if config.autoJoinOnStream {
                        Toggle(isOn: $config.introduceOnStreamJoin) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Announce on stream join")
                                    .font(.subheadline)
                                Text("SwiftBot says “I’ll read notifications during the stream.” when it joins for a stream.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.leading, 20)
                    }
                }

                Divider()

                // Duration
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Stay connected")
                            .font(.subheadline)
                        Spacer()
                        Picker("", selection: $config.connectionMode) {
                            ForEach(AnnouncerConnectionMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    if config.connectionMode == .fixed {
                        HStack {
                            Text("Duration")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $config.connectionMinutes) {
                                ForEach(connectionMinuteOptions, id: \.self) { minutes in
                                    Text(minutes >= 60
                                         ? "\(minutes / 60) hr\(minutes / 60 > 1 ? "s" : "")"
                                         : "\(minutes) min")
                                    .tag(minutes)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }

                    Text(config.connectionMode == .fixed
                         ? "SwiftBot leaves after \(config.connectionMinutes) minutes of reading, even if users are still present."
                         : "SwiftBot stays until the last member leaves the voice channel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Reads From

    private var readsFromSection: some View {
        AutomationsSection(title: "Reads From", symbol: "text.bubble.fill") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $config.readVoiceChannelChat) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Read voice channel chat")
                                .font(.subheadline)
                            Text("Reads the voice channel's built-in text chat — the chat viewers see beside a Go Live stream.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $config.ignoreWebhooks) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Only read server members")
                                .font(.subheadline)
                            Text("Skips messages posted by webhooks and integrations, so only real server members are read aloud.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }

                Divider()

                if config.textChannels.isEmpty {
                    Text("No text channels added yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(config.textChannels, id: \.self) { channel in
                            HStack(spacing: 6) {
                                channelPill("#\(channel)")
                                Spacer()
                                Button {
                                    config.textChannels.removeAll { $0 == channel }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                let textOptions = allTextChannelOptions.filter { !config.textChannels.contains($0.label) }
                if !textOptions.isEmpty {
                    Menu {
                        ForEach(textOptions) { option in
                            Button(option.label) {
                                config.textChannels.append(option.label)
                            }
                        }
                    } label: {
                        Label("Add Channel", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        AutomationsSection(title: "Behaviour", symbol: "dial.medium.fill") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Announce joins", isOn: $state.announceJoins)
                    Toggle("Announce leaves", isOn: $state.announceLeaves)
                    Divider().padding(.vertical, 2)
                    Toggle("Shorten long messages", isOn: $config.summariseLong)
                    Toggle("Ignore links", isOn: $config.ignoreLinks)
                    Toggle("Skip bot messages", isOn: $config.skipBots)
                    Toggle("Ignore emoji spam", isOn: $config.ignoreEmojiSpam)
                    Toggle("Keep announcements short", isOn: $config.keepShort)
                    Toggle("Smart shorten with Apple Intelligence", isOn: $config.smartShortenWithAppleIntelligence)
                }
                .toggleStyle(.checkbox)

                Text("Messages over 300 characters are shortened instead of skipped. Smart shortening uses Apple Intelligence when available and falls back to the regular caps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Testing

    private var testingSection: some View {
        AutomationsSection(title: "Testing", symbol: "play.circle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        let channelName = config.textChannels.first ?? ""
                        Task {
                            let text = await app.fetchLastMessageText(fromChannelNamed: channelName)
                            app.speakLocallyPreview(text)
                        }
                    } label: {
                        Label("Read Last Message", systemImage: "text.bubble.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(config.textChannels.isEmpty)

                    Button {
                        app.speakLocallyPreview("SwiftBot is ready for the \(config.voiceChannelName) voice channel.")
                    } label: {
                        Label("Hear Voice", systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                if let channel = config.textChannels.first {
                    Text("Last tested from: #\(channel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        AutomationsSection(title: "Advanced", symbol: "gearshape") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Read embeds", isOn: $state.readEmbeds)
                    .toggleStyle(.checkbox)

                configSlider("Cooldown between announcements", value: $state.cooldownSeconds, in: 0...10) {
                    "\(Int($0))s"
                }
                configSlider("Speech delay", value: $state.speechDelay, in: 0...3) {
                    String(format: "%.1fs", $0)
                }
            }
        }
    }

    // MARK: Helpers

    private var allVoiceChannelOptions: [PickerOption] {
        var options: [PickerOption] = []
        for channels in app.availableVoiceChannelsByServer.values {
            options.append(contentsOf: channels.map { PickerOption(id: $0.id, label: $0.name) })
        }
        return options.sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
    }

    private var allTextChannelOptions: [PickerOption] {
        var options: [PickerOption] = []
        for channels in app.availableTextChannelsByServer.values {
            options.append(contentsOf: channels.map { PickerOption(id: $0.id, label: $0.name) })
        }
        return options.sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
    }

    private func configSlider(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        display: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(display(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func channelPill(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(config.tint.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(config.tint.color.opacity(0.10), in: Capsule())
    }
}

private struct PickerOption: Identifiable, Hashable {
    let id: String
    let label: String
}

private struct AnnouncerActivityKind {
    let label: String
    let symbol: String
    let color: Color
}

private struct AnnouncerChipFlow: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let arrangement = arrange(sizes: sizes, maxWidth: proposal.width)
        return CGSize(width: proposal.width ?? arrangement.width, height: arrangement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let arrangement = arrange(sizes: sizes, maxWidth: bounds.width)

        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + arrangement.positions[index].x,
                    y: bounds.minY + arrangement.positions[index].y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    private func arrange(sizes: [CGSize], maxWidth proposedWidth: CGFloat?) -> (positions: [CGPoint], width: CGFloat, height: CGFloat) {
        let availableWidth = proposedWidth.map { max(0, $0) } ?? .greatestFiniteMagnitude
        var positions: [CGPoint] = []
        var rowX: CGFloat = 0
        var rowY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for size in sizes {
            let itemWidth = min(size.width, availableWidth)
            let itemX = rowX == 0 ? 0 : rowX + spacing

            if rowX > 0, itemX + itemWidth > availableWidth {
                measuredWidth = max(measuredWidth, rowX)
                rowX = 0
                rowY += rowHeight + rowSpacing
                rowHeight = 0
            }

            let placedX = rowX == 0 ? 0 : rowX + spacing
            positions.append(CGPoint(x: placedX, y: rowY))
            rowX = placedX + itemWidth
            rowHeight = max(rowHeight, size.height)
        }

        measuredWidth = max(measuredWidth, rowX)
        return (positions, measuredWidth, rowY + rowHeight)
    }
}

private let connectionMinuteOptions: [Int] = [5, 10, 15, 20, 30, 45, 60, 90, 120]

private struct AnnouncerBehaviourState {
    var summariseLong: Bool = true
    var ignoreLinks: Bool = true
    var skipBots: Bool = true
    var ignoreEmojiSpam: Bool = false
    var keepShort: Bool = true
    var announceJoins: Bool = true
    var announceLeaves: Bool = true
    var readEmbeds: Bool = false
    var cooldownSeconds: Double = 3
    var speechDelay: Double = 0.5
    var advancedExpanded: Bool = false
}


private struct VoiceWaveformMark: View {
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach([5.0, 10.0, 7.0, 13.0, 6.0], id: \.self) { height in
                Capsule()
                    .fill(color.opacity(0.72))
                    .frame(width: 3, height: height)
            }
        }
        .frame(width: 24, height: 16)
    }
}

private struct LiveWaveformBars: View {
    let color: Color
    @State private var isAnimating = false

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(0.78))
                    .frame(width: 3, height: isAnimating ? CGFloat(7 + (index % 2) * 7) : CGFloat(13 - (index % 2) * 5))
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.08),
                        value: isAnimating
                    )
            }
        }
        .frame(width: 22, height: 16)
        .onAppear { isAnimating = true }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
