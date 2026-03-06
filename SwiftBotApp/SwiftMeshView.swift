import SwiftUI

struct SwiftMeshView: View {
    @EnvironmentObject var app: AppModel

    private let pollingIntervalNanoseconds: UInt64 = 3_000_000_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SwiftMesh")
                        .font(.title2.weight(.semibold))
                    Text("\(connectedNodeCount) connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                SwiftMeshSection(title: "Cluster Map", symbol: "point.3.connected.trianglepath.dotted") {
                    if app.settings.clusterMode == .standalone {
                        PlaceholderPanelLine(text: "Cluster mode is disabled. Enable Primary or Fail Over mode to use SwiftMesh.")
                    } else if topologyNodes.isEmpty {
                        PlaceholderPanelLine(text: "Waiting for /cluster/status ...")
                    } else {
                        ClusterMapView(nodes: topologyNodes)
                    }
                }

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

                SwiftMeshSection(title: "Cluster Metrics", symbol: "square.grid.2x2") {
                    SwiftMeshMetricsGrid(nodes: app.clusterNodes)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
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

                    HeartbeatConnectionView(
                        start: layout.leaderPosition,
                        end: workerPosition,
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
                .fill(Color.primary.opacity(node.status == .disconnected ? 0.02 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
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

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }
}

struct HeartbeatConnectionView: View {
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

    private var pulseEnabled: Bool {
        status != .disconnected
    }

    private var pulseDuration: Double {
        activeJobs > 0 ? 2.2 : 3.2
    }

    private let pulseStep: Double = 0.035

    private var latencyLabel: String {
        guard let latencyMs else { return "--" }
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
                .stroke(lineColor.opacity(activeJobs > 0 ? 0.45 : 0.34), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            if pulseEnabled {
                TimelineView(.periodic(from: .now, by: pulseStep)) { context in
                    let progress = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: pulseDuration) / pulseDuration

                    Circle()
                        .fill(lineColor)
                        .frame(width: activeJobs > 0 ? 6 : 5, height: activeJobs > 0 ? 6 : 5)
                        .position(point(at: progress))
                }
            }

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

    private var midpoint: CGPoint {
        CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }

    private func point(at progress: Double) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
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
