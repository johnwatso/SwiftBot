import Foundation

enum SwiftBotStorage {
    static let appFolderName = "SwiftBot"
    static let settingsFileName = "settings.json"
    static let rulesFileName = "rules.json"
    static let discordCacheFileName = "discord-cache.json"
    static let meshCursorsFileName = "mesh-cursors.json"
    static let swiftMeshConfigFileName = "swiftmesh-config.json"

    static func folderURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent(appFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

actor ConfigStore {
    private let adminDiscordClientSecretAccount = "admin-discord-client-secret"
    private let openAIAPIKeyAccount = "openai-api-key"
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastToken: String?
    private var lastOpenAIAPIKey: String?

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

        // Always clear secrets from disk-stored settings.
        settingsToSave.token = ""
        settingsToSave.adminWebUI.discordClientSecret = ""
        settingsToSave.openAIAPIKey = ""
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
        copy.sharedSecret = ""
        let data = try encoder.encode(copy)
        try data.write(to: url, options: .atomic)
    }
}

actor RuleConfigStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(filename: String = SwiftBotStorage.rulesFileName) {
        let folder = SwiftBotStorage.folderURL()
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
