# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

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
