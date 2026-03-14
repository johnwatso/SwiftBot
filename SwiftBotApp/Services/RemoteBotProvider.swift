import Foundation
import SwiftUI
import Combine

/// A BotDataProvider implementation that talks to a remote SwiftBot instance via HTTPS.
final class RemoteBotProvider: BotDataProvider {
    @Published private(set) var settings = BotSettings()
    @Published private(set) var status: BotStatus = .stopped
    @Published private(set) var stats = StatCounter()
    @Published private(set) var events: [ActivityEvent] = []
    @Published private(set) var commandLog: [CommandLogEntry] = []
    @Published private(set) var voiceLog: [VoiceEventLogEntry] = []
    @Published private(set) var activeVoice: [VoiceMemberPresence] = []
    @Published private(set) var uptime: UptimeInfo?
    @Published private(set) var connectedServers: [String: String] = [:]
    @Published private(set) var availableVoiceChannelsByServer: [String: [GuildVoiceChannel]] = [:]
    @Published private(set) var availableTextChannelsByServer: [String: [GuildTextChannel]] = [:]
    @Published private(set) var availableRolesByServer: [String: [GuildRole]] = [:]
    @Published private(set) var clusterSnapshot = ClusterSnapshot()
    @Published private(set) var clusterNodes: [ClusterNodeStatus] = []

    @Published private(set) var botUsername: String = "Remote Bot"
    @Published private(set) var botAvatarURL: URL?

    @Published private(set) var rules: [Rule] = []

    @Published private(set) var patchyLastCycleAt: Date?
    @Published private(set) var patchyIsCycleRunning: Bool = false
    @Published private(set) var patchyDebugLogs: [String] = []

    private let api: RemoteAPI
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 8

    var changePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    init(baseURL: String, token: String) throws {
        let configuration = RemoteModeSettings(primaryNodeAddress: baseURL, accessToken: token)
        self.api = try RemoteAPI(configuration: configuration)

        // Start background refresh
        startBackgroundRefresh()
    }

    func avatarURL(forUserId userId: String, guildId: String?) -> URL? {
        // Remote provider doesn't easily have access to all avatar hashes yet, 
        // fallback to standard Discord URLs if possible or return nil
        return nil
    }

    func fallbackAvatarURL(forUserId userId: String) -> URL? {
        guard let numericID = UInt64(userId) else {
            return URL(string: "https://cdn.discordapp.com/embed/avatars/0.png")
        }
        let index = Int(numericID % 6)
        return URL(string: "https://cdn.discordapp.com/embed/avatars/\(index).png")
    }

    func refresh() async {
        do {
            async let statusPayload: RemoteStatusPayload = api.get("/api/remote/status")
            async let rulesPayload: RemoteRulesPayload = api.get("/api/remote/rules")
            async let eventsPayload: RemoteEventsPayload = api.get("/api/remote/events")
            async let configPayload: AdminWebConfigPayload = api.get("/api/remote/settings")

            let s = try await statusPayload
            let r = try await rulesPayload
            let e = try await eventsPayload
            let c = try await configPayload

            await MainActor.run {
                self.updateState(status: s, rules: r, events: e, config: c)
            }
        } catch {
            print("RemoteBotProvider refresh failed: \(error)")
        }
    }

    private func updateState(
        status: RemoteStatusPayload,
        rules: RemoteRulesPayload,
        events: RemoteEventsPayload,
        config: AdminWebConfigPayload
    ) {
        self.botUsername = status.botUsername
        self.status = BotStatus(rawValue: status.botStatus.lowercased()) ?? .stopped

        // Construct partial BotSettings from config payload
        var s = BotSettings()
        s.prefix = config.commands.prefix
        s.commandsEnabled = config.commands.enabled
        s.prefixCommandsEnabled = config.commands.prefixEnabled
        s.slashCommandsEnabled = config.commands.slashEnabled
        s.bugTrackingEnabled = config.commands.bugTrackingEnabled
        s.autoStart = config.general.autoStart

        s.localAIDMReplyEnabled = config.aiBots.localAIDMReplyEnabled
        s.preferredAIProvider = AIProviderPreference(rawValue: config.aiBots.preferredProvider) ?? .apple
        s.openAIEnabled = config.aiBots.openAIEnabled
        s.openAIModel = config.aiBots.openAIModel
        s.openAIImageGenerationEnabled = config.aiBots.openAIImageGenerationEnabled
        s.openAIImageMonthlyLimitPerUser = config.aiBots.openAIImageMonthlyLimitPerUser

        s.clusterMode = ClusterMode(rawValue: config.swiftMesh.mode) ?? .standalone
        s.clusterNodeName = config.swiftMesh.nodeName
        s.clusterLeaderAddress = config.swiftMesh.leaderAddress
        s.clusterListenPort = config.swiftMesh.listenPort
        s.clusterOffloadAIReplies = config.swiftMesh.offloadAIReplies
        s.clusterOffloadWikiLookups = config.swiftMesh.offloadWikiLookups

        s.wikiBot.isEnabled = config.wikiBridge.enabled
        s.patchy.monitoringEnabled = config.patchy.monitoringEnabled

        self.settings = s

        // Update stats
        self.stats.commandsRun = status.gatewayEventCount // Approximation

        // Update rules
        self.rules = rules.rules

        // Update events/logs
        self.events = events.activity.map { ActivityEvent(timestamp: $0.timestamp, kind: parseActivityKind($0.kind), message: $0.message) }
        self.commandLog = [] // Need specific endpoint for this
        self.voiceLog = [] // Need specific endpoint for this

        // Update uptime (use generatedAt as proxy since remote API doesn't provide startedAt yet)
        self.uptime = UptimeInfo(startedAt: Date().addingTimeInterval(-parseUptimeText(status.uptimeText)))

        // Update servers
        self.connectedServers = Dictionary(uniqueKeysWithValues: rules.servers.map { ($0.id, $0.name) })

        // Update channels/roles
        self.availableTextChannelsByServer = rules.textChannelsByServer.mapValues { $0.map { GuildTextChannel(id: $0.id, name: $0.name) } }
        self.availableVoiceChannelsByServer = rules.voiceChannelsByServer.mapValues { $0.map { GuildVoiceChannel(id: $0.id, name: $0.name) } }

        // Cluster info
        self.clusterSnapshot.mode = ClusterMode(rawValue: status.clusterMode) ?? .standalone
    }

    func saveSettings(_ settings: BotSettings) async throws {
        let patch = AdminWebConfigPatch(
            commandsEnabled: settings.commandsEnabled,
            prefixCommandsEnabled: settings.prefixCommandsEnabled,
            slashCommandsEnabled: settings.slashCommandsEnabled,
            bugTrackingEnabled: settings.bugTrackingEnabled,
            prefix: settings.prefix,
            localAIDMReplyEnabled: settings.localAIDMReplyEnabled,
            preferredAIProvider: settings.preferredAIProvider.rawValue,
            openAIEnabled: settings.openAIEnabled,
            openAIModel: settings.openAIModel,
            openAIImageGenerationEnabled: settings.openAIImageGenerationEnabled,
            openAIImageMonthlyLimitPerUser: settings.openAIImageMonthlyLimitPerUser,
            wikiBridgeEnabled: settings.wikiBot.isEnabled,
            patchyMonitoringEnabled: settings.patchy.monitoringEnabled,
            clusterMode: settings.clusterMode.rawValue,
            clusterNodeName: settings.clusterNodeName,
            clusterLeaderAddress: settings.clusterLeaderAddress,
            clusterListenPort: settings.clusterListenPort,
            clusterOffloadAIReplies: settings.clusterOffloadAIReplies,
            clusterOffloadWikiLookups: settings.clusterOffloadWikiLookups,
            autoStart: settings.autoStart
        )
        try await api.post("/api/remote/settings/update", body: patch)
        await refresh()
    }

    func upsertRule(_ rule: Rule) async throws {
        try await api.post("/api/remote/rules/update", body: RemoteRuleUpsertRequest(rule: rule))
        await refresh()
    }

    func deleteRule(_ id: UUID) async throws {
        // Remote API needs a delete endpoint or handle it via upsert with a flag
        // For now, not implemented in RemoteAPI
    }

    func startBot() async throws {
        // Remote API needs a start endpoint
    }

    func stopBot() async throws {
        // Remote API needs a stop endpoint
    }

    func addPatchyTarget(_ target: PatchySourceTarget) async throws {
        try await api.post("/api/patchy/target/upsert", body: AdminWebPatchyTargetPatch(target: target))
        await refresh()
    }

    func updatePatchyTarget(_ target: PatchySourceTarget) async throws {
        try await api.post("/api/patchy/target/upsert", body: AdminWebPatchyTargetPatch(target: target))
        await refresh()
    }

    func deletePatchyTarget(_ id: UUID) async throws {
        try await api.post("/api/patchy/target/delete", body: AdminWebPatchyTargetIDPatch(targetID: id))
        await refresh()
    }

    func togglePatchyTargetEnabled(_ id: UUID) async throws {
        // Find current state to toggle
        guard let target = settings.patchy.sourceTargets.first(where: { $0.id == id }) else { return }
        try await api.post("/api/patchy/target/toggle", body: AdminWebPatchyTargetEnabledPatch(targetID: id, enabled: !target.isEnabled))
        await refresh()
    }

    func sendPatchyTest(targetID: UUID) async throws {
        try await api.post("/api/patchy/target/test", body: AdminWebPatchyTargetIDPatch(targetID: targetID))
        // No refresh needed immediately, logs will follow in background refresh
    }

    func runPatchyManualCheck() async throws {
        try await api.post("/api/patchy/check")
    }

    private func startBackgroundRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }
}

// MARK: - Helpers

private func parseActivityKind(_ kindString: String) -> ActivityEvent.Kind {
    ActivityEvent.Kind(rawValue: kindString) ?? .info
}

private func parseUptimeText(_ text: String?) -> TimeInterval {
    guard let text = text, !text.isEmpty else { return 0 }
    // Parse format like "2h 30m" or "1d 2h 30m" to seconds
    var totalSeconds: TimeInterval = 0
    let components = text.components(separatedBy: " ")
    for component in components {
        if component.hasSuffix("d"), let days = Int(component.dropLast()) {
            totalSeconds += TimeInterval(days * 86400)
        } else if component.hasSuffix("h"), let hours = Int(component.dropLast()) {
            totalSeconds += TimeInterval(hours * 3600)
        } else if component.hasSuffix("m"), let minutes = Int(component.dropLast()) {
            totalSeconds += TimeInterval(minutes * 60)
        } else if component.hasSuffix("s"), let seconds = Int(component.dropLast()) {
            totalSeconds += TimeInterval(seconds)
        }
    }
    return totalSeconds
}

// MARK: - Errors

enum RemoteBotProviderError: Error {
    case missingConfiguration
}
