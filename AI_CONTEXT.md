# SwiftBot — AI Agent Context
> **START HERE.** Read this file before making any changes to the SwiftBot codebase.
> This is the single authoritative reference for AI agents (Claude, Gemini, Kimi, Codex).
> See also: `ARCHITECTURE.md` (technical deep-dive), `AI_GUIDE.md` (common tasks & patterns).

---

## 1. Project Overview

SwiftBot is a **native macOS Discord bot manager** built entirely with Swift and SwiftUI.

| Property | Value |
|----------|-------|
| Platform | macOS 26+ |
| Language | Swift with Concurrency (async/await, actors) |
| Framework | SwiftUI — Apple-platform-first, no web frameworks |
| Design Language | Apple Human Interface Guidelines — Liquid Glass / modern macOS |
| Architecture | MVVM + actor isolation + EventBus pub/sub |
| Build System | Xcode + XcodeGen for the app, SwiftPM only for `Sources/UpdateEngine` |

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
| `AppModel+Commands.swift` | Slash command handlers |
| `AppModel+Gateway.swift` | Gateway event parsing and dispatch |
| `AppModel+AI.swift` | AI provider routing and response generation |
| `DiscordService.swift` | Discord WebSocket gateway + REST API actor. Rule action execution. AI replies. Wiki lookup. |
| `SwiftBotApp/Models/` | Directory containing modular data models: `Automations.swift` (rules), `BotSettings.swift` (config), `EventBus.swift` (pub/sub), `ClusterModels.swift` (mesh). |
| `ClusterCoordinator.swift` | SwiftMesh cluster: leader election, health monitoring, replication, failover |
| `Persistence.swift` | ConfigStore, RuleConfigStore, DiscordCacheStore, SwiftMeshConfigStore, MeshCursorStore (all actors). Keychain for secrets. |
| `AdminWebServer.swift` | HTTP REST API for web admin UI. Discord OAuth. |
| `AutomationsView.swift` | The Automations/Moderation tab: Rule list, template catalog, Natural Language drafting box. |
| `AutomationRuleEditor.swift` | Sheet-style rule editor: configure trigger, polymorphic filters, and sequential steps. |
| `EmptyRuleOnboardingView.swift` | Ghost placeholder shown when a rule has no steps yet |
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

Read `DESIGN.md` before making UI changes. It captures the SwiftMesh visual baseline that should guide SwiftBot styling going forward.

All UI in SwiftBot **must** follow:

1. **Apple Human Interface Guidelines** — always, without exception
2. **SwiftUI only** — no AppKit views unless unavoidable (use `NSViewRepresentable`)
3. **System Settings layout style** — sidebar navigation, split-pane layouts where appropriate, material backgrounds
4. **Liquid Glass / modern macOS design language** — `.ultraThinMaterial`, `.thinMaterial`, semantic system colors
5. **No web-style patterns** — no CSS-like layouts, no custom scrollbars, no card grids
6. **No external UI frameworks** — zero SwiftPM UI dependencies

**Typography:** System fonts only (`.headline`, `.subheadline`, `.caption`, `.title2`, `.title3`)
**Color:** Semantic system colors (`.primary`, `.secondary`, `.accentColor`) — avoid hard-coded hex
**Spacing:** 16–20pt horizontal padding, 8–16pt vertical, generous 16–24pt between sections

---

## 6. Rule Builder System

### Automations Tab View Layout

```
AutomationsView (tab content panel)
├── Read-only Banner (shown only on Failover nodes)
└── ScrollView
    ├── Metrics Row (Grid of summary cards: Rules, Enabled, Triggers, Apple Intelligence status)
    ├── Natural Language drafting section (TextField box + "Create with AI" button)
    ├── Template Catalog (Horizontal ScrollView of preset cards like welcome templates)
    └── Rules List section
        ├── Enabled/Disabled toggle, category symbols/tints
        └── Action buttons: Add rule button -> opens sheet with default trigger/step
```

### Sheet-Style Rule Editor View Layout

```
AutomationRuleEditor (modal sheet)
├── Hero Header (displays rule category icon, Edit/New label, and context-dependent description)
├── ScrollView (form sections enclosed in standard Apple-design cards)
│   ├── Form Section: Name (TextField name + Enabled Toggle switch)
│   ├── Form Section: WHEN this happens (Trigger kind Picker + commandName field if slashCommand)
│   ├── Form Section: IF these conditions match (Flat card list of active polymorphic filters + Add condition Menu)
│   └── Form Section: THEN do these steps (Step card list + Add step Menu with categorized presets)
└── Footer Bar (Cancel button + Save/Create button)
```

### Validations & Custom Inputs

- **Validation:** Save/Create button is gated by rule name non-emptiness and presence of at least 1 action step (`rule.steps.isEmpty == false`).
- **Autocompletes:** Text input areas for message content, AI prompts, log text, or webhooks use `VariableAutocompleteField` providing inline suggestions for context tokens (e.g. `{username}`, `{channelName}`).

---

## 7. Development Constraints

### Always Do

- ✅ Swift Concurrency (`async/await`, `actor`, `@MainActor`, `Task`)
- ✅ Keychain for ALL secrets — never write to disk
- ✅ Treat `project.yml` as the source of truth for app project settings
- ✅ Run `xcodegen` after editing `project.yml`
- ✅ `.id(selectionID)` on all list-detail views to prevent SwiftUI state leakage
- ✅ Look up current selection INSIDE binding closures — never capture IDs at creation time
- ✅ `await MainActor.run {}` when updating `@Published` from background actors
- ✅ Use `embedJSON` from UpdateEngine directly for Patchy Discord notifications
- ✅ Persist Discord metadata cache on disconnect (offline config editing must work)

### Never Do

- ❌ Pre-populate new rules with default trigger or actions
- ❌ Change `Models.swift` structure without cross-agent approval
- ❌ Add new SwiftPM dependencies without explicit justification
- ❌ Convert the main app target into a Swift package or add a repo-root `Package.swift`
- ❌ Break existing UI layouts or split-pane behaviors
- ❌ Send Discord output from Standby or Worker nodes
- ❌ Use `#if DEBUG` to gate production logic
- ❌ Call `test*` methods from production code paths
- ❌ Key mesh cursors by endpoint URL (use `nodeName`)
- ❌ Bypass `DiscordService.outputAllowed` gate
- ❌ Manually reconstruct Patchy Discord embeds

---

## 8. Agent Coordination

If multiple agents are working in parallel, coordinate before editing the same files and prefer clear ownership by area for the duration of the task.

This file does not assign permanent file owners. Treat any historical ownership notes elsewhere as advisory, not authoritative.

---

## 9. Data Types Quick Reference

### Automations.Rule
```swift
struct Rule: Codable, Identifiable, Hashable, Sendable, Validatable {
    var id: String
    var name: String
    var enabled: Bool
    var category: Category
    var trigger: Trigger
    var filterLogic: FilterLogic
    var filters: [Filter]
    var steps: [Step]
}
```

### TriggerKind (10 cases)
`userJoinedVoice` · `userLeftVoice` · `userMovedVoice` · `messageCreated` · `memberJoined` · `memberLeft` · `reactionAdded` · `slashCommand` · `mediaAdded`

### FilterKind (17 cases)
- **Scope:** `inChannel`, `directMessage`
- **User:** `userIsOneOf`, `userHasAnyRole`, `userHasAllRoles`, `userHasNoneOfRoles`
- **Message Content:** `messageContains`, `messageContainsAny`, `messageEquals`, `messageDoesNotContain`, `messageMatchesRegex`, `messageIsReply`
- **Author:** `fromBot`
- **Voice:** `minVoiceDurationSeconds`
- **Reaction:** `reactionEmoji`
- **Media:** `mediaSource`

### StepKind (6 cases)
`sendMessage` · `modifyMember` · `modifyMessage` · `log` · `webhook` · `delay`

### MemberOp (5 cases)
`addRole` · `removeRole` · `timeout` · `kick` · `moveVoice`

### MessageOp (2 cases)
`delete` · `react`

### Automations.Variable (12 tokens)
`{username}` `{userId}` `{userMention}` `{channelName}` `{channelId}` `{guildName}` `{guildId}` `{message}` `{messageId}` `{duration}` `{mediaFile}` `{mediaSource}`

---

## 10. Before Marking Any Task Complete

- [ ] Build succeeds — 0 errors, 0 new warnings
- [ ] Modified feature works as expected
- [ ] No regressions in unrelated features
- [ ] If `project.yml` changed, regenerate with `xcodegen`
- [ ] If versioning or release metadata changed, verify `project.yml`, `SwiftBot.xcodeproj/project.pbxproj`, and `docs/` stay aligned

---

*Last updated: 2026-05-07*
*See `ARCHITECTURE.md` for full technical detail · `AI_GUIDE.md` for common task recipes*
