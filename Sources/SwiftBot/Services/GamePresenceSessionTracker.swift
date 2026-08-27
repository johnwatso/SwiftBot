import Foundation

/// A play session inferred from Discord rich presence.
struct GameSession: Hashable, Sendable, Identifiable {
    let userID: String
    let guildID: String
    let gameName: String
    let startedAt: Date
    var endedAt: Date?

    var id: String { "\(userID)-\(gameName)-\(startedAt.timeIntervalSince1970)" }

    var duration: TimeInterval {
        max(0, (endedAt ?? startedAt).timeIntervalSince(startedAt))
    }
}

enum GameSessionEvent: Hashable, Sendable {
    case started(GameSession)
    case ended(GameSession)
}

struct GameSessionTrackerConfiguration: Hashable, Sendable {
    /// How long a game activity must stay absent before the session is treated
    /// as over. Discord drops and re-adds activities on client restarts, Alt-F4,
    /// and detector glitches, so ending immediately would double-report.
    var absenceGrace: TimeInterval = 180
    /// Sessions shorter than this never announce — a game opened and closed
    /// again is not a session worth posting about.
    var minimumSessionDuration: TimeInterval = 300

    static let `default` = GameSessionTrackerConfiguration()
}

/// Turns a stream of `PRESENCE_UPDATE` events into start/end session events.
///
/// Deliberately pure and synchronous: all timing is driven by the `now` passed
/// in, so the debounce behaviour is testable without sleeping.
///
/// Discord sends a member's *aggregate* presence across all their clients, so a
/// user online on both phone and desktop yields one activity list here and needs
/// no extra merging.
struct GamePresenceSessionTracker {
    private struct LiveSession {
        var session: GameSession
        /// Set when the activity disappears; cleared if it comes back within the
        /// grace window.
        var pendingEndSince: Date?
    }

    /// Keyed by user + normalized game name.
    private struct Key: Hashable {
        let userID: String
        let gameName: String
    }

    private var live: [Key: LiveSession] = [:]
    let configuration: GameSessionTrackerConfiguration

    init(configuration: GameSessionTrackerConfiguration = .default) {
        self.configuration = configuration
    }

    /// Games currently considered in-session for a user.
    func activeGames(for userID: String) -> [String] {
        live.filter { $0.key.userID == userID && $0.value.pendingEndSince == nil }
            .map(\.value.session.gameName)
            .sorted()
    }

    var activeSessionCount: Int {
        live.values.filter { $0.pendingEndSince == nil }.count
    }

    /// Feed one presence update. Returns any session starts detected; ends are
    /// emitted from `tick` once the grace window has elapsed.
    mutating func apply(_ event: GatewayPresenceUpdateEvent, now: Date) -> [GameSessionEvent] {
        var events: [GameSessionEvent] = []
        let playing = event.playingActivities
        let playingNames = Set(playing.map { Self.normalize($0.name) })

        for activity in playing {
            let name = Self.normalize(activity.name)
            let key = Key(userID: event.userID, gameName: name)

            if var existing = live[key] {
                // Activity is back (or still present) — cancel any pending end.
                existing.pendingEndSince = nil
                live[key] = existing
                continue
            }

            // Trust Discord's own start timestamp when it is sane; a client that
            // reconnects mid-game reports the original start, which keeps the
            // duration honest.
            let startedAt: Date
            if let reported = activity.startedAt, reported <= now {
                startedAt = reported
            } else {
                startedAt = now
            }

            let session = GameSession(
                userID: event.userID,
                guildID: event.guildID,
                gameName: activity.name,
                startedAt: startedAt,
                endedAt: nil
            )
            live[key] = LiveSession(session: session, pendingEndSince: nil)
            events.append(.started(session))
        }

        // Any live session for this user whose game is no longer reported starts
        // its grace countdown.
        for (key, value) in live where key.userID == event.userID {
            guard !playingNames.contains(key.gameName) else { continue }
            guard value.pendingEndSince == nil else { continue }
            var updated = value
            updated.pendingEndSince = now
            live[key] = updated
        }

        return events
    }

    /// Closes out sessions whose grace window has expired. Call periodically.
    mutating func tick(now: Date) -> [GameSessionEvent] {
        var events: [GameSessionEvent] = []
        for (key, value) in live {
            guard let pendingSince = value.pendingEndSince else { continue }
            guard now.timeIntervalSince(pendingSince) >= configuration.absenceGrace else { continue }

            live.removeValue(forKey: key)

            var finished = value.session
            // The session ended when the activity vanished, not when the grace
            // window expired, so the grace period never inflates the duration.
            finished.endedAt = pendingSince
            guard finished.duration >= configuration.minimumSessionDuration else { continue }
            events.append(.ended(finished))
        }
        return events
    }

    /// Drops all state, e.g. on gateway resume where presence is replayed.
    mutating func reset() {
        live.removeAll()
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
