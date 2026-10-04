import Foundation

/// Rewind's presence archive and server journal.
///
/// Presence is only recorded while a member is in a voice channel. The store
/// follows voice membership itself (from `VOICE_STATE_UPDATE` and the
/// `voice_states` in `GUILD_CREATE`) and keeps each member's latest presence in
/// memory, unwritten, so recording can start the moment they join.
///
/// Layout, beside the message archive under `rewind/<guildID>/`:
///
/// - `presence-YYYY-MM.jsonl` — one closed `PresenceSegment` per line, sharded
///   by the month the segment *ended*, so appends always go to the newest file.
/// - `events-YYYY-MM.jsonl` — one `RewindJournalEntry` per line.
///
/// and `rewind/presence-live.json`, a checkpoint of segments still in progress.
/// It is rewritten on every flush so a crash loses at most one flush interval:
/// on the next start those segments are closed at the checkpoint time.
///
/// Same append-only approach and 0700/0600 permissions as `RewindStore`, for
/// the same reasons.
actor RewindActivityStore {
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var tracker = PresenceArchiveTracker()
    private var pendingSegments: [PresenceSegment] = []
    private var pendingEntries: [RewindJournalEntry] = []
    private var liveChanged = false
    /// "guildID/userID" → when the member joined voice.
    private var inVoice: [String: Date] = [:]
    /// Latest presence per "guildID/userID", in or out of voice. Memory only.
    private var lastPresence: [String: GatewayPresenceUpdateEvent] = [:]
    private var flushTask: Task<Void, Never>?

    private struct Checkpoint: Codable {
        var savedAt: Date
        var segments: [PresenceSegment]
    }

    init(rootURL: URL = SwiftBotStorage.folderURL().appendingPathComponent("rewind", isDirectory: true)) {
        self.rootURL = rootURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    // MARK: - Lifecycle

    func start() {
        guard flushTask == nil else { return }
        recoverCheckpoint()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(RewindLimits.flushInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.flush()
            }
        }
    }

    /// Closes everything in progress — a clean stop knows exactly when the
    /// sessions it was watching ended.
    func stop() {
        flushTask?.cancel()
        flushTask = nil
        pendingSegments.append(contentsOf: tracker.closeAll(at: Date()))
        inVoice.removeAll()
        liveChanged = true
        flush()
    }

    var isRunning: Bool { flushTask != nil }

    // MARK: - Ingest

    func record(presence event: GatewayPresenceUpdateEvent, now: Date = Date()) {
        let key = Self.memberKey(event.guildID, event.userID)
        lastPresence[key] = event
        guard let joinedAt = inVoice[key] else { return }
        apply(event, now: now, notBefore: joinedAt)
    }

    /// A member joined, moved within, or left voice. `channelID` nil is a leave.
    func voiceStateChanged(guildID: String, userID: String, channelID: String?, now: Date = Date()) {
        let key = Self.memberKey(guildID, userID)
        if channelID == nil {
            guard inVoice.removeValue(forKey: key) != nil else { return }
            pendingSegments.append(contentsOf: tracker.end(guildID: guildID, userID: userID, at: now))
            liveChanged = true
            return
        }
        guard inVoice[key] == nil else { return } // a move or mute keeps recording
        inVoice[key] = now
        if let presence = lastPresence[key] {
            apply(presence, now: now, notBefore: now)
        }
    }

    /// Connect-time snapshot of a guild: everyone's presence, and who is in
    /// voice. Members recorded as in voice who are missing from the snapshot
    /// left while the bot was away and are ended now.
    func seedGuild(guildID: String, presences: [GatewayPresenceUpdateEvent], voiceUserIDs: Set<String>, now: Date = Date()) {
        for event in presences { lastPresence[Self.memberKey(event.guildID, event.userID)] = event }
        let prefix = "\(guildID)/"
        for key in inVoice.keys where key.hasPrefix(prefix) && !voiceUserIDs.contains(String(key.dropFirst(prefix.count))) {
            voiceStateChanged(guildID: guildID, userID: String(key.dropFirst(prefix.count)), channelID: nil, now: now)
        }
        for userID in voiceUserIDs {
            voiceStateChanged(guildID: guildID, userID: userID, channelID: "voice", now: now)
        }
    }

    private func apply(_ event: GatewayPresenceUpdateEvent, now: Date, notBefore: Date) {
        let output = tracker.apply(event, now: now, notBefore: notBefore)
        pendingSegments.append(contentsOf: output.closed)
        if let change = output.statusChange { pendingEntries.append(change) }
        liveChanged = true
        if pendingSegments.count + pendingEntries.count >= RewindLimits.flushMessageThreshold { flush() }
    }

    func record(_ entry: RewindJournalEntry) {
        pendingEntries.append(entry)
        if pendingEntries.count >= RewindLimits.flushMessageThreshold { flush() }
    }

    func flush() {
        if !pendingSegments.isEmpty {
            let batch = pendingSegments
            pendingSegments.removeAll(keepingCapacity: true)
            let grouped = Dictionary(grouping: batch) {
                ShardKey(guildID: $0.guildID, kind: "presence", month: RewindCalendar.monthKey(for: $0.endedAt ?? $0.startedAt))
            }
            for (key, segments) in grouped { append(segments, to: key) }
        }
        if !pendingEntries.isEmpty {
            let batch = pendingEntries
            pendingEntries.removeAll(keepingCapacity: true)
            let grouped = Dictionary(grouping: batch) {
                ShardKey(guildID: $0.guildID, kind: "events", month: RewindCalendar.monthKey(for: $0.receivedAt))
            }
            for (key, entries) in grouped { append(entries, to: key) }
        }
        if liveChanged {
            liveChanged = false
            writeCheckpoint()
        }
    }

    // MARK: - Queries

    /// Presence segments for a member that overlap `start..<end`, in progress
    /// ones included, oldest first. `guildID` nil searches every guild.
    func presence(userID: String?, guildID: String? = nil, from start: Date, to end: Date) -> [PresenceSegment] {
        flush()
        // A segment is filed under the month it ended, so one that overlaps the
        // window may sit in any shard from the window's start onwards.
        let months = Set(RewindCalendar.monthKeys(from: start, to: max(end, Date())))
        var results: [PresenceSegment] = []
        for guild in guildIDs(matching: guildID) {
            for month in months {
                let key = ShardKey(guildID: guild, kind: "presence", month: month)
                results += read(PresenceSegment.self, from: key).filter {
                    (userID == nil || $0.userID == userID) && $0.overlaps(start, end)
                }
            }
        }
        results += tracker.liveSegments.filter {
            (userID == nil || $0.userID == userID) && (guildID == nil || $0.guildID == guildID) && $0.overlaps(start, end)
        }
        return results.sorted { $0.startedAt < $1.startedAt }
    }

    /// What a member was playing at a moment, with the map/mode detail then in
    /// effect. Prefers games, then competing, then streaming. Built for labelling
    /// recordings by the time they were saved.
    func activity(userID: String, at date: Date, tolerance: TimeInterval = 120) -> (segment: PresenceSegment, detail: PresenceDetailSpan?)? {
        let candidates = presence(userID: userID, from: date.addingTimeInterval(-tolerance), to: date.addingTimeInterval(tolerance))
            .filter { $0.type != PresenceActivityType.custom }
        let rank: [Int: Int] = [PresenceActivityType.playing: 0, PresenceActivityType.competing: 1, PresenceActivityType.streaming: 2]
        guard let best = candidates.min(by: { lhs, rhs in
            let l = rank[lhs.type] ?? 3, r = rank[rhs.type] ?? 3
            return l == r ? lhs.duration > rhs.duration : l < r
        }) else { return nil }
        return (best, best.span(at: date))
    }

    /// Journal entries of the given kinds in a window, oldest first.
    func journal(guildID: String, events: Set<String>? = nil, from start: Date, to end: Date) -> [RewindJournalEntry] {
        flush()
        var results: [RewindJournalEntry] = []
        for month in RewindCalendar.monthKeys(from: start, to: end) {
            results += read(RewindJournalEntry.self, from: ShardKey(guildID: guildID, kind: "events", month: month)).filter {
                $0.receivedAt >= start && $0.receivedAt < end && (events?.contains($0.event) ?? true)
            }
        }
        return results.sorted { $0.receivedAt < $1.receivedAt }
    }

    // MARK: - Maintenance

    /// Same rule as the message archive: whole months older than the cutoff go.
    /// Partial months are kept whole — these files are small next to messages.
    func applyRetention(days: Int) {
        guard days > 0, let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: Date()) else { return }
        let cutoffMonth = RewindCalendar.monthKey(for: cutoff)
        let manager = FileManager.default
        for guildID in guildIDs(matching: nil) {
            let folder = rootURL.appendingPathComponent(guildID, isDirectory: true)
            for file in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] {
                for prefix in ["presence-", "events-"] where file.hasPrefix(prefix) && file.hasSuffix(".jsonl") {
                    let month = String(file.dropFirst(prefix.count).dropLast(".jsonl".count))
                    if month < cutoffMonth { try? manager.removeItem(at: folder.appendingPathComponent(file)) }
                }
            }
        }
    }

    /// Removes one member's presence history and every journal entry that
    /// names them. Pairs with `RewindStore.purge` for `/rewind forget`.
    func purge(userID: String, guildID: String?) {
        flush()
        let needle = "\"\(userID)\""
        for guild in guildIDs(matching: guildID) {
            let folder = rootURL.appendingPathComponent(guild, isDirectory: true)
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard (file.hasPrefix("presence-") || file.hasPrefix("events-")) && file.hasSuffix(".jsonl") else { continue }
                let url = folder.appendingPathComponent(file)
                guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
                let kept = text.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.contains(needle) }
                let output = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
                writeRestricted(Data(output.utf8), to: url)
            }
        }
    }

    private static func memberKey(_ guildID: String, _ userID: String) -> String {
        "\(guildID)/\(userID)"
    }

    // MARK: - IO

    private struct ShardKey: Hashable {
        let guildID: String
        let kind: String
        let month: String
    }

    private func url(_ key: ShardKey) -> URL {
        rootURL.appendingPathComponent(key.guildID, isDirectory: true)
            .appendingPathComponent("\(key.kind)-\(key.month).jsonl")
    }

    private var checkpointURL: URL { rootURL.appendingPathComponent("presence-live.json") }

    private func guildIDs(matching guildID: String?) -> [String] {
        if let guildID { return [guildID] }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? []
        return entries.filter { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    private func append<T: Encodable>(_ items: [T], to key: ShardKey) {
        var payload = Data()
        for item in items {
            guard let line = try? encoder.encode(item) else { continue }
            payload.append(line)
            payload.append(0x0A)
        }
        guard !payload.isEmpty else { return }
        let target = url(key)
        if FileManager.default.fileExists(atPath: target.path) {
            guard let handle = try? FileHandle(forWritingTo: target) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            writeRestricted(payload, to: target)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from key: ShardKey) -> [T] {
        guard let data = try? Data(contentsOf: url(key)) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(T.self, from: Data($0)) }
    }

    private func writeCheckpoint() {
        let segments = tracker.liveSegments
        if segments.isEmpty {
            try? FileManager.default.removeItem(at: checkpointURL)
            return
        }
        guard let data = try? encoder.encode(Checkpoint(savedAt: Date(), segments: segments)) else { return }
        writeRestricted(data, to: checkpointURL)
    }

    private func recoverCheckpoint() {
        guard let data = try? Data(contentsOf: checkpointURL),
              let checkpoint = try? decoder.decode(Checkpoint.self, from: data) else { return }
        try? FileManager.default.removeItem(at: checkpointURL)
        pendingSegments.append(contentsOf: tracker.recover(checkpoint.segments, endedAt: checkpoint.savedAt))
        flush()
    }

    private func writeRestricted(_ data: Data, to url: URL) {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        if !manager.fileExists(atPath: folder.path) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
