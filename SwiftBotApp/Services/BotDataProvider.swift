import Foundation
import SwiftUI
import Combine

/// A protocol that abstracts the data source for the SwiftBot dashboard.
/// This allows the same UI to be used for both local and remote bot instances.
@MainActor
protocol BotDataProvider: ObservableObject {
    var changePublisher: AnyPublisher<Void, Never> { get }

    // MARK: - State Properties
    
    var settings: BotSettings { get }
    var status: BotStatus { get }
    var stats: StatCounter { get }
    var events: [ActivityEvent] { get }
    var commandLog: [CommandLogEntry] { get }
    var voiceLog: [VoiceEventLogEntry] { get }
    var activeVoice: [VoiceMemberPresence] { get }
    var uptime: UptimeInfo? { get }
    var connectedServers: [String: String] { get }
    var availableVoiceChannelsByServer: [String: [GuildVoiceChannel]] { get }
    var availableTextChannelsByServer: [String: [GuildTextChannel]] { get }
    var availableRolesByServer: [String: [GuildRole]] { get }
    var clusterSnapshot: ClusterSnapshot { get }
    var clusterNodes: [ClusterNodeStatus] { get }
    
    // MARK: - Bot Info
    
    var botUsername: String { get }
    var botAvatarURL: URL? { get }
    func avatarURL(forUserId userId: String, guildId: String?) -> URL?
    func fallbackAvatarURL(forUserId userId: String) -> URL?
    
    // MARK: - Rules
    
    var rules: [Rule] { get }
    func upsertRule(_ rule: Rule) async throws
    func deleteRule(_ id: UUID) async throws
    
    // MARK: - Patchy
    
    var patchyLastCycleAt: Date? { get }
    var patchyIsCycleRunning: Bool { get }
    var patchyDebugLogs: [String] { get }
    func addPatchyTarget(_ target: PatchySourceTarget) async throws
    func updatePatchyTarget(_ target: PatchySourceTarget) async throws
    func deletePatchyTarget(_ id: UUID) async throws
    func togglePatchyTargetEnabled(_ id: UUID) async throws
    func sendPatchyTest(targetID: UUID) async throws
    func runPatchyManualCheck() async throws
    
    // MARK: - Lifecycle & Actions
    
    func refresh() async
    func saveSettings(_ settings: BotSettings) async throws
    func startBot() async throws
    func stopBot() async throws
}

// MARK: - Type-Erased Wrapper

/// A type-erased wrapper for BotDataProvider that can be used with @EnvironmentObject.
/// This solves the "type 'any BotDataProvider' cannot conform to 'ObservableObject'" issue.
@MainActor
final class AnyBotDataProvider: ObservableObject, BotDataProvider {
    private let _base: any BotDataProvider
    private var changeCancellable: AnyCancellable?

    nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()
    
    // MARK: - BotDataProvider Properties (forwarded)
    
    var settings: BotSettings { _base.settings }
    var status: BotStatus { _base.status }
    var stats: StatCounter { _base.stats }
    var events: [ActivityEvent] { _base.events }
    var commandLog: [CommandLogEntry] { _base.commandLog }
    var voiceLog: [VoiceEventLogEntry] { _base.voiceLog }
    var activeVoice: [VoiceMemberPresence] { _base.activeVoice }
    var uptime: UptimeInfo? { _base.uptime }
    var connectedServers: [String: String] { _base.connectedServers }
    var availableVoiceChannelsByServer: [String: [GuildVoiceChannel]] { _base.availableVoiceChannelsByServer }
    var availableTextChannelsByServer: [String: [GuildTextChannel]] { _base.availableTextChannelsByServer }
    var availableRolesByServer: [String: [GuildRole]] { _base.availableRolesByServer }
    var clusterSnapshot: ClusterSnapshot { _base.clusterSnapshot }
    var clusterNodes: [ClusterNodeStatus] { _base.clusterNodes }
    var botUsername: String { _base.botUsername }
    var botAvatarURL: URL? { _base.botAvatarURL }
    var rules: [Rule] { _base.rules }
    var patchyLastCycleAt: Date? { _base.patchyLastCycleAt }
    var patchyIsCycleRunning: Bool { _base.patchyIsCycleRunning }
    var patchyDebugLogs: [String] { _base.patchyDebugLogs }
    var changePublisher: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }
    
    // MARK: - Initialization
    
    init(_ base: any BotDataProvider) {
        self._base = base
        self.changeCancellable = base.changePublisher.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }
    
    // MARK: - BotDataProvider Methods (forwarded)
    
    func avatarURL(forUserId userId: String, guildId: String?) -> URL? {
        _base.avatarURL(forUserId: userId, guildId: guildId)
    }
    
    func fallbackAvatarURL(forUserId userId: String) -> URL? {
        _base.fallbackAvatarURL(forUserId: userId)
    }
    
    func upsertRule(_ rule: Rule) async throws {
        try await _base.upsertRule(rule)
    }
    
    func deleteRule(_ id: UUID) async throws {
        try await _base.deleteRule(id)
    }
    
    func addPatchyTarget(_ target: PatchySourceTarget) async throws {
        try await _base.addPatchyTarget(target)
    }
    
    func updatePatchyTarget(_ target: PatchySourceTarget) async throws {
        try await _base.updatePatchyTarget(target)
    }
    
    func deletePatchyTarget(_ id: UUID) async throws {
        try await _base.deletePatchyTarget(id)
    }
    
    func togglePatchyTargetEnabled(_ id: UUID) async throws {
        try await _base.togglePatchyTargetEnabled(id)
    }
    
    func sendPatchyTest(targetID: UUID) async throws {
        try await _base.sendPatchyTest(targetID: targetID)
    }
    
    func runPatchyManualCheck() async throws {
        try await _base.runPatchyManualCheck()
    }
    
    func refresh() async {
        await _base.refresh()
    }
    
    func saveSettings(_ settings: BotSettings) async throws {
        try await _base.saveSettings(settings)
    }
    
    func startBot() async throws {
        try await _base.startBot()
    }
    
    func stopBot() async throws {
        try await _base.stopBot()
    }
}
