import Foundation

// MARK: - Version Store Protocol

/// Generic version storage interface supporting arbitrary string keys.
/// Keys can be scoped for any context (vendor, guild, channel, etc.)
protocol VersionStore: Sendable {
    /// Retrieve the last stored version for a given key
    /// - Parameter key: Arbitrary cache key (e.g., "guild123:nvidia-gameready")
    /// - Returns: The last stored version, or nil if no version exists
    func lastVersion(for key: String) -> String?
    
    /// Save a version for a given key
    /// - Parameters:
    ///   - version: The version string to store
    ///   - key: Arbitrary cache key
    /// - Throws: Storage errors (e.g., file write failure)
    func save(version: String, for key: String) throws
}

// MARK: - JSON Version Store

/// File-based version store using JSON persistence.
/// Thread-safe, accepts any file URL, creates directories as needed.
final class JSONVersionStore: VersionStore, @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private var cache: [String: String] = [:]
    private let queue = DispatchQueue(label: "com.driverupdatetester.versionstore", attributes: .concurrent)
    
    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        loadFromDisk()
    }
    
    func lastVersion(for key: String) -> String? {
        queue.sync {
            cache[key]
        }
    }
    
    func save(version: String, for key: String) throws {
        try queue.sync(flags: .barrier) {
            cache[key] = version
            try saveToDisk()
        }
    }
    
    // MARK: - Private Methods
    
    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            // File doesn't exist yet, start with empty cache
            return
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            queue.sync(flags: .barrier) {
                cache = decoded
            }
        } catch {
            // If we can't read the file, start fresh
            print("Warning: Failed to load version cache from disk: \(error.localizedDescription)")
            cache = [:]
        }
    }
    
    private func saveToDisk() throws {
        // Ensure parent directory exists
        let parentDirectory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDirectory.path) {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        }
        
        // Encode and write
        let data = try JSONEncoder().encode(cache)
        try data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - In-Memory Version Store (for testing)

/// Non-persistent version store for testing.
/// Supports arbitrary keys, thread-safe, includes clear() for test cleanup.
final class InMemoryVersionStore: VersionStore, @unchecked Sendable {
    private var cache: [String: String] = [:]
    private let queue = DispatchQueue(label: "com.driverupdatetester.inmemorystore", attributes: .concurrent)
    
    func lastVersion(for key: String) -> String? {
        queue.sync {
            cache[key]
        }
    }
    
    func save(version: String, for key: String) throws {
        queue.sync(flags: .barrier) {
            cache[key] = version
        }
    }
    
    /// Clear all stored versions (for testing)
    func clear() {
        queue.sync(flags: .barrier) {
            cache.removeAll()
        }
    }
}
