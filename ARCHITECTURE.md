# Technical Architecture

This document provides a high-level overview of the SwiftBot application architecture for AI assistants and developers.

## Project Overview

**Type:** Native macOS Application  
**Framework:** SwiftUI  
**Language:** Swift with Concurrency (async/await, actors)  
**Platform:** macOS 13+  
**Build System:** Xcode Project + Swift Package Manager
**Standalone Package (Not Integrated):** `Sources/UpdateEngine`

## Core Components

### 1. Application Layer
- **File:** `SwiftBotApp.swift`
- **Purpose:** SwiftUI App entry point
- **Key:** Initializes `AppModel` as `@StateObject`

### 2. State Management
- **File:** `AppModel.swift`
- **Class:** `AppModel` (MainActor, ObservableObject)
- **Responsibilities:**
  - Bot lifecycle management (start/stop)
  - Settings persistence
  - Gateway event handling
  - Command processing
  - Voice presence tracking
  - Rule engine coordination
  - Plugin management via `PluginManager`
  - Patchy monitoring scheduler and delivery orchestration
  - Discord metadata caching for offline configuration
- **Key Properties:**
  - `eventBus: EventBus` - Event system for plugins
  - `ruleStore: RuleStore` - Notification rules
  - `service: DiscordService` - Discord API service
  - `pluginManager: PluginManager` - Plugin lifecycle

### 3. Discord Communication
- **File:** `DiscordService.swift`
- **Actor:** `DiscordService`
- **Responsibilities:**
  - WebSocket Gateway connection (wss://gateway.discord.gg)
  - REST API calls (https://discord.com/api/v10)
  - Heartbeat management
  - Voice state tracking
  - Rule action execution
  - On-device AI replies for DMs and guild mentions (when enabled)
  - Shared AI prompt/message composition path for consistent local reply behavior

### 4. Data Models
- **File:** `Models.swift`
- **Contains:**
  - **EventBus System:** Event protocol, EventBus class, SubscriptionToken
  - **Events:** VoiceJoined, VoiceLeft, MessageReceived
  - **Settings Models:** BotSettings, GuildSettings
  - **UI Models:** ActivityEvent, CommandLogEntry, VoiceMemberPresence
  - **Gateway:** GatewayPayload, DiscordJSON
  - **Rules:** VoiceRuleEvent (used by rule engine)
  - **Plugin System:** BotPlugin protocol, PluginManager, WeeklySummaryPlugin
- **File:** `RootView.swift`
- **Contains:**
  - **Rule Models:** Rule, RuleAction, Condition, TriggerType, ActionType
  - **UI Components:** All SwiftUI views

### 5. Persistence
- **File:** `Persistence.swift`
- **Actors:**
  - `ConfigStore` - Saves/loads `BotSettings` to JSON
  - `RuleConfigStore` - Saves/loads `[Rule]` array to JSON
  - `DiscordCacheStore` - Saves/loads cached Discord metadata (`DiscordCacheSnapshot`)
- **Storage Location:** `~/Library/Application Support/SwiftBot/`
- **Files:** `settings.json`, `rules.json`, `discord-cache.json`
- **Class:** `LogStore` (@MainActor) - In-memory log with 500 line limit
- **Class:** `MeshCursorStore` (actor) - Durable SwiftMesh replication cursor storage (`mesh-cursors.json`)

### 6. User Interface
- **File:** `RootView.swift`
- **Main View:** `RootView` - `NavigationSplitView` container
- **Sidebar Sections:**
  - **Overview** - Activity feed, stats, server info
  - **Patchy** - SourceTarget monitor panel with grouped targets and modal editor
  - **Actions** - Rule builder (HSplitView: list + editor)
  - **Commands** - Command history log
  - **Logs** - System logs with auto-scroll
  - **Settings** - Bot token, prefix, cluster and AI settings
  - **AI Bots** - AI bot configuration panel
  - **Status** - Gateway stats, voice presence

### 7. UpdateEngine Package + Patchy Runtime Use
- **Path:** `Sources/UpdateEngine`
- **Package Product:** `UpdateEngine` (library target)
- **Status:** Integrated for Patchy source monitoring and Discord delivery. Core package remains source-agnostic.
- **Purpose:** Provide reusable update-source abstractions and identifier-based change detection used by Patchy runtime scheduling.
- **Core API Surface:**
  - `UpdateSource` protocol (`sourceKey`, `fetchLatest()`)
  - `UpdateItem` protocol (`sourceKey`, `identifier`, `version`)
  - `UpdateChecker` actor for identifier comparison and save
  - `VersionStore` async protocol (`JSONVersionStore`, `InMemoryVersionStore`)
  - `CacheKeyBuilder` for base and scoped keys (including per-guild keys)
- **Built-in source implementations:**
  - `NVIDIAUpdateSource`
  - `AMDUpdateSource` (summary extraction prioritizes Highlights, then Fixed Issues, then first meaningful paragraph)
  - `IntelUpdateSource` (`cacheKey`/`sourceKey` = `intel-default`, identifier = vendor version)
  - `SteamNewsUpdateSource`
- **Architectural decisions:**
  - Vendor-agnostic source abstraction via protocols.
  - Identifier-based caching (stable item IDs) instead of version-only comparisons.
  - Runtime-owned scheduling/delivery in `SwiftBotApp` (not in UpdateEngine core).
  - Source modules handle vendor-specific parsing/networking while keeping `UpdateChecker` + `VersionStore` generic.
  - Patchy runtime uses UpdateEngine outputs (`embedJSON`) as Discord payload source of truth.

## Data Flow

### Gateway Event Flow
```
Discord Gateway WebSocket
    ↓
DiscordService.receiveLoop()
    ↓
DiscordService.handleGatewayPayload()
    ↓
AppModel.handlePayload()
    ├→ handleMessageCreate() → executeCommand()
    ├→ handleVoiceStateUpdate() → EventBus.publish(VoiceJoined/Left)
    ├→ handleReady()
    └→ handleGuildCreate()
```

### Rule Engine Flow
```
Gateway Event
    ↓
DiscordService.processRuleActionsIfNeeded()
    ↓
DiscordService.parseVoiceRuleEvent() / parseMessageRuleEvent()
    ↓
RuleEngine.evaluate(event) [MainActor]
    ↓
DiscordService.execute(action)
    ├→ sendMessage()
    ├→ updatePresence()
    └→ addLogEntry (no-op)
```

### EventBus Flow (Plugins)
```
AppModel.handleVoiceStateUpdate()
    ↓
EventBus.publish(VoiceJoined/Left)
    ↓
WeeklySummaryPlugin (subscriber)
    ↓
Update voiceDurations dictionary
```

## Key Design Patterns

### Actor Isolation
- `DiscordService` is an actor for thread-safe WebSocket/REST operations
- `ConfigStore`, `RuleConfigStore` are actors for safe file I/O
- `MeshCursorStore` is an actor for safe failover cursor durability
- `AppModel` uses `@MainActor` for UI binding

### Async/Await
- All network operations use Swift Concurrency
- Gateway events processed asynchronously
- Plugin subscriptions support async handlers

### Publish/Subscribe (EventBus)
- Decoupled event system for extensibility
- Type-safe event subscriptions
- Async handler support
- Used by plugin system

### MVVM Pattern
- `AppModel` = ViewModel
- SwiftUI Views = View layer
- Model types in `Models.swift` and `RootView.swift`

## Important Implementation Details

### Binding Architecture in Server Notifier
**Critical Pattern (Fixed 2026-03-02):**
```swift
// selectedRuleBinding must always look up CURRENT selectedRuleID
// Not capture it at creation time
private var selectedRuleBinding: Binding<Rule>? {
    return Binding(
        get: {
            guard let currentSelectedID = app.ruleStore.selectedRuleID,
                  let idx = app.ruleStore.rules.firstIndex(where: { $0.id == currentSelectedID }) else {
                return Rule(id: selectedRuleID)
            }
            return app.ruleStore.rules[idx]
        },
        set: { updatedRule in
            guard let currentSelectedID = app.ruleStore.selectedRuleID,
                  let idx = app.ruleStore.rules.firstIndex(where: { $0.id == currentSelectedID }) else {
                return
            }
            app.ruleStore.rules[idx] = updatedRule
        }
    )
}

// RuleEditorView MUST have .id() for proper recreation
RuleEditorView(rule: selectedRuleBinding)
    .id(app.ruleStore.selectedRuleID)
```

### Discord Gateway Opcodes
- **0** - Dispatch (events like VOICE_STATE_UPDATE, MESSAGE_CREATE)
- **1** - Heartbeat request from server
- **2** - Identify (sent on connect)
- **3** - Presence update
- **7** - Reconnect
- **9** - Invalid session
- **10** - Hello (contains heartbeat_interval)
- **11** - Heartbeat ACK

### Voice State Tracking
- Maintains `joinTimes: [String: Date]` keyed by `"guildId-userId"`
- Tracks `activeVoice: [VoiceMemberPresence]` for UI display
- Calculates duration on leave events
- Publishes `VoiceJoined` and `VoiceLeft` events to EventBus

### On-Device AI
- Uses `FoundationModels` framework when available
- macOS 26.0+ required for `SystemLanguageModel`
- Falls back gracefully if unavailable
- Controlled by `settings.localAIDMReplyEnabled`
- Uses a shared prompt-composition path to keep direct and rule-triggered replies consistent

## SwiftMesh High Availability (Current State)

SwiftMesh now has phased HA support beyond basic leader/worker routing (Note: Worker mode is temporarily disabled in the UI for UX redesign):

- **Phase 1 (implemented):**
  - `standby` mode with leader health monitoring (10s poll, 3-miss promotion)
  - term-based promotion safety (persisted monotonic `clusterLeaderTerm`)
  - authenticated leader-change propagation to workers
- **Phase 2 (implemented):**
  - incremental conversation replication with per-node durable cursors
  - gap detection + bounded resync pagination
  - idempotent merge behavior for duplicate delivery/retry safety
- **Phase 2.1 (implemented):**
  - cursor-key hardening from endpoint URL keys to stable node identifiers (`nodeName`)
- **Phase 3 (implemented):**
  - wiki cache/state replication across nodes for failover knowledge continuity via background pull protocol (`/v1/mesh/sync/wiki-cache`)

## Plugin System

### Interface
```swift
protocol BotPlugin {
    var name: String { get }
    func register(on bus: EventBus) async
    func unregister(from bus: EventBus) async
}
```

### Current Plugins
- **WeeklySummaryPlugin** - Accumulates voice duration by userId

### Adding New Plugins
1. Create class conforming to `BotPlugin` in `Models.swift`
2. Implement `register()` to subscribe to events
3. Store subscription tokens for cleanup
4. Implement `unregister()` to clean up
5. Add to `PluginManager` in `AppModel.init()`

## File Organization

### Build Target Structure
```
SwiftBot.xcodeproj
└── SwiftBot (target)
    ├── SwiftBotApp.swift (entry point)
    ├── AppModel.swift (main state)
    ├── Models.swift (data models + EventBus + plugins)
    ├── DiscordService.swift (Discord API)
    ├── ClusterCoordinator.swift (SwiftMesh cluster + HTTP server)
    ├── Persistence.swift (storage)
    ├── RootView.swift (all UI)
    └── Resources/
        └── AppIcon.png
```

## Testing Strategy

### Automated Testing (XCTest)
- **`Tests/SwiftBotTests/ClusterSecurityTests.swift`** — 6 tests: shared-secret enforcement, SSRF guards, request body caps
- **`Tests/SwiftBotTests/MeshFailoverTests.swift`** — 7 tests: standby promotion, term monotonicity, worker re-registration
- **`Tests/SwiftBotTests/MeshSyncTests.swift`** — 5 tests: incremental push, duplicate no-op, resync from cursor, paginated convergence, cursor reset on promotion
- **Total:** 18 automated tests covering cluster security, failover, and sync behavior

### Manual Testing
- Bot connection/disconnection
- Voice presence tracking
- Rule creation and triggering
- Command execution
- Settings persistence

### Key Test Scenarios
1. **Multiple Rules:** Create 3+ rules, verify independent editing
2. **Voice Events:** Join/leave/move voice channels, check notifications
3. **Gateway Reconnection:** Kill network, verify reconnect
4. **Rule Engine:** Test all trigger types and conditions
5. **Persistence:** Restart app, verify settings/rules restored

## Performance Considerations

### Memory
- Log entries capped at 500 items (LogStore)
- Activity events capped at 20 items (AppModel)
- Voice log capped at 200 items (AppModel)
- Patchy debug log capped in-memory (AppModel)

### Network
- Single WebSocket connection per bot instance
- REST API calls throttled by Discord (rate limiting)
- Heartbeat every ~41 seconds

### Concurrency
- Gateway receive loop runs continuously in Task
- Heartbeat in separate Task
- All rule evaluation on MainActor
- File I/O isolated in actors
- UpdateEngine checker/store APIs are actor-based for async-safe cache access

## Error Handling

### Gateway Errors
- Reconnect on WebSocket errors (op 7)
- Re-identify on invalid session (op 9)
- Graceful disconnect on user stop

### Rule Execution
- Silent failure on REST errors (no UI disruption)
- Logs errors to stats.errors counter

### File I/O
- Returns defaults on load failure
- Logs but doesn't crash on save failure

## Security Notes

### Token Storage
- Stored in Keychain via `KeychainHelper` (migrated automatically from any legacy disk-stored token on first load)
- Settings JSON on disk always has token cleared (`token = ""`) — only Keychain holds the live value
- User responsible for token security

### Permissions
- Requires bot token with appropriate intents (37,767)
- No OAuth flow (manual token entry)

---

**Last Updated:** 2026-03-05  
**Maintained By:** AI Assistant  
**Purpose:** Context for code modifications and architectural decisions
