import SwiftUI

struct SwiftMeshView: View {
    @EnvironmentObject var app: AppModel
    @State private var showPromoteConfirm = false

    private let pollingIntervalNanoseconds: UInt64 = 3_000_000_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                // Phase 4: manual promote + auto-reclaim countdown.
                if app.clusterSnapshot.mode == .standby {
                    PromoteToPrimaryPanel(
                        countdownSeconds: app.autoReclaimRemainingSeconds,
                        onPromote: { showPromoteConfirm = true }
                    )
                }

                metricTileRow

                if app.settings.clusterMode == .standalone {
                    SwiftMeshSection(title: "Cluster Map", symbol: "point.3.connected.trianglepath.dotted") {
                        PlaceholderPanelLine(text: "Cluster mode is disabled. Enable Primary or Fail Over mode to use SwiftMesh.")
                    }
                } else {
                    SwiftMeshSection(title: "Cluster Map", symbol: "point.3.connected.trianglepath.dotted") {
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
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
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
                Text("SwiftMesh")
                    .font(.title2.weight(.semibold))
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            DashboardMetricCard(
                title: "Mode",
                value: tileMode,
                subtitle: tileModeSubtitle,
                symbol: tileModeSymbol,
                color: .accentColor
            )
            DashboardMetricCard(
                title: "Leader Term",
                value: "\(app.clusterSnapshot.leaderTerm)",
                subtitle: app.clusterSnapshot.lastJobRoute.rawValue.capitalized,
                symbol: "number.square",
                color: .blue
            )
            DashboardMetricCard(
                title: "Connected",
                value: "\(connectedNodeCount)",
                subtitle: "\(app.clusterNodes.filter { $0.status == .healthy }.count) healthy · \(app.clusterNodes.filter { $0.status == .disconnected }.count) offline",
                symbol: "point.3.connected.trianglepath.dotted",
                color: .green
            )
            DashboardMetricCard(
                title: "Active Jobs",
                value: "\(app.clusterNodes.reduce(0) { $0 + max(0, $1.jobsActive) })",
                subtitle: app.registeredWorkersDebugCount > 0
                    ? "\(app.registeredWorkersDebugCount) registered"
                    : "No registered workers",
                symbol: "chart.bar.fill",
                color: .indigo
            )
            DashboardMetricCard(
                title: "Avg Latency",
                value: averageLatencyDisplay,
                subtitle: latencyRangeSubtitle,
                symbol: "speedometer",
                color: latencyTone
            )
            DashboardMetricCard(
                title: "Auto-Reclaim",
                value: autoReclaimDisplay,
                subtitle: autoReclaimSubtitle,
                symbol: "arrow.uturn.up.circle",
                color: app.autoReclaimRemainingSeconds != nil ? .purple : .gray
            )
            DashboardMetricCard(
                title: "Gateway Δ",
                value: gatewayDeltaDisplay,
                subtitle: gatewayDeltaSubtitle,
                symbol: "bolt.horizontal",
                color: gatewayDeltaTone
            )
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
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
            DiagnosticsLine(label: "Node Name", value: app.settings.clusterNodeName, tone: .primary)
            DiagnosticsLine(label: "Listen Port", value: "\(app.settings.clusterListenPort)", tone: .primary)
            DiagnosticsLine(label: "Primary Host", value: primaryHostDisplay, tone: .primary)
            DiagnosticsLine(label: "Primary Port", value: "\(app.settings.clusterLeaderPort)", tone: .primary)
            DiagnosticsLine(label: "Configured Role", value: app.settings.clusterMode.displayName, tone: .primary)
            DiagnosticsLine(label: "Runtime Role", value: app.clusterSnapshot.mode.displayName, tone: .primary)
            DiagnosticsLine(label: "Registered Workers", value: app.registeredWorkersDebugSummary, tone: .secondary, multiline: true)
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
private struct DiagnosticsLine: View {
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

private struct SwiftMeshSection<Content: View>: View {
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
    let nodes: [ClusterNodeStatus]
    private let leaderCardWidth: CGFloat = 182
    private let workerCardWidth: CGFloat = 170
    private let compactCardHeight: CGFloat = 68
    private let mapPadding: CGFloat = 14

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
        connectedNodes
            .sorted(by: { $0.id < $1.id })
            .map { "\($0.id)-\($0.status.rawValue)-\($0.jobsActive)-\($0.latencyMs ?? -1)" }
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

                    ClusterMapNodeChip(node: worker)
                        .frame(width: workerCardWidth)
                        .position(workerPosition)
                }

                if let leader {
                    ClusterMapNodeChip(node: leader, showLeaderSymbol: true)
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
        let leaderInset: CGFloat = 8
        let workerInset: CGFloat = 8
        let start = CGPoint(
            x: leaderCenter.x + (leaderCardWidth / 2) - leaderInset,
            y: leaderCenter.y
        )
        let end = CGPoint(
            x: workerCenter.x - (workerCardWidth / 2) + workerInset,
            y: workerCenter.y
        )
        return (start, end)
    }

    private var mapHeight: CGFloat {
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

private struct ClusterMapNodeChip: View {
    let node: ClusterNodeStatus
    var showLeaderSymbol: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: SwiftMeshHardwareSymbols.symbolName(for: node.hardwareModel))
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(node.displayName)
                        .font(.subheadline.weight(.semibold))
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
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(node.status == .disconnected ? 0.07 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .opacity(node.status == .disconnected ? 0.7 : 1.0)
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
    let node: ClusterNodeStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: SwiftMeshHardwareSymbols.symbolName(for: node.hardwareModel))
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

            Spacer()

            if node.role == .worker, let latency = node.latencyMs {
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

    private var statusColor: Color {
        switch node.status {
        case .healthy: return .green
        case .degraded: return .yellow
        case .disconnected: return .red
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

/// Replaces the previous `HeartbeatConnectionView`. Same visual layout (single
/// stroke between leader and worker, latency capsule at the midpoint) but no
/// timeline-driven pulse animation — the line is a flat color reflecting the
/// connection's health state.
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

    private var latencyLabel: String? {
        guard let latencyMs else { return nil }
        return "\(Int(latencyMs.rounded()))ms"
    }

    private var visualState: ConnectionVisualState {
        if status == .disconnected { return .disconnected }
        if status == .degraded { return .highLatency }
        if let latencyMs, latencyMs >= 140 { return .highLatency }
        if activeJobs <= 0 { return .idle }
        return .healthy
    }

    var body: some View {
        ZStack {
            ClusterConnectionShape(start: start, end: end)
                .stroke(
                    lineColor.opacity(status == .disconnected ? 0.35 : 0.78),
                    style: StrokeStyle(
                        lineWidth: activeJobs > 0 ? 2.5 : 2.0,
                        lineCap: .round,
                        dash: status == .disconnected ? [3, 4] : []
                    )
                )

            if let latencyLabel {
                Text(latencyLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.03), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(lineColor.opacity(0.25), lineWidth: 1)
                    )
                    .position(midpoint)
            }
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
    let countdownSeconds: TimeInterval?
    let onPromote: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
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
            Spacer()
            Button(action: onPromote) {
                Label("Promote to Primary", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
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
    static func symbolName(for hardwareModel: String) -> String {
        let normalized = normalizeHardwareModel(hardwareModel)
        if normalized.hasPrefix("macbook") {
            return "laptopcomputer"
        }
        if normalized.hasPrefix("macmini")
            || normalized.hasPrefix("macstudio")
            || normalized.hasPrefix("macpro")
            || normalized.hasPrefix("imac")
            || normalized.hasPrefix("mac") {
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
