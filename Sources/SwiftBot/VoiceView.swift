import AVFoundation
import SwiftUI
import libdave_swift

struct VoiceView: View {
    @EnvironmentObject var app: AppModel

    @State private var selectedVoiceIdentifier: String = ""
    @State private var daveDiagnostics: DaveDiagnostics? = nil
    @State private var showingVoiceDownloadHelp: Bool = false
    @State private var vcConfigs: [AnnouncerVoiceChannelConfig] = []
    @State private var advancedExpanded: Bool = false
    @State private var vcBehaviours: [String: AnnouncerBehaviourState] = [:]
    @State private var technicalLogsExpanded: Bool = false
    @State private var editingVCConfigIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)

            if app.forwardsConfigEditsToPrimary {
                PreferencesSyncsToPrimaryBanner(text: "Editing as Failover — changes are pushed to the Primary and sync back.")
                    .padding(.horizontal, 16)
            } else if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. Announcer settings sync from Primary.")
                    .padding(.horizontal, 16)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    liveSessionPill
                    metricTileRow
                    voiceChannelConfigurationsSection
                    globalVoiceSettingsSection
                    recentActivitySection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 16)
            }
            .fadingEdges(top: 16, bottom: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(app.isFailoverManagedNode && !app.forwardsConfigEditsToPrimary)
        .opacity(app.isFailoverManagedNode && !app.forwardsConfigEditsToPrimary ? 0.62 : 1)
        .meshConfigMutationErrorAlert()
        .onAppear { syncFromSettings() }
        .onChange(of: app.settings.voice) { _, _ in syncFromSettings() }
        .onChange(of: vcConfigs) { _, newValue in
            app.settings.voice.announcerConfigs = newValue
            // On a Failover, forward the whole Announcer section to the Primary
            // (revert on failure). `syncFromSettings()` guards against echoing
            // the reconciled value back, so this doesn't loop.
            if app.forwardsConfigEditsToPrimary {
                app.forwardConfigMutationToPrimary(.replaceVoice(app.settings.voice), revertOnFailure: true)
            } else {
                app.saveSettings()
            }
        }
        .sheet(isPresented: Binding(
            get: { editingVCConfigIndex != nil },
            set: { if !$0 { editingVCConfigIndex = nil } }
        )) {
            if let index = editingVCConfigIndex {
                AnnouncerConfigSheet(config: $vcConfigs[index], state: behaviourBinding(for: vcConfigs[index].id))
                    .environmentObject(app)
            }
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            if app.voiceConnectionStatus.isConnected {
                Task {
                    daveDiagnostics = await app.getDaveDiagnostics()
                }
            } else {
                daveDiagnostics = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                ViewSectionHeader(title: "Announcer", symbol: "speaker.wave.2.bubble.fill")
                Text("Context-aware spoken Discord feeds")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
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

    private var statusSubtitle: String {
        switch app.voiceConnectionStatus {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting to voice channel\u{2026}"
        case .connected: return connectedSubtitle
        case .recovering(let detail): return detail.isEmpty ? "Recovering voice connection\u{2026}" : detail
        case .disconnecting: return "Disconnecting\u{2026}"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    private var connectedSubtitle: String {
        let channel = voiceChannelDisplayName(for: app.settings.voice.voiceChannelID)
        let guildName = app.connectedServers[app.settings.voice.guildID] ?? "—"
        if channel.isEmpty { return "Connected to \(guildName)" }
        return "Connected to #\(channel) in \(guildName)"
    }

    private var liveSessionPill: some View {
        Group {
            if app.voiceConnectionStatus.isConnected {
                HStack(spacing: 9) {
                    LiveWaveformBars(color: .purple)
                    Text(liveSessionText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Text("/announce join")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.purple.opacity(0.16), lineWidth: 1))
            }
        }
    }

    private var liveSessionText: String {
        let channel = textChannelDisplayName(for: app.settings.voice.watchedTextChannelID).ifEmpty("general")
        let guild = app.connectedServers[app.settings.voice.guildID] ?? "AO"
        return "Reading #\(channel) in \(guild)"
    }

    private var daveBlockedBanner: some View {
        Group {
            if let diag = daveDiagnostics {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DAVE End-to-End Encryption Active")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                        
                        Text("Secure voice connection established via **libdave-swift** and Apple's MLS key ratchet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        HStack(spacing: 16) {
                            HStack(spacing: 4) {
                                Text("MLS Epoch:")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text("\(diag.currentEpoch)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.green)
                            }
                            HStack(spacing: 4) {
                                Text("Handshake:")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(diag.handshakeState.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                            if let stats = diag.encryptionStats {
                                HStack(spacing: 4) {
                                    Text("Encrypted Frames:")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text("\(stats.encryptSuccessCount)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    Spacer()
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.green.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.3), lineWidth: 1)
                )
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "shield.checkered")
                        .foregroundStyle(.purple)
                        .font(.title3)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DAVE E2EE Capability Enabled")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            "SwiftBot now includes a native integration of Discord's DAVE end-to-end encryption " +
                            "protocol powered by **libdave-swift**. Once you connect to a voice channel, a " +
                            "secure, hardware-accelerated MLS session will be established automatically."
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.purple.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.purple.opacity(0.25), lineWidth: 1)
                )
            }
        }
    }

    private var statusBadge: some View {
        Text(app.voiceConnectionStatus.displayLabel.uppercased())
            .font(.caption2.weight(.heavy))
            .tracking(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(badgeForeground)
            .background(
                Capsule().fill(badgeBackground)
            )
            .overlay(
                Capsule().strokeBorder(badgeBorder, lineWidth: 1)
            )
    }

    private var badgeBackground: Color {
        switch app.voiceConnectionStatus {
        case .connected: return .green.opacity(0.18)
        case .connecting, .recovering, .disconnecting: return .yellow.opacity(0.18)
        case .failed: return .red.opacity(0.18)
        case .idle: return Color.primary.opacity(0.06)
        }
    }
    private var badgeForeground: Color {
        switch app.voiceConnectionStatus {
        case .connected: return .green
        case .connecting, .recovering, .disconnecting: return .yellow
        case .failed: return .red
        case .idle: return .secondary
        }
    }
    private var badgeBorder: Color { badgeForeground.opacity(0.4) }

    // MARK: - Metrics

    private var metricTileRow: some View {
        LazyVGrid(columns: DashboardMetricGrid.columns, spacing: DashboardMetricGrid.spacing) {
            DashboardMetricCard(
                title: "Active Sessions",
                value: app.voiceConnectionStatus.canQueueAnnouncements ? "1" : "0",
                subtitle: app.voiceConnectionStatus.canQueueAnnouncements ? liveSessionText : "Ready for /announce",
                symbol: "waveform.badge.mic",
                color: statusColor
            )
            DashboardMetricCard(
                title: "Configured Voice Channels",
                value: "\(vcConfigs.count)",
                subtitle: "Feeds ready for /announce join",
                symbol: "speaker.wave.2.bubble.fill",
                color: .purple
            )
            DashboardMetricCard(
                title: "Messages Read Today",
                value: "\(app.messagesSpokenToday)",
                subtitle: app.messagesSpokenToday == 0 ? "No reads yet today" : "Announcements + previews",
                symbol: "text.bubble.fill",
                color: .blue
            )
            DashboardMetricCard(
                title: "Preferred Voice",
                value: preferredVoiceDisplayName,
                subtitle: selectedVoiceSubtitle,
                symbol: "speaker.wave.3.fill",
                color: .pink
            )
        }
    }

    private var selectedVoiceSubtitle: String {
        selectedVoiceIdentifier.isEmpty ? "Best available voice" : "macOS speech voice"
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
        HStack(spacing: 10) {
            Circle()
                .fill(config.enabled ? config.tint.color : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)

            Image(systemName: config.symbol)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(config.tint.color)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(config.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(config.voiceChannelName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if !config.textChannels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(config.textChannels.prefix(3), id: \.self) { ch in
                            Text("#\(ch)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(config.tint.color)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(config.tint.color.opacity(0.10), in: Capsule())
                        }
                        if config.textChannels.count > 3 {
                            Text("+\(config.textChannels.count - 3)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if !behaviourSummary(for: config).isEmpty {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(behaviourSummary(for: config))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer()

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

            Button {
                Task {
                    let text = await app.fetchLastMessageText(fromChannelNamed: config.textChannels.first ?? "")
                    app.speakLocallyPreview(text)
                }
            } label: {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Read Last Message")

            Button { openConfig(for: config) } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Configure")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { openConfig(for: config) }
        .contextMenu {
            Button {
                Task {
                    let text = await app.fetchLastMessageText(fromChannelNamed: config.textChannels.first ?? "")
                    app.speakLocallyPreview(text)
                }
            } label: {
                Label("Read Last Message", systemImage: "text.bubble")
            }
            Button { openConfig(for: config) } label: {
                Label("Configure", systemImage: "pencil")
            }
            Divider()
            Button(config.enabled ? "Pause" : "Enable") {
                if let i = vcConfigs.firstIndex(where: { $0.id == config.id }) {
                    vcConfigs[i].enabled.toggle()
                }
            }
            Button("Remove", role: .destructive) {
                vcConfigs.removeAll { $0.id == config.id }
            }
        }
    }

    // MARK: - Global voice settings

    private var globalVoiceSettingsSection: some View {
        AutomationsSection(title: "Global Voice Settings", symbol: "speaker.wave.3.fill") {
            VStack(alignment: .leading, spacing: 12) {
                voiceSettingsPanel

                HStack(spacing: 8) {
                    VoiceWaveformMark(color: .purple)
                    Text(preferredVoiceDisplayName)
                        .font(.caption.weight(.medium))
                    Text(selectedVoiceSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        app.speakLocallyPreview("SwiftBot will read Discord messages using \(preferredVoiceDisplayName).")
                    } label: {
                        Label("Preview Voice", systemImage: "play.circle")
                    }
                }

                DisclosureGroup(isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        announcerHealthPanel
                        connectionPanel
                        daveBlockedBanner
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 8) {
                        Label("DAVE Status", systemImage: daveDiagnostics == nil ? "shield.checkered" : "lock.shield.fill")
                        Text(daveDiagnostics == nil ? "Ready when SwiftBot joins voice" : "Encrypted session active")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.medium))
                }
            }
        }
    }

    private var announcerHealthPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: announcerHealthSymbol)
                    .foregroundStyle(announcerHealthColor)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Announcer Health")
                        .font(.subheadline.weight(.semibold))
                    Text(app.announcerHealth.phase.displayLabel)
                        .font(.caption)
                        .foregroundStyle(announcerHealthColor)
                }
                Spacer()
                Button {
                    Task { await app.reconnectAnnouncerVoiceFromUI() }
                } label: {
                    Label("Reconnect Voice", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(app.status != .running || app.settings.voice.voiceChannelID.isEmpty)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], alignment: .leading, spacing: 8) {
                announcerHealthMetric("Pending", "\(app.announcerHealth.queueDepth)")
                announcerHealthMetric("Retry Streak", "\(app.announcerHealth.retryStreak)")
                announcerHealthMetric("Last Spoken", formattedHealthDate(app.announcerHealth.lastSpokenAt))
                announcerHealthMetric("Last Recovery", formattedHealthDate(app.announcerHealth.lastRecoveryAt))
            }

            if let failure = app.announcerHealth.lastFailureReason, !failure.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(announcerHealthColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(announcerHealthColor.opacity(0.28), lineWidth: 1)
        )
    }

    private func announcerHealthMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var announcerHealthColor: Color {
        switch app.announcerHealth.phase {
        case .idle: return .secondary
        case .queued, .rendering, .sending: return .blue
        case .paused, .recovering: return .yellow
        case .failed: return .red
        }
    }

    private var announcerHealthSymbol: String {
        switch app.announcerHealth.phase {
        case .idle: return "checkmark.circle"
        case .queued: return "text.line.first.and.arrowtriangle.forward"
        case .rendering: return "waveform"
        case .sending: return "paperplane.fill"
        case .paused: return "pause.circle"
        case .recovering: return "arrow.clockwise.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func formattedHealthDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    /// Technical Logs render more lines in DEBUG (Dev) builds so a full connect
    /// sequence stays visible; release stays compact.
    private var technicalLogLimit: Int {
        #if DEBUG
        return 60
        #else
        return 12
        #endif
    }

    private var recentActivitySection: some View {
        AutomationsSection(title: "Recent Activity", symbol: "text.bubble") {
            VStack(alignment: .leading, spacing: 8) {
                if app.voiceLog.isEmpty {
                    PlaceholderPanelLine(text: "Spoken announcements and voice connection events will appear here.")
                } else {
                    ForEach(Array(app.voiceLog.prefix(8))) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 64, alignment: .leading)
                            Text(humanReadableLog(entry.description))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 1)
                    }

                    DisclosureGroup("Technical Logs", isExpanded: $technicalLogsExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(app.voiceLog.prefix(technicalLogLimit))) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 64, alignment: .leading)
                                    Text(entry.description)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func humanReadableLog(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("join") && lower.contains("voice") {
            if let channel = raw.components(separatedBy: "#").dropFirst().first?.components(separatedBy: " ").first {
                return "Joined #\(channel) voice channel"
            }
            return "Joined voice channel"
        }
        if lower.contains("left") || lower.contains("disconnect") {
            return "Left voice channel"
        }
        if lower.contains("read") || lower.contains("speak") || lower.contains("announced") {
            if let channel = raw.components(separatedBy: "#").dropFirst().first?.components(separatedBy: " ").first {
                return "Read message from #\(channel)"
            }
            return "Read a message aloud"
        }
        if lower.contains("connect") {
            return "Connected to Discord voice"
        }
        return raw
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
        let s = vcBehaviours[config.id] ?? AnnouncerBehaviourState()
        if s.summariseLong { parts.append("summarises") }
        if s.ignoreLinks   { parts.append("no links") }
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

    // MARK: - Connection panel

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.title3)
                    .foregroundStyle(.purple)
                    .frame(width: 28, height: 28)
                    .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("/announce join")
                        .font(.subheadline.monospaced().weight(.semibold))
                    Text("SwiftBot joins the caller's current voice channel and loads the matching voice-channel configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    Task { await app.disconnectVoice() }
                } label: {
                    Label("End Current Session", systemImage: "phone.down.fill")
                }
                .disabled(app.voiceConnectionStatus == .idle)

                Spacer()
            }

            Text("Connection setup and DAVE encryption happen automatically when a user summons SwiftBot from Discord.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Voice settings

    private var voiceSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                pickerField(label: "Announcer", symbol: "speaker.wave.3.fill", selection: $selectedVoiceIdentifier, options: voiceOptions) { newValue in
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
            Text("Recommended: Nathan (Enhanced). Empty uses Nathan when installed, then the best available Premium or Enhanced English voice.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

            Text("Download Nathan (Enhanced) under English voices if it is not listed. macOS does not let SwiftBot install voices automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("For high-quality neural voices (e.g. Piper), download the 'Piper - Neural TTS' app from the Mac App Store and download voices inside it. They will automatically appear in SwiftBot.")
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
            vcConfigs = app.settings.voice.announcerConfigs
        }
    }

    private var voiceOptions: [PickerOption] {
        var options = [PickerOption(id: "", label: "Recommended: Nathan Enhanced (auto)")]
        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        let premium = englishVoices.filter { $0.quality == .premium }
        let enhanced = englishVoices.filter { $0.quality == .enhanced }
        let piper = englishVoices.filter {
            $0.quality != .premium &&
            $0.quality != .enhanced &&
            ($0.identifier.localizedCaseInsensitiveContains("piper") || $0.name.localizedCaseInsensitiveContains("piper"))
        }
        
        for v in premium {
            options.append(PickerOption(id: v.identifier, label: "\(v.name) (Premium · \(v.language))"))
        }
        for v in enhanced {
            options.append(PickerOption(id: v.identifier, label: "\(v.name) (Enhanced · \(v.language))"))
        }
        for v in piper {
            options.append(PickerOption(id: v.identifier, label: "\(v.name) (Piper · \(v.language))"))
        }
        return options
    }

    private var preferredVoiceDisplayName: String {
        let identifier = app.settings.voice.preferredVoiceIdentifier
        if identifier.isEmpty {
            return VoiceTTSSource.preferredEnglishVoice()?.name ?? "Auto"
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
                }
                .toggleStyle(.checkbox)

                Text("Messages over 300 characters are shortened instead of skipped; \"Keep announcements short\" tightens the cap further.")
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
                        Label("Preview Voice", systemImage: "play.circle")
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
