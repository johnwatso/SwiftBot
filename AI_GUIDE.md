# AI Assistant Quick Reference

This file provides quick answers to common questions and tasks for AI assistants working on this codebase.

## Quick Facts

- **Platform:** macOS app (SwiftUI)
- **Main State:** `AppModel` in `AppModel.swift`
- **UI:** `RootView.swift` contains all views
- **Models:** Split between `Models.swift` (system) and `RootView.swift` (UI-specific)
- **Discord API:** `DiscordService.swift` (actor)
- **Storage:** JSON files in `~/Library/Application Support/SwiftBot/`
- **Mesh Cursor Durability:** `mesh-cursors.json` via `MeshCursorStore`
- **Patchy Monitor:** SourceTarget-based monitoring UI + hourly runtime scheduler in `AppModel.swift`
- **UpdateEngine Module:** Swift package in `Sources/UpdateEngine`, used by Patchy runtime for source fetch/check logic
- **SwiftMesh State:** Fully implemented through Phase 3 (failover, conversation replication, wiki-cache sync)

## UpdateEngine + Patchy Runtime

- **Purpose:** Standalone update detection infrastructure that is vendor-agnostic and reusable across future sources (GPU vendors, Steam, and other feeds).
- **Status:** Integrated into SwiftBot runtime for Patchy monitoring and delivery, while keeping core UpdateEngine abstractions reusable and isolated.
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
- **Current integration path:**
  1. `AppModel` Patchy scheduler checks configured SourceTargets hourly.
  2. Runtime groups targets by source, fetches once per group, then fan-outs delivery.
  3. Discord send path uses UpdateEngine embed JSON directly (fallback text only if embed is missing/invalid).

## AI Reply Pipeline (Naturalness & Memory)

- **Centralized Logic:** `PromptComposer` in `Models.swift` is the single source of truth for shaping AI responses.
- **Message Formatting:**
  - **Speaker Attribution:** All user turns are formatted as `Name: content` to help the AI track multi-user history.
  - **Trimming:** Assistant messages are capped at 300 characters in the transcript to prevent tone poisoning and token bloat.
  - **History Window:** 8-turn sliding window provides consistent short-term memory.

- **Analytics Context Enrichment (Proposed Feature 5):**
  - **Fact Extraction:** Injects `lastSeenDuration` (e.g., "14 days ago") and `firstSeenStatus` ("first time this week") into the system prompt.
  - **Tone Bias:** The system prompt will be dynamically adjusted based on analytics predicates (e.g., "If this is the user’s first join after 10 days, use a witty/sarcastic welcome tone").

- **Grounded System Prompt:** 
  - Automatically injects current **Server Name**, **Channel Name**, and **Local Time**.
  - Merges recent **Wiki Context** if available from the `!finals` command cache.
- **Fallbacks:** Prefers `AppleIntelligenceEngine` (native) but falls back to `OllamaEngine` (local API) with an identical prompt payload.

## SwiftMesh (High Availability)

> **Note:** Worker mode is temporarily disabled in the UI for UX redesign. Primary and Fail Over modes remain fully functional.

- **Architecture:** Monotonic term-based leader election with standby nodes.
- **Persistence:** Cursors are keyed by stable `nodeName` and saved to `mesh-cursors.json`.
- **Sync Protocol:**
  - Incremental `MemoryRecord` push from Leader to Standby/Worker.
  - Heartbeat-based health monitoring (10s poll, 3-miss promotion threshold).
  - Split-brain protection via `leaderTerm` validation on all mesh routes.
  - Gap detection via `fromCursorRecordID` in `MeshSyncPayload` — mismatch triggers resync via `POST /v1/mesh/sync/conversations/resync`.
  - Paginated resync (`hasMore: Bool`) — standby requests next page immediately until caught up.
  - Wiki cache sync (Phase 3) — standbys pull `WikiContextEntry` batches from leader via `GET /v1/mesh/sync/wiki-cache`.
- **Promotion side-effects:** `promoteToLeader()` clears all replication cursors and fires `onCursorsChanged([:])`.

## Common Tasks

### SwiftMesh Status Checklist

When asked for current SwiftMesh status, use this baseline:
- **Phase 1 (done):** standby failover, leader-term safety, leader-change propagation.
- **Phase 2 (done):** conversation incremental sync, gap-resync, pagination, durable cursors.
- **Phase 2.1 (done):** cursor keying hardened to stable `nodeName` (not endpoint URL).
- **Phase 3 (done):** wiki cache/state replication via `GET /v1/mesh/sync/wiki-cache`.
- **All planned SwiftMesh phases shipped.**

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

### Patchy SourceTarget Editing

- **View:** `PatchyView.swift`
- **Runtime orchestration:** `AppModel.swift`
- **Key runtime methods:**
  - `addPatchyTarget(_:)`
  - `updatePatchyTarget(_:)`
  - `togglePatchyTargetEnabled(_:)`
  - `runPatchyManualCheck()`
  - `sendPatchyTest(targetID:)`
  - `sendPatchyNotificationDetailed(...)`

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

### ❌ Don't: Reintroduce split AI prompt builders
**Problem:** Separate prompt-composition paths cause tone drift and inconsistent reply quality.
**Solution:** Keep prompt/message shaping in the shared composer path used by all local AI reply entry points.

### ❌ Don't: Key mesh cursors by endpoint URL
**Problem:** URL changes during failover/reconfiguration can orphan replication state.
**Solution:** Use stable node identity keys (current implementation uses `nodeName`) and keep writes durable.

### ❌ Don't: Expect cursors to survive promotion
**Problem:** When a standby promotes to leader it starts a new term — old cursor state is irrelevant.
**Solution:** `promoteToLeader()` intentionally wipes `replicationCursors` and fires `onCursorsChanged([:])`; this is correct behavior, not a bug.

### ❌ Don't: Rebuild Patchy Discord embeds manually
**Problem:** Reconstructing content can drift from UpdateEngine formatting.
**Solution:** Use UpdateEngine `embedJSON` payloads directly in send path and only fallback to text when embed JSON is invalid/missing.

### ❌ Don't: Assume live gateway data for config UIs
**Problem:** Offline editing becomes impossible if metadata is cleared on stop/disconnect.
**Solution:** Keep and persist cached Discord metadata (`discord-cache.json`) and use it in selectors while offline.

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
- **Intents:** 37507 (guilds, voice, messages, members)

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
- Apple Intelligence API reference project: https://github.com/gouwsxander/Apple-Intelligence-API

---

**Last Updated:** 2026-03-05  
**Purpose:** Quick reference for AI assistants and developers



## Future Feature Planning (March 2026)

### Implementation Guardrails for New Features:
- **API Checking**: Ensure the bot token is never logged. Use `KeychainHelper` for all retrieval.
- **Welcome Actions**: Implement a burst-guard in the `RuleEngine` to prevent spam during member raids.
- **Onboarding**: The `OnboardingView` must be part of the `RootView` navigation or a full-screen cover, gated by a `hasCompletedOnboarding` flag.
- **App Icon**: Wrap `NSApp` calls in `targetEnvironment(macOS)` or similar guards if cross-platform expansion is ever considered.
