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
                        PlaceholderPanelLine(text: "Cluster mode is disabled. Enable Leader or Worker mode to use SwiftMesh.")
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
        app.clusterNodes.filter { $0.status == .healthy }
    }
}

struct ClusterMapView: View {
    let nodes: [ClusterNodeStatus]

    private var connectedNodes: [ClusterNodeStatus] {
        nodes.filter { $0.status == .healthy }
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
            .map { "\($0.id)-\($0.status.rawValue)" }
            .joined(separator: "|")
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(90, min(size.width, size.height) * 0.34)

            ZStack {
                ForEach(Array(workers.enumerated()), id: \.element.id) { index, worker in
                    let workerPosition = positionForWorker(
                        index: index,
                        count: workers.count,
                        center: center,
                        radius: radius
                    )

                    PulseLineView(
                        start: center,
                        end: workerPosition,
                        status: worker.status
                    )

                    ClusterNodeView(node: worker, compact: true)
                        .frame(width: 190)
                        .position(workerPosition)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }

                if let leader {
                    ClusterNodeView(node: leader, compact: true, highlightLeader: true)
                        .frame(width: 210)
                        .position(center)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.52, dampingFraction: 0.82), value: topologyKey)
        }
        .frame(height: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 6)
    }

    private func positionForWorker(index: Int, count: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        guard count > 0 else { return center }
        let angle = (Double(index) / Double(count)) * (2.0 * Double.pi)
        return CGPoint(
            x: center.x + CGFloat(cos(angle)) * radius,
            y: center.y + CGFloat(sin(angle)) * radius
        )
    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: SwiftMeshHardwareIcons.icon(for: node.hardwareModel))
                    .resizable()
                    .scaledToFit()
                    .frame(width: compact ? 42 : 46, height: compact ? 42 : 46)

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
                    nodeMetric(label: "Model", value: node.hardwareModel)
                }
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
}

struct ConnectionLineView: View {
    let start: CGPoint
    let end: CGPoint
    let color: Color

    var body: some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(
            color,
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
        )
    }
}

struct PulseLineView: View {
    let start: CGPoint
    let end: CGPoint
    let status: ClusterNodeHealthStatus

    private var lineColor: Color {
        switch status {
        case .healthy: return .green
        case .degraded: return .yellow
        case .disconnected: return .red
        }
    }

    private var pulseEnabled: Bool {
        status != .disconnected
    }

    var body: some View {
        ZStack {
            ConnectionLineView(
                start: start,
                end: end,
                color: pulseEnabled ? lineColor.opacity(0.42) : Color.secondary.opacity(0.30)
            )

            if pulseEnabled {
                TimelineView(.periodic(from: .now, by: 0.05)) { context in
                    let duration = 1.6
                    let progress = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: duration) / duration

                    Circle()
                        .fill(lineColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: lineColor.opacity(0.45), radius: 5, x: 0, y: 0)
                        .position(point(at: progress))
                }
            }
        }
    }

    private func point(at progress: Double) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }
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
