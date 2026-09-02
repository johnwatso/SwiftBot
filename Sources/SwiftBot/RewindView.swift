import SwiftUI

/// The Rewind tab — the server's message archive and the year in review it
/// feeds. Laid out like `AutomationsView`: metric tiles on top, then
/// `AutomationsSection` cards.
///
/// This screen is the only place collection can be switched on. `isEnabled`
/// ships off, so the archive stays empty until whoever runs the bot opts in
/// here.
struct RewindView: View {
    @EnvironmentObject private var app: AppModel

    @State private var stats = RewindArchiveStats.empty
    @State private var selectedGuildID = ""
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    @State private var availableYears: [Int] = []
    @State private var summary: RewindYearSummary?
    @State private var phrase = ""
    @State private var phraseReport: RewindPhraseReport?
    @State private var isSearching = false
    @State private var showingDeleteConfirmation = false

    private var servers: [(id: String, name: String)] {
        app.connectedServers
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var settings: RewindSettings { app.settings.rewind }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)

            if app.forwardsConfigEditsToPrimary {
                PreferencesSyncsToPrimaryBanner(text: "Editing as Failover — changes are pushed to the Primary and sync back.")
                    .padding(.horizontal, 16)
            } else if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. Rewind settings sync from Primary.")
                    .padding(.horizontal, 16)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    metricTileRow
                    collectionSection
                    phraseSection
                    yearSection
                    archiveSection
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
        .task {
            if selectedGuildID.isEmpty { selectedGuildID = servers.first?.id ?? "" }
            await refresh()
        }
        .onChange(of: selectedGuildID) { _, _ in Task { await refresh() } }
        .onChange(of: selectedYear) { _, _ in Task { await loadSummary() } }
        .onChange(of: settings.excludeFromBackups) { _, _ in
            app.applyRewindBackupExclusion()
        }
        .onChange(of: settings.isEnabled) { _, isEnabled in
            // Picked up mid-session, so the archive's periodic flush and
            // retention sweep start without a bot restart.
            if isEnabled { app.startRewindIfNeeded() }
        }
        .task(id: settings) {
            try? await Task.sleep(for: .milliseconds(400))
            // `saveSettings()` accepts one write per 3 seconds and silently
            // drops anything inside that window, so re-offer the change until
            // one attempt lands outside it. Repeats are free: the save is a
            // no-op once the persisted snapshot matches.
            for _ in 0..<4 {
                guard !Task.isCancelled else { return }
                app.saveSettings()
                try? await Task.sleep(for: .seconds(1.6))
            }
        }
        .confirmationDialog(
            "Delete the entire Rewind archive?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                Task {
                    await app.rewindStore.deleteAll()
                    phraseReport = nil
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every archived message and every counter is removed from this Mac. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            ViewSectionHeader(title: "Rewind", symbol: "arrow.counterclockwise.circle.fill")
            Spacer()
            if !settings.isEnabled {
                Label("Not collecting", systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !settings.retainMessageContent {
                Label("Counts only", systemImage: "number.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Phrase lookups need message text kept.")
            }
        }
    }

    // MARK: - Metric tiles

    private var metricTileRow: some View {
        LazyVGrid(columns: DashboardMetricGrid.columns, spacing: DashboardMetricGrid.spacing) {
            ForEach(metrics) { metric in
                DashboardMetricCard(metric: metric)
            }
        }
    }

    private var metrics: [DashboardMetricDescriptor] {
        let coverage: String = {
            guard let earliest = stats.earliestDay, let latest = stats.latestDay else {
                return "Nothing archived yet"
            }
            return "\(earliest) → \(latest)"
        }()

        return [
            DashboardMetricDescriptor(
                id: "rewind-messages",
                title: "Messages Archived",
                value: app.rewindNumber(stats.messageCount),
                subtitle: coverage,
                symbol: "tray.full.fill",
                detail: stats.guildCount > 0 ? "\(stats.guildCount) server(s)" : "",
                color: .purple
            ),
            DashboardMetricDescriptor(
                id: "rewind-disk",
                title: "On Disk",
                value: app.rewindBytes(stats.diskBytes),
                subtitle: settings.retainMessageContent ? "Message text kept" : "Counts only",
                symbol: "internaldrive.fill",
                detail: settings.retentionDays > 0 ? "Kept \(settings.retentionDays) days" : "Kept forever",
                color: .blue
            ),
            DashboardMetricDescriptor(
                id: "rewind-collection",
                title: "Collection",
                value: settings.isEnabled ? "On" : "Off",
                subtitle: settings.includeBotMessages ? "Members and bots" : "Members only",
                symbol: "dot.radiowaves.left.and.right",
                detail: settings.optedOutUserIDs.isEmpty ? "" : "\(settings.optedOutUserIDs.count) opted out",
                color: settings.isEnabled ? .green : .secondary
            ),
            DashboardMetricDescriptor(
                id: "rewind-year",
                title: "This Year",
                value: app.rewindNumber(summary?.totalMessages ?? 0),
                subtitle: summary.map { "\($0.activeDays) active days" } ?? "No data yet",
                symbol: "calendar",
                detail: summary?.busiestDay.map { "Peak \($0.day)" } ?? "",
                color: .orange
            )
        ]
    }

    // MARK: - Collection

    private var collectionSection: some View {
        AutomationsSection(title: "Collection", symbol: "dot.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 10) {
                settingRow(
                    title: "Archive server messages",
                    detail: "Stores messages from server channels so Rewind can count words, phrases and people. Direct messages are never archived.",
                    isOn: $app.settings.rewind.isEnabled,
                    requiresCollection: false
                )

                Divider().padding(.vertical, 1)

                settingRow(
                    title: "Keep message text",
                    detail: settings.retainMessageContent
                        ? "Any phrase can be counted later — including one you only think to ask about at the end of the year."
                        : "Leaderboards and top words still work, but a specific phrase can't be looked up after the fact.",
                    isOn: $app.settings.rewind.retainMessageContent
                )

                settingRow(
                    title: "Include messages from bots",
                    detail: "Off by default — bot output would otherwise dominate every word count.",
                    isOn: $app.settings.rewind.includeBotMessages
                )

                settingRow(
                    title: "Filter common words",
                    detail: "Drops “the”, “and”, “a” from top-word lists. Phrase searches always match literally.",
                    isOn: $app.settings.rewind.filterStopWords
                )

                settingRow(
                    title: "Restrict /rewind to admins",
                    detail: "Otherwise anyone in the server can count a word or phrase.",
                    isOn: $app.settings.rewind.restrictToAdmins
                )

                settingRow(
                    title: "Keep out of backups",
                    detail: app.settings.rewind.excludeFromBackups
                        ? "Time Machine won't copy the archive. A backup target is usually less protected than this Mac — but the archive can't be restored after a disk failure."
                        : "Time Machine will copy the archive to whatever this Mac backs up to.",
                    isOn: $app.settings.rewind.excludeFromBackups
                )

                Divider().padding(.vertical, 1)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep message text for")
                            .font(.subheadline.weight(.medium))
                        Text(settings.retentionDays > 0
                            ? "Counters are never trimmed, so the yearly card survives."
                            : "0 keeps everything — the point of a year-end rewind.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("0", value: $app.settings.rewind.retentionDays, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Text("days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .modifier(RewindRowChrome())
                .disabled(!settings.isEnabled)

                if !settings.optedOutUserIDs.isEmpty {
                    HStack {
                        Label(
                            "\(settings.optedOutUserIDs.count) member(s) opted out of Rewind",
                            systemImage: "person.crop.circle.badge.minus"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear list") {
                            app.settings.rewind.optedOutUserIDs.removeAll()
                            app.saveSettings()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .modifier(RewindRowChrome())
                }
            }
        }
    }

    // MARK: - Phrase search

    private var phraseSection: some View {
        AutomationsSection(title: "Count a phrase", symbol: "text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("e.g. gg guys", text: $phrase)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await search() } }
                    Button("Count") { Task { await search() } }
                        .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }

                scopePickers

                if !settings.retainMessageContent {
                    Label("Phrase counting needs “Keep message text” switched on.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if isSearching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Scanning the archive…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let report = phraseReport {
                    phraseResults(report)
                } else {
                    Text("Counts every time a word or phrase was used, and who used it most. Matching ignores case and punctuation, so “GG guys!” and “gg guys” are the same phrase.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func phraseResults(_ report: RewindPhraseReport) -> some View {
        if report.totalOccurrences == 0 {
            Text("Never said. Searched \(app.rewindNumber(report.scannedMessages)) messages.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(app.rewindNumber(report.totalOccurrences))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(report.totalOccurrences == 1 ? "time" : "times")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("across \(app.rewindNumber(report.messageCount)) of \(app.rewindNumber(report.scannedMessages)) messages")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 2)

                ForEach(Array(report.byUser.prefix(5).enumerated()), id: \.element.id) { index, entry in
                    rankedRow(rank: index + 1, label: entry.userName, value: app.rewindNumber(entry.count))
                }

                if let sample = report.sampleMessage {
                    Text("“\(sample.content)”")
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Year in review

    private var yearSection: some View {
        AutomationsSection(title: "Year in review", symbol: "sparkles") {
            if let summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        rankedColumn(
                            "Most talkative",
                            summary.topUsers.prefix(5).map { ($0.userName, $0.count) }
                        )
                        rankedColumn(
                            "Top words",
                            summary.topWords.prefix(5).map { ($0.term, $0.count) }
                        )
                        rankedColumn(
                            "Top phrases",
                            summary.topBigrams.prefix(5).map { ($0.term, $0.count) }
                        )
                    }

                    if !summary.topEmoji.isEmpty {
                        Divider().padding(.vertical, 1)
                        HStack(spacing: 12) {
                            ForEach(summary.topEmoji.prefix(8)) { entry in
                                VStack(spacing: 2) {
                                    Text(entry.term).font(.title3)
                                    Text(app.rewindNumber(entry.count))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            } else {
                Text(settings.isEnabled
                    ? "Nothing recorded for \(String(selectedYear)) yet. Leave the bot running, or import history below."
                    : "Switch on “Archive server messages” to start building a rewind.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Archive + import

    private var archiveSection: some View {
        AutomationsSection(title: "Archive", symbol: "internaldrive") {
            VStack(alignment: .leading, spacing: 8) {
                if let progress = app.rewindBackfillProgress, progress.isRunning {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: progress.fractionComplete)
                        HStack {
                            Text("#\(progress.currentChannelName)")
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(progress.channelsCompleted)/\(progress.channelsTotal) channels")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text("\(app.rewindNumber(progress.messagesImported)) imported of \(app.rewindNumber(progress.messagesScanned)) scanned")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let error = progress.lastError {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .modifier(RewindRowChrome())
                } else {
                    Text(
                        "Importing walks every readable channel back through its history. Discord serves 100 "
                            + "messages per request with a pause between pages, so a busy year takes tens of "
                            + "minutes. Re-running tops up rather than duplicating."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let progress = app.rewindBackfillProgress {
                        Label(
                            "Last import: \(app.rewindNumber(progress.messagesImported)) messages",
                            systemImage: "checkmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Divider().padding(.vertical, 2)

                HStack(spacing: 10) {
                    if let progress = app.rewindBackfillProgress, progress.isRunning {
                        Button {
                            app.cancelRewindBackfill()
                        } label: {
                            Label("Stop import", systemImage: "stop.circle")
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            app.startRewindBackfill(guildID: selectedGuildID)
                        } label: {
                            Label("Import history", systemImage: "clock.arrow.circlepath")
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canImport)
                        .help(importHelp)
                    }

                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete archive", systemImage: "trash")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(stats.messageCount == 0)
                }
            }
        }
    }

    private var canImport: Bool {
        !selectedGuildID.isEmpty
            && settings.isEnabled
            && settings.retainMessageContent
            && app.status == .running
    }

    private var importHelp: String {
        if app.status != .running { return "Start the bot first." }
        if !settings.isEnabled { return "Switch on archiving first." }
        if !settings.retainMessageContent { return "Importing needs message text kept." }
        return "Walk this server's channel history into the archive."
    }

    // MARK: - Pieces

    private var scopePickers: some View {
        HStack(spacing: 8) {
            Picker("Server", selection: $selectedGuildID) {
                ForEach(servers, id: \.id) { server in
                    Text(server.name).tag(server.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(servers.isEmpty)

            Picker("Year", selection: $selectedYear) {
                ForEach(availableYears, id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            .disabled(availableYears.isEmpty)

            Spacer()
        }
    }

    /// `requiresCollection` is false only for the master switch, which has to
    /// stay live so collection can be turned back on.
    private func settingRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        requiresCollection: Bool = true
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .modifier(RewindRowChrome())
        .disabled(requiresCollection && !settings.isEnabled)
        .opacity(requiresCollection && !settings.isEnabled ? 0.55 : 1)
    }

    private func rankedRow(rank: Int, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(label)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(RewindRowChrome())
    }

    private func rankedColumn(_ title: String, _ entries: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("--")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    rankedRow(rank: index + 1, label: entry.0, value: app.rewindNumber(entry.1))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    private func refresh() async {
        stats = await app.rewindStore.archiveStats()
        guard !selectedGuildID.isEmpty else {
            availableYears = []
            summary = nil
            return
        }

        let years = await app.rewindStore.availableYears(guildID: selectedGuildID)
        availableYears = years.isEmpty ? [Calendar.current.component(.year, from: Date())] : years
        if !availableYears.contains(selectedYear) {
            selectedYear = availableYears.first ?? selectedYear
        }
        await loadSummary()
    }

    private func loadSummary() async {
        guard !selectedGuildID.isEmpty else {
            summary = nil
            return
        }
        summary = await app.rewindStore.yearSummary(
            guildID: selectedGuildID,
            year: selectedYear,
            filterStopWords: settings.filterStopWords
        )
    }

    private func search() async {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !selectedGuildID.isEmpty else { return }

        isSearching = true
        defer { isSearching = false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let start = calendar.date(from: DateComponents(year: selectedYear, month: 1, day: 1)) ?? Date()
        let end = calendar.date(from: DateComponents(year: selectedYear + 1, month: 1, day: 1))?
            .addingTimeInterval(-1) ?? Date()

        await app.rewindStore.flush()
        phraseReport = await app.rewindStore.phraseReport(
            guildID: selectedGuildID,
            phrase: trimmed,
            start: start,
            end: end
        )
    }
}

/// The inset-row chrome shared by `AutomationsView`'s rule rows, so Rewind's
/// rows sit at the same depth inside an `AutomationsSection`.
private struct RewindRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}
