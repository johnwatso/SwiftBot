import Foundation

// Just enough of the app for the Game Tracker model and renderer files to
// compile on their own. Kept in step with the real definitions by hand; the
// compiler complains the moment they drift.

enum SwiftBotStorage {
    static let gameTrackingStateFileName = "game-tracking.json"
    static func folderURL() -> URL { FileManager.default.temporaryDirectory }
}

struct GameSession: Hashable, Sendable {
    let userID: String
    let guildID: String
    let gameName: String
    let startedAt: Date
    var endedAt: Date?

    var duration: TimeInterval {
        max(0, (endedAt ?? startedAt).timeIntervalSince(startedAt))
    }
}

struct GameSessionTrackerConfiguration {
    var absenceGrace: TimeInterval
    var minimumSessionDuration: TimeInterval
}
