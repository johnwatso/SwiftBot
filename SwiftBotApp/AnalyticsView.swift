import Charts
import SwiftUI

struct AnalyticsView: View {
    @EnvironmentObject var app: AppModel

    @State private var snapshot = AnalyticsSnapshot.empty
    @State private var updatedAt = Date()
    @State private var hoveredUserID: String?

    private var dailyActivity: [AnalyticsDaySample] { snapshot.voice.dailyActivity }
    private var hourlyActivity: [AnalyticsHourSample] { snapshot.voice.hourlyActivity }
    private var topUsers: [AnalyticsTopUser] { snapshot.voice.topUsers }
    private var mostActiveDay: String { snapshot.voice.mostActiveDay }
    private var totalSecondsThisWeek: Int { snapshot.voice.totalSecondsThisWeek }
    private var sessionCountThisWeek: Int { snapshot.voice.sessionCountThisWeek }

    private var averageSessionsPerDay: Double {
        snapshot.voice.averageSessionsPerDay
    }

    private var peakHour: AnalyticsHourSample? {
        snapshot.voice.peakHour
    }

    private var commandsToday: Int {
        snapshot.system.commandsToday
    }

    private var failedCommandsToday: Int {
        snapshot.system.failedCommandsToday
    }

    private var successRate: Double {
        snapshot.system.commandSuccessRate
    }

    private var activeWorkflowCount: Int {
        snapshot.system.activeWorkflowCount
    }

    private var eventQueueLoad: Double {
        snapshot.health.eventQueueLoad
    }

    private var rollingEventCount: Int { snapshot.system.rollingEventCount }
    private var eventFeed: [AnalyticsFeedEntry] { snapshot.feed }

    private var dailyChartDomain: ClosedRange<Date> {
        guard let first = dailyActivity.first?.date, let last = dailyActivity.last?.date else {
            let now = Date()
            return now...now
        }
        let calendar = Calendar.current
        let lower = calendar.date(byAdding: .hour, value: -10, to: first) ?? first
        let upper = calendar.date(byAdding: .hour, value: 10, to: last) ?? last
        return lower...upper
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    heroSummary

                    activityOverview

                    HStack(alignment: .top, spacing: 12) {
                        systemActivity
                            .frame(maxWidth: .infinity)
                        botHealth
                            .frame(maxWidth: .infinity)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        insightsSection
                            .frame(maxWidth: .infinity)
                        topUsersSection
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await loadData()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await loadData()
            }
        }
        .refreshable { await loadData() }
        .animation(.smooth(duration: 0.30), value: sessionCountThisWeek)
        .animation(.smooth(duration: 0.30), value: app.gatewayEventCount)
        .animation(.smooth(duration: 0.35), value: app.activeVoice.count)
    }

    private var header: some View {
        HStack(alignment: .center) {
            ViewSectionHeader(title: "Analytics", symbol: "chart.line.uptrend.xyaxis")
            Spacer()
            liveBadge
        }
    }

    private var liveBadge: some View {
        TimelineView(.animation) { timeline in
            let pulse = app.status == .running ? (sin(timeline.date.timeIntervalSince1970 * 3.4) + 1) / 2 : 0
            HStack(spacing: 8) {
                Circle()
                    .fill(app.status == .running ? .green : .secondary)
                    .frame(width: 8, height: 8)
                    .overlay {
                        Circle()
                            .stroke(app.status == .running ? Color.green.opacity(0.35) : .clear, lineWidth: 5)
                            .scaleEffect(1 + pulse * 0.5)
                            .opacity(0.25 + pulse * 0.45)
                    }
                Text(app.status == .running ? "Live" : app.status.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                Text("Updated \(relativeUpdateText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
    }

    private var heroSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Operational Pulse")
                        .font(.title3.weight(.semibold))
                    Text(heroSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let uptime = app.uptime {
                    Label(uptime.text, systemImage: "timer")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                metricCard(
                    title: "Voice Sessions",
                    value: "\(sessionCountThisWeek)",
                    detail: "\(app.activeVoice.count) currently active",
                    symbol: "waveform",
                    tint: .cyan,
                    prominence: .primary
                )
                metricCard(
                    title: "Total Voice Time",
                    value: formattedDuration(totalSecondsThisWeek),
                    detail: "Average session \(formattedDuration(averageSessionSeconds))",
                    symbol: "clock",
                    tint: .blue,
                    prominence: .primary
                )
                metricCard(
                    title: "Most Active Day",
                    value: mostActiveDay,
                    detail: peakDayDetail,
                    symbol: "calendar.day.timeline.leading",
                    tint: .indigo,
                    prominence: .secondary
                )
                metricCard(
                    title: "Top User",
                    value: topUsers.first?.username ?? "-",
                    detail: topUsers.first.map { "\($0.activityShare)% of tracked voice time" } ?? "No completed sessions yet",
                    symbol: "person.fill",
                    tint: .teal,
                    prominence: .secondary
                )
            }
        }
        .padding(11)
        .glassCard(cornerRadius: 22, tint: .white.opacity(0.07), stroke: .white.opacity(0.18))
    }

    private var activityOverview: some View {
        analyticsCard(title: "Activity Overview", subtitle: peakHour.map { "Peak activity at \(hourLabel($0.hour))" } ?? "Live operational timeline", symbol: "dot.radiowaves.left.and.right") {
            HStack(alignment: .top, spacing: 14) {
                runtimeActivityChart
                    .frame(minWidth: 420, maxWidth: .infinity)

                runtimeFeedPanel
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
            }
        }
    }

    private var runtimeActivityChart: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Voice Activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Last 7 days")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !dailyActivity.contains(where: { hasValue($0.count) }) {
                emptyState("No voice sessions recorded yet")
            } else {
                Chart {
                    ForEach(dailyActivity) { item in
                        AreaMark(
                            x: .value("Day", item.date, unit: .day),
                            y: .value("Sessions", item.count)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.accentColor.opacity(0.22), .accentColor.opacity(0.025)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Day", item.date, unit: .day),
                            y: .value("Sessions", item.count)
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.accentColor)

                        PointMark(
                            x: .value("Day", item.date, unit: .day),
                            y: .value("Sessions", item.count)
                        )
                        .symbolSize(item.count == snapshot.voice.peakDayCount ? 48 : 20)
                        .foregroundStyle(Color.accentColor.opacity(0.82))
                    }

                    RuleMark(y: .value("Average", averageSessionsPerDay))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary.opacity(0.32))
                }
                .chartPlotStyle { plot in
                    plot
                        .background(.black.opacity(0.035))
                        .padding(.horizontal, 7)
                }
                .chartXScale(domain: dailyChartDomain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.white.opacity(0.035))
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.white.opacity(0.035))
                        AxisValueLabel()
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)
                .frame(height: 154)
            }
        }
    }

    private var runtimeFeedPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Live Operations")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(rollingEventCount) recent")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 0) {
                ForEach(Array(eventFeed.prefix(5).enumerated()), id: \.element.id) { index, entry in
                    timelineRow(entry)
                    if index < min(eventFeed.count, 5) - 1 {
                        Divider()
                            .opacity(0.26)
                            .padding(.leading, 30)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var systemActivity: some View {
        analyticsCard(title: "System Activity", subtitle: "Runtime signals", symbol: "bolt.horizontal.circle") {
            VStack(spacing: 7) {
                compactSignal(
                    title: "Commands Today",
                    value: "\(commandsToday)",
                    detail: "\(app.stats.commandsRun) lifetime",
                    color: .cyan
                )
                compactSignal(
                    title: "Failed Actions",
                    value: "\(failedCommandsToday)",
                    detail: "\(Int(successRate * 100))% command success",
                    color: failedCommandsToday > 0 ? .orange : .green
                )
                compactSignal(
                    title: "Gateway Events",
                    value: "\(app.gatewayEventCount)",
                    detail: "Last: \(app.lastGatewayEventName)",
                    color: .blue
                )
                compactSignal(
                    title: "Active Workflows",
                    value: "\(activeWorkflowCount)",
                    detail: snapshot.system.automationDetail,
                    color: .teal
                )
            }
        }
    }

    private var botHealth: some View {
        analyticsCard(title: "Bot Health", subtitle: snapshot.health.state.title, symbol: "waveform.path.ecg") {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: snapshot.health.state.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(snapshot.health.state.color)
                    Text(snapshot.health.state.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(snapshot.health.state.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                healthRow(
                    title: "Gateway Ping",
                    value: snapshot.health.websocketLatencyMs.map { "\($0) ms" } ?? "-",
                    progress: latencyProgress,
                    color: latencyColor
                )
                healthRow(
                    title: "Event Queue",
                    value: "\(snapshot.health.eventQueueDepth)/20",
                    progress: eventQueueLoad,
                    color: eventQueueLoad > 0.75 ? .orange : .green
                )
                healthRow(
                    title: "Concurrent Tasks",
                    value: "\(concurrentTaskCount)",
                    progress: min(Double(concurrentTaskCount) / 8.0, 1.0),
                    color: .blue
                )
                healthRow(
                    title: "Memory",
                    value: snapshot.health.memoryText,
                    progress: nil,
                    color: .purple
                )
            }
        }
    }

    private var topUsersSection: some View {
        analyticsCard(title: "Top Users", subtitle: "Ranked voice activity", symbol: "person.3.fill") {
            if topUsers.isEmpty {
                emptyState("No completed voice sessions yet")
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(topUsers.prefix(5).enumerated()), id: \.element.id) { index, user in
                        rankedUserRow(rank: index + 1, user: user)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var insightsSection: some View {
        analyticsCard(title: "Insights", subtitle: "Generated from live app state", symbol: "sparkles") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)], spacing: 8) {
                ForEach(insights) { insight in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: insight.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(insight.color)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(insight.title)
                                .font(.caption.weight(.semibold))
                            Text(insight.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(9)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(insight.color.opacity(0.18), lineWidth: 1)
                    )
                }
            }
        }
    }

    private func timelineRow(_ entry: AnalyticsFeedEntry) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: entry.category.symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(entry.category.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(entry.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.timestamp, style: .relative)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private func analyticsCard<Content: View>(
        title: String,
        subtitle: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(10)
        .glassCard(cornerRadius: 18, tint: .white.opacity(0.06), stroke: .white.opacity(0.14))
    }

    private func metricCard(
        title: String,
        value: String,
        detail: String,
        symbol: String,
        tint: Color,
        prominence: MetricProminence
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: symbol)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Spacer()
                if prominence == .primary {
                    activityPulse(color: tint)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(prominence == .primary ? .title2.weight(.semibold) : .headline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
        )
    }

    private func compactSignal(title: String, value: String, detail: String, color: Color) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(value)
                .font(.headline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func healthRow(title: String, value: String, progress: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            if let progress {
                ProgressView(value: max(0, min(progress, 1)))
                    .tint(color)
                    .controlSize(.small)
            }
        }
    }

    private func rankedUserRow(rank: Int, user: AnalyticsTopUser) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 9) {
                Text("\(rank)")
                    .font(.caption.weight(rank == 1 ? .bold : .semibold).monospacedDigit())
                    .foregroundStyle(rank == 1 ? Color.accentColor : .secondary)
                    .frame(width: 18)
                ZStack {
                    Circle()
                        .fill(user.isActive ? Color.green.opacity(0.18) : Color.accentColor.opacity(rank == 1 ? 0.18 : 0.12))
                    Text(user.initials)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(user.isActive ? .green : .accentColor)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(user.username)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if user.isActive {
                            activityPulse(color: .green)
                                .frame(width: 10, height: 10)
                        }
                    }
                    Text("\(formattedDuration(user.seconds)) total activity")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(user.activityShare)%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(user.activityShare), total: 100)
                .tint(rank == 1 ? .accentColor : .secondary.opacity(0.45))
                .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            (hoveredUserID == user.id ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial)),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(rank == 1 ? Color.accentColor.opacity(0.18) : .white.opacity(0.06), lineWidth: 1)
        )
        .onHover { isHovering in
            hoveredUserID = isHovering ? user.id : nil
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
    }

    private func activityPulse(color: Color) -> some View {
        TimelineView(.animation) { timeline in
            let pulse = (sin(timeline.date.timeIntervalSince1970 * 2.8) + 1) / 2
            Circle()
                .fill(color.opacity(0.34))
                .frame(width: 7, height: 7)
                .overlay {
                    Circle()
                        .stroke(color.opacity(0.20), lineWidth: 4)
                        .scaleEffect(1 + pulse * 0.45)
                        .opacity(0.25 + pulse * 0.35)
                }
        }
        .frame(width: 18, height: 18)
    }

    private var insights: [AnalyticsInsight] {
        var output: [AnalyticsInsight] = []

        if let peakDay = dailyActivity.max(by: { $0.count < $1.count }), hasValue(peakDay.count), averageSessionsPerDay > 0 {
            let lift = Int(((Double(peakDay.count) / max(averageSessionsPerDay, 1)) - 1) * 100)
            output.append(AnalyticsInsight(
                title: "Weekly concentration",
                body: "\(weekdayName(for: peakDay.date)) ran \(max(lift, 0))% above the 7-day average.",
                symbol: "chart.line.uptrend.xyaxis",
                color: .cyan
            ))
        }

        if let peakHour {
            output.append(AnalyticsInsight(
                title: "Voice peak window",
                body: "Voice sessions are most likely to start around \(hourLabel(peakHour.hour)).",
                symbol: "clock",
                color: .blue
            ))
        }

        if snapshot.health.state == .warning || snapshot.health.state == .degraded || snapshot.health.state == .recovering {
            output.append(AnalyticsInsight(
                title: "Health attention",
                body: snapshot.health.state.detail,
                symbol: snapshot.health.state.symbol,
                color: snapshot.health.state.color
            ))
        } else {
            output.append(AnalyticsInsight(
                title: "Gateway stable",
                body: "No abnormal gateway close is currently recorded.",
                symbol: "checkmark.seal",
                color: .green
            ))
        }

        output.append(AnalyticsInsight(
            title: "Command reliability",
            body: "\(Int(successRate * 100))% success across \(snapshot.system.commandsRunLifetime) tracked command runs.",
            symbol: successRate >= 0.95 ? "checkmark.circle" : "exclamationmark.triangle",
            color: successRate >= 0.95 ? .green : .orange
        ))

        if snapshot.system.patchyCycleRunning || snapshot.system.automationRunsToday > 0 {
            let body = snapshot.system.patchyCycleRunning
                ? "Patchy is actively processing an automation cycle."
                : "Automation completed a cycle today."
            output.append(AnalyticsInsight(
                title: "Automation cadence",
                body: body,
                symbol: "wand.and.stars",
                color: .purple
            ))
        }

        return output
    }

    private var heroSubtitle: String {
        if app.status == .running {
            return "\(app.activeVoice.count) users in voice, \(rollingEventCount) recent events, \(commandsToday) commands today"
        }
        return "Runtime analytics are ready when the bot is online"
    }

    private var averageSessionSeconds: Int {
        guard sessionCountThisWeek > 0 else { return 0 }
        return totalSecondsThisWeek / sessionCountThisWeek
    }

    private var peakDayDetail: String {
        guard let peak = dailyActivity.max(by: { $0.count < $1.count }), hasValue(peak.count) else {
            return "No completed sessions this week"
        }
        return "\(peak.count) sessions on \(weekdayName(for: peak.date))"
    }

    private var concurrentTaskCount: Int {
        var count = app.mediaExportJobs.filter { $0.status == .queued || $0.status == .running }.count
        count += app.patchyIsCycleRunning ? 1 : 0
        count += app.activeBugAutoFixMessageIDs.count
        return count
    }

    private var latencyProgress: Double? {
        guard let latency = snapshot.health.websocketLatencyMs else { return nil }
        return min(Double(latency) / 500.0, 1.0)
    }

    private var latencyColor: Color {
        guard let latency = snapshot.health.websocketLatencyMs else { return .secondary }
        if latency < 150 { return .green }
        if latency < 300 { return .yellow }
        return .orange
    }

    private var relativeUpdateText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(updatedAt)))
        if seconds < 2 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

    private func color(for kind: ActivityEvent.Kind) -> Color {
        switch kind {
        case .voiceJoin: return .green
        case .voiceLeave: return .red
        case .voiceMove: return .blue
        case .command: return .cyan
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func hasValue(_ value: Int) -> Bool {
        value > 0
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case let hourBeforeNoon where hourBeforeNoon < 12: return "\(hourBeforeNoon)a"
        default: return "\(hour - 12)p"
        }
    }

    private func weekdayName(for date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide))
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    private func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    @MainActor
    private func loadData() async {
        async let daily = app.voiceSessionStore.getVoiceActivityLast7Days()
        async let hourly = app.voiceSessionStore.getVoiceActivityByHour()
        async let users = app.voiceSessionStore.getTopVoiceUsers(limit: 5)
        async let totalTime = app.voiceSessionStore.getTotalVoiceTimeThisWeek()
        async let sessionCount = app.voiceSessionStore.getSessionCountThisWeek()

        let loadedDaily = await daily
        let loadedHourly = await hourly
        let loadedUsers = await users
        let loadedTotalSeconds = Int(await totalTime)
        let activeUsernames = Set(app.activeVoice.map(\.username))

        snapshot = AnalyticsAggregator.makeSnapshot(
            dailyActivity: loadedDaily,
            hourlyActivity: loadedHourly,
            topUsers: loadedUsers,
            totalSecondsThisWeek: loadedTotalSeconds,
            sessionCountThisWeek: await sessionCount,
            activeUsernames: activeUsernames,
            app: app,
            memoryBytes: currentResidentMemoryBytes()
        )
        updatedAt = Date()
    }
}

private enum MetricProminence {
    case primary
    case secondary
}

private struct AnalyticsSnapshot: Codable, Equatable {
    let generatedAt: Date
    let voice: AnalyticsVoiceSummary
    let system: AnalyticsSystemMetrics
    let health: AnalyticsHealthMetrics
    let feed: [AnalyticsFeedEntry]

    static let empty = AnalyticsSnapshot(
        generatedAt: Date(),
        voice: .empty,
        system: .empty,
        health: .empty,
        feed: []
    )
}

private struct AnalyticsVoiceSummary: Codable, Equatable {
    let dailyActivity: [AnalyticsDaySample]
    let hourlyActivity: [AnalyticsHourSample]
    let topUsers: [AnalyticsTopUser]
    let mostActiveDay: String
    let totalSecondsThisWeek: Int
    let sessionCountThisWeek: Int

    static let empty = AnalyticsVoiceSummary(
        dailyActivity: [],
        hourlyActivity: [],
        topUsers: [],
        mostActiveDay: "-",
        totalSecondsThisWeek: 0,
        sessionCountThisWeek: 0
    )

    var averageSessionsPerDay: Double {
        guard !dailyActivity.isEmpty else { return 0 }
        return Double(dailyActivity.reduce(0) { $0 + $1.count }) / Double(dailyActivity.count)
    }

    var peakHour: AnalyticsHourSample? {
        hourlyActivity.max { $0.count < $1.count }.flatMap { $0.hasActivity ? $0 : nil }
    }

    var peakDayCount: Int {
        dailyActivity.map(\.count).max() ?? 0
    }
}

private struct AnalyticsSystemMetrics: Codable, Equatable {
    let commandsToday: Int
    let failedCommandsToday: Int
    let commandsRunLifetime: Int
    let commandSuccessRate: Double
    let activeWorkflowCount: Int
    let automationRunsToday: Int
    let failedAutomationCount: Int
    let gatewayEventCount: Int
    let rollingEventCount: Int
    let eventThroughputPerMinute: Double
    let lastGatewayEventName: String
    let patchyCycleRunning: Bool

    static let empty = AnalyticsSystemMetrics(
        commandsToday: 0,
        failedCommandsToday: 0,
        commandsRunLifetime: 0,
        commandSuccessRate: 1,
        activeWorkflowCount: 0,
        automationRunsToday: 0,
        failedAutomationCount: 0,
        gatewayEventCount: 0,
        rollingEventCount: 0,
        eventThroughputPerMinute: 0,
        lastGatewayEventName: "-",
        patchyCycleRunning: false
    )

    var automationDetail: String {
        if patchyCycleRunning {
            return "Patchy running now"
        }
        if failedAutomationCount > 0 {
            return "\(failedAutomationCount) failed automation events"
        }
        return "Rule engine ready"
    }
}

private struct AnalyticsHealthMetrics: Codable, Equatable {
    let websocketLatencyMs: Int?
    let reconnectCount: Int
    let activeTaskCount: Int
    let cpuUsagePercent: Double?
    let memoryBytes: UInt64
    let memoryTrend: Double?
    let eventQueueDepth: Int
    let eventQueueLoad: Double
    let apiResponseTimeMs: Double?
    let state: AnalyticsHealthState

    static let empty = AnalyticsHealthMetrics(
        websocketLatencyMs: nil,
        reconnectCount: 0,
        activeTaskCount: 0,
        cpuUsagePercent: nil,
        memoryBytes: 0,
        memoryTrend: nil,
        eventQueueDepth: 0,
        eventQueueLoad: 0,
        apiResponseTimeMs: nil,
        state: .healthy
    )

    var memoryText: String {
        guard memoryBytes > 0 else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }
}

private enum AnalyticsHealthState: String, Codable, Equatable {
    case healthy
    case warning
    case degraded
    case recovering

    var title: String {
        switch self {
        case .healthy: return "Healthy"
        case .warning: return "Warning"
        case .degraded: return "Degraded"
        case .recovering: return "Recovering"
        }
    }

    var detail: String {
        switch self {
        case .healthy: return "Gateway, queue, and automation signals are nominal"
        case .warning: return "One signal is elevated and worth watching"
        case .degraded: return "Latency, queue, or failures indicate degraded operation"
        case .recovering: return "Gateway is reconnecting or stabilizing after disruption"
        }
    }

    var symbol: String {
        switch self {
        case .healthy: return "checkmark.seal"
        case .warning: return "exclamationmark.triangle"
        case .degraded: return "waveform.path.ecg.rectangle"
        case .recovering: return "arrow.triangle.2.circlepath"
        }
    }

    var color: Color {
        switch self {
        case .healthy: return .green
        case .warning: return .orange
        case .degraded: return .red
        case .recovering: return .yellow
        }
    }
}

private struct AnalyticsFeedEntry: Identifiable, Codable, Equatable {
    let id: String
    let timestamp: Date
    let title: String
    let detail: String
    let category: AnalyticsFeedCategory
}

private enum AnalyticsFeedCategory: String, Codable, Equatable {
    case voice
    case command
    case gateway
    case automation
    case health
    case system

    var symbol: String {
        switch self {
        case .voice: return "waveform"
        case .command: return "terminal"
        case .gateway: return "antenna.radiowaves.left.and.right"
        case .automation: return "wand.and.stars"
        case .health: return "waveform.path.ecg"
        case .system: return "circle.hexagongrid"
        }
    }

    var color: Color {
        switch self {
        case .voice: return .blue
        case .command: return .cyan
        case .gateway: return .green
        case .automation: return .purple
        case .health: return .orange
        case .system: return .secondary
        }
    }
}

private enum AnalyticsAggregator {
    @MainActor
    static func makeSnapshot(
        dailyActivity: [(date: Date, count: Int)],
        hourlyActivity: [(hour: Int, count: Int)],
        topUsers: [(username: String, seconds: Int)],
        totalSecondsThisWeek: Int,
        sessionCountThisWeek: Int,
        activeUsernames: Set<String>,
        app: AppModel,
        memoryBytes: UInt64,
        now: Date = Date()
    ) -> AnalyticsSnapshot {
        let commandSuccessRate: Double = if app.stats.commandsRun > 0 {
            Double(max(0, app.stats.commandsRun - app.stats.errors)) / Double(app.stats.commandsRun)
        } else {
            1
        }

        let automationFailures = app.events.filter {
            ($0.kind == .error || $0.kind == .warning) &&
            $0.message.localizedCaseInsensitiveContains("automation")
        }.count

        let activeTaskCount = app.mediaExportJobs.filter { $0.status == .queued || $0.status == .running }.count
            + (app.patchyIsCycleRunning ? 1 : 0)
            + app.activeBugAutoFixMessageIDs.count
        let rollingEvents = app.events.filter { now.timeIntervalSince($0.timestamp) <= 300 }
        let healthState = healthState(
            status: app.status,
            latencyMs: app.connectionDiagnostics.heartbeatLatencyMs,
            queueLoad: min(Double(app.events.count) / 20.0, 1.0),
            failedCommandsToday: app.commandLog.filter { Calendar.current.isDateInToday($0.time) && !$0.ok }.count,
            automationFailures: automationFailures
        )

        let voice = AnalyticsVoiceSummary(
            dailyActivity: dailyActivity.map { AnalyticsDaySample(date: $0.date, count: $0.count) },
            hourlyActivity: hourlyActivity.map { AnalyticsHourSample(hour: $0.hour, count: $0.count) },
            topUsers: topUsers.map { user in
                AnalyticsTopUser(
                    username: user.username,
                    seconds: user.seconds,
                    totalSeconds: totalSecondsThisWeek,
                    isActive: activeUsernames.contains(user.username)
                )
            },
            mostActiveDay: deterministicMostActiveDay(from: dailyActivity),
            totalSecondsThisWeek: totalSecondsThisWeek,
            sessionCountThisWeek: sessionCountThisWeek
        )

        let system = AnalyticsSystemMetrics(
            commandsToday: app.commandLog.filter { Calendar.current.isDateInToday($0.time) }.count,
            failedCommandsToday: app.commandLog.filter { Calendar.current.isDateInToday($0.time) && !$0.ok }.count,
            commandsRunLifetime: app.stats.commandsRun,
            commandSuccessRate: commandSuccessRate,
            activeWorkflowCount: app.ruleStore.rules.filter(\.isEnabled).count,
            automationRunsToday: app.patchyLastCycleAt.map { Calendar.current.isDateInToday($0) ? 1 : 0 } ?? 0,
            failedAutomationCount: automationFailures,
            gatewayEventCount: app.gatewayEventCount,
            rollingEventCount: rollingEvents.count,
            eventThroughputPerMinute: Double(rollingEvents.count) / 5.0,
            lastGatewayEventName: app.lastGatewayEventName,
            patchyCycleRunning: app.patchyIsCycleRunning
        )

        let health = AnalyticsHealthMetrics(
            websocketLatencyMs: app.connectionDiagnostics.heartbeatLatencyMs,
            reconnectCount: app.status == .reconnecting ? 1 : 0,
            activeTaskCount: activeTaskCount,
            cpuUsagePercent: nil,
            memoryBytes: memoryBytes,
            memoryTrend: nil,
            eventQueueDepth: app.events.count,
            eventQueueLoad: min(Double(app.events.count) / 20.0, 1.0),
            apiResponseTimeMs: nil,
            state: healthState
        )
        let feed = makeFeed(app: app, healthState: healthState, now: now)

        return AnalyticsSnapshot(generatedAt: now, voice: voice, system: system, health: health, feed: feed)
    }

    private static func deterministicMostActiveDay(from dailyActivity: [(date: Date, count: Int)]) -> String {
        let activeDays = dailyActivity
            .filter { $0.count >= 1 }
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0.date < $1.date
            }
        guard let winner = activeDays.first else { return "-" }
        return winner.date.formatted(.dateTime.weekday(.wide))
    }

    private static func healthState(
        status: BotStatus,
        latencyMs: Int?,
        queueLoad: Double,
        failedCommandsToday: Int,
        automationFailures: Int
    ) -> AnalyticsHealthState {
        if status == .reconnecting {
            return .recovering
        }
        if latencyMs.map({ $0 >= 500 }) == true || queueLoad >= 0.90 || failedCommandsToday >= 5 {
            return .degraded
        }
        if latencyMs.map({ $0 >= 300 }) == true || queueLoad >= 0.70 || automationFailures > 0 || failedCommandsToday > 0 {
            return .warning
        }
        return .healthy
    }

    @MainActor
    private static func makeFeed(app: AppModel, healthState: AnalyticsHealthState, now: Date) -> [AnalyticsFeedEntry] {
        var entries: [AnalyticsFeedEntry] = []

        entries += app.events.prefix(8).map { event in
            AnalyticsFeedEntry(
                id: "event-\(event.id)",
                timestamp: event.timestamp,
                title: title(for: event.kind),
                detail: cleanedEventMessage(event.message),
                category: category(for: event.kind)
            )
        }

        entries += app.commandLog.prefix(5).map { command in
            AnalyticsFeedEntry(
                id: "command-\(command.id)",
                timestamp: command.time,
                title: command.ok ? "Command executed" : "Command failed",
                detail: "\(command.user) ran \(command.command)",
                category: .command
            )
        }

        entries += app.voiceLog.prefix(4).map { voice in
            AnalyticsFeedEntry(
                id: "voice-\(voice.id)",
                timestamp: voice.time,
                title: "Voice activity",
                detail: cleanedEventMessage(voice.description),
                category: .voice
            )
        }

        if let patchyLastCycleAt = app.patchyLastCycleAt {
            entries.append(AnalyticsFeedEntry(
                id: "patchy-\(patchyLastCycleAt.timeIntervalSince1970)",
                timestamp: patchyLastCycleAt,
                title: app.patchyIsCycleRunning ? "Automation running" : "Automation completed",
                detail: "Patchy update cycle processed",
                category: .automation
            ))
        }

        if healthState != .healthy {
            entries.append(AnalyticsFeedEntry(
                id: "health-\(healthState.rawValue)-\(Int(now.timeIntervalSince1970 / 60))",
                timestamp: now,
                title: "\(healthState.title) health state",
                detail: healthState.detail,
                category: .health
            ))
        }

        entries.append(AnalyticsFeedEntry(
            id: "launch-\(app.launchedAt.timeIntervalSince1970)",
            timestamp: app.launchedAt,
            title: "Analytics pipeline initialized",
            detail: "SwiftBot runtime metrics are being aggregated",
            category: .system
        ))

        let sortedEntries = entries.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.id < rhs.id
        }
        return Array(sortedEntries.prefix(12))
    }

    private static func title(for kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .voiceJoin: return "Voice session started"
        case .voiceLeave: return "Voice session ended"
        case .voiceMove: return "Voice channel changed"
        case .command: return "Command executed"
        case .info: return "System event"
        case .warning: return "Operational warning"
        case .error: return "Operational error"
        }
    }

    private static func category(for kind: ActivityEvent.Kind) -> AnalyticsFeedCategory {
        switch kind {
        case .voiceJoin, .voiceLeave, .voiceMove: return .voice
        case .command: return .command
        case .warning, .error: return .health
        case .info: return .system
        }
    }

    private static func cleanedEventMessage(_ message: String) -> String {
        ["🟢 ", "🔴 ", "🔀 ", "✅ ", "⚠️ ", "❌ "].reduce(message) { cleaned, marker in
            cleaned.replacingOccurrences(of: marker, with: "")
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AnalyticsDaySample: Identifiable, Codable, Equatable {
    var id: Date { date }
    let date: Date
    let count: Int
}

private struct AnalyticsHourSample: Identifiable, Codable, Equatable {
    var id: Int { hour }
    let hour: Int
    let count: Int

    var hasActivity: Bool {
        count >= 1
    }
}

private struct AnalyticsTopUser: Identifiable, Codable, Equatable {
    var id: String { username }
    let username: String
    let seconds: Int
    let totalSeconds: Int
    let isActive: Bool

    var initials: String {
        let pieces = username.split(separator: " ").prefix(2)
        let letters = pieces.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var activityShare: Int {
        guard totalSeconds > 0 else { return 0 }
        return Int((Double(seconds) / Double(totalSeconds) * 100).rounded())
    }
}

private struct AnalyticsInsight: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let symbol: String
    let color: Color
}
