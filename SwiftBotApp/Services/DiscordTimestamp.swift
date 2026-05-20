import Foundation

// MARK: - Parser

struct DiscordTimestampParser {
    struct ParseResult {
        let date: Date
        let summary: String
    }

    enum ParseError: Error, CustomStringConvertible {
        case empty
        case noTimeFound
        case invalidDate

        var description: String {
            switch self {
            case .empty: return "Type when you want — e.g. `6pm`, `6pm friday`, `6:15 friday the 13th`."
            case .noTimeFound: return "Couldn't find a time. Try `6pm`, `6:15pm`, or `18:30`."
            case .invalidDate: return "Couldn't build a valid date from that input."
            }
        }
    }

    static func parse(
        _ input: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> Result<ParseResult, ParseError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return .failure(.empty) }

        var cal = calendar
        cal.timeZone = timeZone

        if let rel = parseRelative(trimmed, from: now, calendar: cal) {
            return .success(ParseResult(date: rel.date, summary: rel.summary))
        }

        guard let time = extractTime(from: trimmed) else {
            return .failure(.noTimeFound)
        }

        let today = cal.startOfDay(for: now)
        var anchorDate = today
        var weekdayMatched: Int?

        let weekday = extractWeekday(from: trimmed)
        let monthDay = extractMonthDay(from: trimmed)
        let ordinalDay = extractOrdinalDay(from: trimmed)
        let year = extractYear(from: trimmed)
        let isTomorrow = trimmed.range(of: #"\btomorrow\b"#, options: .regularExpression) != nil

        if let monthDay {
            var dc = cal.dateComponents([.year], from: now)
            dc.year = year ?? dc.year
            dc.month = monthDay.month
            dc.day = monthDay.day
            if let d = cal.date(from: dc) {
                anchorDate = d
                if year == nil && d < today {
                    dc.year = (dc.year ?? 0) + 1
                    if let d2 = cal.date(from: dc) { anchorDate = d2 }
                }
            }
        } else if let weekday, let ordinalDay {
            var candidate = today
            for _ in 0..<(366 * 8) {
                let comps = cal.dateComponents([.weekday, .day], from: candidate)
                if comps.weekday == weekday && comps.day == ordinalDay {
                    anchorDate = candidate
                    break
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: candidate) else { break }
                candidate = next
            }
        } else if let weekday {
            let nowWeekday = cal.component(.weekday, from: today)
            let delta = (weekday - nowWeekday + 7) % 7
            if let d = cal.date(byAdding: .day, value: delta, to: today) {
                anchorDate = d
            }
            weekdayMatched = weekday
        } else if let ordinalDay {
            var dc = cal.dateComponents([.year, .month, .day], from: now)
            dc.day = ordinalDay
            if let d = cal.date(from: dc) {
                anchorDate = d
                if d < today, let d2 = cal.date(byAdding: .month, value: 1, to: d) {
                    anchorDate = d2
                }
            }
        } else if isTomorrow {
            if let d = cal.date(byAdding: .day, value: 1, to: today) {
                anchorDate = d
            }
        }

        var finalComps = cal.dateComponents([.year, .month, .day], from: anchorDate)
        finalComps.hour = time.hour
        finalComps.minute = time.minute
        finalComps.second = 0
        guard var resultDate = cal.date(from: finalComps) else {
            return .failure(.invalidDate)
        }

        if let weekdayMatched, resultDate <= now {
            let weekdayToday = cal.component(.weekday, from: today)
            if weekdayMatched == weekdayToday, let bumped = cal.date(byAdding: .day, value: 7, to: resultDate) {
                resultDate = bumped
            }
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = cal.timeZone
        return .success(ParseResult(date: resultDate, summary: formatter.string(from: resultDate)))
    }

    // MARK: Time

    private static func extractTime(from s: String) -> (hour: Int, minute: Int)? {
        let patterns: [(String, Bool, Bool)] = [
            (#"(\d{1,2}):(\d{2})\s*(am|pm)"#, true, true),
            (#"(\d{1,2})\s*(am|pm)"#, false, true),
            (#"(\d{1,2}):(\d{2})"#, true, false)
        ]
        for (pattern, hasMinutes, hasAmPm) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            guard let match = regex.firstMatch(in: s, range: range) else { continue }
            guard let hour = group(match, 1, in: s).flatMap(Int.init) else { continue }
            let minute: Int
            if hasMinutes {
                guard let minStr = group(match, 2, in: s), let m = Int(minStr), m < 60 else { continue }
                minute = m
            } else {
                minute = 0
            }
            if hasAmPm {
                let ampmIdx = hasMinutes ? 3 : 2
                guard let ap = group(match, ampmIdx, in: s) else { continue }
                return (normalizedHour(hour, ampm: ap), minute)
            } else {
                guard hour <= 23 else { continue }
                return (hour, minute)
            }
        }
        return nil
    }

    private static func normalizedHour(_ hour: Int, ampm: String) -> Int {
        if ampm == "pm" { return hour == 12 ? 12 : hour + 12 }
        return hour == 12 ? 0 : hour
    }

    // MARK: Weekday

    private static let weekdayMap: [String: Int] = [
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tues": 3, "tue": 3,
        "wednesday": 4, "wed": 4,
        "thursday": 5, "thurs": 5, "thur": 5, "thu": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7
    ]

    private static func extractWeekday(from s: String) -> Int? {
        let keys = weekdayMap.keys.sorted { $0.count > $1.count }
        for key in keys {
            if s.range(of: "\\b\(key)\\b", options: .regularExpression) != nil {
                return weekdayMap[key]
            }
        }
        return nil
    }

    // MARK: Month

    private static let monthMap: [String: Int] = [
        "january": 1, "jan": 1,
        "february": 2, "feb": 2,
        "march": 3, "mar": 3,
        "april": 4, "apr": 4,
        "may": 5,
        "june": 6, "jun": 6,
        "july": 7, "jul": 7,
        "august": 8, "aug": 8,
        "september": 9, "sept": 9, "sep": 9,
        "october": 10, "oct": 10,
        "november": 11, "nov": 11,
        "december": 12, "dec": 12
    ]

    private static func extractMonthDay(from s: String) -> (month: Int, day: Int)? {
        let keys = monthMap.keys.sorted { $0.count > $1.count }
        for key in keys {
            let forward = "\\b\(key)\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b"
            if let regex = try? NSRegularExpression(pattern: forward),
               let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)),
               let dayStr = group(match, 1, in: s), let day = Int(dayStr), (1...31).contains(day) {
                return (monthMap[key]!, day)
            }
            let backward = "\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+\(key)\\b"
            if let regex = try? NSRegularExpression(pattern: backward),
               let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)),
               let dayStr = group(match, 1, in: s), let day = Int(dayStr), (1...31).contains(day) {
                return (monthMap[key]!, day)
            }
        }
        return nil
    }

    // MARK: Ordinal day-of-month ("the 13th")

    private static func extractOrdinalDay(from s: String) -> Int? {
        let pattern = #"\bthe\s+(\d{1,2})(?:st|nd|rd|th)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = regex.firstMatch(in: s, range: range),
              let dayStr = group(match, 1, in: s),
              let day = Int(dayStr), (1...31).contains(day) else { return nil }
        return day
    }

    private static func extractYear(from s: String) -> Int? {
        let pattern = #"\b(20\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = regex.firstMatch(in: s, range: range),
              let yearStr = group(match, 1, in: s) else { return nil }
        return Int(yearStr)
    }

    // MARK: Relative ("in 2 hours")

    private static func parseRelative(_ s: String, from now: Date, calendar: Calendar) -> (date: Date, summary: String)? {
        let pattern = #"\bin\s+(\d+)\s+(minutes?|mins?|hours?|hrs?|days?|weeks?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = regex.firstMatch(in: s, range: range),
              let numStr = group(match, 1, in: s), let count = Int(numStr),
              let unit = group(match, 2, in: s) else { return nil }
        let component: Calendar.Component
        switch unit {
        case "minute", "minutes", "min", "mins": component = .minute
        case "hour", "hours", "hr", "hrs": component = .hour
        case "day", "days": component = .day
        case "week", "weeks": component = .weekOfYear
        default: return nil
        }
        guard let date = calendar.date(byAdding: component, value: count, to: now) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = calendar.timeZone
        return (date, formatter.string(from: date))
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in s: String) -> String? {
        guard index < match.numberOfRanges,
              let r = Range(match.range(at: index), in: s) else { return nil }
        return String(s[r])
    }
}

// MARK: - Formatter

enum DiscordTimestampStyle: String, CaseIterable {
    case shortTime = "t"
    case longTime = "T"
    case shortDate = "d"
    case longDate = "D"
    case shortDateTime = "f"
    case longDateTime = "F"
    case relative = "R"

    var label: String {
        switch self {
        case .shortTime: return "Short Time"
        case .longTime: return "Long Time"
        case .shortDate: return "Short Date"
        case .longDate: return "Long Date"
        case .shortDateTime: return "Short Date/Time"
        case .longDateTime: return "Long Date/Time"
        case .relative: return "Relative"
        }
    }
}

enum DiscordTimestampFormatter {
    static func code(for date: Date, style: DiscordTimestampStyle = .longDateTime) -> String {
        "<t:\(Int(date.timeIntervalSince1970)):\(style.rawValue)>"
    }

    static func allFormats(for date: Date) -> [(style: DiscordTimestampStyle, code: String)] {
        DiscordTimestampStyle.allCases.map { ($0, code(for: date, style: $0)) }
    }
}
