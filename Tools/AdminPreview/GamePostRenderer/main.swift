import Foundation

// Dev-only: renders Game Tracker sample posts with the app's real
// GameAnnouncementRenderer so the AdminPreview server's style editor preview
// is live. Reads `{"style": {...}, "player": {...}}` on stdin and prints
// `{"rankUpdate": "<json>", "session": "<json>"}` — the same shape as
// AdminWebGameTrackerStylePreview. Mirrors AppModel.gameTrackerSamples.

struct Input: Decodable {
    struct Player: Decodable {
        var displayName: String?
        var score: Int?
        var rankName: String?
        var season: String?
        var discordUserID: String?
    }
    var style: GameAnnouncementStyle
    var player: Player?
}

let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
var style = input.style
style.normalize()

let game = GameID.theFinals
let name = input.player?.displayName ?? "Player"
let userID = input.player?.discordUserID ?? ""
let score = (input.player?.score).flatMap { $0 > 0 ? $0 : nil } ?? 28_160
let previousScore = max(0, score - 340)
let currentTier = game.rankTier(index: nil, score: score, league: nil)
let previousTier = game.rankTier(index: nil, score: previousScore, league: nil)
let position = 56_866.0

var current = GameMetricSet([.rankedScore: Double(score), .leaderboardPosition: position])
var previous = GameMetricSet([.rankedScore: Double(previousScore), .leaderboardPosition: position + 1_204])
var movements = [GameMetricChange(metric: .rankedScore, previous: Double(previousScore), current: Double(score))]
if let currentTier, let previousTier {
    current[.rankTier] = Double(currentTier.ladderPosition)
    previous[.rankTier] = Double(previousTier.ladderPosition)
    if currentTier.ladderPosition != previousTier.ladderPosition {
        movements.append(GameMetricChange(
            metric: .rankTier,
            previous: Double(previousTier.ladderPosition),
            current: Double(currentTier.ladderPosition)
        ))
    }
}

let change = GameRankChange(
    targetID: UUID(), game: game, provider: .finalsID, destinationChannelID: "",
    playerID: "player#0001", displayName: name,
    season: input.player?.season?.lowercased() ?? "s11", rankName: currentTier?.name,
    previousScore: previousScore, currentScore: score,
    metricChanges: movements,
    // What finals.id really reports on a rank check; nothing invented.
    contextMetrics: current,
    previousRankName: previousTier?.name,
    previousMetrics: previous, currentMetrics: current,
    discordUserID: userID
)

var totals = GameSessionSummaryBuilder.Totals()
totals.matches = 6; totals.rankedMatches = 4; totals.wins = 2
totals.kills = 38; totals.deaths = 21; totals.damage = 21_430
let end = Date()
let session = GameAnnouncementRenderer.SessionContext(
    session: GameSession(userID: userID, guildID: "", gameName: game.displayName,
                         startedAt: end.addingTimeInterval(-5_040), endedAt: end),
    displayName: name, game: game, providerName: GameProviderID.finalsID.displayName,
    totals: totals, rankName: currentTier?.name, score: score,
    rankIndex: currentTier?.ladderPosition, discordUserID: userID
)

func json(_ payload: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
}
let rank = GameAnnouncementRenderer.rankUpdateMessages(changes: [change], checkedAt: end, style: style).first?.payload ?? [:]
let output = ["rankUpdate": json(rank), "session": json(GameAnnouncementRenderer.sessionMessage(session, style: style))]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
