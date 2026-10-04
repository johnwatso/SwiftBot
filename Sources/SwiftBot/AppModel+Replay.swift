import Foundation

// MARK: - Replay
//
// Apple-Music-Replay-style recaps for a server: built from the Rewind message
// archive plus voice sessions, community stats, Game Tracker and recordings.
// Shown on the WebUI's Rewind page, posted to Discord as recap drops, and
// privately to each member through `/replay`.

extension AppModel {

    // MARK: Building

    func serverReplay(guildID: String, period: ReplayPeriod, includeText: Bool, now: Date = Date()) async -> ServerReplay {
        await rewindStore.flush()
        let interval = period.interval(now: now)
        let buckets = period.buckets()
        let isOnlyGuild = connectedServers.count <= 1

        async let messages = rewindStore.rangeSummary(
            guildID: guildID, start: interval.start, end: interval.end, buckets: buckets,
            excludingUsers: [], filterStopWords: settings.rewind.filterStopWords
        )
        async let voice = voiceSessionStore.report(
            window: interval, buckets: buckets, previous: nil,
            guildId: guildID, excludingUsers: [], now: now, topLimit: 5
        )
        async let community = communityStatsStore.summary(buckets: buckets, in: interval)
        async let ranks = communityStatsStore.rankHistory(since: interval.start)
        let m = await messages
        let v = await voice

        var replay = ServerReplay(
            guildID: guildID,
            guildName: connectedServers[guildID] ?? "Server",
            periodKey: period.key,
            periodTitle: period.title(),
            isYear: period.isYear,
            isComplete: interval.end < now.addingTimeInterval(-60)
        )
        replay.messages = m.totalMessages
        replay.words = m.totalWords
        replay.activeDays = m.activeDays
        replay.chattingMembers = m.memberCount
        replay.busiestDay = m.busiestDay?.day
        replay.busiestDayMessages = m.busiestDay?.count ?? 0
        replay.peakHour = m.peakHour
        replay.hourly = m.hourly
        replay.timeline = buckets.indices.map { index in
            ServerReplay.Bucket(
                label: buckets[index].label,
                messages: m.bucketCounts[index],
                voiceMinutes: v.buckets.indices.contains(index) ? v.buckets[index].seconds / 60 : 0
            )
        }
        replay.topMembers = m.topUsers.prefix(10).map {
            .init(title: replayName(userID: $0.userID, fallback: $0.userName), count: $0.count, id: $0.userID)
        }
        if includeText {
            let signatures = await rewindStore.signatures(
                guildID: guildID, userIDs: Set(replay.topMembers.compactMap(\.id)), start: interval.start, end: interval.end
            )
            for index in replay.topMembers.indices {
                replay.topMembers[index].signature = replay.topMembers[index].id.flatMap { signatures[$0]?.words.first?.term }
            }
        }
        replay.topChannels = m.topChannels.map { .init(title: "#\(replayChannelName(guildID: guildID, channelID: $0.term))", count: $0.count) }
        if includeText {
            replay.topWords = m.topWords.map { .init(title: $0.term, count: $0.count, note: Self.replayTermNote($0)) }
            replay.topPhrases = m.topBigrams.map { .init(title: $0.term, count: $0.count, note: Self.replayTermNote($0)) }
            replay.wordsAreDistinctive = m.termsAreDistinctive
            replay.topEmoji = m.topEmoji.map { .init(title: $0.term, count: $0.count) }
        }

        replay.voiceSeconds = v.totalSeconds
        replay.voiceSessions = v.sessionCount
        replay.topVoiceMembers = v.topUsers.map { .init(title: replayName(userID: $0.userId, fallback: $0.username), count: $0.seconds, id: $0.userId) }
        replay.topVoiceChannels = v.channels.map { .init(title: $0.name, count: $0.seconds) }

        if isOnlyGuild {
            let c = await community
            replay.commands = c.commandCount
            replay.topCommands = c.commands.sorted { $0.value > $1.value }.prefix(5).map { .init(title: $0.key, count: $0.value) }
            replay.joins = c.joins
            replay.leaves = c.leaves
            replay.rankChanges = await ranks.values.compactMap { series in
                guard let first = series.points.first, let last = series.points.last, first != last else { return nil }
                return .init(name: series.displayName, game: series.game, from: first.score, to: last.score, rankName: last.rankName)
            }.sorted { ($0.to - $0.from) > ($1.to - $1.from) }
            let library = await localMediaLibrarySnapshot()
            let clips = Dictionary(grouping: library.items.filter { interval.contains($0.modifiedAt) }) { mediaGameName(for: $0.fileName) }
            replay.clipsByGame = clips.map { .init(title: $0.key, count: $0.value.count) }.sorted { $0.count > $1.count }.prefix(5).map { $0 }
        }
        return replay
    }

    func personalReplay(guildID: String, userID: String, period: ReplayPeriod, now: Date = Date()) async -> PersonalReplay {
        await rewindStore.flush()
        let interval = period.interval(now: now)
        var replay = PersonalReplay(
            guildID: guildID,
            guildName: connectedServers[guildID] ?? "Server",
            userID: userID,
            name: replayName(userID: userID, fallback: "Member"),
            periodKey: period.key,
            periodTitle: period.title()
        )
        let messages = await rewindStore.userRangeSummary(guildID: guildID, userID: userID, start: interval.start, end: interval.end, excludingUsers: [])
        let voice = await voiceSessionStore.userReport(userId: userID, guildId: guildID, window: interval, now: now)
        let voiceRanking = await voiceSessionStore.report(
            window: interval, buckets: [], previous: nil, guildId: guildID,
            excludingUsers: [], now: now, topLimit: 1_000
        ).topUsers
        if replay.name == "Member", let name = messages.userName { replay.name = name }
        replay.messages = messages.messages
        replay.words = messages.words
        replay.activeDays = messages.activeDays
        replay.busiestDay = messages.busiestDay?.day
        replay.busiestDayMessages = messages.busiestDay?.count ?? 0
        replay.rank = messages.rank
        replay.rankedMembers = messages.rankedMembers
        replay.voiceSeconds = voice.seconds
        replay.voiceSessions = voice.sessions
        replay.longestSessionSeconds = voice.longestSessionSeconds
        replay.favouriteVoiceChannel = voice.favouriteChannel
        replay.voiceRank = voiceRanking.firstIndex { $0.userId == userID }.map { $0 + 1 }
        if let signature = await rewindStore.signatures(guildID: guildID, userIDs: [userID], start: interval.start, end: interval.end)[userID] {
            replay.signatureWords = signature.words.map { .init(title: $0.term, count: $0.count, note: Self.replaySignatureNote($0)) }
            replay.signaturePhrases = signature.phrases.map { .init(title: $0.term, count: $0.count, note: Self.replaySignatureNote($0)) }
        }
        let previous = period.previous
        let previousInterval = previous.interval(now: now)
        replay.previousPeriodTitle = previous.title()
        replay.previousMessages = await rewindStore.userRangeSummary(
            guildID: guildID, userID: userID, start: previousInterval.start, end: previousInterval.end, excludingUsers: []
        ).messages
        replay.previousVoiceSeconds = await voiceSessionStore.userReport(userId: userID, guildId: guildID, window: previousInterval, now: now).seconds
        if connectedServers.count <= 1 {
            let summary = await communityStatsStore.summary(buckets: [], in: interval)
            let keys = Set([userID, replay.name, knownRawUsernamesById[userID] ?? ""].filter { !$0.isEmpty })
            replay.commands = summary.users.filter { keys.contains($0.key) }.values.reduce(0, +)
        }
        return replay
    }

    private func replayName(userID: String, fallback: String) -> String {
        if let name = knownUsersById[userID], !name.isEmpty { return name }
        return fallback
    }

    private func replayChannelName(guildID: String, channelID: String) -> String {
        availableTextChannelsByServer[guildID]?.first { $0.id == channelID }?.name
            ?? availableTextChannelsByServer.values.flatMap { $0 }.first { $0.id == channelID }?.name
            ?? "channel"
    }

    // MARK: Formatting

    /// The two largest units, so a year of voice reads "6mo 26d" rather than
    /// "5,000h". Months are 30 days and years 365, which is plenty for a
    /// recap. Mirrors `rwDuration` in the WebUI.
    static func replayDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if days >= 365 { return pair(days / 365, "y", (days % 365) / 30, "mo") }
        if days >= 30 { return pair(days / 30, "mo", days % 30, "d") }
        if days >= 1 { return pair(days, "d", hours % 24, "h") }
        if hours >= 1 { return pair(hours, "h", minutes % 60, "m") }
        return "\(max(minutes, seconds > 0 ? 1 : 0))m"

        func pair(_ major: Int, _ majorUnit: String, _ minor: Int, _ minorUnit: String) -> String {
            minor > 0 ? "\(major)\(majorUnit) \(minor)\(minorUnit)" : "\(major)\(majorUnit)"
        }
    }

    /// "new" for a term the period introduced, otherwise how many times its
    /// usual rate it ran at. Nil for terms ranked by plain frequency.
    static func replayTermNote(_ term: RewindTermCount) -> String? {
        guard let lift = term.lift, let usual = term.baselineCount else { return nil }
        if usual == 0 { return "new" }
        let multiple = lift < 10 ? (lift * 10).rounded() / 10 : lift.rounded()
        let text = multiple == multiple.rounded() ? String(Int(multiple)) : String(format: "%.1f", multiple)
        return "\(text)× usual"
    }

    /// "only you" when nobody else in the server said it, otherwise how many
    /// times more than everyone else (by share of words) this member says it.
    static func replaySignatureNote(_ term: RewindTermCount) -> String? {
        guard term.baselineCount != 0 else { return "only you" }
        return replayTermNote(term).map { $0.replacingOccurrences(of: "usual", with: "everyone else") }
    }

    static func replayHour(_ hour: Int) -> String {
        let display = hour % 12 == 0 ? 12 : hour % 12
        return "\(display)\(hour < 12 ? "am" : "pm")"
    }

    static func replayDay(_ key: String) -> String {
        guard let date = RewindCalendar.dayFormatter.date(from: key) else { return key }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private static let medals = ["🥇", "🥈", "🥉"]

    private static func rankedLines(_ items: [ServerReplay.Ranked], limit: Int, value: (Int) -> String) -> String {
        items.prefix(limit).enumerated().map { index, item in
            let marker = index < medals.count ? medals[index] : "**\(index + 1).**"
            let signature = item.signature.map { " · *“\($0)”*" } ?? ""
            return "\(marker) \(item.title) — \(value(item.count))\(signature)"
        }.joined(separator: "\n")
    }

    /// The Discord recap: a handful of embeds, kept well under Discord's
    /// 6,000-character total.
    func replayEmbeds(_ replay: ServerReplay) -> [[String: Any]] {
        let accent = 0xBF5AF2
        var embeds: [[String: Any]] = []
        var stats: [String] = []
        if replay.messages > 0 {
            stats.append("💬 **\(replay.messages.formatted())** messages from **\(replay.chattingMembers)** people")
        }
        if replay.voiceSeconds > 0 {
            stats.append("🔊 **\(Self.replayDuration(replay.voiceSeconds))** in voice across \(replay.voiceSessions.formatted()) sessions")
        }
        if let busiest = replay.busiestDay {
            stats.append("📅 Busiest day: **\(Self.replayDay(busiest))** (\(replay.busiestDayMessages.formatted()) messages)")
        }
        if let hour = replay.peakHour { stats.append("🕘 Most active around **\(Self.replayHour(hour))**") }
        if let joins = replay.joins, joins > 0 { stats.append("👋 **\(joins)** new members joined") }
        if let commands = replay.commands, commands > 0 { stats.append("⌨️ **\(commands.formatted())** commands run") }
        embeds.append([
            "title": "📼 \(replay.guildName) · \(replay.periodTitle) Replay",
            "description": stats.isEmpty ? "A quiet \(replay.isYear ? "year" : "month") — nothing to recap yet." : stats.joined(separator: "\n"),
            "color": accent
        ])

        var people: [[String: Any]] = []
        if !replay.topMembers.isEmpty {
            people.append(["name": "Most talkative", "value": Self.rankedLines(replay.topMembers, limit: 5) { "\($0.formatted()) messages" }, "inline": true])
        }
        if !replay.topVoiceMembers.isEmpty {
            people.append(["name": "Most time in voice", "value": Self.rankedLines(replay.topVoiceMembers, limit: 5) { Self.replayDuration($0) }, "inline": true])
        }
        if !people.isEmpty { embeds.append(["title": "🏆 Your top members", "color": accent, "fields": people]) }

        var places: [[String: Any]] = []
        if !replay.topChannels.isEmpty {
            places.append(["name": "Busiest channels", "value": Self.rankedLines(replay.topChannels, limit: 3) { "\($0.formatted())" }, "inline": true])
        }
        if !replay.topVoiceChannels.isEmpty {
            places.append(["name": "Busiest voice", "value": Self.rankedLines(replay.topVoiceChannels, limit: 3) { Self.replayDuration($0) }, "inline": true])
        }
        if let words = replay.topWords, !words.isEmpty {
            let name = replay.wordsAreDistinctive
                ? "What set \(replay.periodTitle) apart"
                : "Words of the \(replay.isYear ? "year" : "month")"
            let value = words.prefix(8).map { word in
                word.note.map { "`\(word.title)` *\($0)*" } ?? "`\(word.title)`"
            }.joined(separator: "  ")
            places.append(["name": name, "value": value, "inline": false])
        }
        if let emoji = replay.topEmoji, !emoji.isEmpty {
            places.append(["name": "Favourite emoji", "value": emoji.prefix(6).map { "\($0.title) \($0.count.formatted())" }.joined(separator: "  "), "inline": false])
        }
        if !places.isEmpty { embeds.append(["title": "💬 Where it happened", "color": accent, "fields": places]) }

        var games: [[String: Any]] = []
        if let clips = replay.clipsByGame, !clips.isEmpty {
            games.append(["name": "Clips recorded", "value": Self.rankedLines(clips, limit: 3) { "\($0) clips" }, "inline": true])
        }
        if let ranks = replay.rankChanges, !ranks.isEmpty {
            let lines = ranks.prefix(3).map { change in
                let delta = change.to - change.from
                return "**\(change.name)** \(change.from.formatted()) → \(change.to.formatted()) (\(delta >= 0 ? "+" : "")\(delta.formatted()))"
            }
            games.append(["name": "Ranked climbs", "value": lines.joined(separator: "\n"), "inline": true])
        }
        if !games.isEmpty { embeds.append(["title": "🎮 Games", "color": accent, "fields": games]) }

        if var last = embeds.popLast() {
            last["footer"] = ["text": "Rewind by SwiftBot · use /replay for your own recap"]
            embeds.append(last)
        }
        return embeds
    }

    func personalReplayEmbed(_ replay: PersonalReplay, asDM: Bool = false) -> [String: Any] {
        func change(_ now: Int, _ before: Int) -> String? {
            guard before > 0, let title = replay.previousPeriodTitle else { return nil }
            let percent = Int(((Double(now) - Double(before)) / Double(before) * 100).rounded())
            guard percent != 0 else { return "same as \(title)" }
            return "\(percent > 0 ? "▲" : "▼") \(abs(percent))% vs \(title)"
        }
        var lines: [String] = []
        if asDM {
            lines.append("Hey **\(replay.name)** 👋 here's your \(replay.periodTitle) in **\(replay.guildName)**.\n")
        }
        if replay.messages > 0 {
            var line = "💬 **\(replay.messages.formatted())** messages, **\(replay.words.formatted())** words"
            if let rank = replay.rank { line += " — #\(rank) of \(replay.rankedMembers)" }
            lines.append(line)
            if let delta = change(replay.messages, replay.previousMessages) { lines.append("   \(delta)") }
            if let top = replay.topPercent, top <= 25 { lines.append("⭐ Top **\(top)%** most talkative in \(replay.guildName)") }
            lines.append("📅 Active on **\(replay.activeDays)** days")
            if let day = replay.busiestDay { lines.append("🔥 Biggest day: **\(Self.replayDay(day))** (\(replay.busiestDayMessages) messages)") }
            if let words = replay.signatureWords, let top = words.first {
                lines.append("🗣️ Your word: **“\(top.title)”** (\(top.count.formatted())×\(top.note.map { ", \($0)" } ?? ""))")
                let more = words.dropFirst().prefix(3).map { "`\($0.title)`" } + (replay.signaturePhrases ?? []).prefix(1).map { "`\($0.title)`" }
                if !more.isEmpty { lines.append("   also very you: \(more.joined(separator: " "))") }
            }
        }
        if replay.voiceSeconds > 0 {
            var line = "🔊 **\(Self.replayDuration(replay.voiceSeconds))** in voice over \(replay.voiceSessions) sessions"
            if let rank = replay.voiceRank { line += " — #\(rank)" }
            lines.append(line)
            if let delta = change(replay.voiceSeconds, replay.previousVoiceSeconds) { lines.append("   \(delta)") }
            if let channel = replay.favouriteVoiceChannel { lines.append("🏠 Favourite spot: **\(channel)**") }
            if replay.longestSessionSeconds >= 3600 { lines.append("⏱️ Longest session: **\(Self.replayDuration(replay.longestSessionSeconds))**") }
        }
        if let commands = replay.commands, commands > 0 { lines.append("⌨️ **\(commands)** commands run") }
        var embed: [String: Any] = [
            "title": "📼 \(replay.name)'s \(replay.periodTitle) Replay",
            "description": lines.isEmpty ? "Nothing yet for \(replay.periodTitle) — say hi in chat or hop into voice!" : lines.joined(separator: "\n"),
            "color": 0xBF5AF2,
            "footer": ["text": asDM ? "\(replay.guildName) · /replay any time for yours" : replay.guildName]
        ]
        if asDM { embed["timestamp"] = ISO8601DateFormatter().string(from: Date()) }
        return embed
    }

    // MARK: /replay

    /// Shown only to the member who asked (the slash reply is ephemeral).
    func replayCommand(periodOption: String?, dmsOption: String? = nil, raw: [String: DiscordJSON]) async -> (ok: Bool, message: String, embed: [String: Any]?) {
        if let dmsOption, case let .object(author)? = raw["author"], case let .string(userID)? = author["id"] {
            let stop = dmsOption.lowercased() == "stop"
            if stop { settings.rewind.replayDMOptOutUserIDs.insert(userID) } else { settings.rewind.replayDMOptOutUserIDs.remove(userID) }
            saveSettings()
            return (true, stop
                ? "Done — SwiftBot won't DM you Replays any more. `/replay` still works any time."
                : "Done — you'll get your Replay by DM when this server's recaps go out.", nil)
        }
        guard settings.rewind.isEnabled else {
            return (false, "Rewind is switched off, so there's no Replay yet.", nil)
        }
        guard let guildID = guildId(from: raw) else {
            return (false, "`/replay` only works inside a server.", nil)
        }
        guard case let .object(author)? = raw["author"], case let .string(userID)? = author["id"] else {
            return (false, "Couldn't tell who asked.", nil)
        }
        let now = Date()
        let calendar = Calendar.current
        let period: ReplayPeriod
        switch (periodOption ?? "year").lowercased() {
        case "month":
            let parts = calendar.dateComponents([.year, .month], from: now)
            period = .month(year: parts.year ?? 2026, month: parts.month ?? 1)
        case "last-month":
            period = .previousMonth(before: now)
        default:
            period = .year(calendar.component(.year, from: now))
        }
        let replay = await personalReplay(guildID: guildID, userID: userID, period: period, now: now)
        return (true, "", personalReplayEmbed(replay))
    }

    // MARK: Recap drops

    /// Posts a guild's Replay to its recap channel. Returns false when there's
    /// no channel set or Discord rejects the post.
    @discardableResult
    func postReplayRecap(guildID: String, period: ReplayPeriod) async -> Bool {
        guard let drop = settings.rewind.recapDrops[guildID], !drop.channelID.isEmpty else { return false }
        let replay = await serverReplay(guildID: guildID, period: period, includeText: true)
        let embeds = replayEmbeds(replay)
        return await sendPayload(channelId: drop.channelID, payload: ["embeds": embeds], action: "replayRecap")
    }

    static let replayDMOptOutCustomID = "replay.dm.optout"

    /// By default personal Replay DMs require regular recent chat as well as
    /// activity in the recap period. A guild can switch off the chat filter.
    func replayDMRecipients(guildID: String, period: ReplayPeriod, now: Date = Date()) async -> [String] {
        await rewindStore.flush()
        let interval = period.interval(now: now)
        var ids = await rewindStore.activeUserIDs(guildID: guildID, start: interval.start, end: interval.end)
        let voice = await voiceSessionStore.report(window: interval, buckets: [], previous: nil, guildId: guildID, now: now, topLimit: 100_000)
        ids.formUnion(voice.topUsers.filter { $0.seconds >= 60 }.map(\.userId))
        if settings.rewind.recapDrops[guildID]?.onlyDMActiveMembers ?? true {
            let activeChatters = await rewindStore.replayDMActiveUserIDs(guildID: guildID, now: now)
            ids.formIntersection(activeChatters)
        }
        ids.subtract(settings.rewind.replayDMOptOutUserIDs)
        ids.subtract(knownBotUserIds)
        if let botUserId { ids.remove(botUserId) }
        return ids.sorted()
    }

    /// DMs each recipient their own Replay, one at a time with a pause between
    /// sends so a big server doesn't hit Discord's rate limits. Members with
    /// DMs closed are skipped quietly.
    @discardableResult
    func sendPersonalReplayDMs(guildID: String, period: ReplayPeriod) async -> (sent: Int, failed: Int) {
        let mode = runtimeClusterMode
        guard mode == .standalone || mode == .leader else { return (0, 0) }
        let recipients = await replayDMRecipients(guildID: guildID, period: period)
        replayDMProgress = ReplayDMProgress(guildID: guildID, periodKey: period.key, total: recipients.count)
        var sent = 0, failed = 0
        let button: [[String: Any]] = [[
            "type": 1,
            "components": [[ "type": 2, "style": 2, "label": "Stop sending me Replays", "custom_id": Self.replayDMOptOutCustomID ]]
        ]]
        for userID in recipients {
            if Task.isCancelled { break }
            defer { replayDMProgress?.processed += 1 }
            // Someone may opt out while a long run is in progress.
            guard !settings.rewind.replayDMOptOutUserIDs.contains(userID) else { continue }
            // Archive history may outlive someone's membership of this server.
            guard await guildMemberRoleIDs(guildID: guildID, userID: userID) != nil else { continue }
            let replay = await personalReplay(guildID: guildID, userID: userID, period: period)
            guard replay.messages > 0 || replay.voiceSeconds > 0 else { continue }
            do {
                nonisolated(unsafe) let embed = personalReplayEmbed(replay, asDM: true)
                nonisolated(unsafe) let components = button
                try await service.sendDMEmbed(userId: userID, embed: embed, components: components)
                sent += 1
            } catch {
                failed += 1
            }
            replayDMProgress?.sent = sent
            replayDMProgress?.failed = failed
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        replayDMProgress?.finishedAt = Date()
        logs.append("[OK] Replay: DMed \(sent) members their \(period.title()) Replay in \(connectedServers[guildID] ?? guildID)\(failed > 0 ? " (\(failed) had DMs closed)" : "").")
        return (sent, failed)
    }

    /// Starts a DM run in the background (from the web's "Send now").
    func startPersonalReplayDMs(guildID: String, period: ReplayPeriod) -> Bool {
        guard replayDMTask == nil else { return false }
        replayDMTask = Task { [weak self] in
            await self?.sendPersonalReplayDMs(guildID: guildID, period: period)
            self?.replayDMTask = nil
        }
        return true
    }

    func handleReplayDMOptOutButton(event: GatewayInteractionCreateEvent, userID: String) async {
        settings.rewind.replayDMOptOutUserIDs.insert(userID)
        saveSettings()
        do {
            let payloadData = try JSONSerialization.data(withJSONObject: [
                "type": 4,
                "data": ["content": "Done — no more Replay DMs. You can still use `/replay` in the server any time, or `/replay dms:start` to turn them back on.", "flags": 64]
            ])
            try await service.respondToInteraction(interactionID: event.interactionID, interactionToken: event.interactionToken, payloadData: payloadData)
        } catch {
            logs.append("❌ Replay opt-out reply failed: \(error.localizedDescription)")
        }
    }

    /// Checks hourly for due recaps: the previous month's on the 1st, and the
    /// previous year's on 1 January, each from 9am local time. Only the node
    /// that sends to Discord (Standalone or Primary) posts.
    func configureReplayDrops() {
        replayDropTask?.cancel()
        replayDropTask = nil
        configureRewindCatchUp()
        guard usesLocalRuntime, settings.rewind.isEnabled,
              settings.rewind.recapDrops.values.contains(where: \.isScheduled) else { return }
        replayDropTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.postDueReplayRecaps()
                try? await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
            }
        }
    }

    func postDueReplayRecaps(now: Date = Date()) async {
        let mode = runtimeClusterMode
        guard mode == .standalone || mode == .leader, status == .running, settings.rewind.isEnabled else { return }
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        guard (parts.hour ?? 0) >= 9 else { return }
        let lastMonth = ReplayPeriod.previousMonth(before: now)
        let lastYear = ReplayPeriod.year((parts.year ?? 2026) - 1)
        for (guildID, drop) in settings.rewind.recapDrops where drop.isScheduled {
            var due: [ReplayPeriod] = []
            if drop.monthly { due.append(lastMonth) }
            if drop.yearly, parts.month == 1 { due.append(lastYear) }
            for period in due {
                let monthly = !period.isYear
                let channelKey = monthly ? drop.lastMonthlyKey : drop.lastYearlyKey
                if !drop.channelID.isEmpty, channelKey != period.key, await postReplayRecap(guildID: guildID, period: period) {
                    if monthly { settings.rewind.recapDrops[guildID]?.lastMonthlyKey = period.key } else { settings.rewind.recapDrops[guildID]?.lastYearlyKey = period.key }
                    saveSettings()
                    logs.append("[OK] Replay: posted \(period.title()) recap for \(connectedServers[guildID] ?? guildID).")
                }
                let personalKey = monthly ? drop.lastPersonalMonthlyKey : drop.lastPersonalYearlyKey
                if drop.personalDMs, personalKey != period.key {
                    // Mark it first so a restart mid-run never DMs anyone twice.
                    if monthly { settings.rewind.recapDrops[guildID]?.lastPersonalMonthlyKey = period.key } else { settings.rewind.recapDrops[guildID]?.lastPersonalYearlyKey = period.key }
                    saveSettings()
                    await sendPersonalReplayDMs(guildID: guildID, period: period)
                }
            }
        }
    }

    // MARK: Nightly catch-up

    /// Rewind records messages live; this fills in anything posted while
    /// SwiftBot was offline. Runs a couple of minutes after the bot starts and
    /// then nightly at 4am. Needs message text kept, since the archive dedupes
    /// by message ID.
    func configureRewindCatchUp() {
        rewindCatchUpTask?.cancel()
        rewindCatchUpTask = nil
        guard usesLocalRuntime, settings.rewind.isEnabled, settings.rewind.retainMessageContent else { return }
        rewindCatchUpTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            while !Task.isCancelled {
                await self?.runRewindCatchUp()
                let calendar = Calendar.current
                let now = Date()
                var next = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(86_400)
                if next <= now { next = calendar.date(byAdding: .day, value: 1, to: next) ?? now.addingTimeInterval(86_400) }
                try? await Task.sleep(nanoseconds: UInt64(max(60, next.timeIntervalSince(now))) * 1_000_000_000)
            }
        }
    }

    func runRewindCatchUp(now: Date = Date()) async {
        guard status == .running, settings.rewind.isEnabled, settings.rewind.retainMessageContent,
              rewindBackfillTask == nil else { return }
        // From the last catch-up, with an hour's overlap; at most two weeks back.
        let since = max(
            (settings.rewind.lastCatchUpAt ?? now.addingTimeInterval(-2 * 86_400)).addingTimeInterval(-3_600),
            now.addingTimeInterval(-14 * 86_400)
        )
        let includeBots = settings.rewind.includeBotMessages
        let ignored = settings.rewind.ignoredChannelIDs
        var imported = 0
        for guildID in connectedServers.keys {
            for channel in availableTextChannelsByServer[guildID] ?? [] where !ignored.contains(channel.id) {
                if Task.isCancelled { return }
                var cursor: String?
                for _ in 0..<30 {
                    guard let page = try? await service.rewindFetchMessagePage(guildId: guildID, channelId: channel.id, limit: 100, before: cursor),
                          !page.messages.isEmpty else { break }
                    let fresh = page.messages.filter { message in
                        message.createdAt >= since
                            && (includeBots || !message.isBot)
                            && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    imported += await rewindStore.importMessages(fresh, retainContent: true)
                    // Pages run newest to oldest; stop once we're past `since`.
                    guard let oldest = page.messages.map(\.createdAt).min(), oldest >= since, let next = page.nextCursor else { break }
                    cursor = next
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        await rewindStore.flush()
        settings.rewind.lastCatchUpAt = now
        saveSettings()
        logs.append("[OK] Rewind catch-up: \(imported) missed message\(imported == 1 ? "" : "s") archived.")
    }
}

// MARK: - WebUI

extension AppModel {
    /// A signed-in person's own Replay. `allowedGuildIDs` is the member's
    /// servers from sign-in, or nil for an admin (any connected server).
    /// Opting out of Replay DMs doesn't hide it.
    func memberReplay(userID: String, allowedGuildIDs: [String]?, guildID requested: String?, periodKey: String?) async -> AdminWebMemberReplayPayload {
        let allowed = Set(allowedGuildIDs ?? Array(connectedServers.keys))
        let guilds = connectedServers
            .filter { allowed.contains($0.key) }
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
            .map { AdminWebSimpleOption(id: $0.key, name: $0.value) }
        let guildID = guilds.first { $0.id == requested }?.id ?? guilds.first?.id
        guard settings.rewind.isEnabled, let guildID else {
            return AdminWebMemberReplayPayload(rewindEnabled: settings.rewind.isEnabled, guilds: guilds, guildID: guildID, periods: [], periodKey: nil, replay: nil)
        }
        let months = await rewindStore.availableMonths(guildID: guildID)
        var periods: [String] = []
        for month in months {
            let year = String(month.prefix(4))
            if !periods.contains(year) { periods.append(year) }
            periods.append(month)
        }
        let currentYear = String(Calendar.current.component(.year, from: Date()))
        let key = periodKey.flatMap { periods.contains($0) ? $0 : nil } ?? (periods.contains(currentYear) ? currentYear : periods.first)
        guard let key, let period = ReplayPeriod(key: key) else {
            return AdminWebMemberReplayPayload(rewindEnabled: true, guilds: guilds, guildID: guildID, periods: periods, periodKey: nil, replay: nil)
        }
        let replay = await personalReplay(guildID: guildID, userID: userID, period: period)
        return AdminWebMemberReplayPayload(rewindEnabled: true, guilds: guilds, guildID: guildID, periods: periods, periodKey: key, replay: replay)
    }

    func adminWebRewind(_ request: AdminWebRewindRequest) async -> AdminWebRewindResult {
        switch request {
        case .replay(let guildID, let period):
            guard connectedServers[guildID] != nil else { return .failure("unknown_guild") }
            return .replay(await serverReplay(guildID: guildID, period: period, includeText: true))

        case .member(let guildID, let userID, let period):
            guard connectedServers[guildID] != nil, !userID.isEmpty else { return .failure("unknown_member") }
            return .member(await personalReplay(guildID: guildID, userID: userID, period: period))

        case .phrase(let guildID, let phrase):
            guard settings.rewind.retainMessageContent else { return .failure("text_not_kept") }
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, connectedServers[guildID] != nil else { return .failure("invalid_query") }
            await rewindStore.flush()
            let report = await rewindStore.phraseReport(
                guildID: guildID, phrase: trimmed,
                start: Date(timeIntervalSince1970: 1_420_070_400), end: Date()
            )
            return .phrase(AdminWebRewindPhrasePayload(
                phrase: trimmed,
                total: report.totalOccurrences,
                messages: report.messageCount,
                scanned: report.scannedMessages,
                firstSeen: report.firstSeen,
                lastSeen: report.lastSeen,
                byUser: report.byUser.prefix(8).map {
                    .init(title: knownUsersById[$0.userID] ?? $0.userName, count: $0.count, id: $0.userID)
                },
                byMonth: report.byMonth.sorted { $0.term < $1.term }.map { .init(title: $0.term, count: $0.count) },
                topChannel: report.topChannelID.map { channelID in
                    "#" + (availableTextChannelsByServer[guildID]?.first { $0.id == channelID }?.name ?? "channel")
                }
            ))

        case .recaps:
            var months: Set<String> = []
            var guilds: [AdminWebRewindRecapsPayload.Guild] = []
            for (guildID, name) in connectedServers.sorted(by: { $0.value < $1.value }) {
                await months.formUnion(rewindStore.availableMonths(guildID: guildID))
                let drop = settings.rewind.recapDrops[guildID] ?? RewindRecapDrop()
                guilds.append(.init(
                    id: guildID, name: name, channelID: drop.channelID, monthly: drop.monthly, yearly: drop.yearly,
                    lastMonthlyKey: drop.lastMonthlyKey, lastYearlyKey: drop.lastYearlyKey,
                    channels: (availableTextChannelsByServer[guildID] ?? [])
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        .map { AdminWebSimpleOption(id: $0.id, name: $0.name) },
                    personalDMs: drop.personalDMs,
                    onlyDMActiveMembers: drop.onlyDMActiveMembers
                ))
            }
            var payload = AdminWebRewindRecapsPayload(guilds: guilds, months: months.sorted(by: >))
            payload.dmOptOutCount = settings.rewind.replayDMOptOutUserIDs.count
            payload.lastCatchUpAt = settings.rewind.lastCatchUpAt
            payload.catchUpAvailable = settings.rewind.retainMessageContent
            payload.dmProgress = replayDMProgress
            return .recaps(payload)

        case .recipients(let guildID, let period):
            guard connectedServers[guildID] != nil else { return .failure("unknown_guild") }
            return .recipients(await replayDMRecipients(guildID: guildID, period: period).count)

        case .sendDMs(let guildID, let period):
            guard !isFailoverManagedNode else { return .failure("managed_by_primary") }
            guard connectedServers[guildID] != nil else { return .failure("unknown_guild") }
            return startPersonalReplayDMs(guildID: guildID, period: period) ? .ok : .failure("already_sending")

        case .updateRecap(let update):
            guard !isFailoverManagedNode else { return .failure("managed_by_primary") }
            guard connectedServers[update.guildID] != nil else { return .failure("unknown_guild") }
            let channelOK = update.channelID.isEmpty
                || (availableTextChannelsByServer[update.guildID] ?? []).contains { $0.id == update.channelID }
            guard channelOK else { return .failure("unknown_channel") }
            var drop = settings.rewind.recapDrops[update.guildID] ?? RewindRecapDrop()
            let now = Date()
            // Turning a drop on starts from the next period, so switching it
            // on mid-month doesn't immediately post last month's recap.
            let lastMonth = ReplayPeriod.previousMonth(before: now).key
            let lastYear = String(Calendar.current.component(.year, from: now) - 1)
            if update.monthly && !drop.monthly { drop.lastMonthlyKey = lastMonth; drop.lastPersonalMonthlyKey = lastMonth }
            if update.yearly && !drop.yearly { drop.lastYearlyKey = lastYear; drop.lastPersonalYearlyKey = lastYear }
            if let dms = update.personalDMs {
                // Same rule for DMs: switching them on starts with the next period.
                if dms && !drop.personalDMs { drop.lastPersonalMonthlyKey = lastMonth; drop.lastPersonalYearlyKey = lastYear }
                drop.personalDMs = dms
            }
            if let onlyActive = update.onlyDMActiveMembers { drop.onlyDMActiveMembers = onlyActive }
            drop.channelID = update.channelID
            drop.monthly = update.monthly
            drop.yearly = update.yearly
            settings.rewind.recapDrops[update.guildID] = drop
            saveSettings()
            configureReplayDrops()
            return .ok

        case .postRecap(let guildID, let period):
            guard let drop = settings.rewind.recapDrops[guildID], !drop.channelID.isEmpty else { return .failure("no_channel") }
            return await postReplayRecap(guildID: guildID, period: period) ? .ok : .failure("send_failed")
        }
    }
}
