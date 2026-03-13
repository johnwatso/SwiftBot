import Foundation
import Combine

/// A BotDataProvider implementation that wraps the local AppModel.
/// This allows the same UI to be used for both local and remote bot instances.
@MainActor
final class LocalBotProvider: ObservableObject, BotDataProvider {
    private let app: AppModel
    private var appChangeCancellable: AnyCancellable?

    nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()

    var changePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    // MARK: - State Properties

    var settings: BotSettings { app.settings }
    var status: BotStatus { app.status }
    var stats: StatCounter { app.stats }
    var events: [ActivityEvent] { app.events }
    var commandLog: [CommandLogEntry] { app.commandLog }
    var voiceLog: [VoiceEventLogEntry] { app.voiceLog }
    var activeVoice: [VoiceMemberPresence] { app.activeVoice }
    var uptime: UptimeInfo? { app.uptime }
    var connectedServers: [String: String] { app.connectedServers }
    var availableVoiceChannelsByServer: [String: [GuildVoiceChannel]] { app.availableVoiceChannelsByServer }
    var availableTextChannelsByServer: [String: [GuildTextChannel]] { app.availableTextChannelsByServer }
    var availableRolesByServer: [String: [GuildRole]] { app.availableRolesByServer }
    var clusterSnapshot: ClusterSnapshot { app.clusterSnapshot }
    var clusterNodes: [ClusterNodeStatus] { app.clusterNodes }
    var rules: [Rule] { app.ruleStore.rules }
    
    // MARK: - Bot Info
    
    var botUsername: String {
        app.botUsername
    }
    
    var botAvatarURL: URL? {
        app.botAvatarURL
    }
    
    // MARK: - Patchy
    
    var patchyLastCycleAt: Date? {
        app.patchyLastCycleAt
    }
    
    var patchyIsCycleRunning: Bool {
        app.patchyIsCycleRunning
    }
    
    var patchyDebugLogs: [String] {
        app.patchyDebugLogs
    }
    
    // MARK: - Initialization
    
    init(app: AppModel) {
        self.app = app
        self.appChangeCancellable = app.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    
    // MARK: - BotDataProvider Methods
    
    func avatarURL(forUserId userId: String, guildId: String?) -> URL? {
        app.avatarURL(forUserId: userId, guildId: guildId)
    }
    
    func fallbackAvatarURL(forUserId userId: String) -> URL? {
        app.fallbackAvatarURL(forUserId: userId)
    }
    
    func refresh() async {
        // Local provider doesn't need explicit refresh - AppModel updates automatically
    }
    
    func saveSettings(_ settings: BotSettings) async throws {
        app.settings = settings
        app.saveSettings()
    }
    
    func startBot() async throws {
        await app.startBot()
    }
    
    func stopBot() async throws {
        await app.stopBot()
    }
    
    // MARK: - Rules
    
    func upsertRule(_ rule: Rule) async throws {
        // Find and update existing rule, or append new one
        if let index = app.ruleStore.rules.firstIndex(where: { $0.id == rule.id }) {
            app.ruleStore.rules[index] = rule
        } else {
            app.ruleStore.rules.append(rule)
        }
        app.ruleStore.scheduleAutoSave()
    }
    
    func deleteRule(_ id: UUID) async throws {
        guard let index = app.ruleStore.rules.firstIndex(where: { $0.id == id }) else { return }
        app.ruleStore.rules.remove(at: index)
        app.ruleStore.scheduleAutoSave()
    }
    
    // MARK: - Patchy
    
    func addPatchyTarget(_ target: PatchySourceTarget) async throws {
        app.addPatchyTarget(target)
    }
    
    func updatePatchyTarget(_ target: PatchySourceTarget) async throws {
        app.updatePatchyTarget(target)
    }
    
    func deletePatchyTarget(_ id: UUID) async throws {
        app.deletePatchyTarget(id)
    }
    
    func togglePatchyTargetEnabled(_ id: UUID) async throws {
        app.togglePatchyTargetEnabled(id)
    }
    
    func sendPatchyTest(targetID: UUID) async throws {
        app.sendPatchyTest(targetID: targetID)
    }
    
    func runPatchyManualCheck() async throws {
        app.runPatchyManualCheck()
    }
}
