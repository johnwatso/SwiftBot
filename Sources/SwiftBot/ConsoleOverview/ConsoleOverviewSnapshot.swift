import Foundation

/// Everything live on the console Overview, worked out from the runtime's
/// current state. A pure value: built from `Inputs`, no side effects, so the
/// rules for "what counts as healthy" are unit-testable without an AppModel
/// (the same shape as `OverviewHealthReport`).
struct ConsoleOverviewSnapshot: Equatable {
    struct Inputs {
        var botStatus: BotStatus
        var hasToken: Bool
        var botUsername: String
        var connectedServerCount: Int
        var lastGatewayCloseCode: Int?
        var uptimeStartedAt: Date?

        var clusterMode: ClusterMode
        var clusterServerState: ClusterConnectionState
        /// Every node in the mesh, this Mac included.
        var clusterNodeCount: Int
        var clusterUnhealthyNodeCount: Int

        var webEnabled: Bool
        var webListening: Bool
        var webAddress: String

        var tunnelEnabled: Bool
        var tunnelStatus: AdminWebPublicAccessRuntimeStatus
    }

    let host: HostStatus
    let services: [ConsoleServiceStatus]

    init(_ inputs: Inputs) {
        let services = ConsoleServiceKind.allCases.map { Self.status(for: $0, inputs) }
        self.services = services
        self.host = Self.hostStatus(inputs, services: services)
    }

    subscript(kind: ConsoleServiceKind) -> ConsoleServiceStatus? {
        services.first { $0.kind == kind }
    }

    /// "All services healthy", "1 needs attention".
    var servicesSummary: String {
        let troubled = services.filter(\.health.needsAttention).count
        if troubled > 0 { return troubled == 1 ? "1 needs attention" : "\(troubled) need attention" }
        let healthy = services.filter { $0.health == .healthy }.count
        return healthy == services.count ? "All services healthy" : "\(healthy) of \(services.count) running"
    }

    // MARK: - Host

    private static func hostStatus(_ inputs: Inputs, services: [ConsoleServiceStatus]) -> HostStatus {
        let issues = services
            .filter(\.health.needsAttention)
            .sorted { $0.health > $1.health }
        let make = { (health: ServiceHealth, badge: String, headline: String, started: Date?) in
            HostStatus(health: health, badge: badge, headline: headline, startedAt: started, issues: issues)
        }

        guard inputs.hasToken else {
            return make(.warning, "Not Set Up", "Add a Discord bot token to start SwiftBot.", nil)
        }

        switch inputs.botStatus {
        case .stopped:
            return make(.disabled, "Stopped", "SwiftBot is stopped.", nil)
        case .connecting:
            return make(.pending, "Starting", "SwiftBot is connecting to Discord…", nil)
        case .reconnecting:
            return make(.warning, "Reconnecting", "SwiftBot lost its Discord connection and is reconnecting.", inputs.uptimeStartedAt)
        case .running:
            guard let worst = issues.first?.health else {
                let headline = inputs.clusterMode == .standby
                    ? "Running as a Fail Over node, ready to take over."
                    : "SwiftBot is running and connected to Discord."
                return make(.healthy, "Running", headline, inputs.uptimeStartedAt)
            }
            let count = issues.count == 1 ? "1 service needs" : "\(issues.count) services need"
            return make(worst, "Needs Attention", "SwiftBot is running, but \(count) attention.", inputs.uptimeStartedAt)
        }
    }

    // MARK: - Services

    private static func status(for kind: ConsoleServiceKind, _ inputs: Inputs) -> ConsoleServiceStatus {
        switch kind {
        case .discord: return discord(inputs)
        case .webInterface: return webInterface(inputs)
        case .swiftMesh: return swiftMesh(inputs)
        case .cloudflareTunnel: return cloudflareTunnel(inputs)
        }
    }

    private static func discord(_ inputs: Inputs) -> ConsoleServiceStatus {
        let make = { ConsoleServiceStatus(kind: .discord, health: $0, summary: $1, detail: $2) }

        guard inputs.hasToken else {
            return make(.warning, "Not Set Up", "Add a bot token in Settings")
        }
        if let code = inputs.lastGatewayCloseCode,
           ConnectionDiagnostics.isUnrecoverableGatewayCloseCode(code) {
            return make(.error, "Rejected", "Gateway closed (\(code))")
        }

        let servers = inputs.connectedServerCount == 1 ? "1 server" : "\(inputs.connectedServerCount) servers"
        switch inputs.botStatus {
        case .running where inputs.clusterMode == .standby:
            return make(.healthy, "Standing By", "Primary sends messages")
        case .running:
            return make(.healthy, "Connected", "As \(inputs.botUsername) · \(servers)")
        case .connecting:
            return make(.pending, "Connecting…", "Opening gateway")
        case .reconnecting:
            return make(.warning, "Reconnecting…", "Gateway dropped")
        case .stopped:
            return make(.unavailable, "Stopped", "Start to connect")
        }
    }

    private static func webInterface(_ inputs: Inputs) -> ConsoleServiceStatus {
        let make = { ConsoleServiceStatus(kind: .webInterface, health: $0, summary: $1, detail: $2) }

        guard inputs.webEnabled else {
            return make(.disabled, "Disabled", "Turned off")
        }
        guard inputs.webListening else {
            return make(.error, "Not Listening", "Check its address and certificate")
        }
        return make(.healthy, "Running", displayAddress(inputs.webAddress))
    }

    /// "test.swiftbot.dev" or "127.0.0.1:38888": the address without its
    /// scheme, short enough for a quarter-width card.
    private static func displayAddress(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host(), !host.isEmpty else { return address }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private static func swiftMesh(_ inputs: Inputs) -> ConsoleServiceStatus {
        let make = { ConsoleServiceStatus(kind: .swiftMesh, health: $0, summary: $1, detail: $2) }

        guard inputs.clusterMode != .standalone else {
            return make(.disabled, "Standalone", "Not in a mesh")
        }

        let role = inputs.clusterMode.displayName
        let peers = max(0, inputs.clusterNodeCount - 1)
        let peersText = peers == 1 ? "1 peer" : "\(peers) peers"
        switch inputs.clusterServerState {
        case .listening, .connected:
            if inputs.clusterUnhealthyNodeCount > 0 {
                return make(.warning, "Degraded", "\(inputs.clusterUnhealthyNodeCount) of \(peersText) unreachable")
            }
            if peers == 0 {
                return make(.healthy, "Listening", "\(role) · no peers yet")
            }
            return make(.healthy, "Connected", "\(role) · \(peersText)")
        case .starting:
            return make(.pending, "Starting…", role)
        case .degraded:
            return make(.warning, "Degraded", "\(role) · \(peersText)")
        case .failed:
            return make(.error, "Error", "Mesh server failed")
        case .inactive, .stopped:
            return make(.unavailable, "Stopped", "Starts with SwiftBot")
        }
    }

    private static func cloudflareTunnel(_ inputs: Inputs) -> ConsoleServiceStatus {
        let make = { ConsoleServiceStatus(kind: .cloudflareTunnel, health: $0, summary: $1, detail: $2) }

        guard inputs.tunnelEnabled else {
            return make(.disabled, "Disabled", "Local network only")
        }
        guard inputs.webEnabled else {
            return make(.unavailable, "Unavailable", "Needs Web Interface")
        }

        let status = inputs.tunnelStatus
        switch status.state {
        case .enabled:
            let host = URL(string: status.publicURL)?.host() ?? status.publicURL
            return make(.healthy, "Connected", host.isEmpty ? "Public access on" : host)
        case .enabling:
            return make(.pending, "Connecting…", "Starting tunnel")
        case .error:
            return make(.error, "Error", status.detail.isEmpty ? "Tunnel couldn't start" : status.detail)
        case .disabled:
            return make(.warning, "Not Running", "Public access on, tunnel down")
        }
    }
}

// MARK: - AppModel

extension AppModel {
    /// Snapshot of the services the console Overview reports on.
    var consoleOverviewSnapshot: ConsoleOverviewSnapshot {
        ConsoleOverviewSnapshot(.init(
            botStatus: status,
            hasToken: !settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            botUsername: resolvedBotUsername,
            connectedServerCount: connectedServers.count,
            lastGatewayCloseCode: connectionDiagnostics.lastGatewayCloseCode,
            uptimeStartedAt: uptime?.startedAt,
            clusterMode: settings.clusterMode,
            clusterServerState: clusterSnapshot.serverState,
            clusterNodeCount: clusterNodes.count,
            clusterUnhealthyNodeCount: clusterNodes.filter { $0.status != .healthy }.count,
            webEnabled: settings.adminWebUI.enabled,
            webListening: adminWebIsListening,
            webAddress: adminWebBaseURL(),
            tunnelEnabled: settings.adminWebUI.internetAccessEnabled,
            tunnelStatus: adminWebPublicAccessStatus
        ))
    }
}
