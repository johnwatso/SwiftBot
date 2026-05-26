import Charts
import SwiftUI

struct AnalyticsView: View {
    @EnvironmentObject var app: AppModel

    @State private var snapshot = AnalyticsSnapshot.empty
    @State private var updatedAt = Date()
    @State private var hoveredUserID: String?

    private let secondaryCardHeight: CGFloat = 268
    private let featureCardHeight: CGFloat = 328

    private struct RankedInsight: Identifiable {
        let id: String
        let title: String
        let value: String
        let detail: String
        let symbol: String
        let color: Color
        let progress: Double
    }

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

    private var averageVoiceSessionText: String {
        guard sessionCountThisWeek > 0 else { return "--" }
        return formattedDuration(totalSecondsThisWeek / sessionCountThisWeek)
    }

    private var sessionsPerActiveDayText: String {
        let activeDays = max(dailyActivity.filter(\.hasActivity).count, 1)
        let average = Double(sessionCountThisWeek) / Double(activeDays)
        return String(format: "%.1f", average)
    }

    private var currentVoiceUsersText: String {
        "\(app.activeVoice.count)"
    }

    private var dailyActiveUsersText: String {
        let recentCommandUsers = Set(app.commandLog.filter { Calendar.current.isDateInToday($0.time) }.map(\.user))
        let activeVoiceUsers = Set(app.activeVoice.map(\.username))
        return "\(recentCommandUsers.union(activeVoiceUsers).count)"
    }

    private var messageVelocityText: String {
        String(format: "%.1f/min", snapshot.system.eventThroughputPerMinute)
    }

    private var commandNameRanks: [RankedInsight] {
        rankedCounts(
            values: app.commandLog.map { normalizedCommandName($0.command) },
            symbol: "terminal",
            color: .cyan,
            emptyDetail: "No command traffic yet"
        )
    }

    private var commandUserRanks: [RankedInsight] {
        rankedCounts(
            values: app.commandLog.map { friendlyUserName($0.user) },
            symbol: "person.text.rectangle",
            color: .teal,
            emptyDetail: "No command users yet"
        )
    }

    private var channelRanks: [RankedInsight] {
        rankedCounts(
            values: app.commandLog.map { friendlyTextChannelName($0.channel, server: $0.server) }.filter { !$0.isEmpty },
            symbol: "number",
            color: .blue,
            emptyDetail: "No channel activity yet"
        )
    }

    private var fastestGrowingChannel: RankedInsight? {
        let recentCutoff = Date().addingTimeInterval(-3600)
        return rankedCounts(
            values: app.commandLog
                .filter { $0.time >= recentCutoff }
                .map { friendlyTextChannelName($0.channel, server: $0.server) }
                .filter { !$0.isEmpty },
            symbol: "arrow.up.right",
            color: .green,
            emptyDetail: "No recent growth"
        ).first
    }

    private var quietestChannel: RankedInsight? {
        channelRanks.last
    }

    private var voiceMovementCount: Int {
        app.events.filter { $0.kind == .voiceMove }.count
    }

    private var automationSuccessRateText: String {
        let failures = snapshot.system.failedAutomationCount
        let total = max(snapshot.system.activeWorkflowCount + failures, 1)
        let rate = Double(max(total - failures, 0)) / Double(total)
        return "\(Int((rate * 100).rounded()))%"
    }

    private var peakVoiceChannel: String {
        let channelNames = app.voiceLog.compactMap { entry -> String? in
            let description = entry.description
            if let range = description.range(of: " joined ") {
                return String(description[range.upperBound...]).components(separatedBy: " — ").first
            }
            if let range = description.range(of: " left ") {
                return String(description[range.upperBound...]).components(separatedBy: " — ").first
            }
            return nil
        }
        return rankedCounts(values: channelNames, symbol: "waveform", color: .blue, emptyDetail: "No voice channels yet").first?.title ?? "--"
    }

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

    private var dailyChartYUpperBound: Int {
        max(2, snapshot.voice.peakDayCount + max(2, Int(ceil(Double(snapshot.voice.peakDayCount) * 0.25))))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    communityHero

                    voiceAnalyticsSection

                    HStack(alignment: .top, spacing: 12) {
                        communityAnalyticsSection
                            .frame(maxWidth: .infinity)
                        channelAnalyticsSection
                            .frame(maxWidth: .infinity)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        automationAnalyticsSection
                            .frame(maxWidth: .infinity)
                        infrastructureAnalyticsSection
                            .frame(maxWidth: .infinity)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        trendInsightsSection
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

    private var communityHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Community Intelligence")
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
                    title: "Most Active Day",
                    value: mostActiveDay,
                    detail: peakDayDetail,
                    symbol: "calendar.day.timeline.leading",
                    tint: .indigo,
                    prominence: .primary
                )
                metricCard(
                    title: "Average Voice Session",
                    value: averageVoiceSessionText,
                    detail: "\(sessionCountThisWeek) sessions this week",
                    symbol: "clock",
                    tint: .blue,
                    prominence: .primary
                )
                metricCard(
                    title: "Peak Voice Hour",
                    value: peakHour.map { hourLabel($0.hour) } ?? "--",
                    detail: peakHour.map { "\($0.count) session starts tracked" } ?? "No peak window yet",
                    symbol: "waveform",
                    tint: .cyan,
                    prominence: .primary
                )
                metricCard(
                    title: "Daily Active Users",
                    value: dailyActiveUsersText,
                    detail: "Commands and live voice today",
                    symbol: "person.2.fill",
                    tint: .green,
                    prominence: .secondary
                )
                metricCard(
                    title: "Most Active User",
                    value: topUsers.first?.username ?? "-",
                    detail: topUsers.first.map { "\($0.activityShare)% of tracked voice time" } ?? "No completed sessions yet",
                    symbol: "person.fill",
                    tint: .teal,
                    prominence: .secondary
                )
            }
        }
        .padding(11)
        .dashboardSurface(cornerRadius: 22, fillOpacity: 0.035, strokeOpacity: 0.08, shadowOpacity: 0.018)
    }

    private var activityOverview: some View {
        analyticsCard(title: "Activity Overview", subtitle: peakHour.map { "Peak activity at \(hourLabel($0.hour))" } ?? "Live operational timeline", symbol: "dot.radiowaves.left.and.right") {
            HStack(alignment: .top, spacing: 14) {
                runtimeActivityChart
                    .frame(minWidth: 420, maxWidth: .infinity)

                runtimeFeedPanel
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(minHeight: 154, alignment: .top)
        }
    }

    private var voiceAnalyticsSection: some View {
        analyticsCard(
            title: "Voice Analytics",
            subtitle: "\(formattedDuration(totalSecondsThisWeek)) tracked this week",
            symbol: "waveform.and.mic"
        ) {
            HStack(alignment: .top, spacing: 14) {
                runtimeActivityChart
                    .frame(minWidth: 320, maxWidth: .infinity)
                    .layoutPriority(1)

                VStack(alignment: .leading, spacing: 10) {
                    insightTile(
                        title: "Most Active Voice Channel",
                        value: peakVoiceChannel,
                        detail: "\(voiceMovementCount) channel movement\(voiceMovementCount == 1 ? "" : "s") tracked",
                        symbol: "speaker.wave.2.fill",
                        color: .blue
                    )
                    insightTile(
                        title: "Current Voice Users",
                        value: currentVoiceUsersText,
                        detail: "\(sessionsPerActiveDayText) sessions per active day",
                        symbol: "person.3.sequence.fill",
                        color: .green
                    )
                    peakHourChart
                        .frame(height: 112)
                }
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 420)
                .layoutPriority(1)
            }
            .frame(minHeight: 230, alignment: .top)
        }
    }

    private var communityAnalyticsSection: some View {
        analyticsCard(title: "Community Analytics", subtitle: "Users, commands, and engagement", symbol: "person.2.wave.2.fill") {
            cardScrollContent {
                VStack(spacing: 8) {
                    insightTile(
                        title: "Message Velocity",
                        value: messageVelocityText,
                        detail: "\(rollingEventCount) community/runtime events in the last window",
                        symbol: "speedometer",
                        color: .green
                    )
                    if let first = commandUserRanks.first {
                        insightTile(
                            title: "Top Command User",
                            value: first.title,
                            detail: first.detail,
                            symbol: "person.text.rectangle",
                            color: .teal
                        )
                    }
                    rankedList(title: "Command Users", rows: Array(commandUserRanks.prefix(4)))
                    if let streak = snapshot.voice.topUserStreak {
                        insightTile(
                            title: "Engagement Streak",
                            value: "\(streak.days)d",
                            detail: "\(streak.username) has the current voice streak",
                            symbol: "flame.fill",
                            color: .orange
                        )
                    }
                }
            }
        }
        .frame(height: secondaryCardHeight, alignment: .top)
    }

    private var channelAnalyticsSection: some View {
        analyticsCard(title: "Channel Analytics", subtitle: "Where activity concentrates", symbol: "square.grid.2x2") {
            cardScrollContent {
                VStack(spacing: 8) {
                    if let first = channelRanks.first {
                        insightTile(
                            title: "Most Active Text Channel",
                            value: first.title,
                            detail: first.detail,
                            symbol: "number",
                            color: .blue
                        )
                    } else {
                        insightTile(
                            title: "Most Active Text Channel",
                            value: "--",
                            detail: "No command channel activity yet",
                            symbol: "number",
                            color: .blue
                        )
                    }
                    if let fastestGrowingChannel {
                        insightTile(
                            title: "Fastest Growing Channel",
                            value: fastestGrowingChannel.title,
                            detail: "Most command activity in the last hour",
                            symbol: "arrow.up.right",
                            color: .green
                        )
                    }
                    if let quietestChannel {
                        insightTile(
                            title: "Quietest Channel",
                            value: quietestChannel.title,
                            detail: quietestChannel.detail,
                            symbol: "speaker.slash",
                            color: .secondary
                        )
                    }
                    insightTile(
                        title: "Media Upload Trends",
                        value: "\(app.recentMediaCount24h)",
                        detail: "new recordings in the last 24 hours",
                        symbol: "film.fill",
                        color: .purple
                    )
                }
            }
        }
        .frame(height: secondaryCardHeight, alignment: .top)
    }

    private var automationAnalyticsSection: some View {
        analyticsCard(title: "Automation Analytics", subtitle: "Rules, AI, and execution patterns", symbol: "wand.and.stars") {
            cardScrollContent {
                VStack(spacing: 8) {
                    if let firstCommand = commandNameRanks.first {
                        insightTile(
                            title: "Most Triggered Rule",
                            value: firstCommand.title,
                            detail: firstCommand.detail,
                            symbol: "bolt.badge.automatic.fill",
                            color: .cyan
                        )
                    }
                    insightTile(
                        title: "AI Usage Count",
                        value: "\(app.commandLog.filter { $0.command.localizedCaseInsensitiveContains("ai") }.count)",
                        detail: "\(app.settings.preferredAIProvider.rawValue) provider selected",
                        symbol: "sparkles",
                        color: .purple
                    )
                    insightTile(
                        title: "Rule Success Rate",
                        value: automationSuccessRateText,
                        detail: "\(snapshot.system.failedAutomationCount) failed automation signal\(snapshot.system.failedAutomationCount == 1 ? "" : "s")",
                        symbol: "checkmark.seal",
                        color: snapshot.system.failedAutomationCount > 0 ? .orange : .green
                    )
                    rankedList(title: "Top Commands", rows: Array(commandNameRanks.prefix(4)))
                }
            }
        }
        .frame(height: secondaryCardHeight, alignment: .top)
    }

    private var infrastructureAnalyticsSection: some View {
        analyticsCard(title: "Infrastructure Analytics", subtitle: "Trends behind the community surface", symbol: "cpu") {
            cardScrollContent {
                VStack(spacing: 8) {
                    compactSignal(
                        title: "Gateway Uptime Trend",
                        value: app.uptime?.text ?? "--",
                        detail: snapshot.health.state.detail,
                        color: snapshot.health.state.color
                    )
                    compactSignal(
                        title: "Queue Throughput",
                        value: messageVelocityText,
                        detail: "\(snapshot.health.eventQueueDepth)/20 retained event depth",
                        color: snapshot.health.eventQueueLoad > 0.75 ? .orange : .green
                    )
                    compactSignal(
                        title: "Worker Performance",
                        value: "\(app.clusterNodes.reduce(0) { $0 + $1.jobsActive }) jobs",
                        detail: app.settings.clusterMode.displayName,
                        color: .blue
                    )
                    compactSignal(
                        title: "Cluster Sync Frequency",
                        value: app.lastClusterStatusSuccessAt.map { relativeText(since: $0) } ?? "--",
                        detail: app.clusterSnapshot.serverStatusText,
                        color: .teal
                    )
                    compactSignal(
                        title: "Patchy Execution Frequency",
                        value: app.patchyLastCycleAt.map { relativeText(since: $0) } ?? "--",
                        detail: app.patchyIsCycleRunning ? "Cycle running now" : "\(app.settings.patchy.sourceTargets.filter(\.isEnabled).count) targets enabled",
                        color: .purple
                    )
                }
            }
        }
        .frame(height: secondaryCardHeight, alignment: .top)
    }

    private var runtimeActivityChart: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Voice Activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Last 7 days · peak \(snapshot.voice.peakDayCount)")
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
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.accentColor.opacity(0.24), .accentColor.opacity(0.035)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Day", item.date, unit: .day),
                            y: .value("Sessions", item.count)
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.accentColor)

                        PointMark(
                            x: .value("Day", item.date, unit: .day),
                            y: .value("Sessions", item.count)
                        )
                        .symbolSize(item.count == snapshot.voice.peakDayCount ? 48 : 20)
                        .foregroundStyle(Color.accentColor.opacity(0.82))
                        .annotation(position: .top, alignment: .center, spacing: 4) {
                            if hasValue(item.count) {
                                Text("\(item.count)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }

                    RuleMark(y: .value("Average", averageSessionsPerDay))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.accentColor.opacity(0.28))
                }
                .chartPlotStyle { plot in
                    plot
                        .padding(.top, 18)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                .chartXScale(domain: dailyChartDomain)
                .chartYScale(domain: -0.45...Double(dailyChartYUpperBound))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 188)
                .background(.black.opacity(0.018), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                HStack(spacing: 0) {
                    ForEach(dailyActivity) { item in
                        Text(item.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 5)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.026), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var systemActivity: some View {
        analyticsCard(title: "System Activity", subtitle: "Runtime signals", symbol: "bolt.horizontal.circle") {
            cardScrollContent {
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
        .frame(height: secondaryCardHeight, alignment: .top)
    }

    private var botHealth: some View {
        analyticsCard(title: "Bot Health", subtitle: snapshot.health.state.title, symbol: "waveform.path.ecg") {
            cardScrollContent {
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
                        title: "Gateway Heartbeat",
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
        .frame(height: secondaryCardHeight, alignment: .top)
    }

    private var topUsersSection: some View {
        analyticsCard(title: "Voice Leaders", subtitle: "Ranked voice activity", symbol: "person.3.fill") {
            if topUsers.isEmpty {
                emptyState("No completed voice sessions yet")
            } else {
                cardScrollContent {
                    VStack(spacing: 6) {
                        ForEach(Array(topUsers.enumerated()), id: \.element.id) { index, user in
                            rankedUserRow(rank: index + 1, user: user)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: featureCardHeight, alignment: .top)
    }

    private var trendInsightsSection: some View {
        analyticsCard(title: "Trend Insights", subtitle: "Streaks, anomalies, and behavior shifts", symbol: "sparkles") {
            TimelineView(.periodic(from: .now, by: 12)) { timeline in
                let deck = operationalInsights(at: timeline.date)
                cardScrollContent {
                    VStack(alignment: .leading, spacing: 6) {
                        if let featured = deck.featured {
                            operationalInsightCard(featured, isFeatured: true)
                        }

                        if !deck.supporting.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(deck.supporting) { insight in
                                    operationalInsightCard(insight, isFeatured: false)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: featureCardHeight, alignment: .top)
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
        .dashboardSurface(cornerRadius: 18, fillOpacity: 0.032, strokeOpacity: 0.075, shadowOpacity: 0.018)
    }

    private func cardScrollContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 1)
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
        .background(Color.primary.opacity(0.030), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(color.opacity(0.14), lineWidth: 1)
        )
    }

    private var peakHourChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Peak Voice Hours")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(peakHour.map { hourLabel($0.hour) } ?? "--")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if !hourlyActivity.contains(where: { $0.hasActivity }) {
                emptyState("No hourly voice data yet")
            } else {
                Chart {
                    ForEach(hourlyActivity) { item in
                        BarMark(
                            x: .value("Hour", item.hour),
                            y: .value("Sessions", item.count)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .foregroundStyle(item.hour == peakHour?.hour ? Color.accentColor : Color.accentColor.opacity(0.32))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                        AxisValueLabel {
                            if let hour = value.as(Int.self) {
                                Text(hourLabel(hour))
                            }
                        }
                    }
                }
                .chartYAxis(.hidden)
                .chartPlotStyle { plot in
                    plot
                        .background(.black.opacity(0.025))
                        .padding(.horizontal, 4)
                }
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.026), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.primary.opacity(0.055), lineWidth: 1)
        )
    }

    private func insightTile(title: String, value: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.headline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(0.14), lineWidth: 1)
        )
    }

    private func rankedList(title: String, rows: [RankedInsight]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("No data yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .center)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Image(systemName: row.symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(row.color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(row.value)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: row.progress)
                                .tint(row.color)
                                .controlSize(.mini)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.020), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.primary.opacity(0.045), lineWidth: 1)
        )
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
            AnyShapeStyle(Color.primary.opacity(hoveredUserID == user.id ? 0.050 : 0.028)),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(rank == 1 ? Color.accentColor.opacity(0.18) : .primary.opacity(0.055), lineWidth: 1)
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

    private func operationalInsights(at now: Date) -> OperationalInsightDeck {
        OperationalInsightsEngine.make(
            context: .init(
                now: now,
                status: app.status,
                uptime: app.uptime,
                activeVoiceCount: app.activeVoice.count,
                dailyActivity: dailyActivity,
                hourlyActivity: hourlyActivity,
                topUsers: topUsers,
                topUserStreak: snapshot.voice.topUserStreak,
                commandLog: app.commandLog,
                events: app.events,
                rules: app.ruleStore.rules,
                patchyMonitoringEnabled: app.settings.patchy.monitoringEnabled,
                patchyEnabledTargetCount: app.settings.patchy.sourceTargets.filter(\.isEnabled).count,
                patchyTotalTargetCount: app.settings.patchy.sourceTargets.count,
                patchyCycleRunning: app.patchyIsCycleRunning,
                patchyLastCycleAt: app.patchyLastCycleAt,
                clusterMode: app.settings.clusterMode,
                clusterNodes: app.clusterNodes,
                lastClusterStatusSuccessAt: app.lastClusterStatusSuccessAt,
                lastVoiceStateAt: app.lastVoiceStateAt,
                health: snapshot.health,
                system: snapshot.system
            )
        )
    }

    private func operationalInsightCard(_ insight: OperationalInsight, isFeatured: Bool) -> some View {
        VStack(alignment: .leading, spacing: isFeatured ? 8 : 6) {
            HStack(alignment: .top, spacing: isFeatured ? 9 : 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: isFeatured ? 9 : 8, style: .continuous)
                        .fill(insight.tone.fillColor.opacity(isFeatured ? 0.18 : 0.14))
                    Image(systemName: insight.symbol)
                        .font(isFeatured ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                        .foregroundStyle(insight.tone.accentColor)
                }
                .frame(width: isFeatured ? 28 : 22, height: isFeatured ? 28 : 22)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(insight.title)
                            .font(isFeatured ? .caption.weight(.semibold) : .caption2.weight(.semibold))
                            .lineLimit(isFeatured ? 2 : 1)
                        Spacer(minLength: 6)
                        Text(insight.tone.label)
                        .font(.caption2.weight(.semibold))
                            .foregroundStyle(insight.tone.accentColor)
                            .padding(.horizontal, isFeatured ? 6 : 5)
                            .padding(.vertical, 2)
                            .background(insight.tone.fillColor.opacity(0.14), in: Capsule())
                    }

                    Text(insight.body)
                        .font(isFeatured ? .caption2 : .caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(isFeatured ? 2 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isFeatured, let note = insight.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(isFeatured ? 9 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: isFeatured ? 13 : 10, style: .continuous)
                    .fill(Color.primary.opacity(isFeatured ? 0.034 : 0.026))
                LinearGradient(
                    colors: [
                        insight.tone.fillColor.opacity(isFeatured ? 0.18 : 0.14),
                        Color.white.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: isFeatured ? 13 : 10, style: .continuous))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: isFeatured ? 13 : 10, style: .continuous)
                .strokeBorder(insight.tone.borderColor, lineWidth: 1)
        )
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
        return count
    }

    private var latencyProgress: Double? {
        guard let latency = snapshot.health.websocketLatencyMs else { return nil }
        return min(Double(latency) / Double(ConnectionDiagnostics.gatewayHeartbeatCriticalThresholdMs), 1.0)
    }

    private var latencyColor: Color {
        guard let latency = snapshot.health.websocketLatencyMs else { return .secondary }
        if ConnectionDiagnostics.isGatewayHeartbeatCritical(latency) { return .red }
        if ConnectionDiagnostics.isGatewayHeartbeatWarning(latency) { return .orange }
        if latency >= 500 { return .yellow }
        return .green
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
        case 0: return "12 AM"
        case 12: return "12 PM"
        case let hourBeforeNoon where hourBeforeNoon < 12: return "\(hourBeforeNoon) AM"
        default: return "\(hour - 12) PM"
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

    private func relativeText(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    private func normalizedCommandName(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Command" }
        if let first = trimmed.split(whereSeparator: \.isWhitespace).first {
            return String(first)
        }
        return trimmed
    }

    private func friendlyUserName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let userID = discordMentionID(from: trimmed, marker: "@"),
           let displayName = app.knownUsersById[userID],
           !displayName.isEmpty {
            return displayName
        }
        if let displayName = app.knownUsersById[trimmed], !displayName.isEmpty {
            return displayName
        }
        if looksLikeDiscordID(trimmed) {
            return "User \(trimmed.suffix(4))"
        }
        return trimmed
    }

    private func friendlyTextChannelName(_ raw: String, server: String?) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("#") { return trimmed }

        let channelID = discordMentionID(from: trimmed, marker: "#") ?? trimmed
        if let serverID = resolvedServerID(from: server),
           let channel = app.availableTextChannelsByServer[serverID]?.first(where: { matchesChannel($0, value: channelID) }) {
            return "#\(channel.name)"
        }
        if let channel = app.availableTextChannelsByServer.values
            .flatMap({ $0 })
            .first(where: { matchesChannel($0, value: channelID) }) {
            return "#\(channel.name)"
        }

        let lower = trimmed.lowercased()
        if lower == "dm" || lower == "direct message" || trimmed == "-" {
            return trimmed
        }
        if looksLikeDiscordID(channelID) {
            return "Channel \(channelID.suffix(4))"
        }
        return "#\(trimmed)"
    }

    private func matchesChannel(_ channel: GuildTextChannel, value: String) -> Bool {
        channel.id == value || channel.name.localizedCaseInsensitiveCompare(value) == .orderedSame
    }

    private func resolvedServerID(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if app.connectedServers[trimmed] != nil { return trimmed }
        return app.connectedServers.first { _, name in
            name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }?.key
    }

    private func discordMentionID(from value: String, marker: Character) -> String? {
        guard value.first == "<", value.dropFirst().first == marker, value.last == ">" else { return nil }
        let body = value.dropFirst(2).dropLast()
        return String(body).trimmingCharacters(in: CharacterSet(charactersIn: "!&"))
    }

    private func looksLikeDiscordID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 15 && trimmed.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private func rankedCounts(values: [String], symbol: String, color: Color, emptyDetail: String) -> [RankedInsight] {
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "-" }
        let grouped = Dictionary(grouping: cleaned, by: { $0 })
        let maxCount = max(grouped.values.map(\.count).max() ?? 0, 1)
        return grouped
            .map { key, entries in
                RankedInsight(
                    id: "\(symbol)-\(key)",
                    title: key,
                    value: "\(entries.count)",
                    detail: entries.count == 1 ? "1 tracked event" : "\(entries.count) tracked events",
                    symbol: symbol,
                    color: color,
                    progress: Double(entries.count) / Double(maxCount)
                )
            }
            .sorted {
                if $0.progress != $1.progress {
                    return $0.progress > $1.progress
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
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
        async let userStreak = app.voiceSessionStore.getTopUserStreakLast7Days()
        async let totalTime = app.voiceSessionStore.getTotalVoiceTimeThisWeek()
        async let sessionCount = app.voiceSessionStore.getSessionCountThisWeek()

        let loadedDaily = await daily
        let loadedHourly = await hourly
        let loadedUsers = await users
        let loadedUserStreak = await userStreak
        let loadedTotalSeconds = Int(await totalTime)
        let activeUsernames = Set(app.activeVoice.map(\.username))

        snapshot = AnalyticsAggregator.makeSnapshot(
            dailyActivity: loadedDaily,
            hourlyActivity: loadedHourly,
            topUsers: loadedUsers,
            topUserStreak: loadedUserStreak,
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

enum AnalyticsDashboardSummary {
    @MainActor
    static func metrics(app: AppModel) -> [DashboardMetricDescriptor] {
        let calendar = Calendar.current
        let commandUserIDs = app.commandLog
            .filter { calendar.isDateInToday($0.time) }
            .map(\.user)
        let voiceUserIDs = app.activeVoice.map(\.userId)
        let activeUsers = Set(commandUserIDs + voiceUserIDs).count
        let sessionsThisWeek = app.voiceLog.filter { entry in
            guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) else { return false }
            return entry.time >= weekAgo
        }.count

        return [
            DashboardMetricDescriptor(
                id: "analytics",
                title: "Analytics",
                value: "\(activeUsers)",
                subtitle: "daily active users",
                symbol: "chart.line.uptrend.xyaxis",
                detail: "\(sessionsThisWeek) voice events this week",
                color: .green
            )
        ]
    }
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
    let topUserStreak: AnalyticsUserStreak?
    let mostActiveDay: String
    let totalSecondsThisWeek: Int
    let sessionCountThisWeek: Int

    static let empty = AnalyticsVoiceSummary(
        dailyActivity: [],
        hourlyActivity: [],
        topUsers: [],
        topUserStreak: nil,
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
        topUserStreak: (username: String, days: Int)?,
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
            topUserStreak: topUserStreak.map { AnalyticsUserStreak(username: $0.username, days: $0.days) },
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

    @MainActor
    private static func friendlyUserName(_ raw: String, app: AppModel) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let displayName = app.knownUsersById[trimmed], !displayName.isEmpty {
            return displayName
        }
        if trimmed.count >= 15 && trimmed.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return "User \(trimmed.suffix(4))"
        }
        return trimmed
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
        if ConnectionDiagnostics.isGatewayHeartbeatCritical(latencyMs) || queueLoad >= 0.90 || failedCommandsToday >= 5 {
            return .degraded
        }
        if ConnectionDiagnostics.isGatewayHeartbeatWarning(latencyMs)
            || queueLoad >= 0.70
            || automationFailures > 0
            || failedCommandsToday > 0 {
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
                detail: "\(friendlyUserName(command.user, app: app)) ran \(command.command)",
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
            title: "Analytics started",
            detail: "SwiftBot is now tracking activity, health, and usage trends",
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

    var hasActivity: Bool {
        count >= 1
    }
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

private struct AnalyticsUserStreak: Codable, Equatable {
    let username: String
    let days: Int
}

private struct OperationalInsightDeck {
    let featured: OperationalInsight?
    let supporting: [OperationalInsight]
}

private struct OperationalInsight: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let symbol: String
    let tone: OperationalInsightTone
    let weight: Int
    let note: String?
}

private enum OperationalInsightTone: Int, Equatable {
    case info
    case healthy
    case warning
    case error

    var label: String {
        switch self {
        case .info: return "Info"
        case .healthy: return "Healthy"
        case .warning: return "Watch"
        case .error: return "Alert"
        }
    }

    var accentColor: Color {
        switch self {
        case .info: return .blue
        case .healthy: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    var fillColor: Color {
        accentColor
    }

    var borderColor: Color {
        accentColor.opacity(0.20)
    }

    var rank: Int {
        switch self {
        case .error: return 4
        case .warning: return 3
        case .healthy: return 2
        case .info: return 1
        }
    }
}

private struct OperationalInsightContext {
    let now: Date
    let status: BotStatus
    let uptime: UptimeInfo?
    let activeVoiceCount: Int
    let dailyActivity: [AnalyticsDaySample]
    let hourlyActivity: [AnalyticsHourSample]
    let topUsers: [AnalyticsTopUser]
    let topUserStreak: AnalyticsUserStreak?
    let commandLog: [CommandLogEntry]
    let events: [ActivityEvent]
    let rules: [Rule]
    let patchyMonitoringEnabled: Bool
    let patchyEnabledTargetCount: Int
    let patchyTotalTargetCount: Int
    let patchyCycleRunning: Bool
    let patchyLastCycleAt: Date?
    let clusterMode: ClusterMode
    let clusterNodes: [ClusterNodeStatus]
    let lastClusterStatusSuccessAt: Date?
    let lastVoiceStateAt: Date?
    let health: AnalyticsHealthMetrics
    let system: AnalyticsSystemMetrics
}

private enum OperationalInsightsEngine {
    static func make(context: OperationalInsightContext) -> OperationalInsightDeck {
        let insights = [
            gatewayUptimeInsight(context),
            voiceStreakInsight(context),
            userStreakInsight(context),
            topCommandInsight(context),
            automationCoverageInsight(context),
            clusterInsight(context),
            patchyInsight(context),
            anomalyInsight(context),
            healthInsight(context),
            weeklyConcentrationInsight(context),
            peakVoiceWindowInsight(context),
            gatewayStabilityInsight(context),
            commandReliabilityInsight(context),
            automationCadenceInsight(context)
        ]
        .compactMap { $0 }
        .sorted(by: insightOrder)

        guard !insights.isEmpty else {
            return OperationalInsightDeck(featured: nil, supporting: [])
        }

        let featuredPool = Array(insights.prefix(min(3, insights.count)))
        let rotationIndex = Int(context.now.timeIntervalSinceReferenceDate / 12) % max(featuredPool.count, 1)
        let featured = featuredPool[rotationIndex]
        let supporting = insights.filter { $0.id != featured.id }
        return OperationalInsightDeck(featured: featured, supporting: supporting)
    }

    private static func insightOrder(lhs: OperationalInsight, rhs: OperationalInsight) -> Bool {
        if lhs.tone.rank != rhs.tone.rank {
            return lhs.tone.rank > rhs.tone.rank
        }
        if lhs.weight != rhs.weight {
            return lhs.weight > rhs.weight
        }
        return lhs.title < rhs.title
    }

    private static func gatewayUptimeInsight(_ context: OperationalInsightContext) -> OperationalInsight? {
        guard let uptime = context.uptime, context.status == .running else { return nil }
        let hours = Int(context.now.timeIntervalSince(uptime.startedAt) / 3600)
        let tone: OperationalInsightTone = context.health.state == .healthy ? .healthy : .info
        let body: String
        if hours >= 24 {
            body = "Gateway has stayed online for \(hours / 24)d \(hours % 24)h without a restart."
        } else {
            body = "Gateway has stayed online for \(uptime.text) without a restart."
        }
        return OperationalInsight(
            id: "gateway-uptime",
            title: "Gateway uptime streak",
            body: body,
            symbol: "bolt.badge.clock",
            tone: tone,
            weight: max(1, hours),
            note: context.system.gatewayEventCount > 0 ? "\(context.system.gatewayEventCount) gateway events processed this session." : nil
        )
    }

    private static func voiceStreakInsight(_ context: OperationalInsightContext) -> OperationalInsight? {
        let streak = currentActiveDayStreak(from: context.dailyActivity)
        guard streak > 0 else { return nil }
        let peakDay = context.dailyActivity.max(by: { $0.count < $1.count })
        let detail = peakDay.map { "\(weekdayName(for: $0.date)) peaked at \($0.count) sessions." }
        return OperationalInsight(
            id: "voice-streak",
            title: "Voice activity streak",
            body: "Voice has been active for \(streak) straight day\(streak == 1 ? "" : "s") in the rolling 7-day window.",
            symbol: "waveform.and.mic",
            tone: streak >= 4 ? .healthy : .info,
            weight: streak,
            note: detail
        )
    }

    private static func userStreakInsight(_ context: OperationalInsightContext) -> OperationalInsight? {
        guard let streak = context.topUserStreak, streak.days >= 2 else { return nil }
        let activityShare = context.topUsers.first(where: { $0.username == streak.username })?.activityShare
        let note = activityShare.map { "\($0)% of this week's tracked voice time." }
        return OperationalInsight(
            id: "user-streak-\(streak.username)",
            title: "User activity streak",
            body: "\(streak.username) has shown up \(streak.days) days in a row.",
            symbol: "person.crop.circle.badge.checkmark",
            tone: .healthy,
            weight: streak.days + (activityShare ?? 0),
            note: note
        )
    }

    private static func topCommandInsight(_ context: OperationalInsightContext) -> OperationalInsight? {
        let commands = context.commandLog.map(\.command)
        guard !commands.isEmpty else { return nil }
        let grouped = Dictionary(grouping: commands.map(normalizedCommandName), by: { $0 })
        guard let winner = grouped.max(by: { $0.value.count < $1.value.count }) else { return nil }
        let note = context.system.commandsToday > 0 ? "\(context.system.commandsToday) command\(context.system.commandsToday == 1 ? "" : "s") today." : nil
        return OperationalInsight(
            id: "command-\(winner.key)",
            title: "Most active command",
            body: "\(winner.key) leads recent command traffic with \(winner.value.count) run\(winner.value.count == 1 ? "" : "s").",
            symbol: "terminal",
            tone: .info,
            weight: winner.value.count,
            note: note
        )
    }

    private static func automationCoverageInsight(_ context: OperationalInsightContext) -> OperationalInsight? {
        let enabledRules = context.rules.filter(\.isEnabled)
        let configuredActions = enabledRules.reduce(0) { $0 + actionableBlockCount(in: $1) }
        let activeWorkflowCount = enabledRules.count
        guard configuredActions > 0 || context.patchyEnabledTargetCount > 0 else { return nil }

        let body = "\(configuredActions) automation action\(configuredActions == 1 ? "" : "s") are armed across \(activeWorkflowCount) live workflow\(activeWorkflowCount == 1 ? "" : "s")."
        let note: String
        if context.patchyEnabledTargetCount > 0 {
            note = "Patchy is watching \(context.patchyEnabledTargetCount) of \(context.patchyTotalTargetCount) configured target\(context.patchyTotalTargetCount == 1 ? "" : "s")."
        } else {
            note = "No Patchy monitoring targets are enabled right now."
        }

        return OperationalInsight(
            id: "automation-coverage",
            title: "Automation footprint",
            body: body,
            symbol: "wand.and.stars.inverse",
            tone: configuredActions >= 6 ? .healthy : .info,
            weight: configuredActions + activeWorkflowCount,
            note: note
        )
    }

    private static func clusterInsight(_ context: OperationalInsightContext) -> OperationalInsight? {
        guard context.clusterMode != .standalone else {
            return OperationalInsight(
                id: "cluster-standalone",
                title: "Cluster posture",
                body: "SwiftBot is operating as a standalone node with no failover peers attached.",
                symbol: "point.3.filled.connected.trianglepath.dotted",
                tone: .info,
                weight: 1,
                note: nil
            )
        }

        let connected = context.clusterNodes.filter { $0.status == .healthy }.count
        let degraded = context.clusterNodes.filter { $0.status == .degraded }.count
        let disconnected = context.clusterNodes.filter { $0.status == .disconnected }.count
        let leaderLatency = context.clusterNodes.first(where: { $0.role == .leader })?.latencyMs

        let tone: OperationalInsightTone = if disconnected > 0 {
            .error
        } else if degraded > 0 {
            .warning
        } else {
            .healthy
        }

        let body = "\(connected) node\(connected == 1 ? "" : "s") connected, \(degraded) degraded, \(disconnected) offline."
        let note = leaderLatency.map { "Leader latency is \(Int($0)) ms." }

        return OperationalInsight(
            id: "cluster-health",
            title: "Cluster stability",
            body: body,
            symbol: "point.3.connected.trianglepath.dotted",
            tone: tone,
            weight: connected + degraded + disconnected,
            note: note
        )
    }

    private static func patchyInsight(_ context: OperationalInsightContext) -> OperationalInsight? {
        guard context.patchyMonitoringEnabled || context.patchyTotalTargetCount > 0 else { return nil }

        let tone: OperationalInsightTone = if context.patchyCycleRunning {
            .info
        } else {
            .healthy
        }

        let body: String
        if context.patchyCycleRunning {
            body = "Patchy is actively processing update checks across \(context.patchyEnabledTargetCount) enabled target\(context.patchyEnabledTargetCount == 1 ? "" : "s")."
        } else if let lastCycleAt = context.patchyLastCycleAt {
            body = "Last Patchy monitoring cycle completed \(relativeText(since: lastCycleAt, now: context.now))."
        } else {
            body = "Patchy monitoring is configured and waiting for its next cycle."
        }

        let note = "\(context.patchyEnabledTargetCount) of \(context.patchyTotalTargetCount) targets enabled."

        return OperationalInsight(
            id: "patchy-monitoring",
            title: "Patchy monitoring",
            body: body,
            symbol: "shippingbox.and.arrow.backward",
            tone: tone,
            weight: context.patchyEnabledTargetCount,
            note: note
        )
    }

    private static func anomalyInsight(_ context: OperationalInsightContext) -> OperationalInsight? {
        if let latency = context.health.websocketLatencyMs,
           ConnectionDiagnostics.isGatewayHeartbeatWarning(latency) {
            return OperationalInsight(
                id: "anomaly-latency",
                title: "Gateway heartbeat elevated",
                body: "Gateway heartbeat is holding at \(latency) ms, above the normal operating band.",
                symbol: "waveform.path.badge.exclamationmark",
                tone: ConnectionDiagnostics.isGatewayHeartbeatCritical(latency) ? .error : .warning,
                weight: latency,
                note: context.health.state.detail
            )
        }

        if context.system.rollingEventCount == 0,
           context.status == .running,
           let latestEventAt = context.events.first?.timestamp {
            let minutesSilent = Int(context.now.timeIntervalSince(latestEventAt) / 60)
            if minutesSilent >= 10 {
                return OperationalInsight(
                    id: "anomaly-silence",
                    title: "Gateway quiet spell",
                    body: "No new runtime events have been observed for \(minutesSilent)m while the bot is still online.",
                    symbol: "antenna.radiowaves.left.and.right.slash",
                    tone: .warning,
                    weight: minutesSilent,
                    note: "Recent event queue depth is \(context.health.eventQueueDepth)."
                )
            }
        }

        if context.clusterMode != .standalone,
           let lastClusterStatusSuccessAt = context.lastClusterStatusSuccessAt {
            let minutesSinceRefresh = Int(context.now.timeIntervalSince(lastClusterStatusSuccessAt) / 60)
            if minutesSinceRefresh >= 12 {
                return OperationalInsight(
                    id: "anomaly-cluster-stale",
                    title: "Cluster status stale",
                    body: "SwiftMesh health has not refreshed for \(minutesSinceRefresh)m.",
                    symbol: "clock.badge.exclamationmark",
                    tone: .warning,
                    weight: minutesSinceRefresh,
                    note: "Latest cluster snapshot may be out of date."
                )
            }
        }

        return nil
    }

    private static func healthInsight(_ context: OperationalInsightContext) -> OperationalInsight {
        let tone: OperationalInsightTone = switch context.health.state {
        case .healthy: .healthy
        case .warning, .recovering: .warning
        case .degraded: .error
        }

        let peakHourText = context.hourlyActivity.max(by: { $0.count < $1.count }).flatMap {
            $0.hasActivity ? hourLabel($0.hour) : nil
        }

        let note: String?
        if let peakHourText {
            note = "Voice starts trend highest around \(peakHourText)."
        } else {
            note = "\(Int(context.system.commandSuccessRate * 100))% command success across \(context.system.commandsRunLifetime) tracked runs."
        }

        return OperationalInsight(
            id: "health-state",
            title: "System health",
            body: context.health.state.detail,
            symbol: context.health.state.symbol,
            tone: tone,
            weight: Int(context.health.eventQueueLoad * 100),
            note: note
        )
    }

    private static func weeklyConcentrationInsight(_ context: OperationalInsightContext) -> OperationalInsight? {
        guard let peakDay = context.dailyActivity.max(by: { $0.count < $1.count }),
              peakDay.hasActivity else { return nil }

        let totalSessions = context.dailyActivity.reduce(0) { $0 + $1.count }
        let averageSessionsPerDay = Double(totalSessions) / Double(max(context.dailyActivity.count, 1))
        guard averageSessionsPerDay > 0 else { return nil }

        let lift = Int(max(((Double(peakDay.count) / averageSessionsPerDay) - 1) * 100, 0).rounded())
        let tone: OperationalInsightTone = lift >= 75 ? .healthy : .info

        return OperationalInsight(
            id: "weekly-concentration",
            title: "Weekly concentration",
            body: "\(weekdayName(for: peakDay.date)) ran \(lift)% above the 7-day average.",
            symbol: "chart.line.uptrend.xyaxis",
            tone: tone,
            weight: max(1, min(lift, 24)),
            note: "\(peakDay.count) voice session\(peakDay.count == 1 ? "" : "s") landed on that day."
        )
    }

    private static func peakVoiceWindowInsight(_ context: OperationalInsightContext) -> OperationalInsight? {
        guard let peakHour = context.hourlyActivity.max(by: { $0.count < $1.count }),
              peakHour.hasActivity else { return nil }

        return OperationalInsight(
            id: "voice-peak-window",
            title: "Voice peak window",
            body: "Voice sessions are most likely to start around \(hourLabel(peakHour.hour)).",
            symbol: "clock",
            tone: .info,
            weight: max(1, min(peakHour.count, 20)),
            note: "\(peakHour.count) session start\(peakHour.count == 1 ? "" : "s") were tracked in that hour band."
        )
    }

    private static func gatewayStabilityInsight(_ context: OperationalInsightContext) -> OperationalInsight? {
        guard context.health.state == .healthy else { return nil }

        let note: String?
        if context.system.rollingEventCount > 0 {
            note = "\(context.system.rollingEventCount) recent runtime event\(context.system.rollingEventCount == 1 ? "" : "s") observed."
        } else {
            note = "No abnormal gateway close is currently recorded."
        }

        return OperationalInsight(
            id: "gateway-stability",
            title: "Gateway stable",
            body: "Gateway, queue, and automation signals are all reading within their normal band.",
            symbol: "checkmark.seal",
            tone: .healthy,
            weight: 8,
            note: note
        )
    }

    private static func commandReliabilityInsight(_ context: OperationalInsightContext) -> OperationalInsight {
        let successRatePercent = Int((context.system.commandSuccessRate * 100).rounded())
        let tone: OperationalInsightTone = context.system.commandSuccessRate >= 0.95 ? .healthy : .warning

        return OperationalInsight(
            id: "command-reliability",
            title: "Command reliability",
            body: "\(successRatePercent)% success across \(context.system.commandsRunLifetime) tracked command run\(context.system.commandsRunLifetime == 1 ? "" : "s").",
            symbol: context.system.commandSuccessRate >= 0.95 ? "checkmark.circle" : "exclamationmark.triangle",
            tone: tone,
            weight: max(1, successRatePercent / 8),
            note: context.system.commandsToday > 0 ? "\(context.system.commandsToday) command\(context.system.commandsToday == 1 ? "" : "s") recorded today." : nil
        )
    }

    private static func automationCadenceInsight(_ context: OperationalInsightContext) -> OperationalInsight? {
        guard context.patchyCycleRunning || context.system.automationRunsToday > 0 else { return nil }

        let body: String
        let tone: OperationalInsightTone
        if context.patchyCycleRunning {
            body = "Patchy is actively processing an automation cycle right now."
            tone = .info
        } else {
            body = "Automation completed \(context.system.automationRunsToday) run\(context.system.automationRunsToday == 1 ? "" : "s") today."
            tone = context.system.failedAutomationCount > 0 ? .warning : .healthy
        }

        let enabledWorkflowCount = context.rules.filter { $0.isEnabled }.count
        let note: String?
        if context.system.failedAutomationCount > 0 {
            note = "\(context.system.failedAutomationCount) automation failure\(context.system.failedAutomationCount == 1 ? "" : "s") need attention."
        } else if context.patchyEnabledTargetCount > 0 {
            note = "\(context.patchyEnabledTargetCount) Patchy target\(context.patchyEnabledTargetCount == 1 ? "" : "s") are enabled."
        } else {
            note = "\(enabledWorkflowCount) workflow\(enabledWorkflowCount == 1 ? "" : "s") currently enabled."
        }

        return OperationalInsight(
            id: "automation-cadence",
            title: "Automation cadence",
            body: body,
            symbol: "wand.and.stars",
            tone: tone,
            weight: max(2, context.system.automationRunsToday + (context.patchyCycleRunning ? 2 : 0)),
            note: note
        )
    }

    private static func currentActiveDayStreak(from dailyActivity: [AnalyticsDaySample]) -> Int {
        var streak = 0
        for day in dailyActivity.reversed() {
            if day.hasActivity {
                streak += 1
            } else {
                break
            }
        }
        return streak
    }

    private static func normalizedCommandName(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Command" }
        if let first = trimmed.split(whereSeparator: \.isWhitespace).first {
            return String(first)
        }
        return trimmed
    }

    private static func actionableBlockCount(in rule: Rule) -> Int {
        let modifierTypes: Set<ActionType> = [.mentionUser, .mentionRole, .disableMention, .sendToChannel, .sendToDM, .replyToTrigger]
        return rule.processedActions.filter { !modifierTypes.contains($0.type) }.count
    }

    private static func weekdayName(for date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide))
    }

    private static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12 AM"
        case 12: return "12 PM"
        case let hourBeforeNoon where hourBeforeNoon < 12: return "\(hourBeforeNoon) AM"
        default: return "\(hour - 12) PM"
        }
    }

    private static func relativeText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}
