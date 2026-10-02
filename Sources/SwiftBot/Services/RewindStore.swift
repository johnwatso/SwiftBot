import Foundation

/// The Rewind archive.
///
/// Layout, under `Application Support/SwiftBot/rewind/<guildID>/`:
///
/// - `messages-YYYY-MM.jsonl` — append-only, one `RewindMessage` per line.
///   Appending is a seek-to-end plus write, so ingest cost does not grow with
///   archive size. This is deliberately *not* part of `AnalyticsRuntimeSnapshot`,
///   which re-encodes and rewrites its entire file on every append — fine at
///   command volume, ruinous at message volume.
/// - `aggregates-YYYY.json` — per-day counters keyed by `yyyy-MM-dd`.
///   Leaderboards and the yearly card read only this, so they stay instant no
///   matter how large the message archive grows.
///
/// Phrase queries scan the shards, which is the price of answering an arbitrary
/// phrase retroactively — roughly 15 MB and about a second per archived year on
/// a typical server.
actor RewindStore {
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let calendar: Calendar

    /// One buffered message plus whether its text should reach a shard. The flag
    /// travels with the message because the setting can change between the
    /// buffering and the flush.
    private struct PendingMessage {
        let message: RewindMessage
        let retainContent: Bool
    }

    private var pending: [PendingMessage] = []
    /// Aggregate years touched since the last write, as "guildID/year".
    private var dirtyAggregates: Set<String> = []
    /// Loaded aggregate years, keyed "guildID/year".
    private var aggregateCache: [String: [String: RewindDailyAggregate]] = [:]
    private var flushTask: Task<Void, Never>?

    /// Per-member word counts for a range, from the message text. `days`
    /// counts runs of days, which is exact for live-ingested shards and close
    /// enough for backfilled ones (imported newest page first) — it only
    /// gates one-day bursts.
    private struct TermTally {
        var count = 0
        var days = 0
        var lastDay = ""

        mutating func add(day: String) {
            count += 1
            if day != lastDay { days += 1; lastDay = day }
        }
    }
    private struct MemberTerms {
        var computedAt: Date
        var words: [String: [String: TermTally]] = [:]
        var bigrams: [String: [String: TermTally]] = [:]
        var activeDays: [String: Set<String>] = [:]
        var totalWords: [String: Int] = [:]
        var totalBigrams: [String: Int] = [:]
    }
    private var memberTermsCache: [String: MemberTerms] = [:]

    init(rootURL: URL = SwiftBotStorage.folderURL().appendingPathComponent("rewind", isDirectory: true)) {
        self.rootURL = rootURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar
    }

    // MARK: - Lifecycle

    /// Starts the periodic flush. Safe to call more than once.
    func start() {
        tightenPermissions()
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(RewindLimits.flushInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.flush()
            }
        }
    }

    func stop() {
        flushTask?.cancel()
        flushTask = nil
        flush()
    }

    // MARK: - Ingest

    /// Buffers one message. It reaches disk on the next threshold or interval
    /// flush, so a busy channel costs one file append per batch rather than one
    /// per message.
    ///
    /// With `retainContent` false the message still updates the daily counters
    /// but its text is never written to a shard — Tier 1 collection.
    func record(_ message: RewindMessage, retainContent: Bool) {
        pending.append(PendingMessage(message: message, retainContent: retainContent))
        if pending.count >= RewindLimits.flushMessageThreshold {
            flush()
        }
    }

    /// Bulk path for the historical backfill. Skips message IDs already present
    /// in the affected shards, so a re-run tops up rather than duplicating.
    ///
    /// Dedupe reads the existing shard, which only exists when content is being
    /// retained. Importing with `retainContent` false would double-count the
    /// aggregates on a second run, so that combination is rejected.
    @discardableResult
    func importMessages(_ messages: [RewindMessage], retainContent: Bool) -> Int {
        guard !messages.isEmpty, retainContent else { return 0 }
        flush()

        var written = 0
        for (key, batch) in groupByShard(messages) {
            let existing = existingMessageIDs(in: key)
            let fresh = batch.filter { !existing.contains($0.id) }
            guard !fresh.isEmpty else { continue }
            appendLines(fresh, to: key)
            absorb(fresh, guildID: key.guildID)
            written += fresh.count
        }

        persistDirtyAggregates()
        return written
    }

    /// Forces the buffer to disk.
    func flush() {
        defer { persistDirtyAggregates() }
        guard !pending.isEmpty else { return }

        let batch = pending
        pending.removeAll(keepingCapacity: true)

        let retained = batch.filter(\.retainContent).map(\.message)
        for (key, messages) in groupByShard(retained) {
            appendLines(messages, to: key)
        }

        let all = batch.map(\.message)
        for (guildID, messages) in Dictionary(grouping: all, by: \.guildID) {
            absorb(messages, guildID: guildID)
        }
    }

    private func groupByShard(_ messages: [RewindMessage]) -> [ShardKey: [RewindMessage]] {
        var grouped: [ShardKey: [RewindMessage]] = [:]
        for message in messages {
            let key = ShardKey(guildID: message.guildID, month: RewindCalendar.monthKey(for: message.createdAt))
            grouped[key, default: []].append(message)
        }
        return grouped
    }

    private func appendLines(_ messages: [RewindMessage], to key: ShardKey) {
        var payload = Data()
        for message in messages {
            guard let line = try? encoder.encode(message) else { continue }
            payload.append(line)
            payload.append(0x0A)
        }
        guard !payload.isEmpty else { return }

        let url = shardURL(key)
        ensureDirectory(url.deletingLastPathComponent())

        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            writeRestricted(payload, to: url)
        }
    }

    private func absorb(_ messages: [RewindMessage], guildID: String) {
        for message in messages {
            let day = RewindCalendar.dayKey(for: message.createdAt)
            guard let year = RewindCalendar.year(from: day) else { continue }

            let cacheKey = aggregateCacheKey(guildID: guildID, year: year)
            var days = aggregates(guildID: guildID, year: year)
            var aggregate = days[day] ?? RewindDailyAggregate(day: day)
            aggregate.absorb(message, calendar: calendar)
            days[day] = aggregate

            aggregateCache[cacheKey] = days
            dirtyAggregates.insert(cacheKey)
        }
    }

    private func persistDirtyAggregates() {
        guard !dirtyAggregates.isEmpty else { return }

        for cacheKey in dirtyAggregates {
            guard var days = aggregateCache[cacheKey],
                  let parsed = splitAggregateCacheKey(cacheKey) else { continue }

            for day in Array(days.keys) {
                days[day]?.trim()
            }
            aggregateCache[cacheKey] = days

            guard let data = try? encoder.encode(days) else { continue }
            writeRestricted(data, to: aggregatesURL(guildID: parsed.guildID, year: parsed.year))
        }

        dirtyAggregates.removeAll(keepingCapacity: true)
    }

    // MARK: - Phrase queries

    /// Counts every occurrence of `phrase` between `start` and `end`.
    ///
    /// Matching runs over the token stream rather than raw substrings, so
    /// "how often is" matches "How often IS this?" while "is" never matches
    /// inside "island". Repeats within one message each count.
    func phraseReport(
        guildID: String,
        phrase: String,
        start: Date,
        end: Date
    ) -> RewindPhraseReport {
        let needle = RewindTokenizer.phraseTokens(phrase)
        guard !needle.isEmpty else { return .empty(phrase: phrase) }

        var totalOccurrences = 0
        var messageCount = 0
        var scanned = 0
        var firstSeen: Date?
        var lastSeen: Date?
        var perUser: [String: Int] = [:]
        var names: [String: String] = [:]
        var perMonth: [String: Int] = [:]
        var perChannel: [String: Int] = [:]
        var sample: RewindMessage?

        for month in RewindCalendar.monthKeys(from: start, to: end) {
            let key = ShardKey(guildID: guildID, month: month)
            forEachMessage(in: key) { message in
                guard message.createdAt >= start, message.createdAt <= end else { return true }
                scanned += 1
                guard scanned <= RewindLimits.phraseScanCeiling else { return false }

                let hits = RewindTokenizer.occurrences(
                    of: needle,
                    in: RewindTokenizer.words(in: message.content)
                )
                guard hits > 0 else { return true }

                totalOccurrences += hits
                messageCount += 1
                perUser[message.authorID, default: 0] += hits
                names[message.authorID] = message.authorName
                perMonth[RewindCalendar.monthKey(for: message.createdAt), default: 0] += hits
                perChannel[message.channelID, default: 0] += hits

                if let current = firstSeen {
                    if message.createdAt < current { firstSeen = message.createdAt }
                } else {
                    firstSeen = message.createdAt
                }
                if let current = lastSeen {
                    if message.createdAt > current { lastSeen = message.createdAt }
                } else {
                    lastSeen = message.createdAt
                }
                if sample == nil { sample = message }
                return true
            }
        }

        return RewindPhraseReport(
            phrase: phrase,
            totalOccurrences: totalOccurrences,
            messageCount: messageCount,
            firstSeen: firstSeen,
            lastSeen: lastSeen,
            byUser: rankUsers(perUser, names: names),
            byMonth: perMonth.sorted { $0.key < $1.key }.map { RewindTermCount(term: $0.key, count: $0.value) },
            topChannelID: perChannel.max { lhs, rhs in lhs.value < rhs.value }?.key,
            scannedMessages: scanned,
            sampleMessage: sample
        )
    }

    // MARK: - Signature words

    /// What each member says far more than the rest of the server over a
    /// range: "Max's word of the year". Needs message text, so it's empty when
    /// Rewind only keeps counts. `userIDs` limits which members are ranked;
    /// everyone still counts towards the comparison.
    func signatures(guildID: String, userIDs: Set<String>, start: Date, end: Date) -> [String: RewindSignature] {
        let terms = memberTerms(guildID: guildID, start: start, end: end)
        var result: [String: RewindSignature] = [:]
        for userID in userIDs {
            guard let words = terms.words[userID] else { continue }
            let written = words.values.reduce(0) { $0 + $1.count }
            guard written >= RewindLimits.signatureMinimumWords else { continue }
            let minimumDays = min(3, max(1, (terms.activeDays[userID]?.count ?? 0) / 4))
            var signature = RewindSignature()
            signature.words = rankAgainstOthers(words, totals: terms.totalWords, minimumDays: minimumDays, limit: 5)
            signature.phrases = rankAgainstOthers(terms.bigrams[userID] ?? [:], totals: terms.totalBigrams, minimumDays: minimumDays, limit: 3)
            if !signature.isEmpty { result[userID] = signature }
        }
        return result
    }

    /// One member's terms ranked against everyone else's in the same range.
    private func rankAgainstOthers(
        _ mine: [String: TermTally],
        totals: [String: Int],
        minimumDays: Int,
        limit: Int
    ) -> [RewindTermCount] {
        var others = totals
        for (term, tally) in mine {
            let remaining = (others[term] ?? 0) - tally.count
            others[term] = remaining > 0 ? remaining : nil
        }
        guard others.values.reduce(0, +) >= RewindLimits.signatureMinimumBaselineWords else { return [] }
        return rankDistinctive(
            mine.mapValues(\.count),
            days: mine.mapValues(\.days),
            baseline: others,
            minimumDays: minimumDays,
            limit: limit
        )
    }

    /// Scans the range's shards once and tallies every member's notable words
    /// and phrases, reusing a recent scan of the same range.
    private func memberTerms(guildID: String, start: Date, end: Date) -> MemberTerms {
        let cacheKey = "\(guildID)|\(start.timeIntervalSince1970)|\(RewindCalendar.dayKey(for: end))"
        let now = Date()
        if let cached = memberTermsCache[cacheKey], now.timeIntervalSince(cached.computedAt) < RewindLimits.signatureCacheLifetime {
            return cached
        }
        memberTermsCache = memberTermsCache.filter { now.timeIntervalSince($0.value.computedAt) < RewindLimits.signatureCacheLifetime }

        var terms = MemberTerms(computedAt: now)
        var scanned = 0
        for month in RewindCalendar.monthKeys(from: start, to: end) {
            forEachMessage(in: ShardKey(guildID: guildID, month: month)) { message in
                guard message.createdAt >= start, message.createdAt <= end, !message.isBot else { return true }
                scanned += 1
                guard scanned <= RewindLimits.phraseScanCeiling else { return false }

                let user = message.authorID
                let day = RewindCalendar.dayKey(for: message.createdAt)
                terms.activeDays[user, default: []].insert(day)
                let words = RewindTokenizer.words(in: message.content)
                for word in words where RewindTokenizer.isNotable(word: word) {
                    terms.words[user, default: [:]][word, default: TermTally()].add(day: day)
                    terms.totalWords[word, default: 0] += 1
                }
                for bigram in RewindTokenizer.bigrams(from: words) where RewindTokenizer.isNotable(bigram: bigram) {
                    terms.bigrams[user, default: [:]][bigram, default: TermTally()].add(day: day)
                    terms.totalBigrams[bigram, default: 0] += 1
                }
                return true
            }
        }
        memberTermsCache[cacheKey] = terms
        return terms
    }

    // MARK: - Aggregate queries

    func yearSummary(guildID: String, year: Int, filterStopWords: Bool) -> RewindYearSummary {
        let days = aggregates(guildID: guildID, year: year)
        guard !days.isEmpty else { return .empty(year: year) }

        var totalMessages = 0
        var totalWords = 0
        var activeDays = 0
        var hours = Array(repeating: 0, count: 24)
        var perUser: [String: Int] = [:]
        var names: [String: String] = [:]
        var words: [String: Int] = [:]
        var bigrams: [String: Int] = [:]
        var emoji: [String: Int] = [:]
        var channels: [String: Int] = [:]
        var busiest: RewindDayCount?

        for aggregate in days.values {
            totalMessages += aggregate.messageCount
            totalWords += aggregate.wordCount
            if aggregate.messageCount > 0 { activeDays += 1 }

            for (index, count) in aggregate.messagesByHour.enumerated() where index < 24 {
                hours[index] += count
            }
            for (userID, count) in aggregate.messagesByUser { perUser[userID, default: 0] += count }
            for (userID, name) in aggregate.userNames { names[userID] = name }
            for (word, count) in aggregate.wordCounts { words[word, default: 0] += count }
            for (bigram, count) in aggregate.bigramCounts { bigrams[bigram, default: 0] += count }
            for (symbol, count) in aggregate.emojiCounts { emoji[symbol, default: 0] += count }
            for (channelID, count) in aggregate.messagesByChannel { channels[channelID, default: 0] += count }

            if let current = busiest {
                if aggregate.messageCount > current.count {
                    busiest = RewindDayCount(day: aggregate.day, count: aggregate.messageCount)
                }
            } else {
                busiest = RewindDayCount(day: aggregate.day, count: aggregate.messageCount)
            }
        }

        if filterStopWords {
            words = words.filter { RewindTokenizer.isNotable(word: $0.key) }
            bigrams = bigrams.filter { RewindTokenizer.isNotable(bigram: $0.key) }
        }

        let peak = hours.enumerated().max { lhs, rhs in lhs.element < rhs.element }
        return RewindYearSummary(
            year: year,
            totalMessages: totalMessages,
            totalWords: totalWords,
            activeDays: activeDays,
            busiestDay: busiest,
            peakHour: (peak?.element ?? 0) > 0 ? peak?.offset : nil,
            topUsers: rankUsers(perUser, names: names),
            topWords: rankTerms(words),
            topBigrams: rankTerms(bigrams),
            topEmoji: rankTerms(emoji),
            topChannels: rankTerms(channels)
        )
    }

    func userSummary(guildID: String, userID: String, year: Int) -> RewindUserSummary? {
        let days = aggregates(guildID: guildID, year: year)
        guard !days.isEmpty else { return nil }

        var messageCount = 0
        var wordCount = 0
        var activeDays = 0
        var busiest: RewindDayCount?
        var perUser: [String: Int] = [:]
        var name = ""

        for aggregate in days.values {
            for (otherID, count) in aggregate.messagesByUser { perUser[otherID, default: 0] += count }

            guard let mine = aggregate.messagesByUser[userID], mine > 0 else { continue }
            messageCount += mine
            wordCount += aggregate.wordsByUser[userID] ?? 0
            activeDays += 1
            if let stored = aggregate.userNames[userID] { name = stored }
            if let current = busiest {
                if mine > current.count { busiest = RewindDayCount(day: aggregate.day, count: mine) }
            } else {
                busiest = RewindDayCount(day: aggregate.day, count: mine)
            }
        }

        guard messageCount > 0 else { return nil }

        let ranked = perUser.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }

        return RewindUserSummary(
            userID: userID,
            userName: name.isEmpty ? "Unknown" : name,
            year: year,
            messageCount: messageCount,
            wordCount: wordCount,
            activeDays: activeDays,
            rank: ranked.firstIndex { $0.key == userID }.map { $0 + 1 },
            totalRankedUsers: ranked.count,
            busiestDay: busiest
        )
    }

    /// Top terms over an arbitrary day range — "top words this month". Reads
    /// aggregates only, so it does not touch the message shards.
    func topWords(
        guildID: String,
        start: Date,
        end: Date,
        filterStopWords: Bool,
        limit: Int = 15
    ) -> [RewindTermCount] {
        let startDay = RewindCalendar.dayKey(for: start)
        let endDay = RewindCalendar.dayKey(for: end)
        guard let startYear = RewindCalendar.year(from: startDay),
              let endYear = RewindCalendar.year(from: endDay),
              startYear <= endYear else { return [] }

        var totals: [String: Int] = [:]
        for year in startYear...endYear {
            for (day, aggregate) in aggregates(guildID: guildID, year: year) where day >= startDay && day <= endDay {
                for (word, count) in aggregate.wordCounts {
                    if filterStopWords && !RewindTokenizer.isNotable(word: word) { continue }
                    totals[word, default: 0] += count
                }
            }
        }

        return rankTerms(totals, limit: limit)
    }

    /// Message activity across every archived server for the Analytics page,
    /// read from the per-day aggregates only (no shard scans).
    func periodSummary(buckets: [AnalyticsBucket], window: DateInterval, previous: DateInterval) -> RewindPeriodSummary {
        let startDay = RewindCalendar.dayKey(for: previous.start)
        let endDay = RewindCalendar.dayKey(for: window.end)
        let windowStartDay = RewindCalendar.dayKey(for: window.start)
        guard let startYear = RewindCalendar.year(from: startDay),
              let endYear = RewindCalendar.year(from: endDay),
              startYear <= endYear else { return RewindPeriodSummary(bucketCounts: Array(repeating: 0, count: buckets.count)) }

        var summary = RewindPeriodSummary(bucketCounts: Array(repeating: 0, count: buckets.count))
        var perUser: [String: Int] = [:]
        var names: [String: String] = [:]
        var words: [String: Int] = [:]
        var emoji: [String: Int] = [:]
        var channels: [String: Int] = [:]
        let bucketDays = buckets.map { (RewindCalendar.dayKey(for: $0.start), RewindCalendar.dayKey(for: $0.end)) }

        for guildID in archivedGuildIDs() {
            for year in startYear...endYear {
                for (day, aggregate) in aggregates(guildID: guildID, year: year) where day >= startDay && day <= endDay {
                    guard day >= windowStartDay else {
                        summary.previousMessages += aggregate.messageCount
                        continue
                    }
                    summary.totalMessages += aggregate.messageCount
                    if let index = bucketDays.firstIndex(where: { day >= $0.0 && day < $0.1 }) {
                        summary.bucketCounts[index] += aggregate.messageCount
                    }
                    for (index, count) in aggregate.messagesByHour.enumerated() where index < 24 {
                        summary.hourly[index] += count
                    }
                    aggregate.messagesByUser.forEach { perUser[$0.key, default: 0] += $0.value }
                    aggregate.userNames.forEach { names[$0.key] = $0.value }
                    aggregate.wordCounts.forEach { if RewindTokenizer.isNotable(word: $0.key) { words[$0.key, default: 0] += $0.value } }
                    aggregate.emojiCounts.forEach { emoji[$0.key, default: 0] += $0.value }
                    aggregate.messagesByChannel.forEach { channels[$0.key, default: 0] += $0.value }
                }
            }
        }
        summary.topUsers = rankUsers(perUser, names: names, limit: 5)
        summary.topWords = rankTerms(words, limit: 10)
        summary.topEmoji = rankTerms(emoji, limit: 8)
        summary.topChannels = rankTerms(channels, limit: 5)
        summary.hasArchive = !archivedGuildIDs().isEmpty
        return summary
    }

    /// Daily aggregates for one guild between two dates (inclusive), by day key.
    private func aggregates(guildID: String, from start: Date, to end: Date) -> [String: RewindDailyAggregate] {
        let startDay = RewindCalendar.dayKey(for: start)
        let endDay = RewindCalendar.dayKey(for: end)
        guard let startYear = RewindCalendar.year(from: startDay),
              let endYear = RewindCalendar.year(from: endDay),
              startYear <= endYear else { return [:] }
        var result: [String: RewindDailyAggregate] = [:]
        for year in startYear...endYear {
            for (day, aggregate) in aggregates(guildID: guildID, year: year) where day >= startDay && day <= endDay {
                result[day] = aggregate
            }
        }
        return result
    }

    /// A guild's messages over any range, for Replay. `buckets` split the
    /// range for the timeline (months of a year, days of a month).
    func rangeSummary(
        guildID: String,
        start: Date,
        end: Date,
        buckets: [AnalyticsBucket],
        excludingUsers excluded: Set<String>,
        filterStopWords: Bool
    ) -> RewindRangeSummary {
        let days = aggregates(guildID: guildID, from: start, to: end)
        var summary = RewindRangeSummary(bucketCounts: Array(repeating: 0, count: buckets.count))
        var perUser: [String: Int] = [:]
        var names: [String: String] = [:]
        var words: [String: Int] = [:]
        var bigrams: [String: Int] = [:]
        var wordDays: [String: Int] = [:]
        var bigramDays: [String: Int] = [:]
        var emoji: [String: Int] = [:]
        var channels: [String: Int] = [:]
        let bucketDays = buckets.map { (RewindCalendar.dayKey(for: $0.start), RewindCalendar.dayKey(for: $0.end)) }

        for (day, aggregate) in days {
            // Opted-out members are dropped at ingest; this also covers anyone
            // who opted out after their messages were counted.
            let removed = aggregate.messagesByUser.filter { excluded.contains($0.key) }.values.reduce(0, +)
            let count = aggregate.messageCount - removed
            guard count > 0 else { continue }
            summary.totalMessages += count
            summary.totalWords += aggregate.wordCount - aggregate.wordsByUser.filter { excluded.contains($0.key) }.values.reduce(0, +)
            summary.activeDays += 1
            if count > (summary.busiestDay?.count ?? 0) { summary.busiestDay = RewindDayCount(day: day, count: count) }
            if let index = bucketDays.firstIndex(where: { day >= $0.0 && day < $0.1 }) {
                summary.bucketCounts[index] += count
            }
            for (index, value) in aggregate.messagesByHour.enumerated() where index < 24 { summary.hourly[index] += value }
            for (userID, value) in aggregate.messagesByUser where !excluded.contains(userID) { perUser[userID, default: 0] += value }
            aggregate.userNames.forEach { names[$0.key] = $0.value }
            for (word, value) in aggregate.wordCounts {
                words[word, default: 0] += value
                wordDays[word, default: 0] += 1
            }
            for (bigram, value) in aggregate.bigramCounts {
                bigrams[bigram, default: 0] += value
                bigramDays[bigram, default: 0] += 1
            }
            aggregate.emojiCounts.forEach { emoji[$0.key, default: 0] += $0.value }
            aggregate.messagesByChannel.forEach { channels[$0.key, default: 0] += $0.value }
        }
        if filterStopWords {
            words = words.filter { RewindTokenizer.isNotable(word: $0.key) }
            bigrams = bigrams.filter { RewindTokenizer.isNotable(bigram: $0.key) }
        }
        let peak = summary.hourly.enumerated().max { $0.element < $1.element }
        summary.peakHour = (peak?.element ?? 0) > 0 ? peak?.offset : nil
        summary.memberCount = perUser.count
        summary.topUsers = rankUsers(perUser, names: names, limit: 25)

        // With the filter on, rank words by what set this range apart rather
        // than raw frequency: "haha" and "game" are common every month, so they
        // score near zero, and what's left is what the server was actually
        // talking about. Without enough history to compare to, fall back.
        let baseline = filterStopWords ? baselineTerms(guildID: guildID, outside: days.keys) : nil
        if let baseline, baseline.days >= RewindLimits.distinctiveBaselineDays {
            // A term has to come up on a few separate days, so one person
            // pasting something forty times in an afternoon doesn't define a year.
            let minimumDays = min(3, max(1, summary.activeDays / 4))
            summary.topWords = rankDistinctive(words, days: wordDays, baseline: baseline.words, minimumDays: minimumDays, limit: 12)
            summary.topBigrams = rankDistinctive(bigrams, days: bigramDays, baseline: baseline.bigrams, minimumDays: minimumDays, limit: 6)
            summary.termsAreDistinctive = !summary.topWords.isEmpty
            if summary.topWords.isEmpty { summary.topWords = rankTerms(words, limit: 12) }
        } else {
            summary.topWords = rankTerms(words, limit: 12)
            summary.topBigrams = rankTerms(bigrams, limit: 6)
        }
        summary.topEmoji = rankTerms(emoji, limit: 8)
        summary.topChannels = rankTerms(channels, limit: 5)
        return summary
    }

    /// Everyone who posted in a guild over a range.
    func activeUserIDs(guildID: String, start: Date, end: Date) -> Set<String> {
        var ids: Set<String> = []
        for aggregate in aggregates(guildID: guildID, from: start, to: end).values {
            for (userID, count) in aggregate.messagesByUser where count > 0 { ids.insert(userID) }
        }
        return ids
    }

    /// One member's messages over a range, with where they rank.
    func userRangeSummary(guildID: String, userID: String, start: Date, end: Date, excludingUsers excluded: Set<String>) -> RewindUserRangeSummary {
        let days = aggregates(guildID: guildID, from: start, to: end)
        var perUser: [String: Int] = [:]
        var result = RewindUserRangeSummary()
        for (day, aggregate) in days {
            for (id, value) in aggregate.messagesByUser where !excluded.contains(id) { perUser[id, default: 0] += value }
            if let name = aggregate.userNames[userID] { result.userName = name }
            guard let mine = aggregate.messagesByUser[userID], mine > 0 else { continue }
            result.messages += mine
            result.words += aggregate.wordsByUser[userID] ?? 0
            result.activeDays += 1
            if mine > (result.busiestDay?.count ?? 0) { result.busiestDay = RewindDayCount(day: day, count: mine) }
        }
        let ranked = perUser.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        if let index = ranked.firstIndex(where: { $0.key == userID }) { result.rank = index + 1 }
        result.rankedMembers = ranked.count
        return result
    }

    /// Months with at least one archived message, newest first ("2026-09").
    func availableMonths(guildID: String) -> [String] {
        var months: Set<String> = []
        for year in availableYears(guildID: guildID) {
            for (day, aggregate) in aggregates(guildID: guildID, year: year) where aggregate.messageCount > 0 {
                months.insert(String(day.prefix(7)))
            }
        }
        return months.sorted(by: >)
    }

    /// Years holding data for a guild, newest first.
    func availableYears(guildID: String) -> [Int] {
        let folder = guildURL(guildID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.compactMap { name -> Int? in
            guard name.hasPrefix("aggregates-"), name.hasSuffix(".json") else { return nil }
            return Int(name.dropFirst("aggregates-".count).dropLast(".json".count))
        }.sorted(by: >)
    }

    /// Guild IDs with a folder in the archive.
    func archivedGuildIDs() -> [String] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: rootURL.path) else { return [] }
        return entries.filter { entry in
            var isDirectory: ObjCBool = false
            let path = rootURL.appendingPathComponent(entry, isDirectory: true).path
            return manager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    // MARK: - Maintenance

    func archiveStats() -> RewindArchiveStats {
        let manager = FileManager.default
        let guilds = archivedGuildIDs()
        guard !guilds.isEmpty else { return .empty }

        var messageCount = 0
        var bytes: Int64 = 0
        var earliest: String?
        var latest: String?

        for guildID in guilds {
            for year in availableYears(guildID: guildID) {
                for (day, aggregate) in aggregates(guildID: guildID, year: year) {
                    messageCount += aggregate.messageCount
                    if earliest == nil || day < earliest! { earliest = day }
                    if latest == nil || day > latest! { latest = day }
                }
            }

            let folder = guildURL(guildID)
            guard let files = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
            for file in files {
                let url = folder.appendingPathComponent(file)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                bytes += Int64(size)
            }
        }

        return RewindArchiveStats(
            guildCount: guilds.count,
            messageCount: messageCount,
            diskBytes: bytes,
            earliestDay: earliest,
            latestDay: latest
        )
    }

    /// Drops message text older than `days`. Aggregates survive: they are small,
    /// carry no message text, and are what the yearly card reads, so a short
    /// retention window still leaves a usable rewind.
    func applyRetention(days: Int) {
        guard days > 0, let cutoff = calendar.date(byAdding: .day, value: -days, to: Date()) else { return }
        let cutoffMonth = RewindCalendar.monthKey(for: cutoff)
        let manager = FileManager.default

        for guildID in archivedGuildIDs() {
            let folder = guildURL(guildID)
            guard let files = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
            for file in files {
                guard file.hasPrefix("messages-"), file.hasSuffix(".jsonl") else { continue }
                let month = String(file.dropFirst("messages-".count).dropLast(".jsonl".count))
                if month < cutoffMonth {
                    try? manager.removeItem(at: folder.appendingPathComponent(file))
                } else if month == cutoffMonth {
                    rewriteShard(ShardKey(guildID: guildID, month: month)) { $0.createdAt >= cutoff }
                }
            }
        }
    }

    /// Erases one user from the archive — their message text and their entries
    /// in every aggregate. Backs `/rewind forget`.
    func purge(userID: String, guildID: String?) {
        memberTermsCache.removeAll()
        let manager = FileManager.default
        let guilds = guildID.map { [$0] } ?? archivedGuildIDs()

        for guild in guilds {
            let folder = guildURL(guild)
            if let files = try? manager.contentsOfDirectory(atPath: folder.path) {
                for file in files where file.hasPrefix("messages-") && file.hasSuffix(".jsonl") {
                    let month = String(file.dropFirst("messages-".count).dropLast(".jsonl".count))
                    rewriteShard(ShardKey(guildID: guild, month: month)) { $0.authorID != userID }
                }
            }

            for year in availableYears(guildID: guild) {
                let cacheKey = aggregateCacheKey(guildID: guild, year: year)
                var days = aggregates(guildID: guild, year: year)

                for day in Array(days.keys) {
                    guard var aggregate = days[day],
                          let removedMessages = aggregate.messagesByUser.removeValue(forKey: userID) else { continue }
                    let removedWords = aggregate.wordsByUser.removeValue(forKey: userID) ?? 0
                    aggregate.messageCount = max(0, aggregate.messageCount - removedMessages)
                    aggregate.wordCount = max(0, aggregate.wordCount - removedWords)
                    aggregate.userNames.removeValue(forKey: userID)
                    days[day] = aggregate
                }

                aggregateCache[cacheKey] = days
                dirtyAggregates.insert(cacheKey)
            }
        }

        persistDirtyAggregates()
    }

    /// Deletes everything Rewind has stored.
    func deleteAll() {
        pending.removeAll()
        memberTermsCache.removeAll()
        aggregateCache.removeAll()
        dirtyAggregates.removeAll()
        try? FileManager.default.removeItem(at: rootURL)
    }

    // MARK: - Backup exclusion

    /// Keeps the archive out of Time Machine (and any other backup that honours
    /// the flag).
    ///
    /// Application Support is backed up by default, so without this the server's
    /// whole message history is copied to whatever target the Mac backs up to —
    /// often a NAS or a cloud destination with weaker protection than the
    /// machine itself. That is the one exposure app-level encryption would have
    /// closed, and the exclusion closes it without a key the bot has to be able
    /// to read unattended anyway.
    ///
    /// The trade is real and is surfaced in the UI: an excluded archive is not
    /// recoverable from a backup if the disk fails.
    func setBackupExclusion(_ excluded: Bool) {
        ensureDirectory(rootURL)
        var url = rootURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try? url.setResourceValues(values)
    }

    func isExcludedFromBackup() -> Bool {
        (try? rootURL.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }

    // MARK: - File permissions

    /// Rewind is the only SwiftBot store that holds message text, so its files
    /// are owner-only inside owner-only directories. The rest of Application
    /// Support is written 0644, which is fine for settings and counters but not
    /// for a record of everything the server said: on a box with more than one
    /// account, 0644 means any other local user can read the whole archive.
    ///
    /// This is defence against *other users on the machine*, not against
    /// anything running as the bot's own user — see `tightenPermissions`.
    /// Computed rather than stored: `[FileAttributeKey: Any]` is not `Sendable`,
    /// so it cannot be a static constant under strict concurrency.
    private static var directoryAttributes: [FileAttributeKey: Any] { [.posixPermissions: 0o700] }
    private static var fileAttributes: [FileAttributeKey: Any] { [.posixPermissions: 0o600] }

    private func restrict(_ url: URL) {
        try? FileManager.default.setAttributes(Self.fileAttributes, ofItemAtPath: url.path)
    }

    /// Writes `data` and immediately narrows the result to 0600. An atomic
    /// write lands a brand-new inode with default permissions, so the mode has
    /// to be reapplied after every write rather than set once on creation.
    private func writeRestricted(_ data: Data, to url: URL) {
        ensureDirectory(url.deletingLastPathComponent())
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        restrict(url)
    }

    /// Re-applies 0700/0600 across the whole archive. Called on `start()` so an
    /// archive created before this existed gets narrowed rather than staying
    /// world-readable forever.
    func tightenPermissions() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: rootURL.path) else { return }
        try? manager.setAttributes(Self.directoryAttributes, ofItemAtPath: rootURL.path)

        guard let walker = manager.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            try? manager.setAttributes(
                isDirectory ? Self.directoryAttributes : Self.fileAttributes,
                ofItemAtPath: url.path
            )
        }
    }

    // MARK: - Shard IO

    private struct ShardKey: Hashable {
        let guildID: String
        let month: String
    }

    private func guildURL(_ guildID: String) -> URL {
        rootURL.appendingPathComponent(guildID, isDirectory: true)
    }

    private func shardURL(_ key: ShardKey) -> URL {
        guildURL(key.guildID).appendingPathComponent("messages-\(key.month).jsonl")
    }

    private func aggregatesURL(guildID: String, year: Int) -> URL {
        guildURL(guildID).appendingPathComponent("aggregates-\(year).json")
    }

    private func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: Self.directoryAttributes
        )
    }

    /// Streams a shard line by line in 1 MB chunks, so peak memory stays flat
    /// regardless of shard size. The handler returns `false` to stop early.
    private func forEachMessage(in key: ShardKey, _ handler: (RewindMessage) -> Bool) {
        let url = shardURL(key)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var carry = Data()
        let chunkSize = 1 << 20

        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            carry.append(chunk)

            while let newline = carry.firstIndex(of: 0x0A) {
                let line = carry[carry.startIndex..<newline]
                carry = Data(carry[carry.index(after: newline)...])
                if let message = decodeLine(line), !handler(message) { return }
            }
        }

        if !carry.isEmpty, let message = decodeLine(carry), !handler(message) { return }
    }

    private func decodeLine(_ line: Data) -> RewindMessage? {
        guard !line.isEmpty else { return nil }
        return try? decoder.decode(RewindMessage.self, from: Data(line))
    }

    private func existingMessageIDs(in key: ShardKey) -> Set<String> {
        var ids: Set<String> = []
        forEachMessage(in: key) { message in
            ids.insert(message.id)
            return true
        }
        return ids
    }

    /// Rewrites a shard keeping only messages passing `keep`. Writes a sibling
    /// temp file and moves it into place, so an interrupted purge never leaves a
    /// half-written archive.
    private func rewriteShard(_ key: ShardKey, keep: (RewindMessage) -> Bool) {
        let url = shardURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let tempURL = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil, attributes: Self.fileAttributes)
        guard let out = try? FileHandle(forWritingTo: tempURL) else { return }

        var kept = 0
        forEachMessage(in: key) { message in
            guard keep(message) else { return true }
            if let line = try? encoder.encode(message) {
                var payload = line
                payload.append(0x0A)
                try? out.write(contentsOf: payload)
                kept += 1
            }
            return true
        }
        try? out.close()

        if kept == 0 {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: url)
        } else {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            restrict(url)
        }
    }

    // MARK: - Aggregate IO

    private func aggregateCacheKey(guildID: String, year: Int) -> String {
        "\(guildID)/\(year)"
    }

    private func splitAggregateCacheKey(_ key: String) -> (guildID: String, year: Int)? {
        guard let separator = key.lastIndex(of: "/"),
              let year = Int(key[key.index(after: separator)...]) else { return nil }
        return (String(key[key.startIndex..<separator]), year)
    }

    private func aggregates(guildID: String, year: Int) -> [String: RewindDailyAggregate] {
        let cacheKey = aggregateCacheKey(guildID: guildID, year: year)
        if let cached = aggregateCache[cacheKey] { return cached }
        let loaded = loadAggregates(guildID: guildID, year: year)
        aggregateCache[cacheKey] = loaded
        return loaded
    }

    private func loadAggregates(guildID: String, year: Int) -> [String: RewindDailyAggregate] {
        let url = aggregatesURL(guildID: guildID, year: year)
        guard let data = try? Data(contentsOf: url),
              let days = try? decoder.decode([String: RewindDailyAggregate].self, from: data) else {
            return [:]
        }
        return days
    }

    // MARK: - Ranking

    /// Notable word and phrase totals for every archived day of a guild
    /// outside `excluded`: the "usual" a Replay range is compared with.
    private func baselineTerms(
        guildID: String,
        outside excluded: Dictionary<String, RewindDailyAggregate>.Keys
    ) -> (words: [String: Int], bigrams: [String: Int], days: Int) {
        let skip = Set(excluded)
        var words: [String: Int] = [:]
        var bigrams: [String: Int] = [:]
        var days = 0
        for year in availableYears(guildID: guildID) {
            for (day, aggregate) in aggregates(guildID: guildID, year: year) where !skip.contains(day) && aggregate.messageCount > 0 {
                days += 1
                for (word, count) in aggregate.wordCounts where RewindTokenizer.isNotable(word: word) {
                    words[word, default: 0] += count
                }
                for (bigram, count) in aggregate.bigramCounts where RewindTokenizer.isNotable(bigram: bigram) {
                    bigrams[bigram, default: 0] += count
                }
            }
        }
        return (words, bigrams, days)
    }

    /// Terms a range used far more than usual, ranked by `count × ln(lift)`
    /// so a term needs both volume and distinctiveness: a word said 4 times
    /// that was never said before doesn't beat one said 300 times at triple
    /// its normal rate. Shares are smoothed so an unseen baseline term gets a
    /// large but finite lift.
    private func rankDistinctive(
        _ counts: [String: Int],
        days: [String: Int],
        baseline: [String: Int],
        minimumDays: Int,
        limit: Int
    ) -> [RewindTermCount] {
        let total = Double(counts.values.reduce(0, +))
        let baselineTotal = Double(baseline.values.reduce(0, +))
        guard total > 0, baselineTotal > 0 else { return [] }
        let smoothing = 0.5
        let vocabulary = Double(Set(counts.keys).union(baseline.keys).count)

        let scored: [(term: RewindTermCount, score: Double)] = counts.compactMap { term, count in
            guard count >= 3, (days[term] ?? 0) >= minimumDays else { return nil }
            let usual = baseline[term] ?? 0
            let share = (Double(count) + smoothing) / (total + smoothing * vocabulary)
            let usualShare = (Double(usual) + smoothing) / (baselineTotal + smoothing * vocabulary)
            let lift = share / usualShare
            guard lift >= RewindLimits.distinctiveMinimumLift else { return nil }
            return (RewindTermCount(term: term, count: count, lift: lift, baselineCount: usual), Double(count) * log(lift))
        }
        return scored
            .sorted { $0.score == $1.score ? $0.term.term < $1.term.term : $0.score > $1.score }
            .prefix(limit)
            .map(\.term)
    }

    private func rankTerms(_ counts: [String: Int], limit: Int = 15) -> [RewindTermCount] {
        counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        .prefix(limit)
        .map { RewindTermCount(term: $0.key, count: $0.value) }
    }

    private func rankUsers(_ counts: [String: Int], names: [String: String], limit: Int = 10) -> [RewindUserCount] {
        counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        .prefix(limit)
        .map { RewindUserCount(userID: $0.key, userName: names[$0.key] ?? "Unknown", count: $0.value) }
    }
}
