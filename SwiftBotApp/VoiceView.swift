import AVFoundation
import SwiftUI

struct VoiceView: View {
    @EnvironmentObject var app: AppModel

    @State private var selectedGuild: String = ""
    @State private var selectedVoiceChannel: String = ""
    @State private var selectedTextChannel: String = ""
    @State private var selectedVoiceIdentifier: String = ""
    @State private var textChannelSourceEnabled: Bool = false
    @State private var testText: String = "Hello from SwiftBot."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                daveBlockedBanner
                metricTileRow
                SwiftMeshSection(title: "Connection", symbol: "antenna.radiowaves.left.and.right") {
                    connectionPanel
                }
                SwiftMeshSection(title: "Announcement Sources", symbol: "bell.badge") {
                    sourcesPanel
                }
                SwiftMeshSection(title: "Voice & Speech", symbol: "waveform") {
                    voiceSettingsPanel
                }
                SwiftMeshSection(title: "Recent Announcements", symbol: "text.bubble") {
                    PlaceholderPanelLine(text: "Spoken announcements will appear here as the bot reads them aloud.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .onAppear { syncFromSettings() }
        .onChange(of: app.settings.voice) { _, _ in syncFromSettings() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Voice")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
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

    private var daveBlockedBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice playback is paused")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "Discord enforced their DAVE end-to-end encryption " +
                    "protocol on March 2, 2026. Third-party bots can no " +
                    "longer connect to regular voice channels without a " +
                    "Swift MLS / DAVE implementation, which doesn't exist " +
                    "yet. The full pipeline (WS, UDP, RTP, Opus, AES-GCM) " +
                    "is built and waiting; only the encryption layer needs " +
                    "swapping. Use **Preview on Mac** below to audition " +
                    "voices in the meantime."
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
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            DashboardMetricCard(
                title: "Status",
                value: app.voiceConnectionStatus.displayLabel,
                subtitle: app.voiceConnectionStatus.failureReason ?? subtitleForStatus,
                symbol: "dot.radiowaves.left.and.right",
                color: statusColor
            )
            DashboardMetricCard(
                title: "Voice Channel",
                value: voiceChannelDisplayName(for: app.settings.voice.voiceChannelID).ifEmpty("—"),
                subtitle: app.connectedServers[app.settings.voice.guildID] ?? "Pick a server",
                symbol: "speaker.wave.2.fill",
                color: .blue
            )
            DashboardMetricCard(
                title: "Active Source",
                value: app.settings.voice.textChannelSourceEnabled ? "Text channel" : "None",
                subtitle: app.settings.voice.textChannelSourceEnabled
                    ? "#\(textChannelDisplayName(for: app.settings.voice.watchedTextChannelID).ifEmpty("—"))"
                    : "No source enabled",
                symbol: app.settings.voice.textChannelSourceEnabled ? "text.bubble.fill" : "bell.slash",
                color: app.settings.voice.textChannelSourceEnabled ? .purple : .orange
            )
            DashboardMetricCard(
                title: "Preferred Voice",
                value: preferredVoiceDisplayName,
                subtitle: "AVSpeechSynthesizer",
                symbol: "waveform.circle.fill",
                color: .pink
            )
        }
    }

    private var subtitleForStatus: String {
        switch app.voiceConnectionStatus {
        case .idle: return "Not in a voice channel"
        case .connecting: return "Negotiating WS + UDP"
        case .connected: return "Ready to speak"
        case .disconnecting: return "Tearing down"
        case .failed: return "—"
        }
    }

    // MARK: - Connection panel

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                pickerField(label: "Server", selection: $selectedGuild, options: serverOptions) { newValue in
                    app.settings.voice.guildID = newValue
                    selectedVoiceChannel = ""
                    selectedTextChannel = ""
                }
                pickerField(label: "Voice Channel", selection: $selectedVoiceChannel, options: voiceChannelOptions) { newValue in
                    app.settings.voice.voiceChannelID = newValue
                }
                .disabled(selectedGuild.isEmpty)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await app.connectVoice() }
                } label: {
                    Label("Join (blocked: DAVE required)", systemImage: "lock.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)

                Button {
                    Task { await app.disconnectVoice() }
                } label: {
                    Label("Leave", systemImage: "phone.down.fill")
                }
                .disabled(app.voiceConnectionStatus == .idle)

                Spacer()
            }

            Text(
                "Discord requires the DAVE end-to-end encryption protocol " +
                "on regular voice channels as of March 2, 2026. SwiftBot's " +
                "WS/UDP/RTP/Opus pipeline is built and tested up to the " +
                "encryption negotiation; we're waiting on a Swift MLS " +
                "implementation (or a libdave wrapper) before this can be " +
                "enabled."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectButtonTitle: String {
        switch app.voiceConnectionStatus {
        case .connected: return "Reconnect"
        case .connecting: return "Connecting\u{2026}"
        default: return "Join Voice Channel"
        }
    }

    private var canConnect: Bool {
        !selectedGuild.isEmpty &&
        !selectedVoiceChannel.isEmpty &&
        app.voiceConnectionStatus != .connecting
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
                    .disabled(true)
                    .help("Disabled until DAVE support lands — no voice channel to read into.")
            }

            pickerField(label: "Text Channel", selection: $selectedTextChannel, options: textChannelOptions) { newValue in
                Task { await app.setWatchedTextChannelForAnnouncer(newValue) }
            }
            .disabled(true)

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
                Text("Preview plays through this Mac's speakers using the selected voice — no Discord connection needed. Speak in Discord is blocked until DAVE support lands.")
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
            HStack(spacing: 12) {
                pickerField(label: "Voice", selection: $selectedVoiceIdentifier, options: voiceOptions) { newValue in
                    Task { await app.setPreferredAnnouncerVoice(newValue) }
                }
            }
            Text("English voices on this Mac, grouped Premium → Enhanced → Default. Empty means “best Premium English voice available.”")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        let standard = englishVoices.filter { $0.quality == .default }
        for v in premium {
            options.append(PickerOption(id: v.identifier, label: "\(v.name) (Premium · \(v.language))"))
        }
        for v in enhanced {
            options.append(PickerOption(id: v.identifier, label: "\(v.name) (Enhanced · \(v.language))"))
        }
        for v in standard {
            options.append(PickerOption(id: v.identifier, label: "\(v.name) (\(v.language))"))
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
        selection: Binding<String>,
        options: [PickerOption],
        onChange: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
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
