import Foundation

// MARK: - SwiftBot Application

/// Main SwiftBot application entry point.
/// This is where the polling system is initialized and started.
/// This is NOT part of UpdateEngine - it's the runtime layer.
@main
struct SwiftBotApp {
    
    static func main() async {
        print("=== Driver Update SwiftBot ===")
        print("Initializing...")
        
        // Load configuration
        let configURL = getConfigurationURL()
        let guilds: [GuildConfiguration]
        
        do {
            guilds = try ConfigurationLoader.loadGuilds(from: configURL)
            print("Loaded \(guilds.count) guild(s) from configuration")
            
            if guilds.isEmpty {
                print("")
                print("⚠️  No guilds configured!")
                print("⚠️  Please edit the configuration file at:")
                print("⚠️  \(configURL.path)")
                print("")
                print("Press Ctrl+C to exit")
                
                // Keep running so user can see the message
                try await Task.sleep(for: .seconds(Double.infinity))
                return
            }
        } catch {
            print("❌ Failed to load configuration: \(error)")
            return
        }
        
        // Initialize version store
        let versionStoreURL = getVersionStoreURL()
        let versionStore = JSONVersionStore(fileURL: versionStoreURL)
        print("Version store: \(versionStoreURL.path)")
        
        // Initialize update checker
        let updateChecker = UpdateChecker(store: versionStore)
        
        // Initialize guild update service
        let guildUpdateService = GuildUpdateService(
            updateChecker: updateChecker,
            guilds: guilds
        )
        
        // Initialize polling manager
        let pollingManager = UpdatePollingManager(
            guildUpdateService: guildUpdateService
        )
        
        // Start polling
        print("")
        print("✓ Starting update polling...")
        print("✓ Checking every 60 minutes")
        print("✓ Monitoring \(guilds.count) guild(s)")
        print("")
        pollingManager.start()
        
        // Keep the application running
        print("Bot is running. Press Ctrl+C to stop.")
        
        // Run forever
        try? await Task.sleep(for: .seconds(Double.infinity))
    }
    
    // MARK: - Configuration Paths
    
    /// Get configuration file URL.
    /// Checks environment variable, falls back to default location.
    private static func getConfigurationURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["GUILDS_CONFIG_PATH"] {
            return URL(fileURLWithPath: path)
        }
        
        // Default: ./config/guilds.json
        return URL(fileURLWithPath: "./config/guilds.json")
    }
    
    /// Get version store file URL.
    /// Checks environment variable, falls back to default location.
    private static func getVersionStoreURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["VERSION_STORE_PATH"] {
            return URL(fileURLWithPath: path)
        }
        
        // Default: ./data/versions.json
        return URL(fileURLWithPath: "./data/versions.json")
    }
}
