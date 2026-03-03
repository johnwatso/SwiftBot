# Per-Guild Version Caching Architecture

## Overview

The update engine now supports **per-guild version caching**, enabling independent version tracking across multiple Discord guilds without coupling the core logic to Discord-specific concepts.

## Key Design Principles

1. **Arbitrary Cache Keys**: VersionStore accepts any string key format
2. **No Guild Logic in Core**: UpdateChecker doesn't know about guilds
3. **Protocol-Based Sources**: UpdateSource exposes base cache keys
4. **Runtime Composition**: Guild context is added externally by SwiftBot runtime

## Architecture Components

### 1. UpdateSource Protocol

```swift
protocol UpdateSource {
    var cacheKey: String { get }  // Base key: "nvidia-gameready"
    var version: String { get }    // Current version
}
```

**Purpose**: Abstracts any update source (drivers, game patches, etc.)

**Example Implementation**:
```swift
struct DriverUpdateSource: UpdateSource {
    let vendor: String    // "NVIDIA"
    let channel: String   // "gameReady"
    let version: String   // "560.81"
    
    var cacheKey: String {
        CacheKeyBuilder.build(vendor: vendor, channel: channel)
    }
    // Result: "nvidia-gameready"
}
```

### 2. UpdateChecker

```swift
final class UpdateChecker {
    func check(version: String, for key: String) -> VersionChangeResult
    func save(version: String, for key: String) throws
}
```

**Purpose**: Core version comparison logic

**Key Feature**: Accepts full cache keys as strings - no assumptions about format

**Examples**:
```swift
// Global tracking
checker.check(version: "560.81", for: "nvidia-gameready")

// Guild-scoped tracking
checker.check(version: "560.81", for: "guild:123456:nvidia-gameready")

// Channel-scoped tracking
checker.check(version: "560.81", for: "channel:789:nvidia-gameready")

// Custom scope
checker.check(version: "560.81", for: "any-arbitrary-key-format")
```

### 3. CacheKeyBuilder

```swift
struct CacheKeyBuilder {
    // Build base key
    static func build(vendor: String, channel: String) -> String
    
    // Build guild-scoped key
    static func buildGuildScoped(guildID: String, baseKey: String) -> String
    
    // Build guild-scoped key from vendor/channel
    static func buildGuildScoped(guildID: String, vendor: String, channel: String) -> String
}
```

**Purpose**: Utility for constructing cache keys

**Examples**:
```swift
// Base key
let base = CacheKeyBuilder.build(vendor: "NVIDIA", channel: "gameReady")
// Result: "nvidia-gameready"

// Guild-scoped key
let scoped = CacheKeyBuilder.buildGuildScoped(guildID: "123", baseKey: base)
// Result: "guild:123:nvidia-gameready"

// Shortcut
let scoped2 = CacheKeyBuilder.buildGuildScoped(
    guildID: "123",
    vendor: "NVIDIA",
    channel: "gameReady"
)
// Result: "guild:123:nvidia-gameready"
```

## Cache Key Format

### Standard Format

`guild:{guildID}:{vendor}-{channel}`

**Examples**:
- `guild:123456789:nvidia-gameready`
- `guild:987654321:amd-default`
- `guild:555555555:intel-default`

### Global Format (No Guild Context)

`{vendor}-{channel}`

**Examples**:
- `nvidia-gameready`
- `amd-default`
- `intel-default`

### Custom Formats

The system supports **any** key format:
- `channel:123:nvidia-gameready` - Per-channel tracking
- `user:456:nvidia-gameready` - Per-user tracking
- `region:us-west:nvidia-gameready` - Per-region tracking
- `env:production:nvidia-gameready` - Per-environment tracking

## Per-Guild Workflow

### 1. Setup (Bot Initialization)

```swift
// Single version store for all guilds
let versionStore = JSONVersionStore(
    fileURL: URL(fileURLWithPath: "./data/versions.json")
)

let updateChecker = UpdateChecker(store: versionStore)
```

### 2. Fetch Driver Info (Once)

```swift
let nvidiaService = NVIDIAService()
let driverInfo = try await nvidiaService.fetchLatestDriver()

// Wrap in UpdateSource
let updateSource = DriverUpdateSource.nvidia(driverInfo)

// Base key is available
print(updateSource.cacheKey) // "nvidia-gameready"
print(updateSource.version)   // "560.81"
```

### 3. Check Each Guild (Independent)

```swift
for guild in guilds {
    // Build guild-specific cache key
    let cacheKey = CacheKeyBuilder.buildGuildScoped(
        guildID: guild.id,
        baseKey: updateSource.cacheKey
    )
    
    // Check version for this guild
    let result = updateChecker.check(
        version: updateSource.version,
        for: cacheKey
    )
    
    // Send notification if new for THIS guild
    if result.isNewVersion {
        await sendToGuild(guild, embedJSON: updateSource.embedJSON)
        try updateChecker.save(version: updateSource.version, for: cacheKey)
    }
}
```

### 4. Independent State

Each guild maintains **independent** version history:

| Guild ID | Last NVIDIA Version | Last AMD Version |
|----------|-------------------|-----------------|
| 123456   | 560.81            | 24.3.1          |
| 789012   | 560.70            | 24.2.1          |
| 345678   | 560.81            | 24.3.1          |

- Guild 789012 will receive update for NVIDIA 560.81 (even though Guild 123456 already has it)
- Guild 789012 will receive update for AMD 24.3.1 (even though Guild 123456 already has it)
- Guild 345678 is up to date with all drivers

## Storage Format

### versions.json Example

```json
{
  "guild:123456789:nvidia-gameready": "560.81",
  "guild:123456789:nvidia-studio": "560.70",
  "guild:123456789:amd-default": "24.3.1",
  "guild:123456789:intel-default": "101.5445",
  
  "guild:987654321:nvidia-gameready": "560.70",
  "guild:987654321:amd-default": "24.2.1",
  
  "guild:555555555:nvidia-gameready": "560.81",
  "guild:555555555:amd-default": "24.3.1",
  "guild:555555555:intel-default": "101.5445",
  
  "nvidia-gameready": "560.81",
  "amd-default": "24.3.1"
}
```

**Notes**:
- Guild-scoped keys don't interfere with global keys
- Each guild maintains independent state
- Multiple channels per vendor are supported
- Keys are human-readable for debugging

## SwiftBot Integration Patterns

### Pattern 1: Simple Multi-Guild Bot

```swift
class DriverBot {
    let updateChecker: UpdateChecker
    let guilds: [GuildConfig]
    
    func runCheckCycle() async {
        // Fetch drivers once
        let updates = await fetchAllDrivers()
        
        // Check each guild
        for guild in guilds {
            for update in updates {
                let key = CacheKeyBuilder.buildGuildScoped(
                    guildID: guild.id,
                    baseKey: update.cacheKey
                )
                
                let result = updateChecker.check(version: update.version, for: key)
                
                if result.isNewVersion {
                    await notify(guild: guild, update: update)
                    try? updateChecker.save(version: update.version, for: key)
                }
            }
        }
    }
}
```

### Pattern 2: Per-Guild Configuration

```swift
struct GuildConfig {
    let guildID: String
    let webhookURL: String
    let enabledVendors: [String]  // ["NVIDIA", "AMD"]
    let enabledChannels: [String: [String]]  // ["NVIDIA": ["gameReady", "studio"]]
}

func checkGuild(_ guild: GuildConfig, updates: [DriverUpdateSource]) async {
    for update in updates {
        // Skip if guild doesn't want this vendor
        guard guild.enabledVendors.contains(update.vendor) else {
            continue
        }
        
        // Skip if guild doesn't want this channel
        if let channels = guild.enabledChannels[update.vendor],
           !channels.contains(update.channel) {
            continue
        }
        
        // Check version
        let key = CacheKeyBuilder.buildGuildScoped(
            guildID: guild.guildID,
            baseKey: update.cacheKey
        )
        
        let result = updateChecker.check(version: update.version, for: key)
        
        if result.isNewVersion {
            await sendToGuild(guild, update: update)
            try? updateChecker.save(version: update.version, for: key)
        }
    }
}
```

### Pattern 3: Parallel Guild Checks

```swift
func checkAllGuilds(_ guilds: [GuildConfig], updates: [DriverUpdateSource]) async {
    await withTaskGroup(of: Void.self) { group in
        for guild in guilds {
            group.addTask {
                await checkGuild(guild, updates: updates)
            }
        }
    }
}
```

## Benefits

### 1. Independent Guild State
- Each guild tracks versions independently
- No cross-guild interference
- Guilds can be added/removed without affecting others

### 2. Flexible Scoping
- Guild-level tracking (default)
- Channel-level tracking (optional)
- User-level tracking (for DMs)
- Custom scoping (environment, region, etc.)

### 3. No Discord Coupling
- Core logic knows nothing about Discord
- No guild ID types or Discord SDK dependencies
- Works with any string-based context

### 4. Efficient Resource Usage
- Fetch driver info once per check cycle
- Share fetched data across all guilds
- Parallel processing supported

### 5. Easy Testing
- Use InMemoryVersionStore for tests
- Mock guild IDs with simple strings
- No Discord API required for testing

## Migration Guide

### From Global to Per-Guild

**Before** (Global tracking):
```swift
let key = "nvidia-gameready"
let result = checker.check(version: "560.81", for: key)
```

**After** (Per-guild tracking):
```swift
let key = CacheKeyBuilder.buildGuildScoped(
    guildID: guildID,
    baseKey: "nvidia-gameready"
)
let result = checker.check(version: "560.81", for: key)
```

**Note**: Old global keys remain in versions.json and don't interfere with guild-scoped keys.

### Backwards Compatibility

The system supports both formats simultaneously:

```json
{
  "nvidia-gameready": "560.81",                    // Old global key
  "guild:123:nvidia-gameready": "560.81",         // New guild key
  "guild:456:nvidia-gameready": "560.70"          // Another guild key
}
```

## Performance Considerations

### 1. Memory Usage
- All cached versions loaded into memory
- Typical usage: ~1KB for 100 guild-vendor combinations
- Scales linearly with (guilds × vendors × channels)

### 2. Disk I/O
- Write on every version save (atomic write)
- Consider batching saves if needed
- File size: ~100 bytes per cached version

### 3. Concurrent Access
- Thread-safe reads (concurrent queue)
- Thread-safe writes (barrier queue)
- Safe for parallel guild checks

## Testing

### Unit Test Example

```swift
import Testing

@Suite("Per-Guild Version Caching")
struct PerGuildTests {
    
    @Test("Independent guild tracking")
    func testIndependentGuilds() throws {
        let store = InMemoryVersionStore()
        let checker = UpdateChecker(store: store)
        
        // Guild 1 sees version 1.0
        let guild1Key = CacheKeyBuilder.buildGuildScoped(
            guildID: "guild1",
            baseKey: "nvidia-gameready"
        )
        try checker.save(version: "1.0", for: guild1Key)
        
        // Guild 2 sees version 1.0
        let guild2Key = CacheKeyBuilder.buildGuildScoped(
            guildID: "guild2",
            baseKey: "nvidia-gameready"
        )
        try checker.save(version: "1.0", for: guild2Key)
        
        // Version 2.0 released
        let result1 = checker.check(version: "2.0", for: guild1Key)
        let result2 = checker.check(version: "2.0", for: guild2Key)
        
        #expect(result1.isNewVersion)
        #expect(result2.isNewVersion)
        
        // Guild 1 updates
        try checker.save(version: "2.0", for: guild1Key)
        
        // Guild 2 still sees it as new
        let result2Again = checker.check(version: "2.0", for: guild2Key)
        #expect(result2Again.isNewVersion)
    }
}
```

## Security Considerations

### 1. Key Sanitization
- Guild IDs should be sanitized before use
- Avoid special characters in keys
- CacheKeyBuilder handles common cases

### 2. Storage Security
- versions.json contains only version strings
- No sensitive data (tokens, keys, etc.)
- File permissions default to user-only

### 3. Denial of Service
- Malicious guilds can't affect other guilds
- No cross-guild state pollution
- Independent version tracking prevents cascade failures

## Future Enhancements

Potential improvements:

1. **Timestamp Tracking**
   - Track when each version was first seen
   - Enable age-based queries

2. **Version History**
   - Store multiple versions per key
   - Enable rollback detection

3. **Batch Operations**
   - Batch save multiple versions
   - Reduce disk I/O

4. **Database Backend**
   - PostgreSQL, SQLite support
   - Better query capabilities

5. **Metrics**
   - Track version adoption rates
   - Monitor guild activity

6. **Cleanup**
   - Remove stale guild keys
   - Archive old versions
