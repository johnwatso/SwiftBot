# Version Caching System

## Overview

The version caching system prevents duplicate driver update notifications by tracking the last seen version for each vendor/channel combination. This is essential for SwiftBot deployments to avoid spamming Discord channels with repeated notifications.

## Architecture

### Core Components

1. **VersionStore Protocol** (`VersionStore.swift`)
   - Defines the interface for version persistence
   - Decoupled from any UI framework
   - Thread-safe operations

2. **JSONVersionStore** (`VersionStore.swift`)
   - Persistent storage using JSON files
   - Accepts file URL via initializer (no hardcoded paths)
   - Automatically creates parent directories
   - Handles errors gracefully
   - Thread-safe using concurrent dispatch queue

3. **InMemoryVersionStore** (`VersionStore.swift`)
   - Non-persistent storage for testing
   - Same interface as JSONVersionStore
   - Includes clear() method for test cleanup

4. **VersionChecker** (`VersionChecker.swift`)
   - Business logic for version comparison
   - Generates composite cache keys
   - Returns structured results (changed/unchanged/firstCheck)

## Cache Key Format

Cache keys use the format: `{vendor}-{channel}`

### Examples:
- `nvidia-gameready` - NVIDIA Game Ready Drivers
- `nvidia-studio` - NVIDIA Studio Drivers  
- `amd-default` - AMD Radeon Drivers
- `intel-default` - Intel Arc Drivers

**Rules:**
- Vendor and channel names are lowercased
- Spaces are replaced with hyphens
- Keys are URL-safe and filesystem-safe

## Usage

### Basic Setup

```swift
// Create version store with custom file path
let fileURL = URL(fileURLWithPath: "./data/versions.json")
let store = JSONVersionStore(fileURL: fileURL)
let checker = VersionChecker(store: store)
```

### Checking for Updates

```swift
// Fetch driver info
let driverInfo = try await nvidiaService.fetchLatestDriver()

// Build cache key
let cacheKey = VersionChecker.cacheKey(vendor: "NVIDIA", channel: "gameReady")

// Check if version changed
let result = checker.checkVersion(driverInfo.releaseNotes.version, for: cacheKey)

switch result {
case .firstCheck(let version):
    print("First check - version: \(version)")
    
case .changed(let old, let new):
    print("Version changed from \(old ?? "unknown") to \(new)")
    // Send notification
    
case .unchanged(let version):
    print("No change - current version: \(version)")
    // Skip notification
}
```

### Saving After Successful Send

```swift
if result.isNewVersion {
    // Send to Discord
    await sendToDiscord(driverInfo.embedJSON)
    
    // Save version only after successful send
    try checker.saveVersion(result.currentVersion, for: cacheKey)
}
```

## SwiftBot Integration

### File Location Options

**Option 1: Home Directory**
```swift
let homeDir = FileManager.default.homeDirectoryForCurrentUser
let fileURL = homeDir
    .appendingPathComponent(".driver-update-bot")
    .appendingPathComponent("versions.json")
```

**Option 2: Working Directory**
```swift
let fileURL = URL(fileURLWithPath: "./data/versions.json")
```

**Option 3: Environment Variable**
```swift
let path = ProcessInfo.processInfo.environment["VERSION_STORE_PATH"] ?? "./data/versions.json"
let fileURL = URL(fileURLWithPath: path)
```

### Periodic Check Loop

```swift
let versionStore = JSONVersionStore(fileURL: fileURL)
let versionChecker = VersionChecker(store: versionStore)

while true {
    // Check NVIDIA
    if let driverInfo = try? await nvidiaService.fetchLatestDriver() {
        let key = VersionChecker.cacheKey(vendor: "NVIDIA", channel: "gameReady")
        let result = versionChecker.checkVersion(driverInfo.releaseNotes.version, for: key)
        
        if result.isNewVersion {
            await sendToDiscord(driverInfo.embedJSON)
            try? versionChecker.saveVersion(result.currentVersion, for: key)
        }
    }
    
    // Check AMD
    if let driverInfo = try? await amdService.fetchLatestDriver() {
        let key = VersionChecker.cacheKey(vendor: "AMD", channel: "default")
        let result = versionChecker.checkVersion(driverInfo.releaseNotes.version, for: key)
        
        if result.isNewVersion {
            await sendToDiscord(driverInfo.embedJSON)
            try? versionChecker.saveVersion(result.currentVersion, for: key)
        }
    }
    
    // Wait before next check
    try? await Task.sleep(for: .seconds(3600)) // 1 hour
}
```

## JSON File Format

The `versions.json` file has a simple structure:

```json
{
  "nvidia-gameready": "560.81",
  "nvidia-studio": "560.70",
  "amd-default": "24.3.1",
  "intel-default": "101.5445"
}
```

## Thread Safety

Both `JSONVersionStore` and `InMemoryVersionStore` use concurrent dispatch queues for thread-safe read/write operations:

- **Reads**: Concurrent (multiple simultaneous reads allowed)
- **Writes**: Barrier (exclusive access during writes)

This ensures the version cache can be safely accessed from multiple threads in a SwiftBot environment.

## Error Handling

### JSONVersionStore Errors

- **File doesn't exist**: Automatically starts with empty cache
- **Invalid JSON**: Prints warning and starts fresh
- **Directory creation failure**: Throws error (caller should handle)
- **File write failure**: Throws error (caller should handle)

### Best Practices

```swift
// Always wrap save operations in error handling
do {
    try versionChecker.saveVersion(version, for: key)
} catch {
    print("Failed to save version: \(error)")
    // Log but don't crash - bot should continue running
}
```

## Testing

### Using InMemoryVersionStore

```swift
let store = InMemoryVersionStore()
let checker = VersionChecker(store: store)

// Run tests
let result = checker.checkVersion("1.0.0", for: "test-vendor-default")
XCTAssertTrue(result.isNewVersion)

// Clean up between tests
store.clear()
```

### Using JSONVersionStore with Temporary Files

```swift
let tempDir = FileManager.default.temporaryDirectory
let testFile = tempDir.appendingPathComponent("test-versions.json")
let store = JSONVersionStore(fileURL: testFile)

// Run tests

// Clean up
try? FileManager.default.removeItem(at: testFile)
```

## Migration Notes

### From No Caching

If you're adding this to an existing bot:

1. First run will treat all versions as "first check"
2. No notifications will be sent (optional - you can change this)
3. Versions will be saved to cache
4. Subsequent runs will properly detect changes

### From Custom Caching

If you have existing version tracking:

1. Create a `versions.json` file with your current versions
2. Use the correct cache key format
3. Initialize JSONVersionStore with that file

## Deployment Considerations

### Docker/Kubernetes

- Mount a persistent volume for the version cache
- Use environment variables for file path configuration
- Ensure the file path is writable by the bot process

### Serverless

- Use external storage (database, S3, etc.)
- Implement a custom VersionStore for your storage backend
- Consider using InMemoryVersionStore with Lambda triggers

### Local Development

- Use InMemoryVersionStore for quick testing
- Use JSONVersionStore in home directory for persistent testing
- Don't commit `versions.json` to git

## Security Notes

- The version cache contains no sensitive data (just version strings)
- File permissions default to user-only read/write
- No encryption needed for the cache file
- Consider backup if version history is important

## Performance

- **Read operations**: O(1) - direct dictionary lookup
- **Write operations**: O(n) - full file write (where n = number of cached versions)
- **Memory usage**: Minimal - entire cache fits in memory
- **Disk usage**: <1KB for typical usage (dozens of vendors/channels)

## Future Enhancements

Potential improvements for future versions:

- Database backend for VersionStore (PostgreSQL, SQLite)
- Version history tracking (not just last version)
- Timestamp tracking for last check
- Automatic cache cleanup for stale entries
- Metrics/analytics on version change frequency
