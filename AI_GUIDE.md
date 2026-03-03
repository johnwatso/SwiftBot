# AI Assistant Quick Reference

This file provides quick answers to common questions and tasks for AI assistants working on this codebase.

## Quick Facts

- **Platform:** macOS app (SwiftUI)
- **Main State:** `AppModel` in `AppModel.swift`
- **UI:** `RootView.swift` contains all views
- **Models:** Split between `Models.swift` (system) and `RootView.swift` (UI-specific)
- **Discord API:** `DiscordService.swift` (actor)
- **Storage:** JSON files in `~/Library/Application Support/SwiftBot/`
- **UpdateEngine Module:** Standalone Swift Package in `Sources/UpdateEngine`, not wired into `SwiftBotApp` runtime yet

## UpdateEngine (Standalone, Not Integrated)

- **Purpose:** Standalone update detection infrastructure that is vendor-agnostic and reusable across future sources (GPU vendors, Steam, and other feeds).
- **Status:** Not integrated into SwiftBot runtime. Do not wire it into bot startup, runtime polling, or existing command/event flow.
- **Current core abstractions:**
  - `UpdateSource` protocol (`sourceKey`, `fetchLatest()`)
  - `UpdateItem` protocol (`sourceKey`, `identifier`, `version`)
  - `VersionStore` protocol with async `JSONVersionStore` and `InMemoryVersionStore`
  - `UpdateChecker` actor + `CacheKeyBuilder` for identifier-based checks and scoped keys (global or per-guild)
- **Built-in standalone sources:**
  - `NVIDIAUpdateSource`
  - `AMDUpdateSource` (summary prioritizes Highlights, then Fixed Issues, then first meaningful paragraph)
  - `IntelUpdateSource` (identifier = Intel version, cache key `intel-default`)
  - `SteamNewsUpdateSource`
- **Intended future integration path:**
  1. Runtime polling layer fetches updates from configured sources.
  2. Runtime composes per-guild cache keys and checks identifiers independently per guild.
  3. Notifications are sent only after successful delivery, then cache is committed.
- **Architecture direction to preserve:**
  - Keep UpdateEngine vendor/source agnostic.
  - Keep source fetching, change detection, and delivery transport separate.
  - Keep identifier-based caching as the primary change detector (not version-string-only comparison).

## Common Tasks

### Adding a New Command

**Location:** `AppModel.swift` → `executeCommand()` method

```swift
// Add case to switch statement around line 260
case "mycommand":
    // Process arguments from tokens array
    let arg = tokens.count > 1 ? tokens[1] : ""
    return await send(channelId, "Response: \(arg)")
```

**Don't forget:** Update help text in the "help" command case.

### Adding a New Event Type

**Location:** `Models.swift` → EventBus System section

```swift
// Add after MessageReceived struct
struct MyNewEvent: Event {
    let someData: String
    // ... other properties
    
    init(someData: String) {
        self.someData = someData
    }
}
```

**Then:** Publish it somewhere in `AppModel.swift` or `DiscordService.swift`:
```swift
await eventBus.publish(MyNewEvent(someData: "value"))
```

### Creating a New Plugin

**Location:** `Models.swift` → after `WeeklySummaryPlugin`

```swift
final class MyNewPlugin: BotPlugin {
    let name = "MyPlugin"
    private var tokens: [SubscriptionToken] = []
    
    init() {}
    
    func register(on bus: EventBus) async {
        let token = await bus.subscribe(MessageReceived.self) { [weak self] event in
            // Handle event
        }
        tokens.append(token)
    }
    
    func unregister(from bus: EventBus) async {
        for token in tokens {
            await bus.unsubscribe(token)
        }
        tokens.removeAll()
    }
}
```

**Register it:** In `AppModel.init()`, add:
```swift
let myPlugin = MyNewPlugin()
Task { await pluginManager.add(myPlugin) }
```

### Adding a Setting to BotSettings

**Location:** `Models.swift` → `BotSettings` struct

```swift
struct BotSettings: Codable, Hashable {
    // ... existing properties
    var myNewSetting: Bool = false
}
```

**Add UI:** In `RootView.swift` → `SettingsView`, add control:
```swift
Toggle("My New Setting", isOn: $app.settings.myNewSetting)
```

### Adding a New View Tab

**Location:** `RootView.swift` → `RootView` body

```swift
// Add after existing tabs
.tabItem {
    Label("My Tab", systemImage: "star.fill")
}
MyNewTabView()
    .environmentObject(app)
```

**Create view struct:** In `RootView.swift`, add:
```swift
struct MyNewTabView: View {
    @EnvironmentObject var app: AppModel
    
    var body: some View {
        VStack {
            Text("My Tab Content")
        }
        .padding()
    }
}
```

### Adding a Gateway Event Handler

**Location:** `AppModel.swift` → `handlePayload()` method

```swift
case "MY_EVENT_NAME":
    handleMyEvent(payload.d)
```

**Then create handler:**
```swift
private func handleMyEvent(_ raw: DiscordJSON?) {
    guard case let .object(map)? = raw else { return }
    // Parse and handle event
}
```

### Adding a Rule Trigger Type

**Location:** `RootView.swift` → `TriggerType` enum

```swift
enum TriggerType: String, Codable, CaseIterable, Identifiable {
    // ... existing cases
    case myNewTrigger = "My New Trigger"
    
    var id: String { rawValue }
    var symbol: String {
        switch self {
        // ... existing cases
        case .myNewTrigger: return "bolt.fill"
        }
    }
}
```

**Update rule engine:** In `Models.swift` → `RuleEngine.matchesTrigger()`:
```swift
case (.myNewTrigger, .myEventKind):
    return true
```

### Adding a Rule Action Type

**Location:** `RootView.swift` → `ActionType` enum

```swift
enum ActionType: String, Codable, CaseIterable, Identifiable {
    // ... existing cases
    case myAction = "My Action"
    
    var id: String { rawValue }
}
```

**Implement action:** In `DiscordService.swift` → `execute(action:for:)`:
```swift
case .myAction:
    // Perform action
```

## Common Gotchas

### ❌ Don't: Add files without adding to Xcode target
**Problem:** Swift files not in the build target won't compile with the rest of the project.  
**Solution:** Add code to existing files like `Models.swift` or ensure file is in Xcode project.

### ❌ Don't: Forget `.id()` on list detail views
**Problem:** SwiftUI reuses view instances, causing state to leak between selections.  
**Solution:** Always add `.id(selectionID)` when showing detail view based on selection.

### ❌ Don't: Capture IDs in binding closures
**Problem:** Binding closures that capture IDs at creation time become stale.  
**Solution:** Always look up current selection inside the closure:
```swift
Binding(
    get: { 
        guard let currentID = getCurrentID() else { return defaultValue }
        return lookupValue(currentID)
    }
)
```

### ✅ Do: Use MainActor for UI updates
**Problem:** Updating @Published properties from background actors causes warnings.  
**Solution:** Use `await MainActor.run { }` or mark function `@MainActor`.

### ✅ Do: Use actors for thread safety
**Problem:** Concurrent access to mutable state causes data races.  
**Solution:** Use `actor` for classes with mutable state accessed from multiple contexts.

### ✅ Do: Save settings after changes
**Problem:** Settings changes lost on app restart.  
**Solution:** Call `app.saveSettings()` or `app.ruleStore.scheduleAutoSave()`.

## File Modification Checklist

When modifying this project, update these files:

- [ ] **CHANGELOG.md** - Document what changed and why
- [ ] **This file** - If you discover new patterns or gotchas
- [ ] **ARCHITECTURE.md** - If you change core architecture

## Debug Tips

### Bot won't connect
1. Check token is valid in Settings
2. Check console for WebSocket errors
3. Verify internet connection
4. Check Status tab for gateway event count

### Rules not triggering
1. Check rule is enabled (toggle in list)
2. Verify server ID matches connected server
3. Check notification channel is set
4. Look at Logs tab for execution info
5. Verify trigger conditions match event

### UI not updating
1. Check property has `@Published` in AppModel
2. Verify view has `@EnvironmentObject var app: AppModel`
3. Check MainActor isolation for UI updates
4. Look for SwiftUI view identity issues (missing `.id()`)

### Settings not persisting
1. Check `ConfigStore.save()` is called
2. Verify `~/Library/Application Support/SwiftBot/` exists
3. Check file permissions
4. Look at Logs for save errors

## Code Style

### Naming Conventions
- **Types:** PascalCase (`BotSettings`, `AppModel`)
- **Variables:** camelCase (`selectedRuleID`, `botToken`)
- **Functions:** camelCase with verb (`addNewRule`, `handlePayload`)
- **Constants:** camelCase (`eventBus`, `ruleStore`)

### SwiftUI Patterns
- Use `@State` for view-local state
- Use `@Binding` for child view connections
- Use `@EnvironmentObject` for app-wide state
- Use `@Published` in ObservableObject classes

### Async/Await
- Mark functions `async` when doing I/O or network
- Use `await` for async calls
- Use `Task { }` to create unstructured concurrency
- Use `@MainActor` for UI updates

## Project-Specific Patterns

### Message Template Variables
When rendering notification messages, these variables are available:
- `{userId}` - Discord user ID
- `{username}` - Display name
- `{guildId}` - Server ID
- `{guildName}` - Server name
- `{channelId}` - Channel ID
- `{channelName}` - Channel name
- `{fromChannelId}` - Previous channel (moves)
- `{toChannelId}` - New channel (moves)
- `{duration}` - Formatted duration (leaves)

Use `<@{userId}>` for user mentions and `<#{channelId}>` for channel mentions.

### Voice Event Keys
Voice presence keyed as: `"\(guildId)-\(userId)"`

### Discord API Patterns
- **WebSocket:** `wss://gateway.discord.gg/?v=10&encoding=json`
- **REST Base:** `https://discord.com/api/v10`
- **Auth Header:** `Authorization: Bot {token}`
- **Intents:** 37767 (guilds, voice, messages)

## Testing Checklist

Before marking changes complete:
- [ ] Build succeeds without warnings
- [ ] App launches and connects to Discord
- [ ] Modified features work as expected
- [ ] Existing features still work (no regressions)
- [ ] Settings persist across restart
- [ ] CHANGELOG.md updated
- [ ] No console errors or warnings

## Resources

### Discord API Documentation
- Gateway: https://discord.com/developers/docs/topics/gateway
- REST API: https://discord.com/developers/docs/reference
- Intents: https://discord.com/developers/docs/topics/gateway#gateway-intents

### Swift Documentation
- Concurrency: https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html
- SwiftUI: https://developer.apple.com/documentation/swiftui

---

**Last Updated:** 2026-03-02  
**Purpose:** Quick reference for AI assistants and developers
