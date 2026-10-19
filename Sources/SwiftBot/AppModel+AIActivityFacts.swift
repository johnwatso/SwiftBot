import Foundation

/// Turns a question like "what time does sam usually jump on?" into a short
/// block of facts from SwiftBot's own records, so Apple Intelligence can
/// answer from data instead of guessing. Pure, so it can be tested without a
/// running bot.
enum AIActivityFacts {
    /// The result of looking up an activity question before it reaches the
    /// language model. A deterministic reply means SwiftBot has no verified
    /// basis for an AI-written answer.
    struct Lookup: Sendable {
        var context = ""
        var deterministicReply: String?
        /// The verified facts shown to an admin in the WebUI test chat.
        var debugSummary: String?
    }

    struct Member: Sendable {
        let id: String
        let name: String
        let username: String?
    }

    /// What SwiftBot knows about one member over the window.
    struct MemberRecord: Sendable {
        let member: Member
        var sessions: [VoiceSession] = []
        var messages: Int?
        var playingNow: [String] = []
        var gameHistory: [RewindGameSummary] = []
    }

    static let windowDays = 30

    /// Words that make a question about someone's activity rather than about
    /// something else that happens to share their name.
    private static let activityWords: Set<String> = [
        "usually", "normally", "typically", "often", "always", "when", "time", "times", "online", "on",
        "jump", "jumps", "hop", "hops", "join", "joins", "voice", "vc", "call", "play", "plays", "playing",
        "seen", "last", "active", "around", "hours", "much", "messages", "chat", "chats", "talk", "busy",
        "busiest", "night", "morning", "evening", "weekend", "weekends", "days", "day", "late", "early"
    ]
    private static let selfWords: Set<String> = ["i", "me", "my", "i'm", "im", "myself"]
    private static let serverWords: Set<String> = ["busiest", "busy", "everyone", "people", "server", "most"]

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'_.")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'.")) }
            .filter { !$0.isEmpty }
    }

    static func isActivityQuestion(_ text: String) -> Bool {
        words(in: text).contains { activityWords.contains($0) }
    }

    static func asksAboutSelf(_ text: String) -> Bool {
        words(in: text).contains { selfWords.contains($0) }
    }

    static func asksAboutServer(_ text: String) -> Bool {
        words(in: text).contains { serverWords.contains($0) }
    }

    static func asksAboutGames(_ text: String) -> Bool {
        let questionWords = Set(words(in: text))
        return !questionWords.isDisjoint(with: ["game", "games", "gaming", "played", "play", "plays", "playing"])
    }

    /// Questions that need a history-based pattern, rather than an answer
    /// about somebody's current state or a total amount of activity.
    static func asksForUsualPattern(_ text: String) -> Bool {
        let questionWords = Set(words(in: text))
        return !questionWords.isDisjoint(with: ["usually", "normally", "typically", "often", "when", "time", "times"])
    }

    /// Avoid treating an ordinary conversational question such as "what time
    /// is it?" as a failed member lookup. These are the stronger signals that
    /// somebody expects SwiftBot to identify a Discord member.
    static func needsMemberResolution(_ text: String) -> Bool {
        let questionWords = Set(words(in: text))
        return !questionWords.isDisjoint(with: [
            "usually", "normally", "typically", "often", "voice", "vc", "play", "plays", "playing", "played", "online", "active"
        ])
    }

    static func usableSessions(_ sessions: [VoiceSession], now: Date) -> [VoiceSession] {
        sessions.filter { ($0.leftAt ?? now).timeIntervalSince($0.joinedAt) >= 120 || $0.leftAt == nil }
    }

    static func memberLabel(_ member: Member) -> String {
        member.username.map { "\(member.name) (@\($0))" } ?? member.name
    }

    /// Members named in the question: <@id> mentions first, then display
    /// names, usernames and first names as whole words. At most `limit`.
    static func mentionedMembers(in text: String, members: [Member], botUserID: String?, limit: Int = 3) -> [Member] {
        var found: [Member] = []
        func add(_ member: Member) {
            guard member.id != botUserID, !found.contains(where: { $0.id == member.id }) else { return }
            found.append(member)
        }
        let byID = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let regex = try? NSRegularExpression(pattern: "<@!?(\\d+)>") {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let idRange = Range(match.range(at: 1), in: text), let member = byID[String(text[idRange])] {
                    add(member)
                }
            }
        }

        let tokens = words(in: text.replacingOccurrences(of: "<@!?\\d+>", with: " ", options: .regularExpression))
        let tokenSet = Set(tokens)
        let joined = " " + tokens.joined(separator: " ") + " "
        // A first name only counts when one member has it.
        var firstNames: [String: [Member]] = [:]
        for member in members {
            if let first = words(in: member.name).first, first.count >= 3 { firstNames[first, default: []].append(member) }
        }
        for member in members {
            let full = words(in: member.name).joined(separator: " ")
            let username = member.username.map { words(in: $0).joined(separator: " ") } ?? ""
            if (full.count >= 3 && joined.contains(" \(full) ")) || (username.count >= 3 && joined.contains(" \(username) ")) {
                add(member)
            }
        }
        for (first, owners) in firstNames where owners.count == 1 && tokenSet.contains(first) {
            add(owners[0])
        }
        return Array(found.prefix(limit))
    }

    /// The time most of these sessions start around, rounded to 15 minutes,
    /// and the share of sessions that start within 90 minutes of it.
    static func usualStart(of starts: [Date], timeZone: TimeZone) -> (minutes: Int, share: Double)? {
        guard starts.count >= 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let minutes = starts.map { date -> Int in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        // Best 3-hour window, wrapping past midnight.
        var bestStart = 0
        var bestCount = -1
        for hour in 0..<24 {
            let lower = hour * 60
            let count = minutes.filter { (($0 - lower + 1_440) % 1_440) < 180 }.count
            if count > bestCount { bestCount = count; bestStart = lower }
        }
        let inWindow = minutes.compactMap { value -> Int? in
            let offset = (value - bestStart + 1_440) % 1_440
            return offset < 180 ? offset : nil
        }
        let mean = Double(inWindow.reduce(0, +)) / Double(max(1, inWindow.count))
        let rounded = Int((mean / 15).rounded()) * 15
        return ((bestStart + rounded) % 1_440, Double(bestCount) / Double(minutes.count))
    }

    /// Weekdays holding a clear share of sessions ("Fri and Sat"), or nil
    /// when activity is spread through the week.
    static func usualDays(of starts: [Date], timeZone: TimeZone) -> [Int]? {
        guard starts.count >= 4 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var counts: [Int: Int] = [:]
        for date in starts { counts[calendar.component(.weekday, from: date), default: 0] += 1 }
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(2)
        let share = Double(top.reduce(0) { $0 + $1.value }) / Double(starts.count)
        guard share >= 0.45 else { return nil }
        return top.map(\.key).sorted()
    }

    static func describe(_ record: MemberRecord, now: Date, timeZone: TimeZone, isAsker: Bool) -> String {
        let label = memberLabel(record.member)
        let who = isAsker ? "\(label), the person asking" : label
        var parts: [String] = []
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US")
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "h:mm a"
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US")
        dayFormatter.timeZone = timeZone
        dayFormatter.dateFormat = "EEE d MMM 'at' h:mm a"

        let sessions = usableSessions(record.sessions, now: now)
        if sessions.isEmpty {
            parts.append("no voice activity in the last \(windowDays) days")
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let days = Set(sessions.map { calendar.startOfDay(for: $0.joinedAt) }).count
            let seconds = sessions.reduce(0) { $0 + max(0, Int(($1.leftAt ?? now).timeIntervalSince($1.joinedAt))) }
            parts.append("in voice on \(days) of the last \(windowDays) days, \(sessions.count) sessions, \(hours(seconds)) total")
            let starts = sessions.map(\.joinedAt)
            if let usual = usualStart(of: starts, timeZone: timeZone) {
                let date = calendar.date(bySettingHour: usual.minutes / 60, minute: usual.minutes % 60, second: 0, of: now) ?? now
                let strength = usual.share >= 0.6 ? "usually" : "most often"
                parts.append("\(strength) joins around \(timeFormatter.string(from: date)) (\(Int((usual.share * 100).rounded()))% of sessions start within 90 minutes of that)")
            } else {
                parts.append("too few sessions to say when they usually join")
            }
            if let days = usualDays(of: starts, timeZone: timeZone) {
                let names = days.map { dayFormatter.shortWeekdaySymbols[$0 - 1] }
                parts.append("busiest on \(names.joined(separator: " and "))")
            }
            if let live = sessions.last(where: { $0.leftAt == nil }) {
                parts.append("in voice right now in \(live.channelName.isEmpty ? "a voice channel" : live.channelName) since \(timeFormatter.string(from: live.joinedAt))")
            } else if let last = sessions.compactMap(\.leftAt).max() {
                parts.append("last left voice \(dayFormatter.string(from: last))")
            }
            var channels: [String: Int] = [:]
            for session in sessions where !session.channelName.isEmpty {
                channels[session.channelName, default: 0] += max(0, Int((session.leftAt ?? now).timeIntervalSince(session.joinedAt)))
            }
            if let favourite = channels.max(by: { $0.value < $1.value })?.key { parts.append("favourite voice channel \(favourite)") }
        }
        if let messages = record.messages { parts.append("\(messages) messages sent in the last \(windowDays) days") }
        if !record.playingNow.isEmpty { parts.append("playing \(record.playingNow.joined(separator: ", ")) right now") }
        if let favourite = record.gameHistory.first {
            parts.append(
                "most-played recorded game in this server while in voice over the last \(windowDays) days is \(favourite.game), " +
                "\(hours(Int(favourite.seconds))) across \(favourite.sessions) \(favourite.sessions == 1 ? "session" : "sessions")"
            )
        }
        return "- \(who): " + parts.joined(separator: "; ") + "."
    }

    /// Server-wide: the hour and weekday most voice sessions start.
    static func describeServer(_ sessions: [VoiceSession], timeZone: TimeZone) -> String? {
        let starts = sessions.map(\.joinedAt)
        guard let usual = usualStart(of: starts, timeZone: timeZone) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(bySettingHour: usual.minutes / 60, minute: usual.minutes % 60, second: 0, of: Date()) ?? Date()
        var line = "- The server: \(sessions.count) voice sessions in the last \(windowDays) days; most start around \(formatter.string(from: date))"
        if let days = usualDays(of: starts, timeZone: timeZone) {
            line += ", busiest on \(days.map { formatter.shortWeekdaySymbols[$0 - 1] }.joined(separator: " and "))"
        }
        return line + "."
    }

    static func block(lines: [String], timeZone: TimeZone) -> String {
        guard !lines.isEmpty else { return "" }
        let zone = timeZone.localizedName(for: .generic, locale: Locale(identifier: "en_US")) ?? timeZone.identifier
        return """
        Server activity from SwiftBot's records (last \(windowDays) days, times in \(zone)). \
        Use only these facts to answer questions about when people are on, play or chat. \
        Some game facts are explicitly limited to time in voice; never generalise them beyond that scope. \
        Round times naturally ("around 8 PM"). If something isn't listed, say you don't know.
        \(lines.joined(separator: "\n"))
        """
    }

    private static func hours(_ seconds: Int) -> String {
        let hours = Double(seconds) / 3_600
        if hours < 1 { return "\(max(1, seconds / 60)) min" }
        return hours < 10 ? String(format: "%.1f h", hours) : "\(Int(hours.rounded())) h"
    }
}

extension AppModel {
    /// Locates facts before an AI reply. A member question with no match or too
    /// little data returns a direct, explicit response instead of inviting the
    /// model to guess. `guildID` nil (a DM or the Settings "Try it" box) looks
    /// across every connected server.
    func aiActivityLookup(question: String, askerID: String?, guildID: String?) async -> AIActivityFacts.Lookup {
        guard settings.aiActivityAnswersEnabled, AIActivityFacts.isActivityQuestion(question) else {
            return .init()
        }
        let members = discordMemberOptions.map { AIActivityFacts.Member(id: $0.id, name: $0.displayName, username: $0.username) }
        var targets = AIActivityFacts.mentionedMembers(in: question, members: members, botUserID: botUserId)
        if let askerID, AIActivityFacts.asksAboutSelf(question), !targets.contains(where: { $0.id == askerID }) {
            if let me = members.first(where: { $0.id == askerID }) {
                targets.insert(me, at: 0)
            } else {
                targets.insert(AIActivityFacts.Member(id: askerID, name: await displayNameForUserID(askerID), username: nil), at: 0)
            }
        }

        let zoneID = askerID.flatMap { settings.userTimezones[$0] }
        let timeZone = zoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        let now = Date()
        let since = now.addingTimeInterval(-Double(AIActivityFacts.windowDays) * 86_400)
        let guildIDs = guildID.map { [$0] } ?? Array(connectedServers.keys)

        var lines: [String] = []
        var directReply: String?
        for member in targets {
            var record = AIActivityFacts.MemberRecord(member: member)
            record.sessions = await voiceSessionStore.sessions(userId: member.id, guildId: guildID, since: since)
            if settings.rewind.isEnabled {
                var total = 0
                for id in guildIDs {
                    total += await rewindStore.userRangeSummary(guildID: id, userID: member.id, start: since, end: now, excludingUsers: []).messages
                }
                record.messages = total
            }
            var playingNow = gameSessionTracker.activeGames(for: member.id)
            if settings.rewind.isEnabled, let guildID {
                playingNow += await rewindActivityStore.activePlayingGames(userID: member.id, guildID: guildID)
            }
            record.playingNow = Array(Set(playingNow)).sorted()
            if settings.rewind.isEnabled, AIActivityFacts.asksAboutGames(question) {
                var gameTotals: [String: (sessions: Int, seconds: TimeInterval)] = [:]
                for id in guildIDs {
                    for summary in await rewindActivityStore.gameSummaries(userID: member.id, guildID: id, from: since, to: now) {
                        let current = gameTotals[summary.game] ?? (sessions: 0, seconds: 0)
                        gameTotals[summary.game] = (current.sessions + summary.sessions, current.seconds + summary.seconds)
                    }
                }
                record.gameHistory = gameTotals.map { game, total in
                    RewindGameSummary(game: game, sessions: total.sessions, seconds: total.seconds)
                }.sorted { lhs, rhs in
                    lhs.seconds == rhs.seconds ? lhs.game.localizedCaseInsensitiveCompare(rhs.game) == .orderedAscending : lhs.seconds > rhs.seconds
                }
            }

            let usableSessions = AIActivityFacts.usableSessions(record.sessions, now: now)
            let label = AIActivityFacts.memberLabel(member)
            if AIActivityFacts.asksAboutGames(question) {
                if !settings.rewind.isEnabled {
                    directReply = "I can’t answer game-history questions until Rewind is enabled. It records game presence only while someone is in voice."
                    break
                }
                if record.gameHistory.isEmpty {
                    directReply = "I don’t have recorded in-voice game activity for \(label) in the last \(AIActivityFacts.windowDays) days."
                    break
                }
            } else if AIActivityFacts.asksForUsualPattern(question), usableSessions.count < 3 {
                directReply = usableSessions.isEmpty
                    ? "I don’t have recorded voice activity for \(label) in the last \(AIActivityFacts.windowDays) days."
                    : "I need at least three recorded voice sessions for \(label) before I can say when they usually get on."
                break
            }
            lines.append(AIActivityFacts.describe(record, now: now, timeZone: timeZone, isAsker: member.id == askerID))
        }
        if targets.isEmpty, AIActivityFacts.asksAboutServer(question) {
            let sessions = await voiceSessionStore.sessions(guildId: guildID, since: since)
            let usableSessions = AIActivityFacts.usableSessions(sessions, now: now)
            if usableSessions.count < 3 {
                directReply = usableSessions.isEmpty
                    ? "I don’t have recorded voice activity for this server in the last \(AIActivityFacts.windowDays) days."
                    : "I need at least three recorded voice sessions before I can say when this server is usually busiest."
            } else if let line = AIActivityFacts.describeServer(usableSessions, timeZone: timeZone) {
                lines.append(line)
            }
        }
        if let directReply {
            return .init(deterministicReply: directReply)
        }
        if lines.isEmpty, targets.isEmpty, AIActivityFacts.needsMemberResolution(question) {
            return .init(deterministicReply: "I couldn’t match that member. Please @mention them so I can check SwiftBot’s recorded activity.")
        }
        let context = AIActivityFacts.block(lines: lines, timeZone: timeZone)
        return .init(context: context, debugSummary: lines.isEmpty ? nil : lines.joined(separator: "\n"))
    }
}
