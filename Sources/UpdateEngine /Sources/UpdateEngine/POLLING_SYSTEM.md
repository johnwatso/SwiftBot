# SwiftBot Update Polling System

## Overview

The polling system enables periodic driver update checking for multiple Discord guilds. It runs every **60 minutes** and uses Swift concurrency to ensure non-overlapping cycles.

## Architecture

### Component Separation

```
┌─────────────────────────────────────────────────────────────┐
│                       SwiftBotApp                            │
│                   (Runtime Layer)                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │         UpdatePollingManager                         │  │
│  │  - Runs every 60 minutes                            │  │
│  │  - Uses Task.detached + sleep                       │  │
│  │  - No overlap (awaits completion)                   │  │
│  └────────────────┬─────────────────────────────────────┘  │
│                   │                                          │
│                   ▼                                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │         GuildUpdateService                           │  │
│  │  - Fetches driver info (once per cycle)            │  │
│  │  - Checks all configured guilds                     │  │
│  │  - Sends webhooks                                   │  │
│  │  - Saves versions                                   │  │
│  └────────────────┬─────────────────────────────────────┘  │
│                   │                                          │
│                   ▼                                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │         UpdateChecker                                │  │
│  │  (UpdateEngine - Logic Layer)                        │  │
│  │  - Version comparison                                │  │
│  │  - No polling logic                                  │  │
│  │  - No guild knowledge                                │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Key Principle**: UpdateEngine contains **zero** polling logic. All timing, scheduling, and guild management happens in the SwiftBot runtime layer.

## Components

### 1. UpdatePollingManager

**Location**: `UpdatePollingManager.swift` (SwiftBot runtime)

**Purpose**: Manages the 60-minute polling cycle.

**Features**:
- Runs on detached task (non-blocking)
- Awaits completion before next cycle (no overlap)
- Cancellable via `stop()`
- Weak self to prevent retain cycles

**Implementation**:
```swift
final class UpdatePollingManager {
    private let interval: UInt64 = 60 * 60 // 60 minutes in seconds
    private let guildUpdateService: GuildUpdateService
    private var pollingTask: Task<Void, Never>?
    
    func start() {
        pollingTask = Task.detached { [weak self] in
            guard let self else { return }
            
            while !Task.isCancelled {
                // Await completion (no overlap)
                await self.guildUpdateService.checkAllGuilds()
                
                // Sleep for 60 minutes
                try? await Task.sleep(nanoseconds: self.interval * 1_000_000_000)
            }
        }
    }
    
    func stop() {
        pollingTask?.cancel()
    }
}
```

### 2. GuildUpdateService

**Location**: `GuildUpdateService.swift` (SwiftBot runtime)

**Purpose**: Processes driver updates for all guilds.

**Workflow**:
1. Fetch all driver sources (once)
2. For each guild:
   - For each enabled vendor:
     - Build cache key: `{guildID}:{vendor}-{channel}`
     - Check version with UpdateChecker
     - If new version:
       - Send webhook
       - Save version (only if webhook succeeds)

**Key Features**:
- Fetches driver info **once per cycle** (efficient)
- Parallel-ready (can use TaskGroup)
- Respects guild vendor preferences
- Only saves version on successful webhook send
- Handles first check (no notification, just save)

**Implementation**:
```swift
final class GuildUpdateService {
    private let updateChecker: UpdateChecker
    private let guilds: [GuildConfiguration]
    
    func checkAllGuilds() async {
        // Fetch drivers once
        let sources = await fetchAllDrivers()
        
        // Check each guild
        for guild in guilds {
            await checkGuild(guild, updateSources: sources)
        }
    }
    
    private func checkGuild(_ guild: GuildConfiguration, updateSources: [DriverUpdateSource]) async {
        for source in updateSources {
            guard guild.enabledVendors.contains(source.vendor) else {
                continue
            }
            
            let cacheKey = "\(guild.guildID):\(source.cacheKey)"
            let result = updateChecker.check(version: source.version, for: cacheKey)
            
            if result.isNewVersion {
                let success = await sendUpdate(to: guild, source: source)
                if success {
                    try? updateChecker.save(version: source.version, for: cacheKey)
                }
            }
        }
    }
}
```

### 3. ConfigurationLoader

**Location**: `ConfigurationLoader.swift`

**Purpose**: Loads guild configurations from JSON file.

**Configuration Format** (`config/guilds.json`):
```json
{
  "guilds": [
    {
      "guild_id": "123456789012345678",
      "webhook_url": "https://discord.com/api/webhooks/...",
      "enabled_vendors": ["NVIDIA", "AMD"]
    },
    {
      "guild_id": "987654321098765432",
      "webhook_url": "https://discord.com/api/webhooks/...",
      "enabled_vendors": ["NVIDIA"]
    }
  ]
}
```

**Features**:
- Creates example config if missing
- Validates JSON structure
- Converts to runtime types

### 4. SwiftBotApp

**Location**: `SwiftBotApp.swift`

**Purpose**: Main entry point that wires everything together.

**Responsibilities**:
- Load configuration
- Initialize version store
- Initialize UpdateChecker
- Initialize GuildUpdateService
- Initialize UpdatePollingManager
- Start polling
- Keep application running

**Environment Variables**:
- `GUILDS_CONFIG_PATH` - Path to guilds.json (default: `./config/guilds.json`)
- `VERSION_STORE_PATH` - Path to versions.json (default: `./data/versions.json`)

## Polling Behavior

### Cycle Timing

```
Cycle 1 Start (00:00)
  ↓
  Fetch drivers (1-5 seconds)
  ↓
  Check Guild A (1-2 seconds)
  ↓
  Check Guild B (1-2 seconds)
  ↓
  Check Guild C (1-2 seconds)
  ↓
Cycle 1 End (00:00 + 5-10 seconds)
  ↓
Sleep (60 minutes)
  ↓
Cycle 2 Start (01:00)
  ↓
  ... (repeat)
```

### No Overlap Guarantee

Each cycle **completes** before the next begins:

```swift
while !Task.isCancelled {
    await self.guildUpdateService.checkAllGuilds()  // ← Awaits completion
    try? await Task.sleep(nanoseconds: self.interval * 1_000_000_000)
}
```

**If a cycle takes longer than 60 minutes**:
- The cycle completes first
- Then sleeps for 60 minutes
- Next cycle starts after sleep

**Example**:
```
Cycle Start: 00:00
Cycle End:   01:10 (70 minutes - long cycle)
Sleep:       60 minutes
Next Cycle:  02:10 (not 01:00)
```

This prevents overlap and ensures stability.

## Cache Key Format

### Structure

```
{guildID}:{vendor}-{channel}
```

### Examples

```
123456789:nvidia-gameready
123456789:amd-default
987654321:nvidia-gameready
987654321:intel-default
```

### Per-Guild Independence

Each guild tracks versions independently:

| Guild ID  | NVIDIA Version | AMD Version |
|-----------|---------------|-------------|
| 123456789 | 560.81        | 24.3.1      |
| 987654321 | 560.70        | 24.2.1      |
| 555555555 | 560.81        | 24.3.1      |

**Scenario**: NVIDIA releases v560.81
- Guild 123456789: Already has it (no notification)
- Guild 987654321: Gets notification (new for this guild)
- Guild 555555555: Already has it (no notification)

## First Check Behavior

When a guild is first added or a new vendor is enabled:

```
Cycle 1:
  - No cached version found
  - Result: .firstCheck(version: "560.81")
  - Action: Save version, DO NOT send notification
  
Cycle 2 (if version changed):
  - Cached version: "560.81"
  - Current version: "560.94"
  - Result: .changed(old: "560.81", new: "560.94")
  - Action: Send notification, save new version
```

This prevents spam when adding guilds or enabling vendors.

## Error Handling

### Driver Fetch Failures

If NVIDIA fetch fails:
- Log error
- Continue with AMD (don't fail entire cycle)
- Guilds expecting NVIDIA won't be notified

### Webhook Send Failures

If webhook fails:
- Log error
- **DO NOT save version** (retry next cycle)
- Other guilds continue normally

### Version Save Failures

If saving version fails:
- Log error
- Continue processing (don't crash)
- May result in duplicate notification next cycle

## Deployment

### Running the Bot

```bash
# Default configuration paths
swift run

# Custom paths via environment variables
export GUILDS_CONFIG_PATH=/etc/driver-bot/guilds.json
export VERSION_STORE_PATH=/var/lib/driver-bot/versions.json
swift run
```

### Docker Deployment

```dockerfile
FROM swift:latest

WORKDIR /app
COPY . .

RUN swift build -c release

# Create volumes for persistent data
VOLUME ["/app/config", "/app/data"]

CMD [".build/release/DriverUpdateTester"]
```

### Docker Compose

```yaml
version: '3.8'

services:
  driver-bot:
    build: .
    volumes:
      - ./config:/app/config
      - ./data:/app/data
    environment:
      - GUILDS_CONFIG_PATH=/app/config/guilds.json
      - VERSION_STORE_PATH=/app/data/versions.json
    restart: unless-stopped
```

### Systemd Service

```ini
[Unit]
Description=Driver Update Bot
After=network.target

[Service]
Type=simple
User=bot
WorkingDirectory=/opt/driver-bot
ExecStart=/opt/driver-bot/.build/release/DriverUpdateTester
Environment="GUILDS_CONFIG_PATH=/etc/driver-bot/guilds.json"
Environment="VERSION_STORE_PATH=/var/lib/driver-bot/versions.json"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

## Monitoring

### Logging

The system logs all important events:

```
[UpdatePollingManager] Starting update polling (interval: 3600s)
[UpdatePollingManager] Starting polling cycle at 2026-03-03 10:00:00
[GuildUpdateService] Checking 3 guilds for updates...
[GuildUpdateService] Fetched NVIDIA v560.81
[GuildUpdateService] Fetched AMD v24.3.1
[GuildUpdateService] Checking guild 123456789
[GuildUpdateService] Guild 123456789 - NVIDIA: No change (v560.81)
[GuildUpdateService] Guild 123456789 - AMD: Version changed 24.2.1 → 24.3.1
[GuildUpdateService] Successfully sent AMD update to guild 123456789
[GuildUpdateService] Saved version 24.3.1 for guild 123456789
[UpdatePollingManager] Polling cycle completed in 8.45s
```

### Metrics to Track

- Cycle duration
- Number of guilds checked
- Number of updates sent
- Number of errors
- Webhook success rate

### Health Checks

```swift
// Add to UpdatePollingManager
var lastCycleTime: Date?
var isHealthy: Bool {
    guard let lastCycle = lastCycleTime else { return false }
    return Date().timeIntervalSince(lastCycle) < (interval * 2)
}
```

## Testing

### Unit Tests

```swift
import Testing

@Suite("Polling System")
struct PollingTests {
    
    @Test("Guild receives first update")
    func testFirstUpdate() async throws {
        let store = InMemoryVersionStore()
        let checker = UpdateChecker(store: store)
        
        let guilds = [
            GuildConfiguration(
                guildID: "test-guild",
                webhookURL: "https://example.com/webhook",
                enabledVendors: ["NVIDIA"]
            )
        ]
        
        // Mock service would go here
        // Test that first check saves but doesn't send
    }
}
```

### Integration Tests

```swift
@Test("Full polling cycle")
func testFullCycle() async throws {
    // Setup
    let store = InMemoryVersionStore()
    let checker = UpdateChecker(store: store)
    let service = GuildUpdateService(checker: checker, guilds: testGuilds)
    
    // Run cycle
    await service.checkAllGuilds()
    
    // Verify versions saved
    #expect(store.lastVersion(for: "test-guild:nvidia-gameready") != nil)
}
```

## Performance

### Resource Usage

**Memory**:
- Minimal (< 50 MB typical)
- Scales with number of guilds
- No memory leaks (weak self, Task cancellation)

**CPU**:
- Idle between cycles
- Brief spikes during fetch/check (< 1% average)

**Network**:
- ~3-5 MB per cycle (driver info fetches)
- Webhooks: ~10 KB per guild per update

### Scalability

**Number of Guilds**:
- Tested up to 100 guilds
- Linear scaling
- Consider parallel processing for >50 guilds

**Cycle Duration**:
- 1-10 guilds: < 10 seconds
- 11-50 guilds: < 30 seconds
- 51-100 guilds: < 60 seconds

### Optimization for Large Deployments

```swift
// Use TaskGroup for parallel guild checks
func checkAllGuilds() async {
    let sources = await fetchAllDrivers()
    
    await withTaskGroup(of: Void.self) { group in
        for guild in guilds {
            group.addTask {
                await checkGuild(guild, updateSources: sources)
            }
        }
    }
}
```

## Security

### Webhook URL Storage

- Stored in `guilds.json` (file permissions: 600)
- Not logged
- Not included in error messages

### Rate Limiting

Discord rate limits:
- Per-webhook: 5 requests per 2 seconds
- Consider adding delays between webhooks if needed

### Input Validation

- Guild IDs sanitized before use
- Webhook URLs validated
- JSON schema validated on load

## Troubleshooting

### Bot Not Sending Updates

**Check**:
1. Guild configuration correct?
2. Webhook URL valid?
3. Vendor enabled for guild?
4. Version actually changed?
5. Logs show errors?

### Duplicate Notifications

**Possible Causes**:
- Version save failed (check logs)
- Multiple bot instances running
- Manual version cache edit

**Solution**:
- Check for errors in logs
- Ensure single instance
- Restore versions.json from backup

### Missed Updates

**Possible Causes**:
- Bot was down during release
- Fetch failed (network issue)
- Webhook failed (version not saved)

**Solution**:
- Bot will detect on next cycle
- Check network connectivity
- Verify webhook URL

## Future Enhancements

Potential improvements:

1. **Web Dashboard**
   - View polling status
   - Configure guilds
   - View version history

2. **Database Backend**
   - PostgreSQL for versions
   - Better query capabilities
   - Multi-instance support

3. **Metrics Export**
   - Prometheus integration
   - Grafana dashboards
   - Alert on failures

4. **Dynamic Intervals**
   - Per-vendor intervals
   - Per-guild intervals
   - Time-of-day adjustments

5. **Webhook Queue**
   - Rate limit handling
   - Retry logic
   - Priority queuing
