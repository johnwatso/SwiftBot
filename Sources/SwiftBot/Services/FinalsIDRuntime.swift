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
            let sign = change.delta > 0 ? "+" : ""
            let unit = change.game.scoreUnit
            var lines = ["**\(sign)\(change.delta.formatted()) \(unit)** · \(change.currentScore.formatted()) total"]
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

        let color: Int
        if sortedChanges.allSatisfy({ $0.delta > 0 }) {
            color = 0x3BA55D
        } else if sortedChanges.allSatisfy({ $0.delta < 0 }) {
            color = 0xED4245
        } else {
            color = 0xD21F3C
        }

        return [
            "title": "\(sortedChanges.first?.game.displayName ?? "Game") · Daily Ranked Update",
            "description": "Ranked score changed since the previous daily check.",
            "color": color,
            "fields": fields,
            "footer": ["text": "Data provided by \(sortedChanges.first?.provider.displayName ?? "game provider")"],
            "timestamp": ISO8601DateFormatter().string(from: checkedAt)
        ]
    }
}
