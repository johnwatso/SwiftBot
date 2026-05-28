import SwiftUI
import AppKit

struct SwiftMeshView: View {
    @EnvironmentObject var app: AppModel
    @State private var showPromoteConfirm = false
    @State private var showHandoverTestConfirm = false
    @State private var isCopyingJoinCode = false
    @State private var justCopiedJoinCode = false

    /// 10s polling interval for the SwiftMesh UI. The old 3s interval caused
    /// excessive standby-to-primary HTTP load (up to 40 req/min) and overlapping
    /// URLSession requests that contributed to CFNetwork loader-queue races.
    private let pollingIntervalNanoseconds: UInt64 = 10_000_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                // Handover Test panel — Configured Primary only, requires at least
                // one registered worker or an active test.
                if app.settings.clusterMode == .leader && (app.registeredWorkersDebugCount > 0 || app.clusterSnapshot.isHandoverTestActive || app.clusterSnapshot.scheduledHandoverTestAt != nil) {
                    HandoverTestPanel(
                        lastRunAt: app.settings.clusterLastHandoverTestAt,
                        lastRunOK: app.settings.clusterLastHandoverTestOK,
                        onRun: { showHandoverTestConfirm = true }
                    )
                }

                // Phase 4: manual promote + auto-reclaim countdown.
                if app.settings.clusterMode == .standby {
                    PromoteToPrimaryPanel(
                        snapshot: app.clusterSnapshot,
                        countdownSeconds: app.autoReclaimRemainingSeconds,
                        onPromote: { showPromoteConfirm = true }
                    )
                }

                // Failover-side banner: surfaces when the Primary has either
                // scheduled or started a Handover Test. State is mirrored over
                // the mesh sync so this works even when Primary→Standby
                // callbacks fail (NAT).
                if app.settings.clusterMode == .standby,
                   app.clusterSnapshot.isHandoverTestActive || app.clusterSnapshot.scheduledHandoverTestAt != nil {
                    HandoverTestStandbyBanner(
                        isActive: app.clusterSnapshot.isHandoverTestActive,
                        scheduledAt: app.clusterSnapshot.scheduledHandoverTestAt,
                        endsAt: app.clusterSnapshot.handoverTestEndsAt
                    )
                }

                metricTileRow

                if app.settings.clusterMode == .standalone {
                    SwiftMeshSection(title: "Cluster Map", symbol: "point.3.connected.trianglepath.dotted") {
                        PlaceholderPanelLine(text: "Cluster mode is disabled. Enable Primary or Fail Over mode to use SwiftMesh.")
                    }
                } else {
                    SwiftMeshSection(title: "Cluster Map", symbol: "point.3.connected.trianglepath.dotted") {
                        if app.clusterSnapshot.isHandoverTestActive || app.clusterSnapshot.scheduledHandoverTestAt != nil {
                            ClusterMapHandoverNotice(
                                isActive: app.clusterSnapshot.isHandoverTestActive,
                                scheduledAt: app.clusterSnapshot.scheduledHandoverTestAt,
                                endsAt: app.clusterSnapshot.handoverTestEndsAt
                            )
                        }
                        if topologyNodes.isEmpty {
                            PlaceholderPanelLine(text: "Waiting for /cluster/status ...")
                        } else {
                            ClusterMapView(nodes: topologyNodes)
                        }
                    }

                    diagnosticsAndJobsRow

                    SwiftMeshSection(title: "Nodes", symbol: "cpu") {
                        if app.clusterNodes.isEmpty {
                            PlaceholderPanelLine(text: "No nodes available")
                        } else {
                            VStack(spacing: 8) {
                                ForEach(app.clusterNodes) { node in
                                    ClusterNodeRow(node: node)
                                }
                            }
                        }
                    }

                    // Phase 3: follower activity surfaced from primary's poll.
                    if !app.clusterSnapshot.followerStates.isEmpty {
                        SwiftMeshSection(title: "Follower Activity", symbol: "dot.radiowaves.left.and.right") {
                            VStack(spacing: 8) {
                                ForEach(
                                    app.clusterSnapshot.followerStates
                                        .sorted(by: { $0.value.nodeName < $1.value.nodeName }),
                                    id: \.key
                                ) { _, state in
                                    FollowerActivityRow(state: state)
                                }
                            }
                        }
                    }

                    SwiftMeshSection(title: "Configuration & Replication", symbol: "gearshape.2") {
                        configurationGrid
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, 16)
            .fadingEdges(top: 16, bottom: 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Promote this node to Primary?",
            isPresented: $showPromoteConfirm,
            titleVisibility: .visible
        ) {
            Button("Promote", role: .destructive) {
                Task { await app.manuallyPromoteToPrimary() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current Primary will demote on its next sync. This may briefly interrupt Discord activity while roles change.")
        }
        .confirmationDialog(
            "Run SwiftMesh Handover Test?",
            isPresented: $showHandoverTestConfirm,
            titleVisibility: .visible
        ) {
            Button("Run Test", role: .destructive) {
                Task { await app.runSwiftMeshHandoverTest() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Failover will take over as Primary for 60 seconds, then signal this node to reclaim automatically. Discord activity may briefly bounce between nodes during the swap.")
        }
        .task(id: app.settings.clusterMode) {
            guard app.settings.clusterMode != .standalone else {
                app.clusterNodes = []
                return
            }

            while !Task.isCancelled {
                await app.pollClusterStatus()
                try? await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
            }
        }
    }

    private var connectedNodeCount: Int {
        topologyNodes.count
    }

    private var topologyNodes: [ClusterNodeStatus] {
        app.clusterNodes
    }

    // MARK: - Dashboard sub-views

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                ViewSectionHeader(title: "SwiftMesh", symbol: "point.3.filled.connected.trianglepath.dotted")
                HStack(spacing: 6) {
                    Circle()
                        .fill(headerStatusColor)
                        .frame(width: 7, height: 7)
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ModeBadge(mode: app.clusterSnapshot.mode)
        }
    }

    private var headerSubtitle: String {
        let cs = app.clusterSnapshot
        if app.settings.clusterMode == .standalone { return "Standalone — no mesh" }
        let count = connectedNodeCount
        let healthy = app.clusterNodes.filter { $0.status == .healthy }.count
        let connectedSummary = count == 0 ? "No nodes" : "\(healthy)/\(count) healthy"
        return "\(connectedSummary) · Term \(cs.leaderTerm) · \(cs.workerStatusText)"
    }

    private var headerStatusColor: Color {
        let cs = app.clusterSnapshot
        if app.settings.clusterMode == .standalone { return .gray }
        switch cs.workerState {
        case .connected, .listening: return .green
        case .starting: return .yellow
        case .degraded: return .orange
        case .failed, .stopped, .inactive: return .red
        }
    }

    private var metricTileRow: some View {
        LazyVGrid(columns: DashboardMetricGrid.columns, spacing: DashboardMetricGrid.spacing) {
            ForEach(SwiftMeshDashboardSummary.metrics(app: app)) { metric in
                DashboardMetricCard(metric: metric)
            }
        }
    }

    // MARK: - Gateway delta

    /// Local node's most-recent Discord heartbeat→ACK round-trip in ms.
    private var localGatewayLatencyMs: Int? {
        app.connectionDiagnostics.heartbeatLatencyMs
    }

    /// Worst (largest) Discord latency reported by any follower in the most
    /// recent poll. Returns nil if no follower has reported a latency yet.
    private var worstFollowerGatewayLatencyMs: Int? {
        app.clusterSnapshot.followerStates.values
            .compactMap { $0.discordGatewayLatencyMs }
            .max()
    }

    private var gatewayDeltaDisplay: String {
        guard let local = localGatewayLatencyMs else { return "—" }
        guard let follower = worstFollowerGatewayLatencyMs else { return "Solo" }
        return "\(abs(local - follower)) ms"
    }

    private var gatewayDeltaSubtitle: String {
        guard let local = localGatewayLatencyMs else { return "No local heartbeat" }
        guard let follower = worstFollowerGatewayLatencyMs else {
            return "Local \(local) ms · no follower"
        }
        return "Local \(local) ms · worst peer \(follower) ms"
    }

    /// Delta tone: green if <40 ms drift, yellow if <120, red beyond. Gray when
    /// we don't have both sides yet.
    private var gatewayDeltaTone: Color {
        guard let local = localGatewayLatencyMs,
              let follower = worstFollowerGatewayLatencyMs else { return .gray }
        let delta = abs(local - follower)
        if delta >= 120 { return .red }
        if delta >= 40 { return .orange }
        return .green
    }

    private var diagnosticsAndJobsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            SwiftMeshSection(title: "Diagnostics", symbol: "stethoscope") {
                VStack(alignment: .leading, spacing: 6) {
                    DiagnosticsLine(label: "Server", value: app.clusterSnapshot.serverStatusText, tone: tone(for: app.clusterSnapshot.serverState))
                    DiagnosticsLine(label: "Worker", value: app.clusterSnapshot.workerStatusText, tone: tone(for: app.clusterSnapshot.workerState))
                    DiagnosticsLine(label: "Status", value: app.clusterSnapshot.diagnostics, tone: .secondary, multiline: true)
                }
            }

            SwiftMeshSection(title: "Last Job", symbol: "shippingbox") {
                VStack(alignment: .leading, spacing: 6) {
                    DiagnosticsLine(label: "Route", value: app.clusterSnapshot.lastJobRoute.rawValue.capitalized, tone: .primary)
                    DiagnosticsLine(label: "Node", value: app.clusterSnapshot.lastJobNode, tone: .primary)
                    DiagnosticsLine(label: "Summary", value: app.clusterSnapshot.lastJobSummary, tone: .secondary, multiline: true)
                }
            }
        }
    }

    private var configurationGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                DiagnosticsLine(label: "Node Name", value: app.settings.clusterNodeName, tone: .primary)
                DiagnosticsLine(label: "Listen Port", value: "\(app.settings.clusterListenPort)", tone: .primary)
                DiagnosticsLine(label: "Primary Host", value: primaryHostDisplay, tone: .primary)
                DiagnosticsLine(label: "Primary Port", value: "\(app.settings.clusterLeaderPort)", tone: .primary)
                DiagnosticsLine(label: "Configured Role", value: app.settings.clusterMode.displayName, tone: .primary)
                DiagnosticsLine(label: "Runtime Role", value: app.clusterSnapshot.mode.displayName, tone: .primary)
                DiagnosticsLine(label: "Registered Workers", value: app.registeredWorkersDebugSummary, tone: .secondary, multiline: true)
            }

            if app.settings.clusterMode == .leader {
                Button {
                    isCopyingJoinCode = true
                    Task {
                        if let code = await app.generateSwiftMeshJoinCode() {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            app.logs.append("[SwiftMesh] Join code copied to clipboard!")
                            justCopiedJoinCode = true
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            justCopiedJoinCode = false
                        }
                        isCopyingJoinCode = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isCopyingJoinCode {
                            ProgressView().controlSize(.small)
                            Text("Generating Join Code...")
                        } else if justCopiedJoinCode {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Join Code Copied!")
                        } else {
                            Image(systemName: "doc.on.clipboard.fill")
                            Text("Copy SwiftMesh Join Code")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
                .disabled(isCopyingJoinCode)
                .help("Generates and copies a single pairing code containing this Primary's address and shared secret for standbys to paste.")
            }
        }
    }

    // MARK: - Tile values

    private var tileMode: String {
        app.settings.clusterMode == .standalone
            ? "Standalone"
            : app.clusterSnapshot.mode.displayName
    }

    private var tileModeSubtitle: String {
        let configured = app.settings.clusterMode.displayName
        let runtime = app.clusterSnapshot.mode.displayName
        return configured == runtime ? "Configured \(configured)" : "Configured \(configured) · Runtime \(runtime)"
    }

    private var tileModeSymbol: String {
        switch app.clusterSnapshot.mode {
        case .leader: return "crown.fill"
        case .standby: return "shield.lefthalf.filled"
        case .worker: return "cpu"
        case .standalone: return "circle"
        }
    }

    private var averageLatencyDisplay: String {
        let latencies = app.clusterNodes.compactMap { $0.latencyMs }
        guard !latencies.isEmpty else { return "—" }
        return "\(Int((latencies.reduce(0, +) / Double(latencies.count)).rounded())) ms"
    }

    private var latencyRangeSubtitle: String {
        let latencies = app.clusterNodes.compactMap { $0.latencyMs }
        guard let lo = latencies.min(), let hi = latencies.max() else { return "No samples" }
        return "min \(Int(lo.rounded())) · max \(Int(hi.rounded())) ms"
    }

    private var latencyTone: Color {
        let latencies = app.clusterNodes.compactMap { $0.latencyMs }
        guard let max = latencies.max() else { return .gray }
        if max >= 200 { return .red }
        if max >= 140 { return .orange }
        return .teal
    }

    private var autoReclaimDisplay: String {
        if let secs = app.autoReclaimRemainingSeconds, secs > 0 {
            return formatHM(secs)
        }
        return app.settings.clusterAutoReclaimAfterHours > 0 ? "Armed" : "Off"
    }

    private var autoReclaimSubtitle: String {
        let hours = app.settings.clusterAutoReclaimAfterHours
        if hours <= 0 { return "Disabled in Settings" }
        if app.autoReclaimRemainingSeconds != nil { return "Until reclaim" }
        if app.settings.clusterMode == .leader && app.clusterSnapshot.mode == .standby {
            return "Awaiting stable window"
        }
        return "After \(hours)h healthy"
    }

    private var primaryHostDisplay: String {
        let addr = app.settings.clusterLeaderAddress
        return addr.isEmpty ? "—" : addr
    }

    private func tone(for state: ClusterConnectionState) -> Color {
        switch state {
        case .connected, .listening: return .green
        case .starting: return .yellow
        case .degraded: return .orange
        case .failed: return .red
        case .stopped, .inactive: return .secondary
        }
    }

    private func formatHM(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }
}

/// Small status badge shown in the SwiftMesh header.
private struct ModeBadge: View {
    let mode: ClusterMode

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(mode.displayName.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(color)
        )
    }

    private var symbol: String {
        switch mode {
        case .leader: return "crown.fill"
        case .standby: return "shield.lefthalf.filled"
        case .worker: return "cpu"
        case .standalone: return "circle"
        }
    }

    private var color: Color {
        switch mode {
        case .leader: return .green
        case .standby: return .orange
        case .worker: return .blue
        case .standalone: return .gray
        }
    }
}

/// Two-column label/value row used inside SwiftMesh dashboard panels.
struct DiagnosticsLine: View {
    let label: String
    let value: String
    let tone: Color
    var multiline: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.caption)
                .foregroundStyle(tone)
                .lineLimit(multiline ? 4 : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

enum SwiftMeshDashboardSummary {
    @MainActor
    static func metrics(app: AppModel) -> [DashboardMetricDescriptor] {
        let connectedNodeCount = app.clusterNodes.count
        let healthyCount = app.clusterNodes.filter { $0.status == .healthy }.count
        let offlineCount = app.clusterNodes.filter { $0.status == .disconnected }.count
        let activeJobs = app.clusterNodes.reduce(0) { $0 + max(0, $1.jobsActive) }

        return [
            DashboardMetricDescriptor(
                id: "meshMode",
                title: "SwiftMesh",
                value: tileMode(app: app),
                subtitle: tileModeSubtitle(app: app),
                symbol: tileModeSymbol(app: app),
                detail: app.clusterSnapshot.serverStatusText,
                color: .accentColor
            ),
            DashboardMetricDescriptor(
                id: "mesh-leader-term",
                title: "Leader Term",
                value: "\(app.clusterSnapshot.leaderTerm)",
                subtitle: app.clusterSnapshot.lastJobRoute.rawValue.capitalized,
                symbol: "number.square",
                color: .blue
            ),
            DashboardMetricDescriptor(
                id: "mesh-connected",
                title: "Connected",
                value: "\(connectedNodeCount)",
                subtitle: "\(healthyCount) healthy · \(offlineCount) offline",
                symbol: "point.3.connected.trianglepath.dotted",
                color: .green
            ),
            DashboardMetricDescriptor(
                id: "mesh-active-jobs",
                title: "Active Jobs",
                value: "\(activeJobs)",
                subtitle: app.registeredWorkersDebugCount > 0
                    ? "\(app.registeredWorkersDebugCount) registered"
                    : "No registered workers",
                symbol: "chart.bar.fill",
                color: .indigo
            ),
            DashboardMetricDescriptor(
                id: "mesh-latency",
                title: "Avg Latency",
                value: averageLatencyDisplay(app: app),
                subtitle: latencyRangeSubtitle(app: app),
                symbol: "speedometer",
                color: latencyTone(app: app)
            ),
            DashboardMetricDescriptor(
                id: "mesh-auto-reclaim",
                title: "Auto-Reclaim",
                value: autoReclaimDisplay(app: app),
                subtitle: autoReclaimSubtitle(app: app),
                symbol: "arrow.uturn.up.circle",
                color: app.autoReclaimRemainingSeconds != nil ? .purple : .gray
            ),
            DashboardMetricDescriptor(
                id: "mesh-gateway-delta",
                title: "Gateway Δ",
                value: gatewayDeltaDisplay(app: app),
                subtitle: gatewayDeltaSubtitle(app: app),
                symbol: "bolt.horizontal",
                color: gatewayDeltaTone(app: app)
            )
        ]
    }

    @MainActor
    private static func tileMode(app: AppModel) -> String {
        app.settings.clusterMode == .standalone
            ? "Standalone"
            : app.clusterSnapshot.mode.displayName
    }

    @MainActor
    private static func tileModeSubtitle(app: AppModel) -> String {
        let configured = app.settings.clusterMode.displayName
        let runtime = app.clusterSnapshot.mode.displayName
        return configured == runtime ? "Configured \(configured)" : "Configured \(configured) · Runtime \(runtime)"
    }

    @MainActor
    private static func tileModeSymbol(app: AppModel) -> String {
        switch app.clusterSnapshot.mode {
        case .leader: return "crown.fill"
        case .standby: return "shield.lefthalf.filled"
        case .worker: return "cpu"
        case .standalone: return "circle"
        }
    }

    @MainActor
    private static func averageLatencyDisplay(app: AppModel) -> String {
        let latencies = app.clusterNodes.compactMap { $0.latencyMs }
        guard !latencies.isEmpty else { return "-" }
        return "\(Int((latencies.reduce(0, +) / Double(latencies.count)).rounded())) ms"
    }

    @MainActor
    private static func latencyRangeSubtitle(app: AppModel) -> String {
        let latencies = app.clusterNodes.compactMap { $0.latencyMs }
        guard let lo = latencies.min(), let hi = latencies.max() else { return "No samples" }
        return "min \(Int(lo.rounded())) · max \(Int(hi.rounded())) ms"
    }

    @MainActor
    private static func latencyTone(app: AppModel) -> Color {
        let latencies = app.clusterNodes.compactMap { $0.latencyMs }
        guard let max = latencies.max() else { return .gray }
        if max >= 200 { return .red }
        if max >= 140 { return .orange }
        return .teal
    }

    @MainActor
    private static func autoReclaimDisplay(app: AppModel) -> String {
        if let secs = app.autoReclaimRemainingSeconds, secs > 0 {
            return formatHM(secs)
        }
        return app.settings.clusterAutoReclaimAfterHours > 0 ? "Armed" : "Off"
    }

    @MainActor
    private static func autoReclaimSubtitle(app: AppModel) -> String {
        let hours = app.settings.clusterAutoReclaimAfterHours
        if hours <= 0 { return "Disabled in Settings" }
        if app.autoReclaimRemainingSeconds != nil { return "Until reclaim" }
        if app.settings.clusterMode == .leader && app.clusterSnapshot.mode == .standby {
            return "Awaiting stable window"
        }
        return "After \(hours)h healthy"
    }

    @MainActor
    private static func gatewayDeltaDisplay(app: AppModel) -> String {
        guard let local = app.connectionDiagnostics.heartbeatLatencyMs else { return "-" }
        guard let follower = app.clusterSnapshot.followerStates.values.compactMap(\.discordGatewayLatencyMs).max() else { return "Solo" }
        return "\(abs(local - follower)) ms"
    }

    @MainActor
    private static func gatewayDeltaSubtitle(app: AppModel) -> String {
        guard let local = app.connectionDiagnostics.heartbeatLatencyMs else { return "No local heartbeat" }
        guard let follower = app.clusterSnapshot.followerStates.values.compactMap(\.discordGatewayLatencyMs).max() else {
            return "Local \(local) ms · no follower"
        }
        return "Local \(local) ms · worst peer \(follower) ms"
    }

    @MainActor
    private static func gatewayDeltaTone(app: AppModel) -> Color {
        guard let local = app.connectionDiagnostics.heartbeatLatencyMs,
              let follower = app.clusterSnapshot.followerStates.values.compactMap(\.discordGatewayLatencyMs).max()
        else { return .gray }
        let delta = abs(local - follower)
        if delta >= 300 { return .red }
        if delta >= 150 { return .orange }
        return .teal
    }

    private static func formatHM(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

struct SwiftMeshSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline.weight(.semibold))
            }

            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.03), radius: 2, x: 0, y: 1)
    }
}

struct ClusterMapView: View {
    enum Presentation {
        case dashboard
        case overview
    }

    @EnvironmentObject var app: AppModel
    let nodes: [ClusterNodeStatus]
    var presentation: Presentation = .dashboard

    private func makeIconSelector(for displayName: String) -> (String?) -> Void {
        { newSymbol in
            if let symbol = newSymbol {
                app.settings.clusterNodeIconOverrides[displayName] = symbol
            } else {
                app.settings.clusterNodeIconOverrides.removeValue(forKey: displayName)
            }
            app.saveSettings()
        }
    }

    /// Returns a forget closure only when the row is safe to evict —
    /// disconnected, and not the local node (forgetting yourself just causes
    /// the entry to reappear on the next localNodeStatus tick).
    private func makeForgetAction(for node: ClusterNodeStatus) -> (() -> Void)? {
        guard node.status == .disconnected else { return nil }
        let localName = app.settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localName.isEmpty, node.displayName.caseInsensitiveCompare(localName) == .orderedSame {
            return nil
        }
        let displayName = node.displayName
        return {
            Task { await app.forgetClusterNode(displayName: displayName) }
        }
    }

    private var leaderCardWidth: CGFloat {
        presentation == .overview ? 150 : 182
    }

    private var workerCardWidth: CGFloat {
        presentation == .overview ? 142 : 170
    }

    private var compactCardHeight: CGFloat {
        presentation == .overview ? 48 : 68
    }

    private var mapPadding: CGFloat {
        presentation == .overview ? 10 : 14
    }

    private var connectedNodes: [ClusterNodeStatus] {
        nodes
    }

    private var leader: ClusterNodeStatus? {
        connectedNodes.first(where: { $0.role == .leader }) ?? connectedNodes.first
    }

    private var workers: [ClusterNodeStatus] {
        guard let leader else { return [] }
        return connectedNodes.filter { $0.id != leader.id }
    }

    private var topologyKey: String {
        // Only encode *structural* identity. Including volatile fields like
        // latency/jobsActive made the `.animation(value:)` fire every second,
        // which constantly rebuilt the cluster map and dismissed any open
        // contextMenu before the user could interact with it.
        connectedNodes
            .sorted(by: { $0.id < $1.id })
            .map { "\($0.id)-\($0.status.rawValue)" }
            .joined(separator: "|")
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = topologyLayout(in: proxy.size)

            ZStack {
                ForEach(Array(workers.enumerated()), id: \.element.id) { index, worker in
                    let workerPosition = layout.workerPositions[index]
                    let endpoints = connectionEndpoints(
                        leaderCenter: layout.leaderPosition,
                        workerCenter: workerPosition
                    )

                    StaticConnectionView(
                        start: endpoints.start,
                        end: endpoints.end,
                        status: worker.status,
                        activeJobs: worker.jobsActive,
                        latencyMs: worker.latencyMs
                    )

                    let workerForget = makeForgetAction(for: worker)
                    ClusterMapNodeChip(
                        node: worker,
                        iconOverride: app.settings.clusterNodeIconOverrides[worker.displayName],
                        onIconSelect: makeIconSelector(for: worker.displayName),
                        canForget: workerForget != nil,
                        onForget: workerForget,
                        presentation: presentation
                    )
                    .equatable()
                    .frame(width: workerCardWidth)
                    .position(workerPosition)
                }

                if let leader {
                    let leaderForget = makeForgetAction(for: leader)
                    ClusterMapNodeChip(
                        node: leader,
                        iconOverride: app.settings.clusterNodeIconOverrides[leader.displayName],
                        onIconSelect: makeIconSelector(for: leader.displayName),
                        canForget: leaderForget != nil,
                        onForget: leaderForget,
                        showLeaderSymbol: true,
                        presentation: presentation
                    )
                    .equatable()
                    .frame(width: leaderCardWidth)
                    .position(layout.leaderPosition)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: topologyKey)
        }
        .frame(height: mapHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func topologyLayout(in size: CGSize) -> ClusterTopologyLayout {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        guard !workers.isEmpty else {
            return ClusterTopologyLayout(leaderPosition: center, workerPositions: [])
        }

        // Left-to-right topology:
        // - Primary is fixed on the left side
        // - Workers are distributed vertically on the right side
        // - Connection lines branch from primary toward workers
        let leaderX = mapPadding + (leaderCardWidth / 2)
        let workerX = size.width - mapPadding - (workerCardWidth / 2)
        let leaderPosition = CGPoint(x: leaderX, y: center.y)

        let topY = mapPadding + (compactCardHeight / 2)
        let bottomY = size.height - mapPadding - (compactCardHeight / 2)

        let workerPositions: [CGPoint]
        if workers.count == 1 {
            workerPositions = [CGPoint(x: workerX, y: center.y)]
        } else {
            let span = max(0, bottomY - topY)
            let step = span / CGFloat(max(1, workers.count - 1))
            workerPositions = (0..<workers.count).map { index in
                CGPoint(x: workerX, y: topY + (CGFloat(index) * step))
            }
        }

        return ClusterTopologyLayout(
            leaderPosition: leaderPosition,
            workerPositions: workerPositions
        )
    }

    private func connectionEndpoints(leaderCenter: CGPoint, workerCenter: CGPoint) -> (start: CGPoint, end: CGPoint) {
        // Start the line just *outside* each tile so a straight stroke doesn't
        // visibly clip through the rounded-rect node chips. The original
        // negative inset hid behind the waveform's bouncing path; with the
        // line straight, even 8 px inside the tile clips badly.
        let gap: CGFloat = 4
        let start = CGPoint(
            x: leaderCenter.x + (leaderCardWidth / 2) + gap,
            y: leaderCenter.y
        )
        let end = CGPoint(
            x: workerCenter.x - (workerCardWidth / 2) - gap,
            y: workerCenter.y
        )
        return (start, end)
    }

    private var mapHeight: CGFloat {
        if presentation == .overview {
            let workerCount = workers.count
            if workerCount <= 2 { return 118 }
            if workerCount <= 4 { return 148 }
            return 178
        }

        let workerCount = workers.count
        if workerCount <= 2 { return 280 }
        if workerCount <= 4 { return 340 }
        if workerCount <= 6 { return 400 }
        return 470
    }
}

private struct ClusterTopologyLayout {
    let leaderPosition: CGPoint
    let workerPositions: [CGPoint]
}

@MainActor
private struct ClusterMapNodeChip: View, Equatable {
    let node: ClusterNodeStatus
    let iconOverride: String?
    let onIconSelect: (String?) -> Void
    var canForget: Bool = false
    /// Non-nil iff the parent decides the node is forgettable (disconnected
    /// and not the local node). Closures aren't comparable so we surface
    /// presence via a sibling `canForget` flag inside `==`.
    var onForget: (() -> Void)? = nil
    var showLeaderSymbol: Bool = false
    var presentation: ClusterMapView.Presentation = .dashboard

    // Equality excludes onIconSelect (closures aren't comparable) and any
    // volatile fields like latency. SwiftUI's `.equatable()` will skip body
    // re-evaluation whenever the user-visible state hasn't changed, which
    // prevents the contextMenu from being dismissed by background ticks.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.node.displayName == rhs.node.displayName &&
        lhs.node.status == rhs.node.status &&
        lhs.node.role == rhs.node.role &&
        lhs.node.hardwareModel == rhs.node.hardwareModel &&
        lhs.iconOverride == rhs.iconOverride &&
        lhs.canForget == rhs.canForget &&
        lhs.showLeaderSymbol == rhs.showLeaderSymbol &&
        lhs.presentation == rhs.presentation
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: SwiftMeshHardwareSymbols.symbolName(
                for: node.hardwareModel,
                override: iconOverride
            ))
                .font(presentation == .overview ? .subheadline : .headline)
                .foregroundStyle(.secondary)
                .frame(width: presentation == .overview ? 15 : 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(node.displayName)
                        .font((presentation == .overview ? Font.caption : Font.subheadline).weight(.semibold))
                        .lineLimit(1)
                    if showLeaderSymbol {
                        Image(systemName: "crown.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(node.status.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, presentation == .overview ? 7 : 9)
        .padding(.vertical, presentation == .overview ? 5 : 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(node.status == .disconnected ? 0.07 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .opacity(node.status == .disconnected ? 0.7 : 1.0)
        .contextMenu {
            NodeIconContextMenu(current: iconOverride, onSelect: onIconSelect)
            if let onForget {
                Divider()
                Button(role: .destructive, action: onForget) {
                    Label("Forget Node", systemImage: "trash")
                }
            }
        }
    }

    private var statusColor: Color {
        switch node.status {
        case .healthy: return .green
        case .degraded: return .yellow
        case .disconnected: return .red
        }
    }
}

private struct ClusterNodeRow: View {
    @EnvironmentObject var app: AppModel
    let node: ClusterNodeStatus

    /// Mirrors `ClusterMapView.makeForgetAction` — Forget is only offered for
    /// disconnected, non-self entries. Closures are captured by value so the
    /// row shell's Equatable shortcut can detect "Forget is/isn't available"
    /// without comparing closure identity.
    private var forgetAction: (() -> Void)? {
        guard node.status == .disconnected else { return nil }
        let localName = app.settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localName.isEmpty, node.displayName.caseInsensitiveCompare(localName) == .orderedSame {
            return nil
        }
        let displayName = node.displayName
        let appRef = app
        return {
            Task { await appRef.forgetClusterNode(displayName: displayName) }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Stable shell: hosts the contextMenu and excludes volatile data
            // (latency). SwiftUI skips its body re-eval on cluster ticks so the
            // "Set Icon" menu stays open while the user navigates it.
            let forgetActionRef = forgetAction
            ClusterNodeRowShell(
                node: node,
                iconOverride: app.settings.clusterNodeIconOverrides[node.displayName],
                onIconSelect: { newSymbol in
                    if let symbol = newSymbol {
                        app.settings.clusterNodeIconOverrides[node.displayName] = symbol
                    } else {
                        app.settings.clusterNodeIconOverrides.removeValue(forKey: node.displayName)
                    }
                    app.saveSettings()
                },
                canForget: forgetActionRef != nil,
                onForget: forgetActionRef
            )
            .equatable()

            Spacer()

            if node.role != .leader, let latency = node.latencyMs {
                Text("\(Int(latency.rounded())) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .opacity(node.status == .disconnected ? 0.64 : 1.0)
    }
}

/// Equatable shell holding the identity-stable part of a Nodes-table row
/// (icon, name, status badge). The contextMenu attaches here, so cluster-tick
/// changes to volatile data like latency don't dismiss an open "Set Icon"
/// menu.
@MainActor
private struct ClusterNodeRowShell: View, Equatable {
    let node: ClusterNodeStatus
    let iconOverride: String?
    let onIconSelect: (String?) -> Void
    var canForget: Bool = false
    var onForget: (() -> Void)? = nil

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.node.displayName == rhs.node.displayName &&
        lhs.node.status == rhs.node.status &&
        lhs.node.role == rhs.node.role &&
        lhs.node.hardwareModel == rhs.node.hardwareModel &&
        lhs.node.hostname == rhs.node.hostname &&
        lhs.iconOverride == rhs.iconOverride &&
        lhs.canForget == rhs.canForget
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: SwiftMeshHardwareSymbols.symbolName(
                for: node.hardwareModel,
                override: iconOverride
            ))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.displayName)
                        .font(.subheadline.weight(.semibold))
                    if node.role == .leader {
                        Label("Primary", systemImage: "crown.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(node.status.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(node.hostname)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contextMenu {
            NodeIconContextMenu(current: iconOverride, onSelect: onIconSelect)
            if let onForget {
                Divider()
                Button(role: .destructive, action: onForget) {
                    Label("Forget Node", systemImage: "trash")
                }
            }
        }
    }

    private var statusColor: Color {
        switch node.status {
        case .healthy: return .green
        case .degraded: return .yellow
        case .disconnected: return .red
        }
    }
}

/// Shared "Set Icon" submenu used by both the cluster-map chip and the
/// Nodes-table row's contextual menu.
///
/// Takes static snapshot inputs (`current` + `onSelect`) rather than reading
/// `@EnvironmentObject` directly. SwiftUI's `.contextMenu` dismisses whenever
/// its containing view body re-evaluates; observing live state inside the menu
/// body caused the menu to vanish on every cluster status tick before the user
/// could click "Set Icon".
@MainActor
private struct NodeIconContextMenu: View {
    let current: String?
    let onSelect: (String?) -> Void

    var body: some View {
        Section("Set Icon") {
            ForEach(SwiftMeshNodeIconCatalog.all) { option in
                Button {
                    onSelect(option.symbol)
                } label: {
                    if current == option.symbol {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Label(option.label, systemImage: option.symbol)
                    }
                }
            }
        }
        if current != nil {
            Button("Reset Icon to Auto-detect") {
                onSelect(nil)
            }
        }
    }
}

struct ClusterConnectionShape: Shape {
    let start: CGPoint
    let end: CGPoint

    static func waveformPoints(start: CGPoint, end: CGPoint) -> [CGPoint] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(1, hypot(dx, dy))
        let amplitude = min(10, max(4.5, length * 0.05))

        // Use screen-space vertical offsets so peaks always point upward.
        func point(_ t: CGFloat, _ upOffset: CGFloat = 0) -> CGPoint {
            CGPoint(
                x: start.x + dx * t,
                y: start.y + dy * t - upOffset
            )
        }

        return [
            point(0),
            point(0.14),
            point(0.19, amplitude * 0.18),
            point(0.22, amplitude * 0.82),
            point(0.25, amplitude * 0.30),
            point(0.33),
            point(0.47),
            point(0.52, amplitude * 0.22),
            point(0.55, amplitude),
            point(0.58, amplitude * 0.36),
            point(0.66),
            point(0.76),
            point(0.80, amplitude * 0.16),
            point(0.83, amplitude * 0.72),
            point(0.86, amplitude * 0.28),
            point(0.91),
            point(1)
        ]
    }

    static func point(at t: CGFloat, start: CGPoint, end: CGPoint) -> CGPoint {
        let points = waveformPoints(start: start, end: end)
        guard points.count > 1 else { return start }
        let clamped = max(0, min(1, t))
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return start }

        var remaining = clamped * total
        for (idx, segLen) in lengths.enumerated() {
            if remaining <= segLen || idx == lengths.count - 1 {
                let a = points[idx]
                let b = points[idx + 1]
                let ratio = segLen > 0 ? (remaining / segLen) : 0
                return CGPoint(
                    x: a.x + (b.x - a.x) * ratio,
                    y: a.y + (b.y - a.y) * ratio
                )
            }
            remaining -= segLen
        }
        return end
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = Self.waveformPoints(start: start, end: end)
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }
}

/// Straight line between leader and worker with a `personalhotspot` SF Symbol
/// chip at the midpoint. Color and icon variant indicate connection state:
/// green hotspot when healthy, yellow when degraded, red `personalhotspot.slash`
/// when disconnected. Replaces the prior heartbeat / waveform styling.
struct StaticConnectionView: View {
    let start: CGPoint
    let end: CGPoint
    let status: ClusterNodeHealthStatus
    let activeJobs: Int
    let latencyMs: Double?

    private var lineColor: Color {
        switch visualState {
        case .healthy: return .green
        case .highLatency: return .yellow
        case .disconnected: return .red
        case .idle: return .gray
        }
    }

    private var iconSymbol: String {
        // Visual cue per state. `personalhotspot.slash` cleanly reads as
        // "no connection"; `personalhotspot` reads as "linked / live".
        switch visualState {
        case .disconnected: return "personalhotspot.slash"
        default: return "personalhotspot"
        }
    }

    private var latencyLabel: String? {
        guard let latencyMs else { return nil }
        return "\(Int(latencyMs.rounded())) ms"
    }

    private var visualState: ConnectionVisualState {
        if status == .disconnected { return .disconnected }
        if status == .degraded { return .highLatency }
        if let latencyMs, latencyMs >= 140 { return .highLatency }
        // A healthy link is green even when there are no active jobs — the icon
        // reflects connection health, not job activity. (Previously dropped to
        // a grey "idle" state, which made the only-healthy path look ambiguous
        // compared to other status indicators in the UI.)
        return .healthy
    }

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(
                lineColor.opacity(status == .disconnected ? 0.35 : 0.55),
                style: StrokeStyle(
                    lineWidth: 1.5,
                    lineCap: .round,
                    dash: status == .disconnected ? [4, 4] : []
                )
            )

            // Hotspot chip at the midpoint. Sits above the line so it's the
            // primary signal for the connection's state. Monochrome rendering
            // mode forces `foregroundStyle` to win over the symbol's default
            // multicolor palette — without it `personalhotspot` renders flat
            // grey in some macOS versions.
            VStack(spacing: 2) {
                Image(systemName: iconSymbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(lineColor)
                if let latencyLabel {
                    Text(latencyLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                Capsule()
                    .stroke(lineColor.opacity(0.45), lineWidth: 1)
            )
            .position(midpoint)
        }
    }

    private var midpoint: CGPoint {
        CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }
}

private enum ConnectionVisualState {
    case healthy
    case highLatency
    case disconnected
    case idle
}

private struct SwiftMeshMetricsGrid: View {
    let nodes: [ClusterNodeStatus]

    private var healthyCount: Int {
        nodes.filter { $0.status == .healthy }.count
    }

    private var degradedCount: Int {
        nodes.filter { $0.status == .degraded }.count
    }

    private var disconnectedCount: Int {
        nodes.filter { $0.status == .disconnected }.count
    }

    private var totalJobs: Int {
        nodes.reduce(0) { $0 + max(0, $1.jobsActive) }
    }

    private var avgLatency: String {
        let latencies = nodes.compactMap { $0.latencyMs }
        guard !latencies.isEmpty else { return "--" }
        let average = latencies.reduce(0, +) / Double(latencies.count)
        return "\(Int(average.rounded())) ms"
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
            MetricTile(title: "Nodes", value: "\(nodes.count)", symbol: "point.3.connected.trianglepath.dotted")
            MetricTile(title: "Healthy", value: "\(healthyCount)", symbol: "checkmark.circle")
            MetricTile(title: "Degraded", value: "\(degradedCount)", symbol: "exclamationmark.triangle")
            MetricTile(title: "Offline", value: "\(disconnectedCount)", symbol: "xmark.circle")
            MetricTile(title: "Active Jobs", value: "\(totalJobs)", symbol: "chart.bar")
            MetricTile(title: "Avg Latency", value: avgLatency, symbol: "speedometer")
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.headline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// Phase 4: header panel for runtime-standby nodes — shows the auto-reclaim
// countdown (if eligible) and exposes a manual Promote button.
struct PromoteToPrimaryPanel: View {
    let snapshot: ClusterSnapshot
    let countdownSeconds: TimeInterval?
    let onPromote: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if snapshot.isHandoverTestActive {
                    handoverStatusRow
                    handoverDetailText
                } else {
                    normalStandbyContent
                }
            }
            Spacer()
            
            promoteButton
        }
        .padding(12)
        .background(panelBackground)
        .overlay(panelStroke)
    }

    @ViewBuilder
    private var handoverStatusRow: some View {
        let title = snapshot.mode == .leader ? "ACTING AS PRIMARY" : "Handover Test in Progress"
        let color: Color = snapshot.mode == .leader ? .green : .orange
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private var handoverDetailText: some View {
        if let endsAt = snapshot.handoverTestEndsAt {
            HStack(spacing: 0) {
                Text(snapshot.mode == .leader
                     ? "Test active. Demoting in "
                     : "Primary has demoted. Reclaiming in ")
                HandoverCountdownText(endsAt: endsAt)
                Text(".")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text("This node is acting as Primary for the duration of the test.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var normalStandbyContent: some View {
        Text("Currently running as Failover (Standby)")
            .font(.subheadline.weight(.semibold))
        if let secs = countdownSeconds, secs > 0 {
            Text("Auto-reclaim Primary in \(formatCountdown(secs))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Auto-reclaim disabled. Promote manually any time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var promoteButton: some View {
        if !snapshot.isHandoverTestActive {
            Button(action: onPromote) {
                Label("Promote to Primary", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    private var panelBackground: some View {
        let color: Color = if snapshot.isHandoverTestActive {
            snapshot.mode == .leader ? .green : .orange
        } else {
            .accentColor
        }
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(color.opacity(0.08))
    }

    private var panelStroke: some View {
        let color: Color = if snapshot.isHandoverTestActive {
            snapshot.mode == .leader ? .green : .orange
        } else {
            .accentColor
        }
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(color.opacity(0.2), lineWidth: 1)
    }

    private func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let mins = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        if mins > 0 { return "\(mins)m" }
        return "<1m"
    }
}

/// Trigger panel for the SwiftMesh end-to-end handover test. Visible on the
/// Primary side when at least one Failover is registered. Surfaces the most
/// recent pass timestamp so an operator can see at a glance whether the
/// failover path has been exercised lately.
struct HandoverTestPanel: View {
    @EnvironmentObject var app: AppModel
    let lastRunAt: Date?
    let lastRunOK: Bool
    let onRun: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                testHeaderRow
                testDetailText
            }
            Spacer()
            
            testActionButton
        }
        .padding(12)
        .background(panelBackground)
        .overlay(panelStroke)
    }

    @ViewBuilder
    private var testHeaderRow: some View {
        HStack(spacing: 6) {
            Image(systemName: statusSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
            Text("Test Failover handover")
                .font(.subheadline.weight(.semibold))

            if app.clusterSnapshot.isHandoverTestActive {
                activeBadge
            } else if app.clusterSnapshot.scheduledHandoverTestAt != nil {
                scheduledBadge
            } else {
                Text(statusLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(statusColor.opacity(0.12)))
            }
        }
    }

    @ViewBuilder
    private var scheduledBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar.badge.clock")
                .font(.caption2.weight(.bold))
            Text("SCHEDULED")
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.orange.opacity(0.12)))
    }

    @ViewBuilder
    private var activeBadge: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text("TEST ACTIVE")
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.orange.opacity(0.12)))
    }

    @ViewBuilder
    private var testDetailText: some View {
        if let endsAt = app.clusterSnapshot.handoverTestEndsAt, app.clusterSnapshot.isHandoverTestActive {
            HStack(spacing: 0) {
                Text("Failover has control. Reclaiming automatically in ")
                HandoverCountdownText(endsAt: endsAt)
                Text(".")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if let scheduledAt = app.clusterSnapshot.scheduledHandoverTestAt {
            HStack(spacing: 0) {
                Text("Starts at \(formattedTime(scheduledAt)) — in ")
                HandoverCountdownText(endsAt: scheduledAt)
                Text(". Failover will be notified on its next sync.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Hands the Primary role to the Failover for 60 s, then auto-reclaims. Failover is notified ~90 s ahead via mesh sync so the test works through NAT.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formattedTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f.string(from: date)
    }

    @ViewBuilder
    private var testActionButton: some View {
        if app.clusterSnapshot.isHandoverTestActive {
            Button(role: .destructive) {
                Task { await app.manuallyPromoteToPrimary() }
            } label: {
                Label("End Test", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        } else if app.clusterSnapshot.scheduledHandoverTestAt != nil {
            Button(role: .destructive) {
                Task { await app.cancelScheduledHandoverTest() }
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        } else {
            Button(action: onRun) {
                Label("Run Handover Test", systemImage: "arrow.left.arrow.right.circle.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(app.clusterSnapshot.isHandoverTestActive ? Color.orange.opacity(0.08) : Color.primary.opacity(0.03))
    }

    private var panelStroke: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(app.clusterSnapshot.isHandoverTestActive ? Color.orange.opacity(0.2) : Color.primary.opacity(0.06), lineWidth: 1)
    }

    private var statusLabel: String {
        guard let lastRunAt else { return "Never run" }
        let prefix = lastRunOK ? "Passed" : "Failed"
        let seconds = max(0, -lastRunAt.timeIntervalSinceNow)
        if seconds < 60 { return "\(prefix) just now" }
        if seconds < 3_600 { return "\(prefix) \(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(prefix) \(Int(seconds / 3_600)) h ago" }
        return "\(prefix) \(Int(seconds / 86_400)) d ago"
    }

    private var statusSymbol: String {
        guard lastRunAt != nil else { return "questionmark.circle.fill" }
        return lastRunOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        guard lastRunAt != nil else { return .secondary }
        return lastRunOK ? .green : .orange
    }
}

// Phase 3: Compact view of one follower's live state polled by the primary.
struct FollowerActivityRow: View {
    let state: FollowerStateSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.gatewayConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(state.nodeName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(state.mode.capitalized)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            HStack(spacing: 14) {
                metric("Term", "\(state.leaderTerm)")
                metric("Output", state.outputAllowed ? "On" : "Muted")
                metric("Voice", "\(state.activeVoiceMembers)")
                if let lat = state.discordGatewayLatencyMs {
                    metric("Gateway", "\(lat) ms")
                }
                Spacer()
                Text(state.collectedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let tail = state.recentLogTail.last, !tail.isEmpty {
                Text(tail)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }
}

enum SwiftMeshHardwareSymbols {
    /// Returns the symbol the user has explicitly chosen for this node, or
    /// the auto-detected fallback if none is configured. Falls back further
    /// to a generic "desktopcomputer" if the override string ever contains
    /// an SF Symbol that doesn't exist on this macOS version (shouldn't
    /// happen given the curated picker, but kept defensive).
    static func symbolName(for hardwareModel: String, override: String? = nil) -> String {
        if let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        let normalized = normalizeHardwareModel(hardwareModel)
        if normalized.hasPrefix("macbook") {
            return "laptopcomputer"
        }
        if normalized.hasPrefix("macstudio") {
            return "macstudio"
        }
        if normalized.hasPrefix("macmini") {
            return "macmini"
        }
        if normalized.hasPrefix("macpro") {
            return "macpro.gen3"
        }
        if normalized.hasPrefix("imac") {
            return "desktopcomputer"
        }
        if normalized.hasPrefix("mac") {
            return "server.rack"
        }
        return "desktopcomputer"
    }

    private static func normalizeHardwareModel(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// Curated catalogue of SF Symbols offered by the SwiftMesh node-icon
/// contextual menu. Each entry pairs a system symbol name with the
/// human-readable label shown in the picker. Order here is the order shown
/// in the menu (laptops → desktops → servers → generic).
enum SwiftMeshNodeIconCatalog {
    struct Option: Identifiable {
        let symbol: String
        let label: String
        var id: String { symbol }
    }

    // Apple Silicon-capable Macs only. Older Intel-only models
    // (Xserve, Mac Pro 2013/trash-can, original cheese grater, white MacBook,
    // 12" Retina MacBook) are deliberately omitted.
    static let all: [Option] = [
        .init(symbol: "laptopcomputer", label: "Laptop"),
        .init(symbol: "macbook", label: "MacBook"),
        .init(symbol: "desktopcomputer", label: "Desktop"),
        .init(symbol: "macmini", label: "Mac mini"),
        .init(symbol: "macstudio", label: "Mac Studio"),
        .init(symbol: "macpro.gen3", label: "Mac Pro"),
        .init(symbol: "server.rack", label: "Server rack")
    ]
}

/// Countdown timer used while a Handover Test is running. SwiftUI's
/// `Text(date, style: .timer)` counts up after the deadline passes, which made
/// the UI read "elapsed" instead of "0" once the test window expired. The
/// `timerInterval`/`pauseTime` initialiser stops at zero. We also clamp the
/// interval so a deadline already in the past renders as "00:00" instead of
/// crashing on an invalid range.
/// Banner shown on a Failover node while the Primary is running a Handover
/// Test. The state arrives via the regular mesh sync tick, so it can be up to
/// ~one sync interval stale on first appearance.
struct HandoverTestStandbyBanner: View {
    let isActive: Bool
    let scheduledAt: Date?
    let endsAt: Date?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(headlineText)
                        .font(.subheadline.weight(.semibold))
                    Text(badgeText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                }
                detailRow
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    private var headlineText: String {
        if isActive { return "Handover Test in progress" }
        return "Handover Test scheduled"
    }

    private var badgeText: String {
        isActive ? "PRIMARY-INITIATED" : "SCHEDULED"
    }

    @ViewBuilder
    private var detailRow: some View {
        if isActive, let endsAt {
            HStack(spacing: 4) {
                Text("Primary auto-reclaims in")
                HandoverCountdownText(endsAt: endsAt)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if !isActive, let scheduledAt {
            HStack(spacing: 4) {
                Text("Starts at \(formattedTime(scheduledAt)) — in")
                HandoverCountdownText(endsAt: scheduledAt)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text("Awaiting signal from Primary.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func formattedTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f.string(from: date)
    }
}

/// Inline notice rendered inside the Cluster Map section while a handover
/// test is scheduled or in progress, so the user knows the role labels and
/// connection states they're seeing are transient — not a real failover or a
/// confused topology.
struct ClusterMapHandoverNotice: View {
    let isActive: Bool
    let scheduledAt: Date?
    let endsAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.caption.weight(.semibold))
                detailLine
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .padding(.bottom, 4)
    }

    private var headline: String {
        isActive ? "Handover Test in progress" : "Handover Test scheduled"
    }

    @ViewBuilder
    private var detailLine: some View {
        if isActive, let endsAt {
            HStack(spacing: 3) {
                Text("Roles are temporarily swapped. Auto-reclaim in")
                Text(endsAt, style: .timer)
            }
        } else if !isActive, let scheduledAt {
            HStack(spacing: 3) {
                Text("Starts in")
                Text(scheduledAt, style: .timer)
                Text("— roles will swap briefly.")
            }
        } else {
            Text("Roles are temporarily swapped during the test.")
        }
    }
}

private struct HandoverCountdownText: View {
    let endsAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let remaining = max(0, Int(endsAt.timeIntervalSince(context.date).rounded(.up)))
            let minutes = remaining / 60
            let seconds = remaining % 60
            Text(String(format: "%02d:%02d", minutes, seconds))
                .monospacedDigit()
        }
    }
}
