import Charts
import SwiftUI

struct AnalyticsView: View {
    @EnvironmentObject var app: AppModel

    @State private var dailyActivity: [(date: Date, count: Int)] = []
    @State private var hourlyActivity: [(hour: Int, count: Int)] = []
    @State private var topUsers: [(username: String, seconds: Int)] = []
    @State private var mostActiveDay: String = "—"
    @State private var totalSecondsThisWeek: Int = 0
    @State private var sessionCountThisWeek: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewSectionHeader(title: "Analytics", symbol: "chart.line.uptrend.xyaxis")

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    overviewCards
                    dailyChart
                    HStack(alignment: .top, spacing: 14) {
                        hourlyChart
                        topUsersChart
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await loadData() }
        .refreshable { await loadData() }
    }

    // MARK: - Overview Cards

    private var overviewCards: some View {
        analyticsCard(title: "This Week", symbol: "calendar.badge.clock") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                metricTile(
                    title: "Voice Sessions",
                    value: "\(sessionCountThisWeek)",
                    symbol: "waveform"
                )
                metricTile(
                    title: "Total Voice Time",
                    value: formattedDuration(totalSecondsThisWeek),
                    symbol: "clock"
                )
                metricTile(
                    title: "Most Active Day",
                    value: mostActiveDay,
                    symbol: "sun.max"
                )
                metricTile(
                    title: "Top User",
                    value: topUsers.first?.username ?? "—",
                    symbol: "person.fill"
                )
            }
        }
    }

    // MARK: - Daily Activity Chart

    private var dailyChart: some View {
        analyticsCard(title: "Voice Activity — Last 7 Days", symbol: "chart.bar.fill") {
            if dailyActivity.allSatisfy({ $0.count == 0 }) {
                emptyState("No voice sessions recorded yet")
            } else {
                Chart(dailyActivity, id: \.date) { item in
                    BarMark(
                        x: .value("Day", item.date, unit: .day),
                        y: .value("Sessions", item.count)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 160)
            }
        }
    }

    // MARK: - Hourly Activity Chart

    private var hourlyChart: some View {
        analyticsCard(title: "Activity by Hour", symbol: "clock.badge.checkmark") {
            if hourlyActivity.allSatisfy({ $0.count == 0 }) {
                emptyState("No data")
            } else {
                Chart(hourlyActivity, id: \.hour) { item in
                    BarMark(
                        x: .value("Hour", item.hour),
                        y: .value("Sessions", item.count)
                    )
                    .foregroundStyle(Color.purple.gradient)
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let hour = value.as(Int.self) {
                                Text(hourLabel(hour))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 130)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Top Users Chart

    private var topUsersChart: some View {
        analyticsCard(title: "Top Voice Users", symbol: "person.3.fill") {
            if topUsers.isEmpty {
                emptyState("No data")
            } else {
                Chart(topUsers, id: \.username) { item in
                    BarMark(
                        x: .value("Time", item.seconds),
                        y: .value("User", item.username)
                    )
                    .foregroundStyle(Color.teal.gradient)
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let secs = value.as(Int.self) {
                                Text(formattedDuration(secs))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 130)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func analyticsCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            content()
        }
        .padding(12)
        .commandCatalogSurface(cornerRadius: 14)
    }

    private func metricTile(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case let h where h < 12: return "\(h)a"
        default: return "\(hour - 12)p"
        }
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    private func loadData() async {
        async let daily = app.voiceSessionStore.getVoiceActivityLast7Days()
        async let hourly = app.voiceSessionStore.getVoiceActivityByHour()
        async let users = app.voiceSessionStore.getTopVoiceUsers(limit: 5)
        async let activeDay = app.voiceSessionStore.getMostActiveDay()
        async let totalTime = app.voiceSessionStore.getTotalVoiceTimeThisWeek()
        async let sessionCount = app.voiceSessionStore.getSessionCountThisWeek()

        dailyActivity = await daily
        hourlyActivity = await hourly
        topUsers = await users
        mostActiveDay = await activeDay ?? "—"
        totalSecondsThisWeek = Int(await totalTime)
        sessionCountThisWeek = await sessionCount
    }
}
