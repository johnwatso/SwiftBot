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

- [x] Replace `VoiceRuleEvent` with a typed `SwiftBotEvent` enum — completed and mapped across Gateway, AppModel, and AutomationService pipelines.
- [x] ~~Create typed trigger system~~ — completed typed trigger system with validation and range checks.
- [x] ~~Create typed modifiers/actions~~ — expanded filter kinds with messageContainsSpamLink, messageCapsPercentage, and messageMentionsCount moderation filters.
- [x] ~~Enforce execution category precedence~~ — implemented strict separating precedence where moderation rules run first, and destructive actions bypass subsequent automation rule execution.
- [x] Create execution context model — implemented detailed execution context collecting diagnostic steps and errors.
- [x] Add diagnostics system — added structured step-level throw-capture and error logging.

### Execution Features

> Genuinely open.

- [x] ~~Add rule simulation mode~~ — completed in-memory dry-run evaluation engine and interactive trace views.
- [x] ~~Add execution tracing~~ — completed step-level trace tracking with checkmarks and timelines.
- [x] ~~Add rule validation~~ — completed detailed range validation in Trigger.validate.
- [x] Add execution history — implemented capped `automationLog` persistent execution ledger of 500 entries under `AppModel` and `Persistence`.
- [x] Add structured failure reporting — automated step failure capture and diagnostic details log recording.

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

A single `StepKind.aiTransform` step covers summarisation, moderation
rewrites, notification condensation, and context extraction by prompt
design — they're all "give Apple Intelligence a prompt, store the reply."
Output flows to later steps via the `{ai_output}` template token.
Voice summaries still need separate work (no transcription infra yet).

- [x] ~~AI summarisation~~ — `aiTransform` step with a summarisation prompt.
- [x] ~~AI moderation transforms~~ — `aiTransform` with a rewrite prompt, followed by `sendMessage` using `{ai_output}`.
- [x] ~~AI notification condensation~~ — `aiTransform` on webhook content.
- [x] ~~AI voice summaries~~ — **out of scope for now**. Would require inbound Discord voice capture (no decoder/RTP-receive today, only outbound), a transcription pipeline (no `Speech` / `SpeechAnalyzer` / whisper integration), and a real consent UX surface (per-session opt-in, recording indicator, jurisdiction handling). The summarisation step itself is trivial once a transcript exists, but the three layers below it are a separate product decision.
- [x] ~~AI context extraction~~ — `aiTransform` with an extraction prompt, downstream steps reference `{ai_output}`.

> **Known follow-up:** the rule simulator's step-trace index alignment is
> already off for `log`/`delay` steps (they fire no dependency callbacks);
> `aiTransform` inherits the same pre-existing mis-report. Separate sim
> refactor task — does not affect production execution.

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

All implemented types live in `Sources/SwiftBot/Services/SwiftMinerDMEmbedBuilders.swift` and dispatch via `SwiftMinerDMRouter`.

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

- [x] Localhost integration tests — built `SwiftMinerE2EIntegrationTests` simulating loopback webhooks.
- [x] Webhook delivery tests — verified signature HMAC checks and REST projections lookup.
- [x] Retry validation — verified and covered retries and fail-overs.
- [x] Idempotency validation — verified idempotency.
- [x] Activation flow validation — fully tested user drop claim and Opportunity available flows.
- [x] Mock REST session injection — enabled injecting custom configurations/MockURLProtocols into AppModel REST pipelines to perfectly isolate test execution and prevent standby output blockage.

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

- [x] ~~Strip dead OpenAI image-gen toggles from `Sources/SwiftBot/Resources/admin/index.html`~~ — cleaned up; three dead UI clusters removed, replaced with single Apple Intelligence panels.
- [x] ~~Decide fate of `FoundationModelsSpikeTests`~~ — removed. Was a P1.1 milestone gate for the Apple Intelligence decision; that decision is made, ongoing latency/quality belongs in telemetry not a CI gate. Preserved in git history.
- [x] ~~Rename internal `case aiBots`, `struct AIBotsView`, JSON key `aiBots:`~~ — done. Swift symbols → `appleIntelligence` / `AppleIntelligenceView` / `AppleIntelligenceDashboardSummary`; AdminWeb JSON field → `appleIntelligence`; admin HTML JS updated to match. File renamed `AIBotsView.swift` → `AppleIntelligenceView.swift`.

---

## Session log

### 2026-06-29 — Recordings HLS Playback Continuation

| Commit | Summary |
|---|---|
| `_working-tree_` | Continued the recordings playback work by completing browser-side HLS attachment: the admin player now tries the generated HLS playlist in Safari or hls.js-capable browsers, falls back to the existing MP4 stream when HLS is unavailable, and preserves the lower-quality MP4 escape hatch. Regenerated the Xcode project after the RecordingsKit target changes and verified `xcodebuild -project SwiftBot.xcodeproj -scheme SwiftBot -configuration Debug test` passes. |
| `_working-tree_` | Validated the common desktop sample (`unknown_replay_2026.06.13-02.25.mp4`): it is a 15-minute 1440p H.264/AAC MP4 with `moov` after `mdat`, and AVFoundation HLS passthrough rejects audio+video segmentation for this profile. Added a fast-start remux cache so the normal MP4 fallback rewrites end-`moov` files without re-encoding; the sample remuxed in about 16 seconds and moved `moov` before `mdat`. |
| `_working-tree_` | Added periodic fast-start pre-warming to the media monitor: every monitor pass prepares a small batch of settled local MP4s in the background, independent of media-added automation rules, so common recordings are likely ready before first playback. |

### 2026-06-26 — Piper TTS, Stall Protections, & Priority Inversion Fixes

| Commit | Summary |
|---|---|
| `_working-tree_` | Refined voice picker options in VoiceView to display Apple Premium/Enhanced voices and downloaded Piper voices (identifiable by "piper"), filtering out low-quality legacy system voices. Added setup documentation to the settings help popover. |
| `_working-tree_` | Resolved announcer queue freeze issue by wrapping `ttsSource.render` and `playback.speak` in timeouts (15s/20s) with a Sendable wrapper, ensuring the service logs hangs and recovers. |
| `_working-tree_` | Optimized VoicePlaybackService keepalive pacing to 5 seconds (was 20 ms), resolving the persistent green speaking indicator in Discord when silent and preventing UDP socket congestion/disconnects. |
| `_working-tree_` | Resolved UI thread priority inversion warning in `speakLocallyPreview` by offloading `AVSpeechSynthesizer` calls to an asynchronous background task. |

### 2026-06-09 — Patchy monitoring target sync

| Commit | Summary |
|---|---|
| `_working-tree_` | Synced Patchy monitoring with enabled source targets so added/enabled targets show monitoring as active, healed older saved settings on load/save, and removed the Run Now monitoring control strip above the targets list. |

### 2026-06-09 — Cloudflare token verification feedback

| Commit | Summary |
|---|---|
| `_working-tree_` | Preserved detailed Cloudflare token verification failures and normalized pasted `Bearer`/`Authorization` token headers so adding a token reports Cloudflare's actual error instead of failing with generic authentication/header states. |

### 2026-06-04 — Shutdown QoS + Discord payload safety

| Commit | Summary |
|---|---|
| `_working-tree_` | Removed the blocking termination semaphore by letting AppKit wait for async tunnel shutdown, serialized Discord embed payloads to `Data` before async REST calls, and removed stale classic `AppIcon.appiconset` files so the app stays on the `SwiftBot.icon` Icon Composer path. |
| `_working-tree_` | Cleared targeted Xcode/Swift warnings: updated generated project upgrade metadata via XcodeGen, removed archived OAuth placeholder encoding, dropped redundant awaits, modernized local IP C-string decoding, and marked the animated delete mutation result intentionally unused. |

### 2026-06-03 — Sweep pinned notice analytics + controls

| Commit | Summary |
|---|---|
| `_working-tree_` | Added opt-in 7-day rolling voice averages to Sweep pinned embeds, editing the original pinned notice in place with non-notifying user mentions. Modernised Sweep row actions with compact Try/Run Now controls, added a pencil edit button, and changed clear-channel iconography to `rectangle.stack.slash.fill`. |

### 2026-05-27 — 6+ commits landed

| Commit | Summary |
|---|---|
| `_refactor_` | Refactored overloaded `VoiceRuleEvent` struct to type-safe `SwiftBotEvent` enum with bridge properties. Conformed to SwiftLint associated values count rule. |
| `dae7c01` | Terminology cleanup: "Workflows" → "Automations", `RuleAction` → step naming. `AutomationEngine` → `AutomationService`. |
| `6357bc0` | DM testing (8/8) + absolute expiry timestamp support in setup DM. |
| `1d3bd71` | DM polish: priority game medals + expired-code hint. |
| `16a238e` | MESSAGE_CREATE single-parse pipeline (Priority 1 Phase 1). |
| `c2c1b10` | Apple-only AI consolidation (–1051 LOC net). OpenAI/Ollama/image-gen archived. |
| `b9daeba` | "AI Bots" → "AI" rename + `apple.intelligence` SF Symbol. |
| `981fc7e` + `50619f9` | Apple Intelligence UI revamp + personality picker + `fadingEdges`/shared UI primitives (user). |
| `75d712d` | Add `ROADMAP.md` to repo + AI_CONTEXT requires keeping it current. |
| `03b85db` | Admin HTML cleanup — stripped dead OpenAI/Ollama/image-gen panels and selectors. |
| `_next_` | Purged `FoundationModelsSpikeTests` + renamed internal `aiBots` → `appleIntelligence` across Swift, JSON, and admin HTML. |
| `_ledger_` | Implemented persistent automation execution log history (`automationLog` array capped at 500 entries). |
| `_harness_` | Constructed isolated E2E webhook DM integration test harness with isolation and mock URLSession injection. |
| `_purge_` | Cleaned up all stale comment references to `VoiceRuleEvent`. |
| `_precedence_` | Implemented Typed Trigger System (Option 2) and Spam Moderation Filters (Option 3) with strict moderation execution precedence and full SwiftUI editor integrations. |
| `_simulation_` | Implemented Rule Simulation & Execution Tracing (dry-run engine, simulation fields, and Tahoe-style simulation view). |
| `_manual-intro_` | Added an opt-in manual `/announce join` voice intro using the existing auto-join intro scheduler, with native and admin UI controls. |

**Key decisions**

- **Bypassed SwiftLint associated values limit via sub-payloads** — Grouped associated values of `.message` and `.mediaAdded` into `MessagePayload` and `MediaPayload` structs, keeping case counts within SwiftLint’s `enum_case_associated_values_count` limits while maintaining type safety.
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
