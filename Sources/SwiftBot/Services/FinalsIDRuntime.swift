import Foundation

actor GameTrackingStateStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(filename: String = SwiftBotStorage.gameTrackingStateFileName) {
        url = SwiftBotStorage.folderURL().appendingPathComponent(filename)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> GameTrackingRuntimeState {
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(GameTrackingRuntimeState.self, from: data) else {
            return GameTrackingRuntimeState()
        }
        return state
    }

    func save(_ state: GameTrackingRuntimeState) throws {
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }
}

enum GameTrackingDailySchedule {
    static func nextRun(
        after now: Date,
        lastAttemptAt: Date?,
        hour: Int,
        minute: Int,
        timeZoneIdentifier: String
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let safeHour = min(max(hour, 0), 23)
        let safeMinute = min(max(minute, 0), 59)
        let startOfToday = calendar.startOfDay(for: now)
        let scheduledToday = calendar.date(
            bySettingHour: safeHour,
            minute: safeMinute,
            second: 0,
            of: startOfToday
        ) ?? now

        let alreadyAttemptedToday: Bool
        if let lastAttemptAt {
            alreadyAttemptedToday = calendar.isDate(lastAttemptAt, inSameDayAs: now)
                && lastAttemptAt >= scheduledToday
        } else {
            alreadyAttemptedToday = false
        }

        if now < scheduledToday { return scheduledToday }
        if !alreadyAttemptedToday { return now }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
        return calendar.date(
            bySettingHour: safeHour,
            minute: safeMinute,
            second: 0,
            of: tomorrow
        ) ?? tomorrow
    }
}

enum GameTrackingNotificationBuilder {
    static func embed(changes: [GameRankChange], checkedAt: Date) -> [String: Any] {
        let sortedChanges = changes.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let fields: [[String: Any]] = sortedChanges.map { change in
            var lines: [String] = []

            if change.metricChanges.isEmpty {
                // Rating-only provider: the original single-score presentation.
                let sign = change.delta > 0 ? "+" : ""
                let unit = change.game.scoreUnit
                lines.append("**\(sign)\(change.delta.formatted()) \(unit)** · \(change.currentScore.formatted()) total")
            } else {
                for movement in change.metricChanges {
                    // The ranked score keeps the game's own unit label; every
                    // other metric is named explicitly so the number is legible.
                    if movement.metric == .rankedScore {
                        lines.append("**\(movement.formattedDelta) \(change.game.scoreUnit)** · \(movement.formattedCurrent) total")
                    } else {
                        lines.append("**\(movement.metric.displayName) \(movement.formattedCurrent)** (\(movement.formattedDelta))")
                    }
                }
            }

            // Context metrics that did not themselves trigger the post.
            let moved = Set(change.metricChanges.map(\.metric))
            let context = change.contextMetrics.presentMetrics.filter { !moved.contains($0) }
            if !context.isEmpty {
                let parts = context.compactMap { metric -> String? in
                    guard let value = change.contextMetrics[metric] else { return nil }
                    return "\(metric.displayName) \(metric.formatted(value))"
                }
                if !parts.isEmpty { lines.append(parts.joined(separator: " · ")) }
            }

            if let rankName = change.rankName, !rankName.isEmpty {
                lines.append(rankName)
            }
            if !change.season.isEmpty {
                lines.append(change.season.uppercased())
            }
            return [
                "name": change.displayName,
                "value": lines.joined(separator: "\n"),
                "inline": true
            ]
        }

        // Direction is taken from the headline score when it moved, otherwise
        // from the metrics that did, so a K/D-only profile still colours right.
        func direction(_ change: GameRankChange) -> Int {
            if change.delta != 0 { return change.delta > 0 ? 1 : -1 }
            let deltas = change.metricChanges.map(\.delta).filter { $0 != 0 }
            guard !deltas.isEmpty else { return 0 }
            if deltas.allSatisfy({ $0 > 0 }) { return 1 }
            if deltas.allSatisfy({ $0 < 0 }) { return -1 }
            return 0
        }
        let directions = sortedChanges.map(direction)
        let color: Int
        if directions.allSatisfy({ $0 > 0 }) {
            color = 0x3BA55D
        } else if directions.allSatisfy({ $0 < 0 }) {
            color = 0xED4245
        } else {
            color = 0xD21F3C
        }

        return [
            "title": "\(sortedChanges.first?.game.displayName ?? "Game") · Daily Ranked Update",
            "description": "Tracked stats changed since the previous daily check.",
            "color": color,
            "fields": fields,
            "footer": ["text": "Data provided by \(sortedChanges.first?.provider.displayName ?? "game provider")"],
            "timestamp": ISO8601DateFormatter().string(from: checkedAt)
        ]
    }
}
