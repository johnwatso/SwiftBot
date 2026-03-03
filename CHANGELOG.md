# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Changed - 2026-03-04

#### Repository Hygiene + Release Tooling Consolidation
**Issue:** Generated build artifacts and stale non-source configuration/files were tracked in git, and release publishing logic lived entirely in a large shell script.

**Solution:**
- Removed tracked `build/` output from version control and added `build/` ignore coverage.
- Added a Swift CLI release tool at `Tools/SparklePublisher` and converted `scripts/publish_sparkle_release.sh` into a thin wrapper that calls it.
- Removed stale `project.yml` to avoid drift against the checked-in Xcode project.
- Removed unused root-level `Assets/AppleIntelligence.jpg` and `Assets/ollama.icns` project/resource wiring.
- Fixed README release-script link to a repository-relative path.

**Impact:** No runtime feature changes. Build/release flow is cleaner, easier to maintain, and less likely to reintroduce generated artifact noise in git history.

### Known Issues - 2026-03-03

#### AI Bots Provider Icon Rendering
**Issue:** Apple Intelligence and Ollama provider logos in `AI Bots` are still rendering inconsistently in some builds/environments (including incorrect fallback behavior).

**Status:** Open and tracked as a UI issue for follow-up. Core AI provider functionality and reply routing are unaffected.

### Changed - 2026-03-03

#### Patchy Runtime Integration + Dashboard Redesign
**Issue:** Patch delivery and configuration UX was fragmented, and UpdateEngine formatting was not the sole payload source in runtime delivery flows.

**Solution:** Integrated Patchy into `SwiftBotApp` runtime with a dedicated monitoring dashboard and source-target model:
- Added Patchy to Main navigation and introduced a dedicated monitor panel:
  - grouped SourceTargets by source (AMD, NVIDIA, Intel Arc, Steam)
  - per-target actions: test send, edit, enable/disable, delete
  - focused modal editor (source/server/channel/mentions/enabled)
- Added runtime scheduler in `AppModel`:
  - global Start Monitoring toggle
  - hourly polling cycle (plus manual debug check)
  - fetch-once-per-source-group fan-out delivery to configured targets
- Enforced UpdateEngine embed JSON as source of truth for Discord sends:
  - send path uses `embedJSON` directly when valid/non-empty
  - fallback message only when embed JSON is missing/invalid
  - role mention support with sanitized numeric role IDs and allowed mentions
  - detailed send diagnostics (HTTP status + response snippet)
- Added raw payload Discord REST API method:
  - `sendMessage(channelId:payload:token:)`
  - content helper delegates to payload API

**Impact:** Patchy now behaves like a dedicated monitor dashboard with runtime-owned scheduling and clean per-target delivery.

### Changed - 2026-03-03

#### Offline Discord Metadata Cache + Steam App Name Resolution
**Issue:** Patchy target editing depended on live gateway state; Steam targets showed only App IDs without friendly names.

**Solution:**
- Added persistent Discord metadata cache (`discord-cache.json`) for:
  - servers
  - voice/text channels
  - roles
  - known user display names
- App startup now loads cached metadata and keeps it available when bot is offline/stopped.
- Added Steam app-name resolution from App ID (Steam Store API) with local cache in settings:
  - names resolve automatically when Steam targets are added/updated/checked
  - Patchy list rows show `Steam • <name> (<appID>)` when available

**Impact:** Configuration remains editable offline, and Steam targets are clearer to manage.

### Changed - 2026-03-03

#### UpdateEngine Source Hardening (Standalone)
**Issue:** AMD summary extraction could fall back to `"No release notes available."` despite valid release-note content, and Intel Arc support was missing from built-in sources.

**Solution:** Updated only the standalone `Sources/UpdateEngine` module to improve parser reliability and restore Intel as a first-class source:
- AMD (`AMDService`)
  - Reworked summary extraction priority to: `Highlights` -> `Fixed Issues` -> first meaningful paragraph.
  - Replaced brittle section regex parsing with heading-aware extraction.
  - Improved HTML cleanup for summary content:
    - removes `script/style` blocks
    - handles `<br>` as newlines
    - preserves list hierarchy for bullets/sub-bullets
    - strips remaining tags while preserving text content
- Intel (`IntelService` + `IntelUpdateSource`)
  - Added new standalone Intel Arc source conforming to `UpdateSource`.
  - Uses `sourceKey/cacheKey = intel-default` and identifier-based caching via `identifier = version`.
  - Extracts version, release date, release-notes URL, and summary from Intel Arc driver page payloads.
  - Includes resilient fetch strategy for Intel page variants and descriptive parse errors.
  - Uses Intel Arc logo PNG thumbnail.
- Tester updates
  - Added Intel option to `UpdateEngineTester` CLI.
  - Added Intel option to `UpdateEngineUITester`.

**Verification:**
- `swift build --package-path Sources/UpdateEngine` passed.
- `swift test --package-path Sources/UpdateEngine` passed.
- `swift run --package-path Sources/UpdateEngine UpdateEngineTester --source amd --no-save` passed.
- `swift run --package-path Sources/UpdateEngine UpdateEngineTester --source intel --no-save` passed.

**Important:** No integration into `SwiftBotApp` runtime was performed. No bot startup, runtime polling, Discord event wiring, or existing runtime behavior was changed.

### Changed - 2026-03-03

#### UpdateEngine Standalone Stabilization
**Issue:** `Sources/UpdateEngine` mixed prototype UI/runtime files with core logic, used version-only change checks, and lacked a clean package API boundary.

**Solution:** Refactored UpdateEngine into a standalone library target with identifier-based caching and explicit abstractions:
- Converted package product to library target (`UpdateEngine`) with dedicated source path `Sources/UpdateEngine/Sources/UpdateEngineCore`
- Introduced explicit core protocols/types:
  - `UpdateSource` (source abstraction)
  - `UpdateItem` (identifier + version model)
  - `VersionStore` async protocol (`JSONVersionStore`, `InMemoryVersionStore`)
  - `UpdateChecker` actor for identifier-based checks/saves
  - `CacheKeyBuilder` for scoped cache keys (including per-guild key patterns)
- Added built-in vendor-agnostic source wrappers:
  - `NVIDIAUpdateSource`
  - `AMDUpdateSource`
  - `SteamNewsUpdateSource`
- Added package tests (`UpdateCheckerTests`) covering:
  - first-seen/unchanged/changed flows
  - per-guild scoped-key independence
  - identifier-based behavior independent of display version
- Moved previous prototype app/runtime files into `Sources/UpdateEngine/Legacy/PrototypeApp` to keep them out of the library build surface

**Important:** No integration into `SwiftBotApp` runtime was performed. No bot startup, polling, or Discord event wiring changes were made.

**Files Modified:**
- `Sources/UpdateEngine/Package.swift`
- `Sources/UpdateEngine/Sources/UpdateEngineCore/*` (new core library files)
- `Sources/UpdateEngine/Tests/UpdateEngineTests/UpdateCheckerTests.swift`
- `Sources/UpdateEngine/Legacy/*` (moved legacy prototype files)
- `AI_GUIDE.md`
- `ARCHITECTURE.md`
- `CHANGELOG.md`

### Changed - 2026-03-02

#### Repository Cleanup
**Issue:** The repository contained generated build output, user-specific workspace data, and obsolete duplicate files from earlier project structure changes.

**Solution:** Removed non-source artifacts and stale files from the repo:
- Deleted generated output directories: `Dist/`, `.build/`, `.swiftpm/`
- Deleted obsolete duplicate files: root `EventBus.swift`, `SwiftBotApp/EventBus.swift`, `SwiftBotApp/StarterPlugin.swift`
- Deleted unused leftover project folders: `SwiftBot/`, `SwiftBot.xcodeproj`
- Deleted user-specific metadata: `.DS_Store`, `xcuserdata`
- Added `.gitignore` rules to keep generated and user-local files out of version control

**Files Modified:**
- `.gitignore` - Added ignore rules for generated and user-local files
- `ARCHITECTURE.md` - Removed stale deprecated-files section

### Changed - 2026-03-02

#### Project Rename
**Issue:** The app, package, and project metadata still used the old `DiscordBotApp` naming.

**Solution:** Renamed the active app target and related references from `DiscordBotApp` to `SwiftBot`:
- Renamed the source folder to `SwiftBotApp/`
- Renamed the Xcode project to `SwiftBot.xcodeproj`
- Renamed the app entry file to `SwiftBotApp.swift`
- Updated the SwiftPM package, Xcode target, scheme, and docs to use `SwiftBot`
- Updated storage and Discord client identifier strings to use `SwiftBot`

**Files Modified:**
- `Package.swift`
- `project.yml`
- `SwiftBot.xcodeproj`
- `SwiftBotApp/SwiftBotApp.swift`
- `SwiftBotApp/Persistence.swift`
- `SwiftBotApp/DiscordService.swift`
- `README.md`
- `ARCHITECTURE.md`
- `AI_GUIDE.md`

### Fixed - 2026-03-02

#### Build Errors - EventBus Type Resolution
**Issue:** Multiple compilation errors related to `EventBus`, `VoiceJoined`, `VoiceLeft`, and `SubscriptionToken` types not being found in scope.

**Root Cause:** The files `EventBus.swift` and `StarterPlugin.swift` were not properly included in the Xcode project's build target, causing cross-file type resolution failures.

**Solution:** Consolidated all EventBus-related types into `Models.swift` to ensure all types are in a single compilation unit:
- Moved `Event` protocol, `SubscriptionToken`, `EventBus` class to top of `Models.swift`
- Moved event types (`VoiceJoined`, `VoiceLeft`, `MessageReceived`) to `Models.swift`
- Moved `WeeklySummaryPlugin` class from `StarterPlugin.swift` to `Models.swift`
- Removed the old `EventBus.swift` and `StarterPlugin.swift` files after consolidation

**Files Modified:**
- `Models.swift` - Added EventBus system and WeeklySummaryPlugin

#### Server Notifier Rules Mirroring
**Issue:** When editing one notification rule, changes would affect other rules, making them appear to "mirror" each other.

**Root Cause:** Two separate bugs working together:
1. **Stale Binding Reference:** The `selectedRuleBinding` computed property was capturing `selectedRuleID` at creation time but not looking up the current selected rule ID when getting/setting values
2. **Missing View Identity:** `RuleEditorView` lacked an `.id()` modifier, causing SwiftUI to reuse the same view instance when switching between rules

**Solution:**
1. Updated `selectedRuleBinding` to always look up `app.ruleStore.selectedRuleID` fresh on each access in both `get` and `set` closures
2. Added `.id(app.ruleStore.selectedRuleID)` to `RuleEditorView` to force view recreation when selection changes

**Files Modified:**
- `RootView.swift` - Fixed `ServerNotifierView.selectedRuleBinding` computed property
- `RootView.swift` - Added `.id()` modifier to `RuleEditorView`

**Impact:** Each rule now maintains independent state; editing one rule no longer affects others.

---

## Project Structure Notes

### Current Architecture
- **Main App:** SwiftUI-based macOS Discord bot dashboard
- **Core Files:**
  - `Models.swift` - All data models, EventBus system, plugins
  - `AppModel.swift` - Main application state and business logic
  - `DiscordService.swift` - Discord Gateway and REST API communication
  - `RootView.swift` - Main UI views and components
  - `Persistence.swift` - Settings and rules persistence

### EventBus System
- Location: `Models.swift` (consolidated from `EventBus.swift`)
- Purpose: Type-safe publish/subscribe event system for plugins
- Events: `VoiceJoined`, `VoiceLeft`, `MessageReceived`
- Usage: Allows plugins to subscribe to bot events asynchronously

### Plugin System
- Protocol: `BotPlugin` defined in `Models.swift`
- Manager: `PluginManager` class in `Models.swift`
- Current Plugins:
  - `WeeklySummaryPlugin` - Tracks voice channel usage time

---

## Development Guidelines

### Making Changes
When modifying this project, please update this CHANGELOG with:
- **What** was changed
- **Why** it was changed
- **Which files** were modified
- **Impact** on functionality

### For AI Assistants
This file serves as a reference for:
- Understanding recent changes and their rationale
- Avoiding reintroduction of fixed bugs
- Maintaining awareness of deprecated files
- Understanding the current project structure

---

## Version History

### Initial State
- Native macOS Discord bot with SwiftUI interface
- Gateway connection with voice presence tracking
- Server notification rules engine
- Command system with prefix support
- On-device AI replies for DMs and channel mentions (Beta)
