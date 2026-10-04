import Foundation

/// What a source's real lookups looked like recently: how busy it is, what
/// people ask for most, and what they asked for that found nothing (the
/// queries worth an alias).
struct WikiLookupUsageSummary: Codable, Hashable, Sendable {
    struct TopItem: Codable, Hashable, Sendable {
        let title: String
        let count: Int
    }

    var lookupsThisWeek: Int = 0
    var topItems: [TopItem] = []
    var recentMisses: [String] = []
}

/// Records each Discord lookup per source. Kept out of settings on purpose:
/// it changes on every lookup, and editors save whole sources back, which
/// would overwrite newer counts with the copy they opened.
/// Follows the on-disk JSON actor pattern from AuditDismissalStore.
actor WikiLookupUsageStore {
    struct Entry: Codable, Hashable {
        let query: String
        /// The page that answered, or nil when nothing matched.
        let title: String?
        let at: Date
    }

    private struct Payload: Codable {
        var entries: [UUID: [Entry]] = [:]
    }

    static let perSourceLimit = 400
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    private let url: URL?
    private let encoder: JSONEncoder
    private var payload: Payload

    /// `filename: nil` keeps everything in memory (tests).
    init(filename: String? = "lookup-usage.json") {
        url = filename.map { SwiftBotStorage.folderURL().appendingPathComponent($0) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode(Payload.self, from: data) {
            payload = decoded
        } else {
            payload = Payload()
        }
    }

    func record(sourceID: UUID, query: String, title: String?, at date: Date = Date()) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = payload.entries[sourceID] ?? []
        list.append(Entry(query: String(trimmed.prefix(100)), title: title, at: date))
        let cutoff = date.addingTimeInterval(-Self.retention)
        list.removeAll { $0.at < cutoff }
        if list.count > Self.perSourceLimit {
            list.removeFirst(list.count - Self.perSourceLimit)
        }
        payload.entries[sourceID] = list
        persist()
    }

    func removeSource(_ sourceID: UUID) {
        guard payload.entries.removeValue(forKey: sourceID) != nil else { return }
        persist()
    }

    func summaries(now: Date = Date()) -> [UUID: WikiLookupUsageSummary] {
        payload.entries.mapValues { Self.summary(of: $0, now: now) }
    }

    static func summary(of entries: [Entry], now: Date = Date()) -> WikiLookupUsageSummary {
        let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let recent = entries.filter { $0.at >= now.addingTimeInterval(-retention) }

        var counts: [String: (title: String, count: Int, last: Date)] = [:]
        for entry in recent {
            guard let title = entry.title else { continue }
            let key = WikiAlias.key(title)
            let current = counts[key]
            counts[key] = (title, (current?.count ?? 0) + 1, max(current?.last ?? entry.at, entry.at))
        }
        let top = counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
            .prefix(5)
            .map { WikiLookupUsageSummary.TopItem(title: $0.title, count: $0.count) }

        // A miss stops mattering once the same words later found a page
        // (someone retyped it, or an alias was added).
        let resolvedKeys = Set(recent.filter { $0.title != nil }.map { WikiAlias.key($0.query) })
        var seenMisses: Set<String> = []
        var misses: [String] = []
        for entry in recent.reversed() where entry.title == nil {
            let key = WikiAlias.key(entry.query)
            guard !key.isEmpty, !resolvedKeys.contains(key), seenMisses.insert(key).inserted else { continue }
            misses.append(entry.query)
            if misses.count == 5 { break }
        }

        return WikiLookupUsageSummary(
            lookupsThisWeek: recent.filter { $0.at >= weekAgo }.count,
            topItems: Array(top),
            recentMisses: misses
        )
    }

    private func persist() {
        guard let url, let data = try? encoder.encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
