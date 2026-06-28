import Foundation

public protocol VersionStore: Sendable {
    func lastIdentifier(for key: String) async throws -> String?
    func save(identifier: String, for key: String) async throws
}

public enum VersionStoreError: Error, LocalizedError, Sendable {
    case invalidJSON(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let url):
            return "Failed to decode identifier cache JSON at \(url.path)."
        }
    }
}

/// File-backed identifier store.
public actor JSONVersionStore: VersionStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private var cache: [String: String]

    public init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.cache = try Self.loadCache(fileURL: fileURL, fileManager: fileManager)
    }

    public func lastIdentifier(for key: String) async throws -> String? {
        cache[key]
    }

    public func save(identifier: String, for key: String) async throws {
        cache[key] = identifier
        try persistToDisk()
    }

    public func snapshot() -> [String: String] {
        cache
    }

    private static func loadCache(fileURL: URL, fileManager: FileManager) throws -> [String: String] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw VersionStoreError.invalidJSON(fileURL)
        }
    }

    private func persistToDisk() throws {
        let parentDirectory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDirectory.path) {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        }

        let data = try JSONEncoder().encode(cache)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// In-memory identifier store for tests and ephemeral runs.
public actor InMemoryVersionStore: VersionStore {
    private var cache: [String: String]

    public init(seed: [String: String] = [:]) {
        self.cache = seed
    }

    public func lastIdentifier(for key: String) async throws -> String? {
        cache[key]
    }

    public func save(identifier: String, for key: String) async throws {
        cache[key] = identifier
    }

    public func clear() {
        cache.removeAll()
    }
}
