import Foundation

actor ConfigStore {
    private let adminDiscordClientSecretAccount = "admin-discord-client-secret"
    private let openAIAPIKeyAccount = "openai-api-key"
    private let clusterSharedSecretAccount = "cluster-shared-secret"
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastToken: String?
    private var lastOpenAIAPIKey: String?
    private var lastClusterSharedSecret: String?

    init(filename: String = "settings.json") {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("SwiftBot", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
            settings.adminWebUI.discordClientSecret = adminSecret
        } else if !settings.adminWebUI.discordClientSecret.isEmpty {
            let secretToMigrate = settings.adminWebUI.discordClientSecret
            if KeychainHelper.save(secretToMigrate, account: adminDiscordClientSecretAccount) {
                settings.adminWebUI.discordClientSecret = secretToMigrate
            }
        }

        if let storedKey = KeychainHelper.load(account: openAIAPIKeyAccount) {
            settings.openAIAPIKey = storedKey
        } else if !settings.openAIAPIKey.isEmpty {
            KeychainHelper.save(settings.openAIAPIKey, account: openAIAPIKeyAccount)
        }
        lastOpenAIAPIKey = settings.openAIAPIKey

        if let storedSecret = KeychainHelper.load(account: clusterSharedSecretAccount) {
            settings.clusterSharedSecret = storedSecret
        } else if !settings.clusterSharedSecret.isEmpty {
            KeychainHelper.save(settings.clusterSharedSecret, account: clusterSharedSecretAccount)
        }
        lastClusterSharedSecret = settings.clusterSharedSecret

        return settings
    }

    func save(_ settings: BotSettings) throws {
        var settingsToSave = settings

        // If token has changed, update Keychain.
        if settings.token != lastToken {
            if settings.token.isEmpty {
                KeychainHelper.deleteToken()
            } else {
                KeychainHelper.saveToken(settings.token)
            }
            lastToken = settings.token
        }

        let trimmedAdminSecret = settings.adminWebUI.discordClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAdminSecret.isEmpty {
            KeychainHelper.delete(account: adminDiscordClientSecretAccount)
        } else {
            KeychainHelper.save(trimmedAdminSecret, account: adminDiscordClientSecretAccount)
        }

        let trimmedOpenAIKey = settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOpenAIKey != lastOpenAIAPIKey {
            if trimmedOpenAIKey.isEmpty {
                KeychainHelper.delete(account: openAIAPIKeyAccount)
            } else {
                KeychainHelper.save(trimmedOpenAIKey, account: openAIAPIKeyAccount)
            }
            lastOpenAIAPIKey = trimmedOpenAIKey
        }

        let trimmedClusterSecret = settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedClusterSecret != lastClusterSharedSecret {
            if trimmedClusterSecret.isEmpty {
                KeychainHelper.delete(account: clusterSharedSecretAccount)
            } else {
                KeychainHelper.save(trimmedClusterSecret, account: clusterSharedSecretAccount)
            }
            lastClusterSharedSecret = trimmedClusterSecret
        }

        // Always clear secrets from disk-stored settings.
        settingsToSave.token = ""
        settingsToSave.adminWebUI.discordClientSecret = ""
        settingsToSave.openAIAPIKey = ""
        settingsToSave.clusterSharedSecret = ""

        let data = try encoder.encode(settingsToSave)
        try data.write(to: url, options: .atomic)
    }
}

actor RuleConfigStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(filename: String = "rules.json") {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("SwiftBot", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.url = folder.appendingPathComponent(filename)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> [Rule]? {
        guard let data = try? Data(contentsOf: url),
              let rules = try? decoder.decode([Rule].self, from: data)
        else { return nil }
        return rules
    }

    func save(_ rules: [Rule]) throws {
        let data = try encoder.encode(rules)
        try data.write(to: url, options: .atomic)
    }
}

actor DiscordCacheStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(filename: String = "discord-cache.json") {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("SwiftBot", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
}

@MainActor
final class LogStore: ObservableObject {
    @Published var lines: [String] = []
    @Published var autoScroll = true

    private static let dateFormatter = ISO8601DateFormatter()

    func append(_ line: String) {
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

    init(filename: String = "mesh-cursors.json") {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("SwiftBot", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
