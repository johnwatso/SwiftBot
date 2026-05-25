import AVFoundation
import SwiftUI
import libdave_swift

struct VoiceView: View {
    @EnvironmentObject var app: AppModel

    @State private var selectedGuild: String = ""
    @State private var selectedVoiceChannel: String = ""
    @State private var selectedTextChannel: String = ""
    @State private var selectedVoiceIdentifier: String = ""
    @State private var textChannelSourceEnabled: Bool = false
    @State private var testText: String = "Hello from SwiftBot."
    @State private var daveDiagnostics: DaveDiagnostics? = nil
    @State private var showingVoiceDownloadHelp: Bool = false
    @State private var presetPrompt: String = "Read #general and #clips when someone uses /announce friends"
    @State private var expandedPresetIDs: Set<String> = ["friends"]
    @State private var speechRate: Double = 0.50
    @State private var ignoreBots: Bool = true
    @State private var ignoreLinks: Bool = true
    @State private var ignoreLongMessages: Bool = true
    @State private var autoLeaveMinutes: Double = 10
    @State private var advancedExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    liveSessionPill
                    metricTileRow
                    createPresetSection
                    starterPresetsSection
                    presetsSection
                    recentActivitySection
                    advancedSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { syncFromSettings() }
        .onChange(of: app.settings.voice) { _, _ in syncFromSettings() }
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
                Text("Announcer")
                    .font(.title2.weight(.bold))
                Text("Preset-based voice reads for Discord channels")
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
        case .connecting, .disconnecting: return .yellow
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var statusSubtitle: String {
        switch app.voiceConnectionStatus {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting to voice channel\u{2026}"
        case .connected: return connectedSubtitle
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
                    Text("/announce friends")
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
        case .connecting, .disconnecting: return .yellow.opacity(0.18)
        case .failed: return .red.opacity(0.18)
        case .idle: return Color.primary.opacity(0.06)
        }
    }
    private var badgeForeground: Color {
        switch app.voiceConnectionStatus {
        case .connected: return .green
        case .connecting, .disconnecting: return .yellow
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
                value: app.voiceConnectionStatus.isConnected ? "1" : "0",
                subtitle: app.voiceConnectionStatus.isConnected ? liveSessionText : "Ready for /announce",
                symbol: "waveform.badge.mic",
                color: statusColor
            )
            DashboardMetricCard(
                title: "Presets",
                value: "\(announcerPresets.count)",
                subtitle: "Slash-command ready",
                symbol: "square.stack.3d.up.fill",
                color: .purple
            )
            DashboardMetricCard(
                title: "Messages Read Today",
                value: "\(app.voiceLog.count)",
                subtitle: app.voiceLog.isEmpty ? "No reads yet" : "Includes previews and sessions",
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

    // MARK: - Preset workflow

    private var createPresetSection: some View {
        AutomationsSection(title: "Create an announcer preset", symbol: "plus.message.fill") {
            VStack(alignment: .leading, spacing: 10) {
                TextField(
                    "Read #general and #clips when someone uses /announce friends",
                    text: $presetPrompt,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )

                HStack {
                    Text("Example: Read #general and #clips when someone uses /announce friends")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        expandedPresetIDs.insert("friends")
                    } label: {
                        Label("Create Preset", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(presetPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var starterPresetsSection: some View {
        AutomationsSection(title: "Starter presets", symbol: "square.grid.2x2") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(announcerPresets) { preset in
                        starterPresetCard(preset)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func starterPresetCard(_ preset: AnnouncerPreset) -> some View {
        Button {
            expandedPresetIDs.insert(preset.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: preset.symbol)
                    .font(.title3.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(preset.tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(preset.tint.opacity(0.14)))

                Text(preset.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    compactPill(preset.command, tint: .purple, symbol: "terminal.fill")
                    compactPill("\(preset.channels.count) channels", tint: preset.tint, symbol: "number")
                }

                Text(preset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(width: 210, height: 142, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(preset.tint.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(preset.tint.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var presetsSection: some View {
        AutomationsSection(title: "Announcer presets", symbol: "list.bullet.rectangle") {
            VStack(spacing: 8) {
                ForEach(announcerPresets) { preset in
                    presetCard(preset)
                }
            }
        }
    }

    private func presetCard(_ preset: AnnouncerPreset) -> some View {
        let isExpanded = expandedPresetIDs.contains(preset.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: .constant(preset.enabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                Image(systemName: preset.symbol)
                    .font(.title3.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(preset.tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(preset.tint.opacity(0.14)))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(preset.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(preset.command)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    pillWrap(preset.channels.map { "#\($0)" }, tint: .blue, symbol: "text.bubble.fill")
                    pillWrap(preset.events, tint: preset.tint, symbol: "bell.badge.fill")
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            togglePresetExpansion(preset.id)
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse" : "Expand")

                    Menu {
                        Button("Duplicate") {}
                        Button(preset.enabled ? "Disable" : "Enable") {}
                        Divider()
                        Button("Delete", role: .destructive) {}
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }

            HStack(spacing: 8) {
                VoiceWaveformMark(color: preset.tint)
                Text(preferredVoiceDisplayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text(selectedVoiceSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.leading, 52)

            if isExpanded {
                presetExpandedContent(preset)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(preset.tint.opacity(isExpanded ? 0.18 : 0.09), lineWidth: 1)
        )
    }

    private func presetExpandedContent(_ preset: AnnouncerPreset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

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

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Speech speed", systemImage: "speedometer")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(speechRate * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $speechRate, in: 0.35...0.75)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 8) {
                Toggle("Ignore bots", isOn: $ignoreBots)
                Toggle("Ignore links", isOn: $ignoreLinks)
                Toggle("Ignore long messages", isOn: $ignoreLongMessages)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Auto leave")
                        .font(.caption.weight(.medium))
                    Stepper("\(Int(autoLeaveMinutes)) min", value: $autoLeaveMinutes, in: 1...60, step: 1)
                }
            }
            .font(.caption)

            HStack(spacing: 8) {
                Button {
                    app.speakLocallyPreview(sampleLastMessage(for: preset))
                } label: {
                    Label("Read Last Message", systemImage: "text.bubble.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    app.speakLocallyPreview("This is \(preset.name), using \(preferredVoiceDisplayName).")
                } label: {
                    Label("Preview Voice", systemImage: "play.circle")
                }

                Spacer()
            }
        }
        .padding(.leading, 52)
    }

    private var recentActivitySection: some View {
        AutomationsSection(title: "Recent reads", symbol: "text.bubble") {
            recentVoiceActivityPanel
        }
    }

    private var advancedSection: some View {
        AutomationsSection(title: "Advanced", symbol: "slider.horizontal.3") {
            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    connectionPanel
                    daveBlockedBanner
                }
                .padding(.top, 8)
            } label: {
                Text("Connection and transport details")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private func togglePresetExpansion(_ id: String) {
        if expandedPresetIDs.contains(id) {
            expandedPresetIDs.remove(id)
        } else {
            expandedPresetIDs.insert(id)
        }
    }

    private func sampleLastMessage(for preset: AnnouncerPreset) -> String {
        let channel = preset.channels.first ?? "general"
        return "Latest from #\(channel). Jo says: The build is live, clips are pinned, and the emoji reactions look perfect."
    }

    private func compactPill(_ text: String, tint: Color, symbol: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10), in: Capsule())
    }

    private func pillWrap(_ values: [String], tint: Color, symbol: String) -> some View {
        HStack(spacing: 5) {
            ForEach(values.prefix(4), id: \.self) { value in
                compactPill(value, tint: tint, symbol: symbol)
            }
            if values.count > 4 {
                compactPill("+\(values.count - 4)", tint: .secondary)
            }
        }
    }

    // MARK: - Connection panel

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                pickerField(label: "Server", selection: $selectedGuild, options: serverOptions) { newValue in
                    app.setVoiceGuildForAnnouncer(newValue)
                    selectedVoiceChannel = ""
                    selectedTextChannel = ""
                }
                pickerField(label: "Voice Channel", selection: $selectedVoiceChannel, options: voiceChannelOptions) { newValue in
                    app.setVoiceChannelForAnnouncer(newValue)
                }
                .disabled(selectedGuild.isEmpty)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await app.connectVoice() }
                } label: {
                    Label(connectButtonTitle, systemImage: "phone.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canConnect)

                Button {
                    Task { await app.disconnectVoice() }
                } label: {
                    Label("Leave", systemImage: "phone.down.fill")
                }
                .disabled(app.voiceConnectionStatus == .idle)

                Spacer()
            }

            Text(
                "Establish a secure, end-to-end encrypted connection to the selected Discord voice channel. " +
                "SwiftBot will negotiate the MLS protocol and stream announcements natively."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectButtonTitle: String {
        switch app.voiceConnectionStatus {
        case .connected: return "Connected"
        case .connecting: return "Connecting\u{2026}"
        default: return "Join Voice Channel"
        }
    }

    private var canConnect: Bool {
        !selectedGuild.isEmpty &&
        !selectedVoiceChannel.isEmpty &&
        app.voiceConnectionStatus != .connecting &&
        !app.voiceConnectionStatus.isConnected
    }

    // MARK: - Sources panel

    private var sourcesPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.bubble.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Read messages from a text channel")
                        .font(.subheadline.weight(.semibold))
                    Text("Bot will speak each new message as “Author: text.” Skips messages over 300 characters and link-only posts; reads embed titles when present.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $textChannelSourceEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: textChannelSourceEnabled) { _, newValue in
                        app.setTextChannelSourceEnabledForAnnouncer(newValue)
                    }
            }

            pickerField(label: "Text Channel", selection: $selectedTextChannel, options: textChannelOptions) { newValue in
                Task { await app.setWatchedTextChannelForAnnouncer(newValue) }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Test something", text: $testText)
                        .textFieldStyle(.roundedBorder)
                    Button("Preview on Mac") {
                        app.speakLocallyPreview(testText)
                    }
                    .disabled(testText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Speak in Discord") {
                        let snapshot = testText
                        Task { await app.speakAnnouncement(snapshot) }
                    }
                    .disabled(!app.voiceConnectionStatus.isConnected || testText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(
                    "Preview plays through this Mac's speakers using the selected voice. " +
                    "Speak in Discord sends the audio to the connected Discord voice channel using native DAVE encryption."
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 4)

            DisabledSourceRow(symbol: "person.wave.2.fill", title: "Voice channel join / leave",
                              detail: "Announce when members join or leave the connected voice channel.")
            DisabledSourceRow(symbol: "bolt.shield.fill", title: "Moderation actions",
                              detail: "Speak moderation events (mutes, bans, deletes) as they happen.")
            DisabledSourceRow(symbol: "pickaxe", title: "SwiftMiner alerts",
                              detail: "Voice-channel alerts for rig status changes.")

            Text("Additional sources will ship once the text-channel reader has been exercised in production.")
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
            Text("Premium and Enhanced English voices on this Mac. Empty means “best Premium English voice available.”")
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

            Text("Choose Premium or Enhanced English voices there, then reopen this menu in SwiftBot. VoiceOver-only Siri voices are not available to apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private var recentVoiceActivityPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if app.voiceLog.isEmpty {
                PlaceholderPanelLine(text: "Spoken announcements and voice connection events will appear here.")
            } else {
                ForEach(Array(app.voiceLog.prefix(8))) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.time, style: .time)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(entry.description)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Helpers

    private func syncFromSettings() {
        selectedGuild = app.settings.voice.guildID
        selectedVoiceChannel = app.settings.voice.voiceChannelID
        selectedTextChannel = app.settings.voice.watchedTextChannelID
        selectedVoiceIdentifier = app.settings.voice.preferredVoiceIdentifier
        textChannelSourceEnabled = app.settings.voice.textChannelSourceEnabled
    }

    private var serverOptions: [PickerOption] {
        var options = [PickerOption(id: "", label: "— Pick a server —")]
        let sorted = app.connectedServers.sorted(by: { $0.value.localizedCompare($1.value) == .orderedAscending })
        options.append(contentsOf: sorted.map { PickerOption(id: $0.key, label: $0.value) })
        return options
    }

    private var voiceChannelOptions: [PickerOption] {
        var options = [PickerOption(id: "", label: "— Pick a voice channel —")]
        let list = app.availableVoiceChannelsByServer[selectedGuild] ?? []
        options.append(contentsOf: list.map { PickerOption(id: $0.id, label: $0.name) })
        return options
    }

    private var textChannelOptions: [PickerOption] {
        var options = [PickerOption(id: "", label: "— Pick a text channel —")]
        let list = app.availableTextChannelsByServer[selectedGuild] ?? []
        options.append(contentsOf: list.map { PickerOption(id: $0.id, label: "#\($0.name)") })
        return options
    }

    private var voiceOptions: [PickerOption] {
        var options = [PickerOption(id: "", label: "Best Premium English voice (auto)")]
        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        let premium = englishVoices.filter { $0.quality == .premium }
        let enhanced = englishVoices.filter { $0.quality == .enhanced }
        for v in premium {
            options.append(PickerOption(id: v.identifier, label: "\(v.name) (Premium · \(v.language))"))
        }
        for v in enhanced {
            options.append(PickerOption(id: v.identifier, label: "\(v.name) (Enhanced · \(v.language))"))
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
        for channels in app.availableTextChannelsByServer.values {
            if let match = channels.first(where: { $0.id == id }) { return match.name }
        }
        return ""
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

private struct PickerOption: Identifiable, Hashable {
    let id: String
    let label: String
}

private struct AnnouncerPreset: Identifiable {
    let id: String
    let name: String
    let command: String
    let summary: String
    let symbol: String
    let tint: Color
    let channels: [String]
    let events: [String]
    let enabled: Bool
}

private let announcerPresets: [AnnouncerPreset] = [
    AnnouncerPreset(
        id: "friends",
        name: "Friends",
        command: "/announce friends",
        summary: "Casual reads for active hangout channels.",
        symbol: "person.2.wave.2.fill",
        tint: .purple,
        channels: ["general", "clips"],
        events: ["Messages", "Embeds", "Emoji"],
        enabled: true
    ),
    AnnouncerPreset(
        id: "moderation",
        name: "Moderation",
        command: "/announce mod",
        summary: "Short reads for moderation watch channels.",
        symbol: "shield.lefthalf.filled",
        tint: .red,
        channels: ["mod-log", "reports"],
        events: ["Deletes", "Reports"],
        enabled: true
    ),
    AnnouncerPreset(
        id: "stream-alerts",
        name: "Stream Alerts",
        command: "/announce stream",
        summary: "Bring stream chat highlights into voice.",
        symbol: "dot.radiowaves.left.and.right",
        tint: .blue,
        channels: ["stream", "clips"],
        events: ["Highlights", "Links"],
        enabled: false
    ),
    AnnouncerPreset(
        id: "swiftminer",
        name: "SwiftMiner",
        command: "/announce rigs",
        summary: "Read important rig and pool status changes.",
        symbol: "pickaxe",
        tint: .orange,
        channels: ["swiftminer"],
        events: ["Alerts", "Status"],
        enabled: true
    ),
    AnnouncerPreset(
        id: "patchy-ai",
        name: "Patchy AI",
        command: "/announce patchy",
        summary: "Patch and release notes in a quieter voice.",
        symbol: "sparkles",
        tint: .indigo,
        channels: ["patchy", "updates"],
        events: ["Releases", "Summaries"],
        enabled: false
    )
]

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

private struct DisabledSourceRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: .constant(false))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(true)
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
