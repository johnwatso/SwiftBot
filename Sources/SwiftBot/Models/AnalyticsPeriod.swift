import Foundation

/// The time window Analytics reports on. Week and month chart one bar per
/// day; year charts one per month.
enum AnalyticsPeriod: String, CaseIterable, Codable, Sendable {
    case week = "7d"
    case month = "30d"
    case year = "365d"

    init(query: String?) {
        self = AnalyticsPeriod(rawValue: query ?? "") ?? .week
    }

    var dayCount: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .year: return 365
        }
    }

    var label: String {
        switch self {
        case .week: return "last 7 days"
        case .month: return "last 30 days"
        case .year: return "last 12 months"
        }
    }

    /// Chart buckets, oldest first. The last one always contains `now`.
    func buckets(now: Date = Date(), calendar: Calendar = .current) -> [AnalyticsBucket] {
        switch self {
        case .week, .month:
            let today = calendar.startOfDay(for: now)
            return (0..<dayCount).reversed().compactMap { daysAgo in
                guard let start = calendar.date(byAdding: .day, value: -daysAgo, to: today),
                      let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
                let format: Date.FormatStyle = self == .week
                    ? .dateTime.weekday(.abbreviated)
                    : .dateTime.day().month(.abbreviated)
                return AnalyticsBucket(start: start, end: end, label: start.formatted(format))
            }
        case .year:
            let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            return (0..<12).reversed().compactMap { monthsAgo in
                guard let start = calendar.date(byAdding: .month, value: -monthsAgo, to: thisMonth),
                      let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
                return AnalyticsBucket(start: start, end: end, label: start.formatted(.dateTime.month(.abbreviated)))
            }
        }
    }

    /// The whole window: from the first bucket's start to `now`.
    func window(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let start = buckets(now: now, calendar: calendar).first?.start ?? now
        return DateInterval(start: start, end: max(start, now))
    }

    /// The window of the same length just before this one, for trends.
    func previousWindow(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let current = window(now: now, calendar: calendar)
        return DateInterval(start: current.start.addingTimeInterval(-current.duration), end: current.start)
    }
}

struct AnalyticsBucket: Sendable, Hashable {
    let start: Date
    let end: Date
    let label: String

    func contains(_ date: Date) -> Bool { date >= start && date < end }
}
