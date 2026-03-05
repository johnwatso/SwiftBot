import SwiftUI
import AppKit

struct SwiftMeshView: View {
    @EnvironmentObject var app: AppModel

    private let pollingIntervalNanoseconds: UInt64 = 3_000_000_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("SwiftMesh")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Spacer()
                    Text("\(connectedNodeCount) connected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Cluster Map")
                        .font(.headline)

                    if app.settings.clusterMode == .standalone {
                        PlaceholderPanelLine(text: "Cluster mode is disabled. Enable Primary or Worker mode to use SwiftMesh.")
                    } else if topologyNodes.isEmpty {
                        PlaceholderPanelLine(text: "Waiting for /cluster/status ...")
                    } else {
                        ClusterMapView(nodes: topologyNodes)
                    }
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.20), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Node Details")
                        .font(.headline)

                    if app.clusterNodes.isEmpty {
                        PlaceholderPanelLine(text: "No node details yet")
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(app.clusterNodes) { node in
                                NodeDetailCard(node: node)
                            }
                        }
                    }
                }

                SwiftMeshJobDistributionCard(nodes: app.clusterNodes)
            }
            .padding(20)
            .background(SwiftBotGlassBackground().opacity(0.55))
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

struct ClusterMapView: View {
    let nodes: [ClusterNodeStatus]
    private let leaderCardWidth: CGFloat = 210
    private let workerCardWidth: CGFloat = 190
    private let compactCardHeight: CGFloat = 92
    private let mapPadding: CGFloat = 16

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
            let size = proxy.size
            let layout = topologyLayout(in: size)

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

                    ClusterNodeView(node: worker, compact: true)
                        .frame(width: workerCardWidth)
                        .position(workerPosition)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }

                if let leader {
                    ClusterNodeView(node: leader, compact: true, highlightLeader: true)
                        .frame(width: leaderCardWidth)
                        .position(layout.leaderPosition)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.52, dampingFraction: 0.82), value: topologyKey)
        }
        .frame(height: mapHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 6)
    }

    private func topologyLayout(in size: CGSize) -> ClusterTopologyLayout {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        guard !workers.isEmpty else {
            return ClusterTopologyLayout(leaderPosition: center, workerPositions: [])
        }

        // Two-node topology: keep leader above worker to make direction obvious.
        if workers.count == 1 {
            let desiredSeparation = max(170, compactCardHeight * 1.9)
            let maxHalfShift = max(
                0,
                (size.height / 2) - (compactCardHeight / 2) - mapPadding
            )
            let halfShift = min(desiredSeparation / 2, maxHalfShift)
            return ClusterTopologyLayout(
                leaderPosition: CGPoint(x: center.x, y: center.y - halfShift),
                workerPositions: [CGPoint(x: center.x, y: center.y + halfShift)]
            )
        }

        // Three or more nodes: circular worker placement around centered leader.
        let radius = circularLayoutRadius(for: size, workerCount: workers.count)
        let points = (0..<workers.count).map { index -> CGPoint in
            let angle = (Double(index) / Double(workers.count)) * (2.0 * Double.pi) - (Double.pi / 2)
            return CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            )
        }
        return ClusterTopologyLayout(leaderPosition: center, workerPositions: points)
    }

    private func circularLayoutRadius(for size: CGSize, workerCount: Int) -> CGFloat {
        let baseRadius: CGFloat = 160
        let minLeaderClearance = ((leaderCardWidth + workerCardWidth) / 2) + 20
        let minByNeighborSpacing: CGFloat
        if workerCount > 1 {
            let minChord = workerCardWidth + 24
            minByNeighborSpacing = minChord / (2 * CGFloat(sin(.pi / Double(workerCount))))
        } else {
            minByNeighborSpacing = 0
        }
        let desired = max(baseRadius, minLeaderClearance, minByNeighborSpacing)

        let maxRadiusX = max(80, (size.width / 2) - (workerCardWidth / 2) - mapPadding)
        let maxRadiusY = max(80, (size.height / 2) - (compactCardHeight / 2) - mapPadding)
        let maxAllowed = min(maxRadiusX, maxRadiusY)
        return min(desired, maxAllowed)
    }

    private var mapHeight: CGFloat {
        let workerCount = workers.count
        if workerCount <= 2 { return 460 }
        if workerCount <= 4 { return 520 }
        if workerCount <= 6 { return 600 }
        return 680
    }
}

private struct ClusterTopologyLayout {
    let leaderPosition: CGPoint
    let workerPositions: [CGPoint]
}

struct ClusterNodeView: View {
    let node: ClusterNodeStatus
    var compact: Bool = false
    var highlightLeader: Bool = false

    private var statusColor: Color {
        switch node.status {
        case .healthy: return .green
        case .degraded: return .yellow
        case .disconnected: return .red
        }
    }
}

extension ClusterNodeView {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: SwiftMeshHardwareIcons.icon(for: node.hardwareModel))
                    .resizable()
                    .scaledToFit()
                    .frame(width: compact ? 42 : 46, height: compact ? 42 : 46)
                    .padding(4)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        Circle()
                            .stroke(iconRingColor, lineWidth: compact ? 2.2 : 2.8)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.displayName)
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                        .lineLimit(1)
                    Text(node.hostname)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(node.role.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((highlightLeader ? Color.cyan : Color.white).opacity(0.16), in: Capsule())
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(node.status.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            if !compact {
                Divider()

                HStack {
                    nodeMetric(label: "CPU", value: "\(Int(node.cpu.rounded()))%")
                    nodeMetric(label: "Memory", value: "\(Int(node.mem.rounded()))%")
                    nodeMetric(label: "Uptime", value: formatUptime(node.uptime))
                }

                HStack {
                    nodeMetric(label: "Latency", value: latencyValue)
                    nodeMetric(label: "Jobs", value: "\(node.jobsActive)")
                    nodeMetric(label: "RAM", value: formatMemoryCapacity(node.physicalMemoryBytes))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU: \(node.cpuName)")
                    Text("Model: \(node.hardwareModel)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 6)
    }

    private var latencyValue: String {
        guard node.role == .worker else { return "--" }
        guard let latencyMs = node.latencyMs else { return "--" }
        return "\(Int(latencyMs.rounded())) ms"
    }

    private var iconRingColor: Color {
        switch node.status {
        case .healthy:
            if let latency = node.latencyMs, latency >= 140 {
                return .yellow
            }
            return node.jobsActive > 0 ? .green : .gray
        case .degraded:
            return .yellow
        case .disconnected:
            return .red
        }
    }

    private func nodeMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatUptime(_ uptime: TimeInterval) -> String {
        let total = max(0, Int(uptime))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func formatMemoryCapacity(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "--" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytes))
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

    private var pulseStep: Double {
        0.035
    }

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
                .stroke(
                    pulseEnabled ? lineColor.opacity(activeJobs > 0 ? 0.62 : 0.5) : lineColor.opacity(0.5),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
                )

            if pulseEnabled {
                TimelineView(.periodic(from: .now, by: pulseStep)) { context in
                    let progress = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: pulseDuration) / pulseDuration

                    Circle()
                        .fill(lineColor)
                        .frame(width: activeJobs > 0 ? 8 : 7, height: activeJobs > 0 ? 8 : 7)
                        .shadow(color: lineColor.opacity(0.45), radius: 5, x: 0, y: 0)
                        .position(point(at: progress))
                }
            }

            Text(latencyLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.86))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
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

struct NodeDetailCard: View {
    let node: ClusterNodeStatus

    var body: some View {
        ClusterNodeView(node: node)
            .opacity(node.status == .disconnected ? 0.58 : 1.0)
    }
}

private struct SwiftMeshJobDistributionCard: View {
    let nodes: [ClusterNodeStatus]

    private var totalJobs: Int {
        nodes.reduce(0) { $0 + max(0, $1.jobsActive) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Job Distribution")
                .font(.headline)

            if nodes.isEmpty {
                PlaceholderPanelLine(text: "No nodes available")
            } else if totalJobs == 0 {
                PlaceholderPanelLine(text: "No active jobs reported")
            } else {
                ForEach(nodes.sorted(by: { $0.jobsActive > $1.jobsActive })) { node in
                    let share = Double(node.jobsActive) / Double(max(1, totalJobs))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(node.displayName)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(node.jobsActive) jobs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(barColor(for: node.status).opacity(0.72))
                                    .frame(width: proxy.size.width * share)
                            }
                        }
                        .frame(height: 8)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)
    }

    private func barColor(for status: ClusterNodeHealthStatus) -> Color {
        switch status {
        case .healthy: return .green
        case .degraded: return .yellow
        case .disconnected: return .red
        }
    }
}

enum SwiftMeshHardwareIcons {
    private static let coreTypesBundle = Bundle(path: "/System/Library/CoreServices/CoreTypes.bundle")

    static func icon(for hardwareModel: String) -> NSImage {
        let normalized = normalizeHardwareModel(hardwareModel)
        let iconName: NSImage.Name

        if normalized.hasPrefix("macmini") {
            iconName = NSImage.macminiName
        } else if normalized.hasPrefix("macbookair") {
            iconName = NSImage.macbookAirName
        } else if normalized.hasPrefix("macbookpro") {
            iconName = NSImage.macbookProName
        } else if normalized.hasPrefix("macpro") {
            iconName = NSImage.macProName
        } else if normalized.hasPrefix("mac") {
            iconName = NSImage.macStudioName
        } else {
            iconName = NSImage.computerName
        }

        if let image = coreTypesBundle?.image(forResource: iconName) {
            return image
        }
        if let image = NSImage(named: iconName) {
            return image
        }
        if let fallback = NSImage(named: NSImage.computerName) {
            return fallback
        }

        return NSImage(size: NSSize(width: 46, height: 46))
    }

    private static func normalizeHardwareModel(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private extension NSImage {
    static let macminiName = NSImage.Name("com.apple.macmini")
    static let macbookAirName = NSImage.Name("com.apple.macbookair")
    static let macbookProName = NSImage.Name("com.apple.macbookpro-15")
    static let macProName = NSImage.Name("com.apple.macpro")
    static let macStudioName = NSImage.Name("com.apple.macstudio")
}
