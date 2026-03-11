# SwiftBot — AI Agent Context
> **START HERE.** Read this file before making any changes to the SwiftBot codebase.
> This is the single authoritative reference for AI agents (Claude, Gemini, Kimi, Codex).
> See also: `ARCHITECTURE.md` (technical deep-dive), `AI_GUIDE.md` (common tasks & patterns).

---

## 1. Project Overview

SwiftBot is a **native macOS Discord bot manager** built entirely with Swift and SwiftUI.

| Property | Value |
|----------|-------|
| Platform | macOS 13+ |
| Language | Swift with Concurrency (async/await, actors) |
| Framework | SwiftUI — Apple-platform-first, no web frameworks |
| Design Language | Apple Human Interface Guidelines — Liquid Glass / modern macOS |
| Architecture | MVVM + actor isolation + EventBus pub/sub |
| Build System | Xcode + Swift Package Manager |

**What it does:** Connects to Discord via WebSocket gateway, monitors server events, and executes automated rules when events match. Also supports AI replies, wiki lookups, update monitoring (Patchy), multi-node cluster failover (SwiftMesh), and a web-based admin UI.

**Philosophy:** Apple-platform-first. Native macOS only. No external UI frameworks. SwiftUI throughout. Visual rule builder inspired by Apple Shortcuts.

---

## 2. Core Architecture

### Event Pipeline

```
Discord Gateway WebSocket
    ↓
DiscordService.receiveLoop()
    ↓
DiscordService.handleGatewayPayload()
    ↓
AppModel.handlePayload()
    ├── handleMessageCreate()    → executeCommand() / rule evaluation
    ├── handleVoiceStateUpdate() → EventBus.publish(VoiceJoined/Left)
    ├── handleReady()
    └── handleGuildCreate()
    ↓
EventBus → Plugins (WeeklySummaryPlugin, etc.)
    ↓
RuleEngine.evaluateRules(event)   [MainActor]
    ↓
Rule.processedActions   (runtime migration of legacy bool toggles → modifier blocks)
    ↓
Pipeline: Trigger → Filters → Modifiers → Actions
    ↓
DiscordService.execute(action, for: event, context: &context)
    ├── Update PipelineContext (modifiers / AI)
    ├── sendMessage()
    └── Discord REST API calls (roles, moderation, etc.)
    ↓
Discord REST API (https://discord.com/api/v10)
```

### Block-Based Rule Pipeline

Rules execute in a strict linear sequence:

```
START
  ↓
[Trigger]      — What fires the rule (optional on new/unconfigured rules)
  ↓
[Filters]      — 0+ conditions: server, channel, user, duration, role
  ↓
[Modifiers]    — 0+ message modifiers: replyToTrigger, mentionUser, sendToDM, sendToChannel
  ↓
[Actions]      — 1+ outputs: sendMessage, addRole, kick, AI generation, etc.
  ↓
END
```

**Critical:** `rule.trigger == nil` and `rule.actions == []` are **valid, expected states** for new rules. Never pre-populate. Never assume a rule has content.

### PipelineContext

Mutable context threaded through execution. Modifiers set fields; Actions read them:

```swift
struct PipelineContext {
    var aiResponse: String?           // set by generateAIResponse block
    var targetChannelId: String?      // override by sendToChannel modifier
    var mentionUser: Bool = true      // set by mentionUser modifier
    var replyToTriggerMessage: Bool   // set by replyToTrigger modifier
    var mentionRole: String?          // set by mentionRole modifier
    var isDirectMessage: Bool         // set by sendToDM modifier
}
```

---

## 3. Key Services

| File | Purpose |
|------|---------|
| `AppModel.swift` | Primary app state `@MainActor ObservableObject`. Bot lifecycle, settings, gateway coordination, rule engine orchestration, Patchy scheduler, plugin management. |
| `AppModel+Commands.swift` | Slash and prefix command handlers |
| `AppModel+Gateway.swift` | Gateway event parsing and dispatch |
| `AppModel+AI.swift` | AI provider routing and response generation |
| `DiscordService.swift` | Discord WebSocket gateway + REST API actor. Rule action execution. AI replies. Wiki lookup. |
| `Models.swift` | All data types: Rule, RuleAction, Condition, TriggerType, ActionType, BlockCategory, ContextVariable, EventBus, RuleEngine, RuleStore, BotSettings, GuildSettings. |
| `ClusterCoordinator.swift` | SwiftMesh cluster: leader election, health monitoring, replication, failover |
| `Persistence.swift` | ConfigStore, RuleConfigStore, DiscordCacheStore, SwiftMeshConfigStore, MeshCursorStore (all actors). Keychain for secrets. |
| `AdminWebServer.swift` | HTTP REST API for web admin UI. Discord OAuth. |
| `VoiceActionsView.swift` | 3-pane rule editor UI (rule list + block library + canvas). **Claude's primary file.** |
| `VoiceRuleListView.swift` | Rule list panel with empty state onboarding |
| `EmptyRuleOnboardingView.swift` | Ghost placeholder shown when a rule has no blocks yet |
| `Sources/UpdateEngine` | Standalone Swift package: vendor-agnostic update detection used by Patchy |

### Storage

| Data | Path |
|------|------|
| Settings (non-sensitive) | `~/Library/Application Support/SwiftBot/settings.json` |
| Rules | `~/Library/Application Support/SwiftBot/rules.json` |
| Discord metadata cache | `~/Library/Application Support/SwiftBot/discord-cache.json` |
| SwiftMesh config | `~/Library/Application Support/SwiftBot/swiftmesh-config.json` |
| Mesh replication cursors | `~/Library/Application Support/SwiftBot/mesh-cursors.json` |
| **All secrets** | **macOS Keychain only** — never written to disk |

### Keychain Accounts

`"discord-token"` · `"openai-api-key"` · `"cluster-shared-secret"` · `"admin-discord-client-secret"` · `"admin-web-cloudflare-token"`

---

## 4. SwiftMesh Cluster Rules

### Discord Output Gate — STRICTLY ENFORCED

| Node Mode | May Send Discord Messages |
|-----------|--------------------------|
| **Standalone** | ✅ YES |
| **Leader (Primary)** | ✅ YES |
| **Standby** | ❌ NO — monitoring only, may promote |
| **Worker** | ❌ NO — processing only, never sends |

**All Discord output is gated through `DiscordService.outputAllowed`. This gate must never be bypassed.**

### Cluster Safety Rules

- **Term validation:** All `/v1/mesh/sync/*` routes MUST reject if incoming `leaderTerm` < local `leaderTerm` → `403 Forbidden`
- **Monotonic cursors:** Replication cursors only advance forward. Never regress.
- **Startup split-brain reconciliation:** A node configured as leader probes `/cluster/status` and demotes to standby if an active remote leader is found.
- **Auth is fail-closed:** All non-`/health` mesh routes require valid HMAC when `sharedSecret` is set.
- **Cursor keying:** Use stable `nodeName`, NOT endpoint URL. URL changes during failover must not orphan replication state.
- **Promotion side-effects:** `promoteToLeader()` intentionally wipes `replicationCursors` — correct behavior, not a bug.
- **Standby must run HTTP server:** Standby nodes must have their HTTP server active to receive sync pushes.

### Mesh Phases (All Complete ✅)
Phase 1: failover + term safety · Phase 2: conversation sync + pagination + cursors · Phase 2.1: nodeName cursor keying · Phase 3: wiki cache replication

---

## 5. UI Design Rules

All UI in SwiftBot **must** follow:

1. **Apple Human Interface Guidelines** — always, without exception
2. **SwiftUI only** — no AppKit views unless unavoidable (use `NSViewRepresentable`)
3. **System Settings layout style** — sidebar navigation, HSplitView, material backgrounds
4. **Liquid Glass / modern macOS design language** — `.ultraThinMaterial`, `.thinMaterial`, semantic system colors
5. **No web-style patterns** — no CSS-like layouts, no custom scrollbars, no card grids
6. **No external UI frameworks** — zero SwiftPM UI dependencies

**Typography:** System fonts only (`.headline`, `.subheadline`, `.caption`, `.title2`, `.title3`)
**Color:** Semantic system colors (`.primary`, `.secondary`, `.accentColor`) — avoid hard-coded hex
**Spacing:** 16–20pt horizontal padding, 8–16pt vertical, generous 16–24pt between sections

---

## 6. Rule Builder System

### 3-Pane View Architecture

```
VoiceWorkspaceView (HSplitView)
├── RuleListView (220–320px)             — VoiceRuleListView.swift
│   ├── isLoading → ProgressView()
│   ├── rules.isEmpty → RuleListEmptyStateView ("No Rules Yet")
│   └── normal → RuleRowView list
└── RuleEditorView                       — VoiceActionsView.swift
    ├── Block Library pane (250–300px)
    │   └── RuleBuilderLibraryView (ScrollViewReader + ScrollView)
    │       ├── [Triggers]  .id("library-triggers")
    │       ├── [Filters]
    │       ├── [Message Modifiers]
    │       ├── [AI Blocks]
    │       ├── [Actions]
    │       ├── [Moderation]
    │       └── [Utilities]
    └── Canvas pane
        ├── Rule name TextField
        ├── ValidationBannerView (errors/warnings)
        └── if rule.isEmptyRule
            → EmptyRuleOnboardingView (ghost placeholder, pulsing arrow)
            else
            → 4-section pipeline canvas
```

### New Rule Onboarding Flow

```
1. ruleStore.addNewRule() → Rule.empty() { trigger: nil, actions: [] }
2. RuleListEmptyStateView → "Create First Rule" button
3. RuleEditorView.isEmptyRule == true → EmptyRuleOnboardingView ghost card
4. .onAppear: if !hasSeenRuleOnboarding → FirstRuleOnboardingCard sheet
   ├── "Create Example Rule" → hello world rule, marks onboarding seen
   └── "Start Empty" → guidedStep = .trigger (amber highlight on Trigger section)
5. User adds trigger → guidedStep = .action (mint highlight on Action section)
6. User adds action → guidedStep = .none, canvas shows normally
```

### Key Rule Computed Properties

```swift
var isEmptyRule: Bool          // trigger == nil && conditions.isEmpty && actions.isEmpty
var triggerSummary: String     // "No trigger set" if nil
var validationIssues: [ValidationIssue]
var processedActions: [RuleAction]   // runtime migration: legacy booleans → modifier blocks
```

---

## 7. Development Constraints

### Always Do

- ✅ Swift Concurrency (`async/await`, `actor`, `@MainActor`, `Task`)
- ✅ Keychain for ALL secrets — never write to disk
- ✅ Add new `.swift` files to `project.pbxproj` (4 entries: PBXFileReference, PBXBuildFile, PBXGroup, PBXSourcesBuildPhase)
- ✅ `.id(selectionID)` on all list-detail views to prevent SwiftUI state leakage
- ✅ Look up current selection INSIDE binding closures — never capture IDs at creation time
- ✅ `await MainActor.run {}` when updating `@Published` from background actors
- ✅ Use `embedJSON` from UpdateEngine directly for Patchy Discord notifications
- ✅ Persist Discord metadata cache on disconnect (offline config editing must work)

### Never Do

- ❌ Pre-populate new rules with default trigger or actions
- ❌ Change `Models.swift` structure without cross-agent approval
- ❌ Add new SwiftPM dependencies without explicit justification
- ❌ Break existing UI layouts or SplitView behaviors
- ❌ Send Discord output from Standby or Worker nodes
- ❌ Use `#if DEBUG` to gate production logic
- ❌ Call `test*` methods from production code paths
- ❌ Key mesh cursors by endpoint URL (use `nodeName`)
- ❌ Bypass `DiscordService.outputAllowed` gate
- ❌ Manually reconstruct Patchy Discord embeds

---

## 8. Multi-Agent File Ownership

When multiple agents work on SwiftBot simultaneously, respect file ownership:

| File | Owner |
|------|-------|
| `VoiceActionsView.swift` | **claude** |
| `VoiceRuleListView.swift` | **claude** |
| `EmptyRuleOnboardingView.swift` | **claude** |
| `Models.swift` | **kimi** |
| `AppModel.swift` | **gemini** |
| `DiscordService.swift` | **gemini** |

**Rule:** Post in `#swiftbotdev` before editing another agent's file. Coordinate task splits before starting any work.

---

## 9. Data Types Quick Reference

### Rule
```swift
struct Rule: Identifiable, Codable, Equatable {
    var trigger: TriggerType?        // nil = unconfigured (valid state)
    var conditions: [Condition] = [] // filter blocks
    var modifiers: [RuleAction] = [] // modifier blocks
    var actions: [RuleAction] = []   // action blocks (empty = valid state)
    var isEnabled: Bool = true
}
static func empty() -> Rule { Rule(trigger: nil, actions: []) }
```

### TriggerType (7 cases)
`userJoinedVoice` · `userLeftVoice` · `userMovedVoice` · `messageContains` · `memberJoined` · `reactionAdded` · `slashCommand`

### ActionType by Category
- **Messaging:** `sendMessage`, `replyToMessage`, `sendDM`, `deleteMessage`, `addReaction`
- **Modifiers:** `replyToTrigger`, `mentionUser`, `mentionRole`, `sendToDM`, `sendToChannel`
- **AI:** `generateAIResponse` → stores output in `{ai.response}`
- **Moderation:** `addRole`, `removeRole`, `timeoutMember`, `kickMember`, `moveMember`
- **Utility:** `createChannel`, `webhook`, `addLogEntry`, `setStatus`, `delay`, `setVariable`, `randomChoice`

### ContextVariable (20 tokens)
`{user}` `{user.id}` `{user.name}` `{user.nickname}` `{user.mention}` `{message}` `{message.id}` `{channel}` `{channel.id}` `{channel.name}` `{guild}` `{guild.id}` `{guild.name}` `{voice.channel}` `{voice.channel.id}` `{reaction}` `{reaction.emoji}` `{duration}` `{memberCount}` `{ai.response}`

---

## 10. Before Marking Any Task Complete

- [ ] Build succeeds — 0 errors, 0 new warnings
- [ ] Modified feature works as expected
- [ ] No regressions in unrelated features
- [ ] `CHANGELOG.md` updated
- [ ] Any new `.swift` files added to `project.pbxproj`
- [ ] Posted results in `#swiftbotdev`

---

*Last updated: 2026-03-11*
*See `ARCHITECTURE.md` for full technical detail · `AI_GUIDE.md` for common task recipes*
