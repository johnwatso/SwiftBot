import Foundation

// MARK: - Configuration Loader

/// Loads guild configurations from a JSON file.
/// Provides default configuration if file doesn't exist.
struct ConfigurationLoader {
    
    /// Load guild configurations from a file.
    /// - Parameter fileURL: URL to the guilds.json configuration file
    /// - Returns: Array of GuildConfiguration objects
    /// - Throws: Configuration loading errors
    static func loadGuilds(from fileURL: URL) throws -> [GuildConfiguration] {
        let fileManager = FileManager.default
        
        // Check if file exists
        guard fileManager.fileExists(atPath: fileURL.path) else {
            print("[ConfigurationLoader] Configuration file not found at \(fileURL.path)")
            print("[ConfigurationLoader] Creating example configuration...")
            
            // Create example configuration
            try createExampleConfiguration(at: fileURL)
            
            // Return empty array (user needs to configure guilds)
            return []
        }
        
        // Read and decode
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let config = try decoder.decode(GuildsConfiguration.self, from: data)
        
        // Convert to GuildConfiguration objects
        return config.guilds.map { guild in
            GuildConfiguration(
                guildID: guild.guildID,
                webhookURL: guild.webhookURL,
                enabledVendors: Set(guild.enabledVendors)
            )
        }
    }
    
    /// Create an example configuration file.
    private static func createExampleConfiguration(at fileURL: URL) throws {
        let example = GuildsConfiguration(
            guilds: [
                GuildsConfiguration.Guild(
                    guildID: "123456789012345678",
                    webhookURL: "https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN",
                    enabledVendors: ["NVIDIA", "AMD"]
                ),
                GuildsConfiguration.Guild(
                    guildID: "987654321098765432",
                    webhookURL: "https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN",
                    enabledVendors: ["NVIDIA"]
                )
            ]
        )
        
        // Ensure parent directory exists
        let parentDirectory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDirectory.path) {
            try FileManager.default.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true
            )
        }
        
        // Encode and write
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(example)
        try data.write(to: fileURL)
        
        print("[ConfigurationLoader] Created example configuration at \(fileURL.path)")
        print("[ConfigurationLoader] Please edit this file with your guild configurations")
    }
}

// MARK: - Configuration Models

/// Root configuration structure for guilds.json
struct GuildsConfiguration: Codable {
    let guilds: [Guild]
    
    struct Guild: Codable {
        let guildID: String
        let webhookURL: String
        let enabledVendors: [String]
        
        enum CodingKeys: String, CodingKey {
            case guildID = "guild_id"
            case webhookURL = "webhook_url"
            case enabledVendors = "enabled_vendors"
        }
    }
}
