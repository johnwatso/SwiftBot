# Technical Architecture

This document provides a high-level overview of the DiscordBot Native application architecture for AI assistants and developers.

## Project Overview

**Type:** Native macOS Application  
**Framework:** SwiftUI  
**Language:** Swift with Concurrency (async/await, actors)  
**Platform:** macOS 13+  
**Build System:** Xcode Project + Swift Package Manager

## Core Components

### 1. Application Layer
- **File:** `DiscordBotNativeApp.swift`
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
  - On-device AI DM replies (when enabled)

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
- **Storage Location:** `~/Library/Application Support/DiscordBotNative/`
- **Files:** `settings.json`, `rules.json`
- **Class:** `LogStore` (@MainActor) - In-memory log with 500 line limit

### 6. User Interface
- **File:** `RootView.swift`
- **Main View:** `RootView` - TabView container
- **Tabs:**
  - **Overview** - Activity feed, stats, server info
  - **Server Notifier** - Rule builder (HSplitView: list + editor)
  - **Commands** - Command history log
  - **Logs** - System logs with auto-scroll
  - **Settings** - Bot token, prefix, AI settings
  - **Status** - Gateway stats, voice presence

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
DiscordBotApp.xcodeproj
└── DiscordBotApp (target)
    ├── DiscordBotNativeApp.swift (entry point)
    ├── AppModel.swift (main state)
    ├── Models.swift (data models + EventBus + plugins)
    ├── DiscordService.swift (Discord API)
    ├── Persistence.swift (storage)
    ├── RootView.swift (all UI)
    └── Resources/
        └── AppIcon.png
```

### Deprecated Files (Can Remove)
- `EventBus.swift` - Consolidated into Models.swift
- `StarterPlugin.swift` - Consolidated into Models.swift

## Testing Strategy

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

### Network
- Single WebSocket connection per bot instance
- REST API calls throttled by Discord (rate limiting)
- Heartbeat every ~41 seconds

### Concurrency
- Gateway receive loop runs continuously in Task
- Heartbeat in separate Task
- All rule evaluation on MainActor
- File I/O isolated in actors

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
- Stored in plain text in Application Support
- No keychain integration (could be improved)
- User responsible for token security

### Permissions
- Requires bot token with appropriate intents (37,767)
- No OAuth flow (manual token entry)

---

**Last Updated:** 2026-03-02  
**Maintained By:** AI Assistant  
**Purpose:** Context for code modifications and architectural decisions
