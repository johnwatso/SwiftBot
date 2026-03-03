import Foundation

// MARK: - Guild Configuration

/// Configuration for a single guild.
/// Typically loaded from a config file or database.
struct GuildConfiguration: Sendable {
    let guildID: String
    let webhookURL: String
    let enabledVendors: Set<String>
    
    init(guildID: String, webhookURL: String, enabledVendors: Set<String>) {
        self.guildID = guildID
        self.webhookURL = webhookURL
        self.enabledVendors = enabledVendors
    }
}

// MARK: - Guild Update Service

/// Service responsible for checking driver updates for all configured guilds.
/// This is SwiftBot runtime logic - NOT part of UpdateEngine.
final class GuildUpdateService: Sendable {
    private let updateChecker: UpdateChecker
    private let guilds: [GuildConfiguration]
    
    init(updateChecker: UpdateChecker, guilds: [GuildConfiguration]) {
        self.updateChecker = updateChecker
        self.guilds = guilds
    }
    
    /// Check all guilds for driver updates.
    /// This method completes before returning (no overlap).
    func checkAllGuilds() async {
        print("[GuildUpdateService] Checking \(guilds.count) guilds for updates...")
        
        // Fetch driver info once (shared across all guilds)
        let updateSources = await fetchAllDrivers()
        
        if updateSources.isEmpty {
            print("[GuildUpdateService] No driver info fetched, skipping cycle")
            return
        }
        
        print("[GuildUpdateService] Fetched \(updateSources.count) driver sources")
        
        // Check each guild
        for guild in guilds {
            await checkGuild(guild, updateSources: updateSources)
        }
        
        print("[GuildUpdateService] Completed checking all guilds")
    }
    
    // MARK: - Private Methods
    
    /// Fetch all driver sources.
    /// Returns array of UpdateSource implementations.
    private func fetchAllDrivers() async -> [DriverUpdateSource] {
        var sources: [DriverUpdateSource] = []
        
        // Create services locally (not stored as properties for Sendable compliance)
        let nvidiaService = NVIDIAService()
        let amdService = AMDService()
        
        // Fetch NVIDIA
        do {
            let driverInfo = try await nvidiaService.fetchLatestDriver()
            let source = DriverUpdateSource.nvidia(driverInfo)
            sources.append(source)
            print("[GuildUpdateService] Fetched NVIDIA v\(source.version)")
        } catch {
            print("[GuildUpdateService] Failed to fetch NVIDIA: \(error.localizedDescription)")
        }
        
        // Fetch AMD
        do {
            let driverInfo = try await amdService.fetchLatestDriver()
            let source = DriverUpdateSource.amd(driverInfo)
            sources.append(source)
            print("[GuildUpdateService] Fetched AMD v\(source.version)")
        } catch {
            print("[GuildUpdateService] Failed to fetch AMD: \(error.localizedDescription)")
        }
        
        // Note: Intel is mocked in the current implementation
        // Uncomment when Intel service is ready:
        // do {
        //     let driverInfo = try await intelService.fetchLatestDriver()
        //     let source = DriverUpdateSource.intel(driverInfo)
        //     sources.append(source)
        // } catch {
        //     print("[GuildUpdateService] Failed to fetch Intel: \(error)")
        // }
        
        return sources
    }
    
    /// Check a single guild for updates.
    private func checkGuild(_ guild: GuildConfiguration, updateSources: [DriverUpdateSource]) async {
        print("[GuildUpdateService] Checking guild \(guild.guildID)")
        
        for source in updateSources {
            // Skip if guild doesn't want this vendor
            guard guild.enabledVendors.contains(source.vendor) else {
                continue
            }
            
            // Build guild-scoped cache key
            let cacheKey = "\(guild.guildID):\(source.cacheKey)"
            
            // Check version
            let result = updateChecker.check(version: source.version, for: cacheKey)
            
            switch result {
            case .firstCheck(let version):
                print("[GuildUpdateService] Guild \(guild.guildID) - \(source.vendor): First check (v\(version))")
                // Don't send notification on first check
                // Save version so future updates will be detected
                do {
                    try updateChecker.save(version: version, for: cacheKey)
                } catch {
                    print("[GuildUpdateService] Failed to save version: \(error)")
                }
                
            case .changed(let old, let new):
                print("[GuildUpdateService] Guild \(guild.guildID) - \(source.vendor): Version changed \(old ?? "unknown") → \(new)")
                
                // Send update notification
                let success = await sendUpdate(
                    to: guild,
                    source: source,
                    oldVersion: old,
                    newVersion: new
                )
                
                // Only save if send was successful
                if success {
                    do {
                        try updateChecker.save(version: new, for: cacheKey)
                        print("[GuildUpdateService] Saved version \(new) for guild \(guild.guildID)")
                    } catch {
                        print("[GuildUpdateService] Failed to save version: \(error)")
                    }
                }
                
            case .unchanged(let version):
                print("[GuildUpdateService] Guild \(guild.guildID) - \(source.vendor): No change (v\(version))")
            }
        }
    }
    
    /// Send update notification to a guild's webhook.
    /// Returns true if successful, false otherwise.
    private func sendUpdate(
        to guild: GuildConfiguration,
        source: DriverUpdateSource,
        oldVersion: String?,
        newVersion: String
    ) async -> Bool {
        guard let webhookURL = URL(string: guild.webhookURL) else {
            print("[GuildUpdateService] Invalid webhook URL for guild \(guild.guildID)")
            return false
        }
        
        // Prepare request
        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = source.embedJSON.data(using: .utf8)
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[GuildUpdateService] Invalid response for guild \(guild.guildID)")
                return false
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                print("[GuildUpdateService] Successfully sent \(source.vendor) update to guild \(guild.guildID)")
                return true
            } else {
                print("[GuildUpdateService] Failed to send update to guild \(guild.guildID): HTTP \(httpResponse.statusCode)")
                return false
            }
        } catch {
            print("[GuildUpdateService] Error sending update to guild \(guild.guildID): \(error.localizedDescription)")
            return false
        }
    }
}
