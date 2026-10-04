import Foundation
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
        if isRunningUnderXCTest { return testFolderURL }
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

    init(filename: String = SwiftBotStorage.settingsFileName) {
        let folder = SwiftBotStorage.folderURL()
        self.url = folder.appendingPathComponent(filename)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> BotSettings {
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

    func exportMeshSyncedFiles(excludingFileNames: Set<String>) -> Data? {
        let folder = SwiftBotStorage.folderURL()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [MeshSyncedFile] = []
        for fileURL in entries {
            guard !excludingFileNames.contains(fileURL.lastPathComponent) else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            files.append(MeshSyncedFile(fileName: fileURL.lastPathComponent, base64Data: data.base64EncodedString()))
        }

        let payload = MeshSyncedFilesPayload(generatedAt: Date(), files: files.sorted(by: { $0.fileName < $1.fileName }))
        return try? encoder.encode(payload)
    }

    @discardableResult
    func importMeshSyncedFiles(_ data: Data, excludingFileNames: Set<String>) -> Int {
        guard let payload = try? decoder.decode(MeshSyncedFilesPayload.self, from: data) else { return 0 }
        let folder = SwiftBotStorage.folderURL()
        var imported = 0
        for file in payload.files {
            guard !excludingFileNames.contains(file.fileName) else { continue }
            guard !file.fileName.contains("/"), !file.fileName.contains("..") else { continue }
            guard let decoded = Data(base64Encoded: file.base64Data) else { continue }
            let url = folder.appendingPathComponent(file.fileName)
            do {
                try decoded.write(to: url, options: .atomic)
                imported += 1
            } catch {
                continue
            }
        }
        return imported
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
