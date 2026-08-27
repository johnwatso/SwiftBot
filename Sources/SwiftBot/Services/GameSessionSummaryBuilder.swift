import Foundation

/// Builds the Discord embed posted when a play session ends.
///
/// Deliberately independent of ranked score: the observed finals.id payload for
/// a casual match carries no SR at all, so a summary is built from whatever the
/// provider actually returned. When rounds are unavailable the embed still
/// reports the session itself from presence alone, which is all a presence-only
/// game such as Call of Duty can offer.
enum GameSessionSummaryBuilder {

    static func durationText(_ duration: TimeInterval) -> String {
        let totalMinutes = Int(duration / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(1, minutes))m"
    }

    /// Aggregates the rounds that fall inside the session window.
    struct Totals: Equatable {
        var matches = 0
        var kills = 0
        var deaths = 0
        var damage: Double = 0
        var wins = 0
        var rankedMatches = 0

        var killDeathRatio: Double? {
            guard deaths > 0 else { return kills > 0 ? Double(kills) : nil }
            return Double(kills) / Double(deaths)
        }
    }

    static func totals(
        for session: GameSession,
        rounds: [FinalsIDPlayedRound],
        dateParser: (String) -> Date? = { ISO8601DateFormatter().date(from: $0) }
    ) -> Totals {
        var totals = Totals()
        for round in rounds {
            // Only count matches that actually fall in the session window; the
            // provider returns a rolling history, not just this session.
            guard let started = dateParser(round.startedAt) else { continue }
            guard started >= session.startedAt.addingTimeInterval(-300) else { continue }
            if let ended = session.endedAt, started > ended.addingTimeInterval(300) { continue }

            totals.matches += 1
            totals.kills += round.kills
            totals.deaths += round.deaths
            totals.damage += round.damage
            if round.isRanked { totals.rankedMatches += 1 }
            if round.rounds.contains(where: { $0.roundWon == true }) { totals.wins += 1 }
        }
        return totals
    }

    static func embed(
        session: GameSession,
        displayName: String,
        game: GameID?,
        providerName: String?,
        totals: Totals?
    ) -> [String: Any] {
        var fields: [[String: Any]] = [
            [
                "name": "Session",
                "value": durationText(session.duration),
                "inline": true
            ]
        ]

        if let totals, totals.matches > 0 {
            fields.append([
                "name": "Matches",
                "value": totals.rankedMatches > 0
                    ? "\(totals.matches) (\(totals.rankedMatches) ranked)"
                    : "\(totals.matches)",
                "inline": true
            ])
            fields.append([
                "name": "Wins",
                "value": "\(totals.wins)",
                "inline": true
            ])
            fields.append([
                "name": "Eliminations",
                "value": "\(totals.kills) / \(totals.deaths) deaths",
                "inline": true
            ])
            if let ratio = totals.killDeathRatio {
                fields.append([
                    "name": "K/D",
                    "value": String(format: "%.2f", ratio),
                    "inline": true
                ])
            }
            if totals.damage > 0 {
                fields.append([
                    "name": "Damage",
                    "value": Int(totals.damage.rounded()).formatted(),
                    "inline": true
                ])
            }
        }

        var embed: [String: Any] = [
            "title": "\(game?.displayName ?? session.gameName) · Session Complete",
            "description": "\(displayName) wrapped up a \(durationText(session.duration)) session.",
            "color": 0x5865F2,
            "fields": fields,
            "timestamp": ISO8601DateFormatter().string(from: session.endedAt ?? Date())
        ]

        if let providerName {
            embed["footer"] = ["text": "Data provided by \(providerName)"]
        } else {
            // Presence-only games have no stats provider behind them; say so
            // rather than implying the numbers came from somewhere.
            embed["footer"] = ["text": "Detected from Discord presence"]
        }
        return embed
    }
}
