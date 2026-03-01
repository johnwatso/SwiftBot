# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Fixed - 2026-03-02

#### Build Errors - EventBus Type Resolution
**Issue:** Multiple compilation errors related to `EventBus`, `VoiceJoined`, `VoiceLeft`, and `SubscriptionToken` types not being found in scope.

**Root Cause:** The files `EventBus.swift` and `StarterPlugin.swift` were not properly included in the Xcode project's build target, causing cross-file type resolution failures.

**Solution:** Consolidated all EventBus-related types into `Models.swift` to ensure all types are in a single compilation unit:
- Moved `Event` protocol, `SubscriptionToken`, `EventBus` class to top of `Models.swift`
- Moved event types (`VoiceJoined`, `VoiceLeft`, `MessageReceived`) to `Models.swift`
- Moved `WeeklySummaryPlugin` class from `StarterPlugin.swift` to `Models.swift`
- Deprecated `EventBus.swift` and `StarterPlugin.swift` (can be removed from project)

**Files Modified:**
- `Models.swift` - Added EventBus system and WeeklySummaryPlugin
- `EventBus.swift` - Replaced with deprecation notice
- `StarterPlugin.swift` - Replaced with deprecation notice

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

### Known Deprecated Files
These files have been consolidated into other files and can be safely removed:
- `EventBus.swift` - Content moved to `Models.swift`
- `StarterPlugin.swift` - Content moved to `Models.swift`

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
- On-device AI DM replies (Beta)
