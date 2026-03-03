import Foundation

// MARK: - SwiftBot Integration Example

/*
 This file demonstrates how to integrate the version caching system
 into a SwiftBot deployment.
 
 DO NOT include this file in production builds.
 This is for documentation purposes only.
 */

// MARK: - Example 1: Basic Setup in SwiftBot

func setupVersionStoreForSwiftBot() -> VersionStore {
    // In SwiftBot, determine a persistent storage location
    // Example paths (choose based on your deployment):
    
    // Option 1: User's home directory
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    let versionFileURL = homeDirectory
        .appendingPathComponent(".driver-update-bot")
        .appendingPathComponent("versions.json")
    
    // Option 2: Working directory (for containerized deployments)
    // let versionFileURL = URL(fileURLWithPath: "./data/versions.json")
    
    // Option 3: Provided via environment variable
    // let dataPath = ProcessInfo.processInfo.environment["VERSION_STORE_PATH"] ?? "./data/versions.json"
    // let versionFileURL = URL(fileURLWithPath: dataPath)
    
    return JSONVersionStore(fileURL: versionFileURL)
}

// MARK: - Example 2: Driver Check Loop

func exampleDriverCheckLoop() async {
    // Initialize version store
    let versionStore = setupVersionStoreForSwiftBot()
    let versionChecker = VersionChecker(store: versionStore)
    
    // Initialize services
    let nvidiaService = NVIDIAService()
    let amdService = AMDService()
    
    // Check NVIDIA drivers
    do {
        let driverInfo = try await nvidiaService.fetchLatestDriver()
        let cacheKey = VersionChecker.cacheKey(vendor: "NVIDIA", channel: "gameReady")
        let result = versionChecker.checkVersion(
            driverInfo.releaseNotes.version,
            for: cacheKey
        )
        
        if result.isNewVersion {
            // Send to Discord
            print("New NVIDIA driver detected: \(result.currentVersion)")
            // await sendToDiscord(driverInfo.embedJSON)
            
            // Save version after successful send
            try versionChecker.saveVersion(result.currentVersion, for: cacheKey)
        } else {
            print("No new NVIDIA driver version")
        }
    } catch {
        print("Error checking NVIDIA: \(error)")
    }
    
    // Check AMD drivers
    do {
        let driverInfo = try await amdService.fetchLatestDriver()
        let cacheKey = VersionChecker.cacheKey(vendor: "AMD", channel: "default")
        let result = versionChecker.checkVersion(
            driverInfo.releaseNotes.version,
            for: cacheKey
        )
        
        if result.isNewVersion {
            print("New AMD driver detected: \(result.currentVersion)")
            // await sendToDiscord(driverInfo.embedJSON)
            try versionChecker.saveVersion(result.currentVersion, for: cacheKey)
        } else {
            print("No new AMD driver version")
        }
    } catch {
        print("Error checking AMD: \(error)")
    }
}

// MARK: - Example 3: Multiple Channels

func exampleMultipleChannels() async throws {
    let versionStore = setupVersionStoreForSwiftBot()
    let versionChecker = VersionChecker(store: versionStore)
    
    // Different NVIDIA channels could be:
    // - "gameReady" (Game Ready Drivers)
    // - "studio" (Studio Drivers)
    // - "beta" (Beta Drivers)
    
    let gameReadyKey = VersionChecker.cacheKey(vendor: "NVIDIA", channel: "gameReady")
    let studioKey = VersionChecker.cacheKey(vendor: "NVIDIA", channel: "studio")
    
    // Each channel maintains its own version history
    print("Last Game Ready: \(versionChecker.checkVersion("560.81", for: gameReadyKey))")
    print("Last Studio: \(versionChecker.checkVersion("560.70", for: studioKey))")
}

// MARK: - Example 4: Environment Configuration

struct BotConfiguration {
    let versionStoreURL: URL
    let checkInterval: TimeInterval
    let discordWebhookURL: URL
    
    static func fromEnvironment() -> BotConfiguration {
        // Read from environment variables
        let storePath = ProcessInfo.processInfo.environment["VERSION_STORE_PATH"] ?? "./data/versions.json"
        let interval = ProcessInfo.processInfo.environment["CHECK_INTERVAL"].flatMap(TimeInterval.init) ?? 3600 // 1 hour
        let webhookURL = ProcessInfo.processInfo.environment["DISCORD_WEBHOOK_URL"] ?? ""
        
        return BotConfiguration(
            versionStoreURL: URL(fileURLWithPath: storePath),
            checkInterval: interval,
            discordWebhookURL: URL(string: webhookURL)!
        )
    }
}

// MARK: - Example 5: Periodic Check with Timer

func examplePeriodicChecks() async {
    let config = BotConfiguration.fromEnvironment()
    let versionStore = JSONVersionStore(fileURL: config.versionStoreURL)
    let versionChecker = VersionChecker(store: versionStore)
    
    // Run checks every N seconds
    while true {
        print("Running driver check...")
        // await checkAllDrivers(versionChecker: versionChecker, webhookURL: config.discordWebhookURL)
        
        try? await Task.sleep(for: .seconds(config.checkInterval))
    }
}

// MARK: - Example 6: Manual Reset/Clear Cache

func exampleManualCacheClear() throws {
    // If you need to clear the cache (e.g., for testing)
    let versionStore = setupVersionStoreForSwiftBot()
    
    // For JSONVersionStore, you can manually delete the file
    // Or implement a clear() method if needed
    
    // For InMemoryVersionStore (testing only):
    if let memoryStore = versionStore as? InMemoryVersionStore {
        memoryStore.clear()
    }
}

// MARK: - Example 7: Error Handling

func exampleErrorHandling() async {
    let versionStore = setupVersionStoreForSwiftBot()
    let versionChecker = VersionChecker(store: versionStore)
    let nvidiaService = NVIDIAService()
    
    do {
        let driverInfo = try await nvidiaService.fetchLatestDriver()
        let cacheKey = VersionChecker.cacheKey(vendor: "NVIDIA", channel: "gameReady")
        let result = versionChecker.checkVersion(
            driverInfo.releaseNotes.version,
            for: cacheKey
        )
        
        if result.isNewVersion {
            // Try to send
            // await sendToDiscord(driverInfo.embedJSON)
            
            // Only save if send was successful
            do {
                try versionChecker.saveVersion(result.currentVersion, for: cacheKey)
                print("Version saved successfully")
            } catch {
                print("Failed to save version: \(error)")
                // Don't crash - continue running
            }
        }
    } catch {
        print("Error fetching driver: \(error)")
        // Log and continue - don't let one failure stop the bot
    }
}
