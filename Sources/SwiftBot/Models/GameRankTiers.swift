import Foundation

/// A named rank division such as "Gold 1". Providers report a rank as a bare
/// index (finals.id's `rankIndex: 12`) plus a league name ("Gold"); people
/// talk about "Gold 1", so this is what announcements and the UI show.
struct GameRankTier: Hashable, Sendable {
    let league: String
    /// 1 is the top division of a league. Nil for an undivided league (Ruby).
    let division: Int?
    /// Discord embed colour for the league.
    let color: Int
    let emoji: String
    /// Score at which this division starts, when divisions are score bands.
    let floorScore: Int?
    /// Score at which the next division starts. Nil at the top of the ladder.
    let nextScore: Int?
    /// Name of the division above, e.g. "Platinum 4".
    let nextName: String?
    /// Position on the ladder, used to tell a promotion from a demotion.
    let ladderPosition: Int

    var name: String {
        division.map { "\(league) \($0)" } ?? league
    }

    /// Fraction of the way through this division, when it is a score band.
    func progress(score: Int) -> Double? {
        // Outside the band means the provider's index and score disagree;
        // show no bar rather than a misleading full or empty one.
        guard let floorScore, let nextScore, (floorScore..<nextScore).contains(score) else { return nil }
        return Double(score - floorScore) / Double(nextScore - floorScore)
    }
}

extension GameID {
    /// Resolves whatever rank data a provider supplied into a named division.
    /// The index is trusted only when it agrees with the league name; a
    /// disagreement falls back to the score band, then to the league alone,
    /// so a provider renumbering its ladder can never announce the wrong tier.
    func rankTier(index: Int?, score: Int?, league: String?) -> GameRankTier? {
        switch self {
        case .theFinals:
            return TheFinalsRankLadder.tier(index: index, score: score, league: league)
        }
    }

    /// Display text for one metric reading. Most metrics format themselves;
    /// the rank tier needs the game's ladder to turn "12" into "Gold 1".
    func formattedMetric(_ metric: GameMetricID, _ value: Double, score: Int? = nil, league: String? = nil) -> String {
        if metric == .rankTier,
           let tier = rankTier(index: Int(value.rounded()), score: score, league: league) {
            return tier.name
        }
        return metric.formatted(value)
    }
}

/// THE FINALS ranked ladder: Bronze through Diamond, four divisions each,
/// 2,500 SR per division from 0, then Ruby for the top 500 on the leaderboard.
/// finals.id numbers it from 1 (Bronze 4) to 20 (Diamond 1) and 21 (Ruby).
enum TheFinalsRankLadder {
    static let divisionWidth = 2_500
    static let rubyIndex = 21

    private struct League {
        let name: String
        let color: Int
        let emoji: String
    }

    private static let leagues: [League] = [
        League(name: "Bronze", color: 0xB0703C, emoji: "🥉"),
        League(name: "Silver", color: 0xAEB8C4, emoji: "🥈"),
        League(name: "Gold", color: 0xF1C40F, emoji: "🥇"),
        League(name: "Platinum", color: 0x4FD1C5, emoji: "💠"),
        League(name: "Diamond", color: 0x5DADEC, emoji: "💎")
    ]
    private static let ruby = League(name: "Ruby", color: 0xE0115F, emoji: "♦️")

    static func tier(index: Int?, score: Int?, league rawLeague: String?) -> GameRankTier? {
        // Accept "Gold" from the API or a resolved "Gold 1" read back from a
        // stored baseline; only the league word is compared.
        let league = rawLeague?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: " ")
            .first
            .map(String.init) ?? ""

        if league == "ruby" || index == rubyIndex { return rubyTier }

        if let index, (1...20).contains(index) {
            let candidate = divisionTier(index: index)
            if league.isEmpty || candidate.league.lowercased() == league { return candidate }
        }

        if let score, score >= 0 {
            let index = min(score / divisionWidth, 19) + 1
            let candidate = divisionTier(index: index)
            if league.isEmpty || candidate.league.lowercased() == league { return candidate }
        }

        // Only a league name to go on: show it undivided rather than guess.
        if let match = leagues.firstIndex(where: { $0.name.lowercased() == league }) {
            let entry = leagues[match]
            return GameRankTier(
                league: entry.name, division: nil, color: entry.color, emoji: entry.emoji,
                floorScore: nil, nextScore: nil, nextName: nil, ladderPosition: match * 4 + 1
            )
        }
        return nil
    }

    /// `index` is 1-based: 1 is Bronze 4, 4 is Bronze 1, 5 is Silver 4.
    private static func divisionTier(index: Int) -> GameRankTier {
        let zeroBased = index - 1
        let entry = leagues[zeroBased / 4]
        let floor = zeroBased * divisionWidth
        let nextName: String?
        if index < 20 {
            let next = zeroBased + 1
            nextName = "\(leagues[next / 4].name) \(4 - next % 4)"
        } else {
            nextName = nil
        }
        return GameRankTier(
            league: entry.name,
            division: 4 - zeroBased % 4,
            color: entry.color,
            emoji: entry.emoji,
            floorScore: floor,
            // Diamond 1 has no score ceiling: Ruby is a leaderboard position.
            nextScore: index < 20 ? floor + divisionWidth : nil,
            nextName: nextName,
            ladderPosition: index
        )
    }

    private static var rubyTier: GameRankTier {
        GameRankTier(
            league: ruby.name, division: nil, color: ruby.color, emoji: ruby.emoji,
            floorScore: nil, nextScore: nil, nextName: nil, ladderPosition: rubyIndex
        )
    }
}
