import Foundation

/// Turns Game Tracker events into Discord message payloads according to the
/// operator's `GameAnnouncementStyle`. The WebUI preview is built by these same
/// functions, so what the editor shows is exactly what the channel receives.
///
/// Title templates understand these placeholders:
/// - rank updates: `{player}` `{rank}` `{previousRank}` `{score}` `{delta}`
///   `{unit}` `{game}` `{leaderboard}`
/// - sessions: `{player}` `{game}` `{duration}` `{matches}` `{wins}` `{kd}` `{rank}`
/// - footer: `{game}` `{provider}` `{season}`
enum GameAnnouncementRenderer {
    /// Discord's per-message embed limit.
    static let maxEmbedsPerMessage = 10
    private static let maxContentLength = 2_000
    private static let fallbackColor = 0x5865F2
    private static let upColor = 0x3BA55D
    private static let downColor = 0xED4245
    private static let mixedColor = 0xD21F3C

    /// One Discord message and the players whose changes it carries, so the
    /// caller only advances baselines for messages that were delivered.
    struct Message {
        let payload: [String: Any]
        let targetIDs: [UUID]
    }

    // MARK: - Rank updates

    static func rankUpdateMessages(
        changes: [GameRankChange],
        checkedAt: Date,
        style: GameAnnouncementStyle,
        isTest: Bool = false
    ) -> [Message] {
        let sorted = changes.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        guard !sorted.isEmpty else { return [] }

        switch style.layout {
        case .card:
            return stride(from: 0, to: sorted.count, by: maxEmbedsPerMessage).map { start in
                let batch = Array(sorted[start..<min(start + maxEmbedsPerMessage, sorted.count)])
                var payload: [String: Any] = [
                    "embeds": batch.map { rankCard($0, checkedAt: checkedAt, style: style, isTest: isTest) }
                ]
                applyMentions(batch.map(\.discordUserID), style: style, to: &payload)
                return Message(payload: payload, targetIDs: batch.map(\.targetID))
            }

        case .compact:
            var embed = GameTrackingNotificationBuilder.embed(changes: sorted, checkedAt: checkedAt, shared: style.sharedStats)
            if let color = accentColor(style: style, tier: sorted.count == 1 ? sorted[0].currentTier : nil, direction: nil) {
                embed["color"] = color
            }
            embed["footer"] = ["text": footer(
                style: style, game: sorted[0].game, providerName: sorted[0].provider.displayName,
                season: sorted.count == 1 ? sorted[0].season : "", isTest: isTest
            )]
            var payload: [String: Any] = ["embeds": [embed]]
            applyMentions(sorted.map(\.discordUserID), style: style, to: &payload)
            return [Message(payload: payload, targetIDs: sorted.map(\.targetID))]

        case .minimal:
            let lines = sorted.map { minimalLine($0, style: style) }
            return chunk(lines: lines, prefix: isTest ? "*Test post*" : nil).map { range, text in
                var payload: [String: Any] = ["content": text]
                let batch = Array(sorted[range])
                if style.mentionPlayer {
                    payload["allowed_mentions"] = ["parse": [], "users": validMentionIDs(batch.map(\.discordUserID))]
                } else {
                    payload["allowed_mentions"] = ["parse": []]
                }
                return Message(payload: payload, targetIDs: batch.map(\.targetID))
            }
        }
    }

    static func rankCard(
        _ change: GameRankChange,
        checkedAt: Date,
        style: GameAnnouncementStyle,
        isTest: Bool = false
    ) -> [String: Any] {
        // Everything is recorded; only what the style shares appears here.
        let tier = style.shares(.rankTier) ? change.currentTier : nil
        let unit = change.game.scoreUnit
        let hasScore = style.shares(.rankedScore) && (change.currentScore != 0 || change.previousScore != 0)

        // Headline standing, then the progress bar towards the next division.
        var standing = "**\(change.displayName)**"
        if let tier {
            standing += " is \(tier.emoji) **\(tier.name)**"
        }
        if hasScore {
            standing += " · \(change.currentScore.formatted()) \(unit)"
        }
        var description = [standing]
        if style.showProgress, let tier, hasScore, let progress = tier.progress(score: change.currentScore),
           let nextScore = tier.nextScore, let nextName = tier.nextName {
            let remaining = max(0, nextScore - change.currentScore)
            description.append("`\(progressBar(progress))` \(remaining.formatted()) \(unit) to \(nextName)")
        }

        var fields: [[String: Any]] = []
        if change.tierMovement != 0, let previous = change.previousTier, let tier {
            fields.append(field("Rank", "\(previous.name) → **\(tier.name)**"))
        }
        if hasScore, change.delta != 0 {
            fields.append(field("\(unit) change", "**\(signed(change.delta))** → \(change.currentScore.formatted())"))
        }
        if style.shares(.leaderboardPosition), let position = change.currentMetrics[.leaderboardPosition] {
            var value = "**\(GameMetricID.leaderboardPosition.formatted(position))**"
            if let before = change.previousMetrics[.leaderboardPosition], before != position {
                value += " (\(GameMetricID.leaderboardPosition.formattedDelta(position - before)))"
            }
            fields.append(field("Leaderboard", value))
        }
        let shown: Set<GameMetricID> = [.rankedScore, .rankTier, .leaderboardPosition]
        for movement in change.metricChanges where !shown.contains(movement.metric) && style.shares(movement.metric) {
            fields.append(field(movement.metric.displayName, "**\(movement.formattedCurrent)** (\(movement.formattedDelta))"))
        }
        let moved = Set(change.metricChanges.map(\.metric)).union(shown)
        for metric in change.contextMetrics.presentMetrics where !moved.contains(metric) && style.shares(metric) {
            guard let value = change.contextMetrics[metric] else { continue }
            fields.append(field(metric.displayName, change.game.formattedMetric(metric, value)))
        }

        var embed: [String: Any] = [
            "author": ["name": "\(change.game.displayName) · Ranked"],
            "title": truncate(rankTitle(change, style: style), 256),
            "description": description.joined(separator: "\n"),
            "color": accentColor(style: style, tier: tier, direction: direction(change)) ?? fallbackColor,
            "footer": ["text": footer(
                style: style, game: change.game, providerName: change.provider.displayName,
                season: change.season, isTest: isTest
            )],
            "timestamp": ISO8601DateFormatter().string(from: checkedAt)
        ]
        if !fields.isEmpty { embed["fields"] = fields }
        return embed
    }

    static func rankTitle(_ change: GameRankChange, style: GameAnnouncementStyle) -> String {
        let unit = change.game.scoreUnit
        let template = style.rankTitleTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !template.isEmpty {
            let leaderboard = change.currentMetrics[.leaderboardPosition]
                .map { GameMetricID.leaderboardPosition.formatted($0) } ?? ""
            return fill(template, [
                "player": change.displayName,
                "rank": change.currentTier?.name ?? change.rankName ?? "",
                "previousRank": change.previousTier?.name ?? change.previousRankName ?? "",
                "score": change.currentScore.formatted(),
                "delta": signed(change.delta),
                "unit": unit,
                "game": change.game.displayName,
                "leaderboard": leaderboard
            ])
        }
        if style.shares(.rankTier), change.tierMovement != 0, let tier = change.currentTier {
            return change.tierMovement > 0 ? "▲ Ranked up to \(tier.name)" : "▼ Dropped to \(tier.name)"
        }
        if style.shares(.rankedScore) {
            if change.delta > 0 { return "▲ \(signed(change.delta)) \(unit)" }
            if change.delta < 0 { return "▼ \(abs(change.delta).formatted()) \(unit) lost" }
        }
        if let movement = change.metricChanges.first(where: { style.shares($0.metric) && $0.metric != .rankTier && $0.metric != .rankedScore }) {
            return "\(movement.metric.displayName) \(movement.formattedCurrent) (\(movement.formattedDelta))"
        }
        return "Stats updated"
    }

    private static func minimalLine(_ change: GameRankChange, style: GameAnnouncementStyle) -> String {
        let arrow: String
        switch direction(change) {
        case 1: arrow = "▲"
        case -1: arrow = "▼"
        default: arrow = "•"
        }
        var who = "**\(change.displayName)**"
        if style.mentionPlayer, isValidMentionID(change.discordUserID) {
            who = "<@\(change.discordUserID)>"
        }
        var parts: [String] = []
        let tier = style.shares(.rankTier) ? change.currentTier : nil
        if change.tierMovement != 0, let tier {
            parts.append("\(change.tierMovement > 0 ? "ranked up to" : "dropped to") \(tier.emoji) **\(tier.name)**")
        } else if let tier {
            parts.append("\(tier.emoji) \(tier.name)")
        }
        if style.shares(.rankedScore), change.delta != 0 {
            parts.append("\(change.currentScore.formatted()) \(change.game.scoreUnit) (\(signed(change.delta)))")
        }
        for movement in change.metricChanges
        where movement.metric != .rankedScore && movement.metric != .rankTier && style.shares(movement.metric) {
            parts.append("\(movement.metric.displayName) \(movement.formattedCurrent) (\(movement.formattedDelta))")
        }
        if style.shares(.leaderboardPosition), let position = change.currentMetrics[.leaderboardPosition] {
            parts.append(GameMetricID.leaderboardPosition.formatted(position))
        }
        return "\(arrow) \(who) " + parts.joined(separator: " · ")
    }

    // MARK: - Sessions

    /// Everything a session post can mention. Rank fields come from the
    /// player's last ranked baseline, when there is one.
    struct SessionContext {
        var session: GameSession
        var displayName: String
        var game: GameID?
        var providerName: String?
        var totals: GameSessionSummaryBuilder.Totals?
        var rankName: String?
        var score: Int?
        var rankIndex: Int?
        var discordUserID: String = ""

        var gameName: String { game?.displayName ?? session.gameName }

        var tier: GameRankTier? {
            game?.rankTier(index: rankIndex, score: score.flatMap { $0 > 0 ? $0 : nil }, league: rankName)
        }
    }

    static func sessionMessage(
        _ context: SessionContext,
        style: GameAnnouncementStyle,
        isTest: Bool = false
    ) -> [String: Any] {
        let duration = GameSessionSummaryBuilder.durationText(context.session.duration)
        let totals = context.totals.flatMap { $0.matches > 0 ? $0 : nil }

        switch style.layout {
        case .compact:
            var embed = GameSessionSummaryBuilder.embed(
                session: context.session,
                displayName: context.displayName,
                game: context.game,
                providerName: context.providerName,
                totals: context.totals
            )
            if let color = accentColor(style: style, tier: context.tier, direction: nil) { embed["color"] = color }
            let fieldMetric: [String: GameMetricID] = [
                "Matches": .matchesPlayed, "Wins": .wins, "Eliminations": .kills, "K/D": .killDeathRatio, "Damage": .damage
            ]
            embed["fields"] = (embed["fields"] as? [[String: Any]])?.filter { field in
                guard let name = field["name"] as? String, let metric = fieldMetric[name] else { return true }
                return style.shares(metric)
            }
            if !style.footerText.isEmpty || isTest {
                embed["footer"] = ["text": sessionFooter(context, style: style, isTest: isTest)]
            }
            var payload: [String: Any] = ["embeds": [embed]]
            applyMentions([context.discordUserID], style: style, to: &payload)
            return payload

        case .minimal:
            var who = "**\(context.displayName)**"
            if style.mentionPlayer, isValidMentionID(context.discordUserID) {
                who = "<@\(context.discordUserID)>"
            }
            var line = "🎮 \(who) played \(context.gameName) for \(duration)"
            if let totals, !highlightParts(totals, style: style).isEmpty {
                line += " — " + highlightParts(totals, style: style).map { "\($0.value) \($0.label)" }.joined(separator: " · ")
            }
            if isTest { line = "*Test post*\n" + line }
            return [
                "content": truncate(line, maxContentLength),
                "allowed_mentions": style.mentionPlayer
                    ? ["parse": [], "users": validMentionIDs([context.discordUserID])]
                    : ["parse": []]
            ]

        case .card:
            var fields: [[String: Any]] = [field("Duration", duration)]
            if style.shares(.rankTier), let tier = context.tier {
                var value = "\(tier.emoji) **\(tier.name)**"
                if style.shares(.rankedScore), let score = context.score, score > 0, let unit = context.game?.scoreUnit {
                    value += " · \(score.formatted()) \(unit)"
                }
                fields.append(field("Rank", value))
            }
            if let totals {
                if style.shares(.matchesPlayed) {
                    fields.append(field(
                        "Matches",
                        totals.rankedMatches > 0 ? "\(totals.matches) (\(totals.rankedMatches) ranked)" : "\(totals.matches)"
                    ))
                }
                if style.shares(.wins) { fields.append(field("Wins", "\(totals.wins)")) }
                if style.shares(.kills) {
                    fields.append(field(
                        "Eliminations",
                        style.shares(.deaths) ? "\(totals.kills) / \(totals.deaths) deaths" : "\(totals.kills)"
                    ))
                } else if style.shares(.deaths) {
                    fields.append(field("Deaths", "\(totals.deaths)"))
                }
                if style.shares(.killDeathRatio), let ratio = totals.killDeathRatio {
                    fields.append(field("K/D", String(format: "%.2f", ratio)))
                }
                if style.shares(.damage), totals.damage > 0 {
                    fields.append(field("Damage", Int(totals.damage.rounded()).formatted()))
                }
            }

            let description: String
            if let totals, !highlightParts(totals, style: style).isEmpty {
                description = highlightParts(totals, style: style).map { "**\($0.value)** \($0.label)" }.joined(separator: " · ")
            } else if totals != nil {
                description = "Session complete."
            } else if context.providerName == nil {
                description = "Session detected from Discord presence."
            } else {
                description = "No completed matches found for this session."
            }

            var embed: [String: Any] = [
                "author": ["name": "\(context.gameName) · Session"],
                "title": truncate(sessionTitle(context, style: style), 256),
                "description": description,
                "color": accentColor(style: style, tier: context.tier, direction: nil) ?? fallbackColor,
                "fields": fields,
                "footer": ["text": sessionFooter(context, style: style, isTest: isTest)],
                "timestamp": ISO8601DateFormatter().string(from: context.session.endedAt ?? Date())
            ]
            var payload: [String: Any] = ["embeds": [embed]]
            applyMentions([context.discordUserID], style: style, to: &payload)
            return payload
        }
    }

    static func sessionTitle(_ context: SessionContext, style: GameAnnouncementStyle) -> String {
        let duration = GameSessionSummaryBuilder.durationText(context.session.duration)
        let template = style.sessionTitleTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else {
            return "\(context.displayName) played for \(duration)"
        }
        let totals = context.totals
        return fill(template, [
            "player": context.displayName,
            "game": context.gameName,
            "duration": duration,
            "matches": totals.map { "\($0.matches)" } ?? "0",
            "wins": totals.map { "\($0.wins)" } ?? "0",
            "kd": totals?.killDeathRatio.map { String(format: "%.2f", $0) } ?? "–",
            "rank": context.tier?.name ?? context.rankName ?? ""
        ])
    }

    private static func highlightParts(
        _ totals: GameSessionSummaryBuilder.Totals,
        style: GameAnnouncementStyle
    ) -> [(value: String, label: String)] {
        var parts: [(value: String, label: String)] = []
        if style.shares(.matchesPlayed) {
            parts.append(("\(totals.matches)", totals.matches == 1 ? "match" : "matches"))
        }
        if style.shares(.wins) {
            parts.append(("\(totals.wins)", totals.wins == 1 ? "win" : "wins"))
        }
        if style.shares(.killDeathRatio), let ratio = totals.killDeathRatio {
            parts.append((String(format: "%.2f", ratio), "K/D"))
        }
        return parts
    }

    private static func sessionFooter(_ context: SessionContext, style: GameAnnouncementStyle, isTest: Bool) -> String {
        if style.footerText.isEmpty {
            let base = context.providerName.map { "Data provided by \($0)" } ?? "Detected from Discord presence"
            return isTest ? "Test post · \(base)" : base
        }
        let text = fill(style.footerText, [
            "game": context.gameName,
            "provider": context.providerName ?? "Discord presence",
            "season": ""
        ])
        return isTest ? "Test post · \(text)" : text
    }

    // MARK: - Shared pieces

    /// +1 climb, -1 drop, 0 mixed or flat. Promotions win over the score so a
    /// rank-up with a small SR wobble still reads as good news.
    static func direction(_ change: GameRankChange) -> Int {
        if change.tierMovement != 0 { return change.tierMovement }
        if change.delta != 0 { return change.delta > 0 ? 1 : -1 }
        let deltas = change.metricChanges.map { $0.metric.lowerIsBetter ? -$0.delta : $0.delta }.filter { $0 != 0 }
        guard !deltas.isEmpty else { return 0 }
        if deltas.allSatisfy({ $0 > 0 }) { return 1 }
        if deltas.allSatisfy({ $0 < 0 }) { return -1 }
        return 0
    }

    /// Nil leaves the caller's own default colour in place.
    static func accentColor(style: GameAnnouncementStyle, tier: GameRankTier?, direction: Int?) -> Int? {
        switch style.accent {
        case .custom:
            return style.customColorValue
        case .rank:
            return tier?.color
        case .direction:
            switch direction {
            case .some(1): return upColor
            case .some(-1): return downColor
            case .some: return mixedColor
            case .none: return nil
            }
        }
    }

    private static func footer(
        style: GameAnnouncementStyle,
        game: GameID,
        providerName: String,
        season: String,
        isTest: Bool
    ) -> String {
        let seasonText = style.showSeason ? seasonLabel(season) : ""
        let text: String
        if style.footerText.isEmpty {
            text = [seasonText, "Data provided by \(providerName)"].filter { !$0.isEmpty }.joined(separator: " · ")
        } else {
            text = fill(style.footerText, [
                "game": game.displayName,
                "provider": providerName,
                "season": seasonLabel(season)
            ])
        }
        return isTest ? "Test post · \(text)" : text
    }

    /// "s11" → "Season 11"; anything else is shown as the provider wrote it.
    static func seasonLabel(_ season: String) -> String {
        let trimmed = season.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("s"), let number = Int(lower.dropFirst()) {
            return "Season \(number)"
        }
        return trimmed.uppercased()
    }

    static func progressBar(_ fraction: Double, width: Int = 10) -> String {
        let filled = Int((min(max(fraction, 0), 1) * Double(width)).rounded(.down))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }

    private static func field(_ name: String, _ value: String, inline: Bool = true) -> [String: Any] {
        ["name": truncate(name, 256), "value": truncate(value, 1_024), "inline": inline]
    }

    private static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value.formatted())" : (value < 0 ? "-\(abs(value).formatted())" : "±0")
    }

    private static func fill(_ template: String, _ values: [String: String]) -> String {
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }

    private static func truncate(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    static func isValidMentionID(_ id: String) -> Bool {
        (15...21).contains(id.count) && id.allSatisfy(\.isASCII) && id.allSatisfy(\.isNumber)
    }

    private static func validMentionIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { isValidMentionID($0) && seen.insert($0).inserted }
    }

    /// Mentions only ever ping the linked members; `parse: []` stops a
    /// player name like "@everyone" from pinging the channel.
    private static func applyMentions(_ ids: [String], style: GameAnnouncementStyle, to payload: inout [String: Any]) {
        let valid = style.mentionPlayer ? validMentionIDs(ids) : []
        if !valid.isEmpty {
            payload["content"] = valid.map { "<@\($0)>" }.joined(separator: " ")
        }
        payload["allowed_mentions"] = ["parse": [], "users": valid]
    }

    /// Splits plain-text lines into messages under Discord's content limit.
    private static func chunk(lines: [String], prefix: String?) -> [(Range<Int>, String)] {
        var result: [(Range<Int>, String)] = []
        var start = 0
        var text = prefix ?? ""
        for (index, line) in lines.enumerated() {
            let candidate = text.isEmpty ? line : text + "\n" + line
            if candidate.count > maxContentLength, index > start {
                result.append((start..<index, text))
                start = index
                text = truncate(line, maxContentLength)
            } else {
                text = truncate(candidate, maxContentLength)
            }
        }
        result.append((start..<lines.count, text))
        return result
    }
}
