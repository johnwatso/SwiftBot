import Foundation

/// How Game Tracker posts look in Discord. Edited from the WebUI; one style
/// applies to every tracked player so a channel reads consistently.
struct GameAnnouncementStyle: Codable, Hashable, Sendable {
    enum Layout: String, Codable, CaseIterable, Sendable {
        /// One rich embed per player: tier colour, progress bar, stat fields.
        case card
        /// Every player in a single embed, one field each.
        case compact
        /// Plain text, one line per player.
        case minimal
    }

    enum Accent: String, Codable, CaseIterable, Sendable {
        /// The player's rank league colour (Gold is gold).
        case rank
        /// Green for a climb, red for a drop.
        case direction
        case custom
    }

    var layout: Layout = .card
    var accent: Accent = .rank
    /// `#RRGGBB`, used when `accent` is `.custom`.
    var customColor = "#D21F3C"
    /// Changes that cause a rank post. Counters such as kills are ignored —
    /// they climb every match — see `effectiveAnnounceOn`.
    var announceOn: Set<GameMetricID> = [.rankedScore, .rankTier]
    /// Stats shown on posts wherever the data has them. Everything is
    /// recorded regardless; this only decides what gets shared.
    var sharedStats: Set<GameMetricID> = Self.defaultSharedStats
    /// Progress bar towards the next division.
    var showProgress = true
    var showSeason = true
    /// Ping the linked Discord member.
    var mentionPlayer = false
    /// Empty uses the built-in headline. See `GameAnnouncementRenderer` for
    /// the placeholders each template understands.
    var rankTitleTemplate = ""
    var sessionTitleTemplate = ""
    /// Empty credits the data provider.
    var footerText = ""

    static let maxTemplateLength = 200

    static let defaultSharedStats: Set<GameMetricID> = [
        .rankTier, .rankedScore, .leaderboardPosition,
        .matchesPlayed, .wins, .kills, .deaths, .killDeathRatio, .damage
    ]

    var effectiveAnnounceOn: Set<GameMetricID> {
        announceOn.filter(\.canTriggerAnnouncement)
    }

    func shares(_ metric: GameMetricID) -> Bool {
        sharedStats.contains(metric)
    }

    init() {}

    /// Every field is optional on disk so a style saved by an older or newer
    /// build never fails the whole settings file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GameAnnouncementStyle()
        layout = (try? c.decodeIfPresent(Layout.self, forKey: .layout)) ?? defaults.layout
        accent = (try? c.decodeIfPresent(Accent.self, forKey: .accent)) ?? defaults.accent
        customColor = (try? c.decodeIfPresent(String.self, forKey: .customColor)) ?? defaults.customColor
        announceOn = (try? c.decodeIfPresent(Set<GameMetricID>.self, forKey: .announceOn)) ?? defaults.announceOn
        if let shared = try? c.decodeIfPresent(Set<GameMetricID>.self, forKey: .sharedStats) {
            sharedStats = shared
        } else {
            // Styles saved before per-stat sharing had two switches.
            var shared = defaults.sharedStats
            if (try? c.decodeIfPresent(Bool.self, forKey: .showLeaderboard)) == false {
                shared.remove(.leaderboardPosition)
            }
            if (try? c.decodeIfPresent(Bool.self, forKey: .showStats)) == false {
                shared.subtract([.matchesPlayed, .wins, .kills, .deaths, .killDeathRatio, .damage])
            }
            sharedStats = shared
        }
        showProgress = (try? c.decodeIfPresent(Bool.self, forKey: .showProgress)) ?? defaults.showProgress
        showSeason = (try? c.decodeIfPresent(Bool.self, forKey: .showSeason)) ?? defaults.showSeason
        mentionPlayer = (try? c.decodeIfPresent(Bool.self, forKey: .mentionPlayer)) ?? defaults.mentionPlayer
        rankTitleTemplate = (try? c.decodeIfPresent(String.self, forKey: .rankTitleTemplate)) ?? ""
        sessionTitleTemplate = (try? c.decodeIfPresent(String.self, forKey: .sessionTitleTemplate)) ?? ""
        footerText = (try? c.decodeIfPresent(String.self, forKey: .footerText)) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case layout, accent, customColor, announceOn, sharedStats, showProgress, showSeason, mentionPlayer
        case rankTitleTemplate, sessionTitleTemplate, footerText
        // Decode-only, from before `sharedStats`.
        case showLeaderboard, showStats
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(layout, forKey: .layout)
        try c.encode(accent, forKey: .accent)
        try c.encode(customColor, forKey: .customColor)
        try c.encode(announceOn.map(\.rawValue).sorted(), forKey: .announceOn)
        try c.encode(sharedStats.map(\.rawValue).sorted(), forKey: .sharedStats)
        try c.encode(showProgress, forKey: .showProgress)
        try c.encode(showSeason, forKey: .showSeason)
        try c.encode(mentionPlayer, forKey: .mentionPlayer)
        try c.encode(rankTitleTemplate, forKey: .rankTitleTemplate)
        try c.encode(sessionTitleTemplate, forKey: .sessionTitleTemplate)
        try c.encode(footerText, forKey: .footerText)
    }

    /// The custom colour as an embed integer, or nil when it is not valid hex.
    var customColorValue: Int? {
        Self.parseHexColor(customColor)
    }

    static func parseHexColor(_ text: String) -> Int? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return value
    }

    mutating func normalize() {
        announceOn = effectiveAnnounceOn
        if customColorValue == nil { customColor = GameAnnouncementStyle().customColor }
        rankTitleTemplate = Self.clean(rankTitleTemplate)
        sessionTitleTemplate = Self.clean(sessionTitleTemplate)
        footerText = Self.clean(footerText)
    }

    private static func clean(_ text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(maxTemplateLength))
    }
}
