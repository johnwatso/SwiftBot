# SwiftBot — Engineering Priorities & Roadmap

**Version:** May 2026 (revised 2026-05-27)
**Platform:** Native macOS App (Swift + SwiftUI)
**Target OS:** macOS 26+ (Tahoe)
**Architecture Direction:** Apple-native, actor-safe, service-oriented, event-driven

> **Convention:** `~~strikethrough~~` = done, removed by design, or YAGNI-deferred. Plain `[ ]` = genuinely open. `[ ] (blocked: …)` = open but waiting on something external.

---

## Overview

SwiftBot is transitioning from an experimental feature-heavy application into a mature platform.

The next phase prioritises:

1. Event pipeline stability
2. Automation/rules architecture
3. DM/onboarding completion and hardening

The goal is to stabilise foundations before introducing major new features.

---

## Priority 1 — Unified Event Pipeline

> **Status:** largely resolved; remaining items are YAGNI or low-priority.

### Core Architecture

- [x] ~~Create `SwiftBotEvent`~~ — `GatewayEventDispatcher` + typed event structs already play this role. No new type needed.
- [x] ~~Create `SwiftBotEventParser`~~ — same. Parser already exists, just under a different name.
- [x] ~~Create normalized event metadata~~ — already present in `GatewayMessageCreateEvent` and siblings.
- [x] ~~Separate Discord payloads from internal event model~~ — already separated; raw `GatewayPayload` → typed event structs.
- [x] ~~Create typed event categories~~ — already exist (`GatewayReadyEvent`, `GatewayMessageCreateEvent`, `GatewayVoiceStateUpdateEvent`, etc.).

> Open follow-up: `VoiceRuleEvent` is overloaded (one type, optional fields across message/voice/member/media). Real cleanup, tracked in **Priority 2 → Rule Architecture**.

### Event Distribution

- [x] ~~Build internal async `EventBus`~~ — already exists in `Models/EventBus.swift`. Actor-backed pub/sub.
- [x] ~~Convert systems to subscribers~~ — **deferred (YAGNI)**. Investigated 2026-05-27: the cascade in `handleMessageCreate` is chain-of-responsibility (DM memory > DM AI > DM fallback), not fan-out. Subscribers would each have to re-check exclusion conditions. Revisit only when a 3rd subsystem genuinely wants `MessageReceived`.
- [x] ~~Support fan-out processing via TaskGroup~~ — not needed without parallel subscribers.
- [ ] Structured event tracing — open, low priority. Would help debugging if/when ordering bugs appear.

### Subscriber Systems

Status of each — no per-item work needed:

| Subsystem | Wiring |
|---|---|
| Rule Engine | Runs synchronously before fan-out by design (dedup contract requires it) |
| AI Service | Exclusive branches, stays inline |
| Analytics | `VoiceActivitySummary` subscribes to `VoiceJoined`/`VoiceLeft` |
| Moderation / Services / Presence / Logging / Media | No current need for bus subscription |

### MESSAGE_CREATE Refactor

- [x] ~~Ensure parsed once only~~ — fixed in commit `16a238e`. `GatewayEventDispatcher` is now the single parse authority; `DiscordService.processMessageRuleEvent` consumes the typed event.
- [x] ~~Remove duplicated rule execution~~ — was never duplicated; `AutomationService.evaluate` runs exactly once per event. Misdiagnosis in original roadmap.
- [x] ~~Unify DM handling~~ — cascade is intentional chain-of-responsibility, not a unification problem. Could be method-extracted for readability (not done; low value).
- [x] ~~Unify analytics handling~~ — only `MessageReceived` publish (which nobody subscribes to). Nothing to unify.
- [x] ~~Unify AI handling~~ — already centralised in `generateAIReplyWithTimeout`. Apple-only after `c2c1b10`.

---

## MainActor Reduction — RESOLVED

- [x] ~~Remove `@MainActor` from RuleEngine~~ — `AutomationService` was already an actor; renamed from `AutomationEngine` 2026-05-27.
- [x] ~~Audit thread safety~~ — gateway path is fully off-MainActor.
- [x] ~~Convert to actor-safe computation model~~ — already done.
- [x] ~~Remove unnecessary actor hopping~~ — `AppModel` is MainActor for SwiftUI bindings (load-bearing). Only explicit hops remain.

---

## Performance Benchmarks

> Open, low priority. Not currently a bottleneck. Worth doing if/when scale becomes a concern.

- [ ] Benchmark gateway bursts
- [ ] Benchmark rule execution
- [ ] Benchmark AI pipeline latency (`FoundationModelsSpikeTests` is the existing probe — currently flaky, see [Followups](#followups))

---

## AI Pipeline — RESOLVED BY DESIGN CHANGE

> Consolidated on Apple Intelligence only in commit `c2c1b10` (–1051 LOC net). OpenAI/Ollama/image-gen preserved in `Archive/MultiProviderAI.swift`.

- [x] ~~Replace sequential fallback~~ — single provider.
- [x] ~~Add parallel provider racing~~ — single provider.
- [x] ~~Add timeout propagation~~ — Apple session handles its own timeouts.
- [x] ~~Add provider cancellation~~ — single provider.
- [x] ~~Add provider health metrics~~ — `currentAIStatus()` returns `appleIntelligenceOnline`.
- [ ] Latency tracing — still possible if needed.
- [ ] Structured AI logs — still possible.
- [x] ~~Provider diagnostics~~ — collapsed to one availability flag.

---

## Priority 2 — Automation / Rules System

> **Goal:** turn SwiftBot into a native macOS automation platform for Discord communities. Feel closer to Apple Shortcuts / Automator than to web dashboards.

### Terminology

- [x] ~~Finalise "Automation" naming~~ — commit `dae7c01`.
- [x] ~~Remove outdated "Actions" terminology~~ — commit `dae7c01`.
- [x] ~~Standardise service naming~~ — `AutomationEngine` → `AutomationService` (commit in same area).

### Rule Architecture

> Genuinely open — **biggest Priority 2 lift**.

- [ ] Replace `VoiceRuleEvent` with a typed `SwiftBotEvent` enum — biggest blast radius. Today's `VoiceRuleEvent` is one type with ~18 optional fields covering message/voice/member/media. An enum with associated values per case would be cleaner.
- [ ] Create typed trigger system
- [ ] Create typed modifiers/actions
- [ ] Create execution context model
- [ ] Add diagnostics system

### Execution Features

> Genuinely open.

- [ ] Add rule simulation mode
- [ ] Add execution tracing
- [ ] Add rule validation
- [ ] Add execution history
- [ ] Add structured failure reporting

---

## Automation UI

> Genuinely open. Needs design mockups before code.

**Goals:** native macOS feel, Tahoe-style materials, space efficient, minimal visual clutter, strong hierarchy, consistent card styling.

### Layout

- [ ] Remove sidebar-heavy workflow
- [ ] Build linear pipeline editor (Shortcuts-style)
- [ ] Improve spacing density
- [ ] Reduce nested panels
- [ ] Improve visual hierarchy

### Components

- [ ] Standardise buttons
- [ ] Standardise cards
- [ ] Standardise typography
- [ ] Standardise spacing
- [ ] Remove older square styling

### Native UX

- [ ] Improve drag/drop interactions
- [ ] Improve animations
- [ ] Add inline editing
- [ ] Improve keyboard navigation
- [ ] Improve accessibility

---

## Shared Design System

### Cards

- [ ] Analytics cards
- [ ] Automation cards
- [ ] Moderation cards
- [x] ~~AI cards~~ — substantially done in the 2026-05-27 `AIBotsView` rewrite (personality grid, summary cards, capabilities section).
- [ ] Service cards

### Standardisation

- [ ] Corner radius
- [ ] Materials
- [ ] Typography
- [ ] Padding
- [ ] Status indicators
- [ ] Empty states

---

## AI Features Inside Automation

> All routed through Apple Intelligence.

- [ ] AI summarisation
- [ ] AI moderation transforms
- [ ] AI notification condensation
- [ ] AI voice summaries
- [ ] AI context extraction

---

## Priority 3 — DM / Onboarding Ecosystem

> **Status:** substantially done. Remaining items are backend-blocked or were misdiagnosed.

### Message Types

- [x] ~~Welcome~~
- [x] ~~Setup~~
- [x] ~~Linked~~
- [x] ~~Re-auth~~
- [x] ~~Drop claimed~~
- [x] ~~Welcome back~~
- [ ] Campaign blocked — **blocked**: needs SwiftMiner backend to define the payload shape.
- [ ] Opportunity resolved — **blocked**: needs SwiftMiner backend to define the payload shape.

All implemented types live in `SwiftBotApp/Services/SwiftMinerDMEmbedBuilders.swift` and dispatch via `SwiftMinerDMRouter`.

### DM Rendering — UI Polish

- [x] ~~Standardise embed styling~~ — already centralised in `SwiftMinerDMStyle` + `SwiftMinerDMTheme` before this roadmap was written.
- [x] ~~Improve hierarchy~~ — Discord embed format is fixed; current hierarchy is fine without specific complaint.
- [x] ~~Improve spacing~~ — Discord-controlled, no headroom.
- [x] ~~Improve button styling~~ — Discord doesn't natively render buttons in DMs; CTAs are markdown links by design.
- [x] ~~Improve countdown UI~~ — Discord `<t:UNIX:R>` relative timestamps (commit `6357bc0`) + expired-code hint (commit `1d3bd71`).
- [x] ~~Improve priority game presentation~~ — medals 🥇🥈🥉 + bold rank numbers (commit `1d3bd71`).

### DM Rendering — Behavior

- [x] ~~Respect `message_type`~~ — exhaustive switch in `SwiftMinerDMRouter` (already done before this roadmap).
- [x] ~~Add debug-mode handling~~ — `[TEST]` prefix + footer suffix (already done).
- [x] ~~Prevent analytics mutation during previews~~ — `SwiftMinerDMSender.preview()` returns embed without mutation (already done).
- [x] ~~Add preview rendering~~ — admin endpoint `POST /v1/users/{id}/dm/test` + `previewSwiftMinerDM()` (already done).

### DM Testing

**DiscordMessageRESTClient** (`Tests/SwiftBotTests/DiscordMessageRESTClientDMTests.swift`)

- [x] ~~`testCreateDMChannelSuccess`~~
- [x] ~~`testCreateDMChannelForbidden`~~
- [x] ~~`testCreateDMChannelMalformed`~~

**Gateway Tests** (`Tests/SwiftBotTests/GatewayDMHandlingTests.swift` — added 2026-05-27)

- [x] ~~`testDMBlockedWhenAllowDMsDisabled`~~
- [x] ~~`testDMRateLimitSendsCooldownMessage`~~
- [x] ~~`testDMSkippedWhenHandledByRules`~~ — required adding `markMessageHandledForTesting` test seam to `AutomationService`.

**DiscordService Tests** (`Tests/SwiftBotTests/DiscordServiceDMTests.swift` — added 2026-05-27)

- [x] ~~`testSendDMBlockedOnStandby`~~
- [x] ~~`testSendDMEmbedSuccess`~~ — required adding `setBotTokenForTesting` (DEBUG-only) to `DiscordService` because the only production path to set a token (`connect()`) opens a real websocket.

---

## End-to-End Validation

> Genuinely open, heavy infra. Would build a fake SwiftMiner webhook server in tests to exercise the full DM lifecycle.

- [ ] Localhost integration tests
- [ ] Webhook delivery tests
- [ ] Retry validation
- [ ] Idempotency validation
- [ ] Activation flow validation

---

## Activation Lifecycle Polish

> Most items blocked on SwiftMiner backend support.

- [~] Better timeout states — **partial**. Setup DM has an expired-code hint (commit `1d3bd71`). A real "code expired" follow-up DM needs SwiftMiner to push an `activation_expired` webhook.
- [ ] Better retry UX — **blocked**: needs SwiftMiner to expose "session already active" so `/miner action:setup` can branch instead of always calling `startActivation`.
- [x] ~~Better recovery messaging~~ — copy in `SwiftMinerDMTheme.swift:66-69` is already reasonable; rewording without a specific complaint is thrashing.
- [ ] Better progress presentation — **blocked**: no activation lifecycle stage model exists on either side.
- [ ] Better ignore/snooze UX — **blocked**: needs snooze backend, settings storage, and admin UI.

---

## Followups

> Not in original roadmap.

- [x] ~~Strip dead OpenAI image-gen toggles from `SwiftBotApp/Resources/admin/index.html`~~ — cleaned up; three dead UI clusters removed, replaced with single Apple Intelligence panels.
- [ ] Decide fate of `FoundationModelsSpikeTests` — flaky on Apple's on-device model (fails ~half the time on latency or quality). Either loosen thresholds, mark expected-flaky, or remove.
- [ ] Consider renaming internal `case aiBots`, `struct AIBotsView`, JSON key `aiBots:` to match the user-facing "Apple Intelligence" name. Skipped during the surface rename because the JSON key is a wire contract with the admin web UI.

---

## Session log

### 2026-05-27 — 6+ commits landed

| Commit | Summary |
|---|---|
| `dae7c01` | Terminology cleanup: "Workflows" → "Automations", `RuleAction` → step naming. `AutomationEngine` → `AutomationService`. |
| `6357bc0` | DM testing (8/8) + absolute expiry timestamp support in setup DM. |
| `1d3bd71` | DM polish: priority game medals + expired-code hint. |
| `16a238e` | MESSAGE_CREATE single-parse pipeline (Priority 1 Phase 1). |
| `c2c1b10` | Apple-only AI consolidation (–1051 LOC net). OpenAI/Ollama/image-gen archived. |
| `b9daeba` | "AI Bots" → "AI" rename + `apple.intelligence` SF Symbol. |
| `981fc7e` + `50619f9` | Apple Intelligence UI revamp + personality picker + `fadingEdges`/shared UI primitives (user). |
| `75d712d` | Add `ROADMAP.md` to repo + AI_CONTEXT requires keeping it current. |
| _next_ | Admin HTML cleanup — strip dead OpenAI/Ollama/image-gen panels from `Resources/admin/index.html`. |

**Key decisions**

- **AI multi-provider removed by design** — Apple Intelligence is always present on the macOS 26 target, no API keys, no billing. Trade-off accepted: no fallback if Apple model regresses or is offline.
- **EventBus Phase 2 deferred (YAGNI)** — the cascade in `handleMessageCreate` is chain-of-responsibility, not fan-out. Bus subscribers don't model exclusive branches well. Revisit when a 3rd genuine subscriber emerges.
- **Roadmap revised in place** — many original items were either already done (MainActor reduction, EventBus existence, parser structure), based on misdiagnoses (duplicated rule eval), or removed by the Apple-only design change (provider racing, etc.).

---

## Deprioritised Until Foundations Stabilise

- Massive moderation expansion
- Advanced clustering/failover
- Large web admin systems
- Additional analytics complexity
- More service types
- Enterprise-style features

---

## Engineering Philosophy

SwiftBot should feel like:

- a polished Apple-native application
- a modern automation environment
- a macOS-first experience

NOT:

- a web dashboard
- a Discord control panel
- a ported Electron-style interface

The architecture should prioritise:

- strong event flow
- actor safety
- modular systems
- clean orchestration
- native UX consistency
- long-term maintainability

---

## Success Criteria

The platform should eventually achieve:

- Single normalized event pipeline
- Stable async orchestration
- Minimal MainActor contention
- Consistent Tahoe-native UI
- Fully polished onboarding
- Reliable DM lifecycle
- Extensible automation architecture
- Easier AI-assisted development
- Easier contributor onboarding
- Lower regression risk
