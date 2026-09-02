import Foundation

// MARK: - Ingest

extension AppModel {
    /// Archives one guild message.
    ///
    /// Called from `handleMessageCreate` above the bot guard and above every
    /// early return in that handler, so `includeBotMessages` can actually see
    /// bot traffic and a watched music link or an AI reply path can't silently
    /// drop a message from the archive.
    ///
    /// DMs are never archived. Rewind is a picture of the server, and a DM is
    /// not part of it.
    func recordRewindMessage(event: GatewayMessageCreateEvent, isDirectMessage: Bool) {
        guard !isDirectMessage, let guildID = event.guildID, !guildID.isEmpty else { return }

        let settings = self.settings.rewind
        guard settings.collects(channelID: event.channelID) else { return }
        guard settings.collects(userID: event.userID, isBot: event.isBot) else { return }

        // Nothing to count and nothing to store — an attachment-only post.
        guard !event.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let authorName = event.displayName.isEmpty ? event.username : event.displayName
        let message = RewindMessage(
            id: event.messageID,
            guildID: guildID,
            channelID: event.channelID,
            authorID: event.userID,
            authorName: authorName,
            isBot: event.isBot,
            content: event.content,
            // Snowflake rather than the payload's `timestamp` string, so live
            // ingest and the REST backfill derive the date the same way.
            createdAt: DiscordService.messageCreatedDate(fromSnowflake: event.messageID) ?? Date()
        )

        let retainContent = settings.retainMessageContent
        let store = rewindStore
        Task.detached(priority: .utility) {
            await store.record(message, retainContent: retainContent)
        }
    }

    /// Starts the archive's periodic flush and its retention sweep. Called from
    /// bot startup.
    func startRewindIfNeeded() {
        guard settings.rewind.isEnabled else { return }

        let store = rewindStore
        let excludeFromBackups = settings.rewind.excludeFromBackups
        Task.detached(priority: .utility) {
            await store.setBackupExclusion(excludeFromBackups)
            await store.start()
        }

        guard rewindRetentionTask == nil else { return }
        let retentionDays = settings.rewind.retentionDays
        guard retentionDays > 0 else { return }

        rewindRetentionTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.rewindStore.applyRetention(days: retentionDays)
                try? await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000)
            }
        }
    }

    /// Applies the backup-exclusion toggle without waiting for a bot restart.
    func applyRewindBackupExclusion() {
        let store = rewindStore
        let excluded = settings.rewind.excludeFromBackups
        Task.detached(priority: .utility) {
            await store.setBackupExclusion(excluded)
        }
    }

    func stopRewind() async {
        rewindRetentionTask?.cancel()
        rewindRetentionTask = nil
        rewindBackfillTask?.cancel()
        rewindBackfillTask = nil
        await rewindStore.stop()
    }
}

// MARK: - Slash command

extension AppModel {
    /// Backs `/rewind` — how often a word or phrase has been said, and who says
    /// it most. Returns an embed so the caller can hand it straight to the
    /// deferred interaction response.
    func rewindCommand(
        query: String,
        raw: [String: DiscordJSON]
    ) async -> (ok: Bool, message: String, embed: [String: Any]?) {
        guard settings.rewind.isEnabled else {
            return (false, "Rewind is switched off. Turn it on in SwiftBot under Rewind.", nil)
        }
        guard settings.rewind.retainMessageContent else {
            return (
                false,
                "Rewind is only keeping counts right now. Switch on “Keep message text” in SwiftBot to count phrases.",
                nil
            )
        }
        guard let guildID = guildId(from: raw) else {
            return (false, "`/rewind` only works inside a server.", nil)
        }
        if settings.rewind.restrictToAdmins, !(await canRunDebugCommand(raw: raw)) {
            return (false, "⛔ `/rewind` is restricted to server admins on this server.", nil)
        }

        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else {
            return (false, "Give me a word or phrase to count — `/rewind query:gg guys`.", nil)
        }

        // Anything reading the archive should see writes buffered up to now.
        await rewindStore.flush()

        // Everything on record. Discord's epoch is 2015, so this covers any
        // message the bot could possibly hold.
        let report = await rewindStore.phraseReport(
            guildID: guildID,
            phrase: phrase,
            start: Date(timeIntervalSince1970: 1_420_070_400),
            end: Date()
        )

        guard report.totalOccurrences > 0 else {
            return (
                true,
                "",
                rewindEmbed(
                    title: "“\(phrase)”",
                    description: "Never said here. Searched \(rewindNumber(report.scannedMessages)) messages.",
                    fields: []
                )
            )
        }

        var fields: [[String: Any]] = []

        let plural = report.totalOccurrences == 1 ? "time" : "times"
        var headline = "**\(rewindNumber(report.totalOccurrences))** \(plural)"
        headline += " across \(rewindNumber(report.messageCount)) message"
        headline += report.messageCount == 1 ? "" : "s"
        headline += " — out of \(rewindNumber(report.scannedMessages)) searched."
        fields.append(["name": "Said", "value": headline, "inline": false])

        if !report.byUser.isEmpty {
            let lines = report.byUser.prefix(5).enumerated().map { index, entry in
                "\(rewindMedal(index)) **\(entry.userName)** — \(rewindNumber(entry.count))"
            }
            fields.append(["name": "Who says it", "value": lines.joined(separator: "\n"), "inline": false])
        }

        if let first = report.firstSeen, let last = report.lastSeen {
            let value = "First: <t:\(Int(first.timeIntervalSince1970)):D>\nLatest: <t:\(Int(last.timeIntervalSince1970)):D>"
            fields.append(["name": "Span", "value": value, "inline": true])
        }

        if let channelID = report.topChannelID {
            let name = await discordCache.channelName(for: channelID) ?? "channel"
            fields.append(["name": "Home channel", "value": "#\(name)", "inline": true])
        }

        if let peak = report.byMonth.max(by: { $0.count < $1.count }), report.byMonth.count > 1 {
            fields.append([
                "name": "Peak month",
                "value": "\(rewindMonthName(peak.term)) — \(rewindNumber(peak.count))",
                "inline": true
            ])
        }

        return (true, "", rewindEmbed(title: "“\(phrase)”", description: nil, fields: fields))
    }

    // MARK: Formatting

    private func rewindEmbed(title: String, description: String?, fields: [[String: Any]]) -> [String: Any] {
        var embed: [String: Any] = [
            "title": String(title.prefix(256)),
            "color": 10_181_046
        ]
        if let description, !description.isEmpty {
            embed["description"] = String(description.prefix(4_000))
        }
        if !fields.isEmpty {
            embed["fields"] = Array(fields.prefix(25))
        }
        return embed
    }

    private func rewindMedal(_ index: Int) -> String {
        switch index {
        case 0: return "🥇"
        case 1: return "🥈"
        case 2: return "🥉"
        default: return "`\(index + 1).`"
        }
    }

    private func rewindMonthName(_ monthKey: String) -> String {
        guard let date = RewindCalendar.monthFormatter.date(from: monthKey) else { return monthKey }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    func rewindNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    func rewindBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Historical backfill

extension AppModel {
    /// Walks every readable text channel in a guild back through its history and
    /// imports what Rewind missed.
    ///
    /// Discord serves 100 messages per request and the walk staggers pages, so
    /// this is a background job measured in tens of minutes per channel-year,
    /// not a command that returns. Progress lands in `rewindBackfillProgress`.
    /// Re-running tops up rather than duplicating — the store skips message IDs
    /// it already holds.
    func startRewindBackfill(guildID: String, maxMessagesPerChannel: Int = 200_000) {
        guard rewindBackfillTask == nil else {
            logs.append("⚠️ Rewind backfill already running.")
            return
        }
        guard settings.rewind.isEnabled, settings.rewind.retainMessageContent else {
            logs.append("⚠️ Rewind backfill needs archiving and message retention switched on.")
            return
        }

        let channels = availableTextChannelsByServer[guildID] ?? []
        guard !channels.isEmpty else {
            logs.append("⚠️ Rewind backfill: no known text channels for that server.")
            return
        }

        let guildName = connectedServers[guildID] ?? guildID
        rewindBackfillProgress = RewindBackfillProgress(
            guildID: guildID,
            guildName: guildName,
            channelsTotal: channels.count,
            channelsCompleted: 0,
            currentChannelName: channels.first?.name ?? "",
            messagesImported: 0,
            messagesScanned: 0,
            startedAt: Date()
        )

        let includeBots = settings.rewind.includeBotMessages
        let optedOut = settings.rewind.optedOutUserIDs
        let ignoredChannels = settings.rewind.ignoredChannelIDs

        rewindBackfillTask = Task { [weak self] in
            guard let self else { return }

            for channel in channels {
                if Task.isCancelled { break }
                guard !ignoredChannels.contains(channel.id) else {
                    self.advanceRewindBackfillChannel(name: channel.name)
                    continue
                }

                self.rewindBackfillProgress?.currentChannelName = channel.name

                var cursor: String?
                var pulled = 0

                while pulled < maxMessagesPerChannel {
                    if Task.isCancelled { break }

                    let page: (messages: [RewindMessage], nextCursor: String?)
                    do {
                        page = try await self.service.rewindFetchMessagePage(
                            guildId: guildID,
                            channelId: channel.id,
                            limit: 100,
                            before: cursor
                        )
                    } catch {
                        // A channel the bot can't read is normal, not fatal.
                        self.rewindBackfillProgress?.lastError =
                            "#\(channel.name): \(error.localizedDescription)"
                        break
                    }

                    guard !page.messages.isEmpty else { break }
                    pulled += page.messages.count

                    let keep = page.messages.filter { message in
                        if message.isBot && !includeBots { return false }
                        if optedOut.contains(message.authorID) { return false }
                        return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }

                    let imported = await self.rewindStore.importMessages(keep, retainContent: true)
                    self.rewindBackfillProgress?.messagesImported += imported
                    self.rewindBackfillProgress?.messagesScanned += page.messages.count

                    guard let next = page.nextCursor else { break }
                    cursor = next

                    // Same stagger Sweep uses, to stay polite with the API.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }

                self.advanceRewindBackfillChannel(name: channel.name)
            }

            await self.rewindStore.flush()
            self.rewindBackfillProgress?.finishedAt = Date()
            self.rewindBackfillProgress?.isCancelled = Task.isCancelled
            self.rewindBackfillTask = nil
            let imported = self.rewindBackfillProgress?.messagesImported ?? 0
            self.logs.append("✅ Rewind backfill finished — imported \(imported) messages.")
        }
    }

    func cancelRewindBackfill() {
        rewindBackfillTask?.cancel()
        rewindBackfillTask = nil
        rewindBackfillProgress?.isCancelled = true
        rewindBackfillProgress?.finishedAt = Date()
    }

    private func advanceRewindBackfillChannel(name: String) {
        rewindBackfillProgress?.channelsCompleted += 1
        rewindBackfillProgress?.currentChannelName = name
    }
}
