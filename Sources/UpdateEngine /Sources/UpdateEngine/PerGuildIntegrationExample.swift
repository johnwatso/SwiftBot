import Foundation

// MARK: - SwiftBot Per-Guild Integration Example

/*
 This file demonstrates how to integrate per-guild version caching
 into a SwiftBot deployment.
 
 DO NOT include this file in production builds.
 This is for documentation purposes only.
 */

// MARK: - Example 1: Per-Guild Version Tracking

func examplePerGuildCaching() async {
    // Setup single version store for all guilds
    let versionStore = JSONVersionStore(
        fileURL: URL(fileURLWithPath: "./data/versions.json")
    )
    let updateChecker = UpdateChecker(store: versionStore)
    
    let nvidiaService = NVIDIAService()
    
    // Guild A checks NVIDIA
    do {
        let driverInfo = try await nvidiaService.fetchLatestDriver()
        let updateSource = DriverUpdateSource.nvidia(driverInfo)
        
        // Build guild-scoped cache key
        let guildACacheKey = CacheKeyBuilder.buildGuildScoped(
            guildID: "123456789",
            baseKey: updateSource.cacheKey
        )
        // Result: "guild:123456789:nvidia-gameready"
        
        let result = updateChecker.check(version: updateSource.version, for: guildACacheKey)
        
        if result.isNewVersion {
            print("New version for Guild A")
            // Send to Guild A's webhook
            try updateChecker.save(version: updateSource.version, for: guildACacheKey)
        }
    } catch {
        print("Error: \(error)")
    }
    
    // Guild B checks NVIDIA (same driver, different guild)
    do {
        let driverInfo = try await nvidiaService.fetchLatestDriver()
        let updateSource = DriverUpdateSource.nvidia(driverInfo)
        
        let guildBCacheKey = CacheKeyBuilder.buildGuildScoped(
            guildID: "987654321",
            baseKey: updateSource.cacheKey
        )
        // Result: "guild:987654321:nvidia-gameready"
        
        let result = updateChecker.check(version: updateSource.version, for: guildBCacheKey)
        
        if result.isNewVersion {
            print("New version for Guild B (even if Guild A already saw it)")
            // Send to Guild B's webhook
            try updateChecker.save(version: updateSource.version, for: guildBCacheKey)
        }
    } catch {
        print("Error: \(error)")
    }
}

// MARK: - Example 2: SwiftBot Runtime Integration

struct GuildConfig {
    let guildID: String
    let webhookURL: String
    let enabledVendors: [String]
}

class DriverUpdateBot {
    private let updateChecker: UpdateChecker
    private let nvidiaService = NVIDIAService()
    private let amdService = AMDService()
    private let guilds: [GuildConfig]
    
    init(versionStoreURL: URL, guilds: [GuildConfig]) {
        let store = JSONVersionStore(fileURL: versionStoreURL)
        self.updateChecker = UpdateChecker(store: store)
        self.guilds = guilds
    }
    
    func checkAllGuilds() async {
        // Fetch driver info once
        let nvidiaInfo: DriverUpdateSource?
        let amdInfo: DriverUpdateSource?
        
        do {
            let nvidia = try await nvidiaService.fetchLatestDriver()
            nvidiaInfo = .nvidia(nvidia)
        } catch {
            print("Failed to fetch NVIDIA: \(error)")
            nvidiaInfo = nil
        }
        
        do {
            let amd = try await amdService.fetchLatestDriver()
            amdInfo = .amd(amd)
        } catch {
            print("Failed to fetch AMD: \(error)")
            amdInfo = nil
        }
        
        // Check each guild
        for guild in guilds {
            await checkGuild(guild, nvidiaInfo: nvidiaInfo, amdInfo: amdInfo)
        }
    }
    
    private func checkGuild(
        _ guild: GuildConfig,
        nvidiaInfo: DriverUpdateSource?,
        amdInfo: DriverUpdateSource?
    ) async {
        // Check NVIDIA for this guild
        if guild.enabledVendors.contains("NVIDIA"), let nvidia = nvidiaInfo {
            let cacheKey = CacheKeyBuilder.buildGuildScoped(
                guildID: guild.guildID,
                baseKey: nvidia.cacheKey
            )
            
            let result = updateChecker.check(version: nvidia.version, for: cacheKey)
            
            if result.isNewVersion {
                // Send to this guild's webhook
                await sendToGuild(guild, embedJSON: nvidia.embedJSON)
                try? updateChecker.save(version: nvidia.version, for: cacheKey)
            }
        }
        
        // Check AMD for this guild
        if guild.enabledVendors.contains("AMD"), let amd = amdInfo {
            let cacheKey = CacheKeyBuilder.buildGuildScoped(
                guildID: guild.guildID,
                baseKey: amd.cacheKey
            )
            
            let result = updateChecker.check(version: amd.version, for: cacheKey)
            
            if result.isNewVersion {
                await sendToGuild(guild, embedJSON: amd.embedJSON)
                try? updateChecker.save(version: amd.version, for: cacheKey)
            }
        }
    }
    
    private func sendToGuild(_ guild: GuildConfig, embedJSON: String) async {
        // Implementation
        print("Sending to guild \(guild.guildID)")
    }
}

// MARK: - Example 3: versions.json Structure

/*
With per-guild caching, the versions.json file looks like:

{
  "guild:123456789:nvidia-gameready": "560.81",
  "guild:123456789:amd-default": "24.3.1",
  "guild:987654321:nvidia-gameready": "560.70",
  "guild:987654321:amd-default": "24.3.1",
  "guild:555555555:nvidia-gameready": "560.81",
  "guild:555555555:intel-default": "101.5445"
}

Each guild tracks its own version state independently.
*/

// MARK: - Example 4: Global vs Per-Guild

func exampleGlobalVsPerGuild() async {
    let store = JSONVersionStore(fileURL: URL(fileURLWithPath: "./data/versions.json"))
    let checker = UpdateChecker(store: store)
    
    let nvidiaService = NVIDIAService()
    let driverInfo = try! await nvidiaService.fetchLatestDriver()
    let updateSource = DriverUpdateSource.nvidia(driverInfo)
    
    // Global tracking (no guild context)
    let globalKey = updateSource.cacheKey // "nvidia-gameready"
    let globalResult = checker.check(version: updateSource.version, for: globalKey)
    
    // Per-guild tracking
    let guild1Key = CacheKeyBuilder.buildGuildScoped(
        guildID: "guild1",
        baseKey: updateSource.cacheKey
    ) // "guild:guild1:nvidia-gameready"
    
    let guild1Result = checker.check(version: updateSource.version, for: guild1Key)
    
    // These are independent
    print("Global: \(globalResult)")
    print("Guild 1: \(guild1Result)")
}

// MARK: - Example 5: UpdateSource Protocol Usage

func exampleUpdateSourceProtocol() async {
    let nvidiaService = NVIDIAService()
    let driverInfo = try! await nvidiaService.fetchLatestDriver()
    
    // Wrap in UpdateSource
    let updateSource = DriverUpdateSource.nvidia(driverInfo)
    
    // Access properties
    print("Cache Key: \(updateSource.cacheKey)") // "nvidia-gameready"
    print("Version: \(updateSource.version)")    // "560.81"
    print("Vendor: \(updateSource.vendor)")      // "NVIDIA"
    print("Channel: \(updateSource.channel)")    // "gameReady"
    
    // Access original data
    print("Embed JSON: \(updateSource.embedJSON)")
    print("Release Notes: \(updateSource.releaseNotes)")
}

// MARK: - Example 6: Custom Cache Key Scopes

func exampleCustomScopes() {
    // Guild scope
    let guildKey = CacheKeyBuilder.buildGuildScoped(
        guildID: "123",
        baseKey: "nvidia-gameready"
    )
    // Result: "guild:123:nvidia-gameready"
    
    // You can build any scope you want
    // Channel scope (for user-specific tracking)
    let channelKey = "channel:456:nvidia-gameready"
    
    // User scope (for DM tracking)
    let userKey = "user:789:nvidia-gameready"
    
    // The UpdateChecker doesn't care - it accepts any string key
    let store = InMemoryVersionStore()
    let checker = UpdateChecker(store: store)
    
    let result = checker.check(version: "560.81", for: channelKey)
    print(result)
}

// MARK: - Example 7: Migration from Global to Per-Guild

func exampleMigration() throws {
    /*
    If you're migrating from global tracking to per-guild tracking:
    
    Old versions.json:
    {
      "nvidia-gameready": "560.70",
      "amd-default": "24.3.1"
    }
    
    New versions.json (after migration):
    {
      "nvidia-gameready": "560.70",  // Keep old keys for backward compatibility
      "amd-default": "24.3.1",
      "guild:123:nvidia-gameready": "560.70",  // Add per-guild keys
      "guild:123:amd-default": "24.3.1",
      "guild:456:nvidia-gameready": "560.70",
      "guild:456:amd-default": "24.3.1"
    }
    
    The old global keys won't interfere with guild-scoped keys.
    */
}

// MARK: - Example 8: Testing Per-Guild Caching

func testPerGuildCaching() throws {
    let store = InMemoryVersionStore()
    let checker = UpdateChecker(store: store)
    
    // Simulate Guild A seeing version 1.0
    let guild1Key = CacheKeyBuilder.buildGuildScoped(guildID: "guild1", baseKey: "nvidia-gameready")
    try checker.save(version: "1.0", for: guild1Key)
    
    // Simulate Guild B seeing version 1.0
    let guild2Key = CacheKeyBuilder.buildGuildScoped(guildID: "guild2", baseKey: "nvidia-gameready")
    try checker.save(version: "1.0", for: guild2Key)
    
    // Version 2.0 is released
    let guild1Result = checker.check(version: "2.0", for: guild1Key)
    let guild2Result = checker.check(version: "2.0", for: guild2Key)
    
    assert(guild1Result.isNewVersion) // Both guilds see it as new
    assert(guild2Result.isNewVersion)
    
    // Guild 1 sends notification
    try checker.save(version: "2.0", for: guild1Key)
    
    // Guild 2 still sees it as new (independent tracking)
    let guild2Check = checker.check(version: "2.0", for: guild2Key)
    assert(guild2Check.isNewVersion)
    
    store.clear()
}
