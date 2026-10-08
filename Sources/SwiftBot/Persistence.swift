import Foundation
import CryptoKit
import RecordingsKit

enum SwiftBotStorage {
    static let appFolderName = "SwiftBot"
    static let settingsFileName = "settings.json"
    static let rulesFileName = "rules.json"
    static let discordCacheFileName = "discord-cache.json"
    static let meshCursorsFileName = "mesh-cursors.json"
    static let swiftMeshConfigFileName = "swiftmesh-config.json"
    static let clusterStateFileName = "cluster_state.json"
    static let mediaLibraryConfigFileName = "media-library.json"
    static let voiceActiveSessionsFileName = "voice-active-sessions.json"
    static let voiceSessionHistoryFileName = "voice-session-history.json"
    static let analyticsRuntimeFileName = "analytics-runtime.json"
    static let gameTrackingStateFileName = "game-tracking-state.json"
    static let communityStatsFileName = "community-stats.json"

    /// The test bundle is hosted by `SwiftBot.app` itself, so without this the
    /// suite reads and writes the same `settings.json`, caches and session
    /// history as the real bot: any test that builds an `AppModel` can, and
    /// did, overwrite a live configuration. Tests get a throwaway directory
    /// per process instead.
    private static let isRunningUnderXCTest: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil

    /// Resolved once so every store in a test process shares one directory —
    /// a fresh directory per call would break anything that writes and then
    /// reads its own state back.
    private static let testFolderURL: URL = {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftBotTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    static func folderURL() -> URL {
        // Screenshot demo mode is kept away from real data the same way.
        if isRunningUnderXCTest || ScreenshotDemo.isEnabled { return testFolderURL }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent(appFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

struct AnalyticsRuntimeSnapshot: Codable {
    var events: [ActivityEvent] = []
    var commandLog: [CommandLogEntry] = []
    var voiceLog: [VoiceEventLogEntry] = []
    var auditLog: [AuditLogEntry] = []
    var patchyLastCycleAt: Date?
    var automationLog: [AutomationLogEntry]?
}

actor AnalyticsRuntimeStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(filename: String = SwiftBotStorage.analyticsRuntimeFileName) {
        let folder = SwiftBotStorage.folderURL()
        self.url = folder.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() -> AnalyticsRuntimeSnapshot {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(AnalyticsRuntimeSnapshot.self, from: data) else {
            return AnalyticsRuntimeSnapshot()
        }
        return snapshot
    }

    func save(_ snapshot: AnalyticsRuntimeSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

actor ConfigStore {
    private let adminDiscordClientSecretAccount = "admin-discord-client-secret"
    private let adminWebCloudflareTokenAccount = "admin-web-cloudflare-token"
    private let adminWebPublicAccessTunnelTokenAccount = "admin-web-public-access-tunnel-token"
    private let adminWebLocalAuthPasswordAccount = "admin-web-local-auth-password"
    private let openAIAPIKeyAccount = "openai-api-key"
    private let swiftMinerAPIKeyAccount = "swiftminer-api-key"
    private let swiftMinerWebhookSecretAccount = "swiftminer-webhook-secret"
    private var lastSwiftMinerAPIKey: String?
    private var lastSwiftMinerWebhookSecret: String?
    /// Pre-multi-provider account name, migrated on first load.
    private let legacyFinalsIDAPITokenAccount = "finals-id-api-token"
    private var lastGameProviderTokens: [GameProviderID: String] = [:]

    private func gameProviderTokenAccount(_ id: GameProviderID) -> String {
        "game-provider-token-\(id.rawValue)"
    }
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastToken: String?
    private var lastAdminWebCloudflareToken: String?
    private var lastAdminWebPublicAccessTunnelToken: String?
    private var lastAdminWebLocalAuthPassword: String?

    init(filename: String = SwiftBotStorage.settingsFileName, folderURL: URL? = nil) {
        let folder = folderURL ?? SwiftBotStorage.folderURL()
        self.url = folder.appendingPathComponent(filename)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? MeshSnapshotDisk.recover(in: folder)
    }

    func load() -> BotSettings {
        try? MeshSnapshotDisk.recover(in: url.deletingLastPathComponent())
        guard let data = try? Data(contentsOf: url),
              var settings = try? decoder.decode(BotSettings.self, from: data)
        else { return BotSettings() }

        // Migration logic:
        // 1. Check if Keychain has a token.
        // 2. If not, and disk settings HAS a token, move it to Keychain and clear from disk.
        // 3. If Keychain HAS a token, ensure disk settings token is empty.

        if let keychainToken = KeychainHelper.loadToken() {
            settings.token = keychainToken
            lastToken = keychainToken
        } else if !settings.token.isEmpty {
            // Found token on disk but not in Keychain - migrate it.
            let tokenToMigrate = settings.token
            if KeychainHelper.saveToken(tokenToMigrate) {
                lastToken = tokenToMigrate
                // Token successfully moved to Keychain.
                // We'll return the settings with the token, but future saves will clear it from disk.
            }
        }

        if let adminSecret = KeychainHelper.load(account: adminDiscordClientSecretAccount) {
            settings.adminWebUI.discordOAuth.clientSecret = adminSecret
        } else if !settings.adminWebUI.discordOAuth.clientSecret.isEmpty {
            let secretToMigrate = settings.adminWebUI.discordOAuth.clientSecret
            if KeychainHelper.save(secretToMigrate, account: adminDiscordClientSecretAccount) {
                settings.adminWebUI.discordOAuth.clientSecret = secretToMigrate
            }
        }

        if let localAuthPassword = KeychainHelper.load(account: adminWebLocalAuthPasswordAccount) {
            settings.adminWebUI.localAuthPassword = localAuthPassword
        } else if !settings.adminWebUI.localAuthPassword.isEmpty {
            let passwordToMigrate = settings.adminWebUI.localAuthPassword
            if KeychainHelper.save(passwordToMigrate, account: adminWebLocalAuthPasswordAccount) {
                settings.adminWebUI.localAuthPassword = passwordToMigrate
            }
        }
        lastAdminWebLocalAuthPassword = settings.adminWebUI.localAuthPassword

        if let cloudflareToken = KeychainHelper.load(account: adminWebCloudflareTokenAccount) {
            settings.adminWebUI.cloudflareAPIToken = cloudflareToken
        } else if !settings.adminWebUI.cloudflareAPIToken.isEmpty {
            let tokenToMigrate = settings.adminWebUI.cloudflareAPIToken
            if KeychainHelper.save(tokenToMigrate, account: adminWebCloudflareTokenAccount) {
                settings.adminWebUI.cloudflareAPIToken = tokenToMigrate
            }
        }
        lastAdminWebCloudflareToken = settings.adminWebUI.cloudflareAPIToken

        if let tunnelToken = KeychainHelper.load(account: adminWebPublicAccessTunnelTokenAccount) {
            settings.adminWebUI.publicAccessTunnelToken = tunnelToken
        } else if !settings.adminWebUI.publicAccessTunnelToken.isEmpty {
            let tokenToMigrate = settings.adminWebUI.publicAccessTunnelToken
            if KeychainHelper.save(tokenToMigrate, account: adminWebPublicAccessTunnelTokenAccount) {
                settings.adminWebUI.publicAccessTunnelToken = tokenToMigrate
            }
        }
        lastAdminWebPublicAccessTunnelToken = settings.adminWebUI.publicAccessTunnelToken

        // One Keychain item per provider. The finals.id item predates the keyed
        // store, so fold it in before reading the per-provider accounts.
        if let legacyToken = KeychainHelper.load(account: legacyFinalsIDAPITokenAccount) {
            if KeychainHelper.save(legacyToken, account: gameProviderTokenAccount(.finalsID)) {
                KeychainHelper.delete(account: legacyFinalsIDAPITokenAccount)
            }
            settings.gameProviders.setToken(legacyToken, for: .finalsID)
        }
        for providerID in GameProviderID.allCases {
            let account = gameProviderTokenAccount(providerID)
            if let token = KeychainHelper.load(account: account) {
                settings.gameProviders.setToken(token, for: providerID)
            } else {
                let pending = settings.gameProviders.token(for: providerID)
                if !pending.isEmpty {
                    _ = KeychainHelper.save(pending, account: account)
                }
            }
            lastGameProviderTokens[providerID] = settings.gameProviders.token(for: providerID)
        }

        // SwiftMiner's pairing used to be written to settings.json in plain
        // text. A value still on disk is newer than the Keychain's by
        // definition (this build never writes one), so it wins and moves in;
        // the file is then rewritten without it rather than waiting for the
        // next save.
        let migratedAPIKey = loadKeychainBacked(&settings.swiftMiner.apiKey, account: swiftMinerAPIKeyAccount)
        let migratedWebhookSecret = loadKeychainBacked(&settings.swiftMiner.webhookSecret, account: swiftMinerWebhookSecretAccount)
        lastSwiftMinerAPIKey = settings.swiftMiner.apiKey
        lastSwiftMinerWebhookSecret = settings.swiftMiner.webhookSecret
        if migratedAPIKey || migratedWebhookSecret {
            try? writeSettingsFile(settings)
        }

        // OpenAI API keys are no longer used. Purge the legacy keychain entry
        // on first load after the Apple-only consolidation so secrets don't
        // sit in the keychain indefinitely.
        if KeychainHelper.load(account: openAIAPIKeyAccount) != nil {
            KeychainHelper.delete(account: openAIAPIKeyAccount)
        }

        return settings
    }

    /// Fills `value` from the Keychain, or moves a plaintext value found on
    /// disk into it. Returns true when a value was migrated off disk.
    private func loadKeychainBacked(_ value: inout String, account: String) -> Bool {
        let onDisk = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !onDisk.isEmpty {
            guard KeychainHelper.save(onDisk, account: account) else { return false }
            value = onDisk
            return true
        }
        if let stored = KeychainHelper.load(account: account) { value = stored }
        return false
    }

    private func saveKeychainBacked(_ value: String, account: String, last: inout String?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != last else { return }
        if trimmed.isEmpty {
            KeychainHelper.delete(account: account)
        } else {
            KeychainHelper.save(trimmed, account: account)
        }
        last = trimmed
    }

    func save(_ settings: BotSettings) throws {
        // If token has changed, update Keychain.
        if settings.token != lastToken {
            if settings.token.isEmpty {
                KeychainHelper.deleteToken()
            } else {
                KeychainHelper.saveToken(settings.token)
            }
            lastToken = settings.token
        }

        let trimmedAdminSecret = settings.adminWebUI.discordOAuth.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAdminSecret.isEmpty {
            KeychainHelper.delete(account: adminDiscordClientSecretAccount)
        } else {
            KeychainHelper.save(trimmedAdminSecret, account: adminDiscordClientSecretAccount)
        }

        let trimmedLocalAuthPassword = settings.adminWebUI.localAuthPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLocalAuthPassword != lastAdminWebLocalAuthPassword {
            if trimmedLocalAuthPassword.isEmpty {
                KeychainHelper.delete(account: adminWebLocalAuthPasswordAccount)
            } else {
                KeychainHelper.save(trimmedLocalAuthPassword, account: adminWebLocalAuthPasswordAccount)
            }
            lastAdminWebLocalAuthPassword = trimmedLocalAuthPassword
        }

        let trimmedCloudflareToken = settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCloudflareToken != lastAdminWebCloudflareToken {
            if trimmedCloudflareToken.isEmpty {
                KeychainHelper.delete(account: adminWebCloudflareTokenAccount)
            } else {
                KeychainHelper.save(trimmedCloudflareToken, account: adminWebCloudflareTokenAccount)
            }
            lastAdminWebCloudflareToken = trimmedCloudflareToken
        }

        let trimmedTunnelToken = settings.adminWebUI.publicAccessTunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTunnelToken != lastAdminWebPublicAccessTunnelToken {
            if trimmedTunnelToken.isEmpty {
                KeychainHelper.delete(account: adminWebPublicAccessTunnelTokenAccount)
            } else {
                KeychainHelper.save(trimmedTunnelToken, account: adminWebPublicAccessTunnelTokenAccount)
            }
            lastAdminWebPublicAccessTunnelToken = trimmedTunnelToken
        }

        for providerID in GameProviderID.allCases {
            let trimmed = settings.gameProviders
                .token(for: providerID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != lastGameProviderTokens[providerID] else { continue }
            let account = gameProviderTokenAccount(providerID)
            if trimmed.isEmpty {
                KeychainHelper.delete(account: account)
            } else {
                KeychainHelper.save(trimmed, account: account)
            }
            lastGameProviderTokens[providerID] = trimmed
        }

        saveKeychainBacked(settings.swiftMiner.apiKey, account: swiftMinerAPIKeyAccount, last: &lastSwiftMinerAPIKey)
        saveKeychainBacked(settings.swiftMiner.webhookSecret, account: swiftMinerWebhookSecretAccount, last: &lastSwiftMinerWebhookSecret)

        try writeSettingsFile(settings)
    }

    /// Writes settings.json with every secret blanked. Callers store the
    /// secrets in the Keychain first (`save`, or a migration in `load`).
    private func writeSettingsFile(_ settings: BotSettings) throws {
        var settingsToSave = settings

        // Always clear secrets from disk-stored settings.
        settingsToSave.token = ""
        settingsToSave.adminWebUI.discordOAuth.clientSecret = ""
        settingsToSave.adminWebUI.localAuthPassword = ""
        settingsToSave.adminWebUI.cloudflareAPIToken = ""
        settingsToSave.adminWebUI.publicAccessTunnelToken = ""
        settingsToSave.gameProviders.clearTokens()
        settingsToSave.swiftMiner.apiKey = ""
        settingsToSave.swiftMiner.webhookSecret = ""
        settingsToSave.clusterSharedSecret = ""
        settingsToSave.clusterMode = .standalone
        settingsToSave.clusterNodeName = Host.current().localizedName ?? "SwiftBot Node"
        settingsToSave.clusterLeaderAddress = ""
        settingsToSave.clusterListenPort = 38787
        settingsToSave.clusterLeaderTerm = 0

        let data = try encoder.encode(settingsToSave)
        try data.write(to: url, options: .atomic)
    }

    func exportMeshSyncedFiles(excludingFileNames: Set<String>, leaderTerm: Int = 0) -> Data? {
        let folder = url.deletingLastPathComponent()
        do {
            try MeshSnapshotDisk.recover(in: folder)
            let names = MeshSnapshotDisk.fileNames.subtracting(excludingFileNames)
            guard names.contains(SwiftBotStorage.settingsFileName), leaderTerm >= 0 else { return nil }
            var files: [MeshSyncedFile] = []
            var deleted: [String] = []
            for name in names.sorted() {
                let fileURL = folder.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    guard name != SwiftBotStorage.settingsFileName else { return nil }
                    deleted.append(name)
                    continue
                }
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                var data = try Data(contentsOf: fileURL)
                guard data.count <= MeshSnapshotDisk.maximumFileBytes else { return nil }
                if name == SwiftBotStorage.settingsFileName {
                    data = try MeshBotConfiguration.sharedData(from: data)
                } else {
                    try MeshSnapshotDisk.validateFile(data, named: name)
                }
                files.append(MeshSyncedFile(fileName: name, base64Data: data.base64EncodedString()))
            }
            let digest = try MeshSnapshotDisk.digest(files: files, deleted: deleted)
            let previous = try MeshSnapshotDisk.loadStamp(in: folder)
            guard previous.map({ leaderTerm >= $0.version.leaderTerm }) ?? true else { return nil }
            let version: MeshSnapshotVersion
            if let previous, previous.version.leaderTerm == leaderTerm {
                guard previous.version.revision < Int64.max else { return nil }
                version = MeshSnapshotVersion(
                    leaderTerm: leaderTerm,
                    revision: previous.digest == digest ? previous.version.revision : previous.version.revision + 1)
            } else {
                version = MeshSnapshotVersion(leaderTerm: leaderTerm, revision: 1)
            }
            let stamp = MeshSnapshotDisk.Stamp(version: version, digest: digest)
            try MeshSnapshotDisk.saveStamp(stamp, in: folder)
            let payload = MeshSyncedFilesPayload(
                generatedAt: Date(), files: files,
                leaderTerm: version.leaderTerm, revision: version.revision, deletedFileNames: deleted)
            return try encoder.encode(payload)
        } catch {
            return nil
        }
    }

    @discardableResult
    func importMeshSyncedFiles(_ data: Data, excludingFileNames: Set<String>, minimumLeaderTerm: Int = 0) -> Int {
        importMeshSnapshot(
            data, excludingFileNames: excludingFileNames,
            minimumLeaderTerm: minimumLeaderTerm).importedFileCount
    }

    /// Full snapshots carry deletions and a persisted (term, revision) stamp.
    /// Validate every entry before staging; never accept partial or stale input.
    func importMeshSnapshot(_ data: Data, excludingFileNames: Set<String> = [], minimumLeaderTerm: Int) -> MeshSnapshotImportResult {
        let folder = url.deletingLastPathComponent()
        func rejected(_ reason: String) -> MeshSnapshotImportResult {
            MeshSnapshotImportResult(accepted: false, importedFileCount: 0, version: nil, rejectionReason: reason)
        }
        do {
            try MeshSnapshotDisk.recover(in: folder)
            guard data.count <= MeshSnapshotDisk.maximumSnapshotBytes,
                  let payload = try? decoder.decode(MeshSyncedFilesPayload.self, from: data),
                  payload.schemaVersion == 2, let term = payload.leaderTerm,
                  let revision = payload.revision, revision > 0, term >= minimumLeaderTerm,
                  let deleted = payload.deletedFileNames else { return rejected("invalid_or_stale_snapshot") }
            let version = MeshSnapshotVersion(leaderTerm: term, revision: revision)
            let names = MeshSnapshotDisk.fileNames.subtracting(excludingFileNames)
            let writtenNames = payload.files.map(\.fileName)
            guard Set(writtenNames).count == writtenNames.count,
                  Set(deleted).count == deleted.count,
                  Set(writtenNames).isDisjoint(with: Set(deleted)),
                  Set(writtenNames).union(deleted) == names,
                  writtenNames.contains(SwiftBotStorage.settingsFileName) else { return rejected("invalid_manifest") }

            var staged: [MeshSyncedFile] = []
            for file in payload.files {
                guard let decoded = Data(base64Encoded: file.base64Data),
                      decoded.count <= MeshSnapshotDisk.maximumFileBytes else { return rejected("invalid_file") }
                let destination = folder.appendingPathComponent(file.fileName)
                if let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                    return rejected("symlink_destination")
                }
                let merged: Data
                if file.fileName == SwiftBotStorage.settingsFileName {
                    let local = try (try? Data(contentsOf: url)) ?? encoder.encode(BotSettings())
                    merged = try MeshBotConfiguration.mergingSharedData(decoded, into: local)
                } else {
                    try MeshSnapshotDisk.validateFile(decoded, named: file.fileName)
                    merged = decoded
                }
                staged.append(MeshSyncedFile(fileName: file.fileName, base64Data: merged.base64EncodedString()))
            }
            let digest = try MeshSnapshotDisk.digest(files: payload.files, deleted: deleted)
            if let previous = try MeshSnapshotDisk.loadStamp(in: folder) {
                guard version >= previous.version else { return rejected("stale_revision") }
                if version == previous.version {
                    guard digest == previous.digest else { return rejected("conflicting_revision") }
                    return MeshSnapshotImportResult(accepted: true, importedFileCount: 0, version: version, rejectionReason: nil)
                }
            }
            let stamp = MeshSnapshotDisk.Stamp(version: version, digest: digest)
            try MeshSnapshotDisk.commit(files: staged, deleted: deleted, stamp: stamp, in: folder)
            return MeshSnapshotImportResult(
                accepted: true,
                importedFileCount: staged.count + deleted.count, version: version, rejectionReason: nil)
        } catch {
            return rejected("snapshot_storage_or_validation_failed")
        }
    }

    func meshSnapshotVersion() -> MeshSnapshotVersion? {
        (try? MeshSnapshotDisk.loadStamp(in: url.deletingLastPathComponent()))?.version
    }
}

/// Explicit bot configuration projection. Transport, recovery credentials,
/// startup preferences and mesh identity remain owned by the receiving Mac.
enum MeshBotConfiguration {
    static let sharedKeys: Set<String> = [
        "prefix", "commandsEnabled", "prefixCommandsEnabled", "slashCommandsEnabled", "disabledCommandKeys",
        "guildSettings", "clusterWorkerOffloadEnabled", "clusterOffloadAIReplies", "clusterOffloadWikiLookups",
        "localAIDMReplyEnabled", "aiActivityAnswersEnabled", "recordingSourceOwners", "recordingGameOverrides",
        "recordingGameAliases", "operators", "userTimezones", "aiMemoryNotes", "localAISystemPrompt",
        "behavior", "welcomeFlow", "wikiBot", "patchy", "musicLinkWatch", "gameTracking",
        "gameProviders", "cachedBotIdentity", "help", "voice", "rewind"
    ]
    static let sharedAuthKeys: Set<String> = [
        "discordOAuth", "redirectPath", "restrictAccessToSpecificUsers", "allowedUserIDs", "memberAccessEnabled"
    ]

    static func withoutSecrets(_ value: BotSettings) -> BotSettings {
        var copy = value
        copy.token = ""
        copy.clusterSharedSecret = ""
        copy.adminWebUI.discordOAuth.clientSecret = ""
        copy.adminWebUI.localAuthPassword = ""
        copy.adminWebUI.cloudflareAPIToken = ""
        copy.adminWebUI.publicAccessTunnelToken = ""
        copy.gameProviders.clearTokens()
        copy.swiftMiner.apiKey = ""
        copy.swiftMiner.webhookSecret = ""
        return copy
    }

    static func sharedData(from data: Data) throws -> Data {
        let settings = try JSONDecoder().decode(BotSettings.self, from: data)
        let object = try dictionary(from: JSONEncoder().encode(withoutSecrets(settings)))
        var shared = object.filter { sharedKeys.contains($0.key) }
        let web = (object["adminWebUI"] as? [String: Any]) ?? [:]
        shared["adminWebUI"] = web.filter { sharedAuthKeys.contains($0.key) }
        // Voice identifiers are installed on a particular Mac.
        if var voice = shared["voice"] as? [String: Any] {
            voice.removeValue(forKey: "preferredVoiceIdentifier")
            shared["voice"] = voice
        }
        return try JSONSerialization.data(withJSONObject: shared, options: [.sortedKeys])
    }

    static func mergingSharedData(_ incoming: Data, into local: Data) throws -> Data {
        let shared = try dictionary(from: sharedData(from: incoming))
        let localSettings = try JSONDecoder().decode(BotSettings.self, from: local)
        var merged = try dictionary(from: JSONEncoder().encode(withoutSecrets(localSettings)))
        for key in sharedKeys {
            if let value = shared[key] { merged[key] = value }
        }
        var web = (merged["adminWebUI"] as? [String: Any]) ?? [:]
        for (key, value) in (shared["adminWebUI"] as? [String: Any]) ?? [:] { web[key] = value }
        merged["adminWebUI"] = web
        if var voice = merged["voice"] as? [String: Any] {
            voice["preferredVoiceIdentifier"] = localSettings.voice.preferredVoiceIdentifier
            merged["voice"] = voice
        }
        let result = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        _ = try JSONDecoder().decode(BotSettings.self, from: result)
        return result
    }

    private static func dictionary(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }
}

/// The journal is written before touching any destination. A crash rolls the
/// complete staged snapshot forward before ConfigStore reads it again; normal
/// I/O failures restore the original files and stamp instead of acknowledging
/// a partially imported snapshot. Ordering is always (term, revision).
enum MeshSnapshotDisk {
    static let fileNames: Set<String> = [
        SwiftBotStorage.settingsFileName, SwiftBotStorage.rulesFileName, "automations.json",
        "automation-executions.json", "bot-command-cooldowns.json", "automation-memory.json",
        SwiftBotStorage.voiceActiveSessionsFileName, SwiftBotStorage.voiceSessionHistoryFileName,
        SwiftBotStorage.gameTrackingStateFileName, SwiftBotStorage.communityStatsFileName
    ]
    static let maximumFileBytes = 16 * 1024 * 1024
    static let maximumSnapshotBytes = 96 * 1024 * 1024
    private static let stampName = "mesh-config-revision.json"
    private static let journalName = ".mesh-config-transaction.json"

    struct Stamp: Codable {
        let version: MeshSnapshotVersion
        let digest: String
    }
    struct Transaction: Codable {
        let files: [MeshSyncedFile]
        let deleted: [String]
        let stamp: Stamp
    }

    static func validateFile(_ data: Data, named name: String) throws {
        try validateJSON(data)
        switch name {
        case "automations.json":
            _ = try JSONDecoder().decode([Automations.Rule].self, from: data)
        case AutomationExecutionJournal.fileName:
            let records = try JSONDecoder().decode([AutomationExecutionCheckpoint].self, from: data)
            guard records.count <= 1000, Set(records.map(\.id)).count == records.count,
                  records.allSatisfy({ $0.nextStep >= 0 && $0.nextStep <= $0.rule.steps.count }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        case AutomationMemory.fileName:
            _ = try JSONDecoder().decode(AutomationMemory.self, from: data)
        case "bot-command-cooldowns.json":
            _ = try JSONDecoder().decode([String: Date].self, from: data)
        default: break
        }
    }

    static func validateJSON(_ data: Data) throws {
        _ = try JSONSerialization.jsonObject(with: data)
    }

    static func digest(files: [MeshSyncedFile], deleted: [String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifest = MeshSyncedFilesPayload(
            generatedAt: Date(timeIntervalSince1970: 0),
            files: files.sorted { $0.fileName < $1.fileName }, deletedFileNames: deleted.sorted())
        return SHA256.hash(data: try encoder.encode(manifest)).map { String(format: "%02x", $0) }.joined()
    }

    static func loadStamp(in folder: URL) throws -> Stamp? {
        let url = folder.appendingPathComponent(stampName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Stamp.self, from: Data(contentsOf: url))
    }

    static func saveStamp(_ stamp: Stamp, in folder: URL) throws {
        try JSONEncoder().encode(stamp).write(to: folder.appendingPathComponent(stampName), options: .atomic)
    }

    static func recover(in folder: URL) throws {
        let journal = folder.appendingPathComponent(journalName)
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let transaction = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: journal))
        guard Set(transaction.files.map(\.fileName)).union(transaction.deleted).isSubset(of: fileNames) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try install(transaction, in: folder)
        try FileManager.default.removeItem(at: journal)
    }

    static func commit(files: [MeshSyncedFile], deleted: [String], stamp: Stamp, in folder: URL) throws {
        let manager = FileManager.default
        let journal = folder.appendingPathComponent(journalName)
        let transaction = Transaction(files: files, deleted: deleted, stamp: stamp)
        let names = Set(files.map(\.fileName)).union(deleted)
        var originalFiles: [MeshSyncedFile] = []
        var originalMissing: [String] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                originalFiles.append(MeshSyncedFile(
                    fileName: name,
                    base64Data: try Data(contentsOf: url).base64EncodedString()
                ))
            } else { originalMissing.append(name) }
        }
        let oldStamp = try loadStamp(in: folder)
        try JSONEncoder().encode(transaction).write(to: journal, options: .atomic)
        do {
            try install(transaction, in: folder)
            try manager.removeItem(at: journal)
        } catch {
            let originalError = error
            // Keep the journal if rollback fails: startup recovery can still
            // install the complete snapshot rather than trust mixed files.
            for original in originalFiles {
                guard let data = Data(base64Encoded: original.base64Data) else { continue }
                try data.write(to: folder.appendingPathComponent(original.fileName), options: .atomic)
            }
            for name in originalMissing {
                let url = folder.appendingPathComponent(name)
                if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            }
            if let oldStamp {
                try saveStamp(oldStamp, in: folder)
            } else {
                let url = folder.appendingPathComponent(stampName)
                if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            }
            try manager.removeItem(at: journal)
            throw originalError
        }
    }

    private static func install(_ transaction: Transaction, in folder: URL) throws {
        for file in transaction.files {
            guard let data = Data(base64Encoded: file.base64Data) else { throw CocoaError(.fileReadCorruptFile) }
            try data.write(to: folder.appendingPathComponent(file.fileName), options: .atomic)
        }
        for name in transaction.deleted {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try saveStamp(transaction.stamp, in: folder)
    }
}

actor MeshCredentialEnrollmentStore {
    private struct State: Codable {
        var local: MeshCredentialEnrollment?
        var grants: [MeshCredentialGrant] = []
    }
    private let account: String
    private var loadedState: State?

    /// Read from the Keychain on first use, on this actor. Reading in `init`
    /// ran on the main thread while AppModel was created, so a Keychain
    /// prompt froze launch before any window appeared.
    private var state: State {
        get {
            if let loadedState { return loadedState }
            var loaded = State()
            if let stored = KeychainHelper.load(account: account), let data = stored.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(State.self, from: data) {
                loaded = decoded
            }
            loadedState = loaded
            return loaded
        }
        set { loadedState = newValue }
    }

    init(account: String = "swiftmesh-credential-enrollment") {
        self.account = account
    }

    func loadOrCreateLocalEnrollment() throws -> MeshCredentialEnrollment {
        if let local = state.local { return local }
        let enrollment = Self.makeEnrollment()
        try saveLocalEnrollment(enrollment)
        return enrollment
    }

    func saveLocalEnrollment(_ enrollment: MeshCredentialEnrollment) throws {
        guard !enrollment.nodeID.isEmpty, Self.privateKey(enrollment.token) != nil else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        var copy = state
        copy.local = enrollment
        try persist(copy)
    }

    func issueGrant(nodeName: String) throws -> MeshCredentialEnrollment {
        let enrollment = Self.makeEnrollment()
        try authorize(enrollment: enrollment, nodeName: nodeName)
        return enrollment
    }

    func authorize(enrollment: MeshCredentialEnrollment, nodeName: String) throws {
        guard !enrollment.nodeID.isEmpty, let key = Self.privateKey(enrollment.token) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let prior = state.grants.first { $0.nodeID == enrollment.nodeID }
        if prior?.publicKey == publicKey { return }
        var copy = state
        copy.grants.removeAll { $0.nodeID == enrollment.nodeID }
        copy.grants.append(MeshCredentialGrant(
            nodeID: enrollment.nodeID, nodeName: nodeName,
            publicKey: publicKey, revision: (prior?.revision ?? 0) + 1))
        try persist(copy)
    }

    func authorizedPublicKey(nodeID: String) -> String? { state.grants.first { $0.nodeID == nodeID }?.publicKey }
    func allGrants() -> [MeshCredentialGrant] { state.grants.sorted { $0.nodeID < $1.nodeID } }

    /// Authoritative full replacement intentionally propagates revocations.
    /// The caller must validate the leader term/config revision first.
    func replaceGrants(_ grants: [MeshCredentialGrant]) throws {
        guard Set(grants.map(\.nodeID)).count == grants.count,
              grants.allSatisfy({ grant in
                  guard !grant.nodeID.isEmpty, grant.revision > 0,
                        let raw = Data(base64Encoded: grant.publicKey) else { return false }
                  return (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil
              }) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        var copy = state
        copy.grants = grants
        try persist(copy)
    }

    func revoke(nodeID: String) throws {
        var copy = state
        copy.grants.removeAll { $0.nodeID == nodeID }
        try persist(copy)
    }

    private func persist(_ copy: State) throws {
        let data = try JSONEncoder().encode(copy)
        guard KeychainHelper.update(data, account: account) else { throw CocoaError(.fileWriteNoPermission) }
        state = copy
    }

    private static func makeEnrollment() -> MeshCredentialEnrollment {
        MeshCredentialEnrollment(
            nodeID: UUID().uuidString,
            token: Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
    }

    private static func privateKey(_ encoded: String) -> Curve25519.Signing.PrivateKey? {
        guard let raw = Data(base64Encoded: encoded) else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }
}

actor SwiftMeshConfigStore {
    private let clusterSharedSecretAccount = "cluster-shared-secret"
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastClusterSharedSecret: String?

    init(filename: String = SwiftBotStorage.swiftMeshConfigFileName) {
        let folder = SwiftBotStorage.folderURL()
        self.url = folder.appendingPathComponent(filename)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> SwiftMeshSettings? {
        var settings: SwiftMeshSettings?
        if let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode(SwiftMeshSettings.self, from: data) {
            settings = decoded
        }

        if let storedSecret = KeychainHelper.load(account: clusterSharedSecretAccount) {
            lastClusterSharedSecret = storedSecret
            if settings != nil {
                settings?.sharedSecret = storedSecret
            }
        } else if let fileSecret = settings?.sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fileSecret.isEmpty {
            KeychainHelper.save(fileSecret, account: clusterSharedSecretAccount)
            lastClusterSharedSecret = fileSecret
            settings?.sharedSecret = fileSecret
            if let scrubbed = settings {
                try? save(scrubbed)
            }
        }
        return settings
    }

    func save(_ settings: SwiftMeshSettings) throws {
        let trimmedClusterSecret = settings.sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedClusterSecret != lastClusterSharedSecret {
            if trimmedClusterSecret.isEmpty {
                KeychainHelper.delete(account: clusterSharedSecretAccount)
            } else {
                KeychainHelper.save(trimmedClusterSecret, account: clusterSharedSecretAccount)
            }
            lastClusterSharedSecret = trimmedClusterSecret
        }

        var copy = settings
        // Secrets are Keychain-only. The config file may be synced across mesh
        // nodes, so never persist the shared secret there.
        copy.sharedSecret = ""
        let data = try encoder.encode(copy)
        try data.write(to: url, options: .atomic)
    }
}

actor MediaLibraryConfigStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(filename: String = SwiftBotStorage.mediaLibraryConfigFileName) {
        let folder = SwiftBotStorage.folderURL()
        self.url = folder.appendingPathComponent(filename)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> MediaLibrarySettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(MediaLibrarySettings.self, from: data) else {
            return MediaLibrarySettings()
        }
        return settings
    }

    func save(_ settings: MediaLibrarySettings) throws {
        var next = settings
        // Ordinary queued settings snapshots cannot change the separately
        // committed local sharing choice, including after pairing completes.
        if FileManager.default.fileExists(atPath: url.path) {
            next.sharedLibraryEnabled = load().sharedLibraryEnabled
        }
        try write(next)
    }

    func saveSharingChoice(_ settings: MediaLibrarySettings) throws {
        try write(settings)
    }

    private func write(_ settings: MediaLibrarySettings) throws {
        let data = try encoder.encode(settings)
        try data.write(to: url, options: .atomic)
    }

    func fileURL() -> URL {
        url
    }
}

actor DiscordCacheStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(filename: String = SwiftBotStorage.discordCacheFileName) {
        let folder = SwiftBotStorage.folderURL()
        self.url = folder.appendingPathComponent(filename)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> DiscordCacheSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(DiscordCacheSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    func save(_ snapshot: DiscordCacheSnapshot) throws {
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// Remove the persisted cache file so stale server data (channel/role/member
    /// names from a previously-connected server) doesn't linger.
    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
final class LogStore: ObservableObject {
    @Published var lines: [String] = []
    @Published var autoScroll = true

    private static let dateFormatter = ISO8601DateFormatter()

    func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("ViewBridge to RemoteViewService Terminated") ||
           trimmed.contains("NSViewBridgeErrorCanceled") {
            return
        }

        let stamp = Self.dateFormatter.string(from: Date())
        lines.append("[\(stamp)] \(line)")
        if lines.count > 500 {
            lines.removeFirst(lines.count - 500)
        }
    }

    func clear() {
        lines.removeAll()
    }

    func fullLog() -> String {
        lines.joined(separator: "\n")
    }
}

actor MeshCursorStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(filename: String = SwiftBotStorage.meshCursorsFileName) {
        let folder = SwiftBotStorage.folderURL()
        self.url = folder.appendingPathComponent(filename)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> [String: ReplicationCursor] {
        guard let data = try? Data(contentsOf: url),
              let cursors = try? decoder.decode([String: ReplicationCursor].self, from: data)
        else { return [:] }
        return cursors
    }

    func save(_ cursors: [String: ReplicationCursor]) throws {
        let data = try encoder.encode(cursors)
        try data.write(to: url, options: .atomic)
    }
}
